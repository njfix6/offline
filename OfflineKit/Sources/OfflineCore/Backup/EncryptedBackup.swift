import CryptoKit
import Foundation

/// Reads and writes `.offlinebackup` files.
///
/// Layout (integers are big-endian):
///
///     header (42 bytes)
///       magic        8   "OFFLBKUP"
///       version      1   1
///       kdf          1   1 = Argon2id
///       iterations   4
///       memory KiB   4
///       parallelism  4
///       salt        16   random
///       reserved     4   zero
///     records, repeated
///       length       4   size of the sealed box that follows
///       sealed box       AES-256-GCM ciphertext + 16-byte tag
///
/// Each record is sealed with the key Argon2id derives from the passphrase and
/// the salt. The nonce is the record's index, and the header plus the index
/// are authenticated with every record, so records cannot be reordered,
/// dropped or moved between files. The first plaintext byte of a record is its
/// kind: the manifest (all notes, folders and tags as JSON), one record per
/// image, then an end marker carrying the image count, which makes truncation
/// detectable.
///
/// Nothing is ever written to disk unencrypted, and a backup is independent of
/// the Keychain key, so it can be restored on another Mac.
public enum EncryptedBackup {
    public static let fileExtension = "offlinebackup"
    public static let minimumPassphraseLength = 8

    static let magic = Array("OFFLBKUP".utf8)
    static let version: UInt8 = 1
    static let kdfArgon2id: UInt8 = 1
    static let headerLength = 42
    static let saltLength = 16
    /// Upper bound on one record, to reject nonsense lengths early.
    static let maximumRecordLength = 600 * 1024 * 1024

    enum RecordKind: UInt8 {
        case manifest = 1
        case attachment = 2
        case end = 255
    }

    public enum Failure: Error, Equatable, Sendable {
        case passphraseTooShort
        /// Not an Offline backup, or made by a newer version.
        case unrecognizedFile
        /// The passphrase is wrong or the file has been altered.
        case wrongPassphraseOrDamaged
        /// The file ends early or its contents are inconsistent.
        case incomplete
    }

    struct Manifest: Codable {
        var formatVersion: Int
        var createdAt: Date
        var snapshot: VaultSnapshot
    }

    struct AttachmentHeader: Codable {
        var id: UUID
        var noteID: UUID
        var mimeType: String
        var createdAt: Date
    }

    public struct Summary: Equatable, Sendable {
        public var noteCount: Int
        public var folderCount: Int
        public var attachmentCount: Int
    }

    // MARK: - Writing

    /// Writes an encrypted backup of `store` to `url`, replacing any file
    /// there. On failure the partial file is removed.
    @discardableResult
    public static func write(
        store: Store,
        to url: URL,
        passphrase: String,
        parameters: Argon2id.Parameters = .standard,
        now: Date = Date()
    ) throws -> Summary {
        guard passphrase.count >= minimumPassphraseLength else { throw Failure.passphraseTooShort }

        var generator = SystemRandomNumberGenerator()
        let salt = (0..<saltLength).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        let header = makeHeader(parameters: parameters, salt: salt)
        let keyBytes = try Argon2id.deriveKey(passphrase: passphrase, salt: salt, parameters: parameters)
        defer { keyBytes.wipe() }
        let key = try keyBytes.withBytes { SymmetricKey(data: Data($0)) }

        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
        guard fileManager.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let handle = try FileHandle(forWritingTo: url)

        var summary = Summary(noteCount: 0, folderCount: 0, attachmentCount: 0)
        do {
            try handle.write(contentsOf: Data(header))
            var sealer = RecordSealer(key: key, header: header)

            try store.readSnapshot({ snapshot in
                summary.noteCount = snapshot.notes.count
                summary.folderCount = snapshot.folders.count
                let manifest = Manifest(formatVersion: Int(version), createdAt: now, snapshot: snapshot)
                let json = try JSONEncoder().encode(manifest)
                try handle.write(contentsOf: try sealer.seal(kind: .manifest, payload: json))
            }, attachment: { attachment in
                let headerJSON = try JSONEncoder().encode(AttachmentHeader(
                    id: attachment.id,
                    noteID: attachment.noteID,
                    mimeType: attachment.mimeType,
                    createdAt: attachment.createdAt
                ))
                var payload = Data()
                payload.append(contentsOf: bigEndianBytes(UInt32(headerJSON.count)))
                payload.append(headerJSON)
                payload.append(attachment.data)
                try handle.write(contentsOf: try sealer.seal(kind: .attachment, payload: payload))
                summary.attachmentCount += 1
            })

            let endPayload = Data(bigEndianBytes(UInt32(summary.attachmentCount)))
            try handle.write(contentsOf: try sealer.seal(kind: .end, payload: endPayload))
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            try? fileManager.removeItem(at: url)
            throw error
        }
        return summary
    }

    // MARK: - Restoring

    /// Replaces the contents of `store` with the backup at `url`. The store is
    /// only changed if the whole file decrypts and is complete.
    @discardableResult
    public static func restore(from url: URL, passphrase: String, into store: Store) throws -> Summary {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        guard let headerData = try handle.read(upToCount: headerLength), headerData.count == headerLength else {
            throw Failure.unrecognizedFile
        }
        let header = Array(headerData)
        let (parameters, salt) = try parseHeader(header)

        let keyBytes = try Argon2id.deriveKey(passphrase: passphrase, salt: salt, parameters: parameters)
        defer { keyBytes.wipe() }
        let key = try keyBytes.withBytes { SymmetricKey(data: Data($0)) }
        var opener = RecordOpener(key: key, header: header, handle: handle)

        // The manifest is checked before the store is touched, so a wrong
        // passphrase never modifies anything.
        guard let first = try opener.next(), first.kind == .manifest else { throw Failure.incomplete }
        let manifest: Manifest
        do {
            manifest = try JSONDecoder().decode(Manifest.self, from: first.payload)
        } catch {
            throw Failure.incomplete
        }
        let snapshot = manifest.snapshot
        let knownNotes = Set(snapshot.notes.map(\.id))
        var summary = Summary(
            noteCount: snapshot.notes.count,
            folderCount: snapshot.folders.count,
            attachmentCount: 0
        )

        try store.replaceAll(with: snapshot) { insert in
            var finished = false
            while !finished {
                guard let record = try opener.next() else { throw Failure.incomplete }
                switch record.kind {
                case .manifest:
                    throw Failure.incomplete
                case .attachment:
                    let attachment = try decodeAttachment(record.payload)
                    guard knownNotes.contains(attachment.noteID) else { throw Failure.incomplete }
                    try insert(attachment)
                    summary.attachmentCount += 1
                case .end:
                    guard record.payload.count == 4,
                          readUInt32(Array(record.payload), at: 0) == UInt32(summary.attachmentCount),
                          try opener.isAtEnd()
                    else { throw Failure.incomplete }
                    finished = true
                }
            }
        }
        return summary
    }

    // MARK: - Header

    static func makeHeader(parameters: Argon2id.Parameters, salt: [UInt8]) -> [UInt8] {
        var header = magic
        header.append(version)
        header.append(kdfArgon2id)
        header.append(contentsOf: bigEndianBytes(parameters.iterations))
        header.append(contentsOf: bigEndianBytes(parameters.memoryKiB))
        header.append(contentsOf: bigEndianBytes(parameters.parallelism))
        header.append(contentsOf: salt)
        header.append(contentsOf: [0, 0, 0, 0])
        precondition(header.count == headerLength)
        return header
    }

    static func parseHeader(_ header: [UInt8]) throws -> (Argon2id.Parameters, [UInt8]) {
        guard header.count == headerLength,
              Array(header[0..<8]) == magic,
              header[8] == version,
              header[9] == kdfArgon2id
        else { throw Failure.unrecognizedFile }
        let parameters = Argon2id.Parameters(
            iterations: readUInt32(header, at: 10),
            memoryKiB: readUInt32(header, at: 14),
            parallelism: readUInt32(header, at: 18)
        )
        guard parameters.isAcceptable else { throw Failure.unrecognizedFile }
        return (parameters, Array(header[22..<38]))
    }

    private static func decodeAttachment(_ payload: Data) throws -> Attachment {
        let bytes = Array(payload.prefix(4))
        guard bytes.count == 4 else { throw Failure.incomplete }
        let headerLength = Int(readUInt32(bytes, at: 0))
        guard headerLength > 0, payload.count >= 4 + headerLength else { throw Failure.incomplete }
        let start = payload.startIndex + 4
        let headerData = payload[start..<(start + headerLength)]
        let header: AttachmentHeader
        do {
            header = try JSONDecoder().decode(AttachmentHeader.self, from: Data(headerData))
        } catch {
            throw Failure.incomplete
        }
        return Attachment(
            id: header.id,
            noteID: header.noteID,
            mimeType: header.mimeType,
            data: Data(payload[(start + headerLength)...]),
            createdAt: header.createdAt
        )
    }
}

// MARK: - Records

private func nonce(for index: UInt64) throws -> AES.GCM.Nonce {
    // 96-bit nonce: four zero bytes, then the record index. The key is unique
    // to this file (random salt), so an index never repeats under one key.
    try AES.GCM.Nonce(data: Data([0, 0, 0, 0] + bigEndianBytes(index)))
}

private func associatedData(header: [UInt8], index: UInt64) -> Data {
    Data(header + bigEndianBytes(index))
}

private struct RecordSealer {
    let key: SymmetricKey
    let header: [UInt8]
    var index: UInt64 = 0

    mutating func seal(kind: EncryptedBackup.RecordKind, payload: Data) throws -> Data {
        var plaintext = Data([kind.rawValue])
        plaintext.append(payload)
        let box = try AES.GCM.seal(
            plaintext,
            using: key,
            nonce: try nonce(for: index),
            authenticating: associatedData(header: header, index: index)
        )
        index += 1
        var framed = Data(bigEndianBytes(UInt32(box.ciphertext.count + box.tag.count)))
        framed.append(box.ciphertext)
        framed.append(box.tag)
        return framed
    }
}

private struct RecordOpener {
    let key: SymmetricKey
    let header: [UInt8]
    let handle: FileHandle
    var index: UInt64 = 0

    mutating func next() throws -> (kind: EncryptedBackup.RecordKind, payload: Data)? {
        guard let lengthData = try handle.read(upToCount: 4), !lengthData.isEmpty else { return nil }
        guard lengthData.count == 4 else { throw EncryptedBackup.Failure.incomplete }
        let length = Int(readUInt32(Array(lengthData), at: 0))
        guard length >= 17, length <= EncryptedBackup.maximumRecordLength else {
            throw EncryptedBackup.Failure.incomplete
        }
        guard let sealed = try handle.read(upToCount: length), sealed.count == length else {
            throw EncryptedBackup.Failure.incomplete
        }
        let plaintext: Data
        do {
            let box = try AES.GCM.SealedBox(
                nonce: try nonce(for: index),
                ciphertext: sealed.dropLast(16),
                tag: sealed.suffix(16)
            )
            plaintext = try AES.GCM.open(
                box,
                using: key,
                authenticating: associatedData(header: header, index: index)
            )
        } catch {
            throw EncryptedBackup.Failure.wrongPassphraseOrDamaged
        }
        index += 1
        guard let first = plaintext.first, let kind = EncryptedBackup.RecordKind(rawValue: first) else {
            throw EncryptedBackup.Failure.incomplete
        }
        return (kind, Data(plaintext.dropFirst()))
    }

    func isAtEnd() throws -> Bool {
        let rest = try handle.read(upToCount: 1)
        return rest == nil || rest?.isEmpty == true
    }
}

// MARK: - Bytes

func bigEndianBytes<T: FixedWidthInteger>(_ value: T) -> [UInt8] {
    withUnsafeBytes(of: value.bigEndian) { Array($0) }
}

func readUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
    bytes[offset..<(offset + 4)].reduce(0) { ($0 << 8) | UInt32($1) }
}
