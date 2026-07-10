import Foundation

/// Optional "Drafts" default folder. When the user opts in by choosing a folder, File ▸ New backs
/// the new document with a real `.md` here up front, so autosave-in-place protects it from the
/// first keystroke (the opt-in follow-up to the deliberate "don't auto-home File>New" default —
/// nothing is written anywhere until the user configures this). A security-scoped folder bookmark.
struct MoltenDraftsStore {
    private enum Key {
        static let bookmark = "Molten.drafts.folderBookmark"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var isConfigured: Bool {
        defaults.data(forKey: Key.bookmark) != nil
    }

    func setFolder(_ url: URL) throws {
        let bookmark = try url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        defaults.set(bookmark, forKey: Key.bookmark)
    }

    func clear() {
        defaults.removeObject(forKey: Key.bookmark)
    }

    /// Resolves the Drafts folder URL, refreshing the bookmark if stale. Nil if unset/unresolvable.
    func resolveFolderURL() -> URL? {
        guard let data = defaults.data(forKey: Key.bookmark),
              let resolved = URL.resolvingDocumentFolderBookmark(data) else {
            return nil
        }
        if let refreshed = resolved.refreshedData {
            defaults.set(refreshed, forKey: Key.bookmark)
        }
        return resolved.url
    }
}
