import Foundation
import GRDB

extension Store {
    // MARK: - Folders

    /// All folders, top level first, each level ordered by `sortOrder` then
    /// name.
    public func folders() throws -> [Folder] {
        try pool.read { db in try Self.fetchFolders(db) }
    }

    static func fetchFolders(_ db: Database) throws -> [Folder] {
        try Row.fetchAll(
            db,
            sql: """
                SELECT * FROM folder
                ORDER BY parent_id IS NOT NULL, sort_order, name COLLATE NOCASE
                """
        ).map(Folder.init(row:))
    }

    /// Creates a folder. A folder inside a folder is allowed; a third level is
    /// not (`StoreError.nestingTooDeep`).
    @discardableResult
    public func createFolder(name: String, parentID: UUID? = nil) throws -> Folder {
        let cleanName = try Self.cleanName(name)
        return try pool.write { db in
            if let parentID {
                guard let parent = try Row.fetchOne(
                    db,
                    sql: "SELECT parent_id FROM folder WHERE id = ?",
                    arguments: [parentID.uuidString]
                ) else { throw StoreError.notFound }
                guard (parent["parent_id"] as String?) == nil else { throw StoreError.nestingTooDeep }
            }
            let nextOrder = try Int.fetchOne(
                db,
                sql: "SELECT coalesce(max(sort_order), -1) + 1 FROM folder WHERE parent_id IS ?",
                arguments: [parentID?.uuidString]
            ) ?? 0
            let folder = Folder(parentID: parentID, name: cleanName, sortOrder: nextOrder)
            try Self.insert(folder, in: db)
            return folder
        }
    }

    static func insert(_ folder: Folder, in db: Database) throws {
        try db.execute(
            sql: "INSERT INTO folder (id, parent_id, name, sort_order) VALUES (?, ?, ?, ?)",
            arguments: [folder.id.uuidString, folder.parentID?.uuidString, folder.name, folder.sortOrder]
        )
    }

    public func renameFolder(id: UUID, to name: String) throws {
        let cleanName = try Self.cleanName(name)
        try pool.write { db in
            try db.execute(
                sql: "UPDATE folder SET name = ? WHERE id = ?",
                arguments: [cleanName, id.uuidString]
            )
        }
    }

    /// Deletes a folder and its subfolders. The notes inside are kept: they
    /// move out to "All Notes" with no folder.
    public func deleteFolder(id: UUID) throws {
        try pool.write { db in
            try db.execute(
                sql: """
                    UPDATE note SET folder_id = NULL
                    WHERE folder_id IN (SELECT id FROM folder WHERE id = ? OR parent_id = ?)
                    """,
                arguments: [id.uuidString, id.uuidString]
            )
            try db.execute(sql: "DELETE FROM folder WHERE id = ?", arguments: [id.uuidString])
        }
    }

    static func cleanName(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw StoreError.invalidName }
        return trimmed
    }

    // MARK: - Tags

    /// Every tag with the number of (non-trashed) notes using it.
    public func tags() throws -> [TagCount] {
        try pool.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT tag.id, tag.name,
                           (SELECT count(*) FROM note_tag
                            JOIN note ON note.id = note_tag.note_id
                            WHERE note_tag.tag_id = tag.id AND note.deleted_at IS NULL) AS note_count
                    FROM tag
                    ORDER BY tag.name COLLATE NOCASE
                    """
            ).map { row in
                TagCount(tag: try Tag(row: row), noteCount: row["note_count"])
            }
        }
    }

    public func tags(forNote noteID: UUID) throws -> [Tag] {
        try pool.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT tag.* FROM tag
                    JOIN note_tag ON note_tag.tag_id = tag.id
                    WHERE note_tag.note_id = ?
                    ORDER BY tag.name COLLATE NOCASE
                    """,
                arguments: [noteID.uuidString]
            ).map(Tag.init(row:))
        }
    }

    /// Replaces a note's tags with `names`. Tags are created as needed and
    /// tags no note uses any more are removed. Names are matched without
    /// regard to case.
    public func setTags(_ names: [String], forNote noteID: UUID) throws {
        let wanted = TagName.normalized(names)
        try pool.write { db in
            guard try Self.fetchNote(db, id: noteID) != nil else { throw StoreError.notFound }
            try db.execute(sql: "DELETE FROM note_tag WHERE note_id = ?", arguments: [noteID.uuidString])
            for name in wanted {
                let tagID = try Self.findOrCreateTag(named: name, in: db)
                try db.execute(
                    sql: "INSERT OR IGNORE INTO note_tag (note_id, tag_id) VALUES (?, ?)",
                    arguments: [noteID.uuidString, tagID]
                )
            }
            try Self.deleteUnusedTags(db)
        }
    }

    static func findOrCreateTag(named name: String, in db: Database) throws -> String {
        if let existing = try String.fetchOne(db, sql: "SELECT id FROM tag WHERE name = ?", arguments: [name]) {
            return existing
        }
        let id = UUID().uuidString
        try db.execute(sql: "INSERT INTO tag (id, name) VALUES (?, ?)", arguments: [id, name])
        return id
    }

    static func deleteUnusedTags(_ db: Database) throws {
        try db.execute(sql: "DELETE FROM tag WHERE id NOT IN (SELECT tag_id FROM note_tag)")
    }

    // MARK: - Attachments

    /// Stores an image inside the encrypted database and returns its id. The
    /// note's body refers to it as `![alt](attachment:<id>)`.
    @discardableResult
    public func addAttachment(noteID: UUID, mimeType: String, data: Data, now: Date = Date()) throws -> UUID {
        let attachment = Attachment(noteID: noteID, mimeType: mimeType, data: data, createdAt: now)
        try pool.write { db in try Self.insert(attachment, in: db) }
        return attachment.id
    }

    static func insert(_ attachment: Attachment, in db: Database) throws {
        try db.execute(
            sql: "INSERT INTO attachment (id, note_id, mime_type, data, created_at) VALUES (?, ?, ?, ?, ?)",
            arguments: [
                attachment.id.uuidString,
                attachment.noteID.uuidString,
                attachment.mimeType,
                attachment.data,
                attachment.createdAt.timeIntervalSince1970,
            ]
        )
    }

    public func attachment(id: UUID) throws -> Attachment? {
        try pool.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM attachment WHERE id = ?", arguments: [id.uuidString])
                .map(Self.attachment(from:))
        }
    }

    static func attachment(from row: Row) throws -> Attachment {
        Attachment(
            id: try uuid(row, "id"),
            noteID: try uuid(row, "note_id"),
            mimeType: row["mime_type"],
            data: row["data"],
            createdAt: date(row, "created_at")
        )
    }

    public func attachmentInfos(forNote noteID: UUID? = nil) throws -> [AttachmentInfo] {
        try pool.read { db in try Self.fetchAttachmentInfos(db, noteID: noteID) }
    }

    static func fetchAttachmentInfos(_ db: Database, noteID: UUID? = nil) throws -> [AttachmentInfo] {
        let rows: [Row]
        let columns = "id, note_id, mime_type, created_at, length(data) AS byte_count"
        if let noteID {
            rows = try Row.fetchAll(
                db,
                sql: "SELECT \(columns) FROM attachment WHERE note_id = ? ORDER BY created_at, id",
                arguments: [noteID.uuidString]
            )
        } else {
            rows = try Row.fetchAll(db, sql: "SELECT \(columns) FROM attachment ORDER BY created_at, id")
        }
        return try rows.map { row in
            AttachmentInfo(
                id: try uuid(row, "id"),
                noteID: try uuid(row, "note_id"),
                mimeType: row["mime_type"],
                createdAt: date(row, "created_at"),
                byteCount: row["byte_count"]
            )
        }
    }

    /// Removes images whose note no longer mentions them. Run at unlock, not
    /// while editing, so undo can still bring an image back during a session.
    @discardableResult
    public func pruneOrphanAttachments() throws -> Int {
        try pool.write { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT attachment.id AS id FROM attachment
                    JOIN note ON note.id = attachment.note_id
                    WHERE instr(lower(note.body), 'attachment:' || lower(attachment.id)) = 0
                    """
            )
            for row in rows {
                try db.execute(sql: "DELETE FROM attachment WHERE id = ?", arguments: [row["id"] as String])
            }
            return rows.count
        }
    }
}

public enum TagName {
    /// Trims, drops a leading `#`, removes empties and case-insensitive
    /// duplicates, keeping first-seen order.
    public static func normalized(_ names: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for raw in names {
            var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            while name.hasPrefix("#") { name.removeFirst() }
            name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            if seen.insert(name.lowercased()).inserted {
                result.append(name)
            }
        }
        return result
    }

    /// Splits a comma-separated field into tag names.
    public static func parse(_ field: String) -> [String] {
        normalized(field.split(separator: ",").map(String.init))
    }
}
