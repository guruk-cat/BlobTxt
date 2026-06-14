import SwiftUI
import WebKit

// NSViewRepresentable adapter that owns the WKWebView lifecycle. Its only job
// is to create and configure the web view on first use. All content loading and
// settings updates are driven by EditorMonitor via EditorBridge — this file
// does not track or apply any editor settings directly.
struct WebViewAdapter: NSViewRepresentable {
    @ObservedObject var bridge: EditorBridge

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
        // Intentionally empty. Settings changes flow through EditorMonitor's
        // onChange handlers → bridge.updateConfig(), not through SwiftUI updates here.
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    // MARK: - Coordinator

    // The coordinator's only role is acting as WKNavigationDelegate. Content
    // loading is initiated by EditorMonitor in response to the editorReady message.
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
