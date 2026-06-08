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

        // Toolbar init — injected after all module scripts have run, so window.editorBridge
        // and its helper functions are guaranteed to exist. No retry loop needed.
        let toolbarScript = WKUserScript(
            source: Self.toolbarInitJS,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
        config.userContentController.addUserScript(toolbarScript)

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

// MARK: - Toolbar init script

extension WebEditorView {
    static let toolbarInitJS = """
    (function () {
      var eb = window.editorBridge;

      // Active state
      function updateToolbar() {
        // Suppress all active indicators until the user has placed the cursor via a click.
        // window.__ft_userInteracted() returns false until that first interaction fires,
        // preventing the toolbar from reflecting formatting at the load-time selection
        // position (which may be inside a heading or other block the user hasn't touched).
        var interacted = typeof window.__ft_userInteracted === 'function' && window.__ft_userInteracted();
        var snap = (interacted && typeof window.__ft_stateSnapshot === 'function') ? window.__ft_stateSnapshot() : {};
        toggle('bold-btn',  interacted && !!snap.bold);
        toggle('italic-btn', interacted && !!snap.italic);
        toggle('quote-btn', interacted && !!snap.blockquote);
        toggle('link-btn',  interacted && !!snap.linkActive);
        var h = interacted ? (snap.heading || 0) : 0;
        var label = document.getElementById('heading-label');
        if (label) label.textContent = h > 0 ? 'H' + h : 'Headings';
        toggle('heading-menu', h > 0);
        toggle('list-menu', interacted && !!(snap.bulletList || snap.orderedList));
      }
      function toggle(id, active) {
        var el = document.getElementById(id);
        if (el) el.classList.toggle('active', active);
      }
      setInterval(updateToolbar, 100);
      updateToolbar();

      // Formatting commands
      function on(id, fn) {
        var el = document.getElementById(id);
        if (el) el.addEventListener('click', fn);
      }
      on('bold-btn',   function () { eb.toggleBold(); });
      on('italic-btn', function () { eb.toggleItalic(); });
      on('quote-btn',  function () { eb.toggleBlockquote(); });
      on('link-btn',   function () {
        var href = typeof window.__ft_getLinkHref === 'function' ? window.__ft_getLinkHref() : null;
        post({ type: 'insertLink', href: href || null });
      });
      on('ref-btn',   function () { eb.addFootnoteReference(); });
      on('image-btn', function () { post({ type: 'insertImage' }); });

      // Heading dropdown
      var headingMenu = document.getElementById('heading-menu');
      var headingDrop = document.getElementById('heading-dropdown');
      headingMenu.addEventListener('click', function (e) {
        e.stopPropagation();
        listDrop.classList.remove('open');
        headingDrop.classList.toggle('open');
      });
      headingDrop.querySelectorAll('.dropdown-item').forEach(function (item) {
        item.addEventListener('click', function (e) {
          e.stopPropagation();
          eb.setHeading(parseInt(item.dataset.level, 10));
          headingDrop.classList.remove('open');
        });
      });

      // List dropdown
      var listMenu = document.getElementById('list-menu');
      var listDrop = document.getElementById('list-dropdown');
      listMenu.addEventListener('click', function (e) {
        e.stopPropagation();
        headingDrop.classList.remove('open');
        listDrop.classList.toggle('open');
      });
      document.getElementById('bullet-item').addEventListener('click', function (e) {
        e.stopPropagation();
        eb.toggleBulletList();
        listDrop.classList.remove('open');
      });
      document.getElementById('ordered-item').addEventListener('click', function (e) {
        e.stopPropagation();
        eb.toggleOrderedList();
        listDrop.classList.remove('open');
      });

      // Chrome → Swift
      on('copy-btn',  function () { eb.copyAll(); });
      on('close-btn', function () { post({ type: 'closeEditor' }); });
      function post(msg) {
        var h = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.editorBridge;
        if (h) h.postMessage(msg);
      }

      // Close dropdowns on outside click
      document.addEventListener('click', function () {
        headingDrop.classList.remove('open');
        listDrop.classList.remove('open');
      });

      // Outline: scroll-to-heading + active heading tracking
      function detectActiveHeading() {
        var el = document.getElementById('editor');
        if (!el) return;
        var hs = el.querySelectorAll('h1,h2,h3,h4,h5,h6');
        var edTop = el.getBoundingClientRect().top;
        var threshold = el.clientHeight * 0.3;
        var scrolledPast = -1;
        var firstVisible = -1;
        hs.forEach(function(h, i) {
          var top = h.getBoundingClientRect().top - edTop;
          if (top < 0) { scrolledPast = i; }
          else if (firstVisible === -1 && top <= threshold) { firstVisible = i; }
        });
        post({ type: 'headingVisible', index: firstVisible !== -1 ? firstVisible : scrolledPast });
      }
      window.scrollToHeading = function(index) {
        var el = document.getElementById('editor');
        if (!el) return;
        var hs = el.querySelectorAll('h1,h2,h3,h4,h5,h6');
        if (index >= 0 && index < hs.length) {
          hs[index].scrollIntoView({ behavior: 'smooth', block: 'start' });
          el.addEventListener('scrollend', detectActiveHeading, { once: true });
        }
      };
      (function() {
        var el = document.getElementById('editor');
        if (!el) return;
        var _t = 0;
        el.addEventListener('scroll', function() {
          var now = Date.now();
          if (now - _t < 100) return;
          _t = now;
          detectActiveHeading();
        });
      })();
    })();
    """
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
