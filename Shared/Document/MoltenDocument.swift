import AppKit

/// Markdown document backed by the WYSIWYG editing surface.
///
/// Ownership split: NSDocument owns the FILE (open/save/autosave/dirty state);
/// the JS editor owns the SESSION (melting render, in-editor undo). `text` is
/// the last serialization reported over the bridge, refreshed at the single
/// save chokepoint below so no write path can persist stale content.
final class MoltenDocument: NSDocument {
    static let markdownType = "net.daringfireball.markdown"
    /// Refuse files the melt surface cannot edit interactively. Measured
    /// (docs/PERF.md): serialization runs on the JS main thread and costs
    /// ~103 ms at 431 KB, scaling linearly — the old 20 MB ceiling worked out
    /// to ~4.8 s per flush, far past the 2 s adaptive-debounce cap, i.e. a
    /// permanently beachballed editor. 4 MB (~1 s) is the honest limit; larger
    /// files are refused with a message that points at source mode.
    static let maximumFileSize = 4 * 1024 * 1024
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
    /// Front matter as last read from / written to disk. Without this the
    /// dirty flag only tracked the body, so YAML-only edits looked clean.
    private var savedFrontMatter: String = ""
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
        // Native window tabs (⌘T-style tabbing, Merge All Windows). Preferred
        // rather than automatic so documents tab together even when the
        // system-wide setting is "never".
        window.tabbingMode = .preferred
        window.tabbingIdentifier = "VellumiDocument"
        window.titlebarAppearsTransparent = true
        // Editor surface color extends into the titlebar (Bear/Craft-style
        // seamless chrome).
        window.backgroundColor = .textBackgroundColor
        window.contentViewController = workspace

        // Unified toolbar: sidebar toggles on the left, export on the right —
        // one-click access to what were previously menu-only features.
        let toolbar = NSToolbar(identifier: "VellumiDocumentToolbar")
        toolbar.delegate = workspace
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        window.toolbarStyle = .unified
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
        savedFrontMatter = parts.frontMatter
        editorViewController?.loadDocumentText(parts.body)
        // Revert (File ▸ Revert To Saved) lands here too: the source view, if
        // showing, must be re-seeded or its stale text is re-adopted on the
        // next keystroke and undoes the revert.
        workspaceViewController?.noteDocumentContentReplaced()
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
        // A BOM-less UTF-16 file decodes "successfully" as UTF-8 because NUL is
        // a valid UTF-8 byte — the result is NUL-riddled mojibake that would
        // then be written back over the original. Real Markdown never contains
        // NUL, so treat it as the corruption signal it is.
        if data.contains(0x00) {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadInapplicableStringEncodingError, userInfo: [
                NSLocalizedDescriptionKey: L10n.string("document.error.encoding"),
            ])
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

    /// EVERY save operation funnels through here. DEADLOCK RULE: nothing in
    /// this override (or autosave) may hop the main queue asynchronously —
    /// NSDocument wraps saves in a "file activity", and canClose/terminate
    /// WAIT SYNCHRONOUSLY on the main thread for open activities. An activity
    /// that needs a main-queue callback (evaluateJavaScript) to finish can
    /// then never finish: the app hard-hangs on the last window close.
    /// Editor freshness is instead guaranteed BEFORE the machinery starts:
    /// canClose/saveDocument/saveDocumentAs below pull the editor first, and
    /// the change stream keeps `text` at most ~1s stale for plain autosaves.
    override func save(
        to url: URL,
        ofType typeName: String,
        for saveOperation: NSDocument.SaveOperationType,
        completionHandler: @escaping (Error?) -> Void
    ) {
        // Snapshot BEFORE the async write: keystrokes bridged during the
        // write must not be recorded as "on disk".
        let snapshot = self.text
        let frontMatterSnapshot = self.frontMatter
        super.save(to: url, ofType: typeName, for: saveOperation) { error in
            // autosave-ELSEWHERE writes a recovery file, not the document;
            // treating it as saved would let undo-back-to-it read as clean
            // and close without a prompt, losing the content.
            if error == nil, saveOperation != .autosaveElsewhereOperation {
                self.savedText = snapshot
                self.savedFrontMatter = frontMatterSnapshot
                // fileURL may have just come into existence (first save of an
                // untitled/draft document) or moved (Save As) — the image
                // scheme must follow it or pastes render as broken images.
                self.editorViewController?.noteDocumentURLChanged()
                // Autosave-in-place cannot change the folder listing, and a
                // full recursive rescan (one realpath per node) on every
                // autosave was pure churn. Only real saves can add/rename.
                if saveOperation != .autosaveInPlaceOperation {
                    self.workspaceViewController?.noteDocumentSaved()
                }
            }
            completionHandler(error)
        }
    }

    /// User-initiated save (⌘S): pull the freshest serialization from the
    /// editor BEFORE entering the save machinery — outside any file activity,
    /// so the async hop is deadlock-free.
    override func save(_ sender: Any?) {
        refreshTextFromEditor { [weak self] in
            self?.superSave(sender)
        }
    }

    // Swift can't call super from a self-capturing closure; trampolines.
    private func superSave(_ sender: Any?) { super.save(sender) }
    private func superSaveAs(_ sender: Any?) { super.saveAs(sender) }
    private func superCanClose(
        withDelegate delegate: Any,
        shouldClose shouldCloseSelector: Selector?,
        contextInfo: UnsafeMutableRawPointer?
    ) {
        super.canClose(withDelegate: delegate, shouldClose: shouldCloseSelector, contextInfo: contextInfo)
    }

    /// Save As (⇧⌘S): same pre-pull as save.
    override func saveAs(_ sender: Any?) {
        refreshTextFromEditor { [weak self] in
            self?.superSaveAs(sender)
        }
    }

    /// Close (⌘W / window button / app termination review): pull first, then
    /// let AppKit run its synchronous-waiting close dance against a document
    /// whose `text` is already current and whose activities are all idle.
    override func canClose(
        withDelegate delegate: Any,
        shouldClose shouldCloseSelector: Selector?,
        contextInfo: UnsafeMutableRawPointer?
    ) {
        refreshTextFromEditor { [weak self] in
            self?.superCanClose(
                withDelegate: delegate,
                shouldClose: shouldCloseSelector,
                contextInfo: contextInfo
            )
        }
    }

    private func refreshTextFromEditor(then continuation: @escaping () -> Void) {
        // Source mode: the NSTextView delegate pushes every keystroke into
        // `text` synchronously, and the web editor holds STALE content —
        // pulling from it would overwrite the source edits.
        guard !sourceModeActive, let editor = editorViewController else {
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

    // MARK: - Source mode

    /// True while the workspace shows the plain-markdown source view; save
    /// paths then trust `text` instead of pulling from the web editor.
    var sourceModeActive = false

    /// Full on-disk representation (front matter + body) for the source view.
    var fullSourceText: String {
        MoltenFrontMatter.join(frontMatter: frontMatter, body: text)
    }

    /// Adopts edits from the source view. The full text is re-split so front
    /// matter added/edited/removed in source mode is honored.
    func adoptSourceText(_ fullText: String) {
        let parts = MoltenFrontMatter.split(fullText)
        let frontMatterChanged = parts.frontMatter != frontMatter
        frontMatter = parts.frontMatter
        applyBodyText(parts.body)
        // A front-matter-only edit leaves the body byte-identical, so
        // applyBodyText early-returns and nothing would ever mark the document
        // dirty — ⌘S wrote nothing and the YAML edit was silently discarded.
        if frontMatterChanged, parts.body == text {
            updateChangeCount(isEquivalentToSavedFile(body: text) ? .changeCleared : .changeDone)
        }
    }

    /// Adopts an edited front-matter block from the editor sheet. Callers
    /// validate the fence shape; this only records the change.
    func setFrontMatter(_ newValue: String) {
        guard newValue != frontMatter else { return }
        frontMatter = newValue
        updateChangeCount(isEquivalentToSavedFile(body: text) ? .changeCleared : .changeDone)
    }

    // MARK: - Bridge callbacks

    /// Debounced content updates from the JS side keep `text` current for
    /// crash recovery and drive the dirty flag. NOTE: with adaptive throttling
    /// the worst-case staleness is the JS max-latency bound (3s on a large
    /// document), not the 1s the original design assumed — this only widens the
    /// crash-recovery window; every save path pulls fresh text first. — including clearing it when
    /// an in-editor undo returns to the saved state.
    func editorTextDidChange(_ markdown: String) {
        // Source mode parks the web editor holding pre-⌘/ content, so anything
        // arriving FROM it is stale: adopting it would overwrite the source
        // view's edits in the model while the visible NSTextView keeps showing
        // them, and the edits would vanish on close. The guard belongs here, on
        // the bridge entry point — NOT on applyBodyText, which the source view
        // itself calls through adoptSourceText.
        guard !sourceModeActive else { return }
        applyBodyText(markdown)
    }

    /// The single body mutation both surfaces funnel through.
    private func applyBodyText(_ markdown: String) {
        guard markdown != text else { return }
        text = markdown
        updateChangeCount(isEquivalentToSavedFile(body: markdown) ? .changeCleared : .changeDone)
        workspaceViewController?.noteContentChanged(markdown)
    }

    /// Clean means BOTH parts match what was last read from / written to disk.
    /// Comparing only the body let a front-matter-only edit read as clean.
    private func isEquivalentToSavedFile(body: String) -> Bool {
        body == savedText && frontMatter == savedFrontMatter
    }

    /// The editor reported its serialization right after (re)building. Crepe
    /// normalizes Markdown on load, so for any file not already in its
    /// canonical form this differs from what was read off disk — and the pull
    /// in canClose then dirtied the document, letting autosave-in-place rewrite
    /// a file the user only opened and closed. Adopting the normalized form as
    /// the clean baseline removes that whole class of phantom edits.
    func editorDidNormalize(_ markdown: String, changed: Bool) {
        // Never on a dirty document: exiting source mode also rebuilds the
        // editor, and clearing the flag there would hide real unsaved edits.
        guard !isDocumentEdited, !sourceModeActive else { return }
        text = markdown
        savedText = markdown
        if changed {
            workspaceViewController?.showNormalizationNoticeOnce()
        }
    }

    /// The editor surface finished booting (or reloaded after a web-content
    /// process crash) — push the authoritative document content into it.
    func editorDidBecomeReady() {
        editorViewController?.loadDocumentText(text)
        workspaceViewController?.noteContentChanged(text)
    }

    // MARK: - Image attachments

    /// The document-relative path recorded in the Markdown for a saved image.
    /// Percent-encodes both components the way the display-time rewrite in
    /// Editor/src/main.js (`encodeURI`) expects, so folder or file names with
    /// spaces resolve through the molten-asset scheme.
    static func documentRelativeAssetPath(folderName: String, fileName: String) -> String {
        let allowed = CharacterSet.urlPathAllowed
        let folder = folderName.addingPercentEncoding(withAllowedCharacters: allowed) ?? folderName
        let file = fileName.addingPercentEncoding(withAllowedCharacters: allowed) ?? fileName
        return "\(folder)/\(file)"
    }

    /// Preferences ▸ Files ▸ image folder. Sanitized to a single path
    /// component — separators/dots would escape the document folder.
    static var imageFolderName: String {
        let raw = UserDefaults.standard.string(forKey: "Vellumi.imageFolderName") ?? "assets"
        let cleaned = raw
            .components(separatedBy: CharacterSet(charactersIn: "/\\:"))
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty || cleaned == "." || cleaned == ".." {
            return "assets"
        }
        return cleaned
    }

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

        let assetsDirectory = folder.appendingPathComponent(Self.imageFolderName, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: assetsDirectory, withIntermediateDirectories: true)
            let target = Self.uniqueAssetURL(in: assetsDirectory, preferredName: name)
            try data.write(to: target, options: .withoutOverwriting)
            // Must mirror the directory we actually wrote into — hardcoding
            // "assets/" here silently produced dead links for anyone who
            // changed the folder name in Preferences.
            return Self.documentRelativeAssetPath(folderName: Self.imageFolderName, fileName: target.lastPathComponent)
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
        // The dirty flag lags the editor by up to the JS debounce window —
        // flush it first, or an external change could clobber the last second
        // of typing. In source mode there is nothing to flush: the NSTextView
        // delegate already pushed every keystroke into `text` synchronously.
        guard !sourceModeActive, let editor = editorViewController else {
            performReloadIfCleanAndChangedOnDisk()
            return
        }
        editor.pullMarkdown { [weak self] markdown in
            if let self, let markdown {
                self.editorTextDidChange(markdown)
            }
            self?.performReloadIfCleanAndChangedOnDisk()
        }
    }

    private func performReloadIfCleanAndChangedOnDisk() {
        guard let url = fileURL, !isDocumentEdited else { return }
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        guard let onDisk = values?.contentModificationDate else { return }
        if let recorded = fileModificationDate, onDisk <= recorded { return }
        // Same size ceiling as the open path — an external swap to a huge file
        // must not trigger an unbounded read.
        if let size = values?.fileSize, size > Self.maximumFileSize { return }
        // Coordinated read: an uncoordinated Data(contentsOf:) can observe a
        // torn half-written file mid-sync and record it as authoritative.
        var coordinatedData: Data?
        let coordinator = NSFileCoordinator(filePresenter: self)
        coordinator.coordinate(readingItemAt: url, options: [], error: nil) { readURL in
            coordinatedData = try? Data(contentsOf: readURL)
        }
        guard let data = coordinatedData,
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
        savedFrontMatter = parts.frontMatter
        updateChangeCount(.changeCleared)
        // Rebuilding the editor from the new content also resets ProseMirror's
        // history — stale undo entries can't replay onto the reloaded text.
        editorViewController?.loadDocumentText(parts.body)
        workspaceViewController?.noteContentChanged(parts.body)
        workspaceViewController?.noteDocumentContentReplaced()
        MoltenLog.document.info("Reloaded document after external change on disk")
    }
}
