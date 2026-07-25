import WebKit
import XCTest
@testable import Vellumi

/// End-to-end bridge tests: load the REAL bundled editor (Crepe + ProseMirror)
/// into a WKWebView, drive it through the same moltenAPI the app uses, and pull
/// serializations back. Guards the whole melt-edit-serialize loop without UI
/// automation.
@MainActor
final class MoltenEditorBridgeTests: XCTestCase {
    private var webView: WKWebView!

    /// Mirrors MoltenEditorViewController.loadEditorPage — including the
    /// Resources-wide read access the app needs (subdirectory-scoped access
    /// breaks subresource loads under the sandbox).
    private func loadEditorPage() throws {
        let bundle = Bundle(for: MoltenDocument.self)
        let pageURL = try XCTUnwrap(
            bundle.url(forResource: "index", withExtension: "html", subdirectory: "dist"),
            "editor bundle must ship in app resources"
        )
        let resourcesURL = try XCTUnwrap(bundle.resourceURL)

        webView = WKWebView(frame: NSRect(origin: .zero, size: MoltenDocument.defaultContentSize))
        webView.loadFileURL(pageURL, allowingReadAccessTo: resourcesURL)

        // The surface posts ready immediately and builds the editor lazily on
        // the first setMarkdown, so readiness here = moltenAPI defined.
        try waitUntil("typeof window.moltenAPI?.getMarkdown === 'function'", description: "moltenAPI defined")
    }

    private func evaluate(_ script: String) throws -> Any? {
        var output: Any?
        var failure: Error?
        let done = expectation(description: "js")
        webView.evaluateJavaScript(script) { result, error in
            output = result
            failure = error
            done.fulfill()
        }
        wait(for: [done], timeout: 10)
        if let failure { throw failure }
        return output
    }

    /// Polls until the boolean JS expression is true, surfacing
    /// window.__moltenBootError in the failure message.
    private func waitUntil(_ expression: String, description: String, timeout: TimeInterval = 30) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let ok = try evaluate("window.__moltenBootError ? 'boot-error' : String(\(expression))") as? String {
                if ok == "true" { return }
                if ok == "boot-error" {
                    let detail = try evaluate("window.__moltenBootError") as? String ?? "unknown"
                    XCTFail("editor boot error while waiting for \(description): \(detail)")
                    return
                }
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        XCTFail("timed out waiting for \(description)")
    }

    /// Loads markdown through moltenAPI and waits for the editor rebuild.
    private func setMarkdown(_ markdown: String) throws {
        let literal = String(data: try JSONEncoder().encode([markdown]), encoding: .utf8)!
            .dropFirst().dropLast()
        _ = try evaluate("window.moltenAPI.setMarkdown(\(literal))")
        try waitUntil("document.querySelector('.milkdown') !== null && window.moltenAPI.getMarkdown() !== null", description: "editor built")
    }

    func testSetThenGetMarkdownRoundTrip() throws {
        try loadEditorPage()
        try setMarkdown("# Hello\n\nWorld **bold**.")

        let markdown = try XCTUnwrap(try evaluate("window.moltenAPI.getMarkdown()") as? String)
        XCTAssertTrue(markdown.contains("# Hello"), "heading must survive the round trip, got: \(markdown)")
        XCTAssertTrue(
            markdown.contains("**bold**") || markdown.contains("__bold__"),
            "bold must survive, got: \(markdown)"
        )
    }

    func testGetMarkdownReturnsNullBeforeFirstLoad() throws {
        try loadEditorPage()
        // No setMarkdown yet — the editor doesn't exist. getMarkdown must be
        // null (JS) → nil here, NEVER an empty string: a save in this window
        // once truncated the document to zero bytes.
        let result = try evaluate("window.moltenAPI.getMarkdown() === null")
        XCTAssertEqual(result as? Bool, true)
    }

    func testUndoRedoCommandsExist() throws {
        try loadEditorPage()
        try setMarkdown("undo target")
        // The native Edit menu forwards here; the calls must not throw.
        _ = try evaluate("window.moltenAPI.undo(); window.moltenAPI.redo(); 'ok'")
    }

    func testSetThemeSwapsStylesheetPair() throws {
        try loadEditorPage()
        _ = try evaluate("window.moltenAPI.setTheme('nord'); 'ok'")
        XCTAssertEqual(
            try evaluate("document.getElementById('theme-light').getAttribute('href')") as? String,
            "themes/nord-light.css"
        )
        XCTAssertEqual(
            try evaluate("document.getElementById('theme-dark').getAttribute('href')") as? String,
            "themes/nord-dark.css"
        )
        // Unknown names fall back to frame instead of 404ing the stylesheet.
        _ = try evaluate("window.moltenAPI.setTheme('bogus'); 'ok'")
        XCTAssertEqual(
            try evaluate("document.getElementById('theme-light').getAttribute('href')") as? String,
            "themes/frame-light.css"
        )
    }

    func testFormatCommandsRewriteMarkdown() throws {
        try loadEditorPage()
        try setMarkdown("hello world")

        // Block-level commands act on the caret's block (selection defaults to
        // document start) — no DOM focus needed headless.
        _ = try evaluate("window.moltenAPI.setHeading(2); 'ok'")
        var markdown = ""
        for _ in 0..<60 {
            markdown = (try evaluate("window.moltenAPI.getMarkdown()") as? String) ?? ""
            if markdown.contains("## hello world") { break }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertTrue(markdown.contains("## hello world"), "⌘2 must produce an H2, got: \(markdown)")

        _ = try evaluate("window.moltenAPI.setHeading(0); 'ok'")
        for _ in 0..<60 {
            markdown = (try evaluate("window.moltenAPI.getMarkdown()") as? String) ?? ""
            if !markdown.contains("##") { break }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertFalse(markdown.contains("##"), "⌘0 must return to body text, got: \(markdown)")
    }

    func testContentHTMLIsCleanForExport() throws {
        try loadEditorPage()
        try setMarkdown("# 标题\n\n段落 **粗** 文。\n\n![pic](assets/p.png)")

        let html = try XCTUnwrap(try evaluate("window.moltenAPI.getContentHTML()") as? String)
        XCTAssertTrue(html.contains("<h1"), "rendered heading expected, got: \(html.prefix(200))")
        XCTAssertTrue(html.contains("<strong>粗</strong>") || html.contains("<b>粗</b>"))
        XCTAssertFalse(html.contains("contenteditable"), "editing chrome must be stripped")
        XCTAssertFalse(html.contains("molten-asset://"), "asset scheme must be restored to relative paths")
        XCTAssertTrue(html.contains("assets/p.png"), "relative image path preserved, got: \(html.prefix(400))")
    }

    func testReplaceAllRewritesEveryOccurrenceInOneTransaction() throws {
        try loadEditorPage()
        try setMarkdown("foo bar foo\n\n## foo heading\n\nfoo **bold foo** end")

        let count = try XCTUnwrap(try evaluate("window.moltenAPI.replaceAll('foo', 'qux')") as? Int)
        XCTAssertEqual(count, 5)
        let markdown = try XCTUnwrap(try evaluate("window.moltenAPI.getMarkdown()") as? String)
        XCTAssertFalse(markdown.contains("foo"), "all occurrences replaced, got: \(markdown)")
        XCTAssertTrue(markdown.contains("qux bar qux"))
        XCTAssertTrue(markdown.contains("## qux heading"), "matches inside headings replaced too")
        XCTAssertTrue(markdown.contains("**bold qux**"), "inline formatting must survive replacement")

        // One transaction → one undo returns the whole document.
        _ = try evaluate("window.moltenAPI.undo(); 'ok'")
        let undone = try XCTUnwrap(try evaluate("window.moltenAPI.getMarkdown()") as? String)
        XCTAssertTrue(undone.contains("foo bar foo"), "replaceAll must undo as a single step, got: \(undone)")
    }

    func testReplaceAllWithNoMatchReturnsZero() throws {
        try loadEditorPage()
        try setMarkdown("nothing here")
        XCTAssertEqual(try evaluate("window.moltenAPI.replaceAll('absent', 'x')") as? Int, 0)
        XCTAssertEqual(try evaluate("window.moltenAPI.replaceAll('', 'x')") as? Int, 0)
    }

    func testImageNodeSurvivesSerialization() throws {
        try loadEditorPage()
        try setMarkdown("before\n\n![alt text](assets/pic.png)\n\nafter")
        let markdown = try XCTUnwrap(try evaluate("window.moltenAPI.getMarkdown()") as? String)
        XCTAssertTrue(
            markdown.contains("](assets/pic.png)"),
            "image node must survive load→serialize round trip, got: \(markdown)"
        )
        // Display-time src is rewritten to the asset scheme, but the MODEL keeps
        // the relative path (otherwise saves would leak molten-asset:// URLs).
        XCTAssertFalse(markdown.contains("molten-asset"), "scheme must not leak into markdown: \(markdown)")
    }

    func testAssetURLRewriteAndImageSaveResolution() throws {
        try loadEditorPage()

        // Relative srcs rewrite to the molten-asset scheme; absolute pass through.
        XCTAssertEqual(
            try evaluate("window.moltenAPI.rewriteAssetURL('assets/图 1.png')") as? String,
            "molten-asset://asset/assets/%E5%9B%BE%201.png"
        )
        XCTAssertEqual(
            try evaluate("window.moltenAPI.rewriteAssetURL('https://x.com/a.png')") as? String,
            "https://x.com/a.png"
        )
        XCTAssertEqual(
            try evaluate("window.moltenAPI.rewriteAssetURL('data:image/png;base64,AA==')") as? String,
            "data:image/png;base64,AA=="
        )

        // resolveImageSave with an unknown id must be a harmless no-op.
        _ = try evaluate("window.moltenAPI.resolveImageSave(9999, 'assets/x.png'); 'ok'")
    }

    func testOutlineExtractionScrollAndFind() throws {
        try loadEditorPage()
        try setMarkdown("# 一级\n\n正文 target 词。\n\n## 二级标题\n\n### 三级")

        // Outline: three headings with correct levels/texts, in document order.
        let summary = try XCTUnwrap(try evaluate(
            "window.moltenAPI.getOutline().map(h => h.level + ':' + h.text).join('|')"
        ) as? String)
        XCTAssertEqual(summary, "1:一级|2:二级标题|3:三级")

        // find() reports hit and miss correctly.
        XCTAssertEqual(try evaluate("window.moltenAPI.find('target', false)") as? Bool, true)
        XCTAssertEqual(try evaluate("window.moltenAPI.find('不存在的词', false)") as? Bool, false)

        // scrollToHeading with a real pos executes without throwing.
        _ = try evaluate("window.moltenAPI.scrollToHeading(window.moltenAPI.getOutline()[2].pos); 'ok'")
    }
    // MARK: - View modes / spellcheck / mermaid / footnotes

    func testFocusAndSpellcheckAPIsToggleDOMState() throws {
        try loadEditorPage()
        try setMarkdown("# 标题\n\n第一段。\n\n第二段。")

        _ = try evaluate("window.moltenAPI.setFocusMode(true)")
        let hasClass = try evaluate("document.body.classList.contains('vellumi-focus-mode')") as? Bool
        XCTAssertEqual(hasClass, true, "focus mode must tag <body>")
        _ = try evaluate("window.moltenAPI.setFocusMode(false)")
        let cleared = try evaluate("document.body.classList.contains('vellumi-focus-mode')") as? Bool
        XCTAssertEqual(cleared, false)

        _ = try evaluate("window.moltenAPI.setSpellcheck(true)")
        let spell = try evaluate("document.querySelector('.ProseMirror')?.getAttribute('spellcheck')") as? String
        XCTAssertEqual(spell, "true", "spellcheck attribute must land on the editing surface")
        _ = try evaluate("window.moltenAPI.setSpellcheck(false)")
        let spellOff = try evaluate("document.querySelector('.ProseMirror')?.getAttribute('spellcheck')") as? String
        XCTAssertEqual(spellOff, "false")

        XCTAssertNoThrow(try evaluate("window.moltenAPI.setTypewriter(true)"))
        XCTAssertNoThrow(try evaluate("window.moltenAPI.setTypewriter(false)"))
    }

    func testFootnoteSyntaxSurvivesRoundTrip() throws {
        try loadEditorPage()
        try setMarkdown("正文引用[^1]继续。\n\n[^1]: 脚注内容\n")

        let markdown = try XCTUnwrap(try evaluate("window.moltenAPI.getMarkdown()") as? String)
        XCTAssertTrue(markdown.contains("[^1]"), "footnote reference must not be mangled, got: \(markdown)")
        XCTAssertTrue(markdown.contains("[^1]: 脚注内容") || markdown.contains("[^1]:"), "footnote definition must survive, got: \(markdown)")
    }

    /// Mermaid needs requestAnimationFrame → park the web view in an offscreen
    /// window (rAF never fires window-less; same lesson as the card renderer).
    func testMermaidFenceRendersSVG() throws {
        try loadEditorPage()
        let window = NSWindow(
            contentRect: NSRect(x: -2000, y: -2000, width: 900, height: 700),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = webView
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }

        try setMarkdown("```mermaid\ngraph TD;\n  A-->B;\n```\n")
        try waitUntil(
            "document.querySelector('.vellumi-mermaid svg') !== null",
            description: "mermaid diagram rendered as SVG",
            timeout: 20
        )
        let markdown = try XCTUnwrap(try evaluate("window.moltenAPI.getMarkdown()") as? String)
        XCTAssertTrue(markdown.contains("mermaid"), "mermaid fence must survive serialization, got: \(markdown)")
        XCTAssertTrue(markdown.contains("A-->B") || markdown.contains("A --> B"), "diagram source must survive, got: \(markdown)")
    }

    // MARK: - Kernel polish batch

    func testEmojiShortcodeCompletes() throws {
        try loadEditorPage()
        try setMarkdown("")
        // Simulate typing the closing colon of :smile: through the input-rule
        // path: insert ":smile" then dispatch the final ":" as text input.
        _ = try evaluate("""
        (() => {
          const view = document.querySelector('.ProseMirror');
          view.focus();
          const sel = window.getSelection();
          document.execCommand('insertText', false, ':smile');
          document.execCommand('insertText', false, ':');
          return true;
        })()
        """)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let markdown = try XCTUnwrap(try evaluate("window.moltenAPI.getMarkdown()") as? String)
        XCTAssertTrue(markdown.contains("😄"), "emoji shortcode must complete, got: \(markdown)")
    }

    func testSmartPunctuationTogglesViaRebuild() throws {
        try loadEditorPage()
        try setMarkdown("正文")
        _ = try evaluate("window.moltenAPI.setSmartPunctuation(true)")
        try waitUntil(
            "window.moltenAPI.getMarkdown() !== null",
            description: "editor rebuilt after smart punctuation toggle"
        )
        _ = try evaluate("""
        (() => {
          document.querySelector('.ProseMirror').focus();
          document.execCommand('insertText', false, '..');
          document.execCommand('insertText', false, '.');
          return true;
        })()
        """)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let markdown = try XCTUnwrap(try evaluate("window.moltenAPI.getMarkdown()") as? String)
        XCTAssertTrue(markdown.contains("…"), "ellipsis rule must fire when enabled, got: \(markdown)")
    }

    func testCodeBlockLanguagesRegistered() throws {
        try loadEditorPage()
        let window = NSWindow(
            contentRect: NSRect(x: -2000, y: -2000, width: 900, height: 700),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = webView
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        try setMarkdown("```python\nprint(1)\n```\n")
        // The CodeMirror component must mount (guards against the
        // editorViewOptionsCtx.nodeViews clobbering bug that shipped plain
        // <pre> blocks) and the language registry must feed it.
        try waitUntil(
            "document.querySelector('.cm-editor, milkdown-code-block') !== null",
            description: "CodeMirror component mounted",
            timeout: 15
        )
        // The searchable picker is fed from the configured LanguageDescription
        // list; the fence language must round-trip either way.
        let markdown = try XCTUnwrap(try evaluate("window.moltenAPI.getMarkdown()") as? String)
        XCTAssertTrue(markdown.contains("```python"), "language tag must survive, got: \(markdown)")
    }

    func testTypographyAPISetsCSSVariables() throws {
        try loadEditorPage()
        try setMarkdown("正文")
        _ = try evaluate("""
        window.moltenAPI.setTypography({scheme: 'sans', lineHeight: 1.8, paragraphSpacing: 1.2, maxWidth: 900})
        """)
        let font = try evaluate("document.documentElement.getAttribute('data-vellumi-font')") as? String
        XCTAssertEqual(font, "sans")
        let lineHeight = try evaluate("document.documentElement.style.getPropertyValue('--vellumi-line-height')") as? String
        XCTAssertEqual(lineHeight, "1.8")
        // Reset: 0 / "default" clears everything back to theme values.
        _ = try evaluate("window.moltenAPI.setTypography({scheme: 'default', lineHeight: 0, paragraphSpacing: 0, maxWidth: 0})")
        let cleared = try evaluate("document.documentElement.hasAttribute('data-vellumi-font')") as? Bool
        XCTAssertEqual(cleared, false)
    }

    func testScrollFractionRoundTrip() throws {
        try loadEditorPage()
        // applyPendingScroll runs inside requestAnimationFrame, which never
        // fires in a window-less web view — park it offscreen (same lesson as
        // the card renderer and mermaid tests).
        let window = NSWindow(
            contentRect: NSRect(x: -2000, y: -2000, width: 900, height: 700),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = webView
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        try setMarkdown(Array(repeating: "段落内容", count: 300).enumerated().map { "第\($0.offset)段 \($0.element)" }.joined(separator: "\n\n"))
        _ = try evaluate("window.moltenAPI.setScrollFraction(0.5)")
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let fraction = try XCTUnwrap(try evaluate("window.moltenAPI.getScrollFraction()") as? Double)
        XCTAssertEqual(fraction, 0.5, accuracy: 0.1, "scroll fraction must round-trip")
    }

    /// Export fidelity. Every one of these three shipped broken in v0.4.2:
    /// rendered code blocks were deleted entirely by the scaffolding sweep, a
    /// table containing an image was replaced BY that image, and task-list
    /// checkbox state was dropped (Crepe draws an SVG, not an <input>).
    func testExportPreservesCodeTablesAndTaskState() throws {
        try loadEditorPage()
        // Code blocks only mount their CodeMirror view in a real window.
        let window = NSWindow(
            contentRect: NSRect(x: -2000, y: -2000, width: 900, height: 900),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.contentView = webView
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }

        try setMarkdown("""
        ```python
        print(1)
        ```

        | A | B |
        | - | - |
        | ![img](x.png) | cell text |

        - [x] done item
        - [ ] todo item
        """)
        RunLoop.main.run(until: Date().addingTimeInterval(2))

        let html = try XCTUnwrap(try evaluate("window.moltenAPI.getContentHTML()") as? String)

        XCTAssertTrue(html.contains("<pre>"), "code block must survive as <pre>, got: \(html.prefix(400))")
        XCTAssertTrue(html.contains("print(1)"), "code text must survive, got: \(html.prefix(400))")
        XCTAssertTrue(html.contains("language-python"), "language tag must survive, got: \(html.prefix(400))")

        XCTAssertTrue(html.contains("<table"), "table must survive, got: \(html.prefix(600))")
        XCTAssertTrue(html.contains("cell text"), "other cells must survive alongside the image, got: \(html.prefix(600))")
        XCTAssertFalse(html.contains("drag-preview"), "the drag ghost must not ship in the export")

        XCTAssertTrue(html.contains("checkbox"), "task list must export checkboxes, got: \(html.prefix(600))")
        XCTAssertTrue(html.contains("checked"), "checked state must survive")
    }

    /// Find, the match count, Replace and Replace All must agree on case.
    func testReplaceIsCaseInsensitiveLikeFind() throws {
        try loadEditorPage()
        try setMarkdown("Hello world. HELLO again. hello once more.")

        let count = try XCTUnwrap(try evaluate("window.moltenAPI.countMatches('hello')") as? Int)
        XCTAssertEqual(count, 3, "the label counts case-insensitively")

        let replaced = try XCTUnwrap(try evaluate("window.moltenAPI.replaceAll('hello', 'HI')") as? Int)
        XCTAssertEqual(replaced, 3, "Replace All must match what the label promised")

        let markdown = try XCTUnwrap(try evaluate("window.moltenAPI.getMarkdown()") as? String)
        XCTAssertFalse(markdown.lowercased().contains("hello"), "no occurrence may remain, got: \(markdown)")
    }

}
