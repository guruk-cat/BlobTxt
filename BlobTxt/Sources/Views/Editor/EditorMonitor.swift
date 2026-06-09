import SwiftUI
import Combine
import AppKit

enum SaveStatus: Equatable {
    case idle, saving, saved
}

struct EditorMonitor: View {
    @EnvironmentObject var store: ProjectStore
    @EnvironmentObject var appColors: AppColors

    let url: URL
    @Binding var isFocusMode: Bool
    let isFullScreen: Bool
    let onClose: () -> Void

    @StateObject private var bridge = EditorBridge()
    @State private var saveStatus: SaveStatus = .idle
    @State private var hasLoaded = false
    @State private var contentOpacity: Double = 0
    @State private var escMonitor: Any?

    @AppStorage("fontSize")              private var fontSize:             Double = 16.0
    @AppStorage("fontFamily")            private var fontFamily:           String = "Menlo"
    @AppStorage("autoScroll")            private var autoScrollMode:       String = "regular"
    @AppStorage("imageLimitHalfWidth")   private var imageLimitHalfWidth:  Bool   = false
    @AppStorage("defaultFocusMode")      private var defaultFocusMode:     Bool   = false

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            AppColors.shared.surface
                .ignoresSafeArea()

            WebViewAdapter(bridge: bridge)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .opacity(contentOpacity)

            saveIsland
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onReceive(bridge.$isReady.filter { $0 }) { _ in
            guard !hasLoaded else { return }
            hasLoaded = true
            let raw      = store.loadBlobContent(url: url)
            let markdown = raw.flatMap { $0.isEmpty ? nil : $0 } ?? ""
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                let savedScroll = store.blobScrollPositions[url] ?? 0
                bridge.load(content: markdown, scrollTop: savedScroll, config: buildConfig())
                bridge.applyFocusModeCustomizations(enabled: isFocusMode && isFullScreen) {
                    withAnimation(.easeIn(duration: 0.3)) { contentOpacity = 1 }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .saveDocument)) { _ in
            performSave(completion: nil)
        }
        .onReceive(
            bridge.$isDirty
                .filter { $0 }
                .debounce(for: .seconds(5), scheduler: RunLoop.main)
        ) { _ in
            performSave(completion: nil)
        }
        .onChange(of: isFocusMode) { newValue in
            bridge.updateConfig(["focusMode": newValue])
            bridge.applyFocusModeCustomizations(enabled: newValue && isFullScreen)
        }
        .onChange(of: isFullScreen) { newValue in
            bridge.applyFocusModeCustomizations(enabled: isFocusMode && newValue)
        }
        .onReceive(NotificationCenter.default.publisher(for: .focusCustomizationChanged)) { _ in
            guard isFocusMode && isFullScreen else { return }
            bridge.applyFocusModeCustomizations(enabled: true)
        }
        .onChange(of: appColors.surface) { _ in
            bridge.updateConfig(["colors": AppColors.shared.colorConfigDict()])
        }
        .onChange(of: fontSize) { newSize in
            bridge.updateConfig(["fontSize": newSize])
        }
        .onChange(of: fontFamily) { newFamily in
            bridge.updateConfig(["fontFamily": newFamily])
        }
        .onChange(of: autoScrollMode) { newMode in
            bridge.updateConfig(["autoscroll": newMode])
        }
        .onChange(of: imageLimitHalfWidth) { newValue in
            bridge.updateConfig(["imageHalfWidth": newValue])
        }
        .onAppear {
            bridge.onClose = { saveAndClose() }
            escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                // Skip if a sheet (link dialog, settings, etc.) is in front.
                guard NSApp.mainWindow?.isKeyWindow == true else { return event }
                if event.keyCode == 53 { // Escape
                    if isFocusMode && !defaultFocusMode {
                        isFocusMode = false
                    } else {
                        saveAndClose()
                    }
                    return nil
                }
                if event.keyCode == 46 && event.modifierFlags.contains(.command) { // Cmd+M
                    isFocusMode.toggle()
                    return nil
                }
                if event.keyCode == 0 && event.modifierFlags.contains(.command) { // Cmd+A
                    bridge.selectAll()
                    return nil
                }
                return event
            }
        }
        .onDisappear {
            store.blobScrollPositions[url] = bridge.lastScrollPosition
            if let monitor = escMonitor {
                NSEvent.removeMonitor(monitor)
                escMonitor = nil
            }
        }
    }

    // MARK: - Save status island

    @ViewBuilder
    private var saveIsland: some View {
        if saveStatus != .idle {
            HStack(spacing: 5) {
                if saveStatus == .saving {
                    ProgressView()
                        .scaleEffect(0.55)
                        .frame(width: 12, height: 12)
                } else {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(AppColors.shared.metaConfirmation)
                }
                Text(saveStatus == .saving ? "Saving..." : "Saved!")
                    .font(.system(size: 11))
                    .foregroundColor(
                        saveStatus == .saving
                            ? AppColors.shared.textHeading
                            : AppColors.shared.metaConfirmation
                    )
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(AppColors.shared.surface.opacity(0.95))
            .cornerRadius(8)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppColors.shared.borderCard, lineWidth: 1))
            .padding(14)
            .transition(.opacity.combined(with: .scale(scale: 0.92, anchor: .bottomTrailing)))
        }
    }

    // MARK: - Save logic

    private func performSave(completion: (() -> Void)?) {
        guard bridge.isDirty else { completion?(); return }
        withAnimation(.easeInOut(duration: 0.15)) { saveStatus = .saving }
        bridge.getContent { json in
            guard let json = json else { completion?(); return }
            store.saveBlobContent(json, url: url)
            withAnimation(.easeInOut(duration: 0.15)) { saveStatus = .saved }
            self.bridge.isDirty = false
            completion?()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                withAnimation(.easeOut(duration: 0.3)) { saveStatus = .idle }
            }
        }
    }

    private func saveAndClose() {
        performSave { onClose() }
    }

    // MARK: - Config assembly

    // Assembles the full config dictionary for the initial load() call.
    private func buildConfig() -> [String: Any] {
        let floating = UserDefaults.standard.bool(forKey: "focusFloating")
        let dimness  = UserDefaults.standard.double(forKey: "focusDimness")
        let blur     = UserDefaults.standard.double(forKey: "focusBlur")
        return [
            "fontSize":       fontSize,
            "fontFamily":     fontFamily,
            "imageHalfWidth": imageLimitHalfWidth,
            "autoscroll":     autoScrollMode,
            "focusMode":      isFocusMode,
            "focusCustom":    isFocusMode && isFullScreen,
            "floating":       floating,
            "focusDimness":   dimness,
            "focusBlur":      blur,
            "colors":         AppColors.shared.colorConfigDict(),
        ]
    }
}


#Preview {
    ZStack {
        AppColors.shared.surfaceSunken.ignoresSafeArea()
        EditorMonitor(
            url: URL(fileURLWithPath: "/tmp/preview.md"),
            isFocusMode: .constant(false),
            isFullScreen: false,
            onClose: {}
        )
        .environmentObject(ProjectStore())
        .environmentObject(AppColors.shared)
    }
}

