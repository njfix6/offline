import Foundation
import GRDB

/// Everything in the vault except image bytes. Used by encrypted backups.
public struct VaultSnapshot: Codable, Equatable, Sendable {
    public var folders: [Folder]
    public var notes: [Note]
    public var tags: [Tag]
    public var noteTags: [NoteTagLink]
    public var attachments: [AttachmentInfo]

    public init(
        folders: [Folder] = [],
        notes: [Note] = [],
        tags: [Tag] = [],
        noteTags: [NoteTagLink] = [],
        attachments: [AttachmentInfo] = []
    ) {
        self.folders = folders
        self.notes = notes
        self.tags = tags
        self.noteTags = noteTags
        self.attachments = attachments
    }
}

extension Store {
    /// Reads a consistent copy of the whole vault. `body` is called once with
    /// the snapshot, then `attachment` once per image, all from the same
    /// database snapshot.
    public func readSnapshot(
        _ body: (VaultSnapshot) throws -> Void,
        attachment: (Attachment) throws -> Void
    ) throws {
        try pool.read { db in
            let snapshot = VaultSnapshot(
                folders: try Self.fetchFolders(db),
                notes: try Row.fetchAll(db, sql: "SELECT * FROM note ORDER BY seq").map(Note.init(row:)),
                tags: try Row.fetchAll(db, sql: "SELECT * FROM tag ORDER BY name COLLATE NOCASE").map(Tag.init(row:)),
                noteTags: try Row.fetchAll(db, sql: "SELECT note_id, tag_id FROM note_tag ORDER BY note_id, tag_id")
                    .map { NoteTagLink(noteID: try uuid($0, "note_id"), tagID: try uuid($0, "tag_id")) },
                attachments: try Self.fetchAttachmentInfos(db)
            )
            try body(snapshot)
            for info in snapshot.attachments {
                guard let row = try Row.fetchOne(
                    db,
                    sql: "SELECT * FROM attachment WHERE id = ?",
                    arguments: [info.id.uuidString]
                ) else { continue }
                try attachment(try Self.attachment(from: row))
            }
        }
    }

    /// Replaces the whole vault with a snapshot, in one transaction. `fill`
    /// receives an `insert` function to call once per image. If anything
    /// throws, nothing changes.
    public func replaceAll(
        with snapshot: VaultSnapshot,
        fill: (_ insert: (Attachment) throws -> Void) throws -> Void
    ) throws {
        try pool.write { db in
            try db.execute(sql: """
                DELETE FROM note_tag;
                DELETE FROM attachment;
                DELETE FROM note;
                DELETE FROM tag;
                DELETE FROM folder;
                """)
            // Parents before children.
            for folder in snapshot.folders where folder.parentID == nil {
                try Self.insert(folder, in: db)
            }
            for folder in snapshot.folders where folder.parentID != nil {
                try Self.insert(folder, in: db)
            }
            for note in snapshot.notes {
                try Self.insert(note, in: db)
            }
            for tag in snapshot.tags {
                try db.execute(
                    sql: "INSERT INTO tag (id, name) VALUES (?, ?)",
                    arguments: [tag.id.uuidString, tag.name]
                )
            }
            for link in snapshot.noteTags {
                try db.execute(
                    sql: "INSERT INTO note_tag (note_id, tag_id) VALUES (?, ?)",
                    arguments: [link.noteID.uuidString, link.tagID.uuidString]
                )
            }
            try fill { attachment in
                try Self.insert(attachment, in: db)
            }
        }
    }

    /// Adds a note with explicit dates, for imports.
    @discardableResult
    public func importNote(
        folderID: UUID?,
        title: String,
        body: String,
        tags: [String],
        createdAt: Date,
        updatedAt: Date
    ) throws -> Note {
        let note = Note(folderID: folderID, title: title, body: body, createdAt: createdAt, updatedAt: updatedAt)
        try pool.write { db in
            try Self.insert(note, in: db)
            for name in TagName.normalized(tags) {
                let tagID = try Self.findOrCreateTag(named: name, in: db)
                try db.execute(
                    sql: "INSERT OR IGNORE INTO note_tag (note_id, tag_id) VALUES (?, ?)",
                    arguments: [note.id.uuidString, tagID]
                )
            }
        }
        return note
    }

    /// Finds a folder by name under `parentID`, creating it if needed.
    public func folder(named name: String, parentID: UUID?) throws -> Folder {
        let cleanName = try Self.cleanName(name)
        let existing = try pool.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT * FROM folder WHERE name = ? COLLATE NOCASE AND parent_id IS ?",
                arguments: [cleanName, parentID?.uuidString]
            ).map(Folder.init(row:))
        }
        if let existing { return existing }
        return try createFolder(name: cleanName, parentID: parentID)
    }
}
