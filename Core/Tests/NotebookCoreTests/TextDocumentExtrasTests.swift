import Foundation
import XCTest
@testable import NotebookCore

/// Manual page break, paper change, search over page changes and text moving
/// back. All against a fixed-width capacity: TextKit itself is a device test.
final class TextDocumentExtrasTests: XCTestCase {
    /// Whole words up to `width` characters, as a page's last line takes them.
    private static func words(_ width: Int) -> (Page, TextBox) throws -> Int {
        { _, box in
            let text = box.text as NSString
            guard text.length > width else { return text.length }
            let cut = text.range(of: " ", options: .backwards, range: NSRange(location: 0, length: width + 1))
            return cut.location == NSNotFound ? width : cut.location + 1
        }
    }
    private let layout = TextFlowLayout(capacity: TextDocumentExtrasTests.words(10))

    private func flowing(_ text: String, capacity: @escaping (Page, TextBox) throws -> Int = TextDocumentExtrasTests.words(10),
                         paper: PaperStyle = .blank, color: PaperColor = .white) throws -> Notebook {
        let document = try Notebook.textDocument(title: "Fluss", paper: paper, color: color)
        let first = try XCTUnwrap(document.textFlowSegments.first)
        var replacement = first.box; replacement.text = text; replacement.runs = nil
        return try document.reflowText(pageID: first.pageID, previous: first.box, replacement: replacement,
            selection: NSRange(location: 0, length: 0), pageCapacity: capacity).0
    }
    private func texts(_ document: Notebook) -> [String] { document.textFlowSegments.map(\.box.text) }

    // MARK: Page break

    func testAPageBreakEndsItsSegmentWhateverRoomThePageHas() throws {
        let document = try flowing("ab\u{0C}cd\u{0C}e")
        XCTAssertEqual(texts(document), ["ab\u{0C}", "cd\u{0C}", "e"])
        XCTAssertEqual(document.textFlowContent?.text, "ab\u{0C}cd\u{0C}e")
        XCTAssertEqual(document.schemaVersion, Notebook.textDocumentSchemaVersion)
        XCTAssertNoThrow(try document.validate())
    }

    func testInsertingAtTheEndOpensTheNextPageForTheCaret() throws {
        let document = try flowing("eins")
        let (next, focus) = try document.editingTextFlow(range: NSRange(location: 4, length: 0), replacement: TextLines.pageBreakText, layout: layout)
        XCTAssertEqual(texts(next), ["eins\u{0C}", ""])
        XCTAssertEqual(focus.pageID, next.pages[1].id)
        XCTAssertEqual(focus.selection, NSRange(location: 0, length: 0))
        XCTAssertEqual(next.textFlowPlace(at: 5)?.pageID, next.pages[1].id)
        XCTAssertEqual(next.textFlowEndFocus?.pageID, next.pages[1].id)
        XCTAssertEqual(next.exportedPageIDs(), next.pages.map(\.id), "the opened page belongs to the document")
        // Typing goes on there; the break stays one character of the flow.
        let (typed, caret) = try next.editingTextFlow(range: NSRange(location: 5, length: 0), replacement: "x", layout: layout)
        XCTAssertEqual(texts(typed), ["eins\u{0C}", "x"])
        XCTAssertEqual(typed.textFlowOffset(boxID: caret.boxID, location: caret.selection.location), 6)
    }

    func testDeletingTheBreakLikeACharacterJoinsThePages() throws {
        let document = try flowing("ab\u{0C}cd")
        XCTAssertEqual(document.pages.count, 2)
        let (next, focus) = try document.editingTextFlow(range: NSRange(location: 2, length: 1), replacement: "", caret: 2, layout: layout)
        XCTAssertEqual(texts(next), ["abcd"])
        XCTAssertEqual(next.pages.count, 1, "the page behind it held nothing else")
        XCTAssertEqual(focus.selection.location, 2)
    }

    func testABreakInTheMiddleMovesTheRestAndKeepsFormats() throws {
        var document = try flowing("ab cd ef gh ij")
        document = try document.restylingTextFlow(range: NSRange(location: 3, length: 2), layout: layout) { $0.bold = true }.0
        let (next, _) = try document.editingTextFlow(range: NSRange(location: 3, length: 0), replacement: TextLines.pageBreakText, layout: layout)
        XCTAssertEqual(texts(next), ["ab \u{0C}", "cd ef gh ", "ij"])
        XCTAssertTrue(try XCTUnwrap(next.textFlowContent).style(at: 4).bold)
    }

    func testTheCharacterChangesNothingInNotebooksAndSurvivesTheStoredForm() throws {
        var book = Notebook.blank(title: "Heft")
        var field = TextBox(text: "a\u{0C}b"); field.flowID = UUID(); field.flowRegion = .page
        book.pages[0].textBoxes = [field]; book.schemaVersion = 8
        let box = try XCTUnwrap(book.pages[0].textBoxes?.first)
        var longer = box; longer.text = "a\u{0C}bc"
        let (reflowed, _) = try book.reflowText(pageID: book.pages[0].id, previous: box, replacement: longer,
            selection: NSRange(location: 0, length: 0), capacity: { ($0.text as NSString).length })
        XCTAssertEqual(reflowed.pages.count, 1, "only text documents break pages")

        let document = try flowing("ab\u{0C}cd")
        let decoded = try NotebookDecoding.decode(try JSONEncoder().encode(document)).notebook
        XCTAssertEqual(decoded.textFlowContent?.text, "ab\u{0C}cd")
        XCTAssertEqual(decoded.schemaVersion, document.schemaVersion)
    }

    func testLinesAndParagraphsEndAtTheBreak() throws {
        let text = "- a\u{0C}- b\nc" as NSString
        XCTAssertEqual(TextLines.lineRange(text, NSRange(location: 1, length: 0)), NSRange(location: 0, length: 4))
        XCTAssertEqual(TextLines.lineRange(text, NSRange(location: 4, length: 0)), NSRange(location: 4, length: 4))
        XCTAssertEqual(TextLines.lineRange(text, NSRange(location: 1, length: 4)), NSRange(location: 0, length: 8))
        XCTAssertEqual(TextLines.paragraphRange(text, NSRange(location: 5, length: 0)), NSRange(location: 4, length: 4))
        XCTAssertEqual(TextLines.lineRange(text, NSRange(location: 9, length: 0)), NSRange(location: 8, length: 1))
        XCTAssertEqual(TextListEditing.newline(in: text as String, range: NSRange(location: 7, length: 0))?.replacement, "\n- ")
        let document = try flowing("1. a\u{0C}3. b")
        let (next, _) = try document.editingTextFlow(range: NSRange(location: 4, length: 0), replacement: "x", layout: layout)
        XCTAssertEqual(next.textFlowContent?.text, "1. ax\u{0C}2. b", "numbering runs on over a break")
    }

    func testTheOutlineEndsAHeadingBeforeItsBreak() throws {
        var document = try flowing("Kopf\u{0C}Kapitel")
        document = try document.restylingTextFlow(range: NSRange(location: 0, length: 4), layout: layout) { TextStylePreset.heading.apply(to: &$0) }.0
        document = try document.restylingTextFlow(range: NSRange(location: 5, length: 7), layout: layout) { TextStylePreset.heading.apply(to: &$0) }.0
        XCTAssertEqual(document.textOutline.map(\.text), ["Kopf", "Kapitel"])
        XCTAssertEqual(document.textOutline[0].range, NSRange(location: 0, length: 4))
        XCTAssertEqual(document.textOutline[1].pageIndex, 1)
    }

    func testAnOpenTaskEndsBeforeTheBreak() throws {
        XCTAssertEqual(TextListEditing.taskItems(in: "☐ offen\u{0C}☑ fertig").map(\.body), [NSRange(location: 2, length: 5), NSRange(location: 10, length: 6)])
    }

    func testTheKeyboardCursorStopsBeforeTheBreakOnItsLine() {
        let text = "ab\u{0C}cd" as NSString
        let line = DocumentTextLine(page: 0, range: NSRange(location: 0, length: 3), rect: PageRect(x: 0, y: 0, width: 100, height: 20),
                                    used: PageRect(x: 0, y: 0, width: 20, height: 20), baseline: 14, ascent: 14, descent: 4)
        XCTAssertEqual(line.clamped(3, in: text), 2)
    }

    func testBreaksInTextAndMarkdownExports() throws {
        var document = try flowing("eins\u{0C}zwei\n\u{0C}drei\u{0C}")
        XCTAssertEqual(texts(document), ["eins\u{0C}", "zwei\n\u{0C}", "drei\u{0C}", ""])
        XCTAssertEqual(TextDocumentExport.plainText(document), "eins\n\u{0C}\nzwei\n\n\u{0C}\ndrei\n")
        XCTAssertEqual(TextDocumentExport.markdown(document), "eins\n\n---\n\nzwei\n\n---\n\ndrei\n")
        document = try document.editingTextFlow(range: NSRange(location: 0, length: 16), replacement: "", layout: layout).0
        XCTAssertEqual(document.textFlowContent?.text, "")
    }

    func testTheNewCommandsHaveTheirKeys() {
        XCTAssertEqual(HelixKeymap.binding("<Space> b", in: .text)?.action, .pageBreak)
        XCTAssertNil(HelixKeymap.binding("<Space> b", in: .page))
        for context: HelixContext in [.library, .page, .text] {
            XCTAssertEqual(HelixKeymap.binding("<Space> e w", in: context)?.action, .export(.word))
            XCTAssertEqual(HelixKeymap.binding("<Space> e r", in: context)?.action, .export(.rtf))
        }
        XCTAssertTrue(HelixKeymap.commands(in: .text).contains { $0.action == .pageBreak }, "the palette lists it")
    }

    // MARK: Word and RTF

    private func office() throws -> Notebook {
        var document = try flowing("Titel\nKapitel\nAbschnitt\nFett kursiv unter strich rot gelb Link\n• Punkt\n    ◦ tief\n3. drei\n4. vier\n☐ offen\n☑ fertig\nKlein\u{0C}Weiter & <mehr>\tTab")
        func format(_ text: String, _ change: (inout TextBoxStyle) -> Void) throws {
            let content = try XCTUnwrap(document.textFlowContent)
            let range = (content.text as NSString).range(of: text)
            document = try document.restylingTextFlow(range: range, layout: layout, change: change).0
        }
        try format("Titel") { TextStylePreset.title.apply(to: &$0) }
        try format("Kapitel") { TextStylePreset.heading.apply(to: &$0) }
        try format("Abschnitt") { TextStylePreset.subheading.apply(to: &$0) }
        try format("Klein") { TextStylePreset.caption.apply(to: &$0) }
        try format("Fett") { $0.bold = true }
        try format("kursiv") { $0.italic = true }
        try format("unter") { $0.underline = true }
        try format("strich") { $0.strikethrough = true }
        try format("rot") { $0.color = .red; $0.automaticColor = nil }
        try format("gelb") { $0.highlighted = true }
        try format("Link") { $0.link = "https://example.org/?a=1&b=2" }
        let content = try XCTUnwrap(document.textFlowContent), tief = (content.text as NSString).range(of: "tief")
        let line = TextLines.lineRange(content.text as NSString, tief)
        return try document.restylingTextFlow(range: line, layout: layout) { $0.indent = TextPlacement.indentStep }.0
    }
    /// Entries of a stored ZIP, walked by its central directory.
    private func entries(_ data: Data) throws -> [String: String] {
        let bytes = [UInt8](data)
        func u16(_ at: Int) -> Int { Int(bytes[at]) | Int(bytes[at + 1]) << 8 }
        func u32(_ at: Int) -> Int { u16(at) | u16(at + 2) << 16 }
        let end = bytes.count - 22
        XCTAssertEqual(u32(end), 0x0605_4B50)
        var result: [String: String] = [:], place = u32(end + 16)
        for _ in 0..<u16(end + 10) {
            XCTAssertEqual(u32(place), 0x0201_4B50)
            let size = u32(place + 24), name = u16(place + 28), offset = u32(place + 42)
            let key = String(decoding: bytes[(place + 46)..<(place + 46 + name)], as: UTF8.self)
            let body = offset + 30 + u16(offset + 26) + u16(offset + 28)
            XCTAssertEqual(StreamingCRC32.checksum(Data(bytes[body..<(body + size)])), UInt32(u32(place + 16)))
            result[key] = String(decoding: bytes[body..<(body + size)], as: UTF8.self)
            place += 46 + name
        }
        return result
    }

    func testWordHoldsParagraphStylesFormatsListsAndBreaks() throws {
        let parts = try entries(TextDocumentExport.word(try office()))
        XCTAssertEqual(Set(parts.keys), ["[Content_Types].xml", "_rels/.rels", "docProps/core.xml", "word/_rels/document.xml.rels",
                                         "word/document.xml", "word/styles.xml", "word/numbering.xml", "word/settings.xml"])
        let body = try XCTUnwrap(parts["word/document.xml"])
        for id in ["Title", "Heading1", "Heading2", "Caption"] {
            XCTAssertTrue(body.contains("<w:pStyle w:val=\"\(id)\"/>"), id)
            XCTAssertTrue(try XCTUnwrap(parts["word/styles.xml"]).contains("w:styleId=\"\(id)\""), id)
        }
        for element in ["<w:b/>", "<w:i/>", "<w:u w:val=\"single\"/>", "<w:strike/>", "<w:color w:val=\"CC1F1F\"/>", "<w:highlight w:val=\"yellow\"/>",
                        "<w:br w:type=\"page\"/>", "<w:tab/>", "Weiter &amp; &lt;mehr&gt;", "<w:hyperlink r:id=\"rIdLink1\""] {
            XCTAssertTrue(body.contains(element), element)
        }
        XCTAssertTrue(try XCTUnwrap(parts["word/_rels/document.xml.rels"]).contains("Target=\"https://example.org/?a=1&amp;b=2\" TargetMode=\"External\""))
        // List markers are structure: no text, one list for the bullets, the first number stays.
        XCTAssertFalse(body.contains("• Punkt"))
        XCTAssertTrue(body.contains("<w:ilvl w:val=\"1\"/><w:numId w:val=\"1\"/>"), "the nested bullet")
        XCTAssertTrue(body.contains("<w:numId w:val=\"3\"/>") && body.contains("<w:numId w:val=\"4\"/>"), "checklists")
        XCTAssertTrue(try XCTUnwrap(parts["word/numbering.xml"]).contains("<w:startOverride w:val=\"3\"/>"))
        XCTAssertEqual(body.components(separatedBy: "<w:numId w:val=\"5\"/>").count, 3, "3. and 4. are one list")
        XCTAssertFalse(body.contains("\u{0C}"))
    }

    func testWordAndRTFFollowTheTextExport() throws {
        var document = try flowing("Fluss")
        var field = TextBox(x: 40, y: 200, width: 200, height: 30, text: "Feld")
        field.style.italic = true
        document.pages[0].textBoxes = (document.pages[0].textBoxes ?? []) + [field]
        document.pages[0].drawing = Data([1])
        let body = try XCTUnwrap(entries(TextDocumentExport.word(document))["word/document.xml"])
        let flow = try XCTUnwrap(body.range(of: "Fluss")), free = try XCTUnwrap(body.range(of: "Feld"))
        XCTAssertLessThan(flow.lowerBound, free.lowerBound)
        XCTAssertTrue(TextDocumentExport.leavesOutContent(of: document), "the app says what is missing")
        XCTAssertFalse(TextDocumentExport.leavesOutContent(of: try flowing("Nur Text")))

        let empty = try Notebook.textDocument(title: "Leer")
        XCTAssertTrue(TextDocumentExport.data(empty, as: .word).isEmpty)
        XCTAssertTrue(TextDocumentExport.data(empty, as: .rtf).isEmpty)
        XCTAssertEqual(TextDocumentExport.Format.word.fileExtension, "docx")
        XCTAssertEqual(TextDocumentExport.Format.rtf.fileExtension, "rtf")
        let same = TextDocumentExport.word(document)
        XCTAssertEqual(same, TextDocumentExport.word(document), "no time stamps")
    }

    func testRTFCarriesFormatsAndEscapes() throws {
        let rtf = TextDocumentExport.rtf(try office())
        XCTAssertTrue(rtf.hasPrefix("{\\rtf1"))
        XCTAssertTrue(rtf.hasSuffix("}\n"))
        for part in ["\\page", "\\b", "\\i", "\\ul", "\\strike", "\\highlight", "\\red204\\green31\\blue31;", "HYPERLINK", "\\u9744?", "\\tab ", "Weiter & <mehr>"] {
            XCTAssertTrue(rtf.contains(part), part)
        }
        XCTAssertEqual(rtf.filter { $0 == "{" }.count, rtf.filter { $0 == "}" }.count)
        XCTAssertTrue(rtf.utf8.allSatisfy { $0 < 128 }, "RTF is plain ASCII")
    }

    func testZipStoreWritesAReadableContainer() throws {
        let data = ZipStore.archive([("a.txt", Data("eins".utf8)), ("ordner/ü.txt", Data("zwei".utf8))])
        XCTAssertEqual(try entries(data), ["a.txt": "eins", "ordner/ü.txt": "zwei"])
    }

    // MARK: Paper

    /// Lined paper takes less: the ruling moves the lines.
    private let paperCapacity: (Page, TextBox) throws -> Int = { page, box in
        try TextDocumentExtrasTests.words(page.paper == .lined ? 7 : 10)(page, box)
    }

    func testPaperChangesTogetherAndTheTextFlowsAnew() throws {
        var document = try flowing("aaaa bbbb cccc dddd", capacity: paperCapacity)
        document.pages[1].drawing = Data([9])
        let inked = document.pages[1].id
        let changed = try document.changingTextDocumentPaper(.lined, color: .white, layout: TextFlowLayout(capacity: paperCapacity))
        XCTAssertEqual(changed.textFlowContent?.text, "aaaa bbbb cccc dddd", "nothing is cut off")
        XCTAssertEqual(texts(changed), ["aaaa ", "bbbb ", "cccc ", "dddd"])
        XCTAssertTrue(changed.pages.allSatisfy { $0.paper == .lined })
        XCTAssertEqual(changed.appearance?.paper, .lined)
        XCTAssertEqual(changed.writingDraft().paper, .lined, "the reserve page follows")
        XCTAssertEqual(changed.pages.first { $0.id == inked }?.drawing, Data([9]))
        XCTAssertEqual(changed.pages.firstIndex { $0.id == inked }, 1, "handwriting stays on its page")
        XCTAssertNoThrow(try changed.validate())
    }

    func testPaperNeverStopsAtAPageThatKeptItsLength() throws {
        // The first page keeps its length, later ones take less: only with
        // every page measured do they move.
        let capacity: (Page, TextBox) throws -> Int = { page, box in
            let tight = page.paper == .lined && (box.text as NSString).length < 15
            return try TextDocumentExtrasTests.words(tight ? 5 : 10)(page, box)
        }
        let document = try flowing("aaaa bbbb ccc dd eee ff", capacity: capacity)
        let changed = try document.changingTextDocumentPaper(.lined, color: .white, layout: TextFlowLayout(capacity: capacity))
        XCTAssertEqual(texts(changed), ["aaaa bbbb ", "ccc ", "dd ", "eee ", "ff"])
    }

    func testPaperColourTurnsAutomaticTextAndAsksForTheInk() throws {
        var document = try flowing("hell und dunkel")
        document.pages[0].drawing = Data([1])
        XCTAssertThrowsError(try document.changingTextDocumentPaper(.blank, color: .dark, layout: layout), "ink needs the app")
        var asked = 0
        let changed = try document.changingTextDocumentPaper(.grid, color: .dark, layout: layout) { data, _ in asked += 1; return data }
        XCTAssertEqual(asked, 1)
        XCTAssertTrue(changed.pages.allSatisfy { $0.paper == .grid && $0.paperColor == .dark })
        XCTAssertEqual(changed.textFlowSegments.first?.box.style.color, .white)
        XCTAssertEqual(changed.appearance?.color, .dark)
    }

    func testPaperThatFindsNoRoomChangesNothing() throws {
        let document = try flowing("aaaa bbbb", capacity: paperCapacity)
        XCTAssertThrowsError(try document.changingTextDocumentPaper(.lined, color: .white, layout: TextFlowLayout(capacity: { _, _ in 0 })))
        XCTAssertEqual(document.pages[0].paper, .blank)
    }

    func testPaperIsOneUndoStep() throws {
        let document = try flowing("aaaa bbbb cccc dddd", capacity: paperCapacity)
        let changed = try document.changingTextDocumentPaper(.lined, color: .dark, layout: TextFlowLayout(capacity: paperCapacity))
        var history = NotebookUndoHistory()
        XCTAssertTrue(history.recordPages(before: document, after: changed, undoPageID: document.pages[0].id, redoPageID: changed.pages[0].id))
        let undone = try XCTUnwrap(history.undo(changed)).notebook
        XCTAssertEqual(undone, document)
        XCTAssertFalse(history.canUndo)
        XCTAssertEqual(try XCTUnwrap(history.redo(undone)).notebook, changed)
    }

    func testNotebooksHaveNoPaperChangeOfThisKind() {
        XCTAssertThrowsError(try Notebook.blank(title: "Heft").changingTextDocumentPaper(.lined, color: .white, layout: layout))
    }

    // MARK: Search over a page change

    private func hits(_ document: Notebook) -> [ContentSearchHit] {
        let pages = ContentSearchPlanner.prepare(document)
        return pages.enumerated().flatMap { index, page in
            ContentSearchPlanner.hits(SearchPageRecord(pageID: page.pageID, text: page.text), pageNumber: index + 1, documentID: document.id, title: document.title)
        }
    }

    func testAPhraseOverAPageChangeIsFoundOnThePageItStarts() throws {
        let document = try flowing("eins zwei drei vier fünf")
        XCTAssertEqual(texts(document), ["eins zwei ", "drei vier ", "fünf"])
        let found = hits(document).filter { $0.matches("zwei drei") }
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found[0].pageNumber, 1)
        XCTAssertEqual(found[0].crossingRange("zwei drei"), NSRange(location: 5, length: 9))
        XCTAssertEqual(found[0].crossingRange("ZWEI  drei"), NSRange(location: 5, length: 9), "case and spaces do not count")
        XCTAssertEqual(hits(document).filter { $0.matches("vier funf") }.count, 1, "diacritics neither")
    }

    func testAPhraseOnOnePageStaysThatPagesOwnHit() throws {
        let document = try flowing("eins zwei drei vier fünf")
        XCTAssertEqual(hits(document).filter { $0.matches("drei vier") }.map(\.pageNumber), [2])
        XCTAssertEqual(hits(document).filter { $0.matches("eins") }.count, 1)
        XCTAssertNil(hits(document).first { $0.seam != nil }?.crossingRange("eins"))
    }

    func testAManualBreakAndALineBreakReadAsASpace() throws {
        let document = try flowing("eins\u{0C}zwei\ndrei")
        XCTAssertEqual(hits(document).filter { $0.matches("eins zwei") }.first?.crossingRange("eins zwei"), NSRange(location: 0, length: 9))
    }

    func testSeamsOnlyInTextDocuments() throws {
        var book = Notebook.blank(title: "Heft")
        book.pages[0].textBoxes = [TextBox(text: "eins")]; book.schemaVersion = 4
        XCTAssertTrue(ContentSearchPlanner.seamLines(book).isEmpty)
        let last = try flowing("nur eine").pages[0].id
        XCTAssertNil(ContentSearchPlanner.seamLines(try flowing("nur eine"))[last])
    }

    func testAnOlderIndexLineStillDecodes() throws {
        let line = try JSONDecoder().decode(SearchLine.self, from: Data(#"{"text":"a","kind":"text","bounds":{"x":0,"y":0,"width":1,"height":1}}"#.utf8))
        XCTAssertNil(line.seam)
    }

    func testTheKeyboardSearchRunsOverPagesAndBreaks() throws {
        let document = try flowing("eins zwei drei\u{0C}vier")
        var engine = TextEngine(text: try XCTUnwrap(document.textFlowContent?.text), mode: .normal)
        _ = engine.search("zwei drei")
        XCTAssertEqual(engine.selectedRange, NSRange(location: 5, length: 9))
        XCTAssertEqual(document.textFlowParts(of: engine.selectedRange).count, 2, "marked on both pages")
        _ = engine.search("drei vier")
        XCTAssertEqual(engine.selectedRange, NSRange(location: 10, length: 9), "a phrase reads on over a manual break")
    }

    // MARK: Moving back

    func testOnlyTheFirstWordCanBringTextBack() {
        XCTAssertTrue(Notebook.reachesFirstWord(from: "Wortkette und", to: "Wort und"))
        XCTAssertTrue(Notebook.reachesFirstWord(from: "Wortkette und", to: "Wort kette und"))
        XCTAssertTrue(Notebook.reachesFirstWord(from: "  Wort und", to: " Wort und"))
        XCTAssertFalse(Notebook.reachesFirstWord(from: "Wort und mehr", to: "Wort und meh"))
        XCTAssertFalse(Notebook.reachesFirstWord(from: "Wort", to: "Wort"))
    }

    func testAShortenedFirstWordMovesBackAndTheCaretGoesWithIt() throws {
        var document = try flowing("aaaa bb cccccc dd")
        XCTAssertEqual(texts(document), ["aaaa bb ", "cccccc dd"])
        // The first word of page two gets shorter: page two alone reflows, as typing does.
        let second = document.textFlowSegments[1]
        var shorter = second.box; shorter.text = "cc dd"; shorter.runs = nil
        (document, _) = try document.reflowText(pageID: second.pageID, previous: second.box, replacement: shorter,
            selection: NSRange(location: 2, length: 0), pageCapacity: Self.words(10))
        XCTAssertEqual(texts(document), ["aaaa bb ", "cc dd"], "typing itself moves nothing back")
        let (settled, focus) = try XCTUnwrap(try document.settlingTextFlow(boxID: second.box.id, selection: NSRange(location: 10, length: 0), layout: layout))
        XCTAssertEqual(texts(settled), ["aaaa bb cc ", "dd"])
        XCTAssertEqual(focus.pageID, settled.pages[0].id, "the caret stays behind its word")
        XCTAssertEqual(settled.textFlowOffset(boxID: focus.boxID, location: focus.selection.location), 10)
        XCTAssertNoThrow(try settled.validate())
    }

    func testNothingMovesWhenTheWordStillDoesNotFitAndNothingMoreIsMeasured() throws {
        let document = try flowing("aaaa bb cccccc dd")
        var measured = 0
        let counting = TextFlowLayout(capacity: { page, box in measured += 1; return try Self.words(10)(page, box) })
        XCTAssertNil(try document.settlingTextFlow(boxID: document.textFlowSegments[1].box.id, selection: nil, layout: counting))
        XCTAssertEqual(measured, 1, "only the page before")
        XCTAssertNil(try document.settlingTextFlow(boxID: document.textFlowSegments[0].box.id, selection: nil, layout: counting), "the first page has none")
    }

    func testAPageBreakHoldsTheTextOnItsPage() throws {
        let document = try flowing("aa\u{0C}bb")
        XCTAssertNil(try document.settlingTextFlow(boxID: document.textFlowSegments[1].box.id, selection: nil, layout: layout))
    }

    func testAWholeTextEditMovesBackAndMeasuresOnlyThePagesItReaches() throws {
        // Editor 2: 50 pages, an edit on page 25 that keeps its boundaries.
        let page = "aaaa bbbb "
        let document = try flowing(String(repeating: page, count: 50))
        XCTAssertEqual(document.pages.count, 50)
        var measured = 0
        let counting = TextFlowLayout(capacity: { page, box in measured += 1; return try Self.words(10)(page, box) })
        let (typed, _) = try document.changingTextFlow(TextFlowChange(edits: [TextListEditing.Edit(range: NSRange(location: 243, length: 1), replacement: "c")],
            selection: NSRange(location: 244, length: 0), selectionBefore: NSRange(location: 243, length: 0)), layout: counting)
        XCTAssertEqual(typed.pages.count, 50)
        XCTAssertLessThanOrEqual(measured, 2, "the page before and the edited one")
        // A shortened first word goes back at once on this way.
        let (shorter, focus) = try document.changingTextFlow(TextFlowChange(edits: [TextListEditing.Edit(range: NSRange(location: 241, length: 3), replacement: "")],
            selection: NSRange(location: 241, length: 0), selectionBefore: NSRange(location: 244, length: 0)), layout: layout)
        XCTAssertEqual(shorter.textFlowContent.map { ($0.text as NSString).length }, 497)
        XCTAssertEqual(shorter.textFlowOffset(boxID: focus.boxID, location: focus.selection.location), 241)
        XCTAssertNoThrow(try shorter.validate())
    }
}
