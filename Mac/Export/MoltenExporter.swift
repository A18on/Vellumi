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
                let page = selfContainedHTML(bodyHTML: expandTOC(in: bodyHTML), title: document.exportBaseName)
                do {
                    try Data(page.utf8).write(to: url)
                } catch {
                    NSApp.presentError(error)
                }
            }
        }
    }

    /// Typora-compatible `[toc]` support at export time: heading tags get
    /// slug ids and any paragraph whose entire text is "[toc]" becomes a
    /// nested nav list. In the editor the marker stays plain text by design.
    static func expandTOC(in bodyHTML: String) -> String {
        var html = bodyHTML
        var headings: [(level: Int, text: String, slug: String)] = []
        var usedSlugs = Set<String>()

        // Give every h1–h6 an id (idempotent slugs, de-duplicated).
        let headingPattern = try! NSRegularExpression(
            pattern: "<h([1-6])([^>]*)>(.*?)</h\\1>",
            options: [.dotMatchesLineSeparators]
        )
        let source = html as NSString
        var rebuilt = ""
        var cursor = 0
        for match in headingPattern.matches(in: html, range: NSRange(location: 0, length: source.length)) {
            let level = Int(source.substring(with: match.range(at: 1))) ?? 1
            let attrs = source.substring(with: match.range(at: 2))
            let inner = source.substring(with: match.range(at: 3))
            let text = inner.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            var slug = text
                .lowercased()
                .replacingOccurrences(of: "[^\\p{L}\\p{N}]+", with: "-", options: .regularExpression)
                .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            if slug.isEmpty { slug = "heading" }
            var unique = slug
            var counter = 2
            while !usedSlugs.insert(unique).inserted {
                unique = "\(slug)-\(counter)"
                counter += 1
            }
            headings.append((level, text, unique))
            rebuilt += source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            rebuilt += "<h\(level) id=\"\(unique)\"\(attrs)>\(inner)</h\(level)>"
            cursor = match.range.location + match.range.length
        }
        rebuilt += source.substring(from: cursor)
        html = rebuilt

        guard !headings.isEmpty else { return html }
        let minLevel = headings.map(\.level).min() ?? 1
        let items = headings.map { heading in
            let indent = heading.level - minLevel
            // heading.text came from stripping tags out of already-valid HTML,
            // so its entities are intact ("Q&amp;A"); escaping again rendered
            // the literal "&amp;amp;" in the TOC. Only "<" could have been
            // reintroduced by tag-stripping edge cases — guard just that.
            let linkText = heading.text.replacingOccurrences(of: "<", with: "&lt;")
            return "<li style=\"margin-left: \(indent)em\"><a href=\"#\(heading.slug)\">\(linkText)</a></li>"
        }.joined()
        let nav = "<nav class=\"vellumi-toc\"><ul style=\"list-style: none; padding-left: 0\">\(items)</ul></nav>"

        // Replace paragraphs whose entire visible text is "[toc]". The nav is
        // used as a REGEX TEMPLATE here, so "$" and "\\" inside heading text
        // would be interpreted — escape it.
        return html.replacingOccurrences(
            of: "<p[^>]*>\\s*\\[toc\\]\\s*</p>",
            with: NSRegularExpression.escapedTemplate(for: nav),
            options: [.regularExpression, .caseInsensitive]
        )
    }

    /// Wraps body HTML with the bundled editor/theme stylesheets inlined, so
    /// the exported file renders standalone (images stay document-relative —
    /// export next to the .md and assets/ keeps working).
    static func selfContainedHTML(bodyHTML: String, title: String) -> String {
        let css = [("editor", "dist"), (UserDefaults.standard.string(forKey: "Vellumi.editorTheme").map { "\($0)-light" } ?? "frame-light", "dist/themes")]
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
