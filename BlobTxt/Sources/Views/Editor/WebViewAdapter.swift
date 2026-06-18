import SwiftUI
import WebKit

// NSViewRepresentable adapter that owns the WKWebView lifecycle.
// It creates and configures the web view on first use. Content loading and settings updates are driven by EditorMonitor via EditorBridge, not here.
struct WebViewAdapter: NSViewRepresentable {
    @ObservedObject var bridge: EditorBridge

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()

        // Inject active palette colors before any CSS is computed.
        // Eliminates the flash of hardcoded colors. Runs on every page load so theme switches also take effect immediately.
        let colorScript = WKUserScript(
            source: AppColors.shared.editorCSSVariablesJS(),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        config.userContentController.addUserScript(colorScript)

        // Weak wrapper prevents a retain cycle between WKUserContentController and EditorBridge.
        let weakHandler = WeakMessageHandler(handler: bridge)
        config.userContentController.add(weakHandler, name: "editorBridge")

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
        // Intentionally empty: settings changes flow through EditorMonitor's onChange handlers → bridge.updateConfig(), not SwiftUI updates here.
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    // MARK: - Coordinator

    // Acts only as WKNavigationDelegate.
    class Coordinator: NSObject, WKNavigationDelegate {}
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
