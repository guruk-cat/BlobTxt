import SwiftUI
import AppKit

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
    @AppStorage("wasFullScreen") private var wasFullScreen: Bool = false

    @State private var isShowingSettings: Bool = false
    @State private var hoverSelectProject: Bool = false

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
                    activeEditorURL: $activeEditorURL
                )
            }
            ZStack {
                AppColors.shared.surface
                    .ignoresSafeArea()

                if store.currentProject != nil {
                    if let url = activeEditorURL {
                        AppColors.shared.surface
                            .ignoresSafeArea()

                        EditView(
                            url: url,
                            isFocusMode: $isFocusMode,
                            isFullScreen: isFullScreen,
                            onClose: {
                                activeEditorURL = nil
                                isFocusMode = false
                            }
                        )
                        .id(url)
                        .opacity(editorOpacity)
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
        .onAppear {
            if followSystemAppearance {
                appColors.applySystemAppearance(dark: systemColorScheme == .dark)
            }
            if wasFullScreen {
                DispatchQueue.main.async { NSApp.mainWindow?.toggleFullScreen(nil) }
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
            if isOn { appColors.applySystemAppearance(dark: systemColorScheme == .dark) }
            else { appColors.reloadManualPalette() }
        }
        .onChange(of: isSidebarOpen) { _ in
            guard activeEditorURL != nil else { return }
            editorOpacity = 0
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.07) {
                withAnimation(.easeIn(duration: 0.3)) { editorOpacity = 1 }
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
            isFullScreen = true; wasFullScreen = true
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
        .onReceive(NotificationCenter.default.publisher(for: .showPreferences)) { _ in isShowingSettings = true }
        .onReceive(NotificationCenter.default.publisher(for: .showProjectPicker)) { _ in isShowingProjectPicker = true }
    }
}

#Preview {
    ContentView()
        .environmentObject(ProjectStore())
        .environmentObject(AppColors.shared)
}
