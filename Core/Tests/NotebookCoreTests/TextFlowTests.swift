import XCTest
@testable import NotebookCore

final class TextFlowTests: XCTestCase {
    private func sample(_ text: String = "") throws -> (Notebook, TextBox) {
        var book = try Notebook.blank(title: "Flow", appearance: NotebookAppearance())
        let rect = try XCTUnwrap(book.pages[0].writingRect(.page))
        var box = TextBox(x: rect.x, y: rect.y, width: rect.width, height: rect.height, text: text)
        box.flowID = UUID(); box.flowRegion = .page
        try book.replaceTextBoxes([box], pageID: book.pages[0].id)
        return (book, box)
    }
    func testFlowTextStartsWithRuledLinesAndOlderTextAlignsOnEdit() throws {
        var book = try Notebook.blank(title: "Flow", appearance: NotebookAppearance())
        let rect = try XCTUnwrap(book.pages[0].writingRect(.page))
        let legacy = try XCTUnwrap(book.pages[0].legacyWritingRect(.page))
        XCTAssertEqual(rect.x, 32); XCTAssertEqual(legacy.x, 16)
        XCTAssertEqual(rect.width, legacy.width - 32, accuracy: 0.001)
        XCTAssertEqual(rect.y, legacy.y); XCTAssertEqual(rect.height, legacy.height)
        var box = TextBox(x: legacy.x, y: legacy.y, width: legacy.width, height: legacy.height, text: "alt")
        box.flowID = UUID(); box.flowRegion = .page
        try book.replaceTextBoxes([box], pageID: book.pages[0].id)
        var replacement = box; replacement.text = "alt!"
        let (next, _) = try book.reflowText(pageID: book.pages[0].id, previous: box, replacement: replacement,
            selection: NSRange(location: 4, length: 0), pageCapacity: { _, _ in 1000 })
        let edited = try XCTUnwrap(next.pages[0].effectiveTextBoxes.first)
        XCTAssertEqual(edited.x, rect.x); XCTAssertEqual(edited.width, rect.width); XCTAssertEqual(edited.text, "alt!")
    }
    func testPaperAndPDFMarginsHaveDistinctAnchors() throws {
        var page = Page(); page.geometry = PaperStyle.geometry
        page.margins = PageMargins(left: 180, right: 260, top: 100, bottom: 120)
        XCTAssertNil(page.writingRegion(at: .init(x: 100, y: 100), hasPDF: true))
        XCTAssertEqual(page.writingRegion(at: .init(x: 100, y: 100), hasPDF: false), .page)
        XCTAssertEqual(page.writingRegion(at: .init(x: 600, y: 100), hasPDF: true), .right)
        XCTAssertEqual(page.writingRegion(at: .init(x: -20, y: 100), hasPDF: true), .left)
        XCTAssertLessThan(try XCTUnwrap(page.writingRect(.left)).x, 0)
        XCTAssertGreaterThan(try XCTUnwrap(page.writingRect(.right)).x, 595)
        XCTAssertEqual(page.writingRegion(at: .init(x: 10, y: -30), hasPDF: true), .top)
        XCTAssertEqual(page.writingRegion(at: .init(x: 10, y: 900), hasPDF: true), .bottom)
        page.margins = nil; XCTAssertNil(page.writingRect(.right))
    }
    func testOverflowCreatesStableContinuationAndMovesCaretOnlyThere() throws {
        let (book, previous) = try sample()
        var replacement = previous; replacement.text = "abcdefghij"
        let draft = book.writingDraft()
        let (next, focus) = try book.reflowText(pageID: book.pages[0].id, previous: previous, replacement: replacement,
            selection: NSRange(location: 10, length: 0), trailingDraft: draft, capacity: { _ in 4 })
        XCTAssertEqual(next.pages.count, 3)
        XCTAssertEqual(next.pages[1].id, draft.id)
        XCTAssertEqual(next.pages.map { $0.textBoxes![0].text }, ["abcd", "efgh", "ij"])
        XCTAssertEqual(focus.pageID, next.pages[2].id); XCTAssertEqual(focus.selection.location, 2)
        XCTAssertEqual(Set(next.pages.flatMap { $0.textBoxes!.compactMap(\.flowID) }), [previous.flowID!])
        XCTAssertEqual(book.pages.count, 1); XCTAssertEqual(book.pages[0].textBoxes![0].text, "")
    }
    func testTypingWithoutMovingABoundaryMeasuresOnlyTheEditedSegment() throws {
        let (book, previous) = try sample()
        var replacement = previous; replacement.text = "abcdefghij"
        let (flowing, _) = try book.reflowText(pageID: book.pages[0].id, previous: previous, replacement: replacement,
            selection: NSRange(location: 10, length: 0), capacity: { _ in 4 })
        XCTAssertEqual(flowing.pages.map { $0.textBoxes![0].text }, ["abcd", "efgh", "ij"])
        // Same length in the first segment: the stored tail still matches.
        let first = flowing.pages[0].textBoxes![0]
        var typed = first; typed.text = "aBcd"
        var measured = 0
        let (same, focus) = try flowing.reflowText(pageID: flowing.pages[0].id, previous: first, replacement: typed,
            selection: NSRange(location: 2, length: 0), capacity: { _ in measured += 1; return 4 })
        XCTAssertEqual(measured, 1)
        XCTAssertEqual(same.pages.map { $0.textBoxes![0].text }, ["aBcd", "efgh", "ij"])
        XCTAssertEqual(same.pages.map(\.id), flowing.pages.map(\.id))
        XCTAssertEqual(focus.pageID, same.pages[0].id); XCTAssertEqual(focus.selection.location, 2)
        // A moved boundary still reflows every following segment.
        var inserted = first; inserted.text = "aXbcd"
        measured = 0
        let (moved, movedFocus) = try flowing.reflowText(pageID: flowing.pages[0].id, previous: first, replacement: inserted,
            selection: NSRange(location: 2, length: 0), capacity: { _ in measured += 1; return 4 })
        XCTAssertEqual(measured, 3)
        XCTAssertEqual(moved.pages.map { $0.textBoxes![0].text }, ["aXbc", "defg", "hij"])
        XCTAssertEqual(movedFocus.pageID, moved.pages[0].id)
        // A formatted tail keeps its stored character styles.
        var styled = flowing.pages[1].textBoxes![0]; styled.style.bold = true
        var restyled = flowing; restyled.pages[1].textBoxes = [styled]
        measured = 0
        let (rewritten, _) = try restyled.reflowText(pageID: restyled.pages[0].id, previous: first, replacement: typed,
            selection: NSRange(location: 2, length: 0), capacity: { _ in measured += 1; return 4 })
        XCTAssertEqual(rewritten.pages.map { $0.textBoxes![0].text }, ["aBcd", "efgh", "ij"])
        XCTAssertEqual(rewritten.pages[1].textBoxes![0].styleRuns, styled.styleRuns)
        XCTAssertEqual(measured, 1, "same text and character styles: the tail is kept as stored")
    }
    func testReflowPullsFollowingTextBackWithoutDeletingPagesOrChangingInk() throws {
        let (book, previous) = try sample()
        var replacement = previous; replacement.text = "abcdefgh"
        var (next, _) = try book.reflowText(pageID: book.pages[0].id, previous: previous, replacement: replacement,
            selection: .init(location: 8, length: 0), capacity: { _ in 4 })
        next.pages[1].drawing = Data([1,2,3])
        let first = next.pages[0].textBoxes![0]
        var shortened = first; shortened.text = "a"; shortened.runs = nil
        let (short, focus) = try next.reflowText(pageID: next.pages[0].id, previous: first, replacement: shortened,
            selection: .init(location: 1, length: 0), capacity: { _ in 10 })
        XCTAssertEqual(short.pages.count, 2); XCTAssertEqual(short.pages[0].textBoxes![0].text, "aefgh")
        XCTAssertEqual(short.pages[1].textBoxes![0].text, ""); XCTAssertEqual(short.pages[1].drawing, Data([1,2,3]))
        XCTAssertEqual(focus.pageID, short.pages[0].id); XCTAssertEqual(focus.selection.location, 1)
    }
    func testDoesNotWriteBodyOverNextPDFOrOccupiedPage() throws {
        var (book, previous) = try sample()
        var occupied = book.writingDraft(); occupied.drawing = Data([9]); occupied.textBoxes = []; book.pages.append(occupied)
        var replacement = previous; replacement.text = "abcde"
        let (next, _) = try book.reflowText(pageID: book.pages[0].id, previous: previous, replacement: replacement,
            selection: .init(location: 5, length: 0), capacity: { _ in 4 })
        XCTAssertEqual(next.pages.count, 3); XCTAssertEqual(next.pages[2], occupied)
        XCTAssertEqual(next.pages[1].textBoxes![0].text, "e")
        var (pdfBook, pdfPrevious) = try sample()
        _ = try pdfBook.insertPDF(Data([4,5,6]), geometries: [PaperStyle.geometry], at: 1)
        pdfBook = try pdfBook.preparedForTextEditing()
        let originalPDF = pdfBook.pages[1]
        var pdfReplacement = pdfPrevious; pdfReplacement.text = "abcde"
        let (continued, _) = try pdfBook.reflowText(pageID: pdfBook.pages[0].id, previous: pdfPrevious, replacement: pdfReplacement,
            selection: .init(location: 5, length: 0), capacity: { _ in 4 })
        XCTAssertEqual(continued.pages[2], originalPDF)
        XCTAssertEqual(continued.pdfSources, pdfBook.pdfSources)
    }
    func testMarginContinuesInMatchingPDFMarginThenOnCleanPaper() throws {
        var book = Notebook(); book.pdf = Data([1,2]); book.pages = [Page(), Page()]
        book = try book.preparedForTextEditing()
        try book.setMargins(PageMargins(right: 240), pageIDs: book.pages.map(\.id))
        let rect = try XCTUnwrap(book.pages[0].writingRect(.right))
        var previous = TextBox(x: rect.x, y: rect.y, width: rect.width, height: rect.height)
        previous.flowID = UUID(); previous.flowRegion = .right
        try book.replaceTextBoxes([previous], pageID: book.pages[0].id)
        var replacement = previous; replacement.text = "abcdefghi"
        let (next, _) = try book.reflowText(pageID: book.pages[0].id, previous: previous, replacement: replacement,
            selection: .init(location: 9, length: 0), capacity: { _ in 4 })
        XCTAssertEqual(next.pages.count, 3)
        XCTAssertEqual(next.pages[1].textBoxes![0].flowRegion, .right)
        XCTAssertEqual(next.pages[2].textBoxes![0].flowRegion, .page)
        XCTAssertNil(next.pages[2].margins); XCTAssertNil(next.pages[2].pdfReference)
        XCTAssertEqual(next.pdfSources, book.pdfSources)
        XCTAssertEqual(next.pages[0].margins, book.pages[0].margins)
    }
    func testUnicodeAndRichStyleSurviveSplittingArchiveAndIndependentCopy() throws {
        var (book, previous) = try sample()
        var replacement = previous; replacement.text = "A👨‍👩‍👧‍👦éZ"
        var style = TextBoxStyle(font: .serif, bold: true); style.ink = InkColor(0.2,0.7,0.3)
        style.strikethrough = true; style.baseline = 1; style.fontName = "Example-Font"
        replacement.runs = [TextRun(location: 1, length: 11, style: style)]
        let (next, _) = try book.reflowText(pageID: book.pages[0].id, previous: previous, replacement: replacement,
            selection: .init(location: 15, length: 0), capacity: { box in
                let ns = box.text as NSString
                return ns.length == 0 ? 0 : NSMaxRange(ns.rangeOfComposedCharacterSequence(at: 0))
            })
        XCTAssertEqual(next.pages.map { $0.textBoxes![0].text }.joined(), replacement.text)
        XCTAssertEqual(next.pages[1].textBoxes![0].runs?.first?.style, style)
        XCTAssertEqual(try BackupArchive.decode(BackupArchive.encode(next)).document, next)
        book = next
        let copyID = try book.duplicatePage(book.pages[1].id)
        let copied = try XCTUnwrap(book.pages.first { $0.id == copyID }?.textBoxes?.first)
        XCTAssertNotEqual(copied.flowID, previous.flowID)
        XCTAssertEqual(copied.runs, next.pages[1].textBoxes![0].runs)
    }
    func testAppendPreservesBaseStyleInGapsBetweenRuns() throws {
        let a = TextBox(text: "a", style: TextBoxStyle(color: .red))
        var b = TextBox(text: "xyz", style: TextBoxStyle(font: .serif, color: .blue))
        b.runs = [TextRun(location: 1, length: 1, style: TextBoxStyle(bold: true))]
        let c = a.appending(b)
        XCTAssertEqual(c.text, "axyz"); XCTAssertEqual(c.runs?.map(\.location), [0,1,2,3])
        XCTAssertEqual(c.runs?[1].style, b.style); XCTAssertEqual(c.runs?[3].style, b.style)
    }
    func testStaleAndNonProgressingReflowsFailWithoutChangingOriginal() throws {
        let (book, previous) = try sample("abc")
        var replacement = previous; replacement.text = "abcdef"
        XCTAssertThrowsError(try book.reflowText(pageID: book.pages[0].id, previous: previous, replacement: replacement,
            selection: .init(location: 6, length: 0), capacity: { _ in 0 }))
        var stale = previous; stale.text = "stale"
        XCTAssertThrowsError(try book.reflowText(pageID: book.pages[0].id, previous: stale, replacement: replacement,
            selection: .init(location: 0, length: 0), capacity: { _ in 4 }))
        XCTAssertEqual(book.pages[0].textBoxes![0], previous)
        XCTAssertThrowsError(try replacement.fragment(.init(location: -1, length: 2)))
        var emoji = replacement; emoji.text = "😀"
        XCTAssertThrowsError(try emoji.fragment(.init(location: 0, length: 1)))
    }
    func testDraftIsPresentationOnlyUntilExplicitMaterialization() throws {
        var book = try Notebook.blank(title: "Draft", appearance: NotebookAppearance())
        let bytes = try JSONEncoder().encode(book), draft = book.writingDraft()
        XCTAssertFalse(book.pages.contains { $0.id == draft.id })
        XCTAssertEqual(try JSONEncoder().encode(book).count, bytes.count)
        XCTAssertEqual(try BackupArchive.decode(BackupArchive.encode(book)).document.pages.count, 1)
        var inkDraft = draft; inkDraft.drawing = Data([1,2,3])
        try book.materializeWritingDraft(inkDraft)
        XCTAssertEqual(book.pages.count, 2); XCTAssertEqual(book.pages[1], inkDraft)
        try book.materializeWritingDraft(inkDraft); XCTAssertEqual(book.pages.count, 2)
        XCTAssertNotEqual(book.writingDraft().id, draft.id)
    }
    func testFormatEightCannotBeWrittenUnderOlderSchemaAndOtherEditsKeepIt() throws {
        var (book, _) = try sample()
        var old = book; old.schemaVersion = 7; XCTAssertThrowsError(try old.validate())
        var boxes = book.pages[0].textBoxes!
        boxes[0].flowRegion = nil; XCTAssertThrowsError(try boxes[0].validate())
        boxes = book.pages[0].textBoxes!; boxes[0].style.baseline = 2
        XCTAssertThrowsError(try boxes[0].validate())
        try book.replaceImages([], pageID: book.pages[0].id); XCTAssertEqual(book.schemaVersion, 8)
        try book.replaceShapes([], pageID: book.pages[0].id); XCTAssertEqual(book.schemaVersion, 8)
        let copy = try book.duplicatePage(book.pages[0].id); try book.trashPage(copy)
        XCTAssertEqual(book.schemaVersion, 8)
    }
    func testSchemaSevenBytesArchivedBeforeFirstFlowCommitIncludingTrash() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var old = try Notebook.blank(title: "Alt", appearance: NotebookAppearance())
        let id = old.pages[0].id
        let duplicate = try old.duplicatePage(id); try old.trashPage(duplicate)
        let store = RevisionStore(directory: root); try store.save(old)
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("manifest.json"))) as! [String: Any]
        let revisions = manifest["revisions"] as! [[String: Any]]
        let original = try Data(contentsOf: root.appendingPathComponent("Revisions").appendingPathComponent(revisions[0]["file"] as! String))
        var new = old
        let rect = try XCTUnwrap(new.pages[0].writingRect(.page))
        var box = TextBox(x: rect.x, y: rect.y, width: rect.width, height: rect.height, text: "Neu")
        box.flowID = UUID(); box.flowRegion = .page
        try new.replaceTextBoxes([box], pageID: id); try store.save(new)
        let folders = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("Migrations"), includingPropertiesForKeys: nil)
        XCTAssertEqual(try Data(contentsOf: folders[0].appendingPathComponent("notebook-v7.json")), original)
        XCTAssertEqual(try RevisionStore(directory: root).load(), new)
        XCTAssertEqual(new.deletedPages, try old.preparedForTextEditing().deletedPages)
    }
    func testCaretRevealMovesOnlyEnoughAndLeavesVisibleCaretStill() {
        let visible = PageRect(x: 100, y: 200, width: 500, height: 300)
        XCTAssertEqual(NotebookViewportGeometry.caretOffset(caret: .init(x: 140, y: 250, width: 2, height: 20), visible: visible), .init(x: 100, y: 200))
        XCTAssertEqual(NotebookViewportGeometry.caretOffset(caret: .init(x: 140, y: 490, width: 2, height: 20), visible: visible), .init(x: 100, y: 210))
        XCTAssertEqual(NotebookViewportGeometry.caretOffset(caret: .init(x: 90, y: 190, width: 2, height: 20), visible: visible), .init(x: 90, y: 190))
    }
}
