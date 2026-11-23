import Foundation
import GRDB

extension Store {
    /// Keys a new connection and turns on the hardening pragmas. Runs for
    /// every connection the pool opens.
    static func prepare(_ db: Database, key: SecureBytes) throws {
        try applyKey(key, to: db)

        // Refuse to continue if this SQLite build cannot encrypt. Plain SQLite
        // silently ignores `PRAGMA key`, which would leave notes in plaintext.
        let cipherVersion = try String.fetchOne(db, sql: "PRAGMA cipher_version")
        guard let cipherVersion, !cipherVersion.isEmpty else {
            throw StoreError.encryptionUnavailable
        }

        // Wipe SQLCipher's internal buffers when they are freed.
        try db.execute(sql: "PRAGMA cipher_memory_security = ON")
        // Temporary tables and indices stay in RAM, never in plaintext files.
        try db.execute(sql: "PRAGMA temp_store = MEMORY")
        // Overwrite deleted content with zeros inside the (encrypted) file.
        try db.execute(sql: "PRAGMA secure_delete = ON")
    }

    /// Gives SQLCipher the raw 256-bit key (`x'…'` form), so no passphrase
    /// derivation is involved: the key in the Keychain is the database key.
    private static func applyKey(_ key: SecureBytes, to db: Database) throws {
        var literal = try key.withBytes { bytes -> [UInt8] in
            let digits = Array("0123456789abcdef".utf8)
            var out: [UInt8] = []
            out.reserveCapacity(bytes.count * 2 + 3)
            out.append(UInt8(ascii: "x"))
            out.append(UInt8(ascii: "'"))
            for byte in bytes {
                out.append(digits[Int(byte >> 4)])
                out.append(digits[Int(byte & 0x0f)])
            }
            out.append(UInt8(ascii: "'"))
            return out
        }
        defer { literal.secureWipe() }

        var data = Data(literal)
        defer { data.resetBytes(in: 0..<data.count) }
        try db.usePassphrase(data)
    }
}
