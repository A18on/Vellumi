import Foundation

extension URL {
    /// Resolves a security-scoped folder bookmark, re-minting it when stale.
    /// Returns the resolved URL plus refreshed bookmark data for the caller to
    /// persist (nil when still fresh). From MarkMac (MIT, same author).
    static func resolvingDocumentFolderBookmark(_ data: Data) -> (url: URL, refreshedData: Data?)? {
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else {
            return nil
        }
        guard isStale,
              let refreshed = try? url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
              ) else {
            return (url, nil)
        }
        return (url, refreshed)
    }
}
