import Foundation
import GRDB

public struct Note: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var folderID: UUID?
    public var title: String
    /// Markdown text.
    public var body: String
    public var pinned: Bool
    public var createdAt: Date
    public var updatedAt: Date
    /// Set while the note is in the Trash.
    public var deletedAt: Date?

    public init(
        id: UUID = UUID(),
        folderID: UUID? = nil,
        title: String = "",
        body: String = "",
        pinned: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.folderID = folderID
        self.title = title
        self.body = body
        self.pinned = pinned
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }
}

/// A note without its full body, for the note list.
public struct NoteSummary: Identifiable, Hashable, Sendable {
    public var id: UUID
    public var folderID: UUID?
    public var title: String
    /// The first few hundred characters of the body.
    public var preview: String
    public var pinned: Bool
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?
}

public struct Folder: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    /// Nil for a top-level folder. Only one level of nesting is allowed.
    public var parentID: UUID?
    public var name: String
    public var sortOrder: Int

    public init(id: UUID = UUID(), parentID: UUID? = nil, name: String, sortOrder: Int = 0) {
        self.id = id
        self.parentID = parentID
        self.name = name
        self.sortOrder = sortOrder
    }
}

public struct Tag: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var name: String

    public init(id: UUID = UUID(), name: String) {
        self.id = id
        self.name = name
    }
}

public struct TagCount: Identifiable, Hashable, Sendable {
    public var tag: Tag
    /// Notes with this tag that are not in the Trash.
    public var noteCount: Int
    public var id: UUID { tag.id }
}

public struct NoteTagLink: Hashable, Codable, Sendable {
    public var noteID: UUID
    public var tagID: UUID

    public init(noteID: UUID, tagID: UUID) {
        self.noteID = noteID
        self.tagID = tagID
    }
}

/// An image stored encrypted inside the database.
public struct Attachment: Identifiable, Hashable, Sendable {
    public var id: UUID
    public var noteID: UUID
    public var mimeType: String
    public var data: Data
    public var createdAt: Date

    public init(id: UUID = UUID(), noteID: UUID, mimeType: String, data: Data, createdAt: Date = Date()) {
        self.id = id
        self.noteID = noteID
        self.mimeType = mimeType
        self.data = data
        self.createdAt = createdAt
    }
}

public struct AttachmentInfo: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var noteID: UUID
    public var mimeType: String
    public var createdAt: Date
    public var byteCount: Int
}

/// Which notes the list shows.
public enum NoteScope: Hashable, Sendable {
    case all
    /// A folder, including the notes in its subfolders.
    case folder(UUID)
    case tag(UUID)
    case trash
}

public enum NoteSort: String, CaseIterable, Sendable {
    case modified
    case created
    case title
}

public struct SearchHit: Identifiable, Hashable, Sendable {
    public var note: NoteSummary
    /// The title with matches wrapped in `SearchMarkup` markers.
    public var markedTitle: String
    /// A short body excerpt with matches wrapped in `SearchMarkup` markers.
    public var markedSnippet: String
    public var id: UUID { note.id }
}

public enum StoreError: Error, Equatable, Sendable {
    /// The file is not a database this key can open.
    case wrongKeyOrCorrupt
    /// The SQLite library in this build has no encryption. Refusing to store
    /// anything.
    case encryptionUnavailable
    case notFound
    /// Folders can only be nested one level deep.
    case nestingTooDeep
    case invalidName
    /// The database was written by a newer version of the app.
    case databaseTooNew
}

// MARK: - Row decoding

func uuid(_ row: Row, _ column: String) throws -> UUID {
    let text: String = row[column]
    guard let value = UUID(uuidString: text) else { throw StoreError.wrongKeyOrCorrupt }
    return value
}

func optionalUUID(_ row: Row, _ column: String) throws -> UUID? {
    guard let text = row[column] as String? else { return nil }
    guard let value = UUID(uuidString: text) else { throw StoreError.wrongKeyOrCorrupt }
    return value
}

func date(_ row: Row, _ column: String) -> Date {
    Date(timeIntervalSince1970: row[column] as Double)
}

func optionalDate(_ row: Row, _ column: String) -> Date? {
    (row[column] as Double?).map(Date.init(timeIntervalSince1970:))
}

extension Note {
    init(row: Row) throws {
        self.init(
            id: try uuid(row, "id"),
            folderID: try optionalUUID(row, "folder_id"),
            title: row["title"],
            body: row["body"],
            pinned: row["pinned"],
            createdAt: date(row, "created_at"),
            updatedAt: date(row, "updated_at"),
            deletedAt: optionalDate(row, "deleted_at")
        )
    }
}

extension NoteSummary {
    static let columns = """
        note.id, note.folder_id, note.title, substr(note.body, 1, 300) AS preview, \
        note.pinned, note.created_at, note.updated_at, note.deleted_at
        """

    init(row: Row) throws {
        self.init(
            id: try uuid(row, "id"),
            folderID: try optionalUUID(row, "folder_id"),
            title: row["title"],
            preview: row["preview"],
            pinned: row["pinned"],
            createdAt: date(row, "created_at"),
            updatedAt: date(row, "updated_at"),
            deletedAt: optionalDate(row, "deleted_at")
        )
    }
}

extension Folder {
    init(row: Row) throws {
        self.init(
            id: try uuid(row, "id"),
            parentID: try optionalUUID(row, "parent_id"),
            name: row["name"],
            sortOrder: row["sort_order"]
        )
    }
}

extension Tag {
    init(row: Row) throws {
        self.init(id: try uuid(row, "id"), name: row["name"])
    }
}
