import AppKit

/// The base class for every text view in the app, including the field editor
/// behind single-line fields.
///
/// It closes the routes by which text normally leaves a text view without the
/// user asking for it:
/// - Writing Tools (Apple Intelligence) is switched off.
/// - Inline predictions, autocorrection, spelling and grammar checking, data
///   detectors and smart substitutions are off, so text is not handed to
///   system language services.
/// - The view offers nothing to the Services menu.
/// - The context menu is built here and only has Cut, Copy, Paste and Select
///   All: no Look Up, Translate, Search With, Share or Writing Tools items.
/// - Copy and cut mark the clipboard as concealed and transient.
/// - Paste takes plain text only.
class HardenedTextView: NSTextView {
    /// A text view built on an explicit TextKit 1 stack does not retain its
    /// text storage, so the view keeps it alive here.
    private(set) var ownedStorage: NSTextStorage?

    /// Builds the storage, layout manager and container for a new view.
    static func makeTextStack(containerSize: NSSize) -> (NSTextStorage, NSTextContainer) {
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: containerSize)
        layoutManager.addTextContainer(container)
        return (storage, container)
    }

    func own(_ storage: NSTextStorage) {
        ownedStorage = storage
    }

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
        harden()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        harden()
    }

    /// Applies every restriction. Called again whenever AppKit might have
    /// reset a property (for example when a field editor is reused).
    func harden() {
        writingToolsBehavior = .none
        allowedWritingToolsResultOptions = []
        inlinePredictionType = .no

        isAutomaticSpellingCorrectionEnabled = false
        isAutomaticTextCompletionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticDataDetectionEnabled = false
        isAutomaticLinkDetectionEnabled = false
        isContinuousSpellCheckingEnabled = false
        isGrammarCheckingEnabled = false
        smartInsertDeleteEnabled = false

        isRichText = false
        importsGraphics = false
        allowsImageEditing = false
        usesFontPanel = false
        usesFindBar = false
        usesInspectorBar = false
        isIncrementalSearchingEnabled = false
        displaysLinkToolTips = false
    }

    // MARK: Services

    /// Returning nil for every type tells AppKit this view can neither send
    /// its selection to a service nor receive from one.
    override func validRequestor(
        forSendType sendType: NSPasteboard.PasteboardType?,
        returnType: NSPasteboard.PasteboardType?
    ) -> Any? {
        nil
    }

    // MARK: Context menu

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.allowsContextMenuPlugIns = false
        menu.addItem(withTitle: "Cut", action: #selector(cut(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Copy", action: #selector(copy(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Paste", action: #selector(paste(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Select All", action: #selector(selectAll(_:)), keyEquivalent: "")
        return menu
    }

    // MARK: Clipboard

    /// The text Copy puts on the clipboard. Subclasses can translate the
    /// selection (the note editor turns inline images back into Markdown).
    func plainText(in range: NSRange) -> String {
        (string as NSString).substring(with: range)
    }

    override func copy(_ sender: Any?) {
        let range = selectedRange()
        guard range.length > 0 else { return }
        ConcealedPasteboard.write(plainText(in: range))
    }

    override func cut(_ sender: Any?) {
        guard isEditable, selectedRange().length > 0 else { return }
        copy(sender)
        delete(sender)
    }

    /// Used for drags and anything else that asks the view to put its
    /// selection on a pasteboard.
    override func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        let range = selectedRange()
        guard range.length > 0 else { return false }
        return ConcealedPasteboard.write(plainText(in: range), to: pboard)
    }

    override func paste(_ sender: Any?) {
        pasteAsPlainText(sender)
    }

    override func pasteAsRichText(_ sender: Any?) {
        pasteAsPlainText(sender)
    }

    // MARK: Keys

    /// Command-Delete is the menu shortcut for "Delete Note". While typing it
    /// should keep its usual meaning, so the text view claims it before the
    /// menu bar sees it.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.type == .keyDown, event.keyCode == 51, modifiers == .command,
           window?.firstResponder === self {
            deleteToBeginningOfLine(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// The shared editor that single-line text fields type into.
final class HardenedFieldEditor: HardenedTextView {
    override func harden() {
        super.harden()
        isFieldEditor = true
    }
}
