import AppKit
import SwiftUI

/// Quick Open (⇧⌘P): fuzzy filename matching across every tracked project
/// folder plus the frontmost document's folder. Keyboard-first — type, arrow,
/// Return. The corpus is enumerated fresh on every show (off-main) so results
/// never go stale.
@MainActor
final class MoltenQuickOpenWindowController: NSWindowController {
    static let shared = MoltenQuickOpenWindowController()

    private let model = MoltenQuickOpenModel()

    private init() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 380),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true
        super.init(window: panel)
        panel.contentViewController = NSHostingController(
            rootView: MoltenQuickOpenView(model: model) { [weak panel] in
                panel?.close()
            }
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func show() {
        model.reload()
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: false)
    }
}

@MainActor
final class MoltenQuickOpenModel: ObservableObject {
    @Published var query = "" {
        didSet { refilter() }
    }
    @Published private(set) var results: [MoltenProjectFile] = []

    private var corpus: [MoltenProjectFile] = []
    private var loadGeneration = 0
    private let store = MoltenProjectStore()

    /// Re-enumerates every tracked folder plus the frontmost document's
    /// folder. Folder URLs resolve on the main actor; enumeration runs
    /// detached via the pure static helper (same pattern as content search).
    func reload() {
        loadGeneration += 1
        let generation = loadGeneration
        var folders = store.projects().compactMap { store.resolveFolderURL(for: $0) }
        if let current = (NSDocumentController.shared.currentDocument as? MoltenDocument)?
            .fileURL?.deletingLastPathComponent() {
            folders.append(current)
        }
        Task { [weak self] in
            let files = await Task.detached(priority: .userInitiated) {
                folders.flatMap { MoltenProjectStore.markdownFiles(inFolder: $0) ?? [] }
            }.value
            guard let self, self.loadGeneration == generation else { return }
            // De-dup by resolved path (the current folder may also be tracked).
            var seen = Set<String>()
            self.corpus = files.filter { seen.insert($0.path).inserted }
            self.refilter()
        }
    }

    private func refilter() {
        if query.isEmpty {
            // Empty query: most recently modified first, capped.
            results = Array(
                corpus
                    .sorted { ($0.modifiedAt ?? .distantPast) > ($1.modifiedAt ?? .distantPast) }
                    .prefix(50)
            )
            return
        }
        results = corpus
            .compactMap { file -> (MoltenProjectFile, Int)? in
                guard let score = MoltenFuzzyMatch.score(query: query, candidate: file.name) else {
                    return nil
                }
                return (file, score)
            }
            .sorted { $0.1 > $1.1 }
            .prefix(50)
            .map(\.0)
    }
}

struct MoltenQuickOpenView: View {
    @ObservedObject var model: MoltenQuickOpenModel
    let dismiss: () -> Void

    @State private var selection: String?
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            TextField(L10n.string("quickopen.placeholder"), text: $model.query)
                .textFieldStyle(.plain)
                .font(.title3)
                .padding(14)
                .focused($searchFocused)
                .onSubmit { openSelectionOrFirst() }

            Divider()

            if model.results.isEmpty {
                Text(L10n.string("quickopen.empty"))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $selection) {
                    ForEach(model.results) { file in
                        HStack {
                            Image(systemName: "doc.text")
                                .foregroundStyle(.secondary)
                            Text(file.name)
                                .lineLimit(1)
                            Spacer()
                            Text(file.url.deletingLastPathComponent().lastPathComponent)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                        .padding(.vertical, 2)
                        .tag(file.id)
                    }
                }
                .listStyle(.plain)
                .contextMenu(forSelectionType: String.self) { _ in
                } primaryAction: { ids in
                    if let id = ids.first { open(id: id) }
                }
            }
        }
        .frame(width: 520, height: 380)
        .onAppear {
            searchFocused = true
            selection = model.results.first?.id
        }
        .onChange(of: model.results) { results in
            if selection == nil || !results.contains(where: { $0.id == selection }) {
                selection = results.first?.id
            }
        }
        .onExitCommand { dismiss() }
        // Arrow keys move List selection natively once the list has focus;
        // from the text field, ⌥↓/tab reaches the list. Return always opens.
        .onMoveCommand { direction in
            guard !model.results.isEmpty else { return }
            let ids = model.results.map(\.id)
            let currentIndex = selection.flatMap { ids.firstIndex(of: $0) } ?? -1
            switch direction {
            case .down:
                selection = ids[min(currentIndex + 1, ids.count - 1)]
            case .up:
                selection = ids[max(currentIndex - 1, 0)]
            default:
                break
            }
        }
    }

    private func openSelectionOrFirst() {
        if let id = selection ?? model.results.first?.id {
            open(id: id)
        }
    }

    private func open(id: String) {
        guard let file = model.results.first(where: { $0.id == id }) else { return }
        dismiss()
        NSDocumentController.shared.openDocument(withContentsOf: file.url, display: true) { _, _, error in
            if let error { NSApp.presentError(error) }
        }
    }
}
