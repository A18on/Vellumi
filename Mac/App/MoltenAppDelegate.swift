import AppKit

final class MoltenAppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MoltenMainMenuBuilder.build()
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

    private static func viewMenu() -> NSMenu {
        let menu = NSMenu(title: L10n.string("menu.view"))
        let outline = menu.addItem(
            withTitle: L10n.string("menu.toggleOutline"),
            action: #selector(MoltenWorkspaceViewController.toggleOutline(_:)),
            keyEquivalent: "1"
        )
        outline.keyEquivalentModifierMask = [.command, .option]
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
