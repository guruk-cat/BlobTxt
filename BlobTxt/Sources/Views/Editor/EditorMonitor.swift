import SwiftUI
import Combine
import AppKit

enum SaveStatus: Equatable {
    case idle, saving, saved
}

// The owner's handle on the mounted editor's save. `url` tags which document it belongs to so the
// editor can clear the slot on disappear without clobbering the next editor's handler (the new
// editor's onAppear can run before the old one's onDisappear).
struct EditorFlush {
    let url: URL
    let save: (@escaping () -> Void) -> Void
}

struct EditorMonitor: View {
    @EnvironmentObject var store: ProjectStore
    @EnvironmentObject var appColors: AppColors

    let url: URL
    let onClose: () -> Void

    // Following a local link to a different blob: switches the active document.
    let onOpenDocument: (URL) -> Void

    // Lets the owner flush this document to disk before swapping to another file. While this editor
    // is on screen it registers its save here; it clears the slot on disappear only if the slot is
    // still its own. nil means no editor is mounted.
    @Binding var flushHandler: EditorFlush?

    @StateObject private var bridge = EditorBridge()
    @State private var saveStatus: SaveStatus = .idle
    @State private var hasLoaded = false
    @State private var contentOpacity: Double = 0
    @State private var escMonitor: Any?

    @AppStorage("fontSize")              private var fontSize:             Double = 16.0
    @AppStorage("fontFamily")            private var fontFamily:           String = "Menlo"
    @AppStorage("autoScroll")            private var autoScrollMode:       String = "regular"

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
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                let savedScroll = store.blobScrollPositions[url] ?? 0
                bridge.load(content: markdown, scrollTop: savedScroll, config: buildConfig())
                withAnimation(.easeIn(duration: 0.1)) { contentOpacity = 1 }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .saveDocument)) { _ in
            performSave(completion: nil)
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleSearch)) { _ in
            bridge.toggleSearch()
        }
        .onReceive(NotificationCenter.default.publisher(for: .arrangeFootnotes)) { _ in
            bridge.arrangeFootnotes()
        }
        .onReceive(
            bridge.$isDirty
                .filter { $0 }
                .debounce(for: .seconds(5), scheduler: RunLoop.main)
        ) { _ in
            performSave(completion: nil)
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
        .onAppear {
            bridge.onClose = { saveAndClose() }
            bridge.documentURL = url
            // Expose this document's save to the owner so a pending file switch can flush it first.
            flushHandler = EditorFlush(url: url) { completion in performSave(completion: completion) }
            // A link into the current file scrolls in place; any other target
            // switches documents (handled up in ContentView).
            bridge.onOpenLocal = { target, fragment in
                if target == url {
                    if let fragment = fragment { bridge.scrollToHeading(fragment) }
                } else {
                    // The opened blob restores its own saved scroll position, so a
                    // cross-file "#heading" anchor is not honored (known limitation).
                    onOpenDocument(target)
                }
            }
            escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                // Skip if a sheet (link dialog, settings, etc.) is in front.
                guard NSApp.mainWindow?.isKeyWindow == true else { return event }
                if event.keyCode == 53 { // Escape
                    if bridge.isSearchOpen {
                        bridge.closeSearch()
                    } else {
                        saveAndClose()
                    }
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
            // Clear only if the next editor hasn't already claimed the slot (onAppear/onDisappear
            // order is not guaranteed across an .id swap).
            if flushHandler?.url == url { flushHandler = nil }
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
                            ? AppColors.shared.textResting
                            : AppColors.shared.metaConfirmation
                    )
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(AppColors.shared.surfaceSunken.opacity(0.95))
            .cornerRadius(8)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppColors.shared.border, lineWidth: 1))
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
        return [
            "fontSize":       fontSize,
            "fontFamily":     fontFamily,
            "autoscroll":     autoScrollMode,
            "colors":         AppColors.shared.colorConfigDict(),
        ]
    }
}


#Preview {
    ZStack {
        AppColors.shared.surface.ignoresSafeArea()
        EditorMonitor(
            url: URL(fileURLWithPath: "/tmp/preview.md"),
            onClose: {},
            onOpenDocument: { _ in },
            flushHandler: .constant(nil)
        )
        .environmentObject(ProjectStore())
        .environmentObject(AppColors.shared)
    }
}

