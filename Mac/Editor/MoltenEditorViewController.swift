import AppKit
import WebKit

/// Hosts the full-window WKWebView running the Crepe editing surface and owns
/// the Swift side of the bridge (see Editor/src/main.js for the contract).
final class MoltenEditorViewController: NSViewController {
    private weak var document: MoltenDocument?
    private var webView: WKWebView!
    private var isEditorReady = false

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

        webView = WKWebView(
            frame: NSRect(origin: .zero, size: MoltenDocument.defaultContentSize),
            configuration: configuration
        )
        webView.navigationDelegate = self
        webView.setValue(false, forKey: "drawsBackground")
        view = webView

        loadEditorPage()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(webView)
        // The editor may have finished building before the window became key;
        // a DOM focus set back then didn't stick. Re-focus now that it can.
        webView.evaluateJavaScript("window.moltenAPI?.focus();")
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

    /// Pushes document content into the editor. Before the ready message this
    /// is a no-op: the surface pulls the authoritative text from the document
    /// via editorDidBecomeReady, so there is exactly one delivery path.
    func loadDocumentText(_ text: String) {
        guard isEditorReady else { return }
        // callAsyncJavaScript marshals the string as an argument — no O(N)
        // escaping pass, no parsing a megabytes-long script literal.
        webView.callAsyncJavaScript(
            "window.moltenAPI.setMarkdown(md);",
            arguments: ["md": text],
            in: nil,
            in: .page
        ) { result in
            if case .failure(let error) = result {
                MoltenLog.editor.error("setMarkdown failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Pulls the current serialization from the editor. Completion receives
    /// nil when no live editor exists (booting/rebuilding) so callers keep
    /// the text they already have rather than saving garbage.
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

    // MARK: - Native menu actions → ProseMirror history

    // WKWebView does not respond to undo:/redo:, so menu clicks land here via
    // the responder chain and forward to the editor's own history plugin
    // (Cmd+Z already works through the web view's key handling).
    @objc func undo(_ sender: Any?) {
        webView.evaluateJavaScript("window.moltenAPI.undo();")
    }

    @objc func redo(_ sender: Any?) {
        webView.evaluateJavaScript("window.moltenAPI.redo();")
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
            document?.editorDidBecomeReady()
        case "change":
            if let markdown = body["markdown"] as? String {
                document?.editorTextDidChange(markdown)
            }
        case "boot-error":
            let detail = body["message"] as? String ?? "unknown"
            MoltenLog.editor.error("Editor surface failed to boot: \(detail, privacy: .public)")
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
