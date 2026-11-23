import Foundation
import XCTest
@testable import OfflineCore

/// A key store that lives in memory, standing in for the Keychain.
final class InMemoryKeyStore: KeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [UInt8]?
    private(set) var presenceChecks = 0
    private(set) var loads = 0
    var failNextLoad: VaultError?

    func keyExists() throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        return stored != nil
    }

    func confirmUserPresence(reason: String) throws {
        lock.lock(); defer { lock.unlock() }
        presenceChecks += 1
    }

    func storeKey(_ key: SecureBytes) throws {
        lock.lock(); defer { lock.unlock() }
        guard stored == nil else { throw VaultError.keyAlreadyExists }
        stored = try key.withBytes { Array($0) }
    }

    func loadKey(reason: String) throws -> SecureBytes {
        lock.lock(); defer { lock.unlock() }
        loads += 1
        if let failure = failNextLoad {
            failNextLoad = nil
            throw failure
        }
        guard let stored else { throw VaultError.keyNotFound }
        return stored.withUnsafeBytes { SecureBytes(copying: $0) }
    }

    func deleteKey() throws {
        lock.lock(); defer { lock.unlock() }
        stored = nil
    }

    var rawKey: [UInt8]? {
        lock.lock(); defer { lock.unlock() }
        return stored
    }
}

class TemporaryDirectoryTestCase: XCTestCase {
    var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("offline-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func makeStore(name: String = "test.db", key: SecureBytes = .random(count: 32)) throws -> Store {
        try Store.open(at: directory.appendingPathComponent(name), key: key)
    }

    /// Every byte of every file under `url`, concatenated.
    func allBytes(under url: URL) throws -> Data {
        var data = Data()
        let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey])
        while let file = enumerator?.nextObject() as? URL {
            if (try file.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true {
                data.append(try Data(contentsOf: file))
            }
        }
        return data
    }
}

/// Small, fast Argon2 settings for tests.
let testKDF = Argon2id.Parameters(iterations: 1, memoryKiB: 64, parallelism: 1)

/// A tiny valid PNG header followed by filler, enough for type sniffing.
func fakePNG(marker: String = "pixels") -> Data {
    Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) + Data(marker.utf8)
}
