import AppKit

/// Security-scoped bookmark store for document folders. The sandbox grants
/// access to the opened FILE only; writing `assets/` next to it (and reading
/// images back) needs a one-time user grant per folder, remembered here.
final class MoltenFolderAccess {
    static let shared = MoltenFolderAccess()

    private let defaults: UserDefaults
    private static let keyPrefix = "Molten.folderBookmark."
    /// Folders whose scope has been started this session (leaked deliberately:
    /// scoped access stays open for the app's lifetime, matching how documents
    /// keep their folders in play).
    private var activeFolders: Set<String> = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private func key(for folder: URL) -> String {
        Self.keyPrefix + folder.standardizedFileURL.path
    }

    func hasBookmark(for folder: URL) -> Bool {
        defaults.data(forKey: key(for: folder)) != nil
    }

    /// Ensures read-write access to the folder. Order: already-active scope →
    /// stored bookmark → plain writability probe (temp dirs, tests) →
    /// interactive NSOpenPanel grant (locked to the folder) when allowed.
    @discardableResult
    func ensureAccess(to folder: URL, interactive: Bool) -> Bool {
        let folderKey = key(for: folder)
        if activeFolders.contains(folderKey) {
            return true
        }

        if let data = defaults.data(forKey: folderKey) {
            var isStale = false
            if let resolved = try? URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ), resolved.startAccessingSecurityScopedResource() {
                if isStale, let refreshed = try? resolved.bookmarkData(
                    options: [.withSecurityScope],
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                ) {
                    defaults.set(refreshed, forKey: folderKey)
                }
                activeFolders.insert(folderKey)
                return true
            }
        }

        // Already writable without a scope (temporary directories, unsandboxed
        // tests, folders inside the container).
        if FileManager.default.isWritableFile(atPath: folder.path) {
            activeFolders.insert(folderKey)
            return true
        }

        guard interactive else { return false }
        return promptForAccess(to: folder, key: folderKey)
    }

    private func promptForAccess(to folder: URL, key folderKey: String) -> Bool {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = folder
        panel.message = String(format: L10n.string("folderAccess.message"), folder.lastPathComponent)
        panel.prompt = L10n.string("folderAccess.prompt")

        guard panel.runModal() == .OK, let granted = panel.url else { return false }
        // The user may navigate elsewhere; only accept the requested folder,
        // otherwise assets/ would land in the wrong place.
        guard granted.standardizedFileURL.path == folder.standardizedFileURL.path else { return false }

        guard let bookmark = try? granted.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) else { return false }
        defaults.set(bookmark, forKey: folderKey)
        guard granted.startAccessingSecurityScopedResource() else { return false }
        activeFolders.insert(folderKey)
        return true
    }
}
