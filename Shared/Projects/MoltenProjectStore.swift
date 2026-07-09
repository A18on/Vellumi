import Foundation

/// UserDefaults-backed store for the user's projects (folder references). Mirrors the bookmark
/// handling of `MarkdownImageDropFolderAccessStore`: resolve with staleness detection and rewrite
/// the refreshed bookmark so moved/renamed folders don't silently lose access. Pure Foundation —
/// no AppKit — so it compiles into the iOS target unchanged (the bookmark option shim is empty
/// on iOS).
struct MoltenProjectStore {
    static let supportedExtensions: Set<String> = ["md", "markdown", "txt"]

    private enum Key {
        static let list = "Molten.projects.list"
    }

    private let defaults: UserDefaults
    private let fileManager: FileManager

    init(defaults: UserDefaults = .standard, fileManager: FileManager = .default) {
        self.defaults = defaults
        self.fileManager = fileManager
    }

    // MARK: - CRUD

    func projects() -> [MoltenProject] {
        guard let data = defaults.data(forKey: Key.list),
              let decoded = try? PropertyListDecoder().decode([MoltenProject].self, from: data) else {
            return []
        }
        return decoded
    }

    func save(_ projects: [MoltenProject]) {
        guard let data = try? PropertyListEncoder().encode(projects) else { return }
        defaults.set(data, forKey: Key.list)
    }

    /// Creates a security-scoped bookmark for the chosen folder and appends a project. If the same
    /// folder (resolved path) is already tracked, the existing entry is replaced (re-authorized).
    @discardableResult
    func addProject(folderURL: URL, name: String? = nil) throws -> MoltenProject {
        let bookmark = try folderURL.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        let project = MoltenProject(name: name ?? folderURL.lastPathComponent, folderBookmark: bookmark)
        let targetPath = Self.canonicalPath(folderURL)

        var all = projects()
        all.removeAll { existing in
            URL.resolvingDocumentFolderBookmark(existing.folderBookmark).map { Self.canonicalPath($0.url) } == targetPath
        }
        all.append(project)
        save(all)
        return project
    }

    func removeProject(id: UUID) {
        var all = projects()
        all.removeAll { $0.id == id }
        save(all)
    }

    func renameProject(id: UUID, to name: String) {
        var all = projects()
        guard let index = all.firstIndex(where: { $0.id == id }) else { return }
        all[index].name = name
        save(all)
    }

    // MARK: - Bookmark resolution

    /// Resolves the project's folder URL, refreshing and persisting the bookmark if it went stale.
    /// Returns nil if the folder can't be resolved (deleted, on an unmounted volume, etc.).
    func resolveFolderURL(for project: MoltenProject) -> URL? {
        guard let resolved = URL.resolvingDocumentFolderBookmark(project.folderBookmark) else {
            return nil
        }
        if let refreshed = resolved.refreshedData {
            var all = projects()
            if let index = all.firstIndex(where: { $0.id == project.id }) {
                all[index].folderBookmark = refreshed
                save(all)
            }
        }
        return resolved.url
    }

    // MARK: - Enumeration

    /// Live list of Markdown files in the project folder, newest first. Returns nil if the folder
    /// can't be resolved or accessed (caller renders an "unavailable / re-link" state).
    func markdownFiles(in project: MoltenProject) -> [MoltenProjectFile]? {
        guard let folderURL = resolveFolderURL(for: project) else { return nil }
        let didStart = folderURL.startAccessingSecurityScopedResource()
        defer {
            if didStart { folderURL.stopAccessingSecurityScopedResource() }
        }
        return Self.markdownFiles(inFolder: folderURL, fileManager: fileManager)
    }

    /// Pure enumeration over a directly-accessible folder URL (no bookmark/security scope). Split
    /// out so the filtering and sort order are unit-testable without sandbox-vended bookmarks.
    static func markdownFiles(inFolder folderURL: URL, fileManager: FileManager = .default) -> [MoltenProjectFile]? {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else {
            return nil
        }

        return entries
            .filter { url in
                guard supportedExtensions.contains(url.pathExtension.lowercased()) else { return false }
                // A DIRECTORY named "Notes.md" must not be listed as an openable file.
                return (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false
            }
            .map { url in
                let modifiedAt = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                return MoltenProjectFile(
                    path: canonicalPath(url),
                    name: url.lastPathComponent,
                    url: url,
                    modifiedAt: modifiedAt
                )
            }
            .sorted { lhs, rhs in
                let l = lhs.modifiedAt ?? .distantPast
                let r = rhs.modifiedAt ?? .distantPast
                if l == r { return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending }
                return l > r
            }
    }

    // MARK: - Helpers

    static func canonicalPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// Computes the new file name for a rename: preserves the original extension unless the user
    /// already typed it. Returns nil when the input is empty or unchanged. Pure → unit-testable.
    static func renamedFileName(currentName: String, input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let ext = (currentName as NSString).pathExtension
        var newName = trimmed
        if !ext.isEmpty, (newName as NSString).pathExtension.lowercased() != ext.lowercased() {
            newName += ".\(ext)"
        }
        return newName == currentName ? nil : newName
    }

    /// A non-colliding `.md` URL in the folder: `baseName.md`, then `baseName 2.md`, `baseName 3.md`…
    /// Used by "New Note" to assign a backing file up front so autosave-in-place owns it from the
    /// first keystroke. Pure (no security scope) so it's unit-testable.
    static func uniqueMarkdownFileURL(
        in folderURL: URL,
        baseName: String,
        fileManager: FileManager = .default
    ) -> URL {
        let ext = "md"
        var candidate = folderURL.appendingPathComponent("\(baseName).\(ext)", isDirectory: false)
        var counter = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = folderURL.appendingPathComponent("\(baseName) \(counter).\(ext)", isDirectory: false)
            counter += 1
        }
        return candidate
    }
}
