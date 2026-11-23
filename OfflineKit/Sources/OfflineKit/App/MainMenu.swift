import AppKit
import OfflineCore

/// Builds the menu bar by hand, so it holds only what Offline puts there.
///
/// AppKit likes to add its own items to a menu called "Edit" (Writing Tools,
/// AutoFill, dictation, the emoji picker). `EditMenuGuard` removes anything
/// this file did not create every time the menu is about to open.
enum MainMenu {
    static func build(target: OfflineAppDelegate, editGuard: EditMenuGuard) -> NSMenu {
        let main = NSMenu()

        // Application menu
        let app = NSMenu()
        app.addItem(item("About Offline", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), target: NSApp))
        app.addItem(.separator())
        app.addItem(item("Settings…", #selector(OfflineAppDelegate.showSettings(_:)), ",", target: target))
        app.addItem(.separator())
        app.addItem(item("Lock Offline", #selector(OfflineAppDelegate.lockNow(_:)), "l", target: target))
        app.addItem(.separator())
        app.addItem(item("Hide Offline", #selector(NSApplication.hide(_:)), "h", target: NSApp))
        app.addItem(item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option], target: NSApp))
        app.addItem(item("Show All", #selector(NSApplication.unhideAllApplications(_:)), target: NSApp))
        app.addItem(.separator())
        app.addItem(item("Quit Offline", #selector(NSApplication.terminate(_:)), "q", target: NSApp))
        add(app, titled: "Offline", to: main)

        // File
        let file = NSMenu(title: "File")
        file.addItem(item("New Note", #selector(OfflineAppDelegate.newNote(_:)), "n", target: target))
        file.addItem(item("New Folder", #selector(OfflineAppDelegate.newFolder(_:)), "n", [.command, .shift], target: target))
        file.addItem(.separator())
        file.addItem(item("Rename Note", #selector(OfflineAppDelegate.renameNote(_:)), target: target))
        file.addItem(item("Duplicate Note", #selector(OfflineAppDelegate.duplicateNote(_:)), "d", target: target))
        file.addItem(item("Pin or Unpin Note", #selector(OfflineAppDelegate.togglePin(_:)), target: target))
        file.addItem(item("Delete Note", #selector(OfflineAppDelegate.deleteNote(_:)), "\u{8}", target: target))
        file.addItem(item("Empty Trash…", #selector(OfflineAppDelegate.emptyTrash(_:)), target: target))
        file.addItem(.separator())
        file.addItem(item("Import…", #selector(OfflineAppDelegate.importFiles(_:)), "i", [.command, .shift], target: target))
        file.addItem(item("Export Note…", #selector(OfflineAppDelegate.exportNote(_:)), "e", [.command, .shift], target: target))
        file.addItem(item("Export All Notes…", #selector(OfflineAppDelegate.exportAll(_:)), "e", [.command, .shift, .option], target: target))
        file.addItem(.separator())
        file.addItem(item("Create Encrypted Backup…", #selector(OfflineAppDelegate.createBackup(_:)), target: target))
        file.addItem(item("Restore from Encrypted Backup…", #selector(OfflineAppDelegate.restoreBackup(_:)), target: target))
        file.addItem(.separator())
        file.addItem(item("Close Window", #selector(NSWindow.performClose(_:)), "w"))
        add(file, titled: "File", to: main)

        // Edit
        let edit = NSMenu(title: "Edit")
        edit.addItem(item("Undo", Selector(("undo:")), "z"))
        edit.addItem(item("Redo", Selector(("redo:")), "z", [.command, .shift]))
        edit.addItem(.separator())
        edit.addItem(item("Cut", #selector(NSText.cut(_:)), "x"))
        edit.addItem(item("Copy", #selector(NSText.copy(_:)), "c"))
        edit.addItem(item("Paste", #selector(NSText.paste(_:)), "v"))
        edit.addItem(item("Select All", #selector(NSText.selectAll(_:)), "a"))
        edit.addItem(.separator())
        edit.addItem(item("Search", #selector(OfflineAppDelegate.find(_:)), "f", target: target))
        editGuard.adopt(edit)
        add(edit, titled: "Edit", to: main)

        // View
        let view = NSMenu(title: "View")
        let sort = NSMenu(title: "Sort Notes By")
        for (title, value) in [("Date Edited", NoteSort.modified), ("Date Created", .created), ("Title", .title)] {
            let sortItem = item(title, #selector(OfflineAppDelegate.sortNotes(_:)), target: target)
            sortItem.representedObject = value.rawValue
            sort.addItem(sortItem)
        }
        let sortParent = NSMenuItem(title: "Sort Notes By", action: nil, keyEquivalent: "")
        sortParent.submenu = sort
        view.addItem(sortParent)
        view.addItem(.separator())
        view.addItem(item("Bigger Text", #selector(OfflineAppDelegate.biggerText(_:)), "+", target: target))
        view.addItem(item("Smaller Text", #selector(OfflineAppDelegate.smallerText(_:)), "-", target: target))
        view.addItem(item("Default Text Size", #selector(OfflineAppDelegate.defaultTextSize(_:)), "0", target: target))
        add(view, titled: "View", to: main)

        // Window
        let window = NSMenu(title: "Window")
        window.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"))
        window.addItem(item("Zoom", #selector(NSWindow.performZoom(_:))))
        window.addItem(.separator())
        window.addItem(item("Offline", #selector(OfflineAppDelegate.showMainWindow(_:)), "1", target: target))
        add(window, titled: "Window", to: main)

        return main
    }

    private static func add(_ menu: NSMenu, titled title: String, to main: NSMenu) {
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        parent.submenu = menu
        main.addItem(parent)
    }

    static func item(
        _ title: String,
        _ action: Selector,
        _ key: String = "",
        _ modifiers: NSEvent.ModifierFlags = [.command],
        target: AnyObject? = nil
    ) -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: key)
        menuItem.keyEquivalentModifierMask = modifiers
        menuItem.target = target
        return menuItem
    }
}

/// Keeps the Edit menu to exactly the items Offline created.
final class EditMenuGuard: NSObject, NSMenuDelegate {
    private var allowed: [NSMenuItem] = []

    func adopt(_ menu: NSMenu) {
        allowed = menu.items
        menu.delegate = self
    }

    private func prune(_ menu: NSMenu) {
        for menuItem in menu.items where !allowed.contains(where: { $0 === menuItem }) {
            menu.removeItem(menuItem)
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        prune(menu)
    }

    func menuWillOpen(_ menu: NSMenu) {
        prune(menu)
    }
}
