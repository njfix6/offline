import Foundation
import GRDB

/// The encrypted notes database.
///
/// A `Store` only exists while the vault is unlocked. All content, including
/// the full-text index and image attachments, lives inside the one SQLCipher
/// file; nothing is written beside it in plaintext.
public final class Store: Sendable {
    /// Days a trashed note is kept before it is removed for good.
    public static let trashRetentionDays = 30
    static let currentSchemaVersion = 1

    let pool: DatabasePool

    private init(pool: DatabasePool) {
        self.pool = pool
    }

    /// Opens (creating if needed) the database at `url` with `key`.
    ///
    /// The key object is kept by the connection pool so it can key additional
    /// reader connections; wiping it makes any further connection fail.
    public static func open(at url: URL, key: SecureBytes) throws -> Store {
        var configuration = Configuration()
        configuration.label = "offline"
        configuration.prepareDatabase { db in
            try Store.prepare(db, key: key)
        }

        let pool: DatabasePool
        do {
            pool = try DatabasePool(path: url.path, configuration: configuration)
            // The first real read is what fails when the key is wrong.
            try pool.read { db in
                _ = try Int.fetchOne(db, sql: "SELECT count(*) FROM sqlite_master")
            }
        } catch let error as DatabaseError where error.resultCode == .SQLITE_NOTADB {
            throw StoreError.wrongKeyOrCorrupt
        }

        let store = Store(pool: pool)
        do {
            try store.migrate()
        } catch {
            try? pool.close()
            throw error
        }
        return store
    }

    /// Folds the write-ahead log into the main file and closes every
    /// connection.
    public func close() {
        _ = try? pool.writeWithoutTransaction { db in
            try db.checkpoint(.truncate)
        }
        try? pool.close()
    }

    // MARK: - Migrations

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1") { db in
            try db.execute(sql: """
                CREATE TABLE meta (
                    id INTEGER PRIMARY KEY CHECK (id = 1),
                    schema_version INTEGER NOT NULL,
                    created_at DOUBLE NOT NULL
                );

                CREATE TABLE folder (
                    id TEXT PRIMARY KEY NOT NULL,
                    parent_id TEXT REFERENCES folder(id) ON DELETE CASCADE,
                    name TEXT NOT NULL,
                    sort_order INTEGER NOT NULL DEFAULT 0
                );
                CREATE INDEX folder_parent ON folder(parent_id);

                -- `seq` is a stable integer key for the full-text index;
                -- `id` is the note's public identity.
                CREATE TABLE note (
                    seq INTEGER PRIMARY KEY AUTOINCREMENT,
                    id TEXT NOT NULL UNIQUE,
                    folder_id TEXT REFERENCES folder(id) ON DELETE SET NULL,
                    title TEXT NOT NULL DEFAULT '',
                    body TEXT NOT NULL DEFAULT '',
                    pinned INTEGER NOT NULL DEFAULT 0,
                    created_at DOUBLE NOT NULL,
                    updated_at DOUBLE NOT NULL,
                    deleted_at DOUBLE
                );
                CREATE INDEX note_folder ON note(folder_id);
                CREATE INDEX note_deleted ON note(deleted_at);

                CREATE TABLE tag (
                    id TEXT PRIMARY KEY NOT NULL,
                    name TEXT NOT NULL UNIQUE COLLATE NOCASE
                );

                CREATE TABLE note_tag (
                    note_id TEXT NOT NULL REFERENCES note(id) ON DELETE CASCADE,
                    tag_id TEXT NOT NULL REFERENCES tag(id) ON DELETE CASCADE,
                    PRIMARY KEY (note_id, tag_id)
                ) WITHOUT ROWID;
                CREATE INDEX note_tag_tag ON note_tag(tag_id);

                CREATE TABLE attachment (
                    id TEXT PRIMARY KEY NOT NULL,
                    note_id TEXT NOT NULL REFERENCES note(id) ON DELETE CASCADE,
                    mime_type TEXT NOT NULL,
                    data BLOB NOT NULL,
                    created_at DOUBLE NOT NULL
                );
                CREATE INDEX attachment_note ON attachment(note_id);

                -- Full-text index over titles and bodies. It stores no copy
                -- of the text (external content) and lives in the same
                -- encrypted file.
                CREATE VIRTUAL TABLE note_fts USING fts5(
                    title,
                    body,
                    content = 'note',
                    content_rowid = 'seq',
                    tokenize = 'unicode61 remove_diacritics 2',
                    prefix = '2 3'
                );

                CREATE TRIGGER note_fts_insert AFTER INSERT ON note BEGIN
                    INSERT INTO note_fts(rowid, title, body)
                    VALUES (new.seq, new.title, new.body);
                END;

                CREATE TRIGGER note_fts_delete AFTER DELETE ON note BEGIN
                    INSERT INTO note_fts(note_fts, rowid, title, body)
                    VALUES ('delete', old.seq, old.title, old.body);
                END;

                CREATE TRIGGER note_fts_update AFTER UPDATE OF title, body ON note BEGIN
                    INSERT INTO note_fts(note_fts, rowid, title, body)
                    VALUES ('delete', old.seq, old.title, old.body);
                    INSERT INTO note_fts(rowid, title, body)
                    VALUES (new.seq, new.title, new.body);
                END;
                """)
            try db.execute(
                sql: "INSERT INTO meta (id, schema_version, created_at) VALUES (1, 1, ?)",
                arguments: [Date().timeIntervalSince1970]
            )
        }

        // Later migrations go here. Each one must end by setting
        // meta.schema_version to its own number.

        return migrator
    }

    private func migrate() throws {
        let migrator = Self.migrator
        let applied = try pool.read { db in try migrator.appliedIdentifiers(db) }
        let known = Set(migrator.migrations)
        guard applied.isSubset(of: known) else { throw StoreError.databaseTooNew }
        try migrator.migrate(pool)
    }

    public func schemaVersion() throws -> Int {
        try pool.read { db in
            try Int.fetchOne(db, sql: "SELECT schema_version FROM meta WHERE id = 1") ?? 0
        }
    }

    public func createdAt() throws -> Date? {
        try pool.read { db in
            try Double.fetchOne(db, sql: "SELECT created_at FROM meta WHERE id = 1")
                .map(Date.init(timeIntervalSince1970:))
        }
    }
}

extension Store {
    /// The SQLCipher version in use, or nil if this SQLite cannot encrypt
    /// (in which case `open` would already have refused).
    public func cipherVersion() throws -> String? {
        try pool.read { db in
            try String.fetchOne(db, sql: "PRAGMA cipher_version")
        }
    }
}
