import Foundation
import XCTest
@testable import NotebookCore

/// A monospaced layout in place of TextKit: 10 pt per character, lines wrap
/// after `columns` characters or a line break, `linesPerPage` lines a page.
private struct FakeMetrics: DocumentTextMetrics {
    var text: NSString
    var columns = 10
    var linesPerPage = 3
    var pageCount = 4
    /// Pages that take no line (between the text).
    var skipped: Set<Int> = []
    private let height = 20.0, ascent = 14.0, descent = 4.0

    init(_ text: String, columns: Int = 10, linesPerPage: Int = 3, pageCount: Int = 4, skipped: Set<Int> = []) {
        self.text = text as NSString; self.columns = columns; self.linesPerPage = linesPerPage
        self.pageCount = pageCount; self.skipped = skipped
    }

    private var allLines: [DocumentTextLine] {
        var result: [DocumentTextLine] = [], start = 0
        var page = 0, row = 0
        func advance() {
            row += 1
            if row == linesPerPage { row = 0; page += 1 }
            while skipped.contains(page) { page += 1 }
        }
        while skipped.contains(page) { page += 1 }
        while start < text.length {
            var end = start
            while end < text.length, end - start < columns, !TextLines.isBreak(text.character(at: end)) { end += 1 }
            if end < text.length, TextLines.isBreak(text.character(at: end)) { end += 1 }
            result.append(line(page: page, row: row, range: NSRange(location: start, length: end - start)))
            start = end
            advance()
        }
        if text.length == 0 || TextLines.isBreak(text.character(at: text.length - 1)) {
            result.append(line(page: page, row: row, range: NSRange(location: text.length, length: 0)))
        }
        return result
    }
    private func line(page: Int, row: Int, range: NSRange) -> DocumentTextLine {
        let top = Double(row) * height
        let visible = text.substring(with: range).trimmingCharacters(in: .newlines)
        return DocumentTextLine(page: page, range: range, rect: PageRect(x: 0, y: top, width: Double(columns) * 10, height: height),
            used: PageRect(x: 0, y: top, width: Double((visible as NSString).length) * 10, height: height),
            baseline: top + ascent, ascent: ascent, descent: descent)
    }
    func page(of offset: Int) -> Int {
        let lines = allLines
        return (lines.first { offset >= $0.range.location && offset < $0.end } ?? lines.last)?.page ?? 0
    }
    func lines(onPage page: Int) -> [DocumentTextLine] { allLines.filter { $0.page == page } }
    func x(of offset: Int, on line: DocumentTextLine) -> Double { Double(offset - line.range.location) * 10 }
    func offset(atX x: Double, on line: DocumentTextLine) -> Int {
        line.clamped(line.range.location + Int((x / 10).rounded()), in: text)
    }
}

final class DocumentTextLayoutTests: XCTestCase {
    // MARK: Page rule against `TextFlowEditing.capacity`

    /// A typesetter's line tops under the ruling (the delegate moves each line).
    private func lines(count: Int, rule: DocumentPageRule, lineHeight: Double, ascent: Double, stopAtPage: Bool) -> [(end: Int, bottom: Double)] {
        var top = 0.0, result: [(end: Int, bottom: Double)] = []
        for index in 0..<count {
            if stopAtPage, !rule.fits(top: top, lineHeight: lineHeight, ascent: ascent) { break }
            let bottom = rule.lineBottom(top: top, lineHeight: lineHeight, ascent: ascent)
            result.append((end: index + 1, bottom: bottom))
            top = bottom
        }
        return result
    }

    func testPageRuleBreaksWhereCapacityBreaks() {
        let box = 810.0 // A4 writing height
        let rules = [DocumentPageRule(height: box),
                     DocumentPageRule(height: box, ruling: .lined, origin: 16, pageTop: 0),
                     DocumentPageRule(height: box, ruling: .grid, origin: 16, pageTop: 0)]
        for rule in rules {
            for (lineHeight, ascent) in [(16.7, 13.3), (19.1, 15.2), (28.6, 22.8), (57.3, 45.6)] {
                let free = lines(count: 400, rule: rule, lineHeight: lineHeight, ascent: ascent, stopAtPage: false)
                let capacity = DocumentPagination.capacity(lineBottoms: free, height: box)
                let container = lines(count: 400, rule: rule, lineHeight: lineHeight, ascent: ascent, stopAtPage: true)
                XCTAssertEqual(container.last?.end, capacity, "\(String(describing: rule.ruling)) line \(lineHeight)")
            }
        }
    }

    func testPageTakesItsFirstLineWhateverItsSize() {
        let rule = DocumentPageRule(height: 40, ruling: .lined, origin: 16, pageTop: 0)
        XCTAssertTrue(rule.fits(top: 0, lineHeight: 500, ascent: 400))
        XCTAssertFalse(rule.fits(top: 30, lineHeight: 20, ascent: 15))
        XCTAssertTrue(DocumentPageRule(height: 40).fits(top: 20, lineHeight: 20.25, ascent: 15), "0.25 slack as in capacity")
        XCTAssertFalse(DocumentPageRule(height: 40).fits(top: 20, lineHeight: 20.3, ascent: 15))
    }

    /// The formula `RuledTextLayout.baseline` had before it moved to Core.
    func testLineBaselineKeepsTheRuleOfThePreviews() {
        for ruling in [TextRuling.lined, .grid] {
            for origin in [16.0, 40.0] {
                for top in [0.0, 0.3, 20.0, 137.5] {
                    for ascent in [11.0, 22.8, 90.0] {
                        let natural = origin + top + ascent
                        let ruled = ruling.baseline(forNatural: natural)
                        XCTAssertEqual(ruling.lineBaseline(top: top, ascent: ascent, origin: origin, pageTop: nil),
                                       (top < 0.5 ? max(natural, ruled) : ruled) - origin)
                        let first = top < 0.5 ? ruling.firstLineBaseline(ascent: ascent, pageTop: 0) - origin : ruled - origin
                        XCTAssertEqual(ruling.lineBaseline(top: top, ascent: ascent, origin: origin, pageTop: 0), first)
                    }
                }
            }
        }
    }

    // MARK: Pages from measured lines

    func testPageRangesAreConsecutiveAndEmptyPagesHoldNothing() {
        let metrics = FakeMetrics("0123456789abcdefghij0123456789abcdefghijKLMNO", skipped: [1])
        let lines = (0..<4).flatMap(metrics.lines(onPage:))
        XCTAssertEqual(DocumentPagination.pageRanges(lines: lines, pageCount: 4, textLength: 45),
                       [NSRange(location: 0, length: 30), NSRange(location: 30, length: 0),
                        NSRange(location: 30, length: 15), NSRange(location: 45, length: 0)])
    }

    func testMeasurementWithGapIsRefused() {
        var lines = FakeMetrics("0123456789abcdefghij").lines(onPage: 0)
        lines[1].range.location += 1
        XCTAssertNil(DocumentPagination.pageRanges(lines: lines, pageCount: 1, textLength: 20))
        XCTAssertNil(DocumentPagination.pageRanges(lines: FakeMetrics("0123456789").lines(onPage: 0), pageCount: 1, textLength: 11))
    }

    func testCapacityAtAPageStart() {
        let pages = [NSRange(location: 0, length: 30), NSRange(location: 30, length: 15)]
        XCTAssertEqual(DocumentPagination.capacity(start: 30, pages: pages), 15)
        XCTAssertNil(DocumentPagination.capacity(start: 12, pages: pages), "no page starts there: another text")
    }

    func testDeviationsNamePagesThatDiffer() {
        let layout = [NSRange(location: 0, length: 30), NSRange(location: 30, length: 15)]
        XCTAssertEqual(DocumentPagination.deviations(layout: layout, stored: [30, 15]), [])
        XCTAssertEqual(DocumentPagination.deviations(layout: layout, stored: [28, 17, 1]),
                       [.init(page: 0, layout: 30, stored: 28), .init(page: 1, layout: 15, stored: 17), .init(page: 2, layout: 0, stored: 1)])
    }

    // MARK: The model follows the layout

    private func document(_ text: String, perPage: Int = 10) throws -> Notebook {
        let document = try Notebook.textDocument(title: "Fluss")
        let first = try XCTUnwrap(document.textFlowSegments.first)
        var replacement = first.box; replacement.text = text; replacement.runs = nil
        return try document.reflowText(pageID: first.pageID, previous: first.box, replacement: replacement,
            selection: NSRange(location: 0, length: 0), pageCapacity: { _, box in min(perPage, (box.text as NSString).length) }).0
    }

    /// `capacity` as the app gives it: from the page ranges of the layout.
    private func layout(_ metrics: FakeMetrics) -> TextFlowLayout {
        let lines = (0..<metrics.pageCount).flatMap(metrics.lines(onPage:))
        let ranges = DocumentPagination.pageRanges(lines: lines.filter { !$0.isExtra }, pageCount: metrics.pageCount, textLength: metrics.text.length) ?? []
        return TextFlowLayout(capacity: { _, box in
            DocumentPagination.capacity(start: metrics.text.length - (box.text as NSString).length, pages: ranges) ?? 0
        })
    }

    func testSegmentsFollowTheLayoutAndStayValid() throws {
        let start = try document(String(repeating: "x", count: 25))
        let typed = "abc\ndef "
        let target = String(repeating: "x", count: 5) + typed + String(repeating: "x", count: 20)
        let change = TextFlowChange(edits: [TextListEditing.Edit(range: NSRange(location: 5, length: 0), replacement: typed)],
            selection: NSRange(location: 13, length: 0), selectionBefore: NSRange(location: 5, length: 0))
        let metrics = FakeMetrics(target, columns: 10, linesPerPage: 1, pageCount: 8)
        let (next, focus) = try start.changingTextFlow(change, layout: layout(metrics))
        XCTAssertNoThrow(try next.validate())
        XCTAssertEqual(next.textFlowContent?.text, target)
        let expected = (0..<8).flatMap(metrics.lines(onPage:)).filter { !$0.isExtra }.map(\.range.length)
        XCTAssertEqual(next.textFlowSegments.map { ($0.box.text as NSString).length }, expected)
        XCTAssertEqual(next.textFlowOffset(boxID: focus.boxID, location: focus.selection.location), 13)
    }

    func testTypedStyleOnlyOnTheTypedText() throws {
        let start = try document("0123456789abcdefghijKLMNO")
        var bold = try XCTUnwrap(start.textFlowContent).style; bold.bold = true
        let change = TextFlowChange(edits: [TextListEditing.Edit(range: NSRange(location: 12, length: 2), replacement: "XY")], style: bold,
            selection: NSRange(location: 14, length: 0), selectionBefore: NSRange(location: 14, length: 0))
        let (next, _) = try start.changingTextFlow(change, layout: TextFlowLayout(capacity: { _, box in min(10, (box.text as NSString).length) }))
        let content = try XCTUnwrap(next.textFlowContent)
        XCTAssertEqual(content.text, "0123456789abXYefghijKLMNO")
        XCTAssertTrue(content.style(at: 12).bold); XCTAssertTrue(content.style(at: 13).bold)
        XCTAssertFalse(content.style(at: 11).bold); XCTAssertFalse(content.style(at: 14).bold)
        XCTAssertNoThrow(try next.validate())
    }

    func testShorterTextRemovesEmptiedPages() throws {
        let start = try document("0123456789abcdefghijKLMNO")
        XCTAssertEqual(start.pages.count, 3)
        let change = TextFlowChange(edits: [TextListEditing.Edit(range: NSRange(location: 3, length: 22), replacement: "")],
            selection: NSRange(location: 3, length: 0), selectionBefore: NSRange(location: 25, length: 0))
        let (next, focus) = try start.changingTextFlow(change, layout: TextFlowLayout(capacity: { _, box in min(10, (box.text as NSString).length) }))
        XCTAssertEqual(next.pages.count, 1)
        XCTAssertEqual(next.textFlowContent?.text, "012")
        XCTAssertEqual(focus.selection.location, 3)
    }

    func testChangeBehindTheTextIsStale() throws {
        let start = try document("0123")
        let change = TextFlowChange(edits: [TextListEditing.Edit(range: NSRange(location: 9, length: 0), replacement: "x")],
            selection: NSRange(location: 10, length: 0), selectionBefore: NSRange(location: 0, length: 0))
        XCTAssertThrowsError(try start.changingTextFlow(change, layout: TextFlowLayout(capacity: { _, _ in 10 })))
    }

    func testFocusAtAnOffsetIsTheSegmentPlace() throws {
        let start = try document("0123456789abcdefghijKLMNO")
        let second = start.textFlowSegments[1]
        let focus = try XCTUnwrap(start.textFlowFocus(selection: NSRange(location: 13, length: 0)))
        XCTAssertEqual(focus.pageID, second.pageID); XCTAssertEqual(focus.boxID, second.box.id)
        XCTAssertEqual(focus.selection, NSRange(location: 3, length: 0))
    }

    func testSlotsSkipPagesBetweenSegmentsAndTakeThoseBehind() throws {
        var pages = try document("0123456789abcdefghij").pages
        XCTAssertEqual(pages.count, 2)
        pages.insert(Notebook.textDocumentPage(), at: 1)
        pages.append(Notebook.textDocumentPage())
        XCTAssertEqual(DocumentPageSlots.indices(in: pages), [0, 2, 3])
        XCTAssertEqual(DocumentPageSlots.indices(in: [Notebook.textDocumentPage()]), [])
    }

    // MARK: Caret and positions

    func testPageBoundaryBelongsToTheFollowingText() {
        let metrics = FakeMetrics("0123456789abcdefghij0123456789abcdef")
        XCTAssertEqual(metrics.page(of: 29), 0)
        XCTAssertEqual(metrics.page(of: 30), 1)
        XCTAssertEqual(metrics.caret(at: 30), DocumentCaret(page: 1, rect: PageRect(x: 0, y: -4 + 4 + 0, width: 2, height: 18)))
        XCTAssertEqual(metrics.caret(at: 36)?.page, 1, "the end of the text stays on the last line")
        XCTAssertEqual(metrics.caret(at: 36)?.rect.x, 60)
    }

    func testCaretOnTheEmptyLineBehindAFinalBreak() throws {
        let metrics = FakeMetrics("0123456789abcdefghij012345\n")
        let caret = try XCTUnwrap(metrics.caret(at: 27))
        XCTAssertEqual(caret.page, 1, "the fourth line goes to the next page")
        XCTAssertEqual(caret.rect.x, 0)
        XCTAssertEqual(metrics.line(at: 27)?.isExtra, true)
    }

    func testEmptyDocumentHasACaret() {
        let metrics = FakeMetrics("")
        XCTAssertEqual(metrics.caret(at: 0)?.page, 0)
        XCTAssertEqual(metrics.selectionRects(NSRange(location: 0, length: 0)), [])
    }

    func testCaretBandFollowsTheFontAtTheCaret() {
        let caret = FakeMetrics("0123").caret(at: 2, band: (ascent: 20, descent: 6))
        XCTAssertEqual(caret?.rect.y, 14 - 20)
        XCTAssertEqual(caret?.rect.height, 26)
    }

    func testClampingStopsBeforeBreaksAndWraps() {
        let text = "0123456789abc\n" as NSString
        let metrics = FakeMetrics(text as String)
        let wrapped = metrics.lines(onPage: 0)[0], last = metrics.lines(onPage: 0)[1]
        XCTAssertEqual(wrapped.clamped(10, in: text), 9, "the end of a wrapped line is the next line's start")
        XCTAssertEqual(last.clamped(14, in: text), 13, "not behind the line break")
        let ending = FakeMetrics("abc").lines(onPage: 0)[0]
        XCTAssertEqual(ending.clamped(3, in: "abc"), 3, "the end of the text is a place")
    }

    // MARK: Selection geometry

    func testSelectionOverAPageChange() {
        let metrics = FakeMetrics("0123456789abcdefghij0123456789abcdefghij")
        let rects = metrics.selectionRects(NSRange(location: 25, length: 8))
        XCTAssertEqual(rects.map(\.page), [0, 1])
        XCTAssertEqual(rects[0].rect.x, 50); XCTAssertEqual(rects[0].rect.width, 50)
        XCTAssertTrue(rects[0].containsStart); XCTAssertFalse(rects[0].containsEnd)
        XCTAssertEqual(rects[1].rect.x, 0); XCTAssertEqual(rects[1].rect.width, 30)
        XCTAssertFalse(rects[1].containsStart); XCTAssertTrue(rects[1].containsEnd)
        XCTAssertEqual(rects[0].rect.y, 40 + 14 - 14); XCTAssertEqual(rects[0].rect.height, 18, "the glyph band, not the line")
    }

    func testLongSelectionMeasuresOnlyVisiblePagesAndItsEnds() {
        let metrics = FakeMetrics(String(repeating: "x", count: 90), linesPerPage: 1, pageCount: 9)
        let rects = metrics.selectionRects(NSRange(location: 5, length: 80), pages: [4])
        XCTAssertEqual(rects.map(\.page), [0, 4, 8])
        XCTAssertTrue(rects[0].containsStart); XCTAssertTrue(rects[2].containsEnd)
    }

    func testAnEmptyLineInASelectionStaysVisible() {
        let rects = FakeMetrics("ab\n\ncd").selectionRects(NSRange(location: 1, length: 4))
        XCTAssertEqual(rects.count, 3)
        XCTAssertEqual(rects[1].rect.width, 2)
    }

    // MARK: Lines over pages

    func testDownAndUpCrossThePageChangeAndKeepTheColumn() {
        let metrics = FakeMetrics("0123456789abcdefghij0123456789abcdefghij")
        let down = metrics.verticalTarget(from: 27, lines: 1, goal: nil)
        XCTAssertEqual(down.offset, 37)
        XCTAssertEqual(down.goal, 70)
        XCTAssertEqual(metrics.verticalTarget(from: 37, lines: -1, goal: 70).offset, 27)
        XCTAssertEqual(metrics.verticalTarget(from: 3, lines: 3, goal: nil).offset, 33)
    }

    func testShortLineKeepsTheGoalForTheNextOne() {
        let metrics = FakeMetrics("0123456789\nab\n0123456789\n", linesPerPage: 2)
        let first = metrics.verticalTarget(from: 8, lines: 1, goal: nil)
        XCTAssertEqual(first.offset, 13, "the short line ends earlier")
        XCTAssertEqual(metrics.verticalTarget(from: first.offset, lines: 1, goal: first.goal).offset, 22)
    }

    func testPagesWithoutTextAreSkipped() {
        let metrics = FakeMetrics("0123456789abcdefghij0123456789abcdef", skipped: [1])
        XCTAssertEqual(metrics.verticalTarget(from: 25, lines: 1, goal: nil).offset, 35)
        XCTAssertEqual(metrics.verticalTarget(from: 35, lines: -1, goal: nil).offset, 25)
    }

    func testEndsOfTheText() {
        let metrics = FakeMetrics("0123456789abcdefghij")
        XCTAssertEqual(metrics.verticalTarget(from: 13, lines: 1, goal: nil).offset, 13, "`j` stays")
        XCTAssertEqual(metrics.verticalTarget(from: 3, lines: -1, goal: nil).offset, 3)
        XCTAssertEqual(metrics.verticalTarget(from: 13, lines: 1, goal: nil, overshoot: true).offset, 20, "the arrow goes to the end")
        XCTAssertEqual(metrics.verticalTarget(from: 3, lines: -1, goal: nil, overshoot: true).offset, 0)
    }

    // MARK: Points

    private let frames = [DocumentPageFrame(page: 0, sheet: PageRect(x: 0, y: 0, width: 595, height: 842), origin: PagePoint(x: 32, y: 16), scale: 1),
                          DocumentPageFrame(page: 1, sheet: PageRect(x: 0, y: 844, width: 595, height: 842), origin: PagePoint(x: 32, y: 860), scale: 1)]

    func testPointOnTheSecondPage() {
        let metrics = FakeMetrics("0123456789abcdefghij0123456789abcdefghij")
        XCTAssertEqual(metrics.offset(closestTo: PagePoint(x: 32 + 40, y: 860 + 30), in: frames), 34)
        XCTAssertEqual(metrics.offset(closestTo: PagePoint(x: 32 + 40, y: 16 + 30), in: frames), 14)
    }

    func testPointInTheGapGoesToTheNearestPage() {
        let metrics = FakeMetrics("0123456789abcdefghij0123456789abcdefghij")
        XCTAssertEqual(metrics.frame(nearest: PagePoint(x: 0, y: 843), in: frames)?.page, 0)
        XCTAssertEqual(metrics.frame(nearest: PagePoint(x: 0, y: 2000), in: frames)?.page, 1)
    }

    func testPageBehindTheTextGivesTheEnd() {
        let metrics = FakeMetrics("abc")
        XCTAssertEqual(metrics.offset(closestTo: PagePoint(x: 32, y: 900), in: frames), 3)
    }

    func testBelowTheLastLineTheNearestPlaceOnIt() {
        XCTAssertEqual(FakeMetrics("abc").offset(closestTo: PagePoint(x: 500, y: 700), in: frames), 3)
    }

    func testFrameRoundTripWithScale() throws {
        let page = Notebook.textDocumentPage()
        let layout = NotebookViewportLayout(pages: [page, page], selectedPageID: page.id, paging: false, normalizeWidths: true)
        let placement = layout.pages[1]
        let frame = DocumentPageFrame(page: 1, placement: placement, box: PageRect(x: 32, y: 16, width: 531, height: 810))
        let point = PagePoint(x: 12, y: 345)
        let back = frame.local(frame.surface(point))
        XCTAssertEqual(back.x, 12, accuracy: 0.0001); XCTAssertEqual(back.y, 345, accuracy: 0.0001)
        let rect = frame.surface(PageRect(x: 0, y: 0, width: 10, height: 10))
        XCTAssertEqual(rect.y, placement.contentFrame.y + 16 * placement.scale, accuracy: 0.0001)
        XCTAssertEqual(rect.width, 10 * placement.scale, accuracy: 0.0001)
    }

    // MARK: Motion and engine display

    func testWordMotion() {
        let text = "ein  Wort, noch" as NSString
        XCTAssertEqual(DocumentCaretMotion.wordForward(text, 3), 9)
        XCTAssertEqual(DocumentCaretMotion.wordForward(text, 9), 15)
        XCTAssertEqual(DocumentCaretMotion.wordBackward(text, 9), 5)
        XCTAssertEqual(DocumentCaretMotion.wordBackward(text, 5), 0)
        XCTAssertEqual(DocumentCaretMotion.wordBackward(text, 0), 0)
    }

    func testSelectionFollowsAReplacementBeforeIt() {
        let mapped = DocumentCaretMotion.selection(NSRange(location: 10, length: 0), replacing: NSRange(location: 2, length: 3), length: 5)
        XCTAssertEqual(mapped, NSRange(location: 12, length: 0))
        XCTAssertEqual(DocumentCaretMotion.selection(NSRange(location: 1, length: 0), replacing: NSRange(location: 2, length: 3), length: 5),
                       NSRange(location: 1, length: 0))
        XCTAssertEqual(DocumentCaretMotion.selection(NSRange(location: 3, length: 0), replacing: NSRange(location: 2, length: 3), length: 5),
                       NSRange(location: 7, length: 0))
    }

    func testEngineShowsEverySelection() {
        var engine = TextEngine(text: "ein Wort\nein Wort\n")
        engine.perform(.word(.nextStart, long: false))
        engine.perform(.copyToNextLine)
        let shown = engine.shownSelections
        XCTAssertEqual(shown.count, 2)
        XCTAssertEqual(shown.filter(\.isPrimary).count, 1)
        XCTAssertEqual(shown[1].range.location, 9)
        XCTAssertTrue(shown.allSatisfy(\.isWide))
        XCTAssertEqual(shown[0].cursor, shown[0].range.length - 1)
    }

    func testEngineCursorIsNoWideSelection() {
        let shown = TextEngine(text: "abc").shownSelections
        XCTAssertEqual(shown, [TextEngine.ShownSelection(range: NSRange(location: 0, length: 1), cursor: 0, isPrimary: true, isWide: false)])
    }

    func testVerticalLayoutThroughTheEngine() {
        struct Layout: TextEngineLayout {
            let metrics: FakeMetrics
            var visibleLines: Int { 3 }
            func verticalTarget(from offset: Int, lines: Int, goal: Double?, in text: NSString) -> (offset: Int, goal: Double) {
                metrics.verticalTarget(from: offset, lines: lines, goal: goal)
            }
        }
        let text = "0123456789abcdefghij0123456789abcdefghij"
        var engine = TextEngine(text: text, caret: 25)
        engine.layout = Layout(metrics: FakeMetrics(text))
        engine.perform(.move(.down))
        XCTAssertEqual(engine.cursor, 35, "`j` over the page change")
    }
}

private extension Notebook {
    /// A page without a flow segment.
    static func textDocumentPage() -> Page {
        var page = Page(); page.paper = .blank; page.geometry = NotebookAppearance().geometry
        return page
    }
}
