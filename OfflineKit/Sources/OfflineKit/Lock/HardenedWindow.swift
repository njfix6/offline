import AppKit

/// The window class for every window that can show note content.
///
/// - `sharingType = .none` asks the window server to leave the window out of
///   screenshots, screen recordings and screen sharing.
/// - The field editor is always a `HardenedFieldEditor`, so single-line text
///   fields get the same restrictions as the note editor.
/// - State restoration is off, so the system keeps no saved copy of the
///   window's contents.
final class HardenedWindow: NSWindow {
    private lazy var hardenedFieldEditor: HardenedFieldEditor = {
        let (storage, container) = HardenedTextView.makeTextStack(
            containerSize: NSSize(width: 1.0e7, height: 1.0e7)
        )
        let editor = HardenedFieldEditor(frame: .zero, textContainer: container)
        editor.own(storage)
        return editor
    }()

    override init(
        contentRect: NSRect,
        styleMask style: NSWindow.StyleMask,
        backing backingStoreType: NSWindow.BackingStoreType,
        defer flag: Bool
    ) {
        super.init(contentRect: contentRect, styleMask: style, backing: backingStoreType, defer: flag)
        sharingType = .none
        isRestorable = false
        // Swift owns the window; AppKit must not release it a second time on close.
        isReleasedWhenClosed = false
        // The title never contains anything from a note.
        title = "Offline"
        tabbingMode = .disallowed
    }

    override var sharingType: NSWindow.SharingType {
        get { super.sharingType }
        // Nothing may make this window capturable again.
        set { super.sharingType = .none }
    }

    override func fieldEditor(_ createFlag: Bool, for object: Any?) -> NSText? {
        // Secure fields keep AppKit's own secure field editor.
        if object is NSSecureTextField {
            return super.fieldEditor(createFlag, for: object)
        }
        hardenedFieldEditor.harden()
        return hardenedFieldEditor
    }
}

extension NSAlert {
    /// Runs the alert with its window excluded from screen capture. Alerts in
    /// this app never include note titles or text.
    @discardableResult
    func runHardened() -> NSApplication.ModalResponse {
        window.sharingType = .none
        return runModal()
    }
}
