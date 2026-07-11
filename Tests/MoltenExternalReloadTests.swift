import XCTest
@testable import Vellumi

@MainActor
final class MoltenExternalReloadTests: XCTestCase {
    private var fileURL: URL!

    override func setUp() async throws {
        fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MoltenReload-\(UUID().uuidString).md")
        try Data("original".utf8).write(to: fileURL)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func makeDocument() throws -> MoltenDocument {
        let document = MoltenDocument()
        document.fileURL = fileURL
        document.fileType = MoltenDocument.markdownType
        try document.read(from: Data("original".utf8), ofType: MoltenDocument.markdownType)
        return document
    }

    func testCleanDocumentAdoptsExternalChange() throws {
        let document = try makeDocument()
        try Data("external edit".utf8).write(to: fileURL)

        document.reloadIfCleanAndChangedOnDisk()

        XCTAssertEqual(document.text, "external edit")
        XCTAssertFalse(document.isDocumentEdited)
    }

    func testDirtyDocumentKeepsUnsavedEdits() throws {
        let document = try makeDocument()
        document.editorTextDidChange("user typing")
        try Data("external edit".utf8).write(to: fileURL)

        document.reloadIfCleanAndChangedOnDisk()

        XCTAssertEqual(document.text, "user typing", "a dirty document must never be clobbered by disk changes")
        XCTAssertTrue(document.isDocumentEdited)
    }

    func testUnchangedMtimeDoesNotReload() throws {
        let document = try makeDocument()
        // Record current mtime as already-seen.
        document.fileModificationDate = try fileURL.resourceValues(
            forKeys: [.contentModificationDateKey]
        ).contentModificationDate

        // Rewrite bytes but force the mtime BACKWARDS so it isn't newer.
        try Data("sneaky".utf8).write(to: fileURL)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -3600)],
            ofItemAtPath: fileURL.path
        )

        document.reloadIfCleanAndChangedOnDisk()
        XCTAssertEqual(document.text, "original", "a not-newer mtime must not trigger a reload")
    }
}
