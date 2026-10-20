import XCTest
@testable import NotebookCore

final class EditorInteractionTests: XCTestCase {
    func testAbortedLiftSetsTheCanvasBackToTheModelInk() {
        let model = Data([1, 2, 3]), remainder = Data([1])
        // Lift in progress: the canvas legitimately shows only the remainder.
        XCTAssertFalse(EditorInteractionPolicy.canvasNeedsReset(shown: remainder, model: model, stroke: false, transient: true))
        // Tool change or lost editing right ended the lift: back to the model.
        XCTAssertTrue(EditorInteractionPolicy.canvasNeedsReset(shown: remainder, model: model, stroke: false, transient: false))
        // Natively drawn, not yet published ink (unknown bytes) is never discarded.
        XCTAssertFalse(EditorInteractionPolicy.canvasNeedsReset(shown: nil, model: model, stroke: false, transient: false))
        // A stroke in progress is never replaced; matching ink needs nothing.
        XCTAssertFalse(EditorInteractionPolicy.canvasNeedsReset(shown: remainder, model: model, stroke: true, transient: false))
        XCTAssertFalse(EditorInteractionPolicy.canvasNeedsReset(shown: model, model: model, stroke: false, transient: false))
    }
    func testTasksCycleAndPencilTogglePreservesIndentationAndSelection() throws {
        var text = "\t👨‍👩‍👧‍👦 Aufgabe"
        var selection = NSRange(location: (text as NSString).length, length: 0)
        for expected in ["\t☐ 👨‍👩‍👧‍👦 Aufgabe", "\t☑ 👨‍👩‍👧‍👦 Aufgabe", "\t👨‍👩‍👧‍👦 Aufgabe"] {
            let edits = TextListEditing.toggle(.checkbox, in: text, range: selection)
            selection = TextListEditing.selection(selection, after: edits)
            let value = NSMutableString(string: text)
            for edit in edits.reversed() { value.replaceCharacters(in: edit.range, with: edit.replacement) }
            text = value as String
            XCTAssertEqual(text, expected)
            XCTAssertEqual(selection, NSRange(location: value.length, length: 0))
        }
        let edit = try XCTUnwrap(TextListEditing.checkbox(in: "  ☑ erledigt", range: .init(location: 8, length: 0)))
        XCTAssertEqual(edit.range, .init(location: 2, length: 1)); XCTAssertEqual(edit.replacement, "☐")
    }

    func testFloatingSizeChangeUsesWholeFieldUnlessUserSelectedWords() {
        let caret = NSRange(location: 4, length: 0), word = NSRange(location: 4, length: 3)
        XCTAssertEqual(EditorInteractionPolicy.formattingRange(selection: caret, textLength: 12, floating: true, wholeField: true), .init(location: 0, length: 12))
        XCTAssertEqual(EditorInteractionPolicy.formattingRange(selection: word, textLength: 12, floating: true, wholeField: true), word)
        XCTAssertEqual(EditorInteractionPolicy.formattingRange(selection: caret, textLength: 12, floating: false, wholeField: true), caret)
        XCTAssertEqual(EditorInteractionPolicy.formattingRange(selection: caret, textLength: 12, floating: true, wholeField: false), caret)
    }

    func testLassoScalesEveryRichTextRunAndRejectsPageFlow() throws {
        var box = TextBox(x: -100, y: 20, width: 180, height: 100, text: "abcde")
        box.style.fontSize = 20
        var large = box.style; large.fontSize = 32; large.bold = true
        box.runs = [TextRun(location: 0, length: 2, style: large), TextRun(location: 2, length: 3, style: box.style)]
        let scaled = try box.scaled(by: 0.5, around: .init(x: -100, y: 20), translation: .init(x: 50, y: 30))
        XCTAssertEqual(scaled.x, -50); XCTAssertEqual(scaled.y, 50)
        XCTAssertEqual(scaled.width, 90); XCTAssertEqual(scaled.style.fontSize, 10)
        XCTAssertEqual(scaled.runs?.map(\.style.fontSize), [16, 10]); XCTAssertEqual(scaled.runs?.first?.style.bold, true)
        XCTAssertThrowsError(try box.scaled(by: 0.1, around: .init(x: 0, y: 0), translation: .init(x: 0, y: 0)))
        box.flowID = UUID(); box.flowRegion = .page
        XCTAssertFalse(box.allowsObjectSelection)
        XCTAssertThrowsError(try box.scaled(by: 1, around: .init(x: 0, y: 0), translation: .init(x: 0, y: 0)))
    }

    func testAutoPenUsesTouchedPaperIncludingNegativeAndTopMargins() {
        let source = PageRect(x: 120, y: 80, width: 595, height: 842)
        for point in [PagePoint(x: 119, y: 100), .init(x: 200, y: 79), .init(x: 715, y: 100), .init(x: 200, y: 922)] {
            XCTAssertTrue(EditorInteractionPolicy.lightAutomaticInk(at: point, source: source, sourceDark: false, marginDark: true))
            XCTAssertFalse(EditorInteractionPolicy.lightAutomaticInk(at: point, source: source, sourceDark: true, marginDark: false))
        }
        XCTAssertFalse(EditorInteractionPolicy.lightAutomaticInk(at: .init(x: 120, y: 80), source: source, sourceDark: false, marginDark: true))
    }

    func testRulingKeepsNormalAndLargeFontsOnLinesWithoutClipping() {
        for baseline in [16.0, 40, 40.00001, 57, 64, 110, 260] {
            let snapped = PaperRuling.nextBaseline(atOrAfter: baseline)
            XCTAssertGreaterThanOrEqual(snapped + 0.001, baseline)
            XCTAssertGreaterThanOrEqual(snapped, 40)
            XCTAssertLessThan(snapped - baseline, 24.001)
            XCTAssertEqual((snapped - 40).truncatingRemainder(dividingBy: 24), 0)
        }
    }

    func testLiftedRulingBaselineStaysJustAboveStrokeForEverySupportedSize() {
        XCTAssertEqual(PaperRuling.baseline(forNatural: 29.3), 37.5, accuracy: 0.0001)
        XCTAssertEqual(PaperRuling.baseline(forNatural: 39), 39, accuracy: 0.0001)
        XCTAssertEqual(PaperRuling.baseline(forNatural: 37), 40 - PaperRuling.baselineLift, accuracy: 0.0001)
        XCTAssertEqual(PaperRuling.baseline(forNatural: 40.5), 64 - PaperRuling.baselineLift, accuracy: 0.0001)
        for natural in stride(from: 0.0, through: 400, by: 0.37) {
            let lifted = PaperRuling.baseline(forNatural: natural), exact = PaperRuling.nextBaseline(atOrAfter: natural)
            XCTAssertGreaterThanOrEqual(lifted + 0.0001, natural)
            XCTAssertLessThanOrEqual(lifted, exact + 0.0001)
            XCTAssertLessThanOrEqual(exact - lifted, PaperRuling.baselineLift + 0.0001)
        }
        // SF-like metrics, TextKit stacking: next natural baseline = previous + descent + ascent.
        for size in stride(from: 8.0, through: 96, by: 1) {
            let ascent = size * 0.952, descent = size * 0.241
            var lifted = PaperRuling.baseline(forNatural: 16 + ascent), exact = PaperRuling.nextBaseline(atOrAfter: 16 + ascent)
            for _ in 0..<30 {
                let line = PaperRuling.nextBaseline(atOrAfter: lifted)
                XCTAssertLessThanOrEqual(lifted, exact + 0.0001, "size \(size) needs more lines than before")
                XCTAssertLessThanOrEqual(line - lifted, PaperRuling.baselineLift + 0.0001)
                if size >= 14 { XCTAssertGreaterThan(lifted + descent, line, "descenders cross the stroke at \(size)") }
                if size <= 18 {
                    XCTAssertEqual(line - lifted, PaperRuling.baselineLift, accuracy: 0.0001)
                    XCTAssertGreaterThan(lifted - size * 0.52, line - PaperRuling.spacing, "x-height between lines at \(size)")
                }
                lifted = PaperRuling.baseline(forNatural: lifted + descent + ascent)
                exact = PaperRuling.nextBaseline(atOrAfter: exact + descent + ascent)
            }
        }
    }

    func testVerticalToolbarSwitchKeepsArrowAtBottom() {
        for dock in [ToolbarDock.left, .right] {
            let main = ToolbarLayout(viewport: .init(width: 1194, height: 834), dock: dock, items: 9, headerItems: 9)
            let more = ToolbarLayout(viewport: main.viewport, dock: dock, items: 6, headerItems: 9)
            XCTAssertEqual(main.frame.y + main.frame.height, more.frame.y + more.frame.height)
        }
    }

    func testPageAwareTextCapacityReceivesEachActualContinuationPage() throws {
        var appearance = NotebookAppearance(); appearance.paper = .lined
        var book = try Notebook.blank(title: "Ruling", appearance: appearance)
        book = try book.preparedForTextEditing()
        let rect = try XCTUnwrap(book.pages[0].writingRect(.page))
        var box = TextBox(x: rect.x, y: rect.y, width: rect.width, height: rect.height)
        box.flowID = UUID(); box.flowRegion = .page
        try book.replaceTextBoxes([box], pageID: book.pages[0].id)
        var replacement = box; replacement.text = "abcdef"
        var seen: [UUID] = []
        let (next, _) = try book.reflowText(pageID: book.pages[0].id, previous: box, replacement: replacement,
            selection: .init(location: 6, length: 0), pageCapacity: { page, candidate in
                seen.append(page.id)
                XCTAssertEqual(page.paper, .lined)
                XCTAssertEqual(candidate.flowID, box.flowID)
                return 3
            })
        XCTAssertEqual(seen, next.pages.map(\.id))
        XCTAssertEqual(next.pages.map { $0.textBoxes![0].text }, ["abc", "def"])
    }

    /// Build 41: the fit covers the complete sheet, writing space included.
    func testWritingMarginsFitWholeSheetAndStillAllowZoomOut() throws {
        var base = Notebook.blank(title: "Fit").pages[0]
        base.margins = PageMargins(right: 595)
        for normalized in [false, true] {
            let layout = NotebookViewportLayout(pages: [base], selectedPageID: base.id, paging: true, normalizeWidths: normalized)
            let page = try XCTUnwrap(layout.pages.first)
            let range = NotebookViewportGeometry.zoomRange(viewport: .init(width: 900, height: 800), page: page.frame.size,
                contentWidth: page.contentFrame.width)
            XCTAssertEqual(page.frame.width * range.fit, 868, accuracy: 0.000001)
            XCTAssertEqual(NotebookViewportGeometry.zoomRange(viewport: .init(width: 900, height: 800), placement: page), range)
            XCTAssertLessThan(range.minimum, range.fit)
            XCTAssertLessThanOrEqual(page.frame.width * range.minimum, 868)
            XCTAssertEqual(page.canvas.width, 1190)
        }
    }
}
