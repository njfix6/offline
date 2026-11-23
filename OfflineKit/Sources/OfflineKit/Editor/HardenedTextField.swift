import AppKit
import SwiftUI

/// An `NSTextField` with Writing Tools and the other text services off.
///
/// While a field is being edited its text lives in the window's field editor.
/// `HardenedWindow` supplies a `HardenedFieldEditor` for that, which is where
/// most of the protection comes from; this class covers the field itself.
final class HardenedNSTextField: NSTextField {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        harden()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        harden()
    }

    private func harden() {
        if #available(macOS 15.2, *) {
            allowsWritingTools = false
        }
        isAutomaticTextCompletionEnabled = false
        allowsCharacterPickerTouchBarItem = false
        allowsEditingTextAttributes = false
        importsGraphics = false
        cell?.isScrollable = true
        cell?.wraps = false
        cell?.usesSingleLineMode = true
    }

    override func textShouldBeginEditing(_ textObject: NSText) -> Bool {
        (textObject as? HardenedTextView)?.harden()
        return super.textShouldBeginEditing(textObject)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        nil
    }
}

/// SwiftUI wrapper. Used instead of SwiftUI's `TextField` everywhere so every
/// field in the app goes through the hardened classes above.
struct HardenedTextField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String = ""
    var font: NSFont = .systemFont(ofSize: NSFont.systemFontSize)
    var isBordered = false
    var accessibilityLabel: String = ""
    /// Changing this value moves keyboard focus into the field.
    var focusToken: Int = 0
    var onCommit: () -> Void = {}
    var onCancel: () -> Void = {}
    var onEndEditing: () -> Void = {}

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> HardenedNSTextField {
        let field = HardenedNSTextField(frame: .zero)
        field.delegate = context.coordinator
        field.isBordered = isBordered
        field.isBezeled = isBordered
        field.bezelStyle = .roundedBezel
        field.drawsBackground = isBordered
        field.focusRingType = isBordered ? .default : .none
        field.lineBreakMode = .byTruncatingTail
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        context.coordinator.lastFocusToken = focusToken
        return field
    }

    func updateNSView(_ field: HardenedNSTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text {
            field.stringValue = text
        }
        field.placeholderString = placeholder
        field.font = font
        field.setAccessibilityLabel(accessibilityLabel.isEmpty ? placeholder : accessibilityLabel)
        if context.coordinator.lastFocusToken != focusToken {
            context.coordinator.lastFocusToken = focusToken
            DispatchQueue.main.async {
                field.window?.makeFirstResponder(field)
            }
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: HardenedTextField
        var lastFocusToken = 0

        init(_ parent: HardenedTextField) {
            self.parent = parent
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            if parent.text != field.stringValue {
                parent.text = field.stringValue
            }
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            parent.onEndEditing()
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.insertNewline(_:)) {
                parent.onCommit()
                return true
            }
            if selector == #selector(NSResponder.cancelOperation(_:)) {
                parent.onCancel()
                return true
            }
            return false
        }
    }
}
