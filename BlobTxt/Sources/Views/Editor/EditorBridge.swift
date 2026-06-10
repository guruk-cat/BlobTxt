import Foundation
import WebKit
import AppKit
import Combine
import UniformTypeIdentifiers

class EditorBridge: NSObject, ObservableObject, WKScriptMessageHandler {
    weak var webView: WKWebView?

    @Published var isReady = false
    @Published var isDirty = false
    @Published var isSearchOpen = false

    var lastScrollPosition: Int = 0

    // Called when the editor requests a close (e.g., a toolbar close button).
    var onClose: (() -> Void)?

    // MARK: - JS → Swift (WKScriptMessageHandler)

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard let body = message.body as? [String: Any],
              let type = body["type"] as? String else { return }

        DispatchQueue.main.async {
            switch type {
            case "editorReady":
                self.isReady = true

            case "documentChanged":
                self.isDirty = true

            case "scrollPositionChanged":
                if let top = body["scrollTop"] as? Int {
                    self.lastScrollPosition = top
                }

            case "openURL":
                if let urlStr = body["url"] as? String, let url = URL(string: urlStr) {
                    NSWorkspace.shared.open(url)
                }

            case "searchPanelOpened":
                self.isSearchOpen = true

            case "searchPanelClosed":
                self.isSearchOpen = false

            default:
                break
            }
        }
    }

    // MARK: - Swift → JS

    /*
      Called once after editorReady. Serializes the full document + config into a
      single JSON payload and calls window.editorBridge.load() in the JS layer.
      This replaces the old sequence of setContent, setFocusMode, setFontSize, etc.
    */
    func load(content: String, scrollTop: Int, config: [String: Any]) {
        let payload: [String: Any] = [
            "content":   content,
            "scrollTop": scrollTop,
            "config":    config,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return }
        evaluate("window.editorBridge.load(\(json))")
    }

    /*
      Called whenever a setting changes. The patch is a sparse dictionary containing
      only the keys that changed. The JS layer inspects the keys and applies only
      what it receives — compartment reconfiguration and/or DOM/CSS updates.
    */
    func updateConfig(_ patch: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: patch),
              let json = String(data: data, encoding: .utf8) else { return }
        evaluate("window.editorBridge.updateConfig(\(json))")
    }

    func toggleSearch() {
        evaluate("window.editorBridge.toggleSearch()")
    }

    func closeSearch() {
        evaluate("window.editorBridge.closeSearch()")
    }

    func arrangeFootnotes() {
        evaluate("window.editorBridge.arrangeFootnotes()")
    }

    func getContent(completion: @escaping (String?) -> Void) {
        webView?.evaluateJavaScript("window.editorBridge.getContent()") { result, _ in
            completion(result as? String)
        }
    }

    func selectAll() {
        DispatchQueue.main.async {
            self.webView?.selectAll(nil)
        }
    }

    // MARK: - Focus mode wallpaper

    func setFocusWallpaper(dataURL: String?) {
        webView?.callAsyncJavaScript(
            "window.editorBridge.setFocusWallpaper(src)",
            arguments: ["src": dataURL ?? NSNull()],
            in: nil,
            in: .page,
            completionHandler: nil
        )
    }

    /*
      Reads focus customization prefs from UserDefaults and sends them to JS via
      updateConfig. When enabled and a wallpaper is set, gates the onReady callback
      on the wallpaper being fetched and painted — so the Swift fade-in begins only
      once the wallpaper is actually visible.
    */
    func applyFocusModeCustomizations(enabled: Bool, onReady: (() -> Void)? = nil) {
        let floating = UserDefaults.standard.bool(forKey: "focusFloating")
        let dimness  = UserDefaults.standard.double(forKey: "focusDimness")
        let blur     = UserDefaults.standard.double(forKey: "focusBlur")

        updateConfig([
            "focusCustom":  enabled,
            "floating":     floating,
            "focusDimness": dimness,
            "focusBlur":    blur,
        ])

        guard enabled else { onReady?(); return }

        let path = UserDefaults.standard.string(forKey: "focusWallpaperPath") ?? ""
        let t = Int(Date().timeIntervalSince1970)
        let wallpaperURL = path.isEmpty ? nil : "blobtxt://wallpaper?t=\(t)"

        guard let url = wallpaperURL, let onReady else {
            setFocusWallpaper(dataURL: wallpaperURL)
            onReady?()
            return
        }

        guard let webView else {
            DispatchQueue.main.async { onReady() }
            return
        }
        webView.callAsyncJavaScript(
            """
            window.editorBridge.setFocusWallpaper(src);
            try { await fetch(src); } catch(e) {}
            await new Promise(r => requestAnimationFrame(r));
            """,
            arguments: ["src": url],
            in: nil,
            in: .page
        ) { _ in DispatchQueue.main.async { onReady() } }
    }

    // MARK: - Private

    private func evaluate(_ js: String) {
        DispatchQueue.main.async {
            self.webView?.evaluateJavaScript(js, completionHandler: nil)
        }
    }
}

// MARK: - Notification names

extension Notification.Name {
    static let toggleFocusMode = Notification.Name("toggleFocusMode")
    static let focusCustomizationChanged = Notification.Name("focusCustomizationChanged")
}

extension URL {
    var mimeType: String {
        if let type = UTType(filenameExtension: pathExtension) {
            return type.preferredMIMEType ?? "application/octet-stream"
        }
        return "application/octet-stream"
    }
}
