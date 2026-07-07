import AppKit
import WebKit

/// Hosts the full-window WKWebView running the Crepe editing surface and owns
/// the Swift side of the bridge (see Editor/src/main.js for the contract).
final class MoltenEditorViewController: NSViewController {
    private weak var document: MoltenDocument?
    private var webView: WKWebView!
    private var isEditorReady = false
    /// Content that arrived before the editor booted (document read can beat
    /// the web view's load) — delivered on the ready message.
    private var pendingText: String?

    init(document: MoltenDocument) {
        self.document = document
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    deinit {
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: Self.bridgeName)
    }

    private static let bridgeName = "molten"

    override func loadView() {
        let configuration = WKWebViewConfiguration()
        // The handler is registered through a weak proxy: WKUserContentController
        // retains its handlers, which would otherwise cycle-retain this controller.
        configuration.userContentController.add(WeakScriptMessageHandler(self), name: Self.bridgeName)

        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 720), configuration: configuration)
        webView.navigationDelegate = self
        webView.setValue(false, forKey: "drawsBackground")
        view = webView

        loadEditorPage()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(webView)
    }

    private func loadEditorPage() {
        guard
            let pageURL = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "dist"),
            let resourcesURL = Bundle.main.resourceURL
        else {
            MoltenLog.editor.error("Editor bundle missing from app resources")
            return
        }
        isEditorReady = false
        // Read access spans the whole Resources directory (not just dist/) —
        // in the sandbox, scoping it to the subdirectory breaks subresource
        // loads (editor.js never executes; blank editor).
        webView.loadFileURL(pageURL, allowingReadAccessTo: resourcesURL)
    }

    // MARK: - Swift → JS

    /// Pushes document content into the editor, queueing it if the surface
    /// hasn't booted yet.
    func loadDocumentText(_ text: String) {
        guard isEditorReady else {
            pendingText = text
            return
        }
        webView.evaluateJavaScript("window.moltenAPI.setMarkdown(\(text.javaScriptStringLiteral));") { _, error in
            if let error {
                MoltenLog.editor.error("setMarkdown failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Pulls the current serialization synchronously from the editor's point
    /// of view (flushes its debounce). Completion receives nil on failure so
    /// callers fall back to the last bridged text rather than saving garbage.
    func pullMarkdown(completion: @escaping (String?) -> Void) {
        guard isEditorReady else {
            completion(nil)
            return
        }
        webView.evaluateJavaScript("window.moltenAPI.getMarkdown();") { result, error in
            if let error {
                MoltenLog.editor.error("getMarkdown failed: \(error.localizedDescription, privacy: .public)")
                completion(nil)
                return
            }
            completion(result as? String)
        }
    }
}

// MARK: - JS → Swift

extension MoltenEditorViewController: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == Self.bridgeName,
              let body = message.body as? [String: Any],
              let type = body["type"] as? String else {
            return
        }

        switch type {
        case "ready":
            isEditorReady = true
            if let pendingText {
                self.pendingText = nil
                loadDocumentText(pendingText)
            } else {
                document?.editorDidBecomeReady()
            }
        case "change":
            if let markdown = body["markdown"] as? String {
                document?.editorTextDidChange(markdown)
            }
        default:
            MoltenLog.editor.debug("Unknown bridge message: \(type, privacy: .public)")
        }
    }
}

extension MoltenEditorViewController: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        MoltenLog.editor.error("Editor page navigation failed: \(error.localizedDescription, privacy: .public)")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        MoltenLog.editor.error("Editor page failed to load: \(error.localizedDescription, privacy: .public)")
    }

    /// WebKit's content process can be jettisoned (memory pressure). Reload the
    /// surface; the ready message then repopulates it from the document, whose
    /// `text` still holds the last bridged content.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        MoltenLog.editor.error("Web content process terminated; reloading editor surface")
        loadEditorPage()
    }
}

/// Breaks the WKUserContentController → handler retain cycle.
private final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    private weak var target: WKScriptMessageHandler?

    init(_ target: WKScriptMessageHandler) {
        self.target = target
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(userContentController, didReceive: message)
    }
}
