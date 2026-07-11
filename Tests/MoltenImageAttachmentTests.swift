import XCTest
@testable import Vellumi

@MainActor
final class MoltenImageAttachmentTests: XCTestCase {
    private var folder: URL!
    private var fileURL: URL!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("MoltenImages-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        fileURL = folder.appendingPathComponent("doc.md")
        try Data("# doc".utf8).write(to: fileURL)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func makeDocument() throws -> MoltenDocument {
        let document = MoltenDocument()
        document.fileURL = fileURL
        document.fileType = MoltenDocument.markdownType
        try document.read(from: Data("# doc".utf8), ofType: MoltenDocument.markdownType)
        return document
    }

    private let onePixelPNGBase64 =
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="

    func testSaveImageWritesAssetAndReturnsRelativePath() throws {
        let document = try makeDocument()
        let path = document.saveImageAttachment(name: "shot.png", base64: onePixelPNGBase64)

        XCTAssertEqual(path, "assets/shot.png")
        let written = folder.appendingPathComponent("assets/shot.png")
        XCTAssertTrue(FileManager.default.fileExists(atPath: written.path))
        XCTAssertEqual(try Data(contentsOf: written), Data(base64Encoded: onePixelPNGBase64))
    }

    func testCollidingNamesGetUniqueSuffixes() throws {
        let document = try makeDocument()
        let first = document.saveImageAttachment(name: "pic.png", base64: onePixelPNGBase64)
        let second = document.saveImageAttachment(name: "pic.png", base64: onePixelPNGBase64)
        XCTAssertEqual(first, "assets/pic.png")
        XCTAssertEqual(second, "assets/pic-1.png")
    }

    func testHostileNameIsSanitized() throws {
        let document = try makeDocument()
        let path = document.saveImageAttachment(name: "../..//evil name?.png", base64: onePixelPNGBase64)
        let saved = try XCTUnwrap(path)
        XCTAssertTrue(saved.hasPrefix("assets/"), "must stay inside assets/, got \(saved)")
        XCTAssertFalse(saved.contains(".."))
        XCTAssertFalse(saved.contains(" "))
    }

    func testInvalidBase64ReturnsNil() throws {
        let document = try makeDocument()
        XCTAssertNil(document.saveImageAttachment(name: "x.png", base64: "not-base64!!!"))
    }
}

final class MoltenAssetSchemeHandlerTests: XCTestCase {
    private let directory = URL(fileURLWithPath: "/Users/someone/Notes", isDirectory: true)

    private func resolve(_ url: String) -> URL? {
        MoltenAssetSchemeHandler.resolvedFileURL(for: URL(string: url)!, in: directory)
    }

    func testResolvesRelativeAssetPath() {
        XCTAssertEqual(resolve("molten-asset://asset/assets/pic.png")?.path, "/Users/someone/Notes/assets/pic.png")
    }

    func testDecodesPercentEncoding() {
        XCTAssertEqual(resolve("molten-asset://asset/assets/%E5%9B%BE.png")?.path, "/Users/someone/Notes/assets/图.png")
    }

    func testRefusesTraversalOutsideDocumentFolder() {
        XCTAssertNil(resolve("molten-asset://asset/../../etc/passwd"))
        XCTAssertNil(resolve("molten-asset://asset/assets/../../../etc/hosts"))
    }

    func testRefusesForeignSchemeOrHost() {
        XCTAssertNil(resolve("https://asset/assets/pic.png"))
        XCTAssertNil(resolve("molten-asset://other/assets/pic.png"))
    }
}
