import WebKit
import XCTest
@testable import Molten

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
}
