import AppKit

@MainActor
final class MoltenAppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MoltenMainMenuBuilder.build()
    }

    @objc func showProjects(_ sender: Any?) {
        MoltenProjectsWindowController.shared.show()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        MoltenAppearance.applyStored()
    }

    @objc func setAppearanceMode(_ sender: NSMenuItem) {
        MoltenAppearance.apply(mode: MoltenAppearance.Mode(rawValue: sender.tag) ?? .system)
    }
}

/// App-wide light/dark override. The editor's theme stylesheets key off
/// prefers-color-scheme, which WKWebView derives from the effective
/// appearance — so flipping NSApp.appearance restyles everything at once.
@MainActor
enum MoltenAppearance {
    enum Mode: Int { case system = 0, light = 1, dark = 2 }
    private static let key = "Molten.appearanceMode"

    static func applyStored() {
        apply(mode: Mode(rawValue: UserDefaults.standard.integer(forKey: key)) ?? .system)
    }

    static func apply(mode: Mode) {
        UserDefaults.standard.set(mode.rawValue, forKey: key)
        switch mode {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    static var current: Mode {
        Mode(rawValue: UserDefaults.standard.integer(forKey: key)) ?? .system
    }
}

/// Programmatic main menu — no storyboard/nib. Standard selectors route
/// through the responder chain, so undo/cut/copy/paste reach the WKWebView
/// editing surface and the document commands reach NSDocumentController.
enum MoltenMainMenuBuilder {
    static func build() -> NSMenu {
        let mainMenu = NSMenu()

        mainMenu.addItem(submenu: appMenu(), title: "Molten")
        mainMenu.addItem(submenu: fileMenu(), title: L10n.string("menu.file"))
        mainMenu.addItem(submenu: editMenu(), title: L10n.string("menu.edit"))
        mainMenu.addItem(submenu: formatMenu(), title: L10n.string("menu.format"))
        mainMenu.addItem(submenu: viewMenu(), title: L10n.string("menu.view"))
        mainMenu.addItem(submenu: windowMenu(), title: L10n.string("menu.window"))

        return mainMenu
    }

    private static func appMenu() -> NSMenu {
        let menu = NSMenu(title: "Molten")
        menu.addItem(withTitle: L10n.string("menu.about"), action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: L10n.string("menu.hide"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = menu.addItem(withTitle: L10n.string("menu.hideOthers"), action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(withTitle: L10n.string("menu.showAll"), action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: L10n.string("menu.quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        return menu
    }

    private static func fileMenu() -> NSMenu {
        let menu = NSMenu(title: L10n.string("menu.file"))
        menu.addItem(withTitle: L10n.string("menu.new"), action: #selector(NSDocumentController.newDocument(_:)), keyEquivalent: "n")
        menu.addItem(withTitle: L10n.string("menu.open"), action: #selector(NSDocumentController.openDocument(_:)), keyEquivalent: "o")
        menu.addItem(.separator())
        menu.addItem(withTitle: L10n.string("menu.close"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        menu.addItem(withTitle: L10n.string("menu.save"), action: #selector(NSDocument.save(_:)), keyEquivalent: "s")
        let saveAs = menu.addItem(withTitle: L10n.string("menu.saveAs"), action: #selector(NSDocument.saveAs(_:)), keyEquivalent: "s")
        saveAs.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(withTitle: L10n.string("menu.revert"), action: #selector(NSDocument.revertToSaved(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        let exportHTML = menu.addItem(
            withTitle: L10n.string("menu.exportHTML"),
            action: #selector(MoltenWorkspaceViewController.exportHTML(_:)),
            keyEquivalent: "e"
        )
        exportHTML.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(
            withTitle: L10n.string("menu.exportPDF"),
            action: #selector(MoltenWorkspaceViewController.exportPDF(_:)),
            keyEquivalent: ""
        )
        menu.addItem(
            withTitle: L10n.string("menu.exportImageCards"),
            action: #selector(MoltenWorkspaceViewController.exportImageCards(_:)),
            keyEquivalent: ""
        )
        menu.addItem(.separator())
        menu.addItem(
            withTitle: L10n.string("menu.print"),
            action: #selector(MoltenWorkspaceViewController.printDocument(_:)),
            keyEquivalent: "p"
        )
        return menu
    }

    private static func editMenu() -> NSMenu {
        let menu = NSMenu(title: L10n.string("menu.edit"))
        // Compile-checked selectors targeting MoltenEditorViewController via
        // the responder chain (WKWebView itself does not respond to undo:).
        menu.addItem(withTitle: L10n.string("menu.undo"), action: #selector(MoltenEditorViewController.undo(_:)), keyEquivalent: "z")
        let redo = menu.addItem(withTitle: L10n.string("menu.redo"), action: #selector(MoltenEditorViewController.redo(_:)), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(.separator())
        menu.addItem(withTitle: L10n.string("menu.cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        menu.addItem(withTitle: L10n.string("menu.copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        menu.addItem(withTitle: L10n.string("menu.paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        menu.addItem(withTitle: L10n.string("menu.selectAll"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        menu.addItem(.separator())
        menu.addItem(
            withTitle: L10n.string("menu.find"),
            action: #selector(MoltenWorkspaceViewController.showFind(_:)),
            keyEquivalent: "f"
        )
        return menu
    }

    private static func formatMenu() -> NSMenu {
        let menu = NSMenu(title: L10n.string("menu.format"))

        // ⌘0 body text, ⌘1–⌘6 headings — the item tag carries the level.
        let body = menu.addItem(
            withTitle: L10n.string("format.bodyText"),
            action: #selector(MoltenEditorViewController.applyHeading(_:)),
            keyEquivalent: "0"
        )
        body.tag = 0
        for level in 1...6 {
            let item = menu.addItem(
                withTitle: String(format: L10n.string("format.heading"), level),
                action: #selector(MoltenEditorViewController.applyHeading(_:)),
                keyEquivalent: "\(level)"
            )
            item.tag = level
        }

        menu.addItem(.separator())
        menu.addItem(withTitle: L10n.string("format.bold"), action: #selector(MoltenEditorViewController.toggleBold(_:)), keyEquivalent: "b")
        menu.addItem(withTitle: L10n.string("format.italic"), action: #selector(MoltenEditorViewController.toggleItalic(_:)), keyEquivalent: "i")
        menu.addItem(withTitle: L10n.string("format.inlineCode"), action: #selector(MoltenEditorViewController.toggleInlineCode(_:)), keyEquivalent: "e")
        let strike = menu.addItem(withTitle: L10n.string("format.strikethrough"), action: #selector(MoltenEditorViewController.toggleStrikethrough(_:)), keyEquivalent: "x")
        strike.keyEquivalentModifierMask = [.command, .shift]

        menu.addItem(.separator())
        let bullet = menu.addItem(withTitle: L10n.string("format.bulletList"), action: #selector(MoltenEditorViewController.toggleBulletList(_:)), keyEquivalent: "u")
        bullet.keyEquivalentModifierMask = [.command, .shift]
        let ordered = menu.addItem(withTitle: L10n.string("format.orderedList"), action: #selector(MoltenEditorViewController.toggleOrderedList(_:)), keyEquivalent: "o")
        ordered.keyEquivalentModifierMask = [.command, .shift]
        let quote = menu.addItem(withTitle: L10n.string("format.blockquote"), action: #selector(MoltenEditorViewController.toggleBlockquote(_:)), keyEquivalent: "q")
        quote.keyEquivalentModifierMask = [.command, .shift]
        let rule = menu.addItem(withTitle: L10n.string("format.horizontalRule"), action: #selector(MoltenEditorViewController.insertHorizontalRule(_:)), keyEquivalent: "-")
        rule.keyEquivalentModifierMask = [.command, .option]

        return menu
    }

    private static func viewMenu() -> NSMenu {
        let menu = NSMenu(title: L10n.string("menu.view"))
        let projects = menu.addItem(
            withTitle: L10n.string("menu.projects"),
            action: #selector(MoltenAppDelegate.showProjects(_:)),
            keyEquivalent: "0"
        )
        projects.keyEquivalentModifierMask = [.command, .shift]
        let outline = menu.addItem(
            withTitle: L10n.string("menu.toggleOutline"),
            action: #selector(MoltenWorkspaceViewController.toggleOutline(_:)),
            keyEquivalent: "1"
        )
        outline.keyEquivalentModifierMask = [.command, .option]
        let fileTree = menu.addItem(
            withTitle: L10n.string("menu.toggleFileTree"),
            action: #selector(MoltenWorkspaceViewController.toggleFileTree(_:)),
            keyEquivalent: "2"
        )
        fileTree.keyEquivalentModifierMask = [.command, .option]

        menu.addItem(.separator())
        let appearance = NSMenu(title: L10n.string("menu.appearance"))
        for (title, mode) in [("appearance.system", 0), ("appearance.light", 1), ("appearance.dark", 2)] {
            let item = appearance.addItem(
                withTitle: L10n.string(title),
                action: #selector(MoltenAppDelegate.setAppearanceMode(_:)),
                keyEquivalent: ""
            )
            item.tag = mode
        }
        let appearanceItem = NSMenuItem(title: L10n.string("menu.appearance"), action: nil, keyEquivalent: "")
        appearanceItem.submenu = appearance
        menu.addItem(appearanceItem)
        return menu
    }

    private static func windowMenu() -> NSMenu {
        let menu = NSMenu(title: L10n.string("menu.window"))
        menu.addItem(withTitle: L10n.string("menu.minimize"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        menu.addItem(withTitle: L10n.string("menu.zoom"), action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        NSApp.windowsMenu = menu
        return menu
    }
}

private extension NSMenu {
    func addItem(submenu: NSMenu, title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        addItem(item)
    }
}
