import SwiftUI

struct ContentView: View {
    @EnvironmentObject var store: ProjectStore
    @EnvironmentObject var appColors: AppColors
    @State var selectedProjectID: UUID?
    @State var activeBlobID: UUID?
    @State var isSidebarOpen: Bool = true
    @State var activePanel: SidebarPanel = .navigator

    @AppStorage("lastProjectID") private var lastProjectIDString: String = ""
    @AppStorage("followSystemAppearance") private var followSystemAppearance: Bool = false
    @Environment(\.colorScheme) private var systemColorScheme
    @State private var editorOpacity: Double = 1.0
    @State private var isFocusMode: Bool = false
    @State private var isFullScreen: Bool = false
    @AppStorage("defaultFocusMode") private var defaultFocusMode: Bool = false
    // Persisted so the app can restore fullscreen state on next launch.
    @AppStorage("wasFullScreen") private var wasFullScreen: Bool = false

    @State private var isShowingSettings: Bool = false
    @State private var isShowingProjectPicker: Bool = false
    @State private var hoverSelectProject: Bool = false

    // Navigator state hoisted here so it survives focus mode (which destroys SidebarView).
    @State private var navigatorExpandedFolderIDs: Set<UUID> = []
    @State private var navigatorSelectedFolderID: UUID?

    // Returns nil when following system appearance so SwiftUI leaves the color scheme unforced.
    private var resolvedColorScheme: ColorScheme? {
        guard !followSystemAppearance else { return nil }
        return appColors.isDark ? .dark : .light
    }

    var body: some View {
        HStack(spacing: 0) {
            if !isFocusMode {
                SidebarView(
                    isSidebarOpen: $isSidebarOpen,
                    activePanel: $activePanel,
                    selectedProjectID: $selectedProjectID,
                    activeBlobID: $activeBlobID,
                    navigatorExpandedFolderIDs: $navigatorExpandedFolderIDs,
                    navigatorSelectedFolderID: $navigatorSelectedFolderID
                )
            }

            ZStack {
                AppColors.shared.surface
                    .ignoresSafeArea()

                if let projectID = selectedProjectID {
                    if let blobID = activeBlobID {
                        AppColors.shared.surface
                            .ignoresSafeArea()

                        EditView(
                            blobID: blobID,
                            projectID: projectID,
                            isFocusMode: $isFocusMode,
                            isFullScreen: isFullScreen,
                            onClose: {
                                activeBlobID = nil
                                isFocusMode = false
                            }
                        )
                        .id(blobID)
                        .opacity(editorOpacity)
                    } else {
                        Text("Open a document")
                            .font(.system(size: 16))
                            .foregroundColor(AppColors.shared.textMuted)
                    }
                } else {
                    Button {
                        NotificationCenter.default.post(name: .showProjectPicker, object: nil)
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
        }
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
        .sheet(isPresented: $isShowingProjectPicker) {
            ProjectPickerPanel(selectedProjectID: $selectedProjectID) {
                isShowingProjectPicker = false
                activeBlobID = nil
            }
            .environmentObject(store)
            .environmentObject(AppColors.shared)
        }
        .onAppear {
            if followSystemAppearance {
                appColors.applySystemAppearance(dark: systemColorScheme == .dark)
            }
            if let pid = UUID(uuidString: lastProjectIDString),
               store.projects.contains(where: { $0.id == pid }) {
                selectedProjectID = pid
            }
            if wasFullScreen {
                DispatchQueue.main.async {
                    NSApp.mainWindow?.toggleFullScreen(nil)
                }
            }
        }
        .onChange(of: selectedProjectID) { newID in
            lastProjectIDString = newID?.uuidString ?? ""
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
        .onChange(of: isSidebarOpen) { _ in
            guard activeBlobID != nil else { return }
            editorOpacity = 0
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.07) {
                withAnimation(.easeIn(duration: 0.3)) { editorOpacity = 1 }
            }
        }
        .onChange(of: activeBlobID) { newID in
            let fullScreen = NSApp.mainWindow?.styleMask.contains(.fullScreen) ?? false
            isFocusMode = newID != nil && defaultFocusMode && fullScreen
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleFocusMode)) { _ in
            guard activeBlobID != nil else { return }
            isFocusMode.toggle()
        }
        .onChange(of: isFocusMode) { newValue in
            guard activeBlobID != nil else { return }
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
            isShowingProjectPicker = true
        }
    }

}

#Preview {
    ContentView()
        .environmentObject(ProjectStore())
        .environmentObject(AppColors.shared)
}
