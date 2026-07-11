import XCTest
@testable import Vellumi

final class MoltenFrontMatterTests: XCTestCase {
    /// The core contract: join(split(x)) == x, for every shape we support.
    private func assertRoundTrip(_ source: String, file: StaticString = #filePath, line: UInt = #line) {
        let parts = MoltenFrontMatter.split(source)
        XCTAssertEqual(
            MoltenFrontMatter.join(frontMatter: parts.frontMatter, body: parts.body),
            source,
            "split/join must be byte-faithful",
            file: file,
            line: line
        )
    }

    func testSplitSeparatesFrontMatterAndBody() {
        let source = "---\ntitle: 测试\ntags: [a, b]\n---\n\n# 正文\n\n段落。\n"
        let parts = MoltenFrontMatter.split(source)
        XCTAssertEqual(parts.frontMatter, "---\ntitle: 测试\ntags: [a, b]\n---\n")
        XCTAssertEqual(parts.body, "\n# 正文\n\n段落。\n", "body keeps its own leading blank line")
        assertRoundTrip(source)
    }

    func testCRLFFrontMatterIsRecognizedAndPreserved() {
        let source = "---\r\ntitle: windows\r\n---\r\n\r\n正文\r\n"
        let parts = MoltenFrontMatter.split(source)
        XCTAssertEqual(parts.frontMatter, "---\r\ntitle: windows\r\n---\r\n", "CRLF closer must terminate the block")
        XCTAssertTrue(parts.body.contains("正文"))
        assertRoundTrip(source)
    }

    func testNoBlankLineAfterFenceStaysFaithful() {
        // Hugo/Jekyll style: body starts immediately after the fence.
        let source = "---\ntitle: x\n---\nBody"
        let parts = MoltenFrontMatter.split(source)
        XCTAssertEqual(parts.frontMatter, "---\ntitle: x\n---\n")
        XCTAssertEqual(parts.body, "Body")
        assertRoundTrip(source)
    }

    func testFenceAtEOFWithoutTrailingNewline() {
        let source = "---\ntitle: x\n---"
        let parts = MoltenFrontMatter.split(source)
        XCTAssertEqual(parts.frontMatter, "---\ntitle: x\n---")
        XCTAssertEqual(parts.body, "")
        assertRoundTrip(source)
    }

    func testNoFrontMatterPassesThrough() {
        let source = "# 普通文档\n\n--- 不是开头的围栏\n"
        let parts = MoltenFrontMatter.split(source)
        XCTAssertEqual(parts.frontMatter, "")
        XCTAssertEqual(parts.body, source)
        assertRoundTrip(source)
    }

    func testUnterminatedFenceIsBody() {
        let source = "---\n没有闭合围栏的正文\n继续\n"
        let parts = MoltenFrontMatter.split(source)
        XCTAssertEqual(parts.frontMatter, "")
        XCTAssertEqual(parts.body, source)
        assertRoundTrip(source)
    }

    func testDotDotDotCloserAccepted() {
        let source = "---\nkey: value\n...\n正文\n"
        let parts = MoltenFrontMatter.split(source)
        XCTAssertEqual(parts.frontMatter, "---\nkey: value\n...\n")
        XCTAssertEqual(parts.body, "正文\n")
        assertRoundTrip(source)
    }

    @MainActor
    func testDocumentPreservesFrontMatterThroughEditCycle() throws {
        let document = MoltenDocument()
        let source = "---\ntitle: 保护测试\n---\n\n原始正文\n"
        try document.read(from: Data(source.utf8), ofType: MoltenDocument.markdownType)

        XCTAssertEqual(document.text, "\n原始正文\n", "editor sees only the body (with its own spacing)")
        document.editorTextDidChange("\n编辑后的正文\n")

        let written = String(data: try document.data(ofType: MoltenDocument.markdownType), encoding: .utf8)
        XCTAssertEqual(
            written,
            "---\ntitle: 保护测试\n---\n\n编辑后的正文\n",
            "front matter must survive byte-for-byte around the edited body"
        )
    }
}
