import XCTest
@testable import OfflineCore

final class Argon2Tests: XCTestCase {
    /// Known answer from the Argon2 reference test suite (Argon2id, v1.3).
    func testKnownAnswer() throws {
        let key = try Argon2id.deriveKey(
            passphrase: "password",
            salt: Array("somesalt".utf8),
            parameters: .init(iterations: 2, memoryKiB: 65_536, parallelism: 1)
        )
        let hex = try key.withBytes { $0.map { String(format: "%02x", $0) }.joined() }
        XCTAssertEqual(hex, "09316115d5cf24ed5a15a31a3ba326e5cf32edc24702987c02b6566f61913cf7")
    }

    func testRejectsUnreasonableParameters() {
        XCTAssertFalse(Argon2id.Parameters(iterations: 0, memoryKiB: 64, parallelism: 1).isAcceptable)
        XCTAssertFalse(Argon2id.Parameters(iterations: 3, memoryKiB: 4_000_000_000, parallelism: 1).isAcceptable)
        XCTAssertFalse(Argon2id.Parameters(iterations: 3, memoryKiB: 64, parallelism: 64).isAcceptable)
        XCTAssertTrue(Argon2id.Parameters.standard.isAcceptable)
    }
}

final class EncryptedBackupTests: TemporaryDirectoryTestCase {
    private let passphrase = "correct horse battery"
    private let secret = "narwhalmarmalade"

    private func populate(_ store: Store) throws -> (note: Note, imageID: UUID) {
        let folder = try store.createFolder(name: "Journal \(secret)")
        let sub = try store.createFolder(name: "2026", parentID: folder.id)
        let note = try store.createNote(folderID: sub.id, title: "Entry \(secret)", now: Date(timeIntervalSince1970: 1_700_000_000))
        let imageID = try store.addAttachment(noteID: note.id, mimeType: "image/png", data: fakePNG(marker: secret))
        try store.updateNote(
            id: note.id,
            body: "Dear diary \(secret)\n\(AttachmentReference.token(id: imageID))",
            now: Date(timeIntervalSince1970: 1_700_000_500)
        )
        try store.setTags(["private", "daily"], forNote: note.id)
        try store.setPinned(true, noteID: note.id)
        let trashed = try store.createNote(title: "In the trash")
        try store.trashNote(id: trashed.id)
        return (try XCTUnwrap(store.note(id: note.id)), imageID)
    }

    private func snapshot(of store: Store) throws -> (VaultSnapshot, [Attachment]) {
        var result = VaultSnapshot()
        var images: [Attachment] = []
        try store.readSnapshot({ result = $0 }, attachment: { images.append($0) })
        return (result, images)
    }

    func testRoundTripIntoAFreshVault() throws {
        let source = try makeStore(name: "source.db")
        let (note, imageID) = try populate(source)
        let file = directory.appendingPathComponent("vault.offlinebackup")

        let written = try EncryptedBackup.write(store: source, to: file, passphrase: passphrase, parameters: testKDF)
        XCTAssertEqual(written, .init(noteCount: 2, folderCount: 2, attachmentCount: 1))

        // A different key, as on another Mac.
        let target = try makeStore(name: "target.db")
        try target.createNote(title: "will be replaced")
        let restored = try EncryptedBackup.restore(from: file, passphrase: passphrase, into: target)
        XCTAssertEqual(restored, written)

        let (before, beforeImages) = try snapshot(of: source)
        let (after, afterImages) = try snapshot(of: target)
        XCTAssertEqual(before, after)
        XCTAssertEqual(beforeImages, afterImages)
        XCTAssertEqual(try target.note(id: note.id), note)
        XCTAssertEqual(try target.attachment(id: imageID)?.data, fakePNG(marker: secret))
        XCTAssertEqual(try target.search(secret).map(\.id), [note.id], "the search index is rebuilt on restore")
        XCTAssertEqual(try target.noteCount(in: .trash), 1)
    }

    func testBackupFileHoldsNoPlaintext() throws {
        let source = try makeStore()
        _ = try populate(source)
        let file = directory.appendingPathComponent("vault.offlinebackup")
        try EncryptedBackup.write(store: source, to: file, passphrase: passphrase, parameters: testKDF)

        let bytes = try Data(contentsOf: file)
        XCTAssertEqual(Array(bytes.prefix(8)), Array("OFFLBKUP".utf8))
        XCTAssertNil(bytes.range(of: Data(secret.utf8)))
        XCTAssertNil(bytes.range(of: Data("private".utf8)))
        XCTAssertNil(bytes.range(of: Data("image/png".utf8)))
    }

    func testWrongPassphraseFailsAndChangesNothing() throws {
        let source = try makeStore(name: "source.db")
        _ = try populate(source)
        let file = directory.appendingPathComponent("vault.offlinebackup")
        try EncryptedBackup.write(store: source, to: file, passphrase: passphrase, parameters: testKDF)

        let target = try makeStore(name: "target.db")
        let existing = try target.createNote(title: "still here")
        for wrong in ["", "wrong horse battery", passphrase + " "] {
            XCTAssertThrowsError(try EncryptedBackup.restore(from: file, passphrase: wrong, into: target)) { error in
                XCTAssertEqual(error as? EncryptedBackup.Failure, .wrongPassphraseOrDamaged)
            }
        }
        XCTAssertEqual(try target.notes(in: .all, sortedBy: .title).map(\.id), [existing.id])
    }

    func testTamperedOrTruncatedFilesAreRejectedAndRolledBack() throws {
        let source = try makeStore(name: "source.db")
        _ = try populate(source)
        let file = directory.appendingPathComponent("vault.offlinebackup")
        try EncryptedBackup.write(store: source, to: file, passphrase: passphrase, parameters: testKDF)
        let original = try Data(contentsOf: file)

        let target = try makeStore(name: "target.db")
        let existing = try target.createNote(title: "still here")

        var variants: [String: Data] = [:]
        var flipped = original
        flipped[flipped.count - 5] ^= 0x01
        variants["last byte flipped"] = flipped
        var middle = original
        middle[original.count / 2] ^= 0x80
        variants["middle byte flipped"] = middle
        variants["end record removed"] = original.dropLast(4 + 1 + 4 + 16)
        variants["cut mid-record"] = original.prefix(original.count - 7)
        variants["extra bytes appended"] = original + Data([0, 0, 0, 1])
        var saltChanged = original
        saltChanged[25] ^= 0xFF
        variants["salt changed"] = saltChanged
        variants["not a backup"] = Data("hello, this is not a backup file at all, really".utf8)
        variants["empty"] = Data()

        for (name, data) in variants {
            let damaged = directory.appendingPathComponent("damaged.offlinebackup")
            try data.write(to: damaged)
            XCTAssertThrowsError(
                try EncryptedBackup.restore(from: damaged, passphrase: passphrase, into: target),
                "\(name) should be rejected"
            )
            XCTAssertEqual(
                try target.notes(in: .all, sortedBy: .title).map(\.id), [existing.id],
                "\(name) must leave the vault untouched"
            )
        }
        XCTAssertNoThrow(try EncryptedBackup.restore(from: file, passphrase: passphrase, into: target))
    }

    func testShortPassphraseIsRefusedAndNoFileIsLeft() throws {
        let source = try makeStore()
        let file = directory.appendingPathComponent("vault.offlinebackup")
        XCTAssertThrowsError(try EncryptedBackup.write(store: source, to: file, passphrase: "short", parameters: testKDF)) { error in
            XCTAssertEqual(error as? EncryptedBackup.Failure, .passphraseTooShort)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testTwoBackupsOfTheSameVaultDiffer() throws {
        let source = try makeStore()
        _ = try populate(source)
        let a = directory.appendingPathComponent("a.offlinebackup")
        let b = directory.appendingPathComponent("b.offlinebackup")
        try EncryptedBackup.write(store: source, to: a, passphrase: passphrase, parameters: testKDF)
        try EncryptedBackup.write(store: source, to: b, passphrase: passphrase, parameters: testKDF)
        XCTAssertNotEqual(try Data(contentsOf: a), try Data(contentsOf: b), "each backup uses a fresh salt")
    }
}

final class MarkdownTransferTests: TemporaryDirectoryTestCase {
    func testExportAllThenImportRoundTrip() throws {
        let store = try makeStore(name: "a.db")
        let folder = try store.createFolder(name: "Work")
        let sub = try store.createFolder(name: "Plans: Q1/Q2", parentID: folder.id)
        let note = try store.createNote(folderID: sub.id, title: "Road/map?", now: Date(timeIntervalSince1970: 1_600_000_000))
        let imageID = try store.addAttachment(noteID: note.id, mimeType: "image/png", data: fakePNG())
        try store.updateNote(
            id: note.id,
            body: "# Plan\n\n\(AttachmentReference.token(id: imageID, alt: "chart"))\n",
            now: Date(timeIntervalSince1970: 1_600_000_600)
        )
        try store.setTags(["plan", "with, comma"], forNote: note.id)
        _ = try store.createNote(title: "Road/map?", body: "same title, no folder")
        let trashed = try store.createNote(title: "Trashed")
        try store.trashNote(id: trashed.id)

        let out = directory.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let report = try MarkdownExport.exportAll(from: store, to: out)
        XCTAssertEqual(report.noteCount, 2, "trashed notes are not exported")
        XCTAssertEqual(report.imageCount, 1)

        let noteFile = report.destination
            .appendingPathComponent("Work/Plans- Q1-Q2/Road-map-.md")
        let text = try String(contentsOf: noteFile, encoding: .utf8)
        XCTAssertTrue(text.contains("![chart](attachments/\(imageID.uuidString).png)"))
        XCTAssertTrue(text.hasPrefix("---\ntitle: \"Road/map?\"\n"))

        let target = try makeStore(name: "b.db")
        let imported = try MarkdownImport.importItems([report.destination], into: target)
        XCTAssertEqual(imported.noteCount, 2)
        XCTAssertEqual(imported.imageCount, 1)

        let folders = try target.folders()
        XCTAssertEqual(folders.map(\.name), [report.destination.lastPathComponent, "Work"])
        let copy = try XCTUnwrap(try target.search("plan").first.flatMap { try target.note(id: $0.id) })
        XCTAssertEqual(copy.title, "Road/map?")
        XCTAssertEqual(copy.createdAt, Date(timeIntervalSince1970: 1_600_000_000))
        XCTAssertEqual(copy.updatedAt, Date(timeIntervalSince1970: 1_600_000_600))
        XCTAssertEqual(try target.tags(forNote: copy.id).map(\.name), ["plan", "with, comma"])
        let reference = try XCTUnwrap(AttachmentReference.findAll(in: copy.body).first)
        XCTAssertEqual(reference.alt, "chart")
        XCTAssertEqual(try target.attachment(id: reference.id)?.data, fakePNG())
    }

    func testExportSingleNoteNeverOverwrites() throws {
        let store = try makeStore()
        let note = try store.createNote(title: "Same", body: "one")
        let out = directory.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        _ = try MarkdownExport.exportNote(id: note.id, from: store, to: out)
        try store.updateNote(id: note.id, body: "two")
        _ = try MarkdownExport.exportNote(id: note.id, from: store, to: out)

        XCTAssertTrue(try String(contentsOf: out.appendingPathComponent("Same.md"), encoding: .utf8).hasSuffix("one\n"))
        XCTAssertTrue(try String(contentsOf: out.appendingPathComponent("Same 2.md"), encoding: .utf8).hasSuffix("two\n"))
    }

    func testImportPlainFilesAndIgnoresOtherTypes() throws {
        let source = directory.appendingPathComponent("in", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("just text".utf8).write(to: source.appendingPathComponent("Plain.txt"))
        try Data("# Heading\nbody".utf8).write(to: source.appendingPathComponent("Doc.md"))
        try Data([0, 1, 2]).write(to: source.appendingPathComponent("binary.dat"))
        try Data("![x](../../etc/passwd.png) ![y](https://example.com/a.png)".utf8)
            .write(to: source.appendingPathComponent("Links.md"))

        let store = try makeStore()
        let folder = try store.createFolder(name: "Inbox")
        let report = try MarkdownImport.importItems(
            [source.appendingPathComponent("Plain.txt"), source.appendingPathComponent("binary.dat")],
            into: store,
            folderID: folder.id
        )
        XCTAssertEqual(report, .init(noteCount: 1, imageCount: 0, skippedCount: 1))
        let plain = try XCTUnwrap(store.notes(in: .folder(folder.id), sortedBy: .title).first)
        XCTAssertEqual(plain.title, "Plain")
        XCTAssertEqual(plain.preview, "just text")

        let whole = try MarkdownImport.importItems([source], into: store)
        XCTAssertEqual(whole.noteCount, 3)
        XCTAssertEqual(whole.imageCount, 0, "links outside the folder or to the web are left alone")
        XCTAssertTrue(try store.attachmentInfos().isEmpty)
    }

    func testFrontMatterParsing() {
        let parsed = FrontMatter.parse("---\ntitle: \"A \\\"quoted\\\" title\"\ntags: [\"a\", b, \"c, d\"]\ncreated: 2026-01-02T03:04:05Z\nweird\n---\n\nBody\n---\nmore")
        XCTAssertEqual(parsed.title, "A \"quoted\" title")
        XCTAssertEqual(parsed.tags, ["a", "b", "c, d"])
        XCTAssertEqual(parsed.createdAt, Date(timeIntervalSince1970: 1_767_323_045))
        XCTAssertNil(parsed.updatedAt)
        XCTAssertEqual(parsed.body, "Body\n---\nmore")

        XCTAssertEqual(FrontMatter.parse("no front matter\n---\n").body, "no front matter\n---\n")
        XCTAssertEqual(MarkdownExport.fileName(from: "  ..a/b:c*  "), "a-b-c-")
        XCTAssertEqual(MarkdownExport.fileName(from: "///"), "---")
        XCTAssertEqual(MarkdownExport.fileName(from: ""), "Untitled")
    }
}
