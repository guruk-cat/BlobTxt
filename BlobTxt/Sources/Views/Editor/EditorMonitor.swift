import SwiftUI
import Combine
import AppKit

enum SaveStatus: Equatable {
    case idle, saving, saved
}

// The owner's handle on the mounted editor's save.
// `url` tags which document it belongs to so the editor can clear the slot on disappear without clobbering the next editor's handler (the new editor's onAppear can run before the old one's onDisappear).
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

    // Lets the owner flush this document to disk before swapping to another file. While this editor is on screen it registers its save here; it clears the slot on disappear only if the slot is still its own. nil means no editor is mounted.
    @Binding var flushHandler: EditorFlush?

    // True while a file-ops overlay (Merge Blobs, Page Layout) floats above the editor.
    // The Escape / Cmd+A monitor yields to the overlay's own key handling rather than acting on the editor behind it.
    let isModalOverlayActive: () -> Bool

    // When false, Escape only dismisses the search panel and never closes the editor (used by the mini view).
    let closesOnEscape: Bool
    // The mini view reads/writes its own font size and never touches the shared front-matter slot.
    let isMini: Bool

    @StateObject private var bridge = EditorBridge()
    // The in-memory owner of this blob, acquired from LifecycleStore on mount and released on unmount.
    @State private var blobContent: BlobContent?
    // The owner's revision this editor's text last matched. When the other surface saves the same blob, the owner moves ahead of this; on regaining key focus the editor reloads to catch up (safe-not-live reconciliation).
    @State private var loadedRevision = 0
    @State private var saveStatus: SaveStatus = .idle
    @State private var hasLoaded = false
    @State private var contentOpacity: Double = 0
    @State private var escMonitor: Any?

    @AppStorage("fontSize")              private var mainFontSize:         Double = 16.0
    @AppStorage("miniFontSize")          private var miniFontSize:         Double = 14.0
    @AppStorage("fontFamily")            private var fontFamily:           String = "Menlo"
    @AppStorage("autoScroll")            private var autoScrollMode:       String = "regular"

    // The font size that applies to this editor, drawn from the right persisted key.
    private var fontSize: Double { isMini ? miniFontSize : mainFontSize }

    // True when this editor's own window holds focus, so app-wide shortcuts act only on the focused window.
    private var isKeyWindow: Bool { bridge.webView?.window?.isKeyWindow == true }

    init(
        url: URL,
        onClose: @escaping () -> Void,
        onOpenDocument: @escaping (URL) -> Void,
        flushHandler: Binding<EditorFlush?>,
        isModalOverlayActive: @escaping () -> Bool,
        closesOnEscape: Bool = true,
        isMini: Bool = false
    ) {
        self.url = url
        self.onClose = onClose
        self.onOpenDocument = onOpenDocument
        self._flushHandler = flushHandler
        self.isModalOverlayActive = isModalOverlayActive
        self.closesOnEscape = closesOnEscape
        self.isMini = isMini
    }

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
            let markdown = blobContent?.body ?? ""
            loadedRevision = blobContent?.revision ?? 0
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                let savedScroll = LifecycleStore.shared.scrollPosition(for: url)
                bridge.load(content: markdown, scrollTop: savedScroll, config: buildConfig())
                withAnimation(.easeIn(duration: 0.1)) { contentOpacity = 1 }
            }
        }
        // The other surface saved this blob: catch up to the shared content. Save-driven rather than focus-driven so the pull happens after the writer's async save has actually landed.
        .onReceive(NotificationCenter.default.publisher(for: .blobContentDidSave)) { notif in
            guard let saved = notif.object as? URL,
                  saved.resolvingSymlinksInPath().path == url.resolvingSymlinksInPath().path else { return }
            reconcileFromDocument()
        }
        // Resigning key: commit our edits to the shared document so a same-blob surface catches up even when the switch beats the debounce.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { notif in
            guard isThisWindow(notif.object) else { return }
            performSave(completion: nil)
        }
        .onReceive(NotificationCenter.default.publisher(for: .saveDocument)) { _ in
            performSave(completion: nil)
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleSearch)) { _ in
            guard isKeyWindow else { return }
            bridge.toggleSearch()
        }
        .onReceive(NotificationCenter.default.publisher(for: .arrangeFootnotes)) { _ in
            guard isKeyWindow else { return }
            bridge.arrangeFootnotes()
        }
        .onReceive(NotificationCenter.default.publisher(for: .increaseFontSize)) { _ in
            guard isKeyWindow else { return }
            if isMini { if miniFontSize < 36 { miniFontSize += 1 } }
            else if mainFontSize < 36 { mainFontSize += 1 }
        }
        .onReceive(NotificationCenter.default.publisher(for: .decreaseFontSize)) { _ in
            guard isKeyWindow else { return }
            if isMini { if miniFontSize > 10 { miniFontSize -= 1 } }
            else if mainFontSize > 10 { mainFontSize -= 1 }
        }
        .onReceive(
            bridge.$isDirty
                .filter { $0 }
                .debounce(for: .seconds(5), scheduler: RunLoop.main)
        ) { _ in
            performSave(completion: nil)
        }
        .onChange(of: appColors.paletteRevision) { _ in
            bridge.updateConfig(["colors": AppColors.shared.colorConfigDict()])
        }
        .onChange(of: isMini ? miniFontSize : mainFontSize) { newSize in
            bridge.updateConfig(["fontSize": newSize])
        }
        .onChange(of: fontFamily) { newFamily in
            bridge.updateConfig(["fontFamily": newFamily])
        }
        .onChange(of: autoScrollMode) { newMode in
            bridge.updateConfig(["autoscroll": newMode])
        }
        .onAppear {
            // Acquire the shared in-memory owner; the main editor also points the Metadata panel at it. The mini view leaves activeContent alone so the panel always tracks the main window.
            let content = LifecycleStore.shared.acquire(url)
            blobContent = content
            if !isMini { store.activeContent = content }

            bridge.onClose = { saveAndClose() }
            bridge.documentURL = url
            // Expose this document's save to the owner so a pending file switch can flush it first.
            flushHandler = EditorFlush(url: url) { completion in performSave(completion: completion) }
            // A link into the current file scrolls in place; any other target switches documents (handled up in ContentView).
            bridge.onOpenLocal = { target, fragment in
                if target == url {
                    if let fragment = fragment { bridge.scrollToHeading(fragment) }
                } else {
                    // The opened blob restores its own saved scroll position, so a cross-file "#heading" anchor is not honored (known limitation).
                    onOpenDocument(target)
                }
            }
            escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                // Act only when this editor's own window is key (so the two editors don't both handle one keystroke, and sheets in front are skipped).
                guard isKeyWindow else { return event }
                // Yield to a floating file-ops overlay's own Escape handling.
                guard !isModalOverlayActive() else { return event }
                if event.keyCode == 53 { // Escape
                    if bridge.isSearchOpen {
                        bridge.closeSearch()
                    } else if closesOnEscape {
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
            // Clear only if the next editor hasn't already claimed the slot (onAppear/onDisappear order is not guaranteed across an .id swap).
            if flushHandler?.url == url { flushHandler = nil }
            // Release the panel binding only if it still points at this editor's document (mount of the next blob may have already repointed it).
            if !isMini, store.activeContent === blobContent { store.activeContent = nil }
            LifecycleStore.shared.setScrollPosition(bridge.lastScrollPosition, for: url)
            LifecycleStore.shared.release(url)
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
            // Commit the editor's text to the owner and let it write — the single save path for this blob.
            blobContent?.updateBody(json)
            blobContent?.save()
            // Our text now matches the owner, so we are not behind our own write.
            loadedRevision = blobContent?.revision ?? loadedRevision
            // Let any other surface on this blob reconcile to what was just written.
            NotificationCenter.default.post(name: .blobContentDidSave, object: url)
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

    // MARK: - Focus reconciliation

    // True when `object` is this editor's own window, so the key-window notifications act only on this surface.
    private func isThisWindow(_ object: Any?) -> Bool {
        guard let window = object as? NSWindow else { return false }
        return window === bridge.webView?.window
    }

    // Reloads the editor from the shared document when the other surface has advanced it past what we last loaded. Local uncommitted edits take precedence: if this editor is dirty we keep them and let the next save win.
    private func reconcileFromDocument() {
        guard let content = blobContent, !bridge.isDirty else { return }
        guard content.revision != loadedRevision else { return }
        bridge.load(content: content.body, scrollTop: bridge.lastScrollPosition, config: buildConfig())
        loadedRevision = content.revision
    }

    // MARK: - Config assembly
    // Assembles the full config dictionary for the initial load() call.
    private func buildConfig() -> [String: Any] {
        return [
            "fontSize":       fontSize,
            "fontFamily":     fontFamily,
            "autoscroll":     autoScrollMode,
            "colors":         AppColors.shared.colorConfigDict(),
            "mini":           isMini,
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
            flushHandler: .constant(nil),
            isModalOverlayActive: { false }
        )
        .environmentObject(ProjectStore())
        .environmentObject(AppColors.shared)
    }
}

