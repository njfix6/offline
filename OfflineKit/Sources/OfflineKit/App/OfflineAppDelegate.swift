import AppKit
import Combine
import OfflineCore
import SwiftUI

/// Starts the app. The app target's `main.swift` calls `OfflineApplication.run()`.
public enum OfflineApplication {
    @MainActor private static var delegate: OfflineAppDelegate?

    @MainActor
    public static func run() {
        // Set before AppKit builds anything: no window state restoration, and
        // none of the menu items AppKit adds to an Edit menu by itself.
        UserDefaults.standard.register(defaults: [
            "NSQuitAlwaysKeepsWindows": false,
            "ApplePersistenceIgnoreState": true,
            "NSDisabledDictationMenuItem": true,
            "NSDisabledCharacterPaletteMenuItem": true,
        ])

        let application = NSApplication.shared
        let delegate = OfflineAppDelegate()
        Self.delegate = delegate
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        application.run()
    }
}

@MainActor
public final class OfflineAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuItemValidation {
    private var model: AppModel!
    private var settings: SettingsStore!
    private var window: HardenedWindow!
    private var settingsWindow: HardenedWindow?
    private var statusItem: NSStatusItem?
    private let editMenuGuard = EditMenuGuard()
    private var cancellables: Set<AnyCancellable> = []

    // MARK: Lifecycle

    public func applicationDidFinishLaunching(_ notification: Notification) {
        let settings = SettingsStore()
        self.settings = settings
        NSApp.appearance = settings.theme.appearance

        let directory: URL
        do {
            directory = try Vault.defaultDirectory()
        } catch {
            let alert = NSAlert()
            alert.messageText = "Offline cannot find its data folder"
            alert.informativeText = AppModel.message(for: error)
            alert.runHardened()
            NSApp.terminate(nil)
            return
        }

        model = AppModel(vault: Vault(directory: directory, keyStore: KeychainKeyStore()), settings: settings)
        NSApp.mainMenu = MainMenu.build(target: self, editGuard: editMenuGuard)
        // No Services menu is installed, and nothing is registered as a
        // services provider.
        NSApp.servicesMenu = nil

        makeWindow()
        makeStatusItem()
        model.$phase
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateStatusItem() }
            .store(in: &cancellables)

        NSApp.activate(ignoringOtherApps: true)
        model.start()
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow(nil)
        return true
    }

    public func applicationWillTerminate(_ notification: Notification) {
        model?.lock()
    }

    public func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    // MARK: Windows

    private func makeWindow() {
        let window = HardenedWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 860, height: 520)
        window.delegate = self
        window.contentView = NSHostingView(
            rootView: RootView()
                .environmentObject(model)
                .environmentObject(settings)
        )
        window.center()
        window.setFrameAutosaveName("OfflineMainWindow")
        window.makeKeyAndOrderFront(nil)
        self.window = window
    }

    /// Closing the window locks: with nothing on screen there is no reason to
    /// keep the notes open in memory.
    public func windowWillClose(_ notification: Notification) {
        if (notification.object as? NSWindow) === window {
            model.lock()
        }
    }

    // MARK: Menu bar status item

    private func makeStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.addItem(MainMenu.item("Show Offline", #selector(showMainWindow(_:)), target: self))
        menu.addItem(MainMenu.item("Lock Now", #selector(lockNow(_:)), target: self))
        menu.addItem(.separator())
        menu.addItem(MainMenu.item("Quit Offline", #selector(NSApplication.terminate(_:)), target: NSApp))
        item.menu = menu
        statusItem = item
        updateStatusItem()
    }

    private func updateStatusItem() {
        let unlocked = model.isUnlocked
        let image = NSImage(
            systemSymbolName: unlocked ? "lock.open.fill" : "lock.fill",
            accessibilityDescription: unlocked ? "Offline is unlocked" : "Offline is locked"
        )
        image?.isTemplate = true
        statusItem?.button?.image = image
        statusItem?.button?.toolTip = unlocked ? "Offline is unlocked" : "Offline is locked"
    }

    // MARK: Actions

    @objc func showMainWindow(_ sender: Any?) {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        if model.phase == .locked {
            model.unlock()
        }
    }

    @objc func lockNow(_ sender: Any?) { model.lock() }
    @objc func newNote(_ sender: Any?) { model.newNote() }
    @objc func newFolder(_ sender: Any?) { model.newFolder() }
    @objc func renameNote(_ sender: Any?) { model.renameCurrentNote() }
    @objc func deleteNote(_ sender: Any?) { model.deleteNote(id: model.selectedNoteID) }
    @objc func emptyTrash(_ sender: Any?) { model.emptyTrash() }
    @objc func importFiles(_ sender: Any?) { model.importFiles() }
    @objc func exportNote(_ sender: Any?) { model.exportCurrentNote() }
    @objc func exportAll(_ sender: Any?) { model.exportAllNotes() }
    @objc func createBackup(_ sender: Any?) { model.createBackup() }
    @objc func restoreBackup(_ sender: Any?) { model.restoreBackup() }
    @objc func find(_ sender: Any?) { model.focusSearch() }

    @objc func duplicateNote(_ sender: Any?) {
        if let id = model.selectedNoteID { model.duplicateNote(id: id) }
    }

    @objc func togglePin(_ sender: Any?) {
        if let id = model.selectedNoteID { model.togglePin(id: id) }
    }

    @objc func sortNotes(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let sort = NoteSort(rawValue: raw) {
            settings.sort = sort
        }
    }

    @objc func biggerText(_ sender: Any?) { settings.typography.size += 1 }
    @objc func smallerText(_ sender: Any?) { settings.typography.size -= 1 }
    @objc func defaultTextSize(_ sender: Any?) { settings.typography.size = EditorTypography.defaultSize }

    @objc func showSettings(_ sender: Any?) {
        if settingsWindow == nil {
            let window = HardenedWindow(
                contentRect: NSRect(x: 0, y: 0, width: 460, height: 420),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = "Offline Settings"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SettingsView().environmentObject(settings))
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    public func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let action = menuItem.action else { return true }
        let ready = model.isUnlocked && model.prompt == nil && model.busyMessage == nil
        let note = model.currentNote
        let editable = ready && note != nil && note?.deletedAt == nil

        switch action {
        case #selector(showMainWindow(_:)), #selector(showSettings(_:)):
            return true
        case #selector(biggerText(_:)):
            return settings.typography.size < EditorTypography.maximumSize
        case #selector(smallerText(_:)):
            return settings.typography.size > EditorTypography.minimumSize
        case #selector(defaultTextSize(_:)):
            return true
        case #selector(lockNow(_:)):
            return model.isUnlocked
        case #selector(sortNotes(_:)):
            menuItem.state = (menuItem.representedObject as? String) == settings.sort.rawValue ? .on : .off
            return ready
        case #selector(renameNote(_:)), #selector(duplicateNote(_:)), #selector(togglePin(_:)):
            return editable
        case #selector(deleteNote(_:)):
            return ready && note != nil
        case #selector(emptyTrash(_:)):
            return ready && model.trashCount > 0
        case #selector(exportNote(_:)):
            return editable
        default:
            return ready
        }
    }
}
