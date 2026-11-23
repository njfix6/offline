import Foundation

/// Writes notes out as plain Markdown files.
///
/// Exported files are NOT encrypted. The app warns before every export; this
/// type only does the writing. It never overwrites an existing file.
public enum MarkdownExport {
    public struct Report: Equatable, Sendable {
        public var noteCount = 0
        public var imageCount = 0
        /// The folder everything was written into.
        public var destination: URL
    }

    /// Exports one note into `directory`.
    public static func exportNote(id: UUID, from store: Store, to directory: URL) throws -> Report {
        guard let note = try store.note(id: id) else { throw StoreError.notFound }
        var report = Report(destination: directory)
        var usedNames = Set<String>()
        try write(note, from: store, into: directory, usedNames: &usedNames, report: &report)
        return report
    }

    /// Exports every note that is not in the Trash into a new, dated folder
    /// inside `directory`, mirroring the folder structure.
    public static func exportAll(from store: Store, to directory: URL, now: Date = Date()) throws -> Report {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HHmmss"
        let root = uniqueURL(
            in: directory,
            name: "Offline Export \(formatter.string(from: now))",
            pathExtension: nil,
            used: nil
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let folders = try store.folders()
        let foldersByID = Dictionary(uniqueKeysWithValues: folders.map { ($0.id, $0) })
        var report = Report(destination: root)
        var usedNamesByDirectory: [URL: Set<String>] = [:]

        for summary in try store.notes(in: .all, sortedBy: .created) {
            guard let note = try store.note(id: summary.id) else { continue }
            var target = root
            if let folderID = note.folderID, let folder = foldersByID[folderID] {
                if let parentID = folder.parentID, let parent = foldersByID[parentID] {
                    target.appendPathComponent(fileName(from: parent.name), isDirectory: true)
                }
                target.appendPathComponent(fileName(from: folder.name), isDirectory: true)
            }
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            var used = usedNamesByDirectory[target] ?? []
            try write(note, from: store, into: target, usedNames: &used, report: &report)
            usedNamesByDirectory[target] = used
        }
        return report
    }

    // MARK: - Writing one note

    private static func write(
        _ note: Note,
        from store: Store,
        into directory: URL,
        usedNames: inout Set<String>,
        report: inout Report
    ) throws {
        var body = note.body

        // Images go into an "attachments" folder next to the note, and the
        // note's links are rewritten to point at them.
        let references = AttachmentReference.findAll(in: body)
        if !references.isEmpty {
            let imagesDirectory = directory.appendingPathComponent("attachments", isDirectory: true)
            let string = NSMutableString(string: body)
            for reference in references.reversed() {
                guard let attachment = try store.attachment(id: reference.id) else { continue }
                try FileManager.default.createDirectory(at: imagesDirectory, withIntermediateDirectories: true)
                let name = "\(attachment.id.uuidString).\(ImageType.pathExtension(forMimeType: attachment.mimeType))"
                let imageURL = imagesDirectory.appendingPathComponent(name)
                if !FileManager.default.fileExists(atPath: imageURL.path) {
                    try attachment.data.write(to: imageURL, options: .withoutOverwriting)
                    report.imageCount += 1
                }
                string.replaceCharacters(in: reference.range, with: "![\(reference.alt)](attachments/\(name))")
            }
            body = string as String
        }

        let tags = try store.tags(forNote: note.id).map(\.name)
        let contents = FrontMatter.render(
            title: note.title,
            tags: tags,
            createdAt: note.createdAt,
            updatedAt: note.updatedAt
        ) + body + (body.hasSuffix("\n") ? "" : "\n")

        let url = uniqueURL(
            in: directory,
            name: fileName(from: note.title.isEmpty ? "Untitled" : note.title),
            pathExtension: "md",
            used: &usedNames
        )
        try Data(contents.utf8).write(to: url, options: .withoutOverwriting)
        report.noteCount += 1
    }

    // MARK: - File names

    /// Makes a title safe to use as a file name.
    public static func fileName(from title: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters).union(.newlines)
        var name = title.unicodeScalars
            .map { forbidden.contains($0) ? "-" : String($0) }
            .joined()
            .trimmingCharacters(in: .whitespaces)
        while name.hasPrefix(".") { name.removeFirst() }
        if name.count > 80 { name = String(name.prefix(80)).trimmingCharacters(in: .whitespaces) }
        return name.isEmpty ? "Untitled" : name
    }

    private static func uniqueURL(
        in directory: URL,
        name: String,
        pathExtension: String?,
        used: UnsafeMutablePointer<Set<String>>?
    ) -> URL {
        var counter = 1
        while true {
            let candidate = counter == 1 ? name : "\(name) \(counter)"
            let fullName = pathExtension.map { "\(candidate).\($0)" } ?? candidate
            let url = directory.appendingPathComponent(fullName)
            let key = fullName.lowercased()
            let taken = used?.pointee.contains(key) ?? false
            if !taken, !FileManager.default.fileExists(atPath: url.path) {
                used?.pointee.insert(key)
                return url
            }
            counter += 1
        }
    }
}

/// The small metadata block at the top of exported notes.
public enum FrontMatter {
    public struct Parsed: Equatable, Sendable {
        public var title: String?
        public var tags: [String] = []
        public var createdAt: Date?
        public var updatedAt: Date?
        /// The text after the metadata block.
        public var body: String
    }

    private static func formatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }

    static func render(title: String, tags: [String], createdAt: Date, updatedAt: Date) -> String {
        let dates = formatter()
        var lines = ["---"]
        lines.append("title: \(quoted(title))")
        if !tags.isEmpty {
            lines.append("tags: [\(tags.map(quoted).joined(separator: ", "))]")
        }
        lines.append("created: \(dates.string(from: createdAt))")
        lines.append("modified: \(dates.string(from: updatedAt))")
        lines.append("---")
        return lines.joined(separator: "\n") + "\n\n"
    }

    private static func quoted(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
        return "\"\(escaped)\""
    }

    private static func unquoted(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2, trimmed.hasPrefix("\""), trimmed.hasSuffix("\"") else { return trimmed }
        var result = ""
        var escaping = false
        for character in trimmed.dropFirst().dropLast() {
            if escaping {
                result.append(character)
                escaping = false
            } else if character == "\\" {
                escaping = true
            } else {
                result.append(character)
            }
        }
        return result
    }

    /// Splits a comma-separated list, respecting double quotes.
    private static func splitList(_ value: String) -> [String] {
        var items: [String] = []
        var current = ""
        var inQuotes = false
        var escaping = false
        for character in value {
            if escaping {
                current.append(character)
                escaping = false
            } else if character == "\\" && inQuotes {
                current.append(character)
                escaping = true
            } else if character == "\"" {
                inQuotes.toggle()
                current.append(character)
            } else if character == "," && !inQuotes {
                items.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        items.append(current)
        return items.map(unquoted).filter { !$0.isEmpty }
    }

    /// Reads a leading `---` block if there is one. Unknown keys are ignored.
    public static func parse(_ text: String) -> Parsed {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        guard lines.first == "---",
              let end = lines.dropFirst().firstIndex(of: "---")
        else { return Parsed(body: normalized) }

        var parsed = Parsed(body: "")
        let dates = formatter()
        for line in lines[1..<end] {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            switch key {
            case "title":
                parsed.title = unquoted(value)
            case "tags":
                var list = value
                if list.hasPrefix("["), list.hasSuffix("]") {
                    list = String(list.dropFirst().dropLast())
                }
                parsed.tags = splitList(list)
            case "created":
                parsed.createdAt = dates.date(from: value)
            case "modified", "updated":
                parsed.updatedAt = dates.date(from: value)
            default:
                break
            }
        }
        var rest = Array(lines[(end + 1)...])
        while rest.first == "" { rest.removeFirst() }
        parsed.body = rest.joined(separator: "\n")
        return parsed
    }
}
