import Foundation
import GRDB

extension Store {
    // MARK: - Reading

    public func note(id: UUID) throws -> Note? {
        try pool.read { db in try Self.fetchNote(db, id: id) }
    }

    static func fetchNote(_ db: Database, id: UUID) throws -> Note? {
        try Row.fetchOne(db, sql: "SELECT * FROM note WHERE id = ?", arguments: [id.uuidString])
            .map(Note.init(row:))
    }

    /// Notes for the list. Pinned notes come first (except in the Trash, which
    /// is ordered by when each note was deleted).
    public func notes(in scope: NoteScope, sortedBy sort: NoteSort) throws -> [NoteSummary] {
        try pool.read { db in
            let filter = Self.filter(for: scope)
            let order: String
            if scope == .trash {
                order = "note.deleted_at DESC"
            } else {
                switch sort {
                case .modified: order = "note.pinned DESC, note.updated_at DESC"
                case .created: order = "note.pinned DESC, note.created_at DESC"
                case .title: order = "note.pinned DESC, note.title COLLATE NOCASE ASC, note.updated_at DESC"
                }
            }
            let sql = "SELECT \(NoteSummary.columns) FROM note WHERE \(filter.sql) ORDER BY \(order)"
            return try Row.fetchAll(db, sql: sql, arguments: filter.arguments).map(NoteSummary.init(row:))
        }
    }

    public func noteCount(in scope: NoteScope) throws -> Int {
        try pool.read { db in
            let filter = Self.filter(for: scope)
            return try Int.fetchOne(
                db,
                sql: "SELECT count(*) FROM note WHERE \(filter.sql)",
                arguments: filter.arguments
            ) ?? 0
        }
    }

    static func filter(for scope: NoteScope) -> (sql: String, arguments: StatementArguments) {
        switch scope {
        case .all:
            return ("note.deleted_at IS NULL", [])
        case .folder(let id):
            return (
                """
                note.deleted_at IS NULL AND note.folder_id IN \
                (SELECT id FROM folder WHERE id = ? OR parent_id = ?)
                """,
                [id.uuidString, id.uuidString]
            )
        case .tag(let id):
            return (
                """
                note.deleted_at IS NULL AND note.id IN \
                (SELECT note_id FROM note_tag WHERE tag_id = ?)
                """,
                [id.uuidString]
            )
        case .trash:
            return ("note.deleted_at IS NOT NULL", [])
        }
    }

    // MARK: - Writing

    @discardableResult
    public func createNote(
        folderID: UUID? = nil,
        title: String = "",
        body: String = "",
        now: Date = Date()
    ) throws -> Note {
        let note = Note(folderID: folderID, title: title, body: body, createdAt: now, updatedAt: now)
        try pool.write { db in try Self.insert(note, in: db) }
        return note
    }

    static func insert(_ note: Note, in db: Database) throws {
        try db.execute(
            sql: """
                INSERT INTO note (id, folder_id, title, body, pinned, created_at, updated_at, deleted_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                note.id.uuidString,
                note.folderID?.uuidString,
                note.title,
                note.body,
                note.pinned,
                note.createdAt.timeIntervalSince1970,
                note.updatedAt.timeIntervalSince1970,
                note.deletedAt?.timeIntervalSince1970,
            ]
        )
    }

    /// Saves a note's text. Passing nil leaves that field alone. The modified
    /// date only moves when something actually changed. Returns whether
    /// anything was written.
    @discardableResult
    public func updateNote(id: UUID, title: String? = nil, body: String? = nil, now: Date = Date()) throws -> Bool {
        try pool.write { db in
            guard let current = try Self.fetchNote(db, id: id) else { throw StoreError.notFound }
            let newTitle = title ?? current.title
            let newBody = body ?? current.body
            guard newTitle != current.title || newBody != current.body else { return false }
            try db.execute(
                sql: "UPDATE note SET title = ?, body = ?, updated_at = ? WHERE id = ?",
                arguments: [newTitle, newBody, now.timeIntervalSince1970, id.uuidString]
            )
            return true
        }
    }

    public func setPinned(_ pinned: Bool, noteID: UUID) throws {
        try pool.write { db in
            try db.execute(
                sql: "UPDATE note SET pinned = ? WHERE id = ?",
                arguments: [pinned, noteID.uuidString]
            )
        }
    }

    public func moveNote(id: UUID, toFolder folderID: UUID?) throws {
        try pool.write { db in
            try db.execute(
                sql: "UPDATE note SET folder_id = ? WHERE id = ?",
                arguments: [folderID?.uuidString, id.uuidString]
            )
        }
    }

    /// Copies a note with its tags and images. The copy is unpinned and sits
    /// in the same folder.
    @discardableResult
    public func duplicateNote(id: UUID, now: Date = Date()) throws -> Note {
        try pool.write { db in
            guard let original = try Self.fetchNote(db, id: id) else { throw StoreError.notFound }
            var copy = Note(
                folderID: original.folderID,
                title: original.title.isEmpty ? "" : original.title + " copy",
                body: original.body,
                createdAt: now,
                updatedAt: now
            )

            // Each image gets its own row for the copy, so deleting one note
            // never breaks the other.
            let attachmentIDs = try String.fetchAll(
                db,
                sql: "SELECT id FROM attachment WHERE note_id = ?",
                arguments: [id.uuidString]
            )
            var replacements: [(old: String, new: String)] = []
            for oldID in attachmentIDs {
                replacements.append((oldID, UUID().uuidString))
            }
            for pair in replacements {
                copy.body = copy.body.replacingOccurrences(
                    of: "attachment:\(pair.old)",
                    with: "attachment:\(pair.new)",
                    options: .caseInsensitive
                )
            }
            try Self.insert(copy, in: db)
            for pair in replacements {
                try db.execute(
                    sql: """
                        INSERT INTO attachment (id, note_id, mime_type, data, created_at)
                        SELECT ?, ?, mime_type, data, ? FROM attachment WHERE id = ?
                        """,
                    arguments: [pair.new, copy.id.uuidString, now.timeIntervalSince1970, pair.old]
                )
            }
            try db.execute(
                sql: "INSERT INTO note_tag (note_id, tag_id) SELECT ?, tag_id FROM note_tag WHERE note_id = ?",
                arguments: [copy.id.uuidString, id.uuidString]
            )
            return copy
        }
    }

    // MARK: - Trash

    public func trashNote(id: UUID, now: Date = Date()) throws {
        try pool.write { db in
            try db.execute(
                sql: "UPDATE note SET deleted_at = ?, pinned = 0 WHERE id = ? AND deleted_at IS NULL",
                arguments: [now.timeIntervalSince1970, id.uuidString]
            )
        }
    }

    public func restoreNote(id: UUID) throws {
        try pool.write { db in
            try db.execute(
                sql: "UPDATE note SET deleted_at = NULL WHERE id = ?",
                arguments: [id.uuidString]
            )
        }
    }

    /// Removes a note, its images and its tag links for good.
    public func deleteNotePermanently(id: UUID) throws {
        try pool.write { db in
            try db.execute(sql: "DELETE FROM note WHERE id = ?", arguments: [id.uuidString])
            try Self.deleteUnusedTags(db)
        }
    }

    public func emptyTrash() throws {
        try pool.write { db in
            try db.execute(sql: "DELETE FROM note WHERE deleted_at IS NOT NULL")
            try Self.deleteUnusedTags(db)
        }
    }

    /// Removes notes that have been in the Trash longer than the retention
    /// period. Returns how many were removed.
    @discardableResult
    public func purgeExpiredTrash(now: Date = Date()) throws -> Int {
        let cutoff = now.timeIntervalSince1970 - Double(Self.trashRetentionDays) * 86_400
        return try pool.write { db in
            try db.execute(
                sql: "DELETE FROM note WHERE deleted_at IS NOT NULL AND deleted_at < ?",
                arguments: [cutoff]
            )
            let removed = db.changesCount
            if removed > 0 { try Self.deleteUnusedTags(db) }
            return removed
        }
    }

    // MARK: - Search

    /// Full-text search over titles and bodies, best match first. Notes in the
    /// Trash are never returned. Every word must match; the last characters
    /// typed match as a prefix, so results narrow while typing.
    public func search(_ text: String, in scope: NoteScope = .all, limit: Int = 200) throws -> [SearchHit] {
        guard let match = SearchQuery.ftsPattern(for: text) else { return [] }
        let effectiveScope: NoteScope = scope == .trash ? .all : scope
        return try pool.read { db in
            let filter = Self.filter(for: effectiveScope)
            var arguments: StatementArguments = [
                SearchMarkup.open, SearchMarkup.close,
                SearchMarkup.open, SearchMarkup.close,
                match,
            ]
            arguments += filter.arguments
            arguments += [limit]
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT \(NoteSummary.columns),
                           highlight(note_fts, 0, ?, ?) AS marked_title,
                           snippet(note_fts, 1, ?, ?, '…', 14) AS marked_snippet
                    FROM note_fts
                    JOIN note ON note.seq = note_fts.rowid
                    WHERE note_fts MATCH ? AND \(filter.sql)
                    ORDER BY bm25(note_fts, 8.0, 1.0)
                    LIMIT ?
                    """,
                arguments: arguments
            )
            return try rows.map { row in
                SearchHit(
                    note: try NoteSummary(row: row),
                    markedTitle: row["marked_title"],
                    markedSnippet: row["marked_snippet"]
                )
            }
        }
    }
}

/// Turns what the user typed into a safe FTS5 query.
public enum SearchQuery {
    /// The words of a query, lowercased, for highlighting matches in text.
    public static func terms(in text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace })
            .map { $0.replacingOccurrences(of: "\"", with: "").lowercased() }
            .filter { !$0.isEmpty }
    }

    /// Each word becomes a quoted prefix term (`"word"*`), so FTS5 operators
    /// and punctuation in the input are treated as plain text.
    static func ftsPattern(for text: String) -> String? {
        let words = terms(in: text)
        guard !words.isEmpty else { return nil }
        return words.map { "\"\($0)\"*" }.joined(separator: " ")
    }
}

/// Markers the store puts around matched text in search results.
public enum SearchMarkup {
    public static let open = "\u{2}"
    public static let close = "\u{3}"

    /// Splits marked text into plain text and the matched ranges within it.
    public static func parse(_ marked: String) -> (text: String, matches: [Range<String.Index>]) {
        var text = ""
        var matches: [Range<String.Index>] = []
        var pendingStart: String.Index?
        for character in marked {
            if String(character) == open {
                pendingStart = text.endIndex
            } else if String(character) == close {
                if let start = pendingStart, start < text.endIndex {
                    matches.append(start..<text.endIndex)
                }
                pendingStart = nil
            } else {
                text.append(character)
            }
        }
        return (text, matches)
    }
}
