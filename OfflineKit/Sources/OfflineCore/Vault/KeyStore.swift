import Foundation

/// Where the 256-bit data key is kept between launches.
///
/// The shipping implementation is `KeychainKeyStore`. Every method may block
/// (the Keychain shows a Touch ID or password prompt), so call them off the
/// main thread.
public protocol KeyStore: Sendable {
    /// Whether a key is stored. Must not prompt the user.
    func keyExists() throws -> Bool

    /// Asks the user to prove presence (Touch ID or Mac password) without
    /// touching the key. Used once, before the key is first created.
    func confirmUserPresence(reason: String) throws

    /// Stores a new key. Fails with `VaultError.keyAlreadyExists` rather than
    /// replacing an existing one.
    func storeKey(_ key: SecureBytes) throws

    /// Reads the key, prompting the user for Touch ID or their Mac password.
    func loadKey(reason: String) throws -> SecureBytes

    /// Removes the key. Data encrypted with it becomes unreadable.
    func deleteKey() throws
}

public enum VaultError: Error, Equatable, Sendable {
    /// The vault is locked, or the key has been wiped.
    case locked
    /// A key is already stored; refusing to overwrite it.
    case keyAlreadyExists
    /// No key is stored.
    case keyNotFound
    /// An encrypted database exists but its key is gone from the Keychain.
    case keyMissingForExistingData
    /// A key exists but the database it belongs to is gone.
    case vaultAlreadyExists
    /// The user cancelled the Touch ID / password prompt.
    case userCancelled
    /// Authentication failed.
    case authenticationFailed
    /// The stored key has an unexpected size.
    case malformedKey
    /// The Keychain returned an unexpected status code.
    case keychain(status: Int32)
}
