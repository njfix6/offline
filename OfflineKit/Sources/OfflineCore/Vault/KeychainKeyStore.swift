#if canImport(Security) && canImport(LocalAuthentication)
import Foundation
import LocalAuthentication
import Security

/// Stores the data key as a generic password in the macOS data-protection
/// Keychain.
///
/// The item is:
/// - readable only after Touch ID or the Mac password (`.userPresence`),
/// - readable only while the Mac is unlocked, and never migrated to another
///   device (`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`),
/// - never synced to iCloud Keychain (`kSecAttrSynchronizable` = false).
///
/// The data-protection Keychain needs an application identifier, so the app
/// has to be signed with a development team; an ad-hoc signed build gets
/// `errSecMissingEntitlement`.
public struct KeychainKeyStore: KeyStore {
    public let service: String
    public let account: String

    public init(service: String = "app.offline.notes.datakey", account: String = "vault") {
        self.service = service
        self.account = account
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true,
            kSecAttrSynchronizable as String: false,
        ]
    }

    public func keyExists() throws -> Bool {
        // A context that is not allowed to show UI: an existing item reports
        // "interaction not allowed" instead of prompting.
        let context = LAContext()
        context.interactionNotAllowed = true
        var query = baseQuery
        query[kSecUseAuthenticationContext as String] = context
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnAttributes as String] = true

        let status = SecItemCopyMatching(query as CFDictionary, nil)
        switch status {
        case errSecSuccess, errSecInteractionNotAllowed, errSecAuthFailed:
            return true
        case errSecItemNotFound:
            return false
        default:
            throw VaultError.keychain(status: status)
        }
    }

    public func confirmUserPresence(reason: String) throws {
        let context = LAContext()
        context.touchIDAuthenticationAllowableReuseDuration = 0

        var policyError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &policyError) else {
            // No Touch ID and no password set: nothing can protect the key.
            throw VaultError.authenticationFailed
        }

        let semaphore = DispatchSemaphore(value: 0)
        let outcome = OutcomeBox()
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, error in
            if success {
                outcome.set(nil)
            } else if let laError = error as? LAError,
                      [.userCancel, .appCancel, .systemCancel].contains(laError.code) {
                outcome.set(.userCancelled)
            } else {
                outcome.set(.authenticationFailed)
            }
            semaphore.signal()
        }
        semaphore.wait()
        if let failure = outcome.value { throw failure }
    }

    public func storeKey(_ key: SecureBytes) throws {
        var accessError: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(
            kCFAllocatorDefault,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            .userPresence,
            &accessError
        ) else {
            accessError?.release()
            throw VaultError.keychain(status: errSecParam)
        }

        let status: OSStatus = try key.withBytes { bytes in
            // The Keychain API needs a CFData. This copy is released as soon
            // as SecItemAdd returns.
            var data = Data(bytes)
            defer { data.resetBytes(in: 0..<data.count) }
            var attributes = baseQuery
            attributes[kSecAttrAccessControl as String] = access
            attributes[kSecValueData as String] = data
            attributes[kSecAttrLabel as String] = "Offline data key"
            return SecItemAdd(attributes as CFDictionary, nil)
        }

        switch status {
        case errSecSuccess: return
        case errSecDuplicateItem: throw VaultError.keyAlreadyExists
        default: throw VaultError.keychain(status: status)
        }
    }

    public func loadKey(reason: String) throws -> SecureBytes {
        let context = LAContext()
        context.localizedReason = reason
        context.touchIDAuthenticationAllowableReuseDuration = 0

        var query = baseQuery
        query[kSecUseAuthenticationContext as String] = context
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard var data = result as? Data else { throw VaultError.malformedKey }
            defer { data.resetBytes(in: 0..<data.count) }
            return data.withUnsafeBytes { SecureBytes(copying: $0) }
        case errSecItemNotFound:
            throw VaultError.keyNotFound
        case errSecUserCanceled:
            throw VaultError.userCancelled
        case errSecAuthFailed:
            throw VaultError.authenticationFailed
        default:
            throw VaultError.keychain(status: status)
        }
    }

    public func deleteKey() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw VaultError.keychain(status: status)
        }
    }
}

private final class OutcomeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: VaultError?

    func set(_ value: VaultError?) {
        lock.lock()
        stored = value
        lock.unlock()
    }

    var value: VaultError? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}
#endif
