import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var store: ProjectStore
    @EnvironmentObject var appColors: AppColors
    @Environment(\.openWindow) private var openWindow
    @State var activeEditorURL: URL?
    @State var isSidebarOpen: Bool = true
    @State var activePanel: SidebarPanel = .navigator

    // This window, for key-window gating of window-scoped shortcuts (e.g. Print).
    @State private var hostWindow: NSWindow?

    // Owned here, not in FileNavigatorView, so the navigator's tree state (expanded folders, the creation-context directory) and its FSEvents watcher survive the sidebar being closed — the navigator view is torn down whenever no panel is active.
    @StateObject private var navigator = NavigatorModel()

    @AppStorage("followSystemAppearance") private var followSystemAppearance: Bool = false
    @Environment(\.colorScheme) private var systemColorScheme
    // Persisted so the app can restore fullscreen state on next launch.
    @AppStorage("wasFullScreen") private var wasFullScreen: Bool = false

    @State private var isShowingSettings: Bool = false
    @State private var isMergingBlobs: Bool = false
    @State private var isEditingLayout: Bool = false
    @State private var isEditingMetadata: Bool = false
    @State private var hoverSelectProject: Bool = false

    // App-global page-layout profiles; the go-to profile drives File → Print.
    @ObservedObject private var layoutStore = LayoutStore.shared

    // Set when a print/PDF export fails, presented as an alert.
    @State private var printError: String?


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
            .modifier(FileOpsOpenReceivers(
                openMerge: { openFileOpsOverlay { isMergingBlobs = true } },
                openLayout: { openFileOpsOverlay { isEditingLayout = true } },
                // Editor-gated, so ignore the route if no blob is open (the launch button is also disabled then).
                openMetadata: { if store.activeContent != nil { openFileOpsOverlay { isEditingMetadata = true } } }
            ))
            .onReceive(NotificationCenter.default.publisher(for: .printDocument)) { _ in
                // Print targets this window's blob, so ignore the shortcut when another window (e.g. the mini view) is key.
                guard hostWindow?.isKeyWindow == true else { return }
                printActiveBlob()
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
            .alert("Print Failed", isPresented: Binding(
                get: { printError != nil },
                set: { if !$0 { printError = nil } }
            )) {
                Button("OK", role: .cancel) { printError = nil }
            } message: {
                Text(printError ?? "")
            }
    }

    // The structural view tree: sidebar, editor region, floating island, and the window-level panels.
    private var rootView: some View {
        HStack(alignment: .top) {

            // Sidebar
            SidebarView(
                isSidebarOpen: $isSidebarOpen,
                activePanel: $activePanel,
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
                                onClose: { activeEditorURL = nil },
                                isModalOverlayActive: { isMergingBlobs || isEditingLayout || isEditingMetadata }
                            )
                            .id(url)
                        } else {
                            EditorMonitor(
                                url: url,
                                onClose: {
                                    activeEditorURL = nil
                                },
                                onOpenDocument: openLocalTarget,
                                flushHandler: $flushCurrentEditor,
                                isModalOverlayActive: { isMergingBlobs || isEditingLayout || isEditingMetadata }
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
        // Page Layout panel: same window-level overlay treatment as Merge Blobs.
        .overlay {
            if isEditingLayout {
                PageLayoutPanel(onExit: closePageLayout)
            }
        }
        // Blob Metadata panel: same window-level overlay treatment, targeting the open blob.
        .overlay {
            if isEditingMetadata {
                MetadataOpPanel(onExit: closeMetadata)
            }
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

    // Renders the open blob to PDF via pandoc and opens the result. Flushes any pending edits first so the export reflects what is on screen, then asks for a destination before writing.
    private func printActiveBlob() {
        guard let url = activeEditorURL, url.isBlobFile else { return }
        let proceed = {
            guard let destination = promptForPDFDestination(for: url) else { return }
            PrintService.printBlob(at: url, to: destination, profile: layoutStore.goToProfile) { result in
                switch result {
                case .success(let pdf): NSWorkspace.shared.open(pdf)
                case .failure(let error): printError = error.localizedDescription
                }
            }
        }
        if let flush = flushCurrentEditor {
            flush.save { proceed() }
        } else {
            proceed()
        }
    }

    // Presents a Save panel for the PDF, defaulting to the blob's name and directory. Returns nil if the user cancels.
    private func promptForPDFDestination(for blob: URL) -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = blob.deletingPathExtension().lastPathComponent + ".pdf"
        panel.directoryURL = blob.deletingLastPathComponent()
        panel.canCreateDirectories = true
        panel.prompt = "Export"
        panel.message = "Choose where to save the PDF"
        return panel.runModal() == .OK ? panel.url : nil
    }

    // Floats a file-ops overlay in over the still-open sidebar (see dismissFileOpsOverlay).
    private func openFileOpsOverlay(_ activate: () -> Void) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            activate()
        }
    }

    // Cancelled out of the merge flow: dismiss the panel and reopen the sidebar at the File Ops panel.
    private func cancelMergeBlobs() {
        dismissFileOpsOverlay(returningTo: .opsControl)
    }

    // Exited the Page Layout panel: same return to the File Ops sidebar panel as Merge Blobs.
    private func closePageLayout() {
        dismissFileOpsOverlay(returningTo: .opsControl)
    }

    // Closed the Blob Metadata panel: same return to the File Ops sidebar panel.
    private func closeMetadata() {
        dismissFileOpsOverlay(returningTo: .opsControl)
    }

    // Finished the merge: dismiss the panel, reopen the sidebar at the navigator, and open the new blob.
    private func finishMergeBlobs(_ url: URL) {
        dismissFileOpsOverlay(returningTo: .navigator)
        requestOpen(url)
    }

    // Tears the file-ops overlay down. The sidebar stayed open behind the scrim the whole time, so only the panel selection is updated here.
    private func dismissFileOpsOverlay(returningTo panel: SidebarPanel) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            isMergingBlobs = false
            isEditingLayout = false
            isEditingMetadata = false
            activePanel = panel
            isSidebarOpen = true
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

// Bundles the three file-ops launch receivers so the main `body` chain stays within the type-checker's inference budget.
private struct FileOpsOpenReceivers: ViewModifier {
    let openMerge: () -> Void
    let openLayout: () -> Void
    let openMetadata: () -> Void

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .openMergeBlobs)) { _ in openMerge() }
            .onReceive(NotificationCenter.default.publisher(for: .openPageLayout)) { _ in openLayout() }
            .onReceive(NotificationCenter.default.publisher(for: .openMetadata)) { _ in openMetadata() }
    }
}

#Preview {
    ContentView()
        .environmentObject(ProjectStore())
        .environmentObject(AppColors.shared)
}
