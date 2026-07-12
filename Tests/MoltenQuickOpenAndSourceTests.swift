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
}
