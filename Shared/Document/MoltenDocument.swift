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
    /// Leading YAML front matter, held OUT of the editor and spliced back on
    /// every write (see MoltenFrontMatter — the editor would mangle it).
    private(set) var frontMatter: String = ""
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
                    format: L10n.string("document.error.tooLarge"),
                    Self.maximumFileSize / (1024 * 1024)
                ),
            ])
        }
        let decoded = try Self.decodeText(from: data)
        let parts = MoltenFrontMatter.split(decoded)
        frontMatter = parts.frontMatter
        text = parts.body
        savedText = parts.body
        editorViewController?.loadDocumentText(parts.body)
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
                NSLocalizedDescriptionKey: L10n.string("document.error.encoding"),
            ])
        }
        if decoded.hasPrefix("\u{FEFF}") {
            decoded.removeFirst()
        }
        return decoded
    }

    override func data(ofType typeName: String) throws -> Data {
        Data(MoltenFrontMatter.join(frontMatter: frontMatter, body: text).utf8)
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

    // MARK: - Image attachments

    /// Writes a pasted/dropped image into `assets/` next to the document and
    /// returns the document-relative path, or nil when it can't (no file yet,
    /// permission declined, bad payload). Runs on the main thread — the write
    /// is small and the open panel needs it anyway.
    func saveImageAttachment(name: String, base64: String) -> String? {
        guard let fileURL else {
            let alert = NSAlert()
            alert.messageText = L10n.string("image.needsSave.title")
            alert.informativeText = L10n.string("image.needsSave.message")
            alert.runModal()
            return nil
        }
        guard let data = Data(base64Encoded: base64), !data.isEmpty else { return nil }

        let folder = fileURL.deletingLastPathComponent()
        guard MoltenFolderAccess.shared.ensureAccess(to: folder, interactive: true) else {
            return nil
        }

        let assetsDirectory = folder.appendingPathComponent("assets", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: assetsDirectory, withIntermediateDirectories: true)
            let target = Self.uniqueAssetURL(in: assetsDirectory, preferredName: name)
            try data.write(to: target, options: .withoutOverwriting)
            return "assets/\(target.lastPathComponent)"
        } catch {
            MoltenLog.document.error("Image save failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Sanitized, collision-free file URL inside the assets directory.
    static func uniqueAssetURL(in directory: URL, preferredName: String) -> URL {
        // Strip any path components and characters that complicate markdown.
        let base = (preferredName as NSString).lastPathComponent
            .replacingOccurrences(of: "[\\\\/:*?\"<>|()\\[\\]\\s]+", with: "-", options: .regularExpression)
        let ext = (base as NSString).pathExtension.isEmpty ? "png" : (base as NSString).pathExtension
        var stem = (base as NSString).deletingPathExtension
        if stem.isEmpty { stem = "image" }

        var candidate = directory.appendingPathComponent("\(stem).\(ext)")
        var counter = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(stem)-\(counter).\(ext)")
            counter += 1
        }
        return candidate
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
        let parts = MoltenFrontMatter.split(reloaded)
        guard parts.body != text || parts.frontMatter != frontMatter else { return }
        frontMatter = parts.frontMatter
        text = parts.body
        savedText = parts.body
        updateChangeCount(.changeCleared)
        // Rebuilding the editor from the new content also resets ProseMirror's
        // history — stale undo entries can't replay onto the reloaded text.
        editorViewController?.loadDocumentText(parts.body)
        workspaceViewController?.noteContentChanged(parts.body)
        MoltenLog.document.info("Reloaded document after external change on disk")
    }
}
