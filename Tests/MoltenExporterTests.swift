import XCTest
@testable import Vellumi

@MainActor
final class MoltenExporterTests: XCTestCase {
    func testSelfContainedHTMLInlinesThemeAndEscapesTitle() {
        let page = MoltenExporter.selfContainedHTML(
            bodyHTML: "<h1>你好</h1><p>body</p>",
            title: "A & B <doc>"
        )
        XCTAssertTrue(page.contains("<h1>你好</h1>"))
        XCTAssertTrue(page.contains("<title>A &amp; B &lt;doc></title>"), "title must be HTML-escaped")
        XCTAssertTrue(page.contains("<style>"), "theme CSS must be inlined")
        // The bundled editor stylesheet defines the milkdown class rules.
        XCTAssertTrue(page.contains("milkdown"), "page must carry the theme's selectors")
        // BOTH stylesheets must inline — the frame theme defines --crepe vars.
        XCTAssertTrue(page.contains("--crepe"), "frame theme variables must be inlined")
        XCTAssertFalse(page.contains("molten-asset"), "no app-private schemes in exported files")
    }

    func testExportBaseNameFallsBackSafely() {
        let document = MoltenDocument()
        XCTAssertFalse(document.exportBaseName.isEmpty)
    }
}
