import AppKit
import OfflineCore
import SwiftUI

/// Connects the app model to the one editor text view.
///
/// The model talks to the editor through this object instead of through
/// SwiftUI state, so note text is never copied into view state or diffed.
@MainActor
final class EditorController: NSObject, NSTextViewDelegate {
    private(set) weak var textView: MarkdownTextView?

    /// Called after every user edit.
    var onChange: () -> Void = {}
    var storeImage: ((Data, String) -> UUID?)?
    var loadImage: ((UUID) -> Data?)?

    private var pendingMarkdown: String?
    private var pendingEditable = true
    private var typography = EditorTypography()
    private var highlightTerms: [String] = []

    func attach(_ view: MarkdownTextView) {
        textView = view
        view.delegate = self
        view.storeImage = { [weak self] data, mimeType in self?.storeImage?(data, mimeType) }
        view.loadImage = { [weak self] id in self?.loadImage?(id) }
        view.typography = typography
        view.isEditable = pendingEditable
        if let pendingMarkdown {
            view.setMarkdown(pendingMarkdown)
            self.pendingMarkdown = nil
        }
        view.setHighlightTerms(highlightTerms)
    }

    func load(markdown: String, editable: Bool) {
        pendingEditable = editable
        guard let textView else {
            pendingMarkdown = markdown
            return
        }
        textView.isEditable = editable
        textView.setMarkdown(markdown)
        textView.setHighlightTerms(highlightTerms)
        if !highlightTerms.isEmpty { textView.revealFirstHighlight() }
    }

    /// Removes all note text from the view and its undo history.
    func clear() {
        pendingMarkdown = nil
        highlightTerms = []
        textView?.setHighlightTerms([])
        textView?.setMarkdown("")
    }

    var markdown: String {
        textView?.markdown ?? pendingMarkdown ?? ""
    }

    var visibleText: String {
        textView?.string ?? ""
    }

    func setTypography(_ value: EditorTypography) {
        typography = value
        textView?.typography = value
    }

    func setHighlightTerms(_ terms: [String]) {
        highlightTerms = terms
        textView?.setHighlightTerms(terms)
    }

    func focus() {
        guard let textView else { return }
        textView.window?.makeFirstResponder(textView)
    }

    func textDidChange(_ notification: Notification) {
        onChange()
    }
}

/// Hosts the editor text view inside a scroll view.
struct NoteEditorView: NSViewRepresentable {
    let controller: EditorController

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor

        let textView = MarkdownTextView.make()
        textView.frame = NSRect(origin: .zero, size: scrollView.contentSize)
        scrollView.documentView = textView
        controller.attach(textView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {}
}
