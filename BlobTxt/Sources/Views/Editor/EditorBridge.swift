import Foundation
import WebKit
import AppKit
import Combine
import UniformTypeIdentifiers

class EditorBridge: NSObject, ObservableObject, WKScriptMessageHandler {
    weak var webView: WKWebView?

    @Published var isReady = false
    @Published var isDirty = false

    var lastScrollPosition: Int = 0

    // Called when the web toolbar's Close button is tapped.
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

            default:
                break
            }
        }
    }

    // MARK: - Swift → JS (editor commands)

    func setAutoScroll(_ mode: String) {
        evaluate("window.editorBridge.setAutoScrollMode('\(mode)')")
    }

    func setFocusMode(_ enabled: Bool) {
        evaluate("document.body.classList.toggle('focus-mode', \(enabled ? "true" : "false"))")
    }

    func applyFocusModeCustomizations(enabled: Bool, onReady: (() -> Void)? = nil) {
        let floating = UserDefaults.standard.bool(forKey: "focusFloating")
        let dimness  = UserDefaults.standard.double(forKey: "focusDimness")
        let blur     = UserDefaults.standard.double(forKey: "focusBlur")
        evaluate("window.editorBridge.setFocusModeCustomizations(\(enabled), \(floating), \(dimness), \(blur))")

        guard enabled else {
            onReady?()
            return
        }

        let path = UserDefaults.standard.string(forKey: "focusWallpaperPath") ?? ""
        let t = Int(Date().timeIntervalSince1970)
        let wallpaperURL = path.isEmpty ? nil : "blobtxt://wallpaper?t=\(t)"

        guard let url = wallpaperURL, let onReady else {
            setFocusWallpaper(dataURL: wallpaperURL)
            onReady?()
            return
        }

        // Gate the callback on the wallpaper actually being fetched and painted.
        // callAsyncJavaScript awaits the fetch (bytes ready) then a rAF (paint queued)
        // before calling back, so the fade-in begins only once the wallpaper is visible.
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

    func setFocusWallpaper(dataURL: String?) {
        webView?.callAsyncJavaScript(
            "window.editorBridge.setFocusWallpaper(src)",
            arguments: ["src": dataURL ?? NSNull()],
            in: nil,
            in: .page,
            completionHandler: nil
        )
    }

    // MARK: - Editor style

    private var currentFontSize: Double = UserDefaults.standard.double(forKey: "fontSize") > 0
        ? UserDefaults.standard.double(forKey: "fontSize") : 16.0
    private var currentFontFamily: String = UserDefaults.standard.string(forKey: "fontFamily") ?? "Menlo"

    func setFontSize(_ size: Double) {
        currentFontSize = size
        applyEditorStyle()
    }

    func setFontFamily(_ family: String) {
        currentFontFamily = family
        applyEditorStyle()
    }

    private func applyEditorStyle() {
        let size = currentFontSize
        let maxWidth = Int(820.0 * size / 20.0)
        let cssFamily = fontFamilyCSS(currentFontFamily)
        let x  = Int(size)
        let css = """
            .cm-content { font-family: \(cssFamily); font-size: \(x)px; max-width: \(maxWidth)px; }
            .cm-line.cm-md-h1 { font-size: \(Int(Double(x) * 2.0))px; line-height: 1.4; }
            .cm-line.cm-md-h2 { font-size: \(Int(Double(x) * 1.6))px; line-height: 1.4; }
            .cm-line.cm-md-h3 { font-size: \(Int(Double(x) * 1.3))px; line-height: 1.4; }
            """
        let js = """
        (function(){
          var el = document.getElementById('ft-font');
          if (!el) { el = document.createElement('style'); el.id = 'ft-font'; document.head.appendChild(el); }
          el.textContent = `\(css)`;
        })()
        """
        evaluate(js)
    }

    private func fontFamilyCSS(_ family: String) -> String {
        switch family {
        case "Palatino": return "Palatino, \"Palatino Linotype\", serif"
        default:         return "Menlo, Consolas, \"Courier New\", monospace"
        }
    }

    func setImageHalfWidth(_ half: Bool) {
        let js = """
        (function(){
          var el = document.getElementById('ft-img-style');
          if (!el) { el = document.createElement('style'); el.id = 'ft-img-style'; document.head.appendChild(el); }
          el.textContent = ':root { --ft-img-max-width: \(half ? "50%" : "100%"); }';
        })()
        """
        evaluate(js)
    }

    // Passes a Markdown string to the web editor. JSONSerialization with
    // .fragmentsAllowed produces a properly escaped JS string literal for any
    // Swift String, including those with backslashes, quotes, and newlines.
    func setContent(_ markdown: String) {
        guard let data = try? JSONSerialization.data(withJSONObject: markdown, options: .fragmentsAllowed),
              let jsStr = String(data: data, encoding: .utf8) else { return }
        let js = "window.editorBridge.setContent(\(jsStr))"
        evaluate(js)
    }

    func setContentAndScrollToTop(_ markdown: String) {
        guard let data = try? JSONSerialization.data(withJSONObject: markdown, options: .fragmentsAllowed),
              let jsStr = String(data: data, encoding: .utf8) else { return }
        let js = """
        (function(){
            window.editorBridge.setContent(\(jsStr));
            var ed = document.getElementById('editor');
            if (ed) ed.scrollTop = 0;
        })()
        """
        evaluate(js)
    }

    func setContentAndScrollTo(_ markdown: String, scrollTop: Int) {
        guard let data = try? JSONSerialization.data(withJSONObject: markdown, options: .fragmentsAllowed),
              let jsStr = String(data: data, encoding: .utf8) else { return }
        let js = """
        (function(){
            window.editorBridge.setContent(\(jsStr));
            var ed = document.getElementById('editor');
            if (ed) ed.scrollTop = \(scrollTop);
        })()
        """
        evaluate(js)
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

    func markClean() {
        DispatchQueue.main.async { self.isDirty = false }
    }

    /// Injects the active AppColors palette into the web editor's CSS variables.
    func applyColors() {
        evaluate(AppColors.shared.editorCSSInjection())
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
