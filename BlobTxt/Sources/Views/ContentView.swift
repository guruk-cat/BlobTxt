import SwiftUI

struct ContentView: View {
    @EnvironmentObject var store: ProjectStore
    @EnvironmentObject var appColors: AppColors
    @State var activeEditorURL: URL?
    @State var isSidebarOpen: Bool = true
    @State var activePanel: SidebarPanel = .navigator

    @AppStorage("followSystemAppearance") private var followSystemAppearance: Bool = false
    @Environment(\.colorScheme) private var systemColorScheme
    @State private var editorOpacity: Double = 1.0
    @State private var isFocusMode: Bool = false
    @State private var isFullScreen: Bool = false
    @AppStorage("defaultFocusMode") private var defaultFocusMode: Bool = false
    // Persisted so the app can restore fullscreen state on next launch.
    @AppStorage("wasFullScreen") private var wasFullScreen: Bool = false

    @State private var isShowingSettings: Bool = false
    @State private var hoverSelectProject: Bool = false

    // Non-nil while the Blaze Clean dialog is shown; holds the `clean --preview` result it displays.
    @State private var blazeCleanPreview: BlazeCleanPreview?

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
            if !isFocusMode {
                SidebarView(
                    isSidebarOpen: $isSidebarOpen,
                    activePanel: $activePanel,
                    activeEditorURL: $activeEditorURL,
                    // Opening a row saves the current blob before swapping; the binding above is left
                    // for the navigator's own repointing (rename/move) and clearing (delete).
                    onRequestOpen: requestOpen
                )
            }

            // Editor
            ZStack {
                AppColors.shared.surface
                    .ignoresSafeArea()

                if store.currentProject != nil {
                    if let url = activeEditorURL {
                        AppColors.shared.surface
                            .ignoresSafeArea()

                        if url.isImageFile {
                            ImageViewer(url: url, onClose: {
                                activeEditorURL = nil
                                isFocusMode = false
                            })
                            .id(url)
                        } else {
                            EditorMonitor(
                                url: url,
                                isFocusMode: $isFocusMode,
                                isFullScreen: isFullScreen,
                                onClose: {
                                    activeEditorURL = nil
                                    isFocusMode = false
                                },
                                onOpenDocument: openLocalTarget,
                                flushHandler: $flushCurrentEditor
                            )
                            .id(url)
                            .opacity(editorOpacity)
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
                            .foregroundColor(hoverSelectProject ? AppColors.shared.surface : AppColors.shared.metaIndication)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(hoverSelectProject ? AppColors.shared.metaIndication
                                          : AppColors.shared.surface)
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
            if !isFocusMode {
                FloatingIslandView(isSidebarOpen: $isSidebarOpen, activePanel: $activePanel)
                    .padding(.leading, 8)
                    .padding(.bottom, 8)
            }
        }
        .frame(minWidth: 700, minHeight: 480)
        .background(AppColors.shared.surface)
        .toolbarBackground(appColors.chromeToolbar, for: .windowToolbar)
        .toolbarBackground(.visible, for: .windowToolbar)
        .preferredColorScheme(resolvedColorScheme)
        .sheet(isPresented: $isShowingSettings) {
            SettingsView()
                .environmentObject(AppColors.shared)
        }
        .onAppear {
            if followSystemAppearance {
                appColors.applySystemAppearance(dark: systemColorScheme == .dark)
            }
            if wasFullScreen {
                DispatchQueue.main.async {
                    NSApp.mainWindow?.toggleFullScreen(nil)
                }
            }
        }
        // Clear the open editor when the project changes so the editor doesn't show a stale blob.
        .onChange(of: store.currentProject?.url) { _ in
            activeEditorURL = nil
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
        .onChange(of: activeEditorURL) { newURL in
            let fullScreen = NSApp.mainWindow?.styleMask.contains(.fullScreen) ?? false
            isFocusMode = newURL != nil && defaultFocusMode && fullScreen
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleFocusMode)) { _ in
            guard activeEditorURL != nil else { return }
            isFocusMode.toggle()
        }
        .onChange(of: isFocusMode) { _ in
            guard activeEditorURL != nil else { return }
            editorOpacity = 0
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                withAnimation(.easeIn(duration: 0.3)) { editorOpacity = 1 }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { notif in
            guard (notif.object as? NSWindow) === NSApp.mainWindow else { return }
            isFullScreen = true
            wasFullScreen = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { notif in
            guard (notif.object as? NSWindow) === NSApp.mainWindow else { return }
            isFullScreen = false
            wasFullScreen = false
            isFocusMode = false
        }
        .onReceive(NotificationCenter.default.publisher(for: .showPreferences)) { _ in
            isShowingSettings = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .showProjectPicker)) { _ in
            store.openProjectWithPanel()
        }
        // Blaze Clean (File menu): compute the preview off the main thread, then present the dialog.
        .onReceive(NotificationCenter.default.publisher(for: .blazeClean)) { _ in
            guard let projectURL = store.currentProject?.url else { return }
            DispatchQueue.global(qos: .userInitiated).async {
                let preview = BlazeTracker.cleanPreview(projectURL: projectURL)
                DispatchQueue.main.async { blazeCleanPreview = preview }
            }
        }
        .alert("Blaze Clean", isPresented: Binding(
            get: { blazeCleanPreview != nil },
            set: { if !$0 { blazeCleanPreview = nil } }
        ), presenting: blazeCleanPreview) { preview in
            if preview.isInitialized && !preview.stalePaths.isEmpty {
                Button("Clean", role: .destructive) { confirmBlazeClean() }
                Button("Cancel", role: .cancel) {}
            } else {
                Button("OK", role: .cancel) {}
            }
        } message: { preview in
            if !preview.isInitialized {
                Text("Blaze has not been initialized in this project.")
            } else if preview.stalePaths.isEmpty {
                Text("Nothing to clean.")
            } else {
                Text("\(preview.stalePaths.count) stale reference(s) will be removed:\n\n"
                     + preview.stalePaths.joined(separator: "\n"))
            }
        }
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

    // Runs the real `blaze clean` after the user confirms.
    private func confirmBlazeClean() {
        guard let projectURL = store.currentProject?.url else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            BlazeTracker.clean(projectURL: projectURL)
        }
    }

}

#Preview {
    ContentView()
        .environmentObject(ProjectStore())
        .environmentObject(AppColors.shared)
}
