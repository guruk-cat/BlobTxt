import SwiftUI
import AppKit

// The editor-only window. There is one instance per app session; the blob it shows tracks store.miniViewURL. It is identical to the main editor environment except for an independent font size (see EditorMonitor's miniFontSize) and the smaller window.
struct MiniView: View {
    static let windowID = "mini-view"

    @EnvironmentObject var store: ProjectStore
    @EnvironmentObject var appColors: AppColors

    @AppStorage("followSystemAppearance") private var followSystemAppearance: Bool = false

    // The blob actually mounted in the editor. Distinct from store.miniViewURL so a swap can flush the outgoing editor before the incoming one mounts.
    @State private var displayedURL: URL?
    @State private var flush: EditorFlush?
    @State private var hostWindow: NSWindow?
    // Set while the window is tearing down, so reacting to store.miniViewURL going nil doesn't re-close it.
    @State private var isClosing = false

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
        })
        .onAppear { displayedURL = store.miniViewURL }
        // The blob changed from elsewhere: a fresh open/focus, a rename repoint, or nil for a delete/project-close.
        .onChange(of: store.miniViewURL) { newURL in
            guard let newURL = newURL else {
                if !isClosing { hostWindow?.close() }
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
        }
    }
}
