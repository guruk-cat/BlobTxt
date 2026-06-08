import SwiftUI
import Combine
import AppKit

enum SaveStatus: Equatable {
    case idle, saving, saved
}

struct EditView: View {
    @EnvironmentObject var store: ProjectStore
    @EnvironmentObject var appColors: AppColors

    let blobURL: URL
    @Binding var isFocusMode: Bool
    let isFullScreen: Bool
    let onClose: () -> Void

    @StateObject private var bridge = EditorBridge()
    @State private var saveStatus: SaveStatus = .idle
    @State private var hasLoaded = false
    @State private var contentOpacity: Double = 0
    @State private var escMonitor: Any?
    @AppStorage("fontSize") private var fontSize: Double = 16.0
    @AppStorage("fontFamily") private var fontFamily: String = "Menlo"
    @AppStorage("defaultFocusMode") private var defaultFocusMode: Bool = false

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            AppColors.shared.surface.ignoresSafeArea()
            WebEditorView(bridge: bridge)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .opacity(contentOpacity)
            saveIsland
            Button("") { store.printBlob(at: blobURL) }
                .keyboardShortcut("p", modifiers: .command)
                .frame(width: 0, height: 0).hidden()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onReceive(bridge.$isReady.filter { $0 }) { _ in
            guard !hasLoaded else { return }
            hasLoaded = true
            let markdown = store.loadBlobContent(at: blobURL) ?? ""
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                let savedScroll = store.blobScrollPositions[blobURL] ?? 0
                if savedScroll > 0 {
                    bridge.setContentAndScrollTo(markdown, scrollTop: savedScroll)
                } else {
                    bridge.setContentAndScrollToTop(markdown)
                }
                bridge.markClean()
                bridge.setFocusMode(isFocusMode)
                bridge.applyFocusModeCustomizations(enabled: isFocusMode && isFullScreen) {
                    withAnimation(.easeIn(duration: 0.3)) { contentOpacity = 1 }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .saveDocument)) { _ in
            performSave(completion: nil)
        }
        .onReceive(NotificationCenter.default.publisher(for: .scrollToOutlineHeading)) { notif in
            if let index = notif.object as? Int { bridge.scrollToHeading(index: index) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .searchAndHighlight)) { notif in
            if let query = notif.object as? String { bridge.searchAndHighlight(query: query) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .scrollToSearchResult)) { notif in
            if let index = notif.object as? Int { bridge.scrollToSearchResult(index: index) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .clearSearchHighlights)) { _ in
            bridge.clearSearchHighlights()
        }
        .onReceive(NotificationCenter.default.publisher(for: .reloadEditorContent)) { notif in
            guard let targetURL = notif.object as? URL, targetURL == blobURL else { return }
            let markdown = store.loadBlobContent(at: blobURL) ?? ""
            bridge.setContent(markdown)
        }
        .onReceive(bridge.$isDirty.filter { $0 }.debounce(for: .seconds(5), scheduler: RunLoop.main)) { _ in
            performSave(completion: nil)
        }
        .onChange(of: isFocusMode) { newValue in
            bridge.setFocusMode(newValue)
            bridge.applyFocusModeCustomizations(enabled: newValue && isFullScreen)
        }
        .onChange(of: isFullScreen) { newValue in
            bridge.applyFocusModeCustomizations(enabled: isFocusMode && newValue)
        }
        .onReceive(NotificationCenter.default.publisher(for: .focusCustomizationChanged)) { _ in
            guard isFocusMode && isFullScreen else { return }
            bridge.applyFocusModeCustomizations(enabled: true)
        }
        .onChange(of: appColors.surface) { _ in bridge.applyColors() }
        .onChange(of: fontSize) { bridge.setFontSize($0) }
        .onChange(of: fontFamily) { bridge.setFontFamily($0) }
        .sheet(isPresented: $bridge.showLinkDialog) { LinkDialogView(bridge: bridge) }
        .onAppear {
            store.activeEditorBlobURL = blobURL
            bridge.onClose = { saveAndClose() }
            escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                guard NSApp.mainWindow?.isKeyWindow == true else { return event }
                if event.keyCode == 53 {
                    if isFocusMode && !defaultFocusMode { isFocusMode = false } else { saveAndClose() }
                    return nil
                }
                if event.keyCode == 46 && event.modifierFlags.contains(.command) { isFocusMode.toggle(); return nil }
                if event.keyCode == 0 && event.modifierFlags.contains(.command) { bridge.selectAll(); return nil }
                return event
            }
        }
        .onDisappear {
            store.blobScrollPositions[blobURL] = bridge.lastScrollPosition
            store.activeEditorBlobURL = nil
            if let monitor = escMonitor { NSEvent.removeMonitor(monitor); escMonitor = nil }
        }
    }

    @ViewBuilder
    private var saveIsland: some View {
        if saveStatus != .idle {
            HStack(spacing: 5) {
                if saveStatus == .saving {
                    ProgressView().scaleEffect(0.55).frame(width: 12, height: 12)
                } else {
                    Image(systemName: "checkmark").font(.system(size: 9, weight: .semibold))
                        .foregroundColor(AppColors.shared.metaConfirmation)
                }
                Text(saveStatus == .saving ? "Saving..." : "Saved!")
                    .font(.system(size: 11))
                    .foregroundColor(saveStatus == .saving ? AppColors.shared.textHeading : AppColors.shared.metaConfirmation)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(AppColors.shared.surface.opacity(0.95)).cornerRadius(8)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppColors.shared.borderCard, lineWidth: 1))
            .padding(14)
            .transition(.opacity.combined(with: .scale(scale: 0.92, anchor: .bottomTrailing)))
        }
    }

    private func performSave(completion: (() -> Void)?) {
        guard bridge.isDirty else { completion?(); return }
        withAnimation(.easeInOut(duration: 0.15)) { saveStatus = .saving }
        bridge.getContent { markdown in
            guard let markdown else { completion?(); return }
            store.saveBlobContent(markdown, at: blobURL)
            withAnimation(.easeInOut(duration: 0.15)) { saveStatus = .saved }
            bridge.markClean()
            completion?()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                withAnimation(.easeOut(duration: 0.3)) { saveStatus = .idle }
            }
        }
    }

    private func saveAndClose() { performSave { onClose() } }
}

#Preview {
    ZStack {
        AppColors.shared.surfaceSunken.ignoresSafeArea()
        EditView(blobURL: URL(fileURLWithPath: "/tmp/preview.md"), isFocusMode: .constant(false), isFullScreen: false, onClose: {})
            .environmentObject(ProjectStore())
            .environmentObject(AppColors.shared)
    }
}
