import XCTest
@testable import NotebookCore

final class TextListStructureTests: XCTestCase {
    private func apply(_ edits: [TextListEditing.Edit], to text: String) -> String {
        let value = NSMutableString(string: text)
        for edit in edits.sorted(by: { $0.range.location > $1.range.location }) { value.replaceCharacters(in: edit.range, with: edit.replacement) }
        return value as String
    }
    /// Box whose paragraphs carry the given nesting levels (indent = 20 pt × level).
    private func box(_ lines: [(String, Int)]) -> TextBox {
        var text = "", runs: [TextRun] = []
        for (index, (line, level)) in lines.enumerated() {
            let value = line + (index < lines.count - 1 ? "\n" : "")
            var style = TextBoxStyle(); style.indent = Double(level) * 20
            runs.append(TextRun(location: (text as NSString).length, length: (value as NSString).length, style: style))
            text += value
        }
        var box = TextBox(text: text); box.runs = runs.filter { $0.length > 0 }
        return box
    }
    private func levels(_ box: TextBox) -> [Int] {
        let source = box.text as NSString
        var result: [Int] = [], cursor = 0
        repeat {
            let line = source.lineRange(for: NSRange(location: cursor, length: 0))
            result.append(box.listLevel(at: line.location)); cursor = NSMaxRange(line)
        } while cursor < source.length
        return result
    }

    // MARK: Ruling and click-and-type

    func testGridRulingKeepsBodyTextOnEveryRowAndLinedPaperUnchanged() {
        for natural in stride(from: 10.0, through: 400, by: 0.7) {
            XCTAssertEqual(TextRuling.lined.baseline(forNatural: natural), PaperRuling.baseline(forNatural: natural), accuracy: 1e-9)
            let grid = TextRuling.grid.baseline(forNatural: natural)
            XCTAssertGreaterThanOrEqual(grid, natural - TextRuling.grid.tolerance - 1e-9)
            let row = TextRuling.grid.nextBaseline(atOrAfter: natural - TextRuling.grid.tolerance)
            XCTAssertEqual((row - 40).truncatingRemainder(dividingBy: 16), 0, accuracy: 1e-6)
            XCTAssertLessThanOrEqual(grid, row + 1e-9); XCTAssertGreaterThanOrEqual(grid, row - TextRuling.grid.lift - 1e-9)
        }
        // 14-pt system metrics: every line advances exactly one 16-pt row.
        var baseline = TextRuling.grid.baseline(forNatural: 16 + 13.36)
        XCTAssertEqual(baseline, 38.5, accuracy: 1e-9)
        for _ in 0..<30 {
            let next = TextRuling.grid.baseline(forNatural: baseline + 3.38 + 13.36)
            XCTAssertEqual(next - baseline, 16, accuracy: 1e-9); baseline = next
        }
        XCTAssertNil(TextRuling(paper: .blank)); XCTAssertEqual(TextRuling(paper: .grid), .grid)
    }
    func testTapBelowTextPicksNearestRuledLineAndCountsBreaks() throws {
        // Lined paper, container top at page y 16, existing line ends at 32.
        let lined = try XCTUnwrap(TextPlacement.below(tap: .init(x: 5, y: 90), top: 32, endsWithBreak: false, width: 500,
            height: 760, lineHeight: 16.7, ascent: 13.36, descent: 3.38, ruling: .lined, origin: 16))
        // Rules at page y 40, 64, 88, 112: container baselines 21.5, 45.5, 69.5, 93.5 (−2.5 lift).
        XCTAssertEqual(lined.baseline, 93.5, accuracy: 1e-6)
        XCTAssertEqual(lined.newlines, 3)
        // Directly below the text on an existing empty line: no break needed.
        let same = try XCTUnwrap(TextPlacement.below(tap: .init(x: 0, y: 40), top: 32, endsWithBreak: true, width: 500,
            height: 760, lineHeight: 16.7, ascent: 13.36, descent: 3.38, ruling: .lined, origin: 16))
        XCTAssertEqual(same.newlines, 0)
        // Blank paper: natural line pitch of the typing font.
        let blank = try XCTUnwrap(TextPlacement.below(tap: .init(x: 0, y: 61), top: 0, endsWithBreak: true, width: 500,
            height: 760, lineHeight: 20, ascent: 15, descent: 5, ruling: nil))
        XCTAssertEqual(blank.newlines, 3); XCTAssertEqual(blank.baseline, 75, accuracy: 1e-9)
        // Grid paper: 16-pt rows.
        let grid = try XCTUnwrap(TextPlacement.below(tap: .init(x: 0, y: 70), top: 0, endsWithBreak: true, width: 500,
            height: 760, lineHeight: 16.7, ascent: 13.36, descent: 3.38, ruling: .grid, origin: 16))
        XCTAssertEqual(grid.newlines, 3); XCTAssertEqual(grid.baseline, 70.5, accuracy: 1e-6)
        // Below the last line that fits: clamp, never past the writing area.
        let clamped = try XCTUnwrap(TextPlacement.below(tap: .init(x: 0, y: 5000), top: 0, endsWithBreak: true, width: 500,
            height: 100, lineHeight: 20, ascent: 15, descent: 5, ruling: nil))
        XCTAssertEqual(clamped.newlines, 4)
        XCTAssertNil(TextPlacement.below(tap: .init(x: 0, y: 10), top: 30, endsWithBreak: true, width: 500,
            height: 760, lineHeight: 20, ascent: 15, descent: 5, ruling: nil))
    }
    func testRightHalfOpensFreeFieldOnlyBesideOrBelowText() {
        // Left half: always the flowing lines, even far below the text.
        XCTAssertFalse(TextPlacement.opensFreeField(tapX: 200, regionX: 16, regionWidth: 563, hitsText: false))
        // From the middle rightwards a free field, unless the tap hits text.
        XCTAssertTrue(TextPlacement.opensFreeField(tapX: 297.5, regionX: 16, regionWidth: 563, hitsText: false))
        XCTAssertTrue(TextPlacement.opensFreeField(tapX: 560, regionX: 16, regionWidth: 563, hitsText: false))
        XCTAssertFalse(TextPlacement.opensFreeField(tapX: 560, regionX: 16, regionWidth: 563, hitsText: true))
        // Writing margin beside a PDF: its own middle counts.
        XCTAssertFalse(TextPlacement.opensFreeField(tapX: 900, regionX: 612, regionWidth: 580, hitsText: false))
        XCTAssertTrue(TextPlacement.opensFreeField(tapX: 910, regionX: 612, regionWidth: 580, hitsText: false))
        XCTAssertFalse(TextPlacement.opensFreeField(tapX: .nan, regionWidth: 500, hitsText: false))
    }
    func testFreeFieldFrameStartsAtTapAndStaysInside() throws {
        let limits = PageRect(x: 0, y: 0, width: 595, height: 842)
        let middle = try XCTUnwrap(TextPlacement.freeFieldFrame(tap: .init(x: 320, y: 200), limits: limits, fontSize: 14))
        XCTAssertEqual(middle.x, 320); XCTAssertEqual(middle.width, 260)
        XCTAssertEqual(middle.y + 14 * TextStylePreset.lineHeightFactor / 2, 200, accuracy: 1e-9, "first line centred on the tap")
        // Near the right edge: shifted left to keep a usable width.
        let edge = try XCTUnwrap(TextPlacement.freeFieldFrame(tap: .init(x: 590, y: 5), limits: limits, fontSize: 14))
        XCTAssertEqual(edge.x, 475); XCTAssertEqual(edge.width, 120); XCTAssertEqual(edge.y, 0)
        let bottom = try XCTUnwrap(TextPlacement.freeFieldFrame(tap: .init(x: 400, y: 841), limits: limits, fontSize: 14))
        XCTAssertEqual(bottom.y + bottom.height, 842, accuracy: 1e-9)
        XCTAssertLessThanOrEqual(bottom.x + bottom.width, 595)
        XCTAssertNil(TextPlacement.freeFieldFrame(tap: .init(x: 1, y: 1), limits: .init(x: 0, y: 0, width: 30, height: 30), fontSize: 14))
    }

    // MARK: Automatic lists

    func testAutoListTriggersAtParagraphStartOnly() {
        for (typed, marker) in [("- ", "• "), ("* ", "• "), ("1) ", "1. "), ("[] ", "☐ "), ("[ ] ", "☐ ")] {
            let text = "Davor\n" + typed
            let edit = TextListEditing.autoList(in: text, caret: (text as NSString).length)
            XCTAssertEqual(apply(edit.map { [$0] } ?? [], to: text), "Davor\n" + marker, typed)
        }
        XCTAssertNil(TextListEditing.autoList(in: "• ", caret: 2), "already a list")
        XCTAssertNil(TextListEditing.autoList(in: "1. ", caret: 3))
        XCTAssertEqual(TextListEditing.autoList(in: "• ", caret: 2, level: 1)?.replacement, "◦ ")
        XCTAssertNil(TextListEditing.autoList(in: "Text - ", caret: 7))
        XCTAssertNil(TextListEditing.autoList(in: "z. B. ", caret: 6))
        XCTAssertEqual(apply([TextListEditing.autoList(in: "  - x", caret: 4)!], to: "  - x"), "  • x")
    }

    // MARK: Nesting

    func testTabNestsBulletsWithCyclingGlyphsAndShiftTabReturns() throws {
        var current = box([("• a", 0), ("• b", 0), ("• c", 0)])
        let caret = ("• a\n• b" as NSString).length
        let nested = try XCTUnwrap(current.nestingList(selection: .init(location: caret, length: 0), outdent: false))
        XCTAssertEqual(nested.box.text, "• a\n◦ b\n• c"); XCTAssertEqual(levels(nested.box), [0, 1, 0])
        XCTAssertEqual(nested.selection.location, caret)
        current = nested.box
        for expected in ["▪ b", "• b"] {
            current = try XCTUnwrap(current.nestingList(selection: .init(location: 6, length: 0), outdent: false)).box
            XCTAssertTrue(current.text.contains(expected))
        }
        XCTAssertEqual(levels(current), [0, 3, 0])
        for _ in 0..<3 { current = try XCTUnwrap(current.nestingList(selection: .init(location: 6, length: 0), outdent: true)).box }
        XCTAssertEqual(current.text, "• a\n• b\n• c"); XCTAssertEqual(levels(current), [0, 0, 0])
        XCTAssertNil(current.nestingList(selection: .init(location: 6, length: 0), outdent: true), "level 0 cannot outdent")
        XCTAssertNil(box([("Normal", 0)]).nestingList(selection: .init(location: 2, length: 0), outdent: false))
        var deep = box([("• x", 12)])
        XCTAssertNil(deep.nestingList(selection: .init(location: 2, length: 0), outdent: false), "240 pt format limit")
        deep = box([("☐ Aufgabe", 0)])
        XCTAssertEqual(try XCTUnwrap(deep.nestingList(selection: .init(location: 3, length: 0), outdent: false)).box.text, "☐ Aufgabe")
    }
    func testNestedNumberingRestartsPerLevelAndParentCountsOn() throws {
        let start = box([("1. a", 0), ("2. b", 0), ("3. c", 0), ("4. d", 0)])
        let b = try XCTUnwrap(start.nestingList(selection: .init(location: 5, length: 0), outdent: false)).box
        XCTAssertEqual(b.text, "1. a\n1. b\n2. c\n3. d")
        let c = try XCTUnwrap(b.nestingList(selection: .init(location: 10, length: 0), outdent: false)).box
        XCTAssertEqual(c.text, "1. a\n1. b\n2. c\n2. d"); XCTAssertEqual(levels(c), [0, 1, 1, 0])
        // Outdenting the first child: it rejoins the parent list, the other child restarts.
        let back = try XCTUnwrap(c.nestingList(selection: .init(location: 5, length: 0), outdent: true)).box
        XCTAssertEqual(back.text, "1. a\n2. b\n1. c\n3. d"); XCTAssertEqual(levels(back), [0, 0, 1, 0])
        // Selection over several items moves them together.
        let both = try XCTUnwrap(start.nestingList(selection: .init(location: 5, length: 7), outdent: false)).box
        XCTAssertEqual(both.text, "1. a\n1. b\n2. c\n2. d")
    }
    func testNestingKeepsWordFormattingAndOnlyChangesIndent() throws {
        var source = box([("• fett", 0), ("• b", 0)])
        var bold = TextBoxStyle(); bold.bold = true; bold.indent = 0
        source.runs = [TextRun(location: 0, length: 2, style: source.runs![0].style), TextRun(location: 2, length: 5, style: bold),
                       TextRun(location: 7, length: 3, style: source.runs![1].style)]
        let nested = try XCTUnwrap(source.nestingList(selection: .init(location: 3, length: 0), outdent: false)).box
        XCTAssertEqual(nested.text, "◦ fett\n• b")
        XCTAssertTrue(nested.style(at: 3).bold); XCTAssertEqual(nested.style(at: 3).indent, 20)
        XCTAssertFalse(nested.style(at: 8).bold); XCTAssertEqual(nested.style(at: 8).indent, 0)
        XCTAssertNoThrow(try nested.validate())
    }

    // MARK: Renumbering

    private func edited(_ old: TextBox, _ new: String, caret: Int) -> (TextBox, NSRange) {
        var next = TextListEditing.changedRange(from: old.text, to: new).map { changed -> TextBox in
            // Typed text inherits the style before it (as UITextView does).
            let removed = (old.text as NSString).length - ((new as NSString).length - changed.length)
            return old.applying([.init(range: NSRange(location: changed.location, length: removed),
                replacement: (new as NSString).substring(with: changed))])
        } ?? old
        next.text = new
        return next.normalizingLists(after: old, selection: .init(location: caret, length: 0)) ?? (next, .init(location: caret, length: 0))
    }
    func testReturnInsideListShiftsFollowingNumbers() throws {
        let old = box([("1. a", 0), ("2. b", 0), ("3. c", 0)])
        let edit = try XCTUnwrap(TextListEditing.newline(in: old.text, range: .init(location: 4, length: 0)))
        let typed = apply([edit], to: old.text)
        XCTAssertEqual(typed, "1. a\n2. \n2. b\n3. c")
        let (result, caret) = edited(old, typed, caret: 8)
        XCTAssertEqual(result.text, "1. a\n2. \n3. b\n4. c"); XCTAssertEqual(caret.location, 8)
    }
    func testDeletingItemsRenumbersIncludingTheFirstItem() {
        let old = box([("1. a", 0), ("2. b", 0), ("3. c", 0)])
        XCTAssertEqual(edited(old, "1. a\n3. c", caret: 5).0.text, "1. a\n2. c")
        XCTAssertEqual(edited(old, "2. b\n3. c", caret: 0).0.text, "1. b\n2. c")
        XCTAssertEqual(edited(old, "1. a\n2. b", caret: 9).0.text, "1. a\n2. b")
    }
    func testMovingItemsAndBlankLinesRenumber() {
        let old = box([("1. a", 0), ("2. b", 0), ("3. c", 0)])
        // Cut "1. a\n" and paste it after c.
        let cut = edited(old, "2. b\n3. c", caret: 0).0
        XCTAssertEqual(edited(cut, cut.text + "\n1. a", caret: 14).0.text, "1. b\n2. c\n3. a")
        // Removing the blank line between two lists joins them.
        let split = box([("1. a", 0), ("", 0), ("1. b", 0)])
        XCTAssertEqual(edited(split, "1. a\n1. b", caret: 5).0.text, "1. a\n2. b")
    }
    func testTypedStartNumbersAndDistantListsStay() {
        XCTAssertEqual(edited(box([("Text", 0), ("", 0), ("3.", 0)]), "Text\n\n3. ", caret: 9).0.text, "Text\n\n3. ")
        let far = box([("1. a", 0), ("Text", 0), ("7. Mai", 0), ("9. Juni", 0)])
        XCTAssertEqual(edited(far, "1. ab\nText\n7. Mai\n9. Juni", caret: 5).0.text, "1. ab\nText\n7. Mai\n9. Juni")
        // Touching that list counts on from its own first number.
        XCTAssertEqual(edited(far, "1. a\nText\n7. Mai\n9. Juni!", caret: 23).0.text, "1. a\nText\n7. Mai\n8. Juni!")
        // Indented explanation text stays inside a list; normal text ends it.
        let inner = box([("1. a", 0), ("Erklärung", 1), ("5. b", 0), ("Normal", 0), ("4. c", 0)])
        XCTAssertEqual(edited(inner, "1. a\nErklärung\n5. b!\nNormal\n4. c", caret: 19).0.text, "1. a\nErklärung\n2. b!\nNormal\n4. c")
    }
    func testBulletToggleUsesLevelGlyph() {
        let source = box([("eins", 0), ("zwei", 1)])
        let edits = TextListEditing.toggle(.bullet, in: source.text, range: .init(location: 0, length: 9), level: source.listLevel(at:))
        XCTAssertEqual(apply(edits, to: source.text), "• eins\n◦ zwei")
        let nested = box([("• a", 0), ("◦ b", 1), ("• c", 0)])
        let numbered = TextListEditing.toggle(.numbered, in: nested.text, range: .init(location: 1, length: 0), level: nested.listLevel(at:))
        XCTAssertEqual(apply(numbered, to: nested.text), "1. a\n◦ b\n• c", "kind change stays on its level")
        XCTAssertTrue(TextListEditing.isActive(.bullet, in: "▪ x", range: .init(location: 1, length: 0)))
        XCTAssertEqual(TextListEditing.newline(in: "◦ x", range: .init(location: 3, length: 0))?.replacement, "\n◦ ")
    }
    func testNumberingContinuesAcrossFlowPages() throws {
        var book = try Notebook.blank(title: "Flow", appearance: NotebookAppearance())
        let rect = try XCTUnwrap(book.pages[0].writingRect(.page))
        var first = TextBox(x: rect.x, y: rect.y, width: rect.width, height: rect.height, text: "")
        first.flowID = UUID(); first.flowRegion = .page
        try book.replaceTextBoxes([first], pageID: book.pages[0].id)
        var typed = first; typed.text = "1. a\n2. b\n3. c\n4. d"
        // Six characters per page: "1. a\n2" never splits inside "3. c"? Use whole lines per page.
        let capacity: (TextBox) -> Int = { box in
            let text = box.text as NSString
            var end = 0
            for _ in 0..<2 { let line = text.lineRange(for: .init(location: end, length: 0)); if line.length == 0 { break }; end = NSMaxRange(line) }
            return max(1, end)
        }
        var (next, _) = try book.reflowText(pageID: book.pages[0].id, previous: first, replacement: typed,
            selection: .init(location: 19, length: 0), capacity: capacity)
        XCTAssertEqual(next.pages.map { $0.textBoxes![0].text }, ["1. a\n2. b\n", "3. c\n4. d"])
        // Return after "a" on page 1: the items on page 2 count on.
        let page1 = next.pages[0].textBoxes![0]
        var inserted = page1; inserted.text = "1. a\n2. \n2. b\n"; inserted.runs = nil
        let (after, focus) = try next.reflowText(pageID: next.pages[0].id, previous: page1, replacement: inserted,
            selection: .init(location: 8, length: 0), capacity: capacity)
        XCTAssertEqual(after.pages.flatMap { $0.textBoxes!.map(\.text) }.joined(), "1. a\n2. \n3. b\n4. c\n5. d")
        XCTAssertEqual(focus.pageID, after.pages[0].id); XCTAssertEqual(focus.selection.location, 8)
        // Editing on page 2 continues the numbering from page 1.
        next = after
        let last = try XCTUnwrap(next.pages.last?.textBoxes?.first)
        var changed = last; changed.text = last.text.replacingOccurrences(of: "5. d", with: "1. d"); changed.runs = nil
        let (fixed, _) = try next.reflowText(pageID: next.pages.last!.id, previous: last, replacement: changed,
            selection: .init(location: 0, length: 0), capacity: capacity)
        XCTAssertTrue(fixed.pages.last!.textBoxes![0].text.hasSuffix("5. d"))
    }

    func testParagraphSplitAcrossPagesIsNotReadAsNewItem() {
        // Page 1 ends inside item 2; page 2 starts with its continuation "2. Teil".
        let context = TextListEditing.context(after: "1. a\n2. lang", level: { _ in 0 })
        let text = "2. Teil\n9. c"
        let edits = TextListEditing.normalize(text, level: { _ in 0 }, changed: .init(location: 11, length: 1),
            context: context, continuation: true)
        XCTAssertEqual(apply(edits, to: text), "2. Teil\n3. c")
        XCTAssertNil(TextListEditing.numberedItem(in: text, at: 0, level: { _ in 0 }, continuation: true))
    }

    // MARK: Undo, caret, tasks

    func testAutomaticConversionIsItsOwnUndoStep() throws {
        var history = NotebookUndoHistory()
        var book = try Notebook.blank(title: "Undo", appearance: NotebookAppearance())
        let id = book.pages[0].id
        func set(_ text: String) throws -> Notebook {
            var next = book; try next.replaceTextBoxes([TextBox(id: id, text: text)], pageID: id); return next
        }
        let key = NotebookUndoHistory.Coalescing(key: "text", window: 1.5), now = Date()
        for text in ["-", "- "] {
            let next = try set(text); history.record(.text, before: book, after: next, coalescing: key, now: now); book = next
        }
        history.separateNextStep()
        let converted = try set("• "); history.record(.text, before: book, after: converted, coalescing: key, now: now); book = converted
        history.separateNextStep()
        let more = try set("• x"); history.record(.text, before: book, after: more, coalescing: key, now: now); book = more
        XCTAssertEqual(history.undoCount, 3)
        book = try XCTUnwrap(history.undo(book)).notebook
        book = try XCTUnwrap(history.undo(book)).notebook
        XCTAssertEqual(book.pages[0].textBoxes?.first?.text, "- ")
    }
    func testUndoCaretIsMappedIntoThePreviousText() {
        XCTAssertEqual(TextListEditing.caret(before: "abcd", after: "abXcd", selection: 3), 2)
        XCTAssertEqual(TextListEditing.caret(before: "[] x", after: "☐ x", selection: 2), 3)
        XCTAssertEqual(TextListEditing.caret(before: "abc", after: "abc", selection: 9), 3)
    }
    func testOpenTasksListUncheckedItemsInPageOrder() throws {
        var book = try Notebook.blank(title: "Aufgaben", appearance: NotebookAppearance())
        try book.replaceTextBoxes([TextBox(text: "☐ Mathe S. 12\n☑ Deutsch\n  ☐ Vokabeln\nNotiz")], pageID: book.pages[0].id)
        let tasks = book.openTasks
        XCTAssertEqual(tasks.map(\.text), ["Mathe S. 12", "Vokabeln"])
        XCTAssertEqual(tasks.map(\.pageIndex), [0, 0])
        XCTAssertEqual((book.pages[0].textBoxes![0].text as NSString).substring(with: tasks[1].body), "Vokabeln")
    }
    func testStyledEditsKeepRunsValid() throws {
        var source = TextBox(text: "ab😀cd")
        var red = TextBoxStyle(); red.color = .red
        source.runs = [TextRun(location: 2, length: 2, style: red)]
        let result = source.applying([.init(range: .init(location: 0, length: 1), replacement: "XY"), .init(range: .init(location: 6, length: 0), replacement: "!")])
        XCTAssertEqual(result.text, "XYb😀cd!")
        XCTAssertEqual(result.style(at: 3).color, .red); XCTAssertEqual(result.style(at: 0).color, .black)
        XCTAssertNoThrow(try result.validate())
        XCTAssertEqual(result.runs?.reduce(0) { $0 + $1.length }, (result.text as NSString).length)
    }
}

/// Value-level forms of the editor's list steps (the app applies the same
/// edits to its text storage); they keep `listNesting` and `normalize`
/// covered on whole boxes.
private extension TextBox {
    /// Renumbers/normalises lists after an edit from `previous` to this text.
    func normalizingLists(after previous: TextBox, selection: NSRange) -> (box: TextBox, selection: NSRange)? {
        guard let changed = TextListEditing.changedRange(from: previous.text, to: text) else { return nil }
        let restart = TextListEditing.numberedItem(in: previous.text, at: changed.location, level: previous.listLevel(at:))
        let edits = TextListEditing.normalize(text, level: listLevel(at:), changed: changed, restart: restart)
        guard !edits.isEmpty else { return nil }
        return (applying(edits), TextListEditing.selection(selection, after: edits))
    }
    func nestingList(selection: NSRange, outdent: Bool) -> (box: TextBox, selection: NSRange)? {
        guard let plan = listNesting(selection: selection, outdent: outdent) else { return nil }
        var box = self
        for (range, indent) in zip(plan.paragraphs, plan.indents) { box = box.restyled([range]) { $0.indent = indent } }
        box = box.applying(plan.markers).applying(plan.renumbering)
        let caret = TextListEditing.selection(TextListEditing.selection(selection, after: plan.markers), after: plan.renumbering)
        return box == self ? nil : (box, caret)
    }
}
