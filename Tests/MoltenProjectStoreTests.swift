import XCTest
@testable import Molten

final class MoltenProjectStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suiteName = "MoltenProjectStoreTests"
    private var tempDir: URL!

    override func setUpWithError() throws {
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MoltenProjectStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - CRUD round-trip (no security-scoped bookmark needed)

    func testSaveAndLoadRoundTripsAllFields() {
        let store = MoltenProjectStore(defaults: defaults)
        let project = MoltenProject(
            id: UUID(),
            name: "Work Notes",
            folderBookmark: Data([0x01, 0x02, 0x03]),
            dateAdded: Date(timeIntervalSince1970: 1_700_000_000)
        )
        store.save([project])

        let loaded = MoltenProjectStore(defaults: defaults).projects()
        XCTAssertEqual(loaded, [project])
    }

    func testRenameAndRemoveById() {
        let store = MoltenProjectStore(defaults: defaults)
        let a = MoltenProject(name: "A", folderBookmark: Data([1]))
        let b = MoltenProject(name: "B", folderBookmark: Data([2]))
        store.save([a, b])

        store.renameProject(id: a.id, to: "Alpha")
        XCTAssertEqual(store.projects().first(where: { $0.id == a.id })?.name, "Alpha")

        store.removeProject(id: b.id)
        let remaining = store.projects()
        XCTAssertEqual(remaining.map(\.id), [a.id])
    }

    func testEmptyDefaultsYieldsNoProjects() {
        XCTAssertEqual(MoltenProjectStore(defaults: defaults).projects(), [])
    }

    // MARK: - Enumeration (pure function over a real folder)

    func testMarkdownFilesFiltersExtensionsAndSortsNewestFirst() throws {
        try write("a.md", modifiedAt: Date(timeIntervalSinceNow: -10))
        try write("note.txt", modifiedAt: Date(timeIntervalSinceNow: -50))
        try write("b.markdown", modifiedAt: Date(timeIntervalSinceNow: -100))
        try write("image.png", modifiedAt: Date())
        try write("plain", modifiedAt: Date())
        try write(".hidden.md", modifiedAt: Date())

        let files = try XCTUnwrap(MoltenProjectStore.markdownFiles(inFolder: tempDir))
        XCTAssertEqual(files.map(\.name), ["a.md", "note.txt", "b.markdown"])
    }

    func testMarkdownFilesReturnsNilForMissingFolder() {
        let missing = tempDir.appendingPathComponent("does-not-exist", isDirectory: true)
        XCTAssertNil(MoltenProjectStore.markdownFiles(inFolder: missing))
    }

    func testMarkdownFilesExcludesDirectoriesNamedLikeMarkdown() throws {
        try write("real.md", modifiedAt: Date())
        try FileManager.default.createDirectory(
            at: tempDir.appendingPathComponent("Archive.md", isDirectory: true),
            withIntermediateDirectories: true
        )
        let files = try XCTUnwrap(MoltenProjectStore.markdownFiles(inFolder: tempDir))
        XCTAssertEqual(files.map(\.name), ["real.md"], "a directory named *.md must not be listed as a file")
    }

    // MARK: - Unique filename (New Note draft fix)

    func testUniqueMarkdownFileURLDedupesAgainstExistingFiles() throws {
        let first = MoltenProjectStore.uniqueMarkdownFileURL(in: tempDir, baseName: "Untitled")
        XCTAssertEqual(first.lastPathComponent, "Untitled.md")
        try Data().write(to: first)

        let second = MoltenProjectStore.uniqueMarkdownFileURL(in: tempDir, baseName: "Untitled")
        XCTAssertEqual(second.lastPathComponent, "Untitled 2.md")
        try Data().write(to: second)

        let third = MoltenProjectStore.uniqueMarkdownFileURL(in: tempDir, baseName: "Untitled")
        XCTAssertEqual(third.lastPathComponent, "Untitled 3.md")
    }

    // MARK: - Rename file name computation

    func testRenamedFileNamePreservesExtensionAndDetectsNoChange() {
        XCTAssertEqual(MoltenProjectStore.renamedFileName(currentName: "note.md", input: "report"), "report.md")
        XCTAssertEqual(MoltenProjectStore.renamedFileName(currentName: "note.md", input: "report.md"), "report.md")
        XCTAssertEqual(MoltenProjectStore.renamedFileName(currentName: "note.md", input: "  spaced  "), "spaced.md")
        XCTAssertNil(MoltenProjectStore.renamedFileName(currentName: "note.md", input: "note"), "unchanged → nil")
        XCTAssertNil(MoltenProjectStore.renamedFileName(currentName: "note.md", input: "   "), "empty → nil")
        XCTAssertEqual(MoltenProjectStore.renamedFileName(currentName: "READ", input: "readme"), "readme", "extensionless rename")
    }

    // MARK: - End-to-end bookmark path (best-effort; skips if the sandbox refuses)

    func testAddResolveEnumerateThroughRealBookmarkIfPermitted() throws {
        try write("doc.md", modifiedAt: Date())
        let store = MoltenProjectStore(defaults: defaults)

        let project: MoltenProject
        do {
            project = try store.addProject(folderURL: tempDir)
        } catch {
            throw XCTSkip("Security-scoped bookmark for a non-user-selected folder was refused: \(error)")
        }

        XCTAssertEqual(store.projects().map(\.id), [project.id])

        guard let files = store.markdownFiles(in: project) else {
            throw XCTSkip("Folder not reachable via the resolved bookmark in this environment")
        }
        XCTAssertEqual(files.map(\.name), ["doc.md"])
    }

    private func write(_ name: String, modifiedAt: Date) throws {
        let url = tempDir.appendingPathComponent(name)
        try "# \(name)".data(using: .utf8)!.write(to: url)
        try FileManager.default.setAttributes([.modificationDate: modifiedAt], ofItemAtPath: url.path)
    }
}
