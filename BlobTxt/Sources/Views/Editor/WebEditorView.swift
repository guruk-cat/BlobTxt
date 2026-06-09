import SwiftUI
import WebKit

struct WebEditorView: NSViewRepresentable {
    @ObservedObject var bridge: EditorBridge
    @AppStorage("autoScroll") private var autoScrollMode: String = "regular"
    @AppStorage("fontSize") private var fontSize: Double = 16.0
    @AppStorage("fontFamily") private var fontFamily: String = "Menlo"
    @AppStorage("imageLimitHalfWidth") private var imageLimitHalfWidth: Bool = false
    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()

        // Inject active palette colors before any CSS is computed — eliminates the flash of
        // hardcoded colors. Runs on every page load so theme switches also take effect immediately.
        let colorScript = WKUserScript(
            source: AppColors.shared.editorCSSVariablesJS(),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        config.userContentController.addUserScript(colorScript)

        // Weak wrapper prevents retain cycle between WKUserContentController and EditorBridge.
        let weakHandler = WeakMessageHandler(handler: bridge)
        config.userContentController.add(weakHandler, name: "editorBridge")

        config.setURLSchemeHandler(WallpaperSchemeHandler(), forURLScheme: "blobtxt")

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")

        bridge.webView = webView

        if let url = Bundle.main.url(forResource: "editor", withExtension: "html") {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }

        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        context.coordinator.updateAutoScroll(autoScrollMode)
        context.coordinator.updateFontSize(fontSize)
        context.coordinator.updateFontFamily(fontFamily)
        context.coordinator.updateImageHalfWidth(imageLimitHalfWidth)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(bridge: bridge)
    }

    // MARK: - Coordinator

    class Coordinator: NSObject, WKNavigationDelegate {
        let bridge: EditorBridge
        private var lastScrollMode: String = ""
        private var lastFontSize: Double = -1
        private var lastFontFamily: String = ""
        private var lastImageHalfWidth: Bool? = nil

        init(bridge: EditorBridge) {
            self.bridge = bridge
        }

        func updateAutoScroll(_ mode: String) {
            guard mode != lastScrollMode else { return }
            lastScrollMode = mode
            bridge.setAutoScroll(mode)
        }

        func updateFontSize(_ size: Double) {
            guard size != lastFontSize else { return }
            lastFontSize = size
            bridge.setFontSize(size)
        }

        func updateFontFamily(_ family: String) {
            guard family != lastFontFamily else { return }
            lastFontFamily = family
            bridge.setFontFamily(family)
        }

        func updateImageHalfWidth(_ half: Bool) {
            guard half != lastImageHalfWidth else { return }
            lastImageHalfWidth = half
            bridge.setImageHalfWidth(half)
        }

        // Applies initial settings after the first page load. `updateNSView` handles
        // subsequent changes, but is not called during the initial load.
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                self.bridge.applyColors()
                let scrollMode = UserDefaults.standard.string(forKey: "autoScroll") ?? "regular"
                self.bridge.setAutoScroll(scrollMode)
                self.lastScrollMode = scrollMode
                let fontSize = UserDefaults.standard.double(forKey: "fontSize")
                let resolvedSize = fontSize > 0 ? fontSize : 16.0
                self.bridge.setFontSize(resolvedSize)
                self.lastFontSize = resolvedSize
                let fontFamily = UserDefaults.standard.string(forKey: "fontFamily") ?? "Menlo"
                self.bridge.setFontFamily(fontFamily)
                self.lastFontFamily = fontFamily
                let halfWidth = UserDefaults.standard.bool(forKey: "imageLimitHalfWidth")
                self.bridge.setImageHalfWidth(halfWidth)
                self.lastImageHalfWidth = halfWidth
            }
        }
    }
}

// MARK: - Wallpaper URL scheme handler

class WallpaperSchemeHandler: NSObject, WKURLSchemeHandler {
    private var activeTasks = Set<ObjectIdentifier>()

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        let taskID = ObjectIdentifier(urlSchemeTask)
        activeTasks.insert(taskID)

        let path = UserDefaults.standard.string(forKey: "focusWallpaperPath") ?? ""
        guard !path.isEmpty else {
            activeTasks.remove(taskID)
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let fileURL = URL(fileURLWithPath: path)
        let requestURL = urlSchemeTask.request.url!
        let mime = fileURL.mimeType

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let data = try? Data(contentsOf: fileURL) else {
                DispatchQueue.main.async {
                    guard self?.activeTasks.contains(taskID) == true else { return }
                    self?.activeTasks.remove(taskID)
                    urlSchemeTask.didFailWithError(URLError(.cannotOpenFile))
                }
                return
            }
            DispatchQueue.main.async {
                guard self?.activeTasks.contains(taskID) == true else { return }
                self?.activeTasks.remove(taskID)
                let response = URLResponse(url: requestURL, mimeType: mime, expectedContentLength: data.count, textEncodingName: nil)
                urlSchemeTask.didReceive(response)
                urlSchemeTask.didReceive(data)
                urlSchemeTask.didFinish()
            }
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        activeTasks.remove(ObjectIdentifier(urlSchemeTask))
    }
}

// MARK: - Retain-cycle prevention

class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var handler: EditorBridge?

    init(handler: EditorBridge) {
        self.handler = handler
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        handler?.userContentController(userContentController, didReceive: message)
    }
}
