import AppKit
import OfflineCore

extension NSAttributedString.Key {
    /// Marks the three characters of a task checkbox, so a click can toggle it.
    static let offlineCheckbox = NSAttributedString.Key("offline.checkbox")
    /// The destination of a Markdown link (opened with Command-click).
    static let offlineLink = NSAttributedString.Key("offline.link")
    /// The id (UUID string) of the stored image an attachment character shows.
    static let offlineImageID = NSAttributedString.Key("offline.imageID")
    /// The alt text of that image.
    static let offlineImageAlt = NSAttributedString.Key("offline.imageAlt")
}

/// The editor's typeface settings.
struct EditorTypography: Equatable {
    enum Family: String, CaseIterable, Identifiable {
        case system
        case serif
        case rounded
        case monospaced

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .system: return "System"
            case .serif: return "Serif"
            case .rounded: return "Rounded"
            case .monospaced: return "Monospaced"
            }
        }
    }

    static let minimumSize: CGFloat = 10
    static let maximumSize: CGFloat = 32
    static let defaultSize: CGFloat = 15

    var family: Family = .system
    var size: CGFloat = EditorTypography.defaultSize

    func font(size: CGFloat? = nil, weight: NSFont.Weight = .regular) -> NSFont {
        let pointSize = size ?? self.size
        let base = NSFont.systemFont(ofSize: pointSize, weight: weight)
        let design: NSFontDescriptor.SystemDesign
        switch family {
        case .system: return base
        case .serif: design = .serif
        case .rounded: design = .rounded
        case .monospaced: return NSFont.monospacedSystemFont(ofSize: pointSize, weight: weight)
        }
        guard let descriptor = base.fontDescriptor.withDesign(design) else { return base }
        return NSFont(descriptor: descriptor, size: pointSize) ?? base
    }

    var codeFont: NSFont {
        NSFont.monospacedSystemFont(ofSize: (size * 0.93).rounded(), weight: .regular)
    }
}

/// Applies Markdown styling to a text storage in place. The characters are
/// never changed: the note stays plain Markdown.
enum MarkdownStyler {
    private static let headingScale: [CGFloat] = [1.7, 1.45, 1.25, 1.12, 1.0, 1.0]

    static func baseAttributes(_ typography: EditorTypography) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = (typography.size * 0.25).rounded()
        paragraph.paragraphSpacing = (typography.size * 0.3).rounded()
        return [
            .font: typography.font(),
            .foregroundColor: NSColor.textColor,
            .paragraphStyle: paragraph,
        ]
    }

    static func restyle(_ storage: NSTextStorage, typography: EditorTypography) {
        let full = NSRange(location: 0, length: storage.length)
        guard full.length > 0 else { return }

        for key: NSAttributedString.Key in [
            .backgroundColor, .strikethroughStyle, .underlineStyle, .cursor,
            .offlineCheckbox, .offlineLink,
        ] {
            storage.removeAttribute(key, range: full)
        }
        storage.addAttributes(baseAttributes(typography), range: full)

        let spans = MarkdownParser.spans(in: storage.string)

        // Block-level styles first, so inline emphasis can build on their fonts.
        for span in spans {
            switch span.element {
            case .heading(let level):
                let scale = headingScale[min(max(level, 1), 6) - 1]
                storage.addAttribute(
                    .font,
                    value: typography.font(size: (typography.size * scale).rounded(), weight: .bold),
                    range: span.range
                )
            case .codeBlock:
                storage.addAttributes([
                    .font: typography.codeFont,
                    .backgroundColor: NSColor.quaternaryLabelColor.withAlphaComponent(0.12),
                ], range: span.range)
            case .blockquote:
                storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: span.range)
            default:
                break
            }
        }

        for span in spans {
            switch span.element {
            case .bold:
                addTrait(.boldFontMask, to: storage, range: span.range)
            case .italic:
                addTrait(.italicFontMask, to: storage, range: span.range)
            case .strikethrough:
                storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: span.range)
            case .inlineCode:
                storage.addAttributes([
                    .font: typography.codeFont,
                    .backgroundColor: NSColor.quaternaryLabelColor.withAlphaComponent(0.12),
                ], range: span.range)
            case .link(let destination):
                storage.addAttributes([
                    .foregroundColor: NSColor.linkColor,
                    .underlineStyle: NSUnderlineStyle.single.rawValue,
                    .offlineLink: destination,
                ], range: span.range)
            case .listMarker:
                storage.addAttribute(.foregroundColor, value: NSColor.controlAccentColor, range: span.range)
            case .checkbox(let checked):
                storage.addAttributes([
                    .font: typography.codeFont,
                    .foregroundColor: checked ? NSColor.secondaryLabelColor : NSColor.controlAccentColor,
                    .cursor: NSCursor.pointingHand,
                    .offlineCheckbox: checked,
                ], range: span.range)
            case .completedTask:
                storage.addAttributes([
                    .foregroundColor: NSColor.secondaryLabelColor,
                    .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                ], range: span.range)
            case .heading, .codeBlock, .blockquote, .syntax:
                break
            }
        }

        // Markup characters are dimmed last so nothing recolours them.
        for span in spans where span.element == .syntax {
            storage.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: span.range)
        }
    }

    private static func addTrait(_ trait: NSFontTraitMask, to storage: NSTextStorage, range: NSRange) {
        var changes: [(NSRange, NSFont)] = []
        storage.enumerateAttribute(.font, in: range) { value, subrange, _ in
            guard let font = value as? NSFont else { return }
            changes.append((subrange, NSFontManager.shared.convert(font, toHaveTrait: trait)))
        }
        for (subrange, font) in changes {
            storage.addAttribute(.font, value: font, range: subrange)
        }
    }
}
