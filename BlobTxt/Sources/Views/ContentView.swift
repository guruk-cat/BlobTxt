import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject var store: ProjectStore
    @EnvironmentObject var appColors: AppColors
    @State var activeBlobURL: URL?
    @State var isSidebarOpen: Bool = true
    @State var activePanel: SidebarPanel = .navigator

    @AppStorage("followSystemAppearance") private var followSystemAppearance: Bool = false
    @Environment(\.colorScheme) private var systemColorScheme
    @State private var editorOpacity: Double = 1.0
    @State private var isFocusMode: Bool = false
    @State private var isFullScreen: Bool = false
    @AppStorage("defaultFocusMode") private var defaultFocusMode: Bool = false
    @AppStorage("wasFullScreen") private var wasFullScreen: Bool = false

    @State private var isShowingSettings: Bool = false
    @State private var isShowingProjectPicker: Bool = false
    @State private var hoverSelectProject: Bool = false

    // Navigator state hoisted here so it survives focus mode (which destroys SidebarView).
    @State private var navigatorExpandedFolderURLs: Set<URL> = []
    @State private var navigatorSelectedFolderURL: URL?

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
                    activeBlobURL: $activeBlobURL,
                    navigatorExpandedFolderURLs: $navigatorExpandedFolderURLs,
                    navigatorSelectedFolderURL: $navigatorSelectedFolderURL
                )
            }
            ZStack {
                AppColors.shared.surface.ignoresSafeArea()
                if store.currentProject != nil {
                    if let blobURL = activeBlobURL {
                        AppColors.shared.surface.ignoresSafeArea()
                        EditView(
                            blobURL: blobURL,
                            isFocusMode: $isFocusMode,
                            isFullScreen: isFullScreen,
                            onClose: { activeBlobURL = nil; isFocusMode = false }
                        )
                        .id(blobURL)
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
                            .padding(.horizontal, 16).padding(.vertical, 10)
                            .background(RoundedRectangle(cornerRadius: 8).fill(
                                hoverSelectProject ? AppColors.shared.metaIndication : AppColors.shared.surface))
                    }
                    .buttonStyle(.plain).onHover { hoverSelectProject = $0 }
                }
            }
        }
        .overlay(alignment: .bottomLeading) {
            if !isFocusMode {
                FloatingIslandView(isSidebarOpen: $isSidebarOpen, activePanel: $activePanel)
                    .padding(.leading, 8).padding(.bottom, 8)
            }
        }
        .frame(minWidth: 700, minHeight: 480)
        .background(AppColors.shared.surface)
        .toolbarBackground(appColors.chromeToolbar, for: .windowToolbar)
        .toolbarBackground(.visible, for: .windowToolbar)
        .preferredColorScheme(resolvedColorScheme)
        .sheet(isPresented: $isShowingSettings) {
            SettingsView().environmentObject(AppColors.shared)
        }
        .sheet(isPresented: $isShowingProjectPicker) {
            ProjectPickerPanel(onDismiss: {
                isShowingProjectPicker = false
                activeBlobURL = nil
            })
            .environmentObject(store)
            .environmentObject(AppColors.shared)
        }
        .onAppear {
            if followSystemAppearance { appColors.applySystemAppearance(dark: systemColorScheme == .dark) }
            if wasFullScreen {
                DispatchQueue.main.async { NSApp.mainWindow?.toggleFullScreen(nil) }
            }
        }
        .onChange(of: systemColorScheme) { scheme in
            guard followSystemAppearance else { return }
            appColors.applySystemAppearance(dark: scheme == .dark)
        }
        .onChange(of: followSystemAppearance) { isOn in
            if isOn { appColors.applySystemAppearance(dark: systemColorScheme == .dark) }
            else { appColors.reloadManualPalette() }
        }
        .onChange(of: isSidebarOpen) { _ in
            guard activeBlobURL != nil else { return }
            editorOpacity = 0
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.07) {
                withAnimation(.easeIn(duration: 0.3)) { editorOpacity = 1 }
            }
        }
        .onChange(of: activeBlobURL) { newURL in
            let fullScreen = NSApp.mainWindow?.styleMask.contains(.fullScreen) ?? false
            isFocusMode = newURL != nil && defaultFocusMode && fullScreen
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleFocusMode)) { _ in
            guard activeBlobURL != nil else { return }
            isFocusMode.toggle()
        }
        .onChange(of: isFocusMode) { _ in
            guard activeBlobURL != nil else { return }
            editorOpacity = 0
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                withAnimation(.easeIn(duration: 0.3)) { editorOpacity = 1 }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { notif in
            guard (notif.object as? NSWindow) === NSApp.mainWindow else { return }
            isFullScreen = true; wasFullScreen = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { notif in
            guard (notif.object as? NSWindow) === NSApp.mainWindow else { return }
            isFullScreen = false; wasFullScreen = false; isFocusMode = false
        }
        .onReceive(NotificationCenter.default.publisher(for: .showPreferences)) { _ in isShowingSettings = true }
        .onReceive(NotificationCenter.default.publisher(for: .showProjectPicker)) { _ in isShowingProjectPicker = true }
    }
}

#Preview {
    ContentView()
        .environmentObject(ProjectStore())
        .environmentObject(AppColors.shared)
}
