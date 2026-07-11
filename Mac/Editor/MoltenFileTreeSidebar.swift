import SwiftUI

/// Backing state for the file-tree sidebar (⌥⌘2) — a model object so tree
/// updates don't rebuild the hosted view.
@MainActor
final class MoltenFileTreeModel: ObservableObject {
    @Published var nodes: [MoltenFileTreeNode] = []
    @Published var currentFilePath: String?
}

/// Recursive markdown tree of the current document's folder.
struct MoltenFileTreeSidebar: View {
    @ObservedObject var model: MoltenFileTreeModel
    let onOpen: (URL) -> Void

    @State private var selection: String?

    var body: some View {
        Group {
            if model.nodes.isEmpty {
                Text(L10n.string("filetree.empty"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(12)
            } else {
                List(model.nodes, children: \.children, selection: $selection) { node in
                    Label(node.name, systemImage: node.isDirectory ? "folder" : "doc.text")
                        .fontWeight(node.id == model.currentFilePath ? .semibold : .regular)
                        .padding(.vertical, 2)
                        .tag(node.id)
                }
                .listStyle(.sidebar)
                .padding(.top, 6)
                // Return / double-click / assistive activation (MarkMac lesson).
                .contextMenu(forSelectionType: String.self) { ids in
                    if let id = ids.first, let node = Self.node(withID: id, in: model.nodes), !node.isDirectory {
                        Button(L10n.string("projects.context.reveal")) {
                            NSWorkspace.shared.activateFileViewerSelecting([node.url])
                        }
                    }
                } primaryAction: { ids in
                    if let id = ids.first, let node = Self.node(withID: id, in: model.nodes), !node.isDirectory {
                        onOpen(node.url)
                    }
                }
            }
        }
        .frame(minWidth: 160, maxWidth: 320, maxHeight: .infinity)
    }

    /// Recursive lookup by stable id (canonical path).
    static func node(withID id: String, in nodes: [MoltenFileTreeNode]) -> MoltenFileTreeNode? {
        for candidate in nodes {
            if candidate.id == id { return candidate }
            if let children = candidate.children,
               let found = Self.node(withID: id, in: children) {
                return found
            }
        }
        return nil
    }
}
