import XCTest
@testable import Molten

final class MoltenFrontMatterTests: XCTestCase {
    func testSplitAndJoinRoundTripsExactly() {
        let source = "---\ntitle: 测试\ntags: [a, b]\n---\n\n# 正文\n\n段落。\n"
        let parts = MoltenFrontMatter.split(source)
        XCTAssertEqual(parts.frontMatter, "---\ntitle: 测试\ntags: [a, b]\n---\n")
        XCTAssertEqual(parts.body, "# 正文\n\n段落。\n")
        XCTAssertEqual(MoltenFrontMatter.join(frontMatter: parts.frontMatter, body: parts.body), source)
    }

    func testNoFrontMatterPassesThrough() {
        let source = "# 普通文档\n\n--- 不是开头的围栏\n"
        let parts = MoltenFrontMatter.split(source)
        XCTAssertEqual(parts.frontMatter, "")
        XCTAssertEqual(parts.body, source)
    }

    func testThematicBreakMidDocumentIsNotFrontMatter() {
        // A document STARTING with a thematic break is indistinguishable from
        // an empty front-matter fence only if a closer exists; "---" followed
        // by regular text and never closed stays body.
        let source = "---\n没有闭合围栏的正文\n继续\n"
        let parts = MoltenFrontMatter.split(source)
        XCTAssertEqual(parts.frontMatter, "")
        XCTAssertEqual(parts.body, source)
    }

    func testDotDotDotCloserAccepted() {
        let source = "---\nkey: value\n...\n正文\n"
        let parts = MoltenFrontMatter.split(source)
        XCTAssertEqual(parts.frontMatter, "---\nkey: value\n...\n")
        XCTAssertEqual(parts.body, "正文\n")
    }

    @MainActor
    func testDocumentPreservesFrontMatterThroughEditCycle() throws {
        let document = MoltenDocument()
        let source = "---\ntitle: 保护测试\n---\n\n原始正文\n"
        try document.read(from: Data(source.utf8), ofType: MoltenDocument.markdownType)

        XCTAssertEqual(document.text, "原始正文\n", "editor must only see the body")
        document.editorTextDidChange("编辑后的正文\n")

        let written = String(data: try document.data(ofType: MoltenDocument.markdownType), encoding: .utf8)
        XCTAssertEqual(
            written,
            "---\ntitle: 保护测试\n---\n\n编辑后的正文\n",
            "front matter must survive byte-for-byte around the edited body"
        )
    }
}
