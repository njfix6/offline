import XCTest
@testable import OfflineCore

final class SecureBytesTests: XCTestCase {
    func testRandomKeysDiffer() throws {
        let a = try SecureBytes.random(count: 32).withBytes { Array($0) }
        let b = try SecureBytes.random(count: 32).withBytes { Array($0) }
        XCTAssertEqual(a.count, 32)
        XCTAssertNotEqual(a, b)
        XCTAssertNotEqual(a, [UInt8](repeating: 0, count: 32))
    }

    func testWipeMakesBytesUnreadable() throws {
        let bytes = SecureBytes.random(count: 32)
        XCTAssertFalse(bytes.isWiped)
        bytes.wipe()
        XCTAssertTrue(bytes.isWiped)
        XCTAssertThrowsError(try bytes.withBytes { $0.count }) { error in
            XCTAssertEqual(error as? VaultError, .locked)
        }
        bytes.wipe() // harmless twice
    }

    func testArrayWipe() {
        var secret: [UInt8] = [1, 2, 3, 4]
        secret.secureWipe()
        XCTAssertEqual(secret, [0, 0, 0, 0])
    }
}

final class VaultTests: TemporaryDirectoryTestCase {
    func testFirstLaunchCreatesKeyAndDatabase() throws {
        let keys = InMemoryKeyStore()
        let vault = Vault(directory: directory.appendingPathComponent("Data.noindex"), keyStore: keys)
        XCTAssertEqual(try vault.status(), .needsSetup)

        let store = try vault.create(reason: "test")
        XCTAssertEqual(keys.presenceChecks, 1, "creating the key must ask for user presence")
        XCTAssertEqual(keys.rawKey?.count, 32)
        XCTAssertTrue(vault.isUnlocked)
        XCTAssertEqual(try vault.status(), .ready)
        XCTAssertTrue(FileManager.default.fileExists(atPath: vault.databaseURL.path))
        XCTAssertEqual(try store.schemaVersion(), 1)
    }

    func testLockClosesDatabaseAndUnlockReadsItBack() throws {
        let keys = InMemoryKeyStore()
        let vault = Vault(directory: directory, keyStore: keys)
        let store = try vault.create(reason: "test")
        let note = try store.createNote(title: "Hello", body: "World")

        vault.lockNow()
        XCTAssertFalse(vault.isUnlocked)
        XCTAssertNil(vault.store)
        XCTAssertThrowsError(try store.note(id: note.id), "a closed store must not serve data")

        let reopened = try vault.unlock(reason: "test")
        XCTAssertEqual(keys.loads, 1)
        XCTAssertEqual(try reopened.note(id: note.id)?.body, "World")
    }

    func testUnlockFailureLeavesVaultLocked() throws {
        let keys = InMemoryKeyStore()
        let vault = Vault(directory: directory, keyStore: keys)
        try vault.create(reason: "test")
        vault.lockNow()

        keys.failNextLoad = .userCancelled
        XCTAssertThrowsError(try vault.unlock(reason: "test")) { error in
            XCTAssertEqual(error as? VaultError, .userCancelled)
        }
        XCTAssertFalse(vault.isUnlocked)
        XCTAssertNoThrow(try vault.unlock(reason: "test"))
    }

    func testCreateNeverReplacesAnExistingKey() throws {
        let keys = InMemoryKeyStore()
        let vault = Vault(directory: directory, keyStore: keys)
        try vault.create(reason: "test")
        let original = keys.rawKey
        vault.lockNow()

        XCTAssertThrowsError(try vault.create(reason: "test"))
        XCTAssertEqual(keys.rawKey, original)
    }

    func testMissingKeyIsReportedAndDataIsSetAsideNotDeleted() throws {
        let keys = InMemoryKeyStore()
        let vault = Vault(directory: directory, keyStore: keys)
        try vault.create(reason: "test")
        vault.lockNow()
        try keys.deleteKey()

        XCTAssertEqual(try vault.status(), .keyMissing)
        XCTAssertThrowsError(try vault.unlock(reason: "test")) { error in
            XCTAssertEqual(error as? VaultError, .keyMissingForExistingData)
        }
        XCTAssertThrowsError(try vault.create(reason: "test")) { error in
            XCTAssertEqual(error as? VaultError, .keyMissingForExistingData)
        }

        let aside = try vault.setAsideOrphanedData()
        XCTAssertTrue(FileManager.default.fileExists(atPath: aside.appendingPathComponent("offline.db").path))
        XCTAssertEqual(try vault.status(), .needsSetup)
        XCTAssertNoThrow(try vault.create(reason: "test"))
    }

    func testDefaultDirectoryIsNoIndex() throws {
        let url = try Vault.defaultDirectory()
        XCTAssertEqual(url.lastPathComponent, "Data.noindex")
        XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, "Offline")
    }
}

final class LockPolicyTests: XCTestCase {
    func testTimeoutIsClampedAndCannotBeDisabled() {
        XCTAssertEqual(LockPolicy(timeoutMinutes: 0).timeoutMinutes, 1)
        XCTAssertEqual(LockPolicy(timeoutMinutes: -5).timeoutMinutes, 1)
        XCTAssertEqual(LockPolicy(timeoutMinutes: 500).timeoutMinutes, 60)
        XCTAssertEqual(LockPolicy().timeoutMinutes, 5)
    }

    func testLocksAfterIdleTimeout() {
        let policy = LockPolicy(timeoutMinutes: 5)
        let start = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertFalse(policy.shouldLock(lastActivity: start, now: start.addingTimeInterval(299)))
        XCTAssertTrue(policy.shouldLock(lastActivity: start, now: start.addingTimeInterval(300)))
        XCTAssertTrue(policy.shouldLock(lastActivity: start, now: start.addingTimeInterval(-10)))
        XCTAssertEqual(policy.statusText(lastActivity: start, now: start.addingTimeInterval(61)), "Locks in 4 min")
        XCTAssertEqual(policy.statusText(lastActivity: start, now: start.addingTimeInterval(290)), "Locks in under a minute")
    }
}
