import XCTest
@testable import OfflineCore

final class MarkdownParserTests: XCTestCase {
    private func elements(_ text: String, _ wanted: (MarkdownElement) -> Bool) -> [String] {
        MarkdownParser.spans(in: text)
            .filter { wanted($0.element) }
            .map { (text as NSString).substring(with: $0.range) }
    }

    private func texts(_ text: String, _ element: MarkdownElement) -> [String] {
        elements(text) { $0 == element }
    }

    func testHeadings() {
        let text = "# One\n### Three\n#NotAHeading\n####### seven"
        XCTAssertEqual(texts(text, .heading(level: 1)), ["# One"])
        XCTAssertEqual(texts(text, .heading(level: 3)), ["### Three"])
        XCTAssertEqual(MarkdownParser.spans(in: text).filter {
            if case .heading = $0.element { return true } else { return false }
        }.count, 2)
    }

    func testEmphasis() {
        let text = "a **bold** b *it* c _it2_ d __b2__ e ~~gone~~ snake_case_word 2 * 3 * 4"
        XCTAssertEqual(texts(text, .bold), ["**bold**", "__b2__"])
        XCTAssertEqual(texts(text, .italic), ["*it*", "_it2_"])
        XCTAssertEqual(texts(text, .strikethrough), ["~~gone~~"])
    }

    func testCodeIsNotStyledInside() {
        let text = "use `**not bold**` here\n```\n# not heading\n*x*\n```\nafter *yes*"
        XCTAssertEqual(texts(text, .inlineCode), ["`**not bold**`"])
        XCTAssertEqual(texts(text, .bold), [])
        XCTAssertEqual(texts(text, .codeBlock), ["```", "# not heading", "*x*", "```"])
        XCTAssertEqual(texts(text, .italic), ["*yes*"])
        XCTAssertEqual(texts(text, .heading(level: 1)), [])
    }

    func testListsAndCheckboxes() {
        let text = "- plain\n  * nested\n1. first\n- [ ] todo\n- [x] done item\n-not a list"
        XCTAssertEqual(texts(text, .listMarker), ["-", "*", "1.", "-", "-"])
        XCTAssertEqual(texts(text, .checkbox(checked: false)), ["[ ]"])
        XCTAssertEqual(texts(text, .checkbox(checked: true)), ["[x]"])
        XCTAssertEqual(texts(text, .completedTask), ["done item"])
    }

    func testLinksAndImages() {
        let id = UUID()
        let text = "see [site](https://example.com/a_b_c) and https://bare.example/x_y_z. \(AttachmentReference.token(id: id, alt: "pic"))"
        let links = MarkdownParser.spans(in: text).compactMap { span -> String? in
            if case .link(let destination) = span.element { return destination } else { return nil }
        }
        XCTAssertEqual(links, ["attachment:\(id.uuidString)", "https://example.com/a_b_c", "https://bare.example/x_y_z."])
        XCTAssertEqual(texts(text, .italic), [], "underscores inside URLs are not emphasis")
    }

    func testBlockquoteAndRangesStayInBounds() {
        let text = "> quoted *text*\r\nnext 🙂 **b**\n\n"
        XCTAssertEqual(texts(text, .blockquote), ["> quoted *text*"])
        XCTAssertEqual(texts(text, .bold), ["**b**"])
        let length = (text as NSString).length
        for span in MarkdownParser.spans(in: text) {
            XCTAssertTrue(span.range.location >= 0 && NSMaxRange(span.range) <= length)
        }
        XCTAssertTrue(MarkdownParser.spans(in: "").isEmpty)
    }
}

final class MarkdownEditingTests: XCTestCase {
    func testReturnContinuesLists() {
        XCTAssertEqual(MarkdownEditing.returnAction(forLine: "- milk"), .continueList(prefix: "- "))
        XCTAssertEqual(MarkdownEditing.returnAction(forLine: "  * nested"), .continueList(prefix: "  * "))
        XCTAssertEqual(MarkdownEditing.returnAction(forLine: "9. ninth"), .continueList(prefix: "10. "))
        XCTAssertEqual(MarkdownEditing.returnAction(forLine: "- [x] done"), .continueList(prefix: "- [ ] "))
        XCTAssertEqual(MarkdownEditing.returnAction(forLine: "- "), .endList)
        XCTAssertEqual(MarkdownEditing.returnAction(forLine: "- [ ] "), .endList)
        XCTAssertNil(MarkdownEditing.returnAction(forLine: "plain text"))
        XCTAssertNil(MarkdownEditing.returnAction(forLine: "-no space"))
    }

    func testCheckboxToggleAndWordCount() {
        XCTAssertEqual(MarkdownEditing.toggledCheckbox("[ ]"), "[x]")
        XCTAssertEqual(MarkdownEditing.toggledCheckbox("[x]"), "[ ]")
        XCTAssertEqual(MarkdownEditing.toggledCheckbox("[X]"), "[ ]")
        XCTAssertEqual(MarkdownEditing.wordCount(""), 0)
        XCTAssertEqual(MarkdownEditing.wordCount("  one, two — don't  3rd\n\n# four "), 5)
    }

    func testSearchTermRanges() {
        let ranges = MarkdownEditing.ranges(of: ["cafe", "x"], in: "Café CAFE x")
        XCTAssertEqual(ranges, [NSRange(location: 0, length: 4), NSRange(location: 5, length: 4), NSRange(location: 10, length: 1)])
        XCTAssertTrue(MarkdownEditing.ranges(of: [""], in: "abc").isEmpty)
    }

    func testAttachmentReferencesAndImageSniffing() {
        let id = UUID()
        let text = "a \(AttachmentReference.token(id: id, alt: "x]y")) b ![no](attachment:not-a-uuid)"
        let found = AttachmentReference.findAll(in: text)
        XCTAssertEqual(found.map(\.id), [id])
        XCTAssertEqual(found.first?.alt, "xy")
        XCTAssertEqual(ImageType.sniffMimeType(fakePNG()), "image/png")
        XCTAssertEqual(ImageType.sniffMimeType(Data([0xFF, 0xD8, 0xFF, 0xE0])), "image/jpeg")
        XCTAssertEqual(ImageType.sniffMimeType(Data([0, 0, 0, 0x18] + Array("ftypheic".utf8))), "image/heic")
        XCTAssertNil(ImageType.sniffMimeType(Data("GIF89a".utf8)))
    }
}
