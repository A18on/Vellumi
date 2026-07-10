import AppKit

/// Custom document controller so File ▸ New can honor an optional Drafts
/// folder: with one configured, a new document is backed by a real `.md` up
/// front (autosave owns it from keystroke one). Without one, standard untitled
/// behavior is unchanged. Only the EXPLICIT File ▸ New action lands in Drafts —
/// automatic untitled windows (launch, Dock reopen) stay scratch buffers, so a
/// configured folder doesn't accumulate one empty file per launch (a MarkMac
/// lesson).
final class MoltenDocumentController: NSDocumentController {
    let draftsStore = MoltenDraftsStore()

    override func newDocument(_ sender: Any?) {
        guard let draftsURL = draftsStore.resolveFolderURL(),
              MoltenFolderAccess.shared.ensureAccess(to: draftsURL, interactive: false) else {
            super.newDocument(sender)
            return
        }
        let fileURL = MoltenProjectStore.uniqueMarkdownFileURL(
            in: draftsURL,
            baseName: L10n.string("projects.newNote.baseName")
        )
        do {
            try Data().write(to: fileURL, options: .withoutOverwriting)
        } catch {
            // Drafts folder unwritable (moved, permissions): plain untitled.
            super.newDocument(sender)
            return
        }
        openDocument(withContentsOf: fileURL, display: true) { document, _, error in
            if let error {
                MoltenLog.document.error("New draft open failed: \(error.localizedDescription, privacy: .public)")
                NSApp.presentError(error)
                if document == nil, let data = try? Data(contentsOf: fileURL), data.isEmpty {
                    try? FileManager.default.removeItem(at: fileURL)
                }
            }
        }
    }

    /// File ▸ Drafts Folder… — choose, or turn off, the opt-in Drafts folder.
    @objc func configureDraftsFolder(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = L10n.string("drafts.config.title")
        alert.informativeText = draftsStore.isConfigured
            ? L10n.string("drafts.config.messageSet")
            : L10n.string("drafts.config.messageUnset")
        alert.addButton(withTitle: L10n.string("drafts.config.choose"))
        if draftsStore.isConfigured {
            alert.addButton(withTitle: L10n.string("drafts.config.disable"))
        }
        alert.addButton(withTitle: L10n.string("common.cancel"))

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.allowsMultipleSelection = false
            panel.prompt = L10n.string("drafts.config.choosePrompt")
            guard panel.runModal() == .OK, let url = panel.url else { return }
            do {
                try draftsStore.setFolder(url)
            } catch {
                NSApp.presentError(error)
            }
        } else if response == .alertSecondButtonReturn, draftsStore.isConfigured {
            draftsStore.clear()
        }
    }
}
