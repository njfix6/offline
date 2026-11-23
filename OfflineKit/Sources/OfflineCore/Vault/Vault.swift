import Foundation

/// Owns the data key and the encrypted database.
///
/// Unlocking reads the key from the `KeyStore` (which prompts for Touch ID or
/// the Mac password) and opens the database. Locking closes the database and
/// zeroes the key. The key is never written anywhere except the `KeyStore`.
public final class Vault: @unchecked Sendable {
    public enum Status: Equatable, Sendable {
        /// First launch: no key and no database yet.
        case needsSetup
        /// A key and (usually) a database exist. Ready to unlock.
        case ready
        /// A database exists but its key is gone. The data cannot be opened.
        case keyMissing
    }

    public static let keyLength = 32
    public static let databaseFileName = "offline.db"

    public let directory: URL
    private let keyStore: any KeyStore
    private let lock = NSLock()
    private var key: SecureBytes?
    private var openStore: Store?

    public init(directory: URL, keyStore: any KeyStore) {
        self.directory = directory
        self.keyStore = keyStore
    }

    /// `~/Library/Application Support/Offline/Data.noindex`. Inside the sandbox
    /// this resolves to the app's container. The `.noindex` suffix keeps
    /// Spotlight out.
    public static func defaultDirectory(fileManager: FileManager = .default) throws -> URL {
        let support = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return support
            .appendingPathComponent("Offline", isDirectory: true)
            .appendingPathComponent("Data.noindex", isDirectory: true)
    }

    public var databaseURL: URL {
        directory.appendingPathComponent(Self.databaseFileName, isDirectory: false)
    }

    public var isUnlocked: Bool {
        lock.lock()
        defer { lock.unlock() }
        return openStore != nil
    }

    /// The open store, or nil while locked.
    public var store: Store? {
        lock.lock()
        defer { lock.unlock() }
        return openStore
    }

    public func status() throws -> Status {
        let hasKey = try keyStore.keyExists()
        let hasDatabase = FileManager.default.fileExists(atPath: databaseURL.path)
        switch (hasKey, hasDatabase) {
        case (true, _): return .ready
        case (false, true): return .keyMissing
        case (false, false): return .needsSetup
        }
    }

    /// First launch: confirms the user is present, generates a random 256-bit
    /// key, stores it in the key store and creates the encrypted database.
    @discardableResult
    public func create(reason: String) throws -> Store {
        lock.lock()
        defer { lock.unlock() }
        if let openStore { return openStore }

        guard !FileManager.default.fileExists(atPath: databaseURL.path) else {
            // Never generate a new key over existing ciphertext.
            throw try keyStore.keyExists() ? VaultError.vaultAlreadyExists : VaultError.keyMissingForExistingData
        }
        guard try !keyStore.keyExists() else { throw VaultError.keyAlreadyExists }

        try keyStore.confirmUserPresence(reason: reason)
        let newKey = SecureBytes.random(count: Self.keyLength)
        try keyStore.storeKey(newKey)
        do {
            return try open(with: newKey)
        } catch {
            newKey.wipe()
            throw error
        }
    }

    /// Reads the key (prompting the user) and opens the database.
    @discardableResult
    public func unlock(reason: String) throws -> Store {
        lock.lock()
        defer { lock.unlock() }
        if let openStore { return openStore }

        guard try keyStore.keyExists() else {
            throw FileManager.default.fileExists(atPath: databaseURL.path)
                ? VaultError.keyMissingForExistingData
                : VaultError.keyNotFound
        }
        let loaded = try keyStore.loadKey(reason: reason)
        guard loaded.count == Self.keyLength else {
            loaded.wipe()
            throw VaultError.malformedKey
        }
        do {
            return try open(with: loaded)
        } catch {
            loaded.wipe()
            throw error
        }
    }

    /// Closes the database and zeroes the in-memory key.
    public func lockNow() {
        lock.lock()
        defer { lock.unlock() }
        openStore?.close()
        openStore = nil
        key?.wipe()
        key = nil
    }

    /// Moves an unreadable database (its key is gone) out of the way so a new
    /// vault can be created. Nothing is deleted: the old ciphertext is renamed
    /// next to where it was. Returns the folder holding the old files.
    @discardableResult
    public func setAsideOrphanedData(now: Date = Date()) throws -> URL {
        lock.lock()
        defer { lock.unlock() }
        guard openStore == nil else { throw VaultError.vaultAlreadyExists }
        guard try !keyStore.keyExists() else { throw VaultError.keyAlreadyExists }

        let fileManager = FileManager.default
        let stamp = Int(now.timeIntervalSince1970)
        let destination = directory.appendingPathComponent("orphaned-\(stamp)", isDirectory: true)
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        for suffix in ["", "-wal", "-shm"] {
            let source = directory.appendingPathComponent(Self.databaseFileName + suffix)
            if fileManager.fileExists(atPath: source.path) {
                try fileManager.moveItem(
                    at: source,
                    to: destination.appendingPathComponent(Self.databaseFileName + suffix)
                )
            }
        }
        return destination
    }

    // Caller holds `lock`.
    private func open(with newKey: SecureBytes) throws -> Store {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let store = try Store.open(at: databaseURL, key: newKey)
        key = newKey
        openStore = store
        return store
    }
}
