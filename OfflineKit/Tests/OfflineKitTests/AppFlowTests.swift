import AppKit
import OfflineCore
import SwiftUI
import XCTest
@testable import OfflineKit

/// Stands in for the Keychain so the whole app flow can run in a test.
final class MemoryKeyStore: KeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [UInt8]?

    func keyExists() throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        return stored != nil
    }

    func confirmUserPresence(reason: String) throws {}

    func storeKey(_ key: SecureBytes) throws {
        lock.lock(); defer { lock.unlock() }
        guard stored == nil else { throw VaultError.keyAlreadyExists }
        stored = try key.withBytes { Array($0) }
    }

    func loadKey(reason: String) throws -> SecureBytes {
        lock.lock(); defer { lock.unlock() }
        guard let stored else { throw VaultError.keyNotFound }
        return stored.withUnsafeBytes { SecureBytes(copying: $0) }
    }

    func deleteKey() throws {
        lock.lock(); defer { lock.unlock() }
        stored = nil
    }
}

@MainActor
final class AppFlowTests: XCTestCase {
    private var directory: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("offline-ui-tests-\(UUID().uuidString)", isDirectory: true)
        suiteName = "offline-ui-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func makeModel() -> AppModel {
        AppModel(
            vault: Vault(directory: directory.appendingPathComponent("Data.noindex"), keyStore: MemoryKeyStore()),
            settings: SettingsStore(defaults: defaults)
        )
    }

    private func wait(
        _ what: String,
        timeout: TimeInterval = 10,
        until condition: () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                XCTFail("timed out waiting for \(what)")
                throw CancellationError()
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    /// Puts the real root view in a real hardened window and lays it out.
    private func host(_ model: AppModel) -> HardenedWindow {
        let window = HardenedWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 640),
            styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false
        )
        window.contentView = NSHostingView(
            rootView: RootView().environmentObject(model).environmentObject(model.settings)
        )
        window.layoutIfNeeded()
        return window
    }

    func testFirstLaunchEditSearchLockAndUnlock() async throws {
        let model = makeModel()
        model.start()
        XCTAssertEqual(model.phase, .onboarding)
        let window = host(model)

        model.createVault()
        try await wait("the vault to be created") { model.phase == .unlocked }
        window.layoutIfNeeded()
        try await wait("the editor to attach") { model.editor.textView != nil }

        // Write a note.
        model.newNote()
        let noteID = try XCTUnwrap(model.selectedNoteID)
        model.titleDraft = "Shopping"
        let textView = try XCTUnwrap(model.editor.textView)
        textView.insertText("- [ ] zucchini and **bread**", replacementRange: NSRange(location: 0, length: 0))
        XCTAssertEqual(model.wordCount, 3)

        // Autosave fires by itself, well inside a second of the last change.
        try await wait("autosave", timeout: 3) {
            (try? model.store?.note(id: noteID))??.body == "- [ ] zucchini and **bread**"
        }
        XCTAssertEqual(try model.store?.note(id: noteID)?.title, "Shopping")
        XCTAssertEqual(model.rows.map(\.title), ["Shopping"])

        // Tags and folders.
        model.tagsDraft = "food, #errands"
        model.commitTags()
        XCTAssertEqual(model.tags.map(\.tag.name), ["errands", "food"])
        let folder = try XCTUnwrap(try model.store?.createFolder(name: "Home"))
        model.moveNote(id: noteID, toFolder: folder.id)
        XCTAssertEqual(model.folderCounts[folder.id], 1)

        // Search finds it and a miss empties the list.
        model.newNote()
        model.titleDraft = "Other"
        model.saveNow()
        model.setSearchText("zucch")
        XCTAssertEqual(model.rows.map(\.id), [noteID])
        XCTAssertEqual(model.selectedNoteID, noteID)
        model.setSearchText("nothingmatchesthis")
        XCTAssertTrue(model.rows.isEmpty)
        model.setSearchText("")
        window.layoutIfNeeded()

        // Lock: nothing from any note may remain in the model or the editor.
        model.select(noteID: noteID)
        model.lock()
        XCTAssertEqual(model.phase, .locked)
        XCTAssertFalse(model.vault.isUnlocked)
        XCTAssertNil(model.store)
        XCTAssertNil(model.currentNote)
        XCTAssertTrue(model.rows.isEmpty)
        XCTAssertTrue(model.folders.isEmpty)
        XCTAssertTrue(model.tags.isEmpty)
        XCTAssertEqual(model.titleDraft, "")
        XCTAssertEqual(model.tagsDraft, "")
        XCTAssertEqual(model.searchText, "")
        XCTAssertEqual(textView.string, "")
        XCTAssertFalse(textView.undoManager?.canUndo ?? false)
        window.layoutIfNeeded()

        // Unlock brings everything back from the encrypted file.
        model.unlock()
        try await wait("unlock") { model.phase == .unlocked }
        XCTAssertEqual(Set(model.rows.map(\.title)), ["Shopping", "Other"])
        model.select(noteID: noteID)
        XCTAssertEqual(model.editor.markdown, "- [ ] zucchini and **bread**")
        window.layoutIfNeeded()
        model.lock()
        window.close()
    }

    func testTrashRestoreAndImagesThroughTheModel() async throws {
        let model = makeModel()
        model.start()
        let window = host(model)
        model.createVault()
        try await wait("the vault to be created") { model.phase == .unlocked }
        window.layoutIfNeeded()
        try await wait("the editor to attach") { model.editor.textView != nil }

        model.newNote()
        let noteID = try XCTUnwrap(model.selectedNoteID)
        model.titleDraft = "With image"
        let imageID = try XCTUnwrap(model.editor.storeImage?(makePNG(), "image/png"))
        model.editor.load(markdown: "see \(AttachmentReference.token(id: imageID))", editable: true)
        XCTAssertTrue(model.editor.visibleText.contains("\u{FFFC}"))
        model.saveNow()
        XCTAssertEqual(
            try model.store?.note(id: noteID)?.body,
            "see \(AttachmentReference.token(id: imageID))"
        )

        model.deleteNote(id: noteID)
        XCTAssertEqual(model.trashCount, 1)
        XCTAssertTrue(model.rows.isEmpty)
        model.setScope(.trash)
        XCTAssertEqual(model.rows.map(\.id), [noteID])
        XCTAssertTrue(model.rows[0].isTrashed)
        window.layoutIfNeeded()

        model.restoreNote(id: noteID)
        model.setScope(.all)
        XCTAssertEqual(model.rows.map(\.id), [noteID])
        XCTAssertEqual(model.trashCount, 0)
        model.lock()
        window.close()
    }

    func testAutoLockSettingIsClampedAndReachesTheLockController() {
        let model = makeModel()
        model.settings.autoLockMinutes = 0
        XCTAssertEqual(model.settings.autoLockMinutes, 1)
        model.settings.autoLockMinutes = 600
        XCTAssertEqual(model.settings.autoLockMinutes, 60)
        XCTAssertEqual(model.lockController.policy.timeoutMinutes, 60)
        XCTAssertEqual(SettingsStore(defaults: defaults).autoLockMinutes, 60)
    }
}
