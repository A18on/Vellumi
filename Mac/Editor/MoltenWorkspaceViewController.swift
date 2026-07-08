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
    private let splitViewController = NSSplitViewController()
    private var outlineItem: NSSplitViewItem!
    private let findBar = NSVisualEffectView()
    private let findField = NSSearchField()
    private let statusBar = NSVisualEffectView()
    private let wordCountLabel = NSTextField(labelWithString: "")
    private var showsOutline = UserDefaults.standard.bool(forKey: "Molten.showsOutline")
    private var pendingStatsWorkItem: DispatchWorkItem?
    private let statsQueue = DispatchQueue(label: "com.aaron.molten.stats", qos: .utility)
    private var statsGeneration = 0

    init(document: MoltenDocument) {
        editorViewController = MoltenEditorViewController(document: document)
        super.init(nibName: nil, bundle: nil)
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
                self.wordCountLabel.stringValue = String(
                    format: L10n.string("status.wordCount"),
                    count
                )
            }
        }
        pendingStatsWorkItem = workItem
        statsQueue.asyncAfter(deadline: .now() + 0.2, execute: workItem)

        if showsOutline {
            refreshOutline()
        }
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
        UserDefaults.standard.set(showsOutline, forKey: "Molten.showsOutline")
        outlineItem.animator().isCollapsed = !showsOutline
        if showsOutline {
            refreshOutline()
        }
    }

    private func configureSplitViewController() {
        let sidebarController = NSViewController()
        sidebarController.view = NSHostingView(rootView: MoltenOutlineSidebar(
            model: outlineModel,
            onSelect: { [weak self] heading in
                self?.editorViewController.scrollToHeading(pos: heading.pos)
            }
        ))

        // NSSplitViewItem handles collapse/divider/animation correctly for
        // hidden panes — a bare NSSplitView leaves a stray divider behind.
        outlineItem = NSSplitViewItem(sidebarWithViewController: sidebarController)
        outlineItem.minimumThickness = 160
        outlineItem.maximumThickness = 320
        outlineItem.canCollapse = true
        outlineItem.isCollapsed = !showsOutline

        let editorItem = NSSplitViewItem(viewController: editorViewController)
        editorItem.minimumThickness = 320

        splitViewController.addSplitViewItem(outlineItem)
        splitViewController.addSplitViewItem(editorItem)
        addChild(splitViewController)
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
        editorViewController.find(term, backwards: backwards) { [weak self] found in
            if !found {
                NSSound.beep()
            }
            // Keep typing focus in the field for repeated Enter presses.
            _ = self
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

        let previous = NSButton(title: "‹", target: self, action: #selector(findPrevious(_:)))
        let next = NSButton(title: "›", target: self, action: #selector(findNext(_:)))
        let done = NSButton(
            title: L10n.string("find.done"),
            target: self,
            action: #selector(hideFindBar(_:))
        )
        [previous, next, done].forEach { $0.bezelStyle = .accessoryBarAction }
        done.keyEquivalent = "\u{1b}" // Esc closes the bar

        let row = NSStackView(views: [findField, previous, next, done])
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
            findField.widthAnchor.constraint(greaterThanOrEqualToConstant: 240),
        ])
    }

    // MARK: - Status bar

    private func configureStatusBar() {
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
                            onSelect(heading)
                        } label: {
                            Text(heading.text.isEmpty ? "—" : heading.text)
                                .font(.callout)
                                .fontWeight(heading.level <= 1 ? .semibold : .regular)
                                .lineLimit(1)
                                .padding(.leading, CGFloat(max(0, heading.level - 1)) * 12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .tag(heading.pos)
                    }
                }
                .listStyle(.sidebar)
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
