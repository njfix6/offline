import AppKit

/// Writes text to the clipboard marked so that clipboard managers skip it.
///
/// `org.nspasteboard.ConcealedType` and `TransientType` are the conventions
/// documented at nspasteboard.org. Well-behaved managers neither record nor
/// sync items carrying them. A manager that ignores the convention can still
/// read the clipboard: copying is always the user's own choice.
enum ConcealedPasteboard {
    static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    /// The general pasteboard's change count right after our last write, so
    /// the clipboard is only cleared on lock if it still holds our text.
    private static var lastGeneralChangeCount: Int?

    @discardableResult
    static func write(_ text: String, to pasteboard: NSPasteboard = .general) -> Bool {
        pasteboard.clearContents()
        pasteboard.declareTypes([.string, concealedType, transientType], owner: nil)
        let wrote = pasteboard.setString(text, forType: .string)
        pasteboard.setString("", forType: concealedType)
        pasteboard.setString("", forType: transientType)
        if pasteboard === NSPasteboard.general {
            lastGeneralChangeCount = pasteboard.changeCount
        }
        return wrote
    }

    /// Empties the clipboard if the last thing on it was copied from Offline.
    static func clearIfOwned() {
        let pasteboard = NSPasteboard.general
        if let count = lastGeneralChangeCount, pasteboard.changeCount == count {
            pasteboard.clearContents()
        }
        lastGeneralChangeCount = nil
    }
}
