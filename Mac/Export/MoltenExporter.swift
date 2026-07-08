import AppKit
import WebKit

/// File ▸ Export/Print. HTML export wraps the editor's cleaned rendered DOM in
/// a self-contained page (theme CSS inlined); PDF/print run against the live
/// editing web view so what you see is what you export.
@MainActor
enum MoltenExporter {
    // MARK: - HTML

    static func exportHTML(from workspace: MoltenWorkspaceViewController, document: MoltenDocument) {
        workspace.editorViewController.fetchContentHTML { bodyHTML in
            guard let bodyHTML else {
                NSSound.beep()
                return
            }
            presentSavePanel(
                suggestedName: document.exportBaseName + ".html",
                fileType: "html",
                for: document
            ) { url in
                let page = selfContainedHTML(bodyHTML: bodyHTML, title: document.exportBaseName)
                do {
                    try Data(page.utf8).write(to: url)
                } catch {
                    NSApp.presentError(error)
                }
            }
        }
    }

    /// Wraps body HTML with the bundled editor/theme stylesheets inlined, so
    /// the exported file renders standalone (images stay document-relative —
    /// export next to the .md and assets/ keeps working).
    static func selfContainedHTML(bodyHTML: String, title: String) -> String {
        let css = [("editor", "dist"), ("light", "dist/themes")]
            .compactMap { name, subdirectory -> String? in
                guard let url = Bundle.main.url(forResource: name, withExtension: "css", subdirectory: subdirectory),
                      let contents = try? String(contentsOf: url, encoding: .utf8) else {
                    MoltenLog.document.error("Export stylesheet missing: \(subdirectory)/\(name).css")
                    return nil
                }
                return contents
            }
            .joined(separator: "\n")

        let escapedTitle = title
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")

        return """
        <!doctype html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(escapedTitle)</title>
        <style>
        \(css)
        body { margin: 0 auto; max-width: 760px; padding: 48px 32px; }
        </style>
        </head>
        <body class="milkdown">
        <div class="ProseMirror editor">\(bodyHTML)</div>
        </body>
        </html>
        """
    }

    // MARK: - PDF

    static func exportPDF(from workspace: MoltenWorkspaceViewController, document: MoltenDocument) {
        presentSavePanel(
            suggestedName: document.exportBaseName + ".pdf",
            fileType: "pdf",
            for: document
        ) { url in
            let configuration = WKPDFConfiguration()
            workspace.editorViewController.webViewForExport.createPDF(configuration: configuration) { result in
                switch result {
                case .success(let data):
                    do {
                        try data.write(to: url)
                    } catch {
                        NSApp.presentError(error)
                    }
                case .failure(let error):
                    NSApp.presentError(error)
                }
            }
        }
    }

    // MARK: - Print

    static func print(from workspace: MoltenWorkspaceViewController) {
        let info = NSPrintInfo.shared
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        let operation = workspace.editorViewController.webViewForExport.printOperation(with: info)
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        if let window = workspace.view.window {
            operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
        } else {
            operation.run()
        }
    }

    // MARK: - Shared

    private static func presentSavePanel(
        suggestedName: String,
        fileType: String,
        for document: MoltenDocument,
        completion: @escaping (URL) -> Void
    ) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.allowedContentTypes = fileType == "pdf" ? [.pdf] : [.html]
        if let folder = document.fileURL?.deletingLastPathComponent() {
            panel.directoryURL = folder
        }
        let handler: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            completion(url)
        }
        if let window = document.windowControllers.first?.window {
            panel.beginSheetModal(for: window, completionHandler: handler)
        } else {
            handler(panel.runModal())
        }
    }
}

extension MoltenDocument {
    var exportBaseName: String {
        let name = fileURL?.deletingPathExtension().lastPathComponent ?? displayName ?? "Untitled"
        return name.isEmpty ? "Untitled" : name
    }
}
