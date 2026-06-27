import SwiftUI
import AppKit

// An editor-only window, one per blob. The blob is fixed for the window's life, seeded from the scene value; opening a different blob opens (or focuses) a different window. It is identical to the main editor environment except for an independent font size (see EditorMonitor's miniFontSize) and the smaller window.
struct MiniView: View {
    static let windowID = "mini-view"

    // The blob this window was opened on, from the WindowGroup value.
    let url: URL

    @EnvironmentObject var appColors: AppColors

    @AppStorage("followSystemAppearance") private var followSystemAppearance: Bool = false

    // The blob actually mounted in the editor, seeded from `url` and repointed in place when that blob is renamed or moved. Local rather than reading the scene value so a rename can follow the file without the window being reopened.
    @State private var displayedURL: URL?
    @State private var flush: EditorFlush?
    @State private var hostWindow: NSWindow?

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
        .onAppear {
            windowDelegate.skipSave = false
            displayedURL = url
        }
        // Keep the delegate's save handle pointed at the mounted editor.
        .onChange(of: flush?.url) { _ in windowDelegate.flush = flush }
        // This window's blob was renamed or moved: follow it in place. The displayedURL change remounts the editor onto the new path.
        .onReceive(NotificationCenter.default.publisher(for: .blobMoved)) { notif in
            guard let move = notif.object as? BlobMoveInfo,
                  let current = displayedURL,
                  let repointed = repointedURL(current, forMove: move) else { return }
            if let flush = flush, flush.url == current {
                flush.save { displayedURL = repointed }
            } else {
                displayedURL = repointed
            }
        }
        // This window's blob was deleted: close without writing it back, since the file is gone.
        .onReceive(NotificationCenter.default.publisher(for: .blobDeleted)) { notif in
            guard let deleted = notif.object as? URL,
                  let current = displayedURL,
                  isAffected(current, byDeletionOf: deleted) else { return }
            closeWithoutSaving()
        }
        // The project changed: this window's blob belongs to the old project, so close without writing it back.
        .onReceive(NotificationCenter.default.publisher(for: .closeAllMiniViews)) { _ in
            closeWithoutSaving()
        }
    }

    // Closes the window without flushing the editor, for code-driven closes (delete, project change) where a write-back would be stale or recreate a gone file.
    private func closeWithoutSaving() {
        windowDelegate.skipSave = true
        hostWindow?.close()
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
