import XCTest
@testable import Molten

@MainActor
final class MoltenDocumentTests: XCTestCase {
    private func makeDocument() -> MoltenDocument {
        MoltenDocument()
    }

    func testReadWriteRoundTripPreservesUTF8Content() throws {
        let document = makeDocument()
        let source = "# 标题\n\n熔字 **bold** 表情 🔥 and English.\n"
        try document.read(from: Data(source.utf8), ofType: MoltenDocument.markdownType)
        XCTAssertEqual(document.text, source)

        let written = try document.data(ofType: MoltenDocument.markdownType)
        XCTAssertEqual(String(data: written, encoding: .utf8), source)
    }

    func testReadRejectsNonUTF8InsteadOfGuessing() {
        let document = makeDocument()
        let latin1 = Data([0x63, 0x61, 0x66, 0xE9]) // "café" in Latin-1, invalid UTF-8
        XCTAssertThrowsError(try document.read(from: latin1, ofType: MoltenDocument.markdownType)) { error in
            XCTAssertEqual((error as NSError).code, NSFileReadInapplicableStringEncodingError)
        }
        XCTAssertEqual(document.text, "", "a failed open must not leave partial content behind")
    }

    func testReadRejectsOversizedFiles() {
        let document = makeDocument()
        let huge = Data(count: MoltenDocument.maximumFileSize + 1)
        XCTAssertThrowsError(try document.read(from: huge, ofType: MoltenDocument.markdownType)) { error in
            XCTAssertEqual((error as NSError).code, NSFileReadTooLargeError)
        }
    }

    func testEditorChangeUpdatesTextAndDirtiesDocument() throws {
        let document = makeDocument()
        try document.read(from: Data("old".utf8), ofType: MoltenDocument.markdownType)
        XCTAssertFalse(document.isDocumentEdited)

        document.editorTextDidChange("new content")
        XCTAssertEqual(document.text, "new content")
        XCTAssertTrue(document.isDocumentEdited)
    }

    func testIdenticalEditorChangeDoesNotDirtyDocument() throws {
        let document = makeDocument()
        try document.read(from: Data("same".utf8), ofType: MoltenDocument.markdownType)
        document.editorTextDidChange("same")
        XCTAssertFalse(document.isDocumentEdited, "echoed identical content must not mark the document edited")
    }
}

final class JavaScriptStringLiteralTests: XCTestCase {
    func testEscapesQuotesNewlinesAndUnicode() {
        let literal = "a\"b\\c\nd\u{2028}е🔥".javaScriptStringLiteral
        XCTAssertTrue(literal.hasPrefix("\""))
        XCTAssertTrue(literal.hasSuffix("\""))
        XCTAssertFalse(literal.dropFirst().dropLast().contains("\n"), "raw newlines would break the injected script")
    }

    func testRoundTripsThroughJSONDecoding() throws {
        let original = "line1\nline2 \"quoted\" 中文 </script>"
        let literal = original.javaScriptStringLiteral
        let decoded = try JSONDecoder().decode([String].self, from: Data("[\(literal)]".utf8))
        XCTAssertEqual(decoded, [original])
    }
}
