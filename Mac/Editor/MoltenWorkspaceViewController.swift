import AppKit
import SwiftUI

struct MoltenHeading: Identifiable, Equatable {
    let level: Int
    let text: String
    let pos: Int
    var id: Int { pos }
}

/// Backing state for the outline sidebar — a model object so heading updates
/// don't rebuild the hosted SwiftUI view.
@MainActor
final class MoltenOutlineModel: ObservableObject {
    @Published var headings: [MoltenHeading] = []
}

/// Window chrome around the editing surface: optional outline sidebar, a find
/// bar (Cmd+F), and a status bar with the mixed CJK/latin word count. The
/// editor itself stays a plain full-bleed web view.
final class MoltenWorkspaceViewController: NSViewController {
    let editorViewController: MoltenEditorViewController

    private let outlineModel = MoltenOutlineModel()
    private let fileTreeModel = MoltenFileTreeModel()
    private let splitViewController = NSSplitViewController()
    private var outlineItem: NSSplitViewItem!
    private var fileTreeItem: NSSplitViewItem!
    private var fileTreeGeneration = 0
    private let findBar = NSVisualEffectView()
    private let findField = NSSearchField()
    private let replaceField = NSTextField()
    private let statusBar = NSVisualEffectView()
    private let wordCountLabel = NSTextField(labelWithString: "")
    private var showsOutline = UserDefaults.standard.bool(forKey: "Vellumi.showsOutline")
    private var showsFileTree = UserDefaults.standard.bool(forKey: "Vellumi.showsFileTree")
    private var collapseObservations: [NSKeyValueObservation] = []
    private var pendingStatsWorkItem: DispatchWorkItem?
    private var sourceScrollView: NSScrollView?
    private var sourceTextView: NSTextView?
    private(set) var isSourceMode = false
    private var imageCardExportWindowController: NSWindowController?
    private let statsQueue = DispatchQueue(label: "com.aaron.vellumi.stats", qos: .utility)
    private var statsGeneration = 0

    private weak var document: MoltenDocument?

    init(document: MoltenDocument) {
        self.document = document
        editorViewController = MoltenEditorViewController(document: document)
        super.init(nibName: nil, bundle: nil)
    }

    // MARK: - Export / print (File menu, via responder chain)

    @objc func exportHTML(_ sender: Any?) {
        guard let document else { return }
        MoltenExporter.exportHTML(from: self, document: document)
    }

    @objc func exportPDF(_ sender: Any?) {
        guard let document else { return }
        MoltenExporter.exportPDF(from: self, document: document)
    }

    @objc func printDocument(_ sender: Any?) {
        MoltenExporter.print(from: self)
    }

    @objc func exportImageCards(_ sender: Any?) {
        guard let document, let window = view.window else { return }
        editorViewController.fetchContentHTML { [weak self] bodyHTML in
            guard let self, let bodyHTML else {
                NSSound.beep()
                return
            }
            // Card renderer lives inside the bundle: relative image srcs must
            // go through the molten-asset scheme to reach the document folder.
            let request = MarkdownImageCardExportRequest(
                bodyHTML: MoltenAssetSchemeHandler.rewritingImageSources(in: bodyHTML),
                documentURL: document.fileURL,
                defaultBaseName: document.exportBaseName
            )

            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 920, height: 640),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            panel.title = L10n.string("export.image.title")
            panel.isReleasedWhenClosed = false
            panel.contentMinSize = NSSize(width: 820, height: 560)
            panel.contentViewController = NSHostingController(
                rootView: ImageCardExportView(request: request) { [weak self, weak panel] in
                    guard let panel else { return }
                    panel.sheetParent?.endSheet(panel)
                    panel.close()
                    self?.imageCardExportWindowController = nil
                }
            )

            self.imageCardExportWindowController = NSWindowController(window: panel)
            window.beginSheet(panel) { [weak self] _ in
                self?.imageCardExportWindowController = nil
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func loadView() {
        configureFindBar()
        configureSplitViewController()
        configureStatusBar()

        // Explicit constraints, not NSStackView: find bar pinned to the top
        // (zero-height while hidden), status bar pinned to the bottom, the
        // split view filling everything between.
        let container = NSView()
        let split = splitViewController.view
        for subview in [findBar, split, statusBar] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(subview)
        }

        findBarHeightConstraint = findBar.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            // safeArea keeps the bar below the (transparent, full-size) titlebar.
            findBar.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor),
            findBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            findBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            findBarHeightConstraint!,

            split.topAnchor.constraint(equalTo: findBar.bottomAnchor),
            split.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            split.bottomAnchor.constraint(equalTo: statusBar.topAnchor),

            statusBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        view = container
        noteContentChanged("")
    }

    private var findBarHeightConstraint: NSLayoutConstraint?

    private var lastWordCount = 0

    /// Renders "N 字 · 阅读约 M 分钟 · 目标 42%" from the cached count — split
    /// out so a goal change in Preferences can re-render without recounting.
    private func renderStatusLine() {
        let count = lastWordCount
        var parts = [String(format: L10n.string("status.wordCount"), count)]
        if count > 0 {
            let minutes = max(1, Int((Double(count) / 400.0).rounded(.up)))
            parts.append(String(format: L10n.string("status.readingTime"), minutes))
        }
        let goal = UserDefaults.standard.integer(forKey: "Vellumi.wordGoal")
        if goal > 0 {
            let percent = Int((Double(count) / Double(goal) * 100).rounded())
            parts.append(String(format: L10n.string("status.wordGoal"), percent, goal))
        }
        wordCountLabel.stringValue = parts.joined(separator: "  ·  ")
    }

    // MARK: - Content updates (from the document)

    /// Called on every bridged change: refreshes word count (off-main) and the
    /// outline (via the editor, only while the sidebar is visible).
    func noteContentChanged(_ text: String) {
        pendingStatsWorkItem?.cancel()
        statsGeneration += 1
        let generation = statsGeneration
        let workItem = DispatchWorkItem { [weak self] in
            let count = MoltenWordCount.count(text)
            DispatchQueue.main.async {
                guard let self, self.statsGeneration == generation else { return }
                self.lastWordCount = count
                self.renderStatusLine()
            }
        }
        pendingStatsWorkItem = workItem
        statsQueue.asyncAfter(deadline: .now() + 0.2, execute: workItem)

        if showsOutline {
            refreshOutline()
        }
        // NOTE: the file tree is NOT refreshed here — document content never
        // changes the folder listing, and a full recursive disk walk per
        // keystroke is pure waste. It refreshes on toggle and after saves.
    }

    private func refreshOutline() {
        editorViewController.fetchOutline { [weak self] headings in
            guard let self, self.outlineModel.headings != headings else { return }
            self.outlineModel.headings = headings
        }
    }

    // MARK: - Outline sidebar

    @objc func toggleOutline(_ sender: Any?) {
        showsOutline.toggle()
        UserDefaults.standard.set(showsOutline, forKey: "Vellumi.showsOutline")
        outlineItem.animator().isCollapsed = !showsOutline
        if showsOutline {
            refreshOutline()
        }
    }

    private func configureSplitViewController() {
        let outlineController = NSViewController()
        outlineController.view = NSHostingView(rootView: MoltenOutlineSidebar(
            model: outlineModel,
            onSelect: { [weak self] heading in
                self?.editorViewController.scrollToHeading(pos: heading.pos)
            }
        ))

        let fileTreeController = NSViewController()
        fileTreeController.view = NSHostingView(rootView: MoltenFileTreeSidebar(
            model: fileTreeModel,
            onOpen: { url in
                NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in
                    if let error { NSApp.presentError(error) }
                }
            }
        ))

        // NSSplitViewItem handles collapse/divider/animation correctly for
        // hidden panes — a bare NSSplitView leaves a stray divider behind.
        fileTreeItem = NSSplitViewItem(sidebarWithViewController: fileTreeController)
        fileTreeItem.minimumThickness = 160
        fileTreeItem.maximumThickness = 320
        fileTreeItem.canCollapse = true
        fileTreeItem.isCollapsed = !showsFileTree

        outlineItem = NSSplitViewItem(sidebarWithViewController: outlineController)
        outlineItem.minimumThickness = 160
        outlineItem.maximumThickness = 320
        outlineItem.canCollapse = true
        outlineItem.isCollapsed = !showsOutline

        let editorItem = NSSplitViewItem(viewController: editorViewController)
        editorItem.minimumThickness = 320

        splitViewController.addSplitViewItem(fileTreeItem)
        splitViewController.addSplitViewItem(outlineItem)
        splitViewController.addSplitViewItem(editorItem)
        addChild(splitViewController)

        // The user can also collapse a sidebar by dragging its divider shut,
        // which bypasses the toggle actions — observe the items so the stored
        // state (and the next toggle) stays truthful.
        collapseObservations = [
            outlineItem.observe(\.isCollapsed) { [weak self] item, _ in
                DispatchQueue.main.async {
                    guard let self, self.showsOutline == item.isCollapsed else { return }
                    self.showsOutline = !item.isCollapsed
                    UserDefaults.standard.set(self.showsOutline, forKey: "Vellumi.showsOutline")
                    if self.showsOutline { self.refreshOutline() }
                }
            },
            fileTreeItem.observe(\.isCollapsed) { [weak self] item, _ in
                DispatchQueue.main.async {
                    guard let self, self.showsFileTree == item.isCollapsed else { return }
                    self.showsFileTree = !item.isCollapsed
                    UserDefaults.standard.set(self.showsFileTree, forKey: "Vellumi.showsFileTree")
                    if self.showsFileTree { self.refreshFileTree() }
                }
            }
        ]
    }

    // MARK: - File tree sidebar

    /// Called by the document after a completed save — the file URL (Save As,
    /// first save) or the folder contents may have changed.
    func noteDocumentSaved() {
        if showsFileTree {
            refreshFileTree()
        }
    }

    @objc func toggleFileTree(_ sender: Any?) {
        showsFileTree.toggle()
        UserDefaults.standard.set(showsFileTree, forKey: "Vellumi.showsFileTree")
        fileTreeItem.animator().isCollapsed = !showsFileTree
        if showsFileTree {
            refreshFileTree()
        }
    }

    /// Rebuilds the tree OFF the main thread, only while visible; a generation
    /// counter drops results superseded by a newer document (MarkMac lessons).
    func refreshFileTree() {
        guard showsFileTree else { return }
        fileTreeGeneration += 1
        let generation = fileTreeGeneration
        guard let folder = document?.fileURL?.deletingLastPathComponent() else {
            fileTreeModel.nodes = []
            fileTreeModel.currentFilePath = nil
            return
        }
        MoltenFolderAccess.shared.ensureAccess(to: folder, interactive: false)
        let currentPath = document?.fileURL.map { MoltenProjectStore.canonicalPath($0) }
        Task { [weak self] in
            let nodes = await Task.detached(priority: .userInitiated) {
                MoltenFileTree.build(at: folder)
            }.value
            guard let self, self.fileTreeGeneration == generation else { return }
            self.fileTreeModel.nodes = nodes
            self.fileTreeModel.currentFilePath = currentPath
        }
    }

    // MARK: - Front matter sheet

    /// Shows the protected YAML block in an editable sheet. The block is
    /// normally invisible by design (the melt editor would mangle it); this
    /// is the explicit hatch for viewing/editing it.
    @objc func editFrontMatter(_ sender: Any?) {
        guard let document, let window = view.window else { return }
        let sheet = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 320),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        sheet.isReleasedWhenClosed = false
        let initial = document.frontMatter.isEmpty
            ? "---\ntitle: \n---\n"
            : document.frontMatter
        sheet.contentViewController = NSHostingController(
            rootView: MoltenFrontMatterSheet(initialText: initial) { [weak self, weak window, weak sheet] newValue in
                guard let window, let sheet else { return }
                defer {
                    window.endSheet(sheet)
                    self?.editorViewController.focusEditingSurface()
                }
                guard let newValue else { return }
                self?.document?.setFrontMatter(newValue)
            }
        )
        window.beginSheet(sheet)
    }

    // MARK: - Source mode (⌘/)

    /// Swaps the melt surface for a plain-markdown NSTextView showing the FULL
    /// file (front matter included) and back. The text view's delegate feeds
    /// every change into the document, so all save paths stay correct while
    /// the web editor is parked.
    @objc func toggleSourceMode(_ sender: Any?) {
        if isSourceMode {
            exitSourceMode()
        } else {
            enterSourceMode()
        }
    }

    private func enterSourceMode() {
        guard let document, !isSourceMode else { return }
        // Flush the newest keystrokes out of the web editor BEFORE freezing it,
        // and capture the reading position so ⌘/ lands where the eye already is.
        editorViewController.fetchScrollFraction { [weak self] fraction in
            self?.pendingSourceScrollFraction = fraction
        }
        editorViewController.pullMarkdown { [weak self] markdown in
            guard let self, let document = self.document else { return }
            if let markdown {
                document.editorTextDidChange(markdown)
            }
            self.isSourceMode = true
            document.sourceModeActive = true

            let scroll = self.sourceScrollView ?? self.makeSourceScrollView()
            self.sourceScrollView = scroll
            if scroll.superview == nil {
                let container = self.view
                scroll.translatesAutoresizingMaskIntoConstraints = false
                container.addSubview(scroll)
                let split = self.splitViewController.view
                NSLayoutConstraint.activate([
                    scroll.topAnchor.constraint(equalTo: split.topAnchor),
                    scroll.leadingAnchor.constraint(equalTo: split.leadingAnchor),
                    scroll.trailingAnchor.constraint(equalTo: split.trailingAnchor),
                    scroll.bottomAnchor.constraint(equalTo: split.bottomAnchor),
                ])
            }
            self.sourceTextView?.string = document.fullSourceText
            scroll.isHidden = false
            self.splitViewController.view.isHidden = true
            self.view.window?.makeFirstResponder(self.sourceTextView)
            // Restore the melt view's reading position in the source view.
            DispatchQueue.main.async {
                self.applySourceScrollFraction(self.pendingSourceScrollFraction)
                self.pendingSourceScrollFraction = 0
            }
        }
    }

    private var pendingSourceScrollFraction: Double = 0

    private func applySourceScrollFraction(_ fraction: Double) {
        guard let scroll = sourceScrollView, let docView = scroll.documentView else { return }
        let maxOffset = max(0, docView.frame.height - scroll.contentSize.height)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: fraction * maxOffset))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    private func currentSourceScrollFraction() -> Double {
        guard let scroll = sourceScrollView, let docView = scroll.documentView else { return 0 }
        let maxOffset = max(1, docView.frame.height - scroll.contentSize.height)
        return Double(scroll.contentView.bounds.origin.y) / Double(maxOffset)
    }

    private func exitSourceMode() {
        guard let document, isSourceMode else { return }
        isSourceMode = false
        document.sourceModeActive = false
        // The delegate already synced every keystroke; adopt once more for
        // safety, then rebuild the melt surface from the (possibly re-split)
        // body text.
        if let sourceTextView {
            document.adoptSourceText(sourceTextView.string)
        }
        let fraction = currentSourceScrollFraction()
        sourceScrollView?.isHidden = true
        splitViewController.view.isHidden = false
        editorViewController.loadDocumentText(document.text)
        // Applied by the JS side once the rebuilt editor lays out.
        editorViewController.setScrollFraction(fraction)
        editorViewController.focusEditingSurface()
    }

    private func makeSourceScrollView() -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = true
        scroll.backgroundColor = .textBackgroundColor

        let textView = NSTextView()
        textView.autoresizingMask = [.width]
        textView.isRichText = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.textContainerInset = NSSize(width: 24, height: 20)
        textView.delegate = self
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.textContainer?.widthTracksTextView = true

        scroll.documentView = textView
        sourceTextView = textView
        return scroll
    }

    // MARK: - Find bar

    @objc func showFind(_ sender: Any?) {
        showFindBar()
    }

    func showFindBar() {
        findBar.isHidden = false
        findBarHeightConstraint?.constant = 34
        view.window?.makeFirstResponder(findField)
    }

    @objc private func hideFindBar(_ sender: Any?) {
        findBar.isHidden = true
        findBarHeightConstraint?.constant = 0
        editorViewController.focusEditingSurface()
    }

    @objc private func findNext(_ sender: Any?) {
        runFind(backwards: false)
    }

    @objc private func findPrevious(_ sender: Any?) {
        runFind(backwards: true)
    }

    private func runFind(backwards: Bool) {
        let term = findField.stringValue
        editorViewController.find(term, backwards: backwards) { found in
            if !found {
                NSSound.beep()
            }
            // Keep typing focus in the field for repeated Enter presses.
        }
    }

    @objc private func replaceNext(_ sender: Any?) {
        editorViewController.replaceNext(findField.stringValue, with: replaceField.stringValue) { replaced in
            if !replaced {
                // Nothing selected/matched yet — the call already advanced to
                // the next match, so the next click replaces it.
            }
        }
    }

    @objc private func replaceAll(_ sender: Any?) {
        editorViewController.replaceAll(findField.stringValue, with: replaceField.stringValue) { count in
            if count == 0 {
                NSSound.beep()
            }
        }
    }

    private func configureFindBar() {
        findBar.material = .headerView
        findBar.blendingMode = .withinWindow
        findBar.isHidden = true

        findField.placeholderString = L10n.string("find.placeholder")
        findField.target = self
        findField.action = #selector(findNext(_:))
        findField.sendsSearchStringImmediately = false

        replaceField.placeholderString = L10n.string("replace.placeholder")
        replaceField.bezelStyle = .roundedBezel
        replaceField.font = findField.font

        let previous = NSButton(title: "‹", target: self, action: #selector(findPrevious(_:)))
        let next = NSButton(title: "›", target: self, action: #selector(findNext(_:)))
        let replaceOne = NSButton(
            title: L10n.string("replace.one"),
            target: self,
            action: #selector(replaceNext(_:))
        )
        let replaceEvery = NSButton(
            title: L10n.string("replace.all"),
            target: self,
            action: #selector(replaceAll(_:))
        )
        let done = NSButton(
            title: L10n.string("find.done"),
            target: self,
            action: #selector(hideFindBar(_:))
        )
        [previous, next, replaceOne, replaceEvery, done].forEach { $0.bezelStyle = .accessoryBarAction }
        done.keyEquivalent = "\u{1b}" // Esc closes the bar

        let row = NSStackView(views: [findField, previous, next, replaceField, replaceOne, replaceEvery, done])
        row.orientation = .horizontal
        row.spacing = 6
        row.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
        row.translatesAutoresizingMaskIntoConstraints = false
        findBar.addSubview(row)
        // The bar collapses to zero height while hidden; the row keeps its own
        // height and gets clipped instead of fighting the collapse.
        findBar.wantsLayer = true
        findBar.layer?.masksToBounds = true
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: findBar.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: findBar.trailingAnchor),
            row.topAnchor.constraint(equalTo: findBar.topAnchor),
            row.heightAnchor.constraint(equalToConstant: 34),
            findField.widthAnchor.constraint(greaterThanOrEqualToConstant: 180),
            replaceField.widthAnchor.constraint(greaterThanOrEqualToConstant: 150),
        ])
    }

    // MARK: - Status bar

    private func configureStatusBar() {
        NotificationCenter.default.addObserver(
            forName: .moltenWordGoalChanged, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.renderStatusLine() }
        }
        statusBar.material = .titlebar
        statusBar.blendingMode = .withinWindow

        wordCountLabel.font = .systemFont(ofSize: 11)
        wordCountLabel.textColor = .secondaryLabelColor
        wordCountLabel.translatesAutoresizingMaskIntoConstraints = false
        statusBar.addSubview(wordCountLabel)
        NSLayoutConstraint.activate([
            statusBar.heightAnchor.constraint(equalToConstant: 24),
            wordCountLabel.leadingAnchor.constraint(equalTo: statusBar.leadingAnchor, constant: 12),
            wordCountLabel.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor),
        ])
    }
}

// MARK: - Unified toolbar

extension MoltenWorkspaceViewController: NSToolbarDelegate {
    private static let outlineItemID = NSToolbarItem.Identifier("vellumi.outline")
    private static let fileTreeItemID = NSToolbarItem.Identifier("vellumi.filetree")
    private static let exportItemID = NSToolbarItem.Identifier("vellumi.export")

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.outlineItemID, Self.fileTreeItemID, .flexibleSpace, Self.exportItemID]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch itemIdentifier {
        case Self.outlineItemID:
            return makeButtonItem(
                id: itemIdentifier,
                symbol: "list.bullet.rectangle",
                labelKey: "toolbar.outline",
                action: #selector(toggleOutline(_:))
            )
        case Self.fileTreeItemID:
            return makeButtonItem(
                id: itemIdentifier,
                symbol: "folder",
                labelKey: "toolbar.fileTree",
                action: #selector(toggleFileTree(_:))
            )
        case Self.exportItemID:
            let item = NSMenuToolbarItem(itemIdentifier: itemIdentifier)
            item.image = NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: L10n.string("toolbar.export"))
            item.label = L10n.string("toolbar.export")
            item.toolTip = L10n.string("toolbar.export")
            let menu = NSMenu()
            menu.addItem(withTitle: L10n.string("menu.exportHTML"), action: #selector(exportHTML(_:)), keyEquivalent: "")
            menu.addItem(withTitle: L10n.string("menu.exportPDF"), action: #selector(exportPDF(_:)), keyEquivalent: "")
            menu.addItem(withTitle: L10n.string("menu.exportImageCards"), action: #selector(exportImageCards(_:)), keyEquivalent: "")
            menu.addItem(.separator())
            menu.addItem(withTitle: L10n.string("menu.print"), action: #selector(printDocument(_:)), keyEquivalent: "")
            for entry in menu.items { entry.target = self }
            item.menu = menu
            item.showsIndicator = true
            return item
        default:
            return nil
        }
    }

    private func makeButtonItem(
        id: NSToolbarItem.Identifier,
        symbol: String,
        labelKey: String,
        action: Selector
    ) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: id)
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: L10n.string(labelKey))
        item.label = L10n.string(labelKey)
        item.toolTip = L10n.string(labelKey)
        item.target = self
        item.action = action
        item.isBordered = true
        return item
    }
}

extension MoltenWorkspaceViewController: NSTextViewDelegate {
    func textDidChange(_ notification: Notification) {
        guard isSourceMode, let textView = sourceTextView else { return }
        document?.adoptSourceText(textView.string)
    }
}

extension MoltenWorkspaceViewController: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleSourceMode(_:)) {
            menuItem.state = isSourceMode ? .on : .off
        }
        return true
    }
}

// MARK: - Outline sidebar (SwiftUI)

struct MoltenOutlineSidebar: View {
    @ObservedObject var model: MoltenOutlineModel
    let onSelect: (MoltenHeading) -> Void

    @State private var selection: Int?

    var body: some View {
        Group {
            if model.headings.isEmpty {
                Text(L10n.string("outline.empty"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(12)
            } else {
                // Button rows: click always navigates (including the selected
                // row); arrow-key selection navigates via onChange.
                List(selection: $selection) {
                    ForEach(model.headings) { heading in
                        Button {
                            // Route through `selection` so the List highlight
                            // always follows the click; only a re-click on the
                            // already-selected row navigates directly (no
                            // selection change → onChange stays silent).
                            if selection == heading.pos {
                                onSelect(heading)
                            } else {
                                selection = heading.pos
                            }
                        } label: {
                            Text(heading.text.isEmpty ? "—" : heading.text)
                                .font(.callout)
                                .fontWeight(heading.level <= 1 ? .semibold : .regular)
                                .lineLimit(1)
                                .padding(.leading, 4 + CGFloat(max(0, heading.level - 1)) * 12)
                                .padding(.vertical, 3)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                // Full-row hit area: bare Text only hit-tests
                                // its glyphs — clicking ON the text hit the
                                // button (navigate, no highlight) while the
                                // blank space hit the row (highlight). Unify.
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .tag(heading.pos)
                    }
                }
                .listStyle(.sidebar)
                .padding(.top, 6)
                .onChange(of: selection) { pos in
                    if let pos, let heading = model.headings.first(where: { $0.pos == pos }) {
                        onSelect(heading)
                    }
                }
            }
        }
        .frame(minWidth: 160, maxWidth: 320, maxHeight: .infinity)
    }
}
