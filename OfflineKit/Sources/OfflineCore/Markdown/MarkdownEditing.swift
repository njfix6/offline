import Foundation

/// Editing behaviours that depend on Markdown structure, kept free of UI so
/// they can be unit tested.
public enum MarkdownEditing {
    public enum ReturnAction: Equatable, Sendable {
        /// Insert a newline followed by this prefix (continue the list).
        case continueList(prefix: String)
        /// The current item is empty: remove its marker and end the list.
        case endList
    }

    private static let listItem = try! NSRegularExpression(
        pattern: #"^([ \t]*)(?:([-*+])|(\d{1,9})([.)]))([ \t]+)(\[[ xX]\][ \t]+)?(.*)$"#
    )

    /// What Return should do when the caret is at the end of `line`. Nil means
    /// a normal newline.
    public static func returnAction(forLine line: String) -> ReturnAction? {
        let string = line as NSString
        guard let match = listItem.firstMatch(in: line, range: NSRange(location: 0, length: string.length)) else {
            return nil
        }
        func group(_ index: Int) -> String {
            let range = match.range(at: index)
            return range.location == NSNotFound ? "" : string.substring(with: range)
        }
        let content = group(7).trimmingCharacters(in: .whitespaces)
        guard !content.isEmpty else { return .endList }

        let indent = group(1)
        let marker: String
        if let number = Int(group(3)) {
            marker = "\(number + 1)\(group(4))"
        } else {
            marker = group(2)
        }
        let checkbox = group(6).isEmpty ? "" : "[ ] "
        return .continueList(prefix: "\(indent)\(marker) \(checkbox)")
    }

    /// The replacement for a three-character checkbox (`[ ]` or `[x]`) when
    /// it is clicked.
    public static func toggledCheckbox(_ checkbox: String) -> String {
        checkbox == "[ ]" ? "[x]" : "[ ]"
    }

    /// Counts words the way a person would: runs of letters and digits.
    public static func wordCount(_ text: String) -> Int {
        var count = 0
        var insideWord = false
        for scalar in text.unicodeScalars {
            let isWordCharacter = CharacterSet.alphanumerics.contains(scalar) || scalar == "'" || scalar == "’"
            if isWordCharacter {
                if !insideWord, CharacterSet.alphanumerics.contains(scalar) {
                    count += 1
                    insideWord = true
                }
            } else {
                insideWord = false
            }
        }
        return count
    }

    /// UTF-16 ranges of each search term in `text`, ignoring case and accents.
    public static func ranges(of terms: [String], in text: String) -> [NSRange] {
        let string = text as NSString
        var result: [NSRange] = []
        for term in terms where !term.isEmpty {
            var search = NSRange(location: 0, length: string.length)
            while search.length > 0 {
                let found = string.range(
                    of: term,
                    options: [.caseInsensitive, .diacriticInsensitive],
                    range: search
                )
                guard found.location != NSNotFound, found.length > 0 else { break }
                result.append(found)
                search = NSRange(
                    location: NSMaxRange(found),
                    length: string.length - NSMaxRange(found)
                )
            }
        }
        return result.sorted { $0.location < $1.location }
    }
}
