import CArgon2
import Foundation

/// Argon2id key derivation, using the vendored reference implementation.
public enum Argon2id {
    public struct Parameters: Equatable, Sendable {
        /// Number of passes.
        public var iterations: UInt32
        /// Memory in KiB.
        public var memoryKiB: UInt32
        public var parallelism: UInt32

        public init(iterations: UInt32, memoryKiB: UInt32, parallelism: UInt32) {
            self.iterations = iterations
            self.memoryKiB = memoryKiB
            self.parallelism = parallelism
        }

        /// 3 passes over 256 MiB: the same cost as libsodium's "moderate"
        /// preset. Takes about a second on a current Mac.
        public static let standard = Parameters(iterations: 3, memoryKiB: 262_144, parallelism: 1)

        /// Limits accepted when reading a backup, so a hostile file cannot
        /// make the app allocate absurd amounts of memory.
        public var isAcceptable: Bool {
            (1...16).contains(iterations)
                && (8 * parallelism...1_048_576).contains(memoryKiB)
                && (1...8).contains(parallelism)
        }
    }

    public enum Failure: Error, Equatable, Sendable {
        case invalidParameters
        case derivationFailed(code: Int32)
    }

    /// Derives `length` bytes from a passphrase and salt.
    public static func deriveKey(
        passphrase: String,
        salt: [UInt8],
        parameters: Parameters,
        length: Int = 32
    ) throws -> SecureBytes {
        guard parameters.isAcceptable, salt.count >= 8, length >= 16 else {
            throw Failure.invalidParameters
        }
        var password = Array(passphrase.utf8)
        defer { password.secureWipe() }

        var output = [UInt8](repeating: 0, count: length)
        defer { output.secureWipe() }

        let code = argon2id_hash_raw(
            parameters.iterations,
            parameters.memoryKiB,
            parameters.parallelism,
            password,
            password.count,
            salt,
            salt.count,
            &output,
            length
        )
        guard code == ARGON2_OK.rawValue else {
            throw Failure.derivationFailed(code: code)
        }
        return output.withUnsafeBytes { SecureBytes(copying: $0) }
    }
}
