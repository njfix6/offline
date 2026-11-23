import AppKit
import OfflineCore

/// The note editor: a hardened text view that styles Markdown as you type,
/// toggles task checkboxes on click, continues lists on Return and shows
/// stored images inline.
///
/// Images appear as attachment characters in the text storage. `markdown`
/// translates them back to `![alt](attachment:<id>)`, so what is saved is
/// always plain Markdown.
final class MarkdownTextView: HardenedTextView, NSTextStorageDelegate {
    var typography = EditorTypography() {
        didSet {
            guard typography != oldValue else { return }
            applyTypography()
        }
    }

    /// Stores a new image and returns its id. Nil if the image was refused.
    var storeImage: ((_ data: Data, _ mimeType: String) -> UUID?)?
    /// Loads a stored image's bytes.
    var loadImage: ((UUID) -> Data?)?

    private var isLoading = false
    private var highlightTerms: [String] = []

    /// A text view on its own TextKit 1 stack, sized to track its scroll view.
    static func make() -> MarkdownTextView {
        let (storage, container) = makeTextStack(
            containerSize: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        )
        container.widthTracksTextView = true

        let view = MarkdownTextView(frame: .zero, textContainer: container)
        view.own(storage)
        storage.delegate = view
        view.minSize = NSSize(width: 0, height: 0)
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainerInset = NSSize(width: 28, height: 20)
        view.allowsUndo = true
        view.drawsBackground = true
        view.backgroundColor = .textBackgroundColor
        view.insertionPointColor = .controlAccentColor
        view.setAccessibilityLabel("Note text")
        view.applyTypography()
        return view
    }

    override func harden() {
        super.harden()
        // Attachments are needed for inline images. `isRichText` stays false
        // for the user: paste is plain text only (see `paste`).
        isRichText = true
        importsGraphics = false
    }

    private func applyTypography() {
        let attributes = MarkdownStyler.baseAttributes(typography)
        typingAttributes = attributes
        font = typography.font()
        if let storage = textStorage, storage.length > 0 {
            storage.beginEditing()
            MarkdownStyler.restyle(storage, typography: typography)
            storage.endEditing()
        }
    }

    // MARK: Content

    /// Replaces the whole document. Clears undo history, so one note's text
    /// can never be "undone" into another.
    func setMarkdown(_ markdown: String) {
        guard let storage = textStorage else { return }
        isLoading = true
        undoManager?.removeAllActions()
        storage.beginEditing()
        storage.setAttributedString(NSAttributedString(
            string: markdown,
            attributes: MarkdownStyler.baseAttributes(typography)
        ))
        materializeImages(in: storage)
        MarkdownStyler.restyle(storage, typography: typography)
        storage.endEditing()
        typingAttributes = MarkdownStyler.baseAttributes(typography)
        setSelectedRange(NSRange(location: 0, length: 0))
        scrollRangeToVisible(NSRange(location: 0, length: 0))
        isLoading = false
        undoManager?.removeAllActions()
        applyHighlights()
    }

    /// The document as Markdown.
    var markdown: String {
        guard let storage = textStorage else { return "" }
        return markdownText(in: NSRange(location: 0, length: storage.length))
    }

    private func markdownText(in range: NSRange) -> String {
        guard let storage = textStorage, range.length > 0 else { return "" }
        var result = ""
        let string = storage.string as NSString
        storage.enumerateAttribute(.offlineImageID, in: range) { value, subrange, _ in
            if let idString = value as? String, let id = UUID(uuidString: idString) {
                let alt = storage.attribute(.offlineImageAlt, at: subrange.location, effectiveRange: nil) as? String
                // One token per attachment character.
                for _ in 0..<subrange.length {
                    result += AttachmentReference.token(id: id, alt: alt ?? "image")
                }
            } else {
                result += string.substring(with: subrange)
                    .replacingOccurrences(of: "\u{FFFC}", with: "")
            }
        }
        return result
    }

    override func plainText(in range: NSRange) -> String {
        markdownText(in: range)
    }

    /// Turns `![alt](attachment:<id>)` tokens in the storage into inline
    /// images. Tokens whose image cannot be loaded stay as text.
    private func materializeImages(in storage: NSTextStorage) {
        let references = AttachmentReference.findAll(in: storage.string)
        for reference in references.reversed() {
            guard let data = loadImage?(reference.id), let image = NSImage(data: data) else { continue }
            storage.replaceCharacters(
                in: reference.range,
                with: imageString(image: image, id: reference.id, alt: reference.alt)
            )
        }
    }

    private func imageString(image: NSImage, id: UUID, alt: String) -> NSAttributedString {
        let maxWidth = max(120, min(640, bounds.width - 2 * textContainerInset.width - 12))
        var size = image.size
        if size.width <= 0 || size.height <= 0 { size = NSSize(width: 64, height: 64) }
        if size.width > maxWidth {
            size = NSSize(width: maxWidth, height: (size.height * maxWidth / size.width).rounded())
        }
        image.size = size

        let attachment = NSTextAttachment()
        attachment.image = image
        attachment.bounds = CGRect(origin: .zero, size: size)

        let string = NSMutableAttributedString(attachment: attachment)
        var attributes = MarkdownStyler.baseAttributes(typography)
        attributes[.offlineImageID] = id.uuidString
        attributes[.offlineImageAlt] = alt
        string.addAttributes(attributes, range: NSRange(location: 0, length: string.length))
        return string
    }

    // MARK: Styling

    func textStorage(
        _ textStorage: NSTextStorage,
        didProcessEditing editedMask: NSTextStorageEditActions,
        range editedRange: NSRange,
        changeInLength delta: Int
    ) {
        // Only attributes are changed here, which TextKit allows at this point.
        guard !isLoading, editedMask.contains(.editedCharacters) else { return }
        MarkdownStyler.restyle(textStorage, typography: typography)
    }

    override func didChangeText() {
        super.didChangeText()
        typingAttributes = MarkdownStyler.baseAttributes(typography)
        applyHighlights()
    }

    /// Highlights search matches without touching the stored text.
    func setHighlightTerms(_ terms: [String]) {
        highlightTerms = terms
        applyHighlights()
    }

    private func applyHighlights() {
        guard let layoutManager, let storage = textStorage else { return }
        let full = NSRange(location: 0, length: storage.length)
        layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: full)
        guard !highlightTerms.isEmpty else { return }
        for range in MarkdownEditing.ranges(of: highlightTerms, in: storage.string) {
            layoutManager.addTemporaryAttribute(
                .backgroundColor,
                value: NSColor.findHighlightColor.withAlphaComponent(0.55),
                forCharacterRange: range
            )
        }
    }

    /// Scrolls to the first search match.
    func revealFirstHighlight() {
        guard let first = MarkdownEditing.ranges(of: highlightTerms, in: string).first else { return }
        scrollRangeToVisible(first)
    }

    // MARK: Editing behaviour

    private func replace(_ range: NSRange, with replacement: String) {
        guard shouldChangeText(in: range, replacementString: replacement) else { return }
        textStorage?.replaceCharacters(in: range, with: replacement)
        didChangeText()
    }

    override func insertNewline(_ sender: Any?) {
        let selection = selectedRange()
        let string = self.string as NSString
        guard selection.length == 0, selection.location <= string.length else {
            super.insertNewline(sender)
            return
        }
        let lineRange = string.lineRange(for: NSRange(location: selection.location, length: 0))
        let beforeCaret = string.substring(with: NSRange(
            location: lineRange.location,
            length: selection.location - lineRange.location
        ))
        switch MarkdownEditing.returnAction(forLine: beforeCaret) {
        case .continueList(let prefix):
            insertText("\n" + prefix, replacementRange: selection)
        case .endList:
            replace(NSRange(location: lineRange.location, length: selection.location - lineRange.location), with: "")
        case nil:
            super.insertNewline(sender)
        }
    }

    override func mouseDown(with event: NSEvent) {
        if let index = characterIndex(at: event), let storage = textStorage {
            var effective = NSRange()
            if storage.attribute(.offlineCheckbox, at: index, effectiveRange: &effective) != nil,
               isEditable, effective.length == 3 {
                let current = (storage.string as NSString).substring(with: effective)
                replace(effective, with: MarkdownEditing.toggledCheckbox(current))
                return
            }
            if event.modifierFlags.contains(.command),
               let destination = storage.attribute(.offlineLink, at: index, effectiveRange: nil) as? String,
               let url = URL(string: destination),
               let scheme = url.scheme?.lowercased(), ["http", "https", "mailto"].contains(scheme) {
                // Hands the address to the default browser or mail app. Offline
                // itself has no network access.
                NSWorkspace.shared.open(url)
                return
            }
        }
        super.mouseDown(with: event)
    }

    private func characterIndex(at event: NSEvent) -> Int? {
        guard let layoutManager, let textContainer, let storage = textStorage, storage.length > 0 else { return nil }
        var point = convert(event.locationInWindow, from: nil)
        point.x -= textContainerOrigin.x
        point.y -= textContainerOrigin.y
        var fraction: CGFloat = 0
        let glyph = layoutManager.glyphIndex(for: point, in: textContainer, fractionOfDistanceThroughGlyph: &fraction)
        let glyphRect = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: textContainer)
        guard glyphRect.contains(point) else { return nil }
        let index = layoutManager.characterIndexForGlyph(at: glyph)
        return index < storage.length ? index : nil
    }

    // MARK: Images

    private static let imageDataTypes: [(NSPasteboard.PasteboardType, String?)] = [
        (.png, "image/png"),
        (NSPasteboard.PasteboardType("public.jpeg"), "image/jpeg"),
        (NSPasteboard.PasteboardType("public.heic"), "image/heic"),
        (.tiff, nil),
    ]

    /// Only plain text is ever read into the note; images go through
    /// `insert(images:at:)` instead.
    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        [.string]
    }

    override var acceptableDragTypes: [NSPasteboard.PasteboardType] {
        [.string, .fileURL] + Self.imageDataTypes.map(\.0)
    }

    /// Images found on a pasteboard, as (bytes, MIME type).
    private func images(on pasteboard: NSPasteboard) -> [(Data, String)] {
        var found: [(Data, String)] = []

        let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []
        for url in urls where ImageType.mimeType(forPathExtension: url.pathExtension) != nil {
            if let data = try? Data(contentsOf: url), let mimeType = ImageType.sniffMimeType(data) {
                found.append((data, mimeType))
            }
        }
        guard found.isEmpty, urls.isEmpty else { return found }

        for (type, mimeType) in Self.imageDataTypes {
            guard let data = pasteboard.data(forType: type) else { continue }
            if mimeType != nil, let sniffed = ImageType.sniffMimeType(data) {
                return [(data, sniffed)]
            }
            // TIFF (screenshots, copied image regions) is converted to PNG.
            if let bitmap = NSBitmapImageRep(data: data),
               let png = bitmap.representation(using: .png, properties: [:]) {
                return [(png, "image/png")]
            }
        }
        return []
    }

    private func insert(images: [(Data, String)], at range: NSRange) {
        guard isEditable else { return }
        let insertion = NSMutableAttributedString()
        for (data, mimeType) in images where data.count <= ImageType.maximumByteCount {
            guard let image = NSImage(data: data), let id = storeImage?(data, mimeType) else { continue }
            insertion.append(imageString(image: image, id: id, alt: "image"))
            insertion.append(NSAttributedString(string: "\n", attributes: MarkdownStyler.baseAttributes(typography)))
        }
        guard insertion.length > 0,
              shouldChangeText(in: range, replacementString: insertion.string)
        else {
            if insertion.length == 0 { NSSound.beep() }
            return
        }
        textStorage?.replaceCharacters(in: range, with: insertion)
        didChangeText()
        setSelectedRange(NSRange(location: range.location + insertion.length, length: 0))
    }

    override func paste(_ sender: Any?) {
        let pasteboard = NSPasteboard.general
        let pastedImages = images(on: pasteboard)
        if !pastedImages.isEmpty {
            insert(images: pastedImages, at: selectedRange())
            return
        }
        let before = textStorage?.length ?? 0
        pasteAsPlainText(sender)
        // Pasted Markdown may contain image tokens copied from another note.
        if let storage = textStorage, storage.length != before,
           !AttachmentReference.findAll(in: storage.string).isEmpty {
            isLoading = true
            storage.beginEditing()
            materializeImages(in: storage)
            MarkdownStyler.restyle(storage, typography: typography)
            storage.endEditing()
            isLoading = false
        }
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let droppedImages = images(on: sender.draggingPasteboard)
        guard !droppedImages.isEmpty else {
            // Anything that is not an image is only accepted as plain text.
            guard sender.draggingPasteboard.availableType(from: [.string]) != nil else { return false }
            return super.performDragOperation(sender)
        }
        let point = convert(sender.draggingLocation, from: nil)
        let index = characterIndexForInsertion(at: point)
        insert(images: droppedImages, at: NSRange(location: index, length: 0))
        return true
    }
}
