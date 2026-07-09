import WebKit
import XCTest
@testable import Molten

/// End-to-end card renderer test: real Crepe content HTML → real card.html →
/// assert the paginated card actually CONTAINS the text (guards against the
/// blank-card class of failures). Uses pure polling — no message handlers —
/// so it can't deadlock against other WKWebView tests' expectations.
@MainActor
final class MoltenImageCardRenderTests: XCTestCase {
    private func evaluate(_ webView: WKWebView, _ script: String) throws -> Any? {
        var output: Any?
        var failure: Error?
        var finished = false
        webView.evaluateJavaScript(script) { result, error in
            output = result
            failure = error
            finished = true
        }
        let deadline = Date().addingTimeInterval(10)
        while !finished && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        if let failure { throw failure }
        return output
    }

    private func poll(_ webView: WKWebView, until expression: String, timeout: TimeInterval, what: String) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if (try? evaluate(webView, expression)) as? Bool == true { return }
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        XCTFail("timed out waiting for \(what)")
    }

    func testRealEditorContentRendersVisibleTextInCards() throws {
        // Passes standalone in seconds, but in the FULL suite the accumulated
        // WKWebViews from earlier tests starve this one's callbacks (10-minute
        // stall). Run explicitly:
        //   MOLTEN_E2E=1 xcodebuild … -only-testing:MoltenTests/MoltenImageCardRenderTests test
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["MOLTEN_E2E"] == "1",
            "resource-heavy E2E; run standalone with MOLTEN_E2E=1"
        )
        let bundle = Bundle(for: MoltenDocument.self)

        // 1. Real Crepe content HTML.
        let editorURL = try XCTUnwrap(bundle.url(forResource: "index", withExtension: "html", subdirectory: "dist"))
        let editorView = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
        editorView.loadFileURL(editorURL, allowingReadAccessTo: try XCTUnwrap(bundle.resourceURL))
        try poll(editorView, until: "typeof window.moltenAPI?.setMarkdown === 'function'", timeout: 20, what: "editor boot")

        _ = try evaluate(editorView, "window.moltenAPI.setMarkdown('# 甲标题\\n\\n段落文字内容。\\n\\n## 乙标题\\n\\n- 列表一\\n- 列表二')")
        try poll(
            editorView,
            until: "(window.moltenAPI.getContentHTML() || '').includes('甲标题')",
            timeout: 15,
            what: "editor content"
        )
        let bodyHTML = try XCTUnwrap(try evaluate(editorView, "window.moltenAPI.getContentHTML()") as? String)

        // 2. Feed the card renderer exactly as the export model does. No
        //    message handler needed: card.html posts through optional chains.
        let cardURL = try XCTUnwrap(bundle.url(forResource: "card", withExtension: "html", subdirectory: "imagecard"))
        let cardView = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
        cardView.loadFileURL(cardURL, allowingReadAccessTo: try XCTUnwrap(bundle.resourceURL))
        try poll(cardView, until: "typeof window.markmacCard?.setContent === 'function'", timeout: 20, what: "card boot")

        _ = try evaluate(cardView, "window.markmacCard.setContent(\(bodyHTML.javaScriptStringLiteral)); true")
        _ = try evaluate(
            cardView,
            "window.markmacCard.setOptions({theme:'aurora',size:{width:1080,height:1920},watermark:'',format:'png',paragraphIndent:'2em',preservePage:false}); true"
        )

        // 3. The visible card must come to contain the document text.
        try poll(
            cardView,
            until: "document.body.innerText.includes('甲标题') && document.body.innerText.includes('段落文字内容')",
            timeout: 30,
            what: "card page text (blank-card regression)"
        )
    }
}
