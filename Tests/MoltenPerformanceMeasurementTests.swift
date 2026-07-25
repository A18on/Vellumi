import WebKit
import XCTest
@testable import Vellumi

/// Load-bearing measurement, not an assertion suite: how does the real editor
/// behave on documents far larger than anything tested during development?
/// Numbers print to the test log; the assertions only catch catastrophic
/// regressions (an order of magnitude), not normal machine variance.
@MainActor
final class MoltenPerformanceMeasurementTests: XCTestCase {
    private var webView: WKWebView!
    private var window: NSWindow!

    private func boot() throws {
        let bundle = Bundle(for: MoltenDocument.self)
        let pageURL = try XCTUnwrap(bundle.url(forResource: "index", withExtension: "html", subdirectory: "dist"))
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
        // rAF only fires in a windowed web view (hard-won lesson).
        window = NSWindow(
            contentRect: NSRect(x: -3000, y: -3000, width: 900, height: 700),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.contentView = webView
        window.orderFrontRegardless()
        webView.loadFileURL(pageURL, allowingReadAccessTo: try XCTUnwrap(bundle.resourceURL))
        try waitUntil("typeof window.moltenAPI?.getMarkdown === 'function'", what: "boot")
    }

    override func tearDown() {
        window?.orderOut(nil)
        webView = nil
        window = nil
        super.tearDown()
    }

    @discardableResult
    private func evaluate(_ script: String, timeout: TimeInterval = 120) throws -> Any? {
        var output: Any?
        var failure: Error?
        let done = expectation(description: "js")
        webView.evaluateJavaScript(script) { result, error in
            output = result
            failure = error
            done.fulfill()
        }
        wait(for: [done], timeout: timeout)
        if let failure { throw failure }
        return output
    }

    private func waitUntil(_ expression: String, what: String, timeout: TimeInterval = 180) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let ok = try evaluate("String(\(expression))") as? String, ok == "true" { return }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        XCTFail("timed out waiting for \(what)")
    }

    /// Representative long-form Chinese document: headings, paragraphs, lists,
    /// code, and a table — the shapes a novelist or note-taker actually writes.
    private func makeDocument(paragraphs: Int) -> String {
        var lines: [String] = []
        for index in 0..<paragraphs {
            if index % 20 == 0 { lines.append("## 第 \(index / 20 + 1) 节\n") }
            lines.append("这是第 \(index) 段正文,用来模拟真实的中文长文写作场景,包含**加粗**与`行内代码`以及[链接](https://example.com)。\n")
            if index % 25 == 12 {
                lines.append("- 列表项 A\n- 列表项 B\n- 列表项 C\n")
            }
            if index % 50 == 30 {
                lines.append("```swift\nlet value = compute(\(index))\nprint(value)\n```\n")
            }
        }
        return lines.joined(separator: "\n")
    }

    func testLargeDocumentEditingCost() throws {
        try boot()
        for paragraphs in [200, 1000, 3000] {
            let markdown = makeDocument(paragraphs: paragraphs)
            let lineCount = markdown.components(separatedBy: "\n").count
            let literal = String(data: try JSONEncoder().encode([markdown]), encoding: .utf8)!
                .dropFirst().dropLast()

            let loadStart = Date()
            _ = try evaluate("window.moltenAPI.setMarkdown(\(literal))")
            try waitUntil("window.moltenAPI.getMarkdown() !== null", what: "editor built (\(lineCount) lines)")
            let loadMS = Date().timeIntervalSince(loadStart) * 1000

            // Serialization is what runs on EVERY debounce flush while typing.
            let serializeMS = try XCTUnwrap(try evaluate("""
            (() => {
              const t0 = performance.now();
              for (let i = 0; i < 5; i += 1) window.moltenAPI.getMarkdown();
              return (performance.now() - t0) / 5;
            })()
            """) as? Double)

            // Outline extraction runs whenever the sidebar is visible.
            let outlineMS = try XCTUnwrap(try evaluate("""
            (() => {
              const t0 = performance.now();
              for (let i = 0; i < 5; i += 1) window.moltenAPI.getOutline();
              return (performance.now() - t0) / 5;
            })()
            """) as? Double)

            // Swift-side word count, the other per-change cost.
            let countStart = Date()
            _ = MoltenWordCount.count(markdown)
            let countMS = Date().timeIntervalSince(countStart) * 1000

            let bytes = markdown.utf8.count
            print(String(
                format: "PERF | %5d 行 | %6.1f KB | 打开 %7.0f ms | 序列化 %6.1f ms | 大纲 %5.1f ms | 字数 %5.1f ms",
                lineCount, Double(bytes) / 1024, loadMS, serializeMS, outlineMS, countMS
            ))

            // Only a catastrophic regression should fail the suite.
            XCTAssertLessThan(serializeMS, 2000, "serialization must stay under 2s even on large documents")
        }
    }
}
