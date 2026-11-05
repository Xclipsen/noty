import Foundation
import XCTest
@testable import NotebookCore

extension TextIndentEditing {
    /// Test form of Return in a text without paragraph indents: the edit, or nil.
    static func newlineEdit(in text: String, range: NSRange) -> TextListEditing.Edit? {
        if case .edit(let edit)? = newline(TextBox(text: text), range: range) { return edit }
        return nil
    }
}

/// The rules of docs/TEXT-FIELDS.md „Einzug und Listen“ (Einzug-Audit 05.11.2026).
final class TextIndentTests: XCTestCase {
    private func apply(_ edits: [TextListEditing.Edit], to text: String) -> String {
        let value = NSMutableString(string: text)
        for edit in edits.sorted(by: { $0.range.location > $1.range.location }) { value.replaceCharacters(in: edit.range, with: edit.replacement) }
        return value as String
    }
    private func box(_ text: String, indents: [Double] = []) -> TextBox {
        var box = TextBox(text: text)
        guard !indents.isEmpty else { return box }
        let source = text as NSString
        var runs: [TextRun] = [], cursor = 0
        for indent in indents where cursor < source.length {
            let line = source.lineRange(for: NSRange(location: cursor, length: 0))
            var style = TextBoxStyle(); style.indent = indent
            runs.append(TextRun(location: line.location, length: line.length, style: style)); cursor = NSMaxRange(line)
        }
        box.runs = runs
        return box
    }
    private func tab(_ text: String, _ location: Int, _ length: Int = 0, outdent: Bool = false, indents: [Double] = [],
                     buttons: Bool = false) -> TextBox? {
        let source = box(text, indents: indents)
        return TextIndentEditing.tab(source, selection: NSRange(location: location, length: length), outdent: outdent,
                                     wholeParagraphs: buttons).map(source.applying)
    }
    /// About 14-pt system text: 7.5 pt per character, 4 pt per space.
    private func measure(_ text: NSString) -> (NSRange) -> Double {
        { range in text.substring(with: range).reduce(0) { $0 + ($1 == " " ? 4 : 7.5) } }
    }
    private func edge(_ value: String, at start: Int = 0, indent: Double = 0, width: Double = 300,
                      alignment: TextAlignment? = nil) -> Double {
        let text = value as NSString
        return TextIndentLayout.hangingEdge(in: text, at: start, indent: indent, tabInterval: 35, width: width, em: 14,
                                            alignment: alignment, measure: measure(text))
    }

    // MARK: Prefix and level

    func testPrefixKnowsListsHangingMarksAndLabels() {
        func prefix(_ text: String) -> TextParagraphPrefix { TextParagraphPrefix(in: text as NSString, at: 0) }
        XCTAssertEqual(prefix("\t\t• a").mark, .list(.bullet)); XCTAssertEqual(prefix("\t\t• a").body, 4)
        XCTAssertEqual(prefix("- a").mark, .list(.bullet), "„-“ is a list mark of its own")
        XCTAssertEqual(prefix("12. a").mark, .list(.numbered)); XCTAssertEqual(prefix("12. a").marker, NSRange(location: 0, length: 3))
        XCTAssertEqual(prefix("☐ a").mark, .list(.checkbox))
        for arrow in ["-> a", "→ a", "=> a", "⇒ a", "->\ta"] { XCTAssertEqual(prefix(arrow).mark, .hanging, arrow) }
        XCTAssertEqual(prefix("•\ta").mark, .hanging, "a mark before a tab only hangs")
        XCTAssertEqual(prefix("Bsp.:\t\tA aus").label, NSRange(location: 0, length: 5)); XCTAssertEqual(prefix("Bsp.:\t\tA aus").body, 7)
        XCTAssertNil(prefix("Bsp.:\t\tA aus").mark); XCTAssertEqual(prefix("Bsp.:\t\tA aus").markEnd, 0)
        XCTAssertNil(prefix("Bsp.: A aus").label, "a label needs a tab")
        XCTAssertNil(prefix("Zusammenfassung:\tA").label, "longer than 12 characters")
        // A label also behind a mark: the text hangs behind its tab.
        let marked = prefix("• Bsp.:\tText")
        XCTAssertEqual(marked.mark, .list(.bullet)); XCTAssertEqual(marked.markEnd, 2)
        XCTAssertEqual(marked.label, NSRange(location: 2, length: 5)); XCTAssertEqual(marked.body, 8)
        XCTAssertEqual(prefix("-> Bsp.:\tText").body, 9)
        XCTAssertNil(prefix("z. B. so").mark)
        XCTAssertNil(prefix("->x").mark)
        XCTAssertNil(prefix("x").mark); XCTAssertEqual(prefix("x").body, 0)
        XCTAssertEqual(prefix("\t\t").body, 2); XCTAssertTrue(prefix("\t\t").isEmpty)
        XCTAssertEqual(prefix("  \t• a").spaces, 2); XCTAssertEqual(prefix("  \t• a").tabs, 1)
    }
    func testLevelIsIndentStepsPlusLeadingTabs() {
        let text = "\t\t• a" as NSString
        XCTAssertEqual(TextParagraphPrefix(in: text, at: 0).level(indent: nil), 2)
        XCTAssertEqual(TextParagraphPrefix(in: text, at: 0).level(indent: 20), 3)
        XCTAssertEqual(TextParagraphPrefix(in: "  • a", at: 0).level(indent: 0), 0, "spaces are no level")
        // Numbering: a tab or an older indent both nest; „2. c“ counts on in the outer run.
        let nested = "1. a\n\t1. b\n2. c"
        XCTAssertTrue(TextListEditing.normalize(nested, level: { _ in 0 }, changed: NSRange(location: 5, length: 0)).isEmpty)
        let flat = "1. a\n\t5. b\n7. c"
        XCTAssertEqual(apply(TextListEditing.normalize(flat, level: { _ in 0 }, changed: NSRange(location: 11, length: 4)), to: flat),
                       "1. a\n\t5. b\n2. c")
        // Typing never changes the glyph of an older bullet behind tabs.
        XCTAssertTrue(TextListEditing.normalize("\t• a", level: { _ in 0 }, changed: NSRange(location: 3, length: 1)).isEmpty)
    }
    func testListButtonAndAutoListUseTheTabLevel() {
        XCTAssertEqual(apply(TextListEditing.toggle(.bullet, in: "\t\tx", range: NSRange(location: 3, length: 0), level: { _ in 0 }), to: "\t\tx"),
                       "\t\t▪ x")
        XCTAssertEqual(apply(TextListEditing.toggle(.bullet, in: "Halllo\n\t\t\t\t\thallo", range: NSRange(location: 17, length: 0), level: { _ in 0 }),
                             to: "Halllo\n\t\t\t\t\thallo"), "Halllo\n\t\t\t\t\t▪ hallo", "the mark goes behind the tabs")
        XCTAssertEqual(TextListEditing.autoList(in: "\t* ", caret: 3)?.replacement, "◦ ")
        XCTAssertEqual(TextListEditing.autoList(in: "* ", caret: 2, level: 1)?.replacement, "◦ ")
        XCTAssertNil(TextListEditing.autoList(in: "- ", caret: 2), "„- “ stays")
        XCTAssertNil(TextListEditing.autoList(in: "Halllo\n\t\t\t\t\t- ", caret: 14))
        XCTAssertEqual(TextListEditing.autoList(in: "[] ", caret: 3)?.replacement, "☐ ")
        XCTAssertEqual(TextListEditing.autoList(in: "1) ", caret: 3)?.replacement, "1. ")
    }

    // MARK: Tab and ⇧Tab

    func testTabInThePrefixIndentsTheParagraphElsewhereTypesATab() throws {
        // Caret in front of the text (also right behind the mark): one level deeper.
        XCTAssertEqual(tab("• Bsp.:", 2)?.text, "\t◦ Bsp.:")
        XCTAssertEqual(tab("• Bsp.:", 0)?.text, "\t◦ Bsp.:")
        XCTAssertEqual(tab("\t◦ a", 1)?.text, "\t\t▪ a")
        XCTAssertEqual(tab("- a", 2)?.text, "\t- a", "„-“ keeps its mark")
        XCTAssertEqual(tab("Text", 0)?.text, "\tText")
        XCTAssertEqual(tab("", 0)?.text, "\t")
        // In the text: an ordinary tab at the caret, also in lists, arrows and labels.
        XCTAssertNil(tab("• Bsp.:", 7), "„• Bsp.:|“ types a tab")
        XCTAssertNil(tab("• Bsp.:A aus", 7))
        XCTAssertNil(tab("-> Bsp.:A aus", 8))
        XCTAssertNil(tab("Text", 2))
        XCTAssertNil(tab("Bsp.:\t", 6), "the tabs behind a label are the user's alignment")
        XCTAssertNil(tab("\tBsp.:\t\tA", 7))
        XCTAssertEqual(tab("\tBsp.:\t\tA", 1)?.text, "\t\tBsp.:\t\tA")
        // A selection inside one paragraph that starts in the prefix moves it, one in the text is replaced.
        XCTAssertEqual(tab("• abc", 0, 4)?.text, "\t◦ abc")
        XCTAssertNil(tab("• abc", 3, 2))
        // The indent button: wherever the caret is.
        XCTAssertEqual(tab("• Bsp.:A", 7, buttons: true)?.text, "\t◦ Bsp.:A")
    }
    func testShiftTabRemovesOnlyALeadingTabNeverOneInTheLine() {
        XCTAssertEqual(tab("\tBsp.:\t\tA", 7, outdent: true)?.text, "Bsp.:\t\tA")
        XCTAssertNil(tab("Bsp.:\t\tA", 6, outdent: true), "no leading tab, no indent: nothing")
        XCTAssertNil(tab("a\tb", 2, outdent: true))
        XCTAssertEqual(tab("      x", 7, outdent: true)?.text, "  x", "up to four spaces")
        XCTAssertEqual(tab("\t\t▪ a", 5, outdent: true)?.text, "\t◦ a")
        // Without a tab the older indent goes down by 20 pt; the bullet follows the level.
        let old = tab("◦ a", 2, outdent: true, indents: [20])
        XCTAssertEqual(old?.text, "• a"); XCTAssertEqual(old?.style(at: 0).indent, 0)
        let both = tab("\t▪ a", 2, outdent: true, indents: [20])
        XCTAssertEqual(both?.text, "◦ a"); XCTAssertEqual(both?.style(at: 0).indent, 20, "a tab goes first")
    }
    func testSelectionsOverParagraphsMoveEveryOneMixedOrNot() {
        XCTAssertEqual(tab("• a\nb\n• c", 0, 9)?.text, "\t◦ a\n\tb\n\t◦ c", "list and normal paragraphs alike")
        XCTAssertEqual(tab("\t◦ a\n\tb\n\t◦ c", 0, 12, outdent: true)?.text, "• a\nb\n• c")
        XCTAssertEqual(tab("eins\n\nzwei", 1, 8)?.text, "\teins\n\n\tzwei", "empty paragraphs stay empty")
        XCTAssertEqual(tab("a\nb\nc", 0, 4)?.text, "\ta\n\tb\nc", "ending behind a break leaves the next one")
        XCTAssertEqual(tab("a\nb\nc", 2, 0, buttons: true)?.text, "a\n\tb\nc")
        // Mixed with an older indent: ⇧Tab takes its tab from one, 20 pt from the other.
        let mixed = tab("\ta\nb", 0, 4, outdent: true, indents: [0, 20])
        XCTAssertEqual(mixed?.text, "a\nb"); XCTAssertEqual(mixed?.style(at: 2).indent, 0)
    }

    // MARK: Return

    func testReturnContinuesListsAndWhiteSpaceButNoArrowsOrLabels() {
        func enter(_ text: String, _ location: Int? = nil) -> String? {
            TextIndentEditing.newlineEdit(in: text, range: NSRange(location: location ?? (text as NSString).length, length: 0))?.replacement
        }
        XCTAssertEqual(enter("• abc"), "\n• ")
        XCTAssertEqual(enter("\t\t◦ abc"), "\n\t\t◦ ")
        XCTAssertEqual(enter("- abc"), "\n- ")
        XCTAssertEqual(enter("19. abc"), "\n20. ")
        XCTAssertEqual(enter("\t☑ abc"), "\n\t☐ ")
        XCTAssertEqual(enter("\tabc"), "\n\t", "every indented paragraph keeps its white space")
        XCTAssertEqual(enter("  abc"), "\n  ")
        XCTAssertNil(enter("-> Fazit"), "an arrow is not continued")
        XCTAssertEqual(enter("\t-> Fazit"), "\n\t", "only its white space")
        XCTAssertEqual(enter("\t\tBsp.:\t\tA aus BI"), "\n\t\t")
        XCTAssertNil(enter("Bsp.:\t\tA aus BI"))
        XCTAssertNil(enter("abc"))
        XCTAssertEqual(enter("\t\t"), "\n\t\t", "a line of white space: the same white space, nothing deleted")
        XCTAssertNil(enter("\t\tabc", 1), "caret inside the prefix: ordinary")
        XCTAssertNil(enter("• abc", 0))
        XCTAssertEqual(enter("• abc", 2), "\n• ", "right behind the mark: the item splits")
    }
    func testReturnOnAnEmptyItemMovesOutALevelThenEndsTheList() throws {
        func enter(_ text: String, indents: [Double] = []) -> TextBox? {
            let source = box(text, indents: indents)
            switch TextIndentEditing.newline(source, range: NSRange(location: (text as NSString).length, length: 0)) {
            case .edit(let edit)?: return source.applying([edit])
            case .plan(let plan)?: return source.applying(plan)
            case nil: return nil
            }
        }
        XCTAssertEqual(enter("\t\t▪ ")?.text, "\t◦ ")
        XCTAssertEqual(enter("\t◦ ")?.text, "• ")
        XCTAssertEqual(enter("• ")?.text, "", "level 0: the mark goes")
        XCTAssertEqual(enter("a\n\t1. ")?.text, "a\n1. ")
        let old = try XCTUnwrap(enter("◦ ", indents: [20]))
        XCTAssertEqual(old.text, "• "); XCTAssertEqual(old.style(at: 0).indent, 0)
        XCTAssertEqual(enter("  - ")?.text, "  ", "spaces are no level, they stay")
    }

    /// Review 05.11.2026, Befund 8: spaces in front of the tabs („ ⇥• “) do
    /// not keep an item on its level.
    func testOutdentTakesTheLastLeadingTabAlsoBehindSpaces() throws {
        func enter(_ text: String) -> String? {
            let source = box(text)
            switch TextIndentEditing.newline(source, range: NSRange(location: (text as NSString).length, length: 0)) {
            case .edit(let edit)?: return source.applying([edit]).text
            case .plan(let plan)?: return source.applying(plan).text
            case nil: return nil
            }
        }
        XCTAssertEqual(enter(" \t◦ "), " • ", "Return on the empty item: one level out")
        XCTAssertEqual(enter(" \t\t▪ "), " \t◦ ")
        XCTAssertEqual(enter(" • "), " ", "level 0: the mark goes, the space stays")
        XCTAssertEqual(tab(" \t◦ a", 5, outdent: true)?.text, " • a", "⇧Tab alike")
        XCTAssertEqual(tab("  \tx", 4, outdent: true)?.text, "  x")
        XCTAssertEqual(tab("\t  x", 4, outdent: true)?.text, "  x")
        XCTAssertEqual(tab("   x", 3, outdent: true)?.text, "x", "without a tab: the spaces")
    }

    /// Review 05.11.2026, Befund 7: `>` and `<` of the keyboard mode follow
    /// the rule of Tab and ⇧Tab in the prefix.
    func testKeyboardModeIndentMovesMarksAndNumbers() throws {
        var engine = TextEngine(text: "1. a\n2. b\n3. c", caret: 6)
        engine.perform(.indent)
        XCTAssertEqual(engine.string, "1. a\n\t1. b\n2. c")
        engine.perform(.unindent)
        XCTAssertEqual(engine.string, "1. a\n2. b\n3. c")
        var bullets = TextEngine(text: "• a\n• b", caret: 5)
        bullets.perform(.indent, count: 2)
        XCTAssertEqual(bullets.string, "• a\n\t\t▪ b", "two levels, the glyph of the second")
        bullets.perform(.unindent)
        XCTAssertEqual(bullets.string, "• a\n\t◦ b")
        // Everything selected: every non-blank line, the list does not restart behind the blank line.
        var all = TextEngine(text: "1. a\n\n2. b\nText")
        all.perform(.selectAll)
        all.perform(.indent)
        XCTAssertEqual(all.string, "\t1. a\n\n\t2. b\n\tText")
        // The older paragraph indent counts as a level and stays.
        func indented(_ text: String) -> TextBox {
            var box = TextBox(text: text); var style = TextBoxStyle(); style.indent = 20
            box.runs = [TextRun(location: 0, length: (text as NSString).length, style: style)]
            return box
        }
        var formatted = TextEngine(text: "◦ a", caret: 2)
        formatted.paragraphFormats = indented("◦ a")
        formatted.perform(.indent)
        XCTAssertEqual(formatted.string, "\t▪ a")
        formatted.paragraphFormats = indented(formatted.string) // the app hands in the field as it stands
        formatted.perform(.unindent)
        XCTAssertEqual(formatted.string, "◦ a")
        formatted.paragraphFormats = indented(formatted.string)
        formatted.perform(.unindent)
        XCTAssertEqual(formatted.string, "◦ a", "the older indent is no tab to take")
    }

    // MARK: ⌫

    func testBackspaceRemovesTheMarkKeepsTheIndentThenReducesAnOlderIndent() throws {
        func back(_ text: String, _ caret: Int, indents: [Double] = []) -> TextBox? {
            let source = box(text, indents: indents)
            switch TextIndentEditing.backspace(source, caret: caret) {
            case .edit(let edit)?: return source.applying([edit])
            case .plan(let plan)?: return source.applying(plan)
            case nil: return nil
            }
        }
        XCTAssertEqual(back("• text", 2)?.text, "text", "no lone „•“ stays")
        XCTAssertEqual(back("\t\t◦ text", 4)?.text, "\t\ttext", "the tabs stay")
        XCTAssertEqual(back("12. text", 4)?.text, "text")
        XCTAssertEqual(back("• ", 2)?.text, "")
        XCTAssertNil(back("\t\ttext", 2), "behind tabs: the usual ⌫ deletes one")
        XCTAssertNil(back("• te", 3))
        XCTAssertNil(back("-> x", 3), "an arrow is text")
        XCTAssertNil(back("a\nb", 2), "no indent: the paragraphs join")
        let reduced = try XCTUnwrap(back("a\n◦ b", 2, indents: [0, 20]))
        XCTAssertEqual(reduced.text, "a\n• b"); XCTAssertEqual(reduced.style(at: 2).indent, 0)
        XCTAssertEqual(try XCTUnwrap(back("text", 0, indents: [40])).style(at: 0).indent, 20)
    }

    // MARK: Hanging indent

    func testHangingEdgeIsTheFirstTextCharacter() {
        XCTAssertEqual(edge("Text ohne Einzug"), 0)
        XCTAssertEqual(edge("• a"), 11.5)
        XCTAssertEqual(edge("\t\t• a"), 81.5, "tabs on the field's grid, then the mark")
        XCTAssertEqual(edge("• a", indent: 20), 31.5, "from the stored indent")
        XCTAssertEqual(edge("-> Fazit lang"), 19)
        XCTAssertEqual(edge("→\tFazit"), 35)
        XCTAssertEqual(edge("Bsp.:\t\tA aus BI kauft ein Haus"), 105, "a label hangs at the text behind its tabs")
        XCTAssertEqual(edge("\t\tBsp.:\t\tA aus"), 175)
        XCTAssertEqual(edge("\t\tnur Text"), 70, "a paragraph indented by tabs hangs, too")
        XCTAssertEqual(edge("a\n\t• b", at: 2), 46.5)
    }
    func testHangingEdgeOfScreenshotThreeAndItsLimit() {
        // einzug-3: five tabs and a bullet in a 253-pt field: the mark at 175 pt,
        // the following lines under its text, not at 0.
        let text = "Halllo\n\t\t\t\t\t• hallo hallo was geht "
        XCTAssertEqual(edge(text, at: 7, width: 253), 186.5)
        // Narrower: at most width − 4 em, never back to 0 (no 50-% rule).
        XCTAssertEqual(edge(text, at: 7, width: 200), 200 - 56)
        XCTAssertEqual(edge(text, at: 7, width: 150), 150 - 56)
        XCTAssertEqual(edge(text, at: 7, indent: 120, width: 150), 120, "never left of the first line")
        XCTAssertEqual(edge("\t\t• a", width: 300, alignment: .center), 0, "centred text does not hang")
        XCTAssertEqual(edge("\t\t• a", indent: 20, alignment: .right), 20)
        XCTAssertEqual(edge("\t\t• a", alignment: .justified), 81.5)
    }
    func testTheStoredIndentIsTheFirstLinesNeverTheHangingEdge() {
        // `TextBoxStyle(attributes:)` reads the paragraph through this rule.
        XCTAssertEqual(TextIndentLayout.storedIndent(firstLineHeadIndent: 20, headIndent: 186.5), 20)
        XCTAssertEqual(TextIndentLayout.storedIndent(firstLineHeadIndent: 0, headIndent: 81.5), 0)
        XCTAssertEqual(TextIndentLayout.storedIndent(firstLineHeadIndent: 400, headIndent: 0), 240)
        XCTAssertEqual(TextIndentLayout.storedIndent(firstLineHeadIndent: .nan, headIndent: 10), 0)
        // Round trip: stored indent → laid out (first line, hanging edge) → stored indent.
        for indent in [0.0, 20, 40, 240] {
            let laidOut = (first: indent, head: edge("\t• Text", indent: indent))
            XCTAssertGreaterThan(laidOut.head, laidOut.first)
            XCTAssertEqual(TextIndentLayout.storedIndent(firstLineHeadIndent: laidOut.first, headIndent: laidOut.head), indent)
        }
    }

    // MARK: Older fields

    func testHangingOnlyWhereItFitsTheStoredHeight() {
        let field = TextBox(x: 40, y: 700, width: 200, height: 40, text: "\t• lang")
        XCTAssertTrue(TextIndentLayout.hangs(field, heightWithHanging: 40))
        XCTAssertTrue(TextIndentLayout.hangs(field, heightWithHanging: 40.9), "the overflow tolerance")
        XCTAssertFalse(TextIndentLayout.hangs(field, heightWithHanging: 60), "more lines: laid out as before, without")
        var flow = field; flow.flowID = UUID()
        XCTAssertFalse(TextIndentLayout.hangs(flow, heightWithHanging: 10), "flow segments never hang")
    }

    func testTheStoredHeightComesFromTheShownLayout() {
        let page = PageRect(x: 0, y: 0, width: 595, height: 842)
        for (y, hung, plain) in [(100.0, 80.0, 60.0), (700, 130, 100), (700, 150, 160), (800, 60, 40), (810, 60, 20), (0, 10, 10)] {
            var box = TextBox(x: 40, y: y, width: 200, height: 20, text: "\t• lang")
            let result = TextIndentLayout.fittedHeight(hung: hung, plain: { plain }, line: 17,
                                                       room: { box.maximumHeight(in: page, minimum: $0) })
            box.height = result.height
            XCTAssertEqual(TextIndentLayout.hangs(box, heightWithHanging: hung), result.hangs, "y \(y): grow and the layout agree")
            if result.hangs { XCTAssertEqual(result.height, max(17, hung), accuracy: 1) }
            else { XCTAssertEqual(result.height, min(max(17, plain), 842 - y), accuracy: 0.01, "without hanging, clamped as before") }
        }
        // At the page edge (142 pt left): 142.5 pt with hanging fit within the tolerance, 160 do not, then 100 without.
        var edge = TextBox(x: 40, y: 700, width: 200, height: 20, text: "x")
        let fits = TextIndentLayout.fittedHeight(hung: 142.5, plain: { 100 }, line: 17, room: { edge.maximumHeight(in: page, minimum: $0) })
        XCTAssertEqual(fits.height, 142, accuracy: 0.01); XCTAssertTrue(fits.hangs)
        let over = TextIndentLayout.fittedHeight(hung: 160, plain: { 100 }, line: 17, room: { edge.maximumHeight(in: page, minimum: $0) })
        XCTAssertEqual(over.height, 100); XCTAssertFalse(over.hangs)
        edge.height = over.height
        XCTAssertFalse(TextIndentLayout.hangs(edge, heightWithHanging: 160))
    }

    func testSelectingOrMovingAnOlderFieldKeepsItsHeightAndLayout() {
        let page = PageRect(x: 0, y: 0, width: 595, height: 842)
        // An older list field: 60 pt without hanging (stored), 80 pt with; it does not hang.
        let old = TextBox(x: 40, y: 100, width: 200, height: 60, text: "\t• lang")
        XCTAssertFalse(TextIndentLayout.hangs(old, heightWithHanging: 80))
        let kept = TextIndentLayout.keptHeight(old, hung: 80, plain: { 60 }, line: 17, room: { old.maximumHeight(in: page, minimum: $0) })
        XCTAssertEqual(kept.height, 60); XCTAssertFalse(kept.hangs)
        var after = old; after.height = kept.height
        XCTAssertFalse(TextIndentLayout.hangs(after, heightWithHanging: 80), "still laid out without")
        // A field that hangs keeps hanging, measured with.
        let hanging = TextBox(x: 40, y: 100, width: 200, height: 80, text: "\t• lang")
        let same = TextIndentLayout.keptHeight(hanging, hung: 80, plain: { 60 }, line: 17, room: { hanging.maximumHeight(in: page, minimum: $0) })
        XCTAssertEqual(same.height, 80); XCTAssertTrue(same.hangs)
        // An edit or a new width may bring it into hanging indents.
        XCTAssertTrue(TextIndentLayout.fittedHeight(hung: 80, plain: { 60 }, line: 17, room: { old.maximumHeight(in: page, minimum: $0) }).hangs)
    }

    /// Review 05.11.2026, Befund 2: tapping, moving and snapping never flip
    /// the mode, but they repair a height that is too small.
    func testKeptHeightRepairsATooSmallHeightWithoutFlippingTheMode() {
        let page = PageRect(x: 0, y: 0, width: 595, height: 842)
        func kept(_ box: TextBox, hung: Double, plain: Double) -> (height: Double, hangs: Bool) {
            TextIndentLayout.keptHeight(box, hung: hung, plain: { plain }, line: 17, room: { box.maximumHeight(in: page, minimum: $0) })
        }
        // No prefix: both layouts are the same; 40 pt stored, 60 pt needed: repaired.
        let plainField = TextBox(x: 40, y: 100, width: 200, height: 40, text: "ein langer Absatz")
        let repaired = kept(plainField, hung: 60, plain: 60)
        XCTAssertEqual(repaired.height, 60)
        var after = plainField; after.height = repaired.height
        XCTAssertFalse(after.overflows(textHeight: 60), "no longer red")
        // Too tall: down to the text, too.
        XCTAssertEqual(kept(TextBox(x: 40, y: 100, width: 200, height: 120, text: "kurz"), hung: 34, plain: 34).height, 34)
        // An older list field without hanging (stored 60, with hanging 80): unchanged, still without.
        let old = TextBox(x: 40, y: 100, width: 200, height: 60, text: "\t• lang")
        let tapped = kept(old, hung: 80, plain: 60)
        XCTAssertEqual(tapped.height, 60); XCTAssertFalse(tapped.hangs)
        // Too small even without: the height without, never into the hanging indents that need more.
        let small = TextBox(x: 40, y: 100, width: 200, height: 40, text: "\t• lang")
        let grown = kept(small, hung: 80, plain: 60)
        XCTAssertEqual(grown.height, 60); XCTAssertFalse(grown.hangs)
        after = small; after.height = grown.height
        XCTAssertFalse(TextIndentLayout.hangs(after, heightWithHanging: 80))
        // Within the tolerance both layouts are as high: the new height may be taken.
        XCTAssertEqual(kept(small, hung: 60.5, plain: 60).height, 60)
        // A hanging field stays hanging, at its height with hanging indents.
        let hanging = TextBox(x: 40, y: 100, width: 200, height: 80, text: "\t• lang")
        let same = kept(hanging, hung: 80, plain: 60)
        XCTAssertEqual(same.height, 80); XCTAssertTrue(same.hangs)
        let roomy = TextBox(x: 40, y: 100, width: 200, height: 100, text: "\t• lang")
        let shrunk = kept(roomy, hung: 80, plain: 60)
        XCTAssertEqual(shrunk.height, 80); XCTAssertTrue(shrunk.hangs, "measured with hanging, never down to 60 without")
    }

    // MARK: Arrows

    func testArrowsAreReplacedWithTheirSpaceAndComeBackWithBackspace() throws {
        func replaced(_ text: String) -> String? {
            TextArrowReplacement.replacement(in: text, caret: (text as NSString).length).map { apply([$0.edit], to: text) }
        }
        XCTAssertEqual(replaced("-> "), "→ ")
        XCTAssertEqual(replaced("=> "), "⇒ ")
        XCTAssertEqual(replaced("<- "), "← ")
        XCTAssertEqual(replaced("<-> "), "↔ ")
        XCTAssertEqual(replaced("Ort -> "), "Ort → ")
        XCTAssertEqual(replaced("\t-> "), "\t→ ")
        XCTAssertEqual(replaced("a\n-> "), "a\n→ ")
        XCTAssertNil(replaced("->"), "only with the following space")
        XCTAssertNil(replaced("x-> "), "only at the start or behind white space")
        XCTAssertNil(replaced("2+2=> "))
        XCTAssertNil(replaced("x <= "), "no ≤ ≥ ≠ ±")
        XCTAssertNil(replaced(">= ")); XCTAssertNil(replaced("+- ")); XCTAssertNil(replaced("!= "))
        XCTAssertNil(replaced("--> "))
        // ⌫ right behind it: what was typed comes back, the caret behind it.
        let replacement = try XCTUnwrap(TextArrowReplacement.replacement(in: "Ort -> ", caret: 7))
        let written = apply([replacement.edit], to: "Ort -> ")
        let back = try XCTUnwrap(TextArrowReplacement.restoring(replacement, in: written, caret: 6))
        XCTAssertEqual(apply([back], to: written), "Ort -> ")
        XCTAssertEqual(TextListEditing.selection(NSRange(location: 6, length: 0), after: [back]).location, 7)
        XCTAssertNil(TextArrowReplacement.restoring(replacement, in: written, caret: 5), "not elsewhere")
        XCTAssertNil(TextArrowReplacement.restoring(replacement, in: "Ort x ", caret: 6), "not after another change")
    }

    // MARK: Review fixes

    func testASecondTabBehindAMarkAndATabIsATab() {
        XCTAssertNil(tab("1.\tText", 3), "„1.\\t|Text“")
        XCTAssertNil(tab("•\t", 2)); XCTAssertNil(tab("-\t", 2)); XCTAssertNil(tab("->\t", 3))
        XCTAssertNil(tab("•  a", 3), "only behind exactly one space")
        XCTAssertNil(tab("• Bsp.:\tText", 8), "behind a label's tab")
        XCTAssertEqual(tab("-> a", 3)?.text, "\t-> a", "behind an arrow and one space it indents")
        XCTAssertEqual(tab("  • a", 1)?.text, "\t  ◦ a", "inside the leading white space")
    }
    func testTabTurnsAnOlderIndentIntoTabsAndKeepsTheLevel() throws {
        // One tab per 20 pt of the older indent, then one more: the level goes up by one,
        // the mark follows it, for every font size (the tab grid does not count).
        for size in [12.0, 14, 17, 30] {
            for (text, indent, expected) in [("◦ a", 20.0, "\t\t▪ a"), ("• a", 60, "\t\t\t\t◦ a"), ("▪ a", 100, "\t\t\t\t\t\t• a"),
                                              ("3. a", 40, "\t\t\t1. a"), ("\t◦ a", 20, "\t\t\t• a"), ("Text", 40, "\t\t\tText")] {
                var source = box(text, indents: [indent]); source.style.fontSize = size
                source.runs = source.runs?.map { var run = $0; run.style.fontSize = size; return run }
                let caret = (text as NSString).length - 1
                let plan = try XCTUnwrap(TextIndentEditing.tab(source, selection: NSRange(location: caret, length: 0), outdent: false, wholeParagraphs: true))
                let result = source.applying(plan)
                XCTAssertEqual(result.text, expected, "\(text) \(indent) pt, \(size) pt")
                XCTAssertEqual(result.style(at: 0).indent, 0)
                let old = TextParagraphPrefix(in: source.text as NSString, at: 0).level(indent: indent)
                XCTAssertEqual(TextParagraphPrefix(in: result.text as NSString, at: 0).level(indent: 0), old + 1)
            }
        }
        // ⇧Tab on an older indent: 20 pt less, as before.
        XCTAssertEqual(tab("▪ a", 2, outdent: true, indents: [60])?.style(at: 0).indent, 40)
        // Without a paragraph format path the indent stays and counts as a fixed level.
        let source = box("◦ a", indents: [60])
        let kept = try XCTUnwrap(TextIndentEditing.tab(source, selection: NSRange(location: 2, length: 0), outdent: false, canChangeIndent: false))
        XCTAssertTrue(kept.indents.isEmpty); XCTAssertEqual(source.applying(kept).text, "\t◦ a", "level 3 + 1 tab = 4 (◦)")
    }
    func testReturnReplacesASelectionFirst() throws {
        func enter(_ text: String, _ range: NSRange, indents: [Double] = [], canChangeIndent: Bool = true) -> String? {
            let source = box(text, indents: indents)
            switch TextIndentEditing.newline(source, range: range, canChangeIndent: canChangeIndent) {
            case .edit(let edit)?: return source.applying([edit]).text
            case .plan(let plan)?: return source.applying(plan).text
            case nil: return nil
            }
        }
        XCTAssertEqual(enter("• Text", NSRange(location: 2, length: 4)), "", "the item without its selection is empty: it ends")
        XCTAssertEqual(enter("\t◦ Text", NSRange(location: 3, length: 4)), "• ", "nested: one level out, the selection gone")
        XCTAssertEqual(enter("• Text mehr", NSRange(location: 2, length: 5)), "• \n• mehr")
        XCTAssertEqual(enter("\tab cd", NSRange(location: 2, length: 2)), "\ta\n\tcd")
        XCTAssertNil(enter("• eins\n• zwei", NSRange(location: 4, length: 6)), "over two paragraphs: ordinary")
        XCTAssertNil(enter("\t• Text", NSRange(location: 1, length: 3)), "starting in the prefix: ordinary")
        // The older indent cannot change (text document): the mark goes instead of staying.
        XCTAssertEqual(enter("◦ ", NSRange(location: 2, length: 0), indents: [20], canChangeIndent: false), "")
        XCTAssertEqual(enter("\t▪ ", NSRange(location: 3, length: 0), indents: [20], canChangeIndent: false), "◦ ")
    }
    func testBufferWithoutParagraphFormatsKeepsTheOlderIndent() {
        let source = box("◦ a", indents: [20])
        XCTAssertNil(TextIndentEditing.tab(source, selection: NSRange(location: 2, length: 0), outdent: true, canChangeIndent: false))
        XCTAssertNil(TextIndentEditing.backspace(box("a\nb", indents: [0, 20]), caret: 2, canChangeIndent: false))
        if case .edit(let edit)? = TextIndentEditing.backspace(source, caret: 2, canChangeIndent: false) {
            XCTAssertEqual(source.applying([edit]).text, "a")
        } else { XCTFail("the mark goes") }
    }
    func testFlowContinuationIsNotItsParagraphsStart() {
        let source = box("Rest des Absatzes\n• b")
        XCTAssertNil(TextIndentEditing.tab(source, selection: NSRange(location: 0, length: 0), outdent: false, wholeParagraphs: true, continuation: true))
        XCTAssertNil(TextIndentEditing.tab(source, selection: NSRange(location: 0, length: 0), outdent: false, continuation: true))
        XCTAssertNil(TextIndentEditing.newline(box("\tweiter"), range: NSRange(location: 7, length: 0), continuation: true))
        XCTAssertNil(TextIndentEditing.backspace(box("• weiter"), caret: 2, continuation: true))
        XCTAssertEqual(TextIndentEditing.tab(source, selection: NSRange(location: 0, length: 20), outdent: false, continuation: true)
            .map(source.applying)?.text, "Rest des Absatzes\n\t◦ b", "only the paragraphs starting on this page")
    }
    func testBackspaceBehindAMarkWithALabel() throws {
        let source = box("• Bsp.:\tText")
        guard case .edit(let edit)? = TextIndentEditing.backspace(source, caret: 2) else { return XCTFail() }
        XCTAssertEqual(source.applying([edit]).text, "Bsp.:\tText")
        XCTAssertNil(TextIndentEditing.backspace(source, caret: 8), "behind the label's tab: an ordinary ⌫")
        XCTAssertEqual(edge("• Bsp.:\tText"), 70, "hangs behind the tab, not under „B“")
    }

    // MARK: Plans on whole boxes

    func testATabAtAParagraphStartKeepsThatParagraphsFormat() {
        var source = box("a\nb", indents: [0, 40])
        var bold = TextBoxStyle(); bold.bold = true; bold.indent = 40
        source.runs = [source.runs![0], TextRun(location: 2, length: 1, style: bold)]
        let result = source.applying([TextListEditing.Edit(range: NSRange(location: 2, length: 0), replacement: "\t")])
        XCTAssertEqual(result.text, "a\n\tb")
        XCTAssertEqual(result.style(at: 2).indent, 40, "the inserted tab belongs to its paragraph")
        XCTAssertTrue(result.style(at: 2).bold)
        XCTAssertEqual(result.style(at: 1).indent, 0)
        XCTAssertNoThrow(try result.validate())
    }
}
