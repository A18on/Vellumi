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

    private let assetSchemeHandler = MoltenAssetSchemeHandler()

    override func loadView() {
        let configuration = WKWebViewConfiguration()
        // The handler is registered through a weak proxy: WKUserContentController
        // retains its handlers, which would otherwise cycle-retain this controller.
        configuration.userContentController.add(WeakScriptMessageHandler(self), name: Self.bridgeName)
        // Serves document-relative images (assets/…) to the sandboxed surface.
        configuration.setURLSchemeHandler(assetSchemeHandler, forURLScheme: MoltenAssetSchemeHandler.scheme)

        // navigator.language in WKWebView follows the SYSTEM locale, but the
        // app's UI language can differ (per-app language setting, localization
        // fallback). Inject the app-resolved language so the editor's slash
        // menu / placeholders match the rest of the UI.
        if let appLanguage = Bundle.main.preferredLocalizations.first,
           let encoded = try? JSONEncoder().encode(appLanguage),
           let literal = String(data: encoded, encoding: .utf8) {
            let script = WKUserScript(
                source: "window.__vellumiLanguage = \(literal);",
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
            configuration.userContentController.addUserScript(script)
        }

        webView = WKWebView(
            frame: NSRect(origin: .zero, size: MoltenDocument.defaultContentSize),
            configuration: configuration
        )
        webView.navigationDelegate = self
        webView.setValue(false, forKey: "drawsBackground")

        // The web view lives inside a CLIPPING container so the sidebar
        // toggle can freeze its width: during the collapse animation the
        // web view stays put (pinned to the trailing edge at constant width)
        // and the sidebar slides over it, instead of AppKit resizing the
        // web view every frame — WebKit renders async, so per-frame resizes
        // made the centered text column visibly wobble.
        let container = NSView()
        container.wantsLayer = true
        container.layer?.masksToBounds = true
        webView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(webView)
        webViewLeadingConstraint = webView.leadingAnchor.constraint(equalTo: container.leadingAnchor)
        NSLayoutConstraint.activate([
            webViewLeadingConstraint!,
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.topAnchor.constraint(equalTo: container.topAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        view = container

        loadEditorPage()
    }

    private var webViewLeadingConstraint: NSLayoutConstraint?
    private var frozenWidthConstraint: NSLayoutConstraint?

    /// Freezes the web view at its current width, released from the leading
    /// edge (trailing stays pinned). Call around sidebar toggle animations.
    func beginConstantWidthAnimation() {
        guard frozenWidthConstraint == nil else { return }
        let frozen = webView.widthAnchor.constraint(equalToConstant: webView.frame.width)
        webViewLeadingConstraint?.isActive = false
        frozen.isActive = true
        frozenWidthConstraint = frozen
    }

    /// Restores width-follows-container: exactly one reflow, at animation end.
    func endConstantWidthAnimation() {
        guard let frozen = frozenWidthConstraint else { return }
        frozen.isActive = false
        frozenWidthConstraint = nil
        webViewLeadingConstraint?.isActive = true
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        focusEditingSurface()
    }

    /// Routes both AppKit first-responder status AND DOM focus to the editing
    /// surface — each alone is insufficient (typing goes to the sidebar, or
    /// nowhere). Callers: window appear, find-bar dismissal, sidebar toggle.
    func focusEditingSurface() {
        // In source mode the web view is hidden behind the source scroll view;
        // focusing it would swallow keystrokes with no visible caret. The
        // workspace owns that state, so ask it before stealing focus.
        guard document?.workspaceViewController?.isSourceMode != true else { return }
        view.window?.makeFirstResponder(webView)
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

    /// Re-points the asset scheme at the document's (possibly new) folder.
    /// Called after every completed save: the first save of an untitled
    /// document and Save As both change fileURL, and without this pasted
    /// images rendered as broken placeholders until the file was reopened —
    /// the PNG and the markdown link were both correct, only display failed.
    func noteDocumentURLChanged() {
        assetSchemeHandler.documentDirectory = document?.fileURL?.deletingLastPathComponent()
    }

    /// Pushes document content into the editor. Before the ready message this
    /// is a no-op: the surface pulls the authoritative text from the document
    /// via editorDidBecomeReady, so there is exactly one delivery path.
    func loadDocumentText(_ text: String) {
        // Keep the asset scheme pointed at the (possibly new) document folder.
        assetSchemeHandler.documentDirectory = document?.fileURL?.deletingLastPathComponent()
        guard isEditorReady else { return }
        applyStoredTheme()
        applyStoredViewSettings()
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

    /// Fetches [{level, text, pos}] headings for the outline sidebar.
    func fetchOutline(completion: @escaping ([MoltenHeading]) -> Void) {
        guard isEditorReady else {
            completion([])
            return
        }
        webView.evaluateJavaScript("window.moltenAPI.getOutline();") { result, _ in
            let rows = (result as? [[String: Any]]) ?? []
            completion(rows.compactMap { row in
                guard let text = row["text"] as? String,
                      let pos = row["pos"] as? Int else { return nil }
                return MoltenHeading(level: row["level"] as? Int ?? 1, text: text, pos: pos)
            })
        }
    }

    func scrollToHeading(pos: Int) {
        webView.evaluateJavaScript("window.moltenAPI.scrollToHeading(\(pos));")
    }

    /// Incremental in-page find; completion(false) when no match.
    func find(_ term: String, backwards: Bool, completion: @escaping (Bool) -> Void) {
        guard isEditorReady, !term.isEmpty else {
            completion(false)
            return
        }
        webView.callAsyncJavaScript(
            "return window.moltenAPI.find(term, backwards);",
            arguments: ["term": term, "backwards": backwards],
            in: nil,
            in: .page
        ) { result in
            if case .success(let value) = result {
                completion((value as? Bool) ?? false)
            } else {
                completion(false)
            }
        }
    }

    /// Total case-insensitive occurrences of `term` for the find-bar label.
    func countMatches(_ term: String, completion: @escaping (Int) -> Void) {
        guard isEditorReady, !term.isEmpty else {
            completion(0)
            return
        }
        webView.callAsyncJavaScript(
            "return window.moltenAPI.countMatches(term);",
            arguments: ["term": term],
            in: nil,
            in: .page
        ) { result in
            completion((try? result.get()) as? Int ?? 0)
        }
    }

    /// Collapses the lingering find-match selection (find bar dismissed).
    func clearFindSelection() {
        webView.evaluateJavaScript("window.moltenAPI?.clearFindSelection();")
    }

    /// The web view exposed for PDF/print snapshots.
    var webViewForExport: WKWebView { webView }

    /// Cleaned rendered HTML for export; nil while the editor isn't live.
    func fetchContentHTML(completion: @escaping (String?) -> Void) {
        guard isEditorReady else {
            completion(nil)
            return
        }
        webView.evaluateJavaScript("window.moltenAPI.getContentHTML();") { result, error in
            if let error {
                MoltenLog.editor.error("getContentHTML failed: \(error.localizedDescription, privacy: .public)")
                completion(nil)
                return
            }
            completion(result as? String)
        }
    }

    /// Replaces the selected match (if it equals `term`) and advances;
    /// completion(true) when a replacement happened.
    func replaceNext(_ term: String, with replacement: String, completion: @escaping (Bool) -> Void) {
        guard isEditorReady, !term.isEmpty else {
            completion(false)
            return
        }
        webView.callAsyncJavaScript(
            "return window.moltenAPI.replaceNext(term, replacement);",
            arguments: ["term": term, "replacement": replacement],
            in: nil,
            in: .page
        ) { result in
            completion((try? result.get()) as? Bool ?? false)
        }
    }

    /// Replaces every occurrence in one undoable transaction; completion
    /// receives the replacement count.
    func replaceAll(_ term: String, with replacement: String, completion: @escaping (Int) -> Void) {
        guard isEditorReady, !term.isEmpty else {
            completion(0)
            return
        }
        webView.callAsyncJavaScript(
            "return window.moltenAPI.replaceAll(term, replacement);",
            arguments: ["term": term, "replacement": replacement],
            in: nil,
            in: .page
        ) { result in
            completion((try? result.get()) as? Int ?? 0)
        }
    }

    /// Pushes the persisted editor theme into the surface.
    func applyStoredTheme() {
        let theme = UserDefaults.standard.string(forKey: "Vellumi.editorTheme") ?? "frame"
        webView.evaluateJavaScript("window.moltenAPI.setTheme('\(theme)');")
    }

    /// Pushes zoom + spellcheck + typewriter/focus modes into the surface.
    /// Called on every document load AND whenever a menu/preferences toggle
    /// broadcasts a change.
    func applyStoredViewSettings() {
        webView.pageZoom = MoltenViewSettings.zoom
        webView.evaluateJavaScript("window.moltenAPI?.setSpellcheck(\(MoltenViewSettings.spellcheck));")
        webView.evaluateJavaScript("window.moltenAPI?.setTypewriter(\(MoltenViewSettings.typewriter));")
        webView.evaluateJavaScript("window.moltenAPI?.setFocusMode(\(MoltenViewSettings.focusMode));")
        webView.evaluateJavaScript("window.moltenAPI?.setSmartPunctuation(\(MoltenViewSettings.smartPunctuation));")
        webView.callAsyncJavaScript(
            "window.moltenAPI?.setTypography(config);",
            arguments: ["config": [
                "scheme": MoltenViewSettings.fontScheme,
                "lineHeight": MoltenViewSettings.lineHeight,
                "paragraphSpacing": MoltenViewSettings.paragraphSpacing,
                "maxWidth": MoltenViewSettings.lineWidth,
            ]],
            in: nil,
            in: .page
        ) { _ in }
    }

    /// Current scroll position as a 0…1 fraction (source-mode round trips).
    func fetchScrollFraction(completion: @escaping (Double) -> Void) {
        webView.evaluateJavaScript("window.moltenAPI.getScrollFraction();") { result, _ in
            completion(result as? Double ?? 0)
        }
    }

    /// Applied after the next editor rebuild completes (or immediately).
    func setScrollFraction(_ fraction: Double) {
        webView.evaluateJavaScript("window.moltenAPI.setScrollFraction(\(fraction));")
    }

    // MARK: - Format menu → ProseMirror commands

    /// Menu item tags carry the heading level (0 = body text).
    @objc func applyHeading(_ sender: Any?) {
        let level = (sender as? NSMenuItem)?.tag ?? 0
        webView.evaluateJavaScript("window.moltenAPI.setHeading(\(level));")
    }

    @objc func toggleBold(_ sender: Any?) {
        webView.evaluateJavaScript("window.moltenAPI.toggleBold();")
    }

    @objc func toggleItalic(_ sender: Any?) {
        webView.evaluateJavaScript("window.moltenAPI.toggleItalic();")
    }

    @objc func toggleInlineCode(_ sender: Any?) {
        webView.evaluateJavaScript("window.moltenAPI.toggleInlineCode();")
    }

    @objc func toggleStrikethrough(_ sender: Any?) {
        webView.evaluateJavaScript("window.moltenAPI.toggleStrikethrough();")
    }

    @objc func toggleBlockquote(_ sender: Any?) {
        webView.evaluateJavaScript("window.moltenAPI.toggleBlockquote();")
    }

    @objc func toggleBulletList(_ sender: Any?) {
        webView.evaluateJavaScript("window.moltenAPI.toggleBulletList();")
    }

    @objc func toggleOrderedList(_ sender: Any?) {
        webView.evaluateJavaScript("window.moltenAPI.toggleOrderedList();")
    }

    @objc func insertHorizontalRule(_ sender: Any?) {
        webView.evaluateJavaScript("window.moltenAPI.insertHorizontalRule();")
    }

    @objc func toggleLink(_ sender: Any?) {
        webView.evaluateJavaScript("window.moltenAPI.toggleLink();")
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
        case "normalized":
            if let markdown = body["markdown"] as? String {
                document?.editorDidNormalize(markdown, changed: (body["changed"] as? Bool) == true)
            }
        case "boot-error":
            let detail = body["message"] as? String ?? "unknown"
            MoltenLog.editor.error("Editor surface failed to boot: \(detail, privacy: .public)")
        case "image-save":
            guard let id = body["id"] as? Int,
                  let name = body["name"] as? String,
                  let base64 = body["base64"] as? String else { return }
            let path = document?.saveImageAttachment(name: name, base64: base64)
            MoltenLog.editor.info("image-save id=\(id) → \(path ?? "nil", privacy: .public)")
            webView.callAsyncJavaScript(
                "window.moltenAPI.resolveImageSave(id, path);",
                arguments: ["id": id, "path": path ?? NSNull()],
                in: nil,
                in: .page
            ) { result in
                if case .failure(let error) = result {
                    MoltenLog.editor.error("resolveImageSave failed: \(error.localizedDescription, privacy: .public)")
                }
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
