import AppKit
import UniformTypeIdentifiers

/// Markdown document backed by the WYSIWYG editing surface.
///
/// Ownership split: NSDocument owns the FILE (open/save/autosave/dirty state);
/// the JS editor owns the SESSION (melting render, in-editor undo). `text` is
/// the last serialization reported over the bridge, refreshed eagerly before
/// explicit saves so Cmd+S can never write stale content.
final class MoltenDocument: NSDocument {
    static let markdownType = "net.daringfireball.markdown"
    /// Refuse absurd files up front — a WYSIWYG DOM at this size would hang
    /// long before memory becomes the problem.
    static let maximumFileSize = 20 * 1024 * 1024

    private(set) var text: String = ""
    weak var editorViewController: MoltenEditorViewController?

    override class var autosavesInPlace: Bool { true }
    override class var readableTypes: [String] { [markdownType, UTType.plainText.identifier] }
    override class var writableTypes: [String] { [markdownType] }

    override func makeWindowControllers() {
        let controller = MoltenEditorViewController(document: self)
        editorViewController = controller

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.minSize = NSSize(width: 480, height: 320)
        window.titlebarAppearsTransparent = true
        window.contentViewController = controller
        window.center()
        window.setFrameAutosaveName("MoltenDocumentWindow")

        let windowController = NSWindowController(window: window)
        addWindowController(windowController)
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
        // UTF-8 only, no lossy fallback: silently reinterpreting bytes is how
        // editors corrupt files. Unreadable input should fail the open.
        guard let decoded = String(data: data, encoding: .utf8) else {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadInapplicableStringEncodingError, userInfo: [
                NSLocalizedDescriptionKey: NSLocalizedString(
                    "document.error.encoding",
                    value: "This file is not UTF-8 text. Molten refuses to guess the encoding rather than risk corrupting it.",
                    comment: "not UTF-8"
                ),
            ])
        }
        text = decoded
        editorViewController?.loadDocumentText(decoded)
    }

    override func data(ofType typeName: String) throws -> Data {
        Data(text.utf8)
    }

    /// Explicit save: pull the freshest serialization from the editor first so
    /// the debounced change stream can't leave the last keystrokes behind.
    override func save(
        withDelegate delegate: Any?,
        didSave didSaveSelector: Selector?,
        contextInfo: UnsafeMutableRawPointer?
    ) {
        guard let editor = editorViewController else {
            super.save(withDelegate: delegate, didSave: didSaveSelector, contextInfo: contextInfo)
            return
        }
        // Strong capture is intentional: the document must stay alive through
        // its own save. (Also required — `super` is unavailable in closures
        // that capture self explicitly.)
        editor.pullMarkdown { markdown in
            if let markdown {
                self.text = markdown
            }
            super.save(withDelegate: delegate, didSave: didSaveSelector, contextInfo: contextInfo)
        }
    }

    // MARK: - Bridge callbacks

    /// Debounced content updates from the JS side keep `text` current for
    /// autosave and mark the document edited.
    func editorTextDidChange(_ markdown: String) {
        guard markdown != text else { return }
        text = markdown
        updateChangeCount(.changeDone)
    }

    /// The editor surface finished booting (or reloaded after a web-content
    /// process crash) — push the authoritative document content into it.
    func editorDidBecomeReady() {
        editorViewController?.loadDocumentText(text)
    }
}
