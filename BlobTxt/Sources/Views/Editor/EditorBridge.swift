import Foundation
import WebKit
import AppKit
import Combine
import UniformTypeIdentifiers

struct EditorState: Equatable {
    var bold = false
    var italic = false
    var underline = false
    var heading = 0   // 0 = paragraph, 1–3 = heading level
    var bulletList = false
    var orderedList = false
    var blockquote = false
    var linkActive = false
}

class EditorBridge: NSObject, ObservableObject, WKScriptMessageHandler {
    weak var webView: WKWebView?

    @Published var isReady = false
    @Published var isDirty = false
    @Published var editorState = EditorState()
    @Published var showLinkDialog = false
    @Published var pendingLinkHref: String? = nil

    var lastScrollPosition: Int = 0

    // Called when the web toolbar's Close button is tapped.
    var onClose: (() -> Void)?

    private var pendingImageInsert: Bool = false

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

            case "stateUpdate":
                self.editorState = EditorState(
                    bold:        body["bold"]        as? Bool ?? false,
                    italic:      body["italic"]      as? Bool ?? false,
                    underline:   body["underline"]   as? Bool ?? false,
                    heading:     body["heading"]     as? Int  ?? 0,
                    bulletList:  body["bulletList"]  as? Bool ?? false,
                    orderedList: body["orderedList"] as? Bool ?? false,
                    blockquote:  body["blockquote"]  as? Bool ?? false,
                    linkActive:  body["linkActive"]  as? Bool ?? false
                )

            case "copyAll":
                if let text = body["text"] as? String {
                    let html = body["html"] as? String
                    Self.writeToClipboard(html: html, plainText: text)
                }

            case "closeEditor":
                self.onClose?()

            case "scrollPositionChanged":
                if let top = body["scrollTop"] as? Int {
                    self.lastScrollPosition = top
                }

            case "headingVisible":
                let index = body["index"] as? Int ?? -1
                NotificationCenter.default.post(name: .activeHeadingChanged, object: index)

            case "insertLink":
                self.pendingLinkHref = body["href"] as? String
                self.showLinkDialog = true

            case "openURL":
                if let urlStr = body["url"] as? String, let url = URL(string: urlStr) {
                    NSWorkspace.shared.open(url)
                }

            case "insertImage":
                self.openImagePicker()

            default:
                break
            }
        }
    }

    // MARK: - Swift → JS (editor commands)

    func toggleBold() { evaluate("window.editorBridge.toggleBold()"); refocusWebView() }
    func toggleItalic() { evaluate("window.editorBridge.toggleItalic()"); refocusWebView() }
    func toggleUnderline() { evaluate("window.editorBridge.toggleUnderline()"); refocusWebView() }
    func toggleBulletList() { evaluate("window.editorBridge.toggleBulletList()"); refocusWebView() }
    func toggleOrderedList() { evaluate("window.editorBridge.toggleOrderedList()"); refocusWebView() }
    func toggleBlockquote() { evaluate("window.editorBridge.toggleBlockquote()"); refocusWebView() }
    func addFootnoteReference() { evaluate("window.editorBridge.addFootnoteReference()") }
    func copyAll() { evaluate("window.editorBridge.copyAll()") }
    func setHeading(level: Int) {
        evaluate("window.editorBridge.setHeading(\(level))")
        refocusWebView()
    }

    func scrollToHeading(index: Int) {
        evaluate("if(window.scrollToHeading) window.scrollToHeading(\(index))")
    }

    func searchAndHighlight(query: String) {
        let escaped = query
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        evaluate("if(window.editorBridge) window.editorBridge.searchAndHighlight(\"\(escaped)\")")
    }

    func scrollToSearchResult(index: Int) {
        evaluate("if(window.editorBridge) window.editorBridge.scrollToSearchResult(\(index))")
    }

    func clearSearchHighlights() {
        evaluate("if(window.editorBridge) window.editorBridge.clearSearchHighlights()")
    }

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

    // MARK: - Image support

    private func openImagePicker() {
        DispatchQueue.main.async {
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.jpeg, .png, .gif, .tiff, .bmp, .heic]
            panel.allowsMultipleSelection = false
            panel.canChooseDirectories = false
            panel.begin { [weak self] response in
                guard response == .OK, let url = panel.url else { return }
                do {
                    let data = try Data(contentsOf: url)
                    let mimeType = url.mimeType
                    let base64 = data.base64EncodedString()
                    let src = "data:\(mimeType);base64,\(base64)"
                    self?.insertImage(src: src)
                } catch {
                    print("[EditorBridge] Failed to read image: \(error)")
                }
            }
        }
    }

    // MARK: - Link support

    func setLink(url: String) {
        let escaped = url
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        evaluate("window.editorBridge.setLink(\"\(escaped)\")")
        refocusWebView()
    }

    func unsetLink() {
        evaluate("window.editorBridge.unsetLink()")
        refocusWebView()
    }

    // callAsyncJavaScript handles the large base64 payload safely; don't swap for evaluate(_:).
    func insertImage(src: String) {
        webView?.callAsyncJavaScript(
            "window.editorBridge.insertImage(src)",
            arguments: ["src": src],
            in: nil,
            in: .page,
            completionHandler: nil
        )
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
            .ProseMirror, .ProseMirror h1, .ProseMirror h2, .ProseMirror h3 { font-family: \(cssFamily); }
            .ProseMirror { font-size: \(x)px; max-width: \(maxWidth)px; }
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

    func setContent(_ jsonString: String) {
        let js = "(function(){ var c = \(jsonString); window.editorBridge.setContent(c); })()"
        evaluate(js)
    }

    func setContentAndScrollToTop(_ jsonString: String) {
        let js = """
        (function(){
            var c = \(jsonString);
            window.editorBridge.setContent(c);
            var ed = document.getElementById('editor');
            if (ed) ed.scrollTop = 0;
        })()
        """
        evaluate(js)
    }

    func setContentAndScrollTo(_ jsonString: String, scrollTop: Int) {
        let js = """
        (function(){
            var c = \(jsonString);
            window.editorBridge.setContent(c);
            var ed = document.getElementById('editor');
            if (ed) ed.scrollTop = \(scrollTop);
        })()
        """
        evaluate(js)
    }

    func getContent(completion: @escaping (String?) -> Void) {
        webView?.evaluateJavaScript("JSON.stringify(window.editor.getJSON())") { result, _ in
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

    private func refocusWebView() {
        DispatchQueue.main.async {
            if let webView = self.webView {
                webView.window?.makeFirstResponder(webView)
            }
        }
    }

    // MARK: - Clipboard

    // Wraps HTML in a UTF-8 document so Pages and Word handle multi-byte characters correctly.
    static func writeToClipboard(html: String?, plainText: String?) {
        let pb = NSPasteboard.general
        pb.clearContents()
        if let html = html {
            let doc = "<html><head><meta http-equiv=\"Content-Type\" content=\"text/html; charset=UTF-8\"></head><body>\(html)</body></html>"
            if let data = doc.data(using: .utf8) {
                pb.setData(data, forType: NSPasteboard.PasteboardType(rawValue: "public.html"))
            }
        }
        if let text = plainText {
            pb.setString(text, forType: .string)
        }
    }
}

// MARK: - Notification names

extension Notification.Name {
    static let scrollToOutlineHeading = Notification.Name("scrollToOutlineHeading")
    static let activeHeadingChanged = Notification.Name("activeHeadingChanged")
    static let scrollToSearchResult = Notification.Name("scrollToSearchResult")
    static let searchAndHighlight = Notification.Name("searchAndHighlight")
    static let clearSearchHighlights = Notification.Name("clearSearchHighlights")
    static let reloadEditorContent = Notification.Name("reloadEditorContent")
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
