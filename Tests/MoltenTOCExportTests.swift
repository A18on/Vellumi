import XCTest
@testable import Vellumi

@MainActor
final class MoltenTOCExportTests: XCTestCase {
    func testTOCParagraphExpandsToNavWithAnchors() {
        let body = "<p>[toc]</p><h1>第一章</h1><p>x</p><h2>第二节</h2><h1>Second Chapter</h1>"
        let out = MoltenExporter.expandTOC(in: body)
        XCTAssertTrue(out.contains("<nav class=\"vellumi-toc\">"), "nav must replace [toc], got: \(out)")
        XCTAssertFalse(out.contains("<p>[toc]</p>"))
        XCTAssertTrue(out.contains("<h1 id=\"第一章\">"), "heading gets slug id, got: \(out)")
        XCTAssertTrue(out.contains("href=\"#第一章\""))
        XCTAssertTrue(out.contains("<h1 id=\"second-chapter\">"), "latin slugs lowercase-hyphenated, got: \(out)")
    }

    func testDuplicateHeadingsGetUniqueSlugs() {
        let body = "<p>[toc]</p><h1>重复</h1><h1>重复</h1>"
        let out = MoltenExporter.expandTOC(in: body)
        XCTAssertTrue(out.contains("id=\"重复\""))
        XCTAssertTrue(out.contains("id=\"重复-2\""))
    }

    func testNoTOCMarkerLeavesBodyUntouchedExceptIds() {
        let body = "<h1>标题</h1><p>正文</p>"
        let out = MoltenExporter.expandTOC(in: body)
        XCTAssertFalse(out.contains("vellumi-toc"))
        XCTAssertTrue(out.contains("正文"))
    }
}
