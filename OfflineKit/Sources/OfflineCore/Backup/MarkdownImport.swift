import Foundation

/// Imports Markdown and plain-text files, and folders of them.
public enum MarkdownImport {
    public struct Report: Equatable, Sendable {
        public var noteCount = 0
        public var imageCount = 0
        public var skippedCount = 0
    }

    static let textExtensions: Set<String> = ["md", "markdown", "mdown", "txt", "text"]
    /// Largest text file accepted as a note.
    static let maximumNoteByteCount = 10 * 1024 * 1024

    /// Imports each URL. A file becomes a note in `folderID`. A directory
    /// becomes a folder (and its subdirectories become subfolders; anything
    /// deeper is flattened into the second level, since folders nest once).
    public static func importItems(
        _ urls: [URL],
        into store: Store,
        folderID: UUID? = nil,
        now: Date = Date()
    ) throws -> Report {
        var report = Report()
        let fileManager = FileManager.default
        for url in urls {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                report.skippedCount += 1
                continue
            }
            if isDirectory.boolValue {
                try importDirectory(url, depth: 0, containerID: nil, into: store, now: now, report: &report)
            } else {
                try importFile(url, into: store, folderID: folderID, now: now, report: &report)
            }
        }
        return report
    }

    private static func importDirectory(
        _ directory: URL,
        depth: Int,
        containerID: UUID?,
        into store: Store,
        now: Date,
        report: inout Report
    ) throws {
        let children = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ).sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

        // The picked directory becomes a top-level folder and its direct
        // subdirectories become subfolders. Anything deeper lands in the
        // subfolder above it.
        var targetID = containerID
        if depth == 0 {
            targetID = try store.folder(named: directory.lastPathComponent, parentID: nil).id
        } else if depth == 1, let containerID, containsNotes(directory) {
            targetID = try store.folder(named: directory.lastPathComponent, parentID: containerID).id
        }

        for child in children {
            let isDirectory = (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDirectory {
                // An "attachments" directory only holds images for its notes.
                if child.lastPathComponent.lowercased() == "attachments" { continue }
                try importDirectory(
                    child,
                    depth: depth + 1,
                    containerID: targetID,
                    into: store,
                    now: now,
                    report: &report
                )
            } else {
                try importFile(child, into: store, folderID: targetID, now: now, report: &report)
            }
        }
    }

    /// Whether any importable text file exists anywhere under `directory`.
    private static func containsNotes(_ directory: URL) -> Bool {
        let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        while let url = enumerator?.nextObject() as? URL {
            if textExtensions.contains(url.pathExtension.lowercased()) { return true }
        }
        return false
    }

    private static func importFile(
        _ url: URL,
        into store: Store,
        folderID: UUID?,
        now: Date,
        report: inout Report
    ) throws {
        guard textExtensions.contains(url.pathExtension.lowercased()) else {
            report.skippedCount += 1
            return
        }
        guard let data = try? Data(contentsOf: url), data.count <= maximumNoteByteCount else {
            report.skippedCount += 1
            return
        }
        // Accept UTF-8, falling back to Latin-1 so old text files still load.
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            report.skippedCount += 1
            return
        }

        let parsed = FrontMatter.parse(text)
        let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        let title = parsed.title ?? url.deletingPathExtension().lastPathComponent
        let updatedAt = parsed.updatedAt ?? values?.contentModificationDate ?? now
        let createdAt = min(parsed.createdAt ?? values?.creationDate ?? updatedAt, updatedAt)

        let note = try store.importNote(
            folderID: folderID,
            title: title,
            body: parsed.body,
            tags: parsed.tags,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
        report.noteCount += 1

        // Pull in images the note links to by relative path.
        let rewritten = try importLinkedImages(
            in: parsed.body,
            noteID: note.id,
            baseDirectory: url.deletingLastPathComponent(),
            store: store,
            report: &report
        )
        if rewritten != parsed.body {
            try store.updateNote(id: note.id, body: rewritten, now: updatedAt)
        }
    }

    static let imageLink = try! NSRegularExpression(pattern: #"!\[([^\]\n]*)\]\(([^)\n]+)\)"#)

    private static func importLinkedImages(
        in body: String,
        noteID: UUID,
        baseDirectory: URL,
        store: Store,
        report: inout Report
    ) throws -> String {
        let string = NSMutableString(string: body)
        let matches = imageLink.matches(in: body, range: NSRange(location: 0, length: string.length))
        let base = baseDirectory.standardizedFileURL.path
        for match in matches.reversed() {
            let alt = string.substring(with: match.range(at: 1))
            let target = string.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespaces)
            guard !target.contains(":"), !target.hasPrefix("/") else { continue }
            let decoded = target.removingPercentEncoding ?? target
            let imageURL = baseDirectory.appendingPathComponent(decoded).standardizedFileURL
            // Stay inside the folder being imported.
            guard imageURL.path.hasPrefix(base + "/"),
                  ImageType.mimeType(forPathExtension: imageURL.pathExtension) != nil,
                  let data = try? Data(contentsOf: imageURL),
                  data.count <= ImageType.maximumByteCount,
                  let mimeType = ImageType.sniffMimeType(data)
            else { continue }
            let id = try store.addAttachment(noteID: noteID, mimeType: mimeType, data: data)
            string.replaceCharacters(in: match.range, with: AttachmentReference.token(id: id, alt: alt))
            report.imageCount += 1
        }
        return string as String
    }
}
