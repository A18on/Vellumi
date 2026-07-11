import XCTest
@testable import Vellumi

@MainActor
final class MoltenDocumentTests: XCTestCase {
    func testReadWriteRoundTripPreservesUTF8Content() throws {
        let document = MoltenDocument()
        let source = "# 标题\n\n熔字 **bold** 表情 🔥 and English.\n"
        try document.read(from: Data(source.utf8), ofType: MoltenDocument.markdownType)
        XCTAssertEqual(document.text, source)

        let written = try document.data(ofType: MoltenDocument.markdownType)
        XCTAssertEqual(String(data: written, encoding: .utf8), source)
    }

    func testReadDecodesBOMIdentifiedUTF16() throws {
        let document = MoltenDocument()
        let source = "# UTF-16 文档\n"
        let data = source.data(using: .utf16)! // includes BOM
        try document.read(from: data, ofType: MoltenDocument.markdownType)
        XCTAssertEqual(document.text, source, "BOM-identified UTF-16 is deterministic, not a guess — it must open")
    }

    func testReadStripsUTF8BOM() throws {
        let document = MoltenDocument()
        var data = Data([0xEF, 0xBB, 0xBF])
        data.append(Data("# BOM'd\n".utf8))
        try document.read(from: data, ofType: MoltenDocument.markdownType)
        XCTAssertEqual(document.text, "# BOM'd\n")
    }

    func testReadRejectsNonUTF8InsteadOfGuessing() {
        let document = MoltenDocument()
        let latin1 = Data([0x63, 0x61, 0x66, 0xE9]) // "café" in Latin-1, invalid UTF-8
        XCTAssertThrowsError(try document.read(from: latin1, ofType: MoltenDocument.markdownType)) { error in
            XCTAssertEqual((error as NSError).code, NSFileReadInapplicableStringEncodingError)
        }
        XCTAssertEqual(document.text, "", "a failed open must not leave partial content behind")
    }

    func testReadRejectsOversizedFiles() {
        let document = MoltenDocument()
        let huge = Data(count: MoltenDocument.maximumFileSize + 1)
        XCTAssertThrowsError(try document.read(from: huge, ofType: MoltenDocument.markdownType)) { error in
            XCTAssertEqual((error as NSError).code, NSFileReadTooLargeError)
        }
    }

    func testEditorChangeUpdatesTextAndDirtiesDocument() throws {
        let document = MoltenDocument()
        try document.read(from: Data("old".utf8), ofType: MoltenDocument.markdownType)
        XCTAssertFalse(document.isDocumentEdited)

        document.editorTextDidChange("new content")
        XCTAssertEqual(document.text, "new content")
        XCTAssertTrue(document.isDocumentEdited)
    }

    func testUndoBackToSavedContentClearsDirtyFlag() throws {
        let document = MoltenDocument()
        try document.read(from: Data("saved state".utf8), ofType: MoltenDocument.markdownType)

        document.editorTextDidChange("saved state edited")
        XCTAssertTrue(document.isDocumentEdited)

        // In-editor undo restores the exact saved serialization.
        document.editorTextDidChange("saved state")
        XCTAssertFalse(
            document.isDocumentEdited,
            "returning to the saved content must clear the dirty flag, not leave the doc forever Edited"
        )
    }

    func testIdenticalEditorChangeDoesNotDirtyDocument() throws {
        let document = MoltenDocument()
        try document.read(from: Data("same".utf8), ofType: MoltenDocument.markdownType)
        document.editorTextDidChange("same")
        XCTAssertFalse(document.isDocumentEdited, "echoed identical content must not mark the document edited")
    }
}
