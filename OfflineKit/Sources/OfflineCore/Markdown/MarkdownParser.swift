import Foundation

/// What a stretch of Markdown text is, for styling in the editor.
public enum MarkdownElement: Equatable, Sendable {
    /// A whole heading line, levels 1 to 6.
    case heading(level: Int)
    case bold
    case italic
    case strikethrough
    case inlineCode
    /// A line inside (or delimiting) a fenced code block.
    case codeBlock
    /// Link text, with where it points.
    case link(destination: String)
    /// A whole quoted line.
    case blockquote
    /// A list bullet or number.
    case listMarker
    /// The `[ ]` or `[x]` of a task item.
    case checkbox(checked: Bool)
    /// The text of a completed task.
    case completedTask
    /// Markup characters (`#`, `**`, backticks…) that should be dimmed.
    case syntax
}

public struct MarkdownSpan: Equatable, Sendable {
    /// UTF-16 range, as used by `NSTextStorage`.
    public var range: NSRange
    public var element: MarkdownElement

    public init(range: NSRange, element: MarkdownElement) {
        self.range = range
        self.element = element
    }
}

/// A small, line-based Markdown scanner. It does not build a document tree:
/// it reports which ranges are headings, emphasis, code and so on, so the
/// editor can style the text in place while it stays plain Markdown.
public enum MarkdownParser {
    private static func regex(_ pattern: String) -> NSRegularExpression {
        // Patterns are compile-time constants.
        try! NSRegularExpression(pattern: pattern)
    }

    private static let fence = regex(#"^\s{0,3}(```|~~~)"#)
    private static let heading = regex(#"^(#{1,6})[ \t]+\S"#)
    private static let quote = regex(#"^\s{0,3}>[ \t]?"#)
    private static let listItem = regex(#"^([ \t]*)([-*+]|\d{1,9}[.)])[ \t]+"#)
    private static let checkbox = regex(#"^\[([ xX])\][ \t]+"#)
    private static let inlineCode = regex(#"(`+)([^`\n]|[^`\n].*?[^`\n])\1(?!`)"#)
    private static let image = regex(#"(!\[)([^\]\n]*)(\]\()([^)\n]+)(\))"#)
    private static let link = regex(#"(?<!!)(\[)([^\]\n]+)(\]\()([^)\s]+)(\))"#)
    private static let bold = regex(#"(\*\*|__)(?=\S)(.+?)(?<=\S)\1"#)
    private static let italicStar = regex(#"(?<![\*\\])(\*)(?![\*\s])([^\*\n]+?)(?<![\*\s])(\*)(?!\*)"#)
    private static let italicUnderscore = regex(#"(?<![\w\\_])(_)(?![_\s])([^_\n]+?)(?<![_\s])(_)(?![\w_])"#)
    private static let strike = regex(#"(~~)(?=\S)(.+?)(?<=\S)(~~)"#)
    private static let bareURL = regex(#"(?<![\(\[\w])(https?://[^\s<>\)\]]+)"#)

    /// Spans for the whole text, in document order of their lines.
    public static func spans(in text: String) -> [MarkdownSpan] {
        let string = text as NSString
        var spans: [MarkdownSpan] = []
        var insideFence = false
        var location = 0

        while location < string.length {
            let lineRange = string.lineRange(for: NSRange(location: location, length: 0))
            // The line without its terminator.
            var contentEnd = NSMaxRange(lineRange)
            while contentEnd > lineRange.location,
                  let scalar = UnicodeScalar(string.character(at: contentEnd - 1)),
                  CharacterSet.newlines.contains(scalar) {
                contentEnd -= 1
            }
            let content = NSRange(location: lineRange.location, length: contentEnd - lineRange.location)

            if fence.firstMatch(in: text, options: [], range: content) != nil {
                spans.append(MarkdownSpan(range: content, element: .codeBlock))
                spans.append(MarkdownSpan(range: content, element: .syntax))
                insideFence.toggle()
            } else if insideFence {
                spans.append(MarkdownSpan(range: content, element: .codeBlock))
            } else if content.length > 0 {
                scanLine(text, content: content, into: &spans)
            }
            location = NSMaxRange(lineRange)
        }
        return spans
    }

    private static func scanLine(_ text: String, content: NSRange, into spans: inout [MarkdownSpan]) {
        var inlineRange = content

        if let match = heading.firstMatch(in: text, options: [], range: content) {
            let hashes = match.range(at: 1)
            spans.append(MarkdownSpan(range: content, element: .heading(level: hashes.length)))
            spans.append(MarkdownSpan(range: hashes, element: .syntax))
            inlineRange = NSRange(
                location: NSMaxRange(hashes),
                length: NSMaxRange(content) - NSMaxRange(hashes)
            )
        } else if let match = quote.firstMatch(in: text, options: [], range: content) {
            spans.append(MarkdownSpan(range: content, element: .blockquote))
            spans.append(MarkdownSpan(range: match.range, element: .syntax))
            inlineRange = NSRange(
                location: NSMaxRange(match.range),
                length: NSMaxRange(content) - NSMaxRange(match.range)
            )
        } else if let match = listItem.firstMatch(in: text, options: [], range: content) {
            spans.append(MarkdownSpan(range: match.range(at: 2), element: .listMarker))
            var rest = NSRange(
                location: NSMaxRange(match.range),
                length: NSMaxRange(content) - NSMaxRange(match.range)
            )
            if let box = checkbox.firstMatch(in: text, options: [.anchored], range: rest) {
                let checked = (text as NSString).substring(with: box.range(at: 1)) != " "
                spans.append(MarkdownSpan(
                    range: NSRange(location: box.range.location, length: 3),
                    element: .checkbox(checked: checked)
                ))
                rest = NSRange(
                    location: NSMaxRange(box.range),
                    length: NSMaxRange(content) - NSMaxRange(box.range)
                )
                if checked, rest.length > 0 {
                    spans.append(MarkdownSpan(range: rest, element: .completedTask))
                }
            }
            inlineRange = rest
        }

        scanInline(text, range: inlineRange, into: &spans)
    }

    private static func scanInline(_ text: String, range: NSRange, into spans: inout [MarkdownSpan]) {
        guard range.length > 0 else { return }
        // Ranges already claimed by code or link destinations: no emphasis is
        // looked for inside them.
        var claimed: [NSRange] = []
        func isClaimed(_ candidate: NSRange) -> Bool {
            claimed.contains { NSIntersectionRange($0, candidate).length > 0 }
        }

        for match in inlineCode.matches(in: text, options: [], range: range) {
            let ticks = match.range(at: 1).length
            spans.append(MarkdownSpan(range: match.range, element: .inlineCode))
            spans.append(MarkdownSpan(
                range: NSRange(location: match.range.location, length: ticks),
                element: .syntax
            ))
            spans.append(MarkdownSpan(
                range: NSRange(location: NSMaxRange(match.range) - ticks, length: ticks),
                element: .syntax
            ))
            claimed.append(match.range)
        }

        for pattern in [image, link] {
            for match in pattern.matches(in: text, options: [], range: range) where !isClaimed(match.range) {
                let destination = (text as NSString).substring(with: match.range(at: 4))
                spans.append(MarkdownSpan(range: match.range(at: 2), element: .link(destination: destination)))
                spans.append(MarkdownSpan(range: match.range(at: 1), element: .syntax))
                let tail = NSRange(
                    location: match.range(at: 3).location,
                    length: NSMaxRange(match.range) - match.range(at: 3).location
                )
                spans.append(MarkdownSpan(range: tail, element: .syntax))
                claimed.append(tail)
            }
        }

        for match in bareURL.matches(in: text, options: [], range: range) where !isClaimed(match.range) {
            let destination = (text as NSString).substring(with: match.range)
            spans.append(MarkdownSpan(range: match.range, element: .link(destination: destination)))
            claimed.append(match.range)
        }

        for match in bold.matches(in: text, options: [], range: range) where !isClaimed(match.range) {
            let marker = match.range(at: 1).length
            spans.append(MarkdownSpan(range: match.range, element: .bold))
            spans.append(MarkdownSpan(
                range: NSRange(location: match.range.location, length: marker),
                element: .syntax
            ))
            spans.append(MarkdownSpan(
                range: NSRange(location: NSMaxRange(match.range) - marker, length: marker),
                element: .syntax
            ))
        }

        for pattern in [italicStar, italicUnderscore] {
            for match in pattern.matches(in: text, options: [], range: range) where !isClaimed(match.range) {
                spans.append(MarkdownSpan(range: match.range, element: .italic))
                spans.append(MarkdownSpan(range: match.range(at: 1), element: .syntax))
                spans.append(MarkdownSpan(range: match.range(at: 3), element: .syntax))
            }
        }

        for match in strike.matches(in: text, options: [], range: range) where !isClaimed(match.range) {
            spans.append(MarkdownSpan(range: match.range, element: .strikethrough))
            spans.append(MarkdownSpan(range: match.range(at: 1), element: .syntax))
            spans.append(MarkdownSpan(range: match.range(at: 3), element: .syntax))
        }
    }
}
