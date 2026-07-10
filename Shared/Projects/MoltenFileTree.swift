import Foundation

/// A node in the in-window file sidebar tree. Files have `children == nil` (no disclosure);
/// folders have a non-nil (non-empty) `children` array. `id` is the canonical path.
struct MoltenFileTreeNode: Identifiable, Equatable {
    let id: String
    let name: String
    let url: URL
    let isDirectory: Bool
    let children: [MoltenFileTreeNode]?
}

/// Builds a recursive folder tree of Markdown files. Folders with no Markdown descendants are
/// pruned so the tree stays relevant; depth, kept-node count, AND total directory entries visited
/// are capped — the scan budget bounds the walk even when a huge subtree contains no Markdown at
/// all (node_modules, Downloads), which the kept-node cap alone would never trip on. Pure (caller
/// holds any needed security scope) → unit-testable.
enum MoltenFileTree {
    static let maxDepth = 6
    static let maxNodes = 2000
    /// Upper bound on directory entries examined during one build, markdown or not.
    static let maxScannedEntries = 20_000

    static func build(at folderURL: URL, fileManager: FileManager = .default) -> [MoltenFileTreeNode] {
        var nodeCount = 0
        var scannedCount = 0

        func level(_ url: URL, depth: Int) -> [MoltenFileTreeNode] {
            guard depth <= maxDepth, nodeCount < maxNodes, scannedCount < maxScannedEntries else { return [] }
            guard let entries = try? fileManager.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else {
                return []
            }

            var directories: [MoltenFileTreeNode] = []
            var files: [MoltenFileTreeNode] = []
            for entry in entries {
                scannedCount += 1
                if nodeCount >= maxNodes || scannedCount >= maxScannedEntries { break }
                let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                if isDirectory {
                    let children = level(entry, depth: depth + 1)
                    guard !children.isEmpty else { continue } // prune folders with no Markdown
                    nodeCount += 1
                    directories.append(MoltenFileTreeNode(
                        id: MoltenProjectStore.canonicalPath(entry),
                        name: entry.lastPathComponent,
                        url: entry,
                        isDirectory: true,
                        children: children
                    ))
                } else if MoltenProjectStore.supportedExtensions.contains(entry.pathExtension.lowercased()) {
                    nodeCount += 1
                    files.append(MoltenFileTreeNode(
                        id: MoltenProjectStore.canonicalPath(entry),
                        name: entry.lastPathComponent,
                        url: entry,
                        isDirectory: false,
                        children: nil
                    ))
                }
            }

            let sortedDirectories = directories.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            let sortedFiles = files.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            return sortedDirectories + sortedFiles
        }

        return level(folderURL, depth: 1)
    }
}
