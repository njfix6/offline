import AppKit
import OfflineCore
import SwiftUI
import XCTest
@testable import OfflineKit

/// A real, tiny PNG.
func makePNG(width: Int = 8, height: Int = 6) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    return rep.representation(using: .png, properties: [:])!
}

@MainActor
final class HardenedTextViewTests: XCTestCase {
    private func allTextViews() -> [HardenedTextView] {
        let window = HardenedWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled], backing: .buffered, defer: true
        )
        let field = HardenedNSTextField(frame: .zero)
        let fieldEditor = window.fieldEditor(true, for: field) as? HardenedTextView
        return [MarkdownTextView.make(), fieldEditor].compactMap { $0 }
    }

    func testWritingToolsAndLanguageServicesAreOff() {
        let views = allTextViews()
        XCTAssertEqual(views.count, 2, "the window must hand out a hardened field editor")
        for view in views {
            XCTAssertEqual(view.writingToolsBehavior, .none)
            XCTAssertTrue(view.allowedWritingToolsResultOptions.isEmpty)
            XCTAssertEqual(view.inlinePredictionType, .no)
            XCTAssertFalse(view.isAutomaticSpellingCorrectionEnabled)
            XCTAssertFalse(view.isAutomaticTextCompletionEnabled)
            XCTAssertFalse(view.isAutomaticDataDetectionEnabled)
            XCTAssertFalse(view.isAutomaticLinkDetectionEnabled)
            XCTAssertFalse(view.isContinuousSpellCheckingEnabled)
            XCTAssertFalse(view.isGrammarCheckingEnabled)
        }
    }

    func testNothingIsOfferedToServices() {
        for view in allTextViews() {
            view.string = "secret text"
            view.selectAll(nil)
            XCTAssertNil(view.validRequestor(forSendType: .string, returnType: nil))
            XCTAssertNil(view.validRequestor(forSendType: nil, returnType: .string))
            XCTAssertNil(view.validRequestor(forSendType: .string, returnType: .string))
        }
    }

    func testContextMenuHasOnlyBasicEditingItems() throws {
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ))
        for view in allTextViews() {
            view.string = "some words to select"
            view.selectAll(nil)
            let menu = try XCTUnwrap(view.menu(for: event))
            let titles = menu.items.filter { !$0.isSeparatorItem }.map(\.title)
            XCTAssertEqual(titles, ["Cut", "Copy", "Paste", "Select All"])
            XCTAssertFalse(menu.allowsContextMenuPlugIns)
            XCTAssertTrue(menu.items.allSatisfy { $0.submenu == nil })
        }
    }

    func testCopiedTextIsMarkedConcealedAndTransient() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("offline-tests-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        for view in allTextViews() {
            view.string = "copy me"
            view.selectAll(nil)
            XCTAssertTrue(view.writeSelection(to: pasteboard, types: [.string]))
            XCTAssertEqual(pasteboard.string(forType: .string), "copy me")
            let types = pasteboard.types ?? []
            XCTAssertTrue(types.contains(NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")))
            XCTAssertTrue(types.contains(NSPasteboard.PasteboardType("org.nspasteboard.TransientType")))
            XCTAssertFalse(types.contains(.rtf), "only plain text leaves the app")
        }
    }

    func testTextFieldHasWritingToolsOff() {
        let field = HardenedNSTextField(frame: .zero)
        if #available(macOS 15.2, *) {
            XCTAssertFalse(field.allowsWritingTools)
        }
        XCTAssertFalse(field.isAutomaticTextCompletionEnabled)
    }
}

@MainActor
final class HardenedWindowTests: XCTestCase {
    func testWindowIsExcludedFromCaptureAndCannotBeMadeCapturable() {
        let window = HardenedWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
            styleMask: [.titled, .resizable], backing: .buffered, defer: true
        )
        XCTAssertEqual(window.sharingType, .none)
        window.sharingType = .readOnly
        XCTAssertEqual(window.sharingType, .none)
        XCTAssertFalse(window.isRestorable)
        XCTAssertEqual(window.title, "Offline")
    }

    func testSecureFieldsKeepTheSystemSecureEditor() {
        let window = HardenedWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
            styleMask: [.titled], backing: .buffered, defer: true
        )
        let plain = window.fieldEditor(true, for: HardenedNSTextField(frame: .zero))
        XCTAssertTrue(plain is HardenedFieldEditor)
        let secure = window.fieldEditor(true, for: NSSecureTextField(frame: .zero))
        XCTAssertFalse(secure is HardenedFieldEditor)
    }
}

@MainActor
final class MarkdownTextViewTests: XCTestCase {
    func testMarkdownRoundTripsWithInlineImages() {
        let view = MarkdownTextView.make()
        view.frame = NSRect(x: 0, y: 0, width: 500, height: 400)
        let id = UUID()
        let png = makePNG()
        view.loadImage = { $0 == id ? png : nil }
        let missing = UUID()

        let source = "# Title\n\nBefore \(AttachmentReference.token(id: id, alt: "chart")) after\n\(AttachmentReference.token(id: missing))\n- [ ] task\n"
        view.setMarkdown(source)

        XCTAssertEqual(view.markdown, source, "saving must give back exactly the Markdown that was loaded")
        XCTAssertTrue(view.string.contains("\u{FFFC}"), "the stored image is shown inline")
        XCTAssertFalse(view.string.contains(id.uuidString))
        XCTAssertTrue(view.string.contains(missing.uuidString), "a token with no image stays as text")
        XCTAssertEqual(view.plainText(in: NSRange(location: 0, length: (view.string as NSString).length)), source)
    }

    func testStylingKeepsCharactersAndMarksCheckboxes() throws {
        let view = MarkdownTextView.make()
        let source = "# Heading\n**bold** and `code`\n- [ ] todo\n- [x] done\n"
        view.setMarkdown(source)
        XCTAssertEqual(view.string, source)

        let storage = try XCTUnwrap(view.textStorage)
        let headingFont = try XCTUnwrap(storage.attribute(.font, at: 2, effectiveRange: nil) as? NSFont)
        let bodyFont = try XCTUnwrap(storage.attribute(.font, at: (source as NSString).range(of: "and").location, effectiveRange: nil) as? NSFont)
        XCTAssertGreaterThan(headingFont.pointSize, bodyFont.pointSize)

        let unchecked = (source as NSString).range(of: "[ ]")
        XCTAssertEqual(storage.attribute(.offlineCheckbox, at: unchecked.location, effectiveRange: nil) as? Bool, false)
        let checked = (source as NSString).range(of: "[x]")
        XCTAssertEqual(storage.attribute(.offlineCheckbox, at: checked.location, effectiveRange: nil) as? Bool, true)
    }

    func testReturnContinuesAndEndsLists() {
        let view = MarkdownTextView.make()
        view.setMarkdown("- first")
        view.setSelectedRange(NSRange(location: 7, length: 0))
        view.insertNewline(nil)
        XCTAssertEqual(view.string, "- first\n- ")
        view.insertNewline(nil)
        XCTAssertEqual(view.string, "- first\n", "Return on an empty item ends the list")

        view.setMarkdown("plain")
        view.setSelectedRange(NSRange(location: 5, length: 0))
        view.insertNewline(nil)
        XCTAssertEqual(view.string, "plain\n")
    }

    func testLoadingANoteClearsUndoHistory() {
        let view = MarkdownTextView.make()
        view.setMarkdown("first note")
        view.insertText(" edited", replacementRange: NSRange(location: 10, length: 0))
        view.setMarkdown("second note")
        XCTAssertFalse(view.undoManager?.canUndo ?? false, "undo must never bring back another note's text")
    }

    func testTypographyChangeRestyles() throws {
        let view = MarkdownTextView.make()
        view.setMarkdown("body text")
        view.typography = EditorTypography(family: .monospaced, size: 20)
        let font = try XCTUnwrap(view.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        XCTAssertEqual(font.pointSize, 20)
        XCTAssertEqual(view.string, "body text")
    }
}
