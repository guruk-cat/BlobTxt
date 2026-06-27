import SwiftUI

struct ContentView: View {
    @EnvironmentObject var store: ProjectStore
    @EnvironmentObject var appColors: AppColors
    @Environment(\.openWindow) private var openWindow
    @State var activeEditorURL: URL?
    @State var isSidebarOpen: Bool = true

    // This window, for key-window gating of window-scoped shortcuts.
    @State private var hostWindow: NSWindow?

    // Owned here, not in FileNavigatorView, so the navigator's tree state (expanded folders, the creation-context directory) and its FSEvents watcher survive the sidebar being closed — the navigator view is torn down whenever no panel is active.
    @StateObject private var navigator = NavigatorModel()

    @AppStorage("followSystemAppearance") private var followSystemAppearance: Bool = false
    @Environment(\.colorScheme) private var systemColorScheme
    // Persisted so the app can restore fullscreen state on next launch.
    @AppStorage("wasFullScreen") private var wasFullScreen: Bool = false

    @State private var isShowingSettings: Bool = false
    @State private var hoverSelectProject: Bool = false

    // Registered by the mounted EditorMonitor; flushes the open document to disk and reports back.
    // Used to save the current blob before switching to another one (see `requestOpen`).
    @State private var flushCurrentEditor: EditorFlush?

    // Returns nil when following system appearance so SwiftUI leaves the color scheme unforced.
    private var resolvedColorScheme: ColorScheme? {
        guard !followSystemAppearance else { return nil }
        return appColors.isDark ? .dark : .light
    }

    var body: some View {
        // Split from the structural tree below so each expression type-checks on its own; the full chain in one `body` exceeds the compiler's inference budget.
        rootView
            .onAppear {
                if let url = store.currentProject?.url { navigator.activate(projectURL: url) }
                if followSystemAppearance {
                    appColors.applySystemAppearance(dark: systemColorScheme == .dark)
                }
                if wasFullScreen {
                    DispatchQueue.main.async {
                        NSApp.mainWindow?.toggleFullScreen(nil)
                    }
                }
            }
            // Clear the open editor when the project changes so the editor doesn't show a stale blob, and re-point the navigator at the new project (resetting its tree state and watcher). The mini-view windows belong to the old project, so close them all.
            .onChange(of: store.currentProject?.url) { newURL in
                activeEditorURL = nil
                NotificationCenter.default.post(name: .closeAllMiniViews, object: nil)
                if let newURL = newURL { navigator.activate(projectURL: newURL) }
            }
            // Mirror the open document into the store, but only when it is a printable blob (not an image), so the File → Print menu item can gate itself.
            .onChange(of: activeEditorURL) { url in
                store.activeBlobURL = (url?.isBlobFile == true) ? url : nil
            }
            .onChange(of: systemColorScheme) { scheme in
                guard followSystemAppearance else { return }
                appColors.applySystemAppearance(dark: scheme == .dark)
            }
            .onChange(of: followSystemAppearance) { isOn in
                if isOn {
                    appColors.applySystemAppearance(dark: systemColorScheme == .dark)
                } else {
                    appColors.reloadManualPalette()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { notif in
                guard (notif.object as? NSWindow) === NSApp.mainWindow else { return }
                wasFullScreen = true
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { notif in
                guard (notif.object as? NSWindow) === NSApp.mainWindow else { return }
                wasFullScreen = false
            }
            .onReceive(NotificationCenter.default.publisher(for: .showPreferences)) { _ in
                isShowingSettings = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .showProjectPicker)) { _ in
                store.openProjectWithPanel()
            }
            // Open a blob in the mini view: open (or focus) the window carrying this blob. The blob may also stay open in the main editor — both share one BlobContent — so flush the main editor first if it holds this blob, so the mini view opens on its latest content.
            .onReceive(NotificationCenter.default.publisher(for: .openMiniView)) { notif in
                guard let url = notif.object as? URL else { return }
                let proceed = {
                    openWindow(id: MiniView.windowID, value: url)
                }
                if activeEditorURL == url, let flush = flushCurrentEditor {
                    flush.save { proceed() }
                } else {
                    proceed()
                }
            }
            // A cross-file link followed inside the mini view routes here, opening in this window.
            .onReceive(NotificationCenter.default.publisher(for: .openInMain)) { notif in
                guard let url = notif.object as? URL else { return }
                openLocalTarget(url)
                hostWindow?.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            }
    }

    // The structural view tree: sidebar, editor region, floating island, and the window-level panels.
    private var rootView: some View {
        HStack(alignment: .top) {

            // Sidebar
            SidebarView(
                isSidebarOpen: $isSidebarOpen,
                activeEditorURL: $activeEditorURL,
                navigator: navigator,
                // Opening a row saves the current blob before swapping; the binding above is left for the navigator's own repointing (rename/move) and clearing (delete).
                onRequestOpen: requestOpen
            )

            // Editor
            ZStack {
                AppColors.shared.surface
                    .ignoresSafeArea()

                if store.currentProject != nil {
                    if let url = activeEditorURL {
                        AppColors.shared.surface
                            .ignoresSafeArea()

                        if url.isImageFile {
                            ImageViewer(
                                url: url,
                                onClose: { activeEditorURL = nil }
                            )
                            .id(url)
                        } else {
                            EditorMonitor(
                                url: url,
                                onClose: {
                                    activeEditorURL = nil
                                },
                                onOpenDocument: openLocalTarget,
                                flushHandler: $flushCurrentEditor
                            )
                            .id(url)
                        }
                    } else {
                        Text("Open a document")
                            .font(.system(size: 16))
                            .foregroundColor(AppColors.shared.textMuted)
                    }
                } else {
                    Button {
                        store.openProjectWithPanel()
                    } label: {
                        Text("Select Project")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(hoverSelectProject ? AppColors.shared.surface : AppColors.shared.uiIndication)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(hoverSelectProject ? AppColors.shared.uiIndication
                                          : AppColors.shared.surface)
                            )
                    }
                    .buttonStyle(.plain)
                    .onHover { hoverSelectProject = $0 }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 700, minHeight: 480)
        .background(AppColors.shared.surface)
        .background(WindowAccessor { hostWindow = $0 })
        .toolbarBackground(appColors.windowBar, for: .windowToolbar)
        .toolbarBackground(.visible, for: .windowToolbar)
        .preferredColorScheme(resolvedColorScheme)
        .sheet(isPresented: $isShowingSettings) {
            SettingsView()
                .environmentObject(AppColors.shared)
        }
    }

    // Routes a followed local link. Blobs and images open in the content region.
    // Any other file type is handed to the OS.
    private func openLocalTarget(_ target: URL) {
        if target.isBlobFile || target.isImageFile {
            requestOpen(target)
        } else {
            NSWorkspace.shared.open(target)
        }
    }

    // Single entry point for switching the open document.
    // If another blob is already open and has unsaved edits, its editor is flushed to disk first and the swap happens only once that write completes; performSave returns immediately when nothing is dirty, so clean switches are instant.
    private func requestOpen(_ target: URL) {
        guard target != activeEditorURL else { return }
        if let flush = flushCurrentEditor {
            flush.save { activeEditorURL = target }
        } else {
            activeEditorURL = target
        }
    }

}

#Preview {
    ContentView()
        .environmentObject(ProjectStore())
        .environmentObject(AppColors.shared)
}
