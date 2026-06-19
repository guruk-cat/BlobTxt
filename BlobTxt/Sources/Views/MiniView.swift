import SwiftUI
import AppKit

// The editor-only window. There is one instance per app session; the blob it shows tracks store.miniViewURL. It is identical to the main editor environment except for an independent font size (see EditorMonitor's miniFontSize) and the smaller window.
struct MiniView: View {
    static let windowID = "mini-view"

    @EnvironmentObject var store: ProjectStore
    @EnvironmentObject var appColors: AppColors

    @AppStorage("followSystemAppearance") private var followSystemAppearance: Bool = false

    // The blob actually mounted in the editor. Distinct from store.miniViewURL so a swap can flush the outgoing editor before the incoming one mounts, and so closing the window can drop the editor entirely (forcing the next open to reload from disk).
    @State private var displayedURL: URL?
    @State private var flush: EditorFlush?
    @State private var hostWindow: NSWindow?
    // Set while the window is tearing down, so reacting to store.miniViewURL going nil doesn't re-close it.
    @State private var isClosing = false

    // Intercepts the window's close so the editor flushes to disk before the webview tears down. See MiniWindowDelegate.
    @StateObject private var windowDelegate = MiniWindowDelegate()

    private var resolvedColorScheme: ColorScheme? {
        guard !followSystemAppearance else { return nil }
        return appColors.isDark ? .dark : .light
    }

    var body: some View {
        ZStack {
            AppColors.shared.surface
                .ignoresSafeArea()

            if let url = displayedURL {
                EditorMonitor(
                    url: url,
                    onClose: { hostWindow?.close() },
                    onOpenDocument: { NotificationCenter.default.post(name: .openInMain, object: $0) },
                    flushHandler: $flush,
                    isModalOverlayActive: { false },
                    closesOnEscape: false,
                    isMini: true
                )
                .id(url)
            }
        }
        .frame(minWidth: 360, minHeight: 300)
        .background(AppColors.shared.surface)
        .preferredColorScheme(resolvedColorScheme)
        .navigationTitle(displayedURL?.deletingPathExtension().lastPathComponent ?? "Mini View")
        .background(WindowAccessor { window in
            hostWindow = window
            window?.identifier = NSUserInterfaceItemIdentifier(Self.windowID)
            window?.isRestorable = false
            // Insert our close-interceptor ahead of SwiftUI's delegate, forwarding everything else to it.
            if let window = window, window.delegate !== windowDelegate {
                windowDelegate.forward = window.delegate
                window.delegate = windowDelegate
            }
        })
        // A fresh open: the window scene is reused across close/reopen, so reset the per-session flags and mount the editor.
        .onAppear {
            isClosing = false
            windowDelegate.skipSave = false
            displayedURL = store.miniViewURL
        }
        // Keep the delegate's save handle pointed at the mounted editor.
        .onChange(of: flush?.url) { _ in windowDelegate.flush = flush }
        // The blob changed from elsewhere: a fresh open/focus, a rename repoint, or nil for a delete/project-close.
        .onChange(of: store.miniViewURL) { newURL in
            guard let newURL = newURL else {
                // The URL was cleared externally (delete or project close), so the editor's content is stale or gone: close without writing it back.
                if !isClosing {
                    isClosing = true
                    windowDelegate.skipSave = true
                    hostWindow?.close()
                }
                return
            }
            if let flush = flush, flush.url != newURL {
                flush.save { displayedURL = newURL }
            } else {
                displayedURL = newURL
            }
        }
        .onDisappear {
            isClosing = true
            store.miniViewURL = nil
            // Drop the editor so the next open remounts and reloads from disk rather than reusing this session's stale view.
            displayedURL = nil
        }
    }
}

// Sits in front of SwiftUI's own window delegate to flush the editor to disk before the window closes. windowShouldClose runs while the webview is still alive, so the async content read can complete; once saved it closes the window for real. The save is skipped for code-driven closes (delete/project-close), which would otherwise rewrite a file that is gone or out of date.
final class MiniWindowDelegate: NSObject, NSWindowDelegate, ObservableObject {
    weak var forward: NSWindowDelegate?
    var flush: EditorFlush?
    var skipSave = false
    // Set between asking for the save and the follow-up close, so the second windowShouldClose lets the window go.
    private var proceeding = false

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if proceeding {
            proceeding = false
            return forward?.windowShouldClose?(sender) ?? true
        }
        guard !skipSave, let flush = flush else {
            return forward?.windowShouldClose?(sender) ?? true
        }
        proceeding = true
        flush.save { sender.close() }
        return false
    }

    // Forward every other delegate call to SwiftUI's original delegate so the scene's own lifecycle keeps working.
    override func responds(to aSelector: Selector!) -> Bool {
        super.responds(to: aSelector) || (forward?.responds(to: aSelector) ?? false)
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        if forward?.responds(to: aSelector) == true { return forward }
        return super.forwardingTarget(for: aSelector)
    }
}
