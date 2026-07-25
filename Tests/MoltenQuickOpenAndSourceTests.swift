import XCTest
@testable import Vellumi

final class MoltenFuzzyMatchTests: XCTestCase {
    func testSubsequenceMatchesAndOrdering() {
        // Word-boundary hits beat scattered hits.
        let boundary = MoltenFuzzyMatch.score(query: "rn", candidate: "release-notes.md")
        let scattered = MoltenFuzzyMatch.score(query: "rn", candidate: "warning.md")
        XCTAssertNotNil(boundary)
        XCTAssertNotNil(scattered)
        XCTAssertGreaterThan(boundary!, scattered!)
    }

    func testNonMatchReturnsNil() {
        XCTAssertNil(MoltenFuzzyMatch.score(query: "xyz", candidate: "notes.md"))
        XCTAssertNil(MoltenFuzzyMatch.score(query: "toolong", candidate: "no.md"))
    }

    func testEmptyQueryMatchesEverything() {
        XCTAssertEqual(MoltenFuzzyMatch.score(query: "", candidate: "anything.md"), 0)
    }

    func testChineseFilenames() {
        XCTAssertNotNil(MoltenFuzzyMatch.score(query: "第一", candidate: "第一章草稿.md"))
        XCTAssertNil(MoltenFuzzyMatch.score(query: "第二", candidate: "第一章草稿.md"))
    }
}

@MainActor
final class MoltenSourceModeDocumentTests: XCTestCase {
    func testAdoptSourceTextResplitsFrontMatter() throws {
        let document = MoltenDocument()
        try document.read(from: Data("---\ntitle: a\n---\n正文\n".utf8), ofType: MoltenDocument.markdownType)

        // Source edit rewrites BOTH front matter and body.
        document.adoptSourceText("---\ntitle: b\nnew: field\n---\n新正文\n")
        XCTAssertEqual(document.frontMatter, "---\ntitle: b\nnew: field\n---\n")
        XCTAssertEqual(document.text, "新正文\n")

        let written = String(data: try document.data(ofType: MoltenDocument.markdownType), encoding: .utf8)
        XCTAssertEqual(written, "---\ntitle: b\nnew: field\n---\n新正文\n")
    }

    func testAdoptSourceTextCanRemoveFrontMatter() throws {
        let document = MoltenDocument()
        try document.read(from: Data("---\ntitle: a\n---\n正文\n".utf8), ofType: MoltenDocument.markdownType)

        document.adoptSourceText("只剩正文\n")
        XCTAssertEqual(document.frontMatter, "")
        XCTAssertEqual(document.text, "只剩正文\n")
    }

    func testFullSourceTextJoinsBothParts() throws {
        let document = MoltenDocument()
        let source = "---\ntitle: t\n---\n\nbody\n"
        try document.read(from: Data(source.utf8), ofType: MoltenDocument.markdownType)
        XCTAssertEqual(document.fullSourceText, source)
    }

    func testSetFrontMatterMarksDocumentDirty() throws {
        let document = MoltenDocument()
        try document.read(from: Data("正文\n".utf8), ofType: MoltenDocument.markdownType)
        XCTAssertFalse(document.isDocumentEdited)

        document.setFrontMatter("---\ntitle: 新增\n---\n")
        XCTAssertTrue(document.isDocumentEdited)
        let written = String(data: try document.data(ofType: MoltenDocument.markdownType), encoding: .utf8)
        XCTAssertEqual(written, "---\ntitle: 新增\n---\n正文\n")
    }
    /// Regression: the source-mode guard was briefly placed on the shared
    /// mutation method instead of the bridge entry point, which silently
    /// dropped EVERY source-mode keystroke — the existing tests missed it
    /// because none of them set sourceModeActive.
    func testSourceModeKeystrokesReachTheModelWhileActive() throws {
        let document = MoltenDocument()
        try document.read(from: Data("原始正文\n".utf8), ofType: MoltenDocument.markdownType)
        document.sourceModeActive = true

        document.adoptSourceText("源码模式输入\n")

        XCTAssertEqual(document.text, "源码模式输入\n", "the source view is authoritative while it is showing")
        XCTAssertTrue(document.isDocumentEdited)
    }

    /// The stale web editor must NOT be able to write back while source mode
    /// is on (external-change reload used to do exactly this).
    func testBridgeChangesAreIgnoredWhileSourceModeIsActive() throws {
        let document = MoltenDocument()
        try document.read(from: Data("原始正文\n".utf8), ofType: MoltenDocument.markdownType)
        document.sourceModeActive = true
        document.adoptSourceText("源码模式输入\n")

        document.editorTextDidChange("来自停摆编辑器的旧内容\n")

        XCTAssertEqual(document.text, "源码模式输入\n", "parked editor content must not win")
    }

    /// A7: a document whose Markdown merely got normalized on load must stay
    /// clean, or autosave-in-place rewrites a file the user only opened.
    func testNormalizationBaselineKeepsUntouchedDocumentClean() throws {
        let document = MoltenDocument()
        try document.read(from: Data("* 非规范列表\n".utf8), ofType: MoltenDocument.markdownType)
        XCTAssertFalse(document.isDocumentEdited)

        // What the editor reports after Crepe canonicalizes the source.
        document.editorDidNormalize("- 非规范列表\n", changed: true)

        XCTAssertFalse(document.isDocumentEdited, "normalization alone must never dirty the document")
        XCTAssertEqual(document.text, "- 非规范列表\n")

        // And a real edit afterwards still dirties normally.
        document.editorTextDidChange("- 非规范列表\n- 新增\n")
        XCTAssertTrue(document.isDocumentEdited)
    }

    /// A7 guard: normalization arriving on an ALREADY dirty document (exiting
    /// source mode rebuilds the editor) must not clear real unsaved edits.
    func testNormalizationDoesNotClearPendingEdits() throws {
        let document = MoltenDocument()
        try document.read(from: Data("正文\n".utf8), ofType: MoltenDocument.markdownType)
        document.editorTextDidChange("正文加了一句\n")
        XCTAssertTrue(document.isDocumentEdited)

        document.editorDidNormalize("正文加了一句\n", changed: false)

        XCTAssertTrue(document.isDocumentEdited, "pending edits must survive an editor rebuild")
    }

    /// A8: front-matter-only edits used to leave the document clean, so ⌘S
    /// wrote nothing and the YAML change was discarded on close.
    func testFrontMatterOnlyEditMarksDocumentDirtyAndPersists() throws {
        let document = MoltenDocument()
        try document.read(from: Data("---\ntitle: 旧\n---\n正文\n".utf8), ofType: MoltenDocument.markdownType)
        XCTAssertFalse(document.isDocumentEdited)
        document.sourceModeActive = true

        // Body byte-identical, only the YAML value differs.
        document.adoptSourceText("---\ntitle: 新\n---\n正文\n")

        XCTAssertTrue(document.isDocumentEdited, "a YAML-only edit is still an edit")
        let written = String(data: try document.data(ofType: MoltenDocument.markdownType), encoding: .utf8)
        XCTAssertEqual(written, "---\ntitle: 新\n---\n正文\n")
    }

    /// A8 second path: the sheet marks dirty, then an in-editor undo back to
    /// the saved BODY must not clear the flag while the YAML still differs.
    func testUndoToSavedBodyKeepsDirtyWhenFrontMatterStillDiffers() throws {
        let document = MoltenDocument()
        try document.read(from: Data("---\ntitle: 旧\n---\n正文\n".utf8), ofType: MoltenDocument.markdownType)

        document.setFrontMatter("---\ntitle: 新\n---\n")
        XCTAssertTrue(document.isDocumentEdited)

        document.editorTextDidChange("正文改了\n")
        document.editorTextDidChange("正文\n") // undo back to the saved body

        XCTAssertTrue(document.isDocumentEdited, "front matter still differs from disk")
    }

}
