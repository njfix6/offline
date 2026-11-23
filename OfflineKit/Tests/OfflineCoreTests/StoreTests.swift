import GRDB
import XCTest
@testable import OfflineCore

final class StoreTests: TemporaryDirectoryTestCase {
    // MARK: Migrations

    func testMigrationCreatesSchema() throws {
        let store = try makeStore()
        XCTAssertEqual(try store.schemaVersion(), Store.currentSchemaVersion)
        XCTAssertNotNil(try store.createdAt())
        let tables = try store.pool.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type IN ('table', 'trigger')")
        }
        for name in ["meta", "folder", "note", "tag", "note_tag", "attachment", "note_fts",
                     "note_fts_insert", "note_fts_update", "note_fts_delete"] {
            XCTAssertTrue(tables.contains(name), "missing \(name)")
        }
    }

    func testReopeningKeepsDataAndDoesNotRerunMigrations() throws {
        let key = SecureBytes.random(count: 32)
        var store = try makeStore(key: key)
        let created = try store.createdAt()
        let note = try store.createNote(title: "Kept")
        store.close()

        store = try makeStore(key: key)
        XCTAssertEqual(try store.note(id: note.id)?.title, "Kept")
        XCTAssertEqual(try store.createdAt(), created)
        XCTAssertEqual(try store.schemaVersion(), 1)
    }

    func testDatabaseFromNewerVersionIsRefused() throws {
        let key = SecureBytes.random(count: 32)
        let store = try makeStore(key: key)
        try store.pool.write { db in
            try db.execute(sql: "INSERT INTO grdb_migrations (identifier) VALUES ('v999')")
        }
        store.close()
        XCTAssertThrowsError(try makeStore(key: key)) { error in
            XCTAssertEqual(error as? StoreError, .databaseTooNew)
        }
    }

    func testWALModeAndTempStore() throws {
        let store = try makeStore()
        let (journal, tempStore) = try store.pool.read { db in
            (try String.fetchOne(db, sql: "PRAGMA journal_mode"), try Int.fetchOne(db, sql: "PRAGMA temp_store"))
        }
        XCTAssertEqual(journal, "wal")
        XCTAssertEqual(tempStore, 2, "temp_store must be MEMORY")
    }

    // MARK: Notes

    func testCreateUpdateAndModifiedDate() throws {
        let store = try makeStore()
        let t0 = Date(timeIntervalSince1970: 1_000)
        let note = try store.createNote(title: "A", body: "one", now: t0)

        XCTAssertFalse(try store.updateNote(id: note.id, title: "A", body: "one", now: t0.addingTimeInterval(5)))
        XCTAssertEqual(try store.note(id: note.id)?.updatedAt, t0, "unchanged text must not move the date")

        XCTAssertTrue(try store.updateNote(id: note.id, body: "two", now: t0.addingTimeInterval(9)))
        let saved = try XCTUnwrap(store.note(id: note.id))
        XCTAssertEqual(saved.body, "two")
        XCTAssertEqual(saved.title, "A")
        XCTAssertEqual(saved.updatedAt, t0.addingTimeInterval(9))
        XCTAssertEqual(saved.createdAt, t0)
    }

    func testSortingAndPinning() throws {
        let store = try makeStore()
        let base = Date(timeIntervalSince1970: 10_000)
        let b = try store.createNote(title: "Banana", now: base)
        let a = try store.createNote(title: "apple", now: base.addingTimeInterval(10))
        let c = try store.createNote(title: "Cherry", now: base.addingTimeInterval(20))
        try store.updateNote(id: b.id, body: "edited", now: base.addingTimeInterval(30))

        XCTAssertEqual(try store.notes(in: .all, sortedBy: .modified).map(\.id), [b.id, c.id, a.id])
        XCTAssertEqual(try store.notes(in: .all, sortedBy: .created).map(\.id), [c.id, a.id, b.id])
        XCTAssertEqual(try store.notes(in: .all, sortedBy: .title).map(\.id), [a.id, b.id, c.id])

        try store.setPinned(true, noteID: c.id)
        XCTAssertEqual(try store.notes(in: .all, sortedBy: .title).map(\.id), [c.id, a.id, b.id])
    }

    func testTrashRestoreAndThirtyDayPurge() throws {
        let store = try makeStore()
        let now = Date(timeIntervalSince1970: 5_000_000)
        let old = try store.createNote(title: "old")
        let recent = try store.createNote(title: "recent")
        let kept = try store.createNote(title: "kept")
        try store.setTags(["gone"], forNote: old.id)

        try store.trashNote(id: old.id, now: now.addingTimeInterval(-31 * 86_400))
        try store.trashNote(id: recent.id, now: now.addingTimeInterval(-29 * 86_400))

        XCTAssertEqual(try store.notes(in: .all, sortedBy: .modified).map(\.id), [kept.id])
        XCTAssertEqual(try store.noteCount(in: .trash), 2)

        XCTAssertEqual(try store.purgeExpiredTrash(now: now), 1)
        XCTAssertNil(try store.note(id: old.id))
        XCTAssertNotNil(try store.note(id: recent.id))
        XCTAssertTrue(try store.tags().isEmpty, "tags only used by purged notes go away")

        try store.restoreNote(id: recent.id)
        XCTAssertNil(try store.note(id: recent.id)?.deletedAt)
        XCTAssertEqual(try store.noteCount(in: .all), 2)

        try store.trashNote(id: kept.id)
        try store.emptyTrash()
        XCTAssertNil(try store.note(id: kept.id))
    }

    func testDuplicateCopiesTagsAndImages() throws {
        let store = try makeStore()
        let note = try store.createNote(title: "Trip")
        let imageID = try store.addAttachment(noteID: note.id, mimeType: "image/png", data: fakePNG())
        try store.updateNote(id: note.id, body: "See \(AttachmentReference.token(id: imageID))")
        try store.setTags(["travel"], forNote: note.id)
        try store.setPinned(true, noteID: note.id)

        let copy = try store.duplicateNote(id: note.id)
        XCTAssertEqual(copy.title, "Trip copy")
        XCTAssertFalse(copy.pinned)
        XCTAssertEqual(try store.tags(forNote: copy.id).map(\.name), ["travel"])

        let copiedRefs = AttachmentReference.findAll(in: copy.body)
        XCTAssertEqual(copiedRefs.count, 1)
        XCTAssertNotEqual(copiedRefs[0].id, imageID)
        XCTAssertEqual(try store.attachment(id: copiedRefs[0].id)?.data, fakePNG())

        try store.deleteNotePermanently(id: note.id)
        XCTAssertNotNil(try store.attachment(id: copiedRefs[0].id), "the copy keeps its own image")
        XCTAssertNil(try store.attachment(id: imageID), "images are deleted with their note")
    }

    // MARK: Folders

    func testFoldersNestOnlyOneLevel() throws {
        let store = try makeStore()
        let work = try store.createFolder(name: " Work ")
        XCTAssertEqual(work.name, "Work")
        let projects = try store.createFolder(name: "Projects", parentID: work.id)
        XCTAssertThrowsError(try store.createFolder(name: "Too deep", parentID: projects.id)) { error in
            XCTAssertEqual(error as? StoreError, .nestingTooDeep)
        }
        XCTAssertThrowsError(try store.createFolder(name: "   ")) { error in
            XCTAssertEqual(error as? StoreError, .invalidName)
        }
        XCTAssertEqual(try store.folders().map(\.name), ["Work", "Projects"])
    }

    func testFolderScopeIncludesSubfoldersAndDeletingKeepsNotes() throws {
        let store = try makeStore()
        let work = try store.createFolder(name: "Work")
        let sub = try store.createFolder(name: "Sub", parentID: work.id)
        let top = try store.createNote(folderID: work.id, title: "top")
        let nested = try store.createNote(folderID: sub.id, title: "nested")
        let loose = try store.createNote(title: "loose")

        XCTAssertEqual(Set(try store.notes(in: .folder(work.id), sortedBy: .title).map(\.id)), [top.id, nested.id])
        XCTAssertEqual(try store.notes(in: .folder(sub.id), sortedBy: .title).map(\.id), [nested.id])

        try store.renameFolder(id: work.id, to: "Job")
        XCTAssertEqual(try store.folders().first?.name, "Job")

        try store.deleteFolder(id: work.id)
        XCTAssertTrue(try store.folders().isEmpty)
        XCTAssertEqual(try store.noteCount(in: .all), 3)
        XCTAssertNil(try store.note(id: nested.id)?.folderID)
        _ = loose
    }

    // MARK: Tags

    func testTagsAreCaseInsensitiveAndCleanedUp() throws {
        let store = try makeStore()
        let a = try store.createNote(title: "a")
        let b = try store.createNote(title: "b")
        try store.setTags(["#Work", "work", " ideas ", ""], forNote: a.id)
        try store.setTags(["WORK"], forNote: b.id)

        let tags = try store.tags()
        XCTAssertEqual(tags.map(\.tag.name), ["ideas", "Work"])
        XCTAssertEqual(tags.map(\.noteCount), [1, 2])

        let workID = try XCTUnwrap(tags.last?.tag.id)
        XCTAssertEqual(Set(try store.notes(in: .tag(workID), sortedBy: .title).map(\.id)), [a.id, b.id])

        try store.setTags([], forNote: a.id)
        XCTAssertEqual(try store.tags().map(\.tag.name), ["Work"])
        XCTAssertEqual(TagName.parse("one, #two,, One"), ["one", "two"])
    }

    // MARK: Attachments

    func testOrphanedImagesArePruned() throws {
        let store = try makeStore()
        let note = try store.createNote(title: "n")
        let used = try store.addAttachment(noteID: note.id, mimeType: "image/png", data: fakePNG())
        let unused = try store.addAttachment(noteID: note.id, mimeType: "image/jpeg", data: Data([0xFF, 0xD8, 0xFF]))
        try store.updateNote(id: note.id, body: AttachmentReference.token(id: used).lowercased())

        XCTAssertEqual(try store.attachmentInfos(forNote: note.id).count, 2)
        XCTAssertEqual(try store.pruneOrphanAttachments(), 1)
        XCTAssertNotNil(try store.attachment(id: used))
        XCTAssertNil(try store.attachment(id: unused))
    }
}

final class SearchTests: TemporaryDirectoryTestCase {
    func testIndexFollowsInsertUpdateAndDelete() throws {
        let store = try makeStore()
        let note = try store.createNote(title: "Groceries", body: "buy quinoa and limes")
        XCTAssertEqual(try store.search("quinoa").map(\.id), [note.id])
        XCTAssertEqual(try store.search("groceries").map(\.id), [note.id])

        try store.updateNote(id: note.id, body: "buy lentils")
        XCTAssertTrue(try store.search("quinoa").isEmpty, "old words must leave the index")
        XCTAssertEqual(try store.search("lentils").map(\.id), [note.id])

        try store.updateNote(id: note.id, title: "Shopping")
        XCTAssertTrue(try store.search("groceries").isEmpty)
        XCTAssertEqual(try store.search("shopping").map(\.id), [note.id])

        try store.deleteNotePermanently(id: note.id)
        XCTAssertTrue(try store.search("lentils").isEmpty)
        let integrity = try store.pool.write { db in
            try db.execute(sql: "INSERT INTO note_fts(note_fts, rank) VALUES ('integrity-check', 1)")
            return true
        }
        XCTAssertTrue(integrity)
    }

    func testPrefixMatchingAllWordsRequiredAndAccents() throws {
        let store = try makeStore()
        let cafe = try store.createNote(title: "Café list", body: "espresso machine notes")
        _ = try store.createNote(title: "Other", body: "espresso only")

        XCTAssertEqual(try store.search("esp").count, 2, "typing narrows by prefix")
        XCTAssertEqual(try store.search("espresso mach").map(\.id), [cafe.id])
        XCTAssertEqual(try store.search("cafe").map(\.id), [cafe.id], "accents are ignored")
        XCTAssertTrue(try store.search("   ").isEmpty)
    }

    func testTrashedNotesAreNotFoundAndScopeIsRespected() throws {
        let store = try makeStore()
        let folder = try store.createFolder(name: "F")
        let inside = try store.createNote(folderID: folder.id, title: "zebra inside")
        let outside = try store.createNote(title: "zebra outside")
        let trashed = try store.createNote(title: "zebra trashed")
        try store.trashNote(id: trashed.id)

        XCTAssertEqual(Set(try store.search("zebra").map(\.id)), [inside.id, outside.id])
        XCTAssertEqual(try store.search("zebra", in: .folder(folder.id)).map(\.id), [inside.id])

        try store.restoreNote(id: trashed.id)
        XCTAssertEqual(try store.search("zebra").count, 3)
    }

    func testQueriesWithOperatorsAndQuotesAreTreatedAsText() throws {
        let store = try makeStore()
        let note = try store.createNote(title: "C++ notes", body: "say \"hello\" AND goodbye (really)")
        for query in ["\"hello", "AND", "(really)", "NEAR(", "title:", "c++", "*", "-", "\"\""] {
            XCTAssertNoThrow(try store.search(query), "query \(query) must not be a syntax error")
        }
        XCTAssertEqual(try store.search("hello goodbye").map(\.id), [note.id])
    }

    func testMatchesAreMarkedForHighlighting() throws {
        let store = try makeStore()
        _ = try store.createNote(title: "Walrus facts", body: "The walrus has tusks. " + String(repeating: "filler ", count: 80))
        let hit = try XCTUnwrap(store.search("walrus").first)

        let title = SearchMarkup.parse(hit.markedTitle)
        XCTAssertEqual(title.text, "Walrus facts")
        XCTAssertEqual(title.matches.map { String(title.text[$0]) }, ["Walrus"])

        let snippet = SearchMarkup.parse(hit.markedSnippet)
        XCTAssertEqual(snippet.matches.map { String(snippet.text[$0]) }, ["walrus"])
        XCTAssertFalse(snippet.text.contains(SearchMarkup.open))
        XCTAssertEqual(SearchQuery.terms(in: "  Wal  \"rus\" "), ["wal", "rus"])
    }
}

/// These only mean something against SQLCipher. On a build without it,
/// `Store.open` refuses to run at all, so they are skipped rather than passed.
final class EncryptionAtRestTests: TemporaryDirectoryTestCase {
    private let secret = "xylophonequokka"

    func testDatabaseFileIsNotRecognisableAndHoldsNoPlaintext() throws {
        let store = try makeStore()
        try XCTSkipIf(try store.cipherVersion() == nil, "SQLite without encryption")

        let note = try store.createNote(title: "Title \(secret)", body: "Body \(secret) " + String(repeating: secret, count: 200))
        try store.setTags([secret], forNote: note.id)
        _ = try store.createFolder(name: secret)
        _ = try store.addAttachment(noteID: note.id, mimeType: "image/png", data: fakePNG(marker: secret))
        XCTAssertEqual(try store.search(secret).count, 1)

        // Check while the write-ahead log still exists, then after closing.
        for phase in ["open", "closed"] {
            if phase == "closed" { store.close() }
            let bytes = try allBytes(under: directory)
            XCTAssertFalse(bytes.isEmpty)
            XCTAssertNil(bytes.range(of: Data(secret.utf8)), "plaintext found on disk while \(phase)")
            XCTAssertNil(bytes.range(of: Data("SQLite format 3".utf8)), "file is recognisable as SQLite while \(phase)")
            XCTAssertNil(bytes.range(of: Data("CREATE TABLE".utf8)), "schema is readable while \(phase)")
        }
    }

    func testWrongKeyCannotOpen() throws {
        let store = try makeStore(key: .random(count: 32))
        try XCTSkipIf(try store.cipherVersion() == nil, "SQLite without encryption")
        try store.createNote(title: "x")
        store.close()
        XCTAssertThrowsError(try makeStore(key: .random(count: 32))) { error in
            XCTAssertEqual(error as? StoreError, .wrongKeyOrCorrupt)
        }
    }

    func testWipedKeyCannotOpenNewConnections() throws {
        let key = SecureBytes.random(count: 32)
        let store = try makeStore(key: key)
        store.close()
        key.wipe()
        XCTAssertThrowsError(try makeStore(key: key))
    }
}
