import Foundation

/// A project is a lightweight REFERENCE to a real folder of Markdown files on disk (held via a
/// security-scoped bookmark) — never a copy or a container. The files stay plain `.md`, openable
/// by any app and by Open Recent. Persisted plist-safely (Codable → PropertyListEncoder) so the
/// model compiles unchanged into both the macOS and iOS targets.
struct MoltenProject: Identifiable, Equatable, Codable {
    let id: UUID
    var name: String
    /// Security-scoped (app-scope) bookmark to the project folder. On iOS the option set is
    /// empty (see `URL.BookmarkCreationOptions.documentFolderAccess`), so this is a plain bookmark.
    var folderBookmark: Data
    var dateAdded: Date

    init(
        id: UUID = UUID(),
        name: String,
        folderBookmark: Data,
        dateAdded: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.folderBookmark = folderBookmark
        self.dateAdded = dateAdded
    }
}

/// A Markdown file enumerated live from a project folder. `path` (resolved, symlink-free) is the
/// stable identity; `url` is valid for opening while the folder's security scope is held.
struct MoltenProjectFile: Identifiable, Equatable {
    var id: String { path }
    let path: String
    let name: String
    let url: URL
    let modifiedAt: Date?
}
