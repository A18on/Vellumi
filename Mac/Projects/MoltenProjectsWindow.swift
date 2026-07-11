import AppKit
import SwiftUI

/// Projects launcher (⇧⌘0): folders the user tracks as projects, their
/// markdown files, recent documents, and per-project New Note. Phase 1 —
/// find-in-files and file trees come later (MarkMac roadmap parity).
@MainActor
final class MoltenProjectsWindowController: NSWindowController {
    static let shared = MoltenProjectsWindowController()

    private init() {
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 560),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        window.title = L10n.string("projects.title")
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("MoltenProjectsWindow")
        super.init(window: window)
        window.contentViewController = NSHostingController(rootView: MoltenProjectsView(model: model))
    }

    private let model = MoltenProjectsModel()

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func show() {
        // Disk may have changed since last open — refresh everything visible.
        model.reload()
        model.reloadRecents()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: false)
    }
}

@MainActor
final class MoltenProjectsModel: ObservableObject {
    @Published private(set) var projects: [MoltenProject] = []
    @Published private(set) var filesByProject: [UUID: [MoltenProjectFile]] = [:]
    @Published private(set) var unavailable: Set<UUID> = []
    @Published var expanded: Set<UUID> = []
    @Published private(set) var recents: [URL] = []
    @Published var searchText: String = ""
    @Published private(set) var contentResults: [MoltenProjectSearchResult] = []
    @Published private(set) var contentSearchActive = false
    /// The query the current results were produced for.
    private(set) var contentQuery = ""
    private var searchGeneration = 0

    private let store = MoltenProjectStore()
    private var observers: [NSObjectProtocol] = []

    init() {
        reload()
        reloadRecents()
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.reloadRecents()
            }
        })
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    func reload() {
        projects = store.projects()
        for project in projects where expanded.contains(project.id) {
            refreshFiles(project.id)
        }
    }

    func reloadRecents() {
        let current = NSDocumentController.shared.recentDocumentURLs
        if recents != current {
            recents = current
        }
    }

    func files(for id: UUID) -> [MoltenProjectFile] {
        filesByProject[id] ?? []
    }

    func isExpanded(_ id: UUID) -> Bool { expanded.contains(id) }
    func isUnavailable(_ id: UUID) -> Bool { unavailable.contains(id) }

    func toggle(_ id: UUID) {
        if expanded.contains(id) {
            expanded.remove(id)
        } else {
            expanded.insert(id)
            refreshFiles(id)
        }
    }

    func refreshFiles(_ id: UUID) {
        guard let project = projects.first(where: { $0.id == id }) else { return }
        if let files = store.markdownFiles(in: project) {
            filesByProject[id] = files
            unavailable.remove(id)
        } else {
            filesByProject[id] = []
            unavailable.insert(id)
        }
    }

    func addProject() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = L10n.string("projects.add.prompt")
        panel.message = L10n.string("projects.add.message")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            _ = try store.addProject(folderURL: url)
            reload()
        } catch {
            NSApp.presentError(error)
        }
    }

    func remove(_ id: UUID) {
        store.removeProject(id: id)
        expanded.remove(id)
        filesByProject[id] = nil
        unavailable.remove(id)
        reload()
    }

    func open(_ file: MoltenProjectFile, in projectID: UUID) {
        guard let project = projects.first(where: { $0.id == projectID }),
              let folderURL = store.resolveFolderURL(for: project) else {
            NSSound.beep()
            return
        }
        MoltenFolderAccess.shared.ensureAccess(to: folderURL, interactive: false)
        openDocument(at: file.url)
    }

    func openRecent(_ url: URL) {
        openDocument(at: url)
    }

    /// Creates the backing .md up front (autosave owns it from keystroke one),
    /// deleting the empty file again if the open fails — no orphans.
    func newNote(in id: UUID) {
        guard let project = projects.first(where: { $0.id == id }),
              let folderURL = store.resolveFolderURL(for: project) else {
            NSSound.beep()
            return
        }
        guard MoltenFolderAccess.shared.ensureAccess(to: folderURL, interactive: true) else { return }
        let fileURL = MoltenProjectStore.uniqueMarkdownFileURL(
            in: folderURL,
            baseName: L10n.string("projects.newNote.baseName")
        )
        do {
            try Data().write(to: fileURL, options: .withoutOverwriting)
        } catch {
            NSApp.presentError(error)
            return
        }
        NSDocumentController.shared.openDocument(withContentsOf: fileURL, display: true) { [weak self] document, _, error in
            if let error {
                NSApp.presentError(error)
                if document == nil, let data = try? Data(contentsOf: fileURL), data.isEmpty {
                    try? FileManager.default.removeItem(at: fileURL)
                }
            }
            self?.refreshFiles(id)
        }
        expanded.insert(id)
    }

    private func openDocument(at url: URL) {
        NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in
            if let error {
                MoltenLog.document.error("Open from projects failed: \(error.localizedDescription, privacy: .public)")
                NSApp.presentError(error)
            }
        }
    }

    // MARK: - Rename

    func promptRenameProject(_ id: UUID) {
        guard let project = projects.first(where: { $0.id == id }) else { return }
        guard let name = Self.promptForName(
            title: L10n.string("projects.rename.title"),
            current: project.name
        ), !name.isEmpty else { return }
        store.renameProject(id: id, to: name)
        reload()
    }

    /// Renames the file on disk (extension preserved via the store helper),
    /// then refreshes the listing. Needs the folder's write scope.
    func promptRenameFile(_ file: MoltenProjectFile, in projectID: UUID) {
        guard let project = projects.first(where: { $0.id == projectID }),
              let folderURL = store.resolveFolderURL(for: project) else {
            NSSound.beep()
            return
        }
        guard let input = Self.promptForName(
            title: L10n.string("projects.renameFile.title"),
            current: file.name
        ), let newName = MoltenProjectStore.renamedFileName(currentName: file.name, input: input) else {
            return
        }
        guard MoltenFolderAccess.shared.ensureAccess(to: folderURL, interactive: true) else { return }
        let target = file.url.deletingLastPathComponent().appendingPathComponent(newName)
        guard !FileManager.default.fileExists(atPath: target.path) else {
            NSSound.beep()
            return
        }
        // If the file is OPEN, rename through its NSDocument so the document
        // follows the file — a raw move would fork it: the next autosave
        // resurrects the old name and all edits land in the wrong file.
        let standardized = file.url.standardizedFileURL
        if let open = NSDocumentController.shared.documents.first(where: {
            $0.fileURL?.standardizedFileURL == standardized
        }) {
            open.move(to: target) { [weak self] error in
                if let error {
                    NSApp.presentError(error)
                }
                self?.refreshFiles(projectID)
            }
            return
        }
        // Closed file: coordinated move so other presenters stay consistent.
        var moveError: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(
            writingItemAt: file.url,
            options: .forMoving,
            error: &moveError
        ) { url in
            do {
                try FileManager.default.moveItem(at: url, to: target)
            } catch {
                DispatchQueue.main.async { NSApp.presentError(error) }
            }
        }
        if let moveError {
            NSApp.presentError(moveError)
        }
        refreshFiles(projectID)
    }

    private static func promptForName(title: String, current: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = current
        alert.accessoryView = field
        alert.addButton(withTitle: L10n.string("common.ok"))
        alert.addButton(withTitle: L10n.string("common.cancel"))
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Find in files

    /// Full-text search across every project (search field's Return action).
    /// The corpus is enumerated FRESH from the store inside the task, and a
    /// generation counter keeps stale results from clobbering newer ones —
    /// both lessons from MarkMac's review.
    func runContentSearch() {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else {
            clearContentSearch()
            return
        }
        for project in projects {
            if let url = store.resolveFolderURL(for: project) {
                MoltenFolderAccess.shared.ensureAccess(to: url, interactive: false)
            }
        }
        searchGeneration += 1
        let generation = searchGeneration
        // Resolve folder URLs on the main actor; the detached task only uses
        // the pure static enumerator (no shared store instance off-main).
        let folders = projects.compactMap { store.resolveFolderURL(for: $0) }
        contentSearchActive = true
        contentResults = []
        Task { [weak self] in
            let results = await Task.detached(priority: .userInitiated) {
                let corpus = folders.flatMap { MoltenProjectStore.markdownFiles(inFolder: $0) ?? [] }
                return MoltenProjectContentSearch.search(query: query, files: corpus, caseSensitive: false)
            }.value
            guard let self, self.searchGeneration == generation else { return }
            self.contentQuery = query
            self.contentResults = results
        }
    }

    func clearContentSearch() {
        searchGeneration += 1
        contentSearchActive = false
        contentResults = []
    }

    /// Opens a search hit and drives the editor's find to the query, which
    /// both highlights and scrolls to the first occurrence.
    func openSearchResult(_ file: MoltenProjectFile) {
        let query = contentQuery
        NSDocumentController.shared.openDocument(withContentsOf: file.url, display: true) { document, _, error in
            if let error {
                NSApp.presentError(error)
                return
            }
            guard let document = document as? MoltenDocument, !query.isEmpty else { return }
            // The editor may still be booting; retry briefly until find lands.
            // Weak: a closed document must not be kept alive by pending retries.
            func attempt(_ remaining: Int) {
                guard let editor = document.editorViewController else { return }
                editor.find(query, backwards: false) { [weak document] found in
                    if !found, remaining > 0, document != nil {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            attempt(remaining - 1)
                        }
                    }
                }
            }
            attempt(10)
        }
    }
}

// MARK: - View

enum MoltenProjectsRowID: Hashable {
    case project(UUID)
    case file(String)
    case unavailable(UUID)
    case recent(URL)
    case searchHit(String)
}

struct MoltenProjectsView: View {
    @ObservedObject var model: MoltenProjectsModel
    @State private var selection: MoltenProjectsRowID?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button {
                    model.addProject()
                } label: {
                    Label(L10n.string("projects.add.button"), systemImage: "plus")
                }
                .controlSize(.small)
                Spacer()
            }
            .padding(10)

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(L10n.string("projects.search.placeholder"), text: $model.searchText)
                    .textFieldStyle(.plain)
                    .onSubmit { model.runContentSearch() }
                if model.contentSearchActive {
                    Button {
                        model.searchText = ""
                        model.clearContentSearch()
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 8)

            Divider()

            List(selection: $selection) {
                if model.contentSearchActive {
                    searchSection
                }
                projectsSection
                recentsSection
            }
            .listStyle(.sidebar)
            // Return / double-click / assistive activation, one entry point
            // (the MarkMac accessibility lesson).
            .contextMenu(forSelectionType: MoltenProjectsRowID.self) { ids in
                if let id = ids.first {
                    contextMenuItems(for: id)
                }
            } primaryAction: { ids in
                if let id = ids.first {
                    activate(id)
                }
            }
        }
        .frame(minWidth: 320, minHeight: 400)
    }

    @ViewBuilder
    private var searchSection: some View {
        Section(L10n.string("projects.search.resultsTitle")) {
            if model.contentResults.isEmpty {
                Text(L10n.string("projects.search.noMatch"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.contentResults) { result in
                    Label {
                        HStack {
                            Text(result.file.name)
                            Spacer()
                            Text("\(result.matchCount)")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    } icon: {
                        Image(systemName: "text.magnifyingglass")
                    }
                    .tag(MoltenProjectsRowID.searchHit(result.file.path))
                }
            }
        }
    }

    @ViewBuilder
    private var projectsSection: some View {
        Section(L10n.string("projects.section.projects")) {
            if model.projects.isEmpty {
                Text(L10n.string("projects.empty"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.projects) { project in
                    Label {
                        HStack {
                            Text(project.name)
                            Spacer()
                            Text("\(model.files(for: project.id).count)")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    } icon: {
                        Image(systemName: model.isExpanded(project.id) ? "folder.fill" : "folder")
                    }
                    .tag(MoltenProjectsRowID.project(project.id))

                    if model.isExpanded(project.id) {
                        if model.isUnavailable(project.id) {
                            Text(L10n.string("projects.unavailable"))
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .tag(MoltenProjectsRowID.unavailable(project.id))
                        } else {
                            ForEach(model.files(for: project.id)) { file in
                                Label(file.name, systemImage: "doc.text")
                                    .padding(.leading, 12)
                                    .tag(MoltenProjectsRowID.file(file.path))
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var recentsSection: some View {
        Section(L10n.string("projects.section.recents")) {
            if model.recents.isEmpty {
                Text(L10n.string("projects.recents.empty"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.recents, id: \.self) { url in
                    Label(url.lastPathComponent, systemImage: "clock")
                        .tag(MoltenProjectsRowID.recent(url))
                }
            }
        }
    }

    private func activate(_ id: MoltenProjectsRowID) {
        switch id {
        case .project(let projectID):
            model.toggle(projectID)
        case .file(let path):
            if let (file, projectID) = fileRow(for: path) {
                model.open(file, in: projectID)
            }
        case .recent(let url):
            model.openRecent(url)
        case .searchHit(let path):
            if let result = model.contentResults.first(where: { $0.file.path == path }) {
                model.openSearchResult(result.file)
            }
        case .unavailable:
            break
        }
    }

    private func fileRow(for path: String) -> (MoltenProjectFile, UUID)? {
        for project in model.projects {
            if let file = model.files(for: project.id).first(where: { $0.path == path }) {
                return (file, project.id)
            }
        }
        return nil
    }

    @ViewBuilder
    private func contextMenuItems(for id: MoltenProjectsRowID) -> some View {
        switch id {
        case .project(let projectID):
            Button(L10n.string("projects.context.newNote")) { model.newNote(in: projectID) }
            Button(L10n.string("projects.context.rename")) { model.promptRenameProject(projectID) }
            Divider()
            Button(L10n.string("projects.context.remove")) { model.remove(projectID) }
        case .file(let path):
            if let (file, projectID) = fileRow(for: path) {
                Button(L10n.string("projects.context.open")) { model.open(file, in: projectID) }
                Button(L10n.string("projects.context.rename")) { model.promptRenameFile(file, in: projectID) }
                Button(L10n.string("projects.context.reveal")) {
                    NSWorkspace.shared.activateFileViewerSelecting([file.url])
                }
            }
        case .recent(let url):
            Button(L10n.string("projects.context.reveal")) {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        case .searchHit(let path):
            if let result = model.contentResults.first(where: { $0.file.path == path }) {
                Button(L10n.string("projects.context.reveal")) {
                    NSWorkspace.shared.activateFileViewerSelecting([result.file.url])
                }
            }
        case .unavailable:
            EmptyView()
        }
    }
}
