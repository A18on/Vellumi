import AppKit

/// Markdown document backed by the WYSIWYG editing surface.
///
/// Ownership split: NSDocument owns the FILE (open/save/autosave/dirty state);
/// the JS editor owns the SESSION (melting render, in-editor undo). `text` is
/// the last serialization reported over the bridge, refreshed at the single
/// save chokepoint below so no write path can persist stale content.
final class MoltenDocument: NSDocument {
    static let markdownType = "net.daringfireball.markdown"
    /// Refuse absurd files up front — a WYSIWYG DOM at this size would hang
    /// long before memory becomes the problem.
    static let maximumFileSize = 20 * 1024 * 1024
    /// Single source of truth for the initial window/web view size (the web
    /// view lays out its page at its pre-attach frame; a mismatch causes a
    /// visible reflow flash on open).
    static let defaultContentSize = NSSize(width: 900, height: 720)

    private(set) var text: String = ""
    /// Serialization at the last successful read/save. Lets an in-editor undo
    /// back to the saved state clear the dirty flag instead of leaving the
    /// document permanently "Edited".
    private var savedText: String = ""
    weak var editorViewController: MoltenEditorViewController?
    weak var workspaceViewController: MoltenWorkspaceViewController?

    override class var autosavesInPlace: Bool { true }
    override class var readableTypes: [String] { [markdownType] }
    override class var writableTypes: [String] { [markdownType] }

    override func makeWindowControllers() {
        let workspace = MoltenWorkspaceViewController(document: self)
        workspaceViewController = workspace
        editorViewController = workspace.editorViewController

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.defaultContentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.minSize = NSSize(width: 480, height: 320)
        window.titlebarAppearsTransparent = true
        window.contentViewController = workspace
        // Assigning contentViewController resizes the window to the view's
        // fitting size (tiny — the web view has no intrinsic size). Restore a
        // saved frame if one exists; otherwise apply the default and center.
        // Order matters: setFrameAutosaveName alone would re-apply the saved
        // frame AFTER any size we set here.
        let restoredSavedFrame = window.setFrameUsingName("MoltenDocumentWindow")
        window.setFrameAutosaveName("MoltenDocumentWindow")
        if !restoredSavedFrame {
            window.setContentSize(Self.defaultContentSize)
            window.center()
        }

        addWindowController(NSWindowController(window: window))
    }

    // MARK: - Reading / writing

    override func read(from data: Data, ofType typeName: String) throws {
        guard data.count <= Self.maximumFileSize else {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadTooLargeError, userInfo: [
                NSLocalizedDescriptionKey: String(
                    format: NSLocalizedString(
                        "document.error.tooLarge",
                        value: "This file is larger than %d MB, which Molten cannot edit yet.",
                        comment: "file too large"
                    ),
                    Self.maximumFileSize / (1024 * 1024)
                ),
            ])
        }
        let decoded = try Self.decodeText(from: data)
        text = decoded
        savedText = decoded
        editorViewController?.loadDocumentText(decoded)
    }

    /// UTF-8, plus deterministic BOM-identified UTF-16 (TextEdit's "Unicode"
    /// flavor). No lossy fallbacks: guessing an encoding is how editors
    /// corrupt files, so anything else refuses to open.
    static func decodeText(from data: Data) throws -> String {
        if data.isEmpty {
            return ""
        }
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]),
           let utf16 = String(data: data, encoding: .utf16) {
            return utf16
        }
        guard var decoded = String(data: data, encoding: .utf8) else {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadInapplicableStringEncodingError, userInfo: [
                NSLocalizedDescriptionKey: NSLocalizedString(
                    "document.error.encoding",
                    value: "This file is not UTF-8 text. Molten refuses to guess the encoding rather than risk corrupting it.",
                    comment: "not UTF-8"
                ),
            ])
        }
        if decoded.hasPrefix("\u{FEFF}") {
            decoded.removeFirst()
        }
        return decoded
    }

    override func data(ofType typeName: String) throws -> Data {
        Data(text.utf8)
    }

    // MARK: - Save chokepoint

    /// EVERY save operation funnels through here (explicit save, Save As,
    /// autosave-in-place, save-on-close, save-on-terminate). Refresh `text`
    /// from the live editor first so the debounced change stream can't leave
    /// the last keystrokes behind on ANY write path.
    override func save(
        to url: URL,
        ofType typeName: String,
        for saveOperation: NSDocument.SaveOperationType,
        completionHandler: @escaping (Error?) -> Void
    ) {
        refreshTextFromEditor {
            super.save(to: url, ofType: typeName, for: saveOperation) { error in
                if error == nil {
                    self.savedText = self.text
                }
                completionHandler(error)
            }
        }
    }

    /// Belt-and-braces: some autosave variants enter here before reaching the
    /// save(to:...) funnel. Refreshing twice is a cheap no-op.
    override func autosave(
        withImplicitCancellability autosavingIsImplicitlyCancellable: Bool,
        completionHandler: @escaping (Error?) -> Void
    ) {
        refreshTextFromEditor {
            super.autosave(
                withImplicitCancellability: autosavingIsImplicitlyCancellable,
                completionHandler: completionHandler
            )
        }
    }

    private func refreshTextFromEditor(then continuation: @escaping () -> Void) {
        guard let editor = editorViewController else {
            continuation()
            return
        }
        editor.pullMarkdown { markdown in
            // nil = editor unavailable (booting/rebuilding); keep what we have.
            if let markdown, markdown != self.text {
                self.text = markdown
                // Content adopted at save time must count as a change: pulling
                // flushes the JS debounce, so the change message that would
                // have dirtied the document will never arrive — and saving a
                // "clean" document performs no write at all.
                self.updateChangeCount(.changeDone)
            }
            continuation()
        }
    }

    // MARK: - Bridge callbacks

    /// Debounced content updates from the JS side keep `text` current for
    /// crash recovery and drive the dirty flag — including clearing it when
    /// an in-editor undo returns to the saved state.
    func editorTextDidChange(_ markdown: String) {
        guard markdown != text else { return }
        text = markdown
        updateChangeCount(markdown == savedText ? .changeCleared : .changeDone)
        workspaceViewController?.noteContentChanged(markdown)
    }

    /// The editor surface finished booting (or reloaded after a web-content
    /// process crash) — push the authoritative document content into it.
    func editorDidBecomeReady() {
        editorViewController?.loadDocumentText(text)
        workspaceViewController?.noteContentChanged(text)
    }

    // MARK: - External changes on disk

    /// Another process rewrote the file (git checkout, sync, another editor).
    /// For a CLEAN document, adopt the new content automatically; a dirty
    /// document keeps NSDocument's own conflict handling.
    override func presentedItemDidChange() {
        super.presentedItemDidChange()
        DispatchQueue.main.async { [weak self] in
            self?.reloadIfCleanAndChangedOnDisk()
        }
    }

    func reloadIfCleanAndChangedOnDisk() {
        guard let url = fileURL, !isDocumentEdited else { return }
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        guard let onDisk = values?.contentModificationDate else { return }
        if let recorded = fileModificationDate, onDisk <= recorded { return }
        // Same size ceiling as the open path — an external swap to a huge file
        // must not trigger an unbounded read.
        if let size = values?.fileSize, size > Self.maximumFileSize { return }
        guard let data = try? Data(contentsOf: url),
              data.count <= Self.maximumFileSize,
              let reloaded = try? Self.decodeText(from: data) else {
            return
        }
        fileModificationDate = onDisk
        guard reloaded != text else { return }
        text = reloaded
        savedText = reloaded
        updateChangeCount(.changeCleared)
        // Rebuilding the editor from the new content also resets ProseMirror's
        // history — stale undo entries can't replay onto the reloaded text.
        editorViewController?.loadDocumentText(reloaded)
        workspaceViewController?.noteContentChanged(reloaded)
        MoltenLog.document.info("Reloaded document after external change on disk")
    }
}
