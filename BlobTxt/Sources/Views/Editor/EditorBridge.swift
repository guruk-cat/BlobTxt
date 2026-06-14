import Foundation
import WebKit
import AppKit
import Combine

class EditorBridge: NSObject, ObservableObject, WKScriptMessageHandler {
    weak var webView: WKWebView?

    @Published var isReady = false
    @Published var isDirty = false
    @Published var isSearchOpen = false

    var lastScrollPosition: Int = 0

    // Called when the editor requests a close (e.g., a toolbar close button).
    var onClose: (() -> Void)?

    // The file currently open in this editor. Used to resolve local link paths,
    // which are relative to the open file's directory.
    var documentURL: URL?

    // Called when a local link is followed: the resolved target file and the
    // optional heading fragment to scroll to once it is open.
    var onOpenLocal: ((URL, String?) -> Void)?

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

            case "openBlob":
                guard let path = body["path"] as? String, let base = self.documentURL else { break }
                let dir     = base.deletingLastPathComponent()
                let decoded = path.removingPercentEncoding ?? path
                let target  = URL(fileURLWithPath: decoded, relativeTo: dir).standardizedFileURL
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: target.path, isDirectory: &isDir),
                      !isDir.boolValue else { break }
                let fragmentRaw = body["fragment"] as? String
                let fragment    = (fragmentRaw?.isEmpty ?? true) ? nil : fragmentRaw
                self.onOpenLocal?(target, fragment)

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

    // Called once after editorReady: serializes document + config to JSON and
    // calls window.editorBridge.load().
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

    // Called whenever a setting changes, with a sparse patch of only the changed keys.
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

    // Scrolls the open document to the heading whose slug matches the fragment.
    // Passed as an argument (not interpolated) so heading text needs no escaping.
    func scrollToHeading(_ fragment: String) {
        webView?.callAsyncJavaScript(
            "window.editorBridge.scrollToHeading(fragment)",
            arguments: ["fragment": fragment],
            in: nil,
            in: .page,
            completionHandler: nil
        )
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

    // MARK: - Private

    private func evaluate(_ js: String) {
        DispatchQueue.main.async {
            self.webView?.evaluateJavaScript(js, completionHandler: nil)
        }
    }
}
