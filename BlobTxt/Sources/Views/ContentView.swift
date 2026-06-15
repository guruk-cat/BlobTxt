import SwiftUI

struct ContentView: View {
    @EnvironmentObject var store: ProjectStore
    @EnvironmentObject var appColors: AppColors
    @State var activeEditorURL: URL?
    @State var isSidebarOpen: Bool = true
    @State var activePanel: SidebarPanel = .navigator

    // Owned here, not in FileNavigatorView, so the navigator's tree state (expanded folders, the
    // creation-context directory) and its FSEvents watcher survive the sidebar being closed — the
    // navigator view is torn down whenever no panel is active.
    @StateObject private var navigator = NavigatorModel()

    @AppStorage("followSystemAppearance") private var followSystemAppearance: Bool = false
    @Environment(\.colorScheme) private var systemColorScheme
    // Persisted so the app can restore fullscreen state on next launch.
    @AppStorage("wasFullScreen") private var wasFullScreen: Bool = false

    @State private var isShowingSettings: Bool = false
    @State private var isMergingBlobs: Bool = false
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
        HStack(alignment: .top) {

            // Sidebar
            SidebarView(
                isSidebarOpen: $isSidebarOpen,
                activePanel: $activePanel,
                activeEditorURL: $activeEditorURL,
                navigator: navigator,
                // Opening a row saves the current blob before swapping; the binding above is left
                // for the navigator's own repointing (rename/move) and clearing (delete).
                onRequestOpen: requestOpen
            )

            // Editor
            ZStack {
                AppColors.shared.uiSurface
                    .ignoresSafeArea()

                if store.currentProject != nil {
                    if let url = activeEditorURL {
                        AppColors.shared.uiSurface
                            .ignoresSafeArea()

                        if url.isImageFile {
                            ImageViewer(url: url, onClose: {
                                activeEditorURL = nil
                            })
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
                            .foregroundColor(AppColors.shared.uiTextMuted)
                    }
                } else {
                    Button {
                        store.openProjectWithPanel()
                    } label: {
                        Text("Select Project")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(hoverSelectProject ? AppColors.shared.uiSurface : AppColors.shared.uiIndication)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(hoverSelectProject ? AppColors.shared.uiIndication
                                          : AppColors.shared.uiSurface)
                            )
                    }
                    .buttonStyle(.plain)
                    .onHover { hoverSelectProject = $0 }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // Dynamic island
        .overlay(alignment: .bottomLeading) {
            FloatingIslandView(isSidebarOpen: $isSidebarOpen, activePanel: $activePanel)
                .padding(.leading, 8)
                .padding(.bottom, 8)
        }
        // Merge Blobs panel: a window-level overlay above everything, including the island.
        .overlay {
            if isMergingBlobs {
                MergeBlobsPanel(onCancel: cancelMergeBlobs, onFinish: finishMergeBlobs)
            }
        }
        .frame(minWidth: 700, minHeight: 480)
        .background(AppColors.shared.uiSurface)
        .toolbarBackground(appColors.windowBar, for: .windowToolbar)
        .toolbarBackground(.visible, for: .windowToolbar)
        .preferredColorScheme(resolvedColorScheme)
        .sheet(isPresented: $isShowingSettings) {
            SettingsView()
                .environmentObject(AppColors.shared)
        }
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
        // Clear the open editor when the project changes so the editor doesn't show a stale blob,
        // and re-point the navigator at the new project (resetting its tree state and watcher).
        .onChange(of: store.currentProject?.url) { newURL in
            activeEditorURL = nil
            if let newURL = newURL { navigator.activate(projectURL: newURL) }
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
        // Opening the Merge Blobs flow closes the sidebar, then floats the panel in.
        .onReceive(NotificationCenter.default.publisher(for: .openMergeBlobs)) { _ in
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                isSidebarOpen = false
                isMergingBlobs = true
            }
        }
    }

    // Cancelled out of the merge flow: dismiss the panel and reopen the sidebar at the File Ops panel.
    private func cancelMergeBlobs() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            isMergingBlobs = false
            activePanel = .opsControl
            isSidebarOpen = true
        }
    }

    // Finished the merge: dismiss the panel, reopen the sidebar at the navigator, and open the new blob.
    private func finishMergeBlobs(_ url: URL) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            isMergingBlobs = false
            activePanel = .navigator
            isSidebarOpen = true
        }
        requestOpen(url)
    }

    // Routes a followed local link. Blobs and images open in the content region;
    // any other file type is handed to the OS.
    private func openLocalTarget(_ target: URL) {
        if target.isBlobFile || target.isImageFile {
            requestOpen(target)
        } else {
            NSWorkspace.shared.open(target)
        }
    }

    // Single entry point for switching the open document. If another blob is already open and has
    // unsaved edits, its editor is flushed to disk first and the swap happens only once that write
    // completes; performSave returns immediately when nothing is dirty, so clean switches are instant.
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
