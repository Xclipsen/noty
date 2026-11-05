import Foundation
import XCTest
@testable import NotebookCore

/// Regressions of the text tool audit (dev 7f8bfe7): calculator, lists,
/// Markdown, tab grid and the keyboard mode's counts.
final class TextToolAuditTests: XCTestCase {
    private func typed(_ typed: String) -> String? {
        let text = typed as NSString
        guard let calculation = TextCalculator.calculation(in: typed, caret: text.length) else { return nil }
        return text.replacingCharacters(in: calculation.edit.range, with: calculation.edit.replacement)
    }

    // MARK: Calculator

    /// A long row of signs used to recurse once per sign and ended the app.
    func testLongRowOfSignsRunsOnASmallStack() {
        let line = String(repeating: "-", count: 20_000) + "1+1="
        final class Box: @unchecked Sendable { var value: TextCalculator.Calculation?; var done = false }
        let box = Box(), finished = expectation(description: "calculated")
        let thread = Thread {
            box.value = TextCalculator.calculation(in: line, caret: (line as NSString).length)
            box.done = true
            finished.fulfill()
        }
        thread.stackSize = 1 << 19
        thread.start()
        wait(for: [finished], timeout: 30)
        XCTAssertTrue(box.done)
        // An even number of minus signs: +1, plus 1.
        XCTAssertEqual(box.value?.edit.replacement, "=2")
        XCTAssertEqual(TextCalculator.evaluate("--3"), 3)
        XCTAssertEqual(TextCalculator.evaluate("-+-3"), 3)
        XCTAssertEqual(TextCalculator.evaluate("2*-−3"), 6)
        XCTAssertNil(TextCalculator.evaluate(String(repeating: "2^", count: 5_000) + "1"), "a chain of powers nests like parentheses")
    }

    func testOverflowingExponentGivesNoResult() {
        for text in ["9^999^999=", "2^(10^200)=", "2^10^200=", "7*3^(10^170)="] { XCTAssertNil(typed(text), text) }
        XCTAssertEqual(typed("2^10="), "2^10=1024")
    }

    func testValueThatWouldShowAsZeroGivesNoResult() {
        XCTAssertNil(typed("0,00000000004*1="))
        XCTAssertNil(typed("0-0,00000000004="))
        XCTAssertEqual(typed("0,5-0,5="), "0,5-0,5=0")
        XCTAssertEqual(typed("0,00000000005*1="), "0,00000000005*1=0,0000000001")
    }

    func testDashListIsNoMinus() {
        XCTAssertNil(typed("- 5\n- 3\n="), "a list of „- “ items is no calculation, like one of „• “ items")
        XCTAssertNil(typed("• 5\n• 3\n="))
        XCTAssertEqual(typed("- 5+3="), "- 5+3=8", "the item's text is calculated")
        XCTAssertEqual(typed("  - 2*3="), "  - 2*3=6")
        // A minus below a number stays a minus.
        XCTAssertEqual(typed("100\n- 30\n="), "100\n- 30\n= 70")
        XCTAssertEqual(typed("-5+3="), "-5+3=-2")
    }

    func testColumnOfWindowsLines() {
        XCTAssertEqual(typed("500\r\n300\r\n="), "500\r\n300\r\n= 800")
        XCTAssertEqual(typed("Miete 500\r\n- 30\r\n="), "Miete 500\r\n- 30\r\n= 470")
    }

    func testTimeAndLonePercentAreNoCalculation() {
        for text in ["10:30=", "Treffen 10:30=", "Treffen um 9:05 =", "10%=", "Rabatt 10%=", "1.2,5+0=", "1,5.3+0="] {
            XCTAssertNil(typed(text), text)
        }
        XCTAssertNil(typed("9:00\n10:30\n="), "times below each other are no column")
        XCTAssertEqual(typed("90\n: 3\n="), "90\n: 3\n= 30")
        XCTAssertEqual(typed("12 : 4="), "12 : 4 = 3")
        XCTAssertEqual(typed("200+10%="), "200+10%=220")
        XCTAssertEqual(typed("1.234,5+0,5="), "1.234,5+0,5=1235")
        XCTAssertEqual(typed("1,234.5+0.5="), "1,234.5+0.5=1235")
        XCTAssertEqual(typed("12.345.678,5*2="), "12.345.678,5*2=24691357")
    }

    // MARK: Lists

    func testSelectionReachingOneCharacterIntoTheLastLineTakesIt() {
        let text = "Milch\nX", all = NSRange(location: 0, length: 7)
        XCTAssertEqual(TextListEditing.selectedLines(in: text, range: all).count, 2)
        XCTAssertEqual(TextBox(text: text).applying(TextListEditing.toggle(.bullet, in: text, range: all)).text, "• Milch\n• X")
        XCTAssertEqual(TextListEditing.selectedLines(in: "Milch\nXY", range: NSRange(location: 2, length: 5)).count, 2)
        XCTAssertEqual(TextListEditing.selectedLines(in: "Milch\nXY", range: NSRange(location: 0, length: 6)).count, 1,
                       "ending right behind the break does not reach the next line")
        XCTAssertEqual(TextListEditing.selectedLines(in: "ab\u{0C}cd", range: NSRange(location: 0, length: 3)).count, 1)
        XCTAssertEqual(TextListEditing.selectedLines(in: "ab\u{0C}cd", range: NSRange(location: 0, length: 4)).count, 2)
        // Button state, ⌘⇧7/8/9 and Tab use the same lines.
        XCTAssertFalse(TextListEditing.isActive(.bullet, in: "• a\n• b\nc", range: NSRange(location: 0, length: 9)))
        XCTAssertTrue(TextListEditing.isActive(.bullet, in: "• a\n• b\nc", range: NSRange(location: 0, length: 7)))
        XCTAssertEqual(TextIndentEditing.tab(TextBox(text: "• a\n• b"), selection: NSRange(location: 0, length: 5), outdent: false)?
            .edits.filter { $0.replacement == "\t" }.count, 2)
    }

    func testEmptyLinesOfASelectionStayEmpty() {
        let text = "a\n\nb", all = NSRange(location: 0, length: 4)
        XCTAssertEqual(TextBox(text: text).applying(TextListEditing.toggle(.numbered, in: text, range: all)).text, "1. a\n\n2. b")
        XCTAssertEqual(TextBox(text: text).applying(TextListEditing.toggle(.bullet, in: text, range: all)).text, "• a\n\n• b")
        let bulleted = "• a\n\n• b"
        XCTAssertTrue(TextListEditing.isActive(.bullet, in: bulleted, range: NSRange(location: 0, length: 8)))
        XCTAssertEqual(TextBox(text: bulleted).applying(TextListEditing.toggle(.bullet, in: bulleted, range: NSRange(location: 0, length: 8))).text,
                       "a\n\nb", "an empty line no longer keeps the list from being removed")
        // A caret on an empty line still starts a list.
        XCTAssertEqual(TextBox(text: "a\n").applying(TextListEditing.toggle(.bullet, in: "a\n", range: NSRange(location: 2, length: 0))).text, "a\n• ")
    }

    func testTaskTextEndsAtEveryLineBreak() {
        let text = "☐ Aufgabe\u{2028}☐ zweite\u{2029}☐ dritte"
        let items = TextListEditing.taskItems(in: text)
        XCTAssertEqual(items.map { (text as NSString).substring(with: $0.body) }, ["Aufgabe", "zweite", "dritte"])
    }

    // MARK: Markdown and tabs

    func testMarkdownKeepsWhiteSpaceAroundEmphasis() {
        var box = TextBox(text: "a\u{00A0}fett")
        var bold = box.style; bold.bold = true
        box.runs = [TextRun(location: 0, length: 1, style: box.style), TextRun(location: 1, length: 5, style: bold)]
        XCTAssertEqual(TextDocumentExport.markdown(box), "a\u{00A0}**fett**\n")
        var tail = TextBox(text: "fett \tx", style: TextBoxStyle(fontSize: 14))
        var strong = tail.style; strong.bold = true
        tail.runs = [TextRun(location: 0, length: 6, style: strong)]
        XCTAssertEqual(TextDocumentExport.markdown(tail), "**fett** \tx\n")
    }

    func testTabGridSeesTheFieldStyleBetweenRuns() {
        var box = TextBox(text: "kleinGROSS", style: TextBoxStyle(fontSize: 30))
        var small = box.style; small.fontSize = 12
        box.runs = [TextRun(location: 0, length: 5, style: small)]
        XCTAssertEqual(TextTabs.interval(box), TextTabs.interval(fontSize: 30))
        box.runs = [TextRun(location: 0, length: 10, style: small)]
        XCTAssertEqual(TextTabs.interval(box), TextTabs.interval(fontSize: 12))
    }

    // MARK: Keyboard mode

    private func press(_ keys: String, on engine: inout TextEngine, parser: inout HelixParser) {
        for token in keys.split(separator: " ").map(String.init) {
            if engine.mode == .insert {
                _ = token == "<Esc>" ? engine.perform(.escape) : engine.insertText(token)
                continue
            }
            let result = parser.feed(token, context: .text)
            if case .action(.text(let command), let count, _, let register) = result {
                engine.selectedRegister = register
                _ = engine.performAtPrimary(command, count: count)
            }
            engine.record(token, result)
        }
    }
    private func timed(_ body: () -> Void) -> TimeInterval {
        let start = Date(); body(); return Date().timeIntervalSince(start)
    }

    func testRepeatWithAHugeCountStopsAtTheBudget() {
        var engine = TextEngine(text: String(repeating: "Lorem ipsum dolor sit amet.\n", count: 400), caret: 0), parser = HelixParser()
        press("i h e l l o <Esc>", on: &engine, parser: &parser)
        let before = engine.text.length
        var notice: TextEngine.Notice?
        let seconds = timed {
            _ = parser.feed("9", context: .text); _ = parser.feed("9", context: .text); _ = parser.feed("9", context: .text); _ = parser.feed("9", context: .text)
            if case .action(.text(let command), let count, _, _) = parser.feed(".", context: .text) {
                notice = engine.performAtPrimary(command, count: count).notice
            }
        }
        XCTAssertLessThan(seconds, TextEngine.macroSeconds + 0.5)
        XCTAssertEqual(notice, .repeatStopped)
        let rounds = (engine.text.length - before) / 5
        XCTAssertGreaterThan(rounds, 0)
        XCTAssertLessThanOrEqual(rounds, TextEngine.macroLimit)
        // A small count runs completely and says nothing.
        var small = TextEngine(text: "abc", caret: 0), smallParser = HelixParser()
        press("i x <Esc> 3 .", on: &small, parser: &smallParser)
        XCTAssertEqual(small.string, "xxxxabc")
    }

    func testRepeatInsideAMacroCountsOnTheMacroBudget() {
        var engine = TextEngine(text: String(repeating: "abc\n", count: 200), caret: 0), parser = HelixParser()
        press("i x <Esc> Q 9 9 9 9 . Q", on: &engine, parser: &parser)
        var notice: TextEngine.Notice?
        let seconds = timed {
            _ = parser.feed("3", context: .text)
            if case .action(.text(let command), let count, _, _) = parser.feed("q", context: .text) {
                notice = engine.performAtPrimary(command, count: count).notice
            }
        }
        XCTAssertLessThan(seconds, TextEngine.macroSeconds + 0.5, "the time is also checked inside a step")
        XCTAssertEqual(notice, .macroStopped)
    }

    func testCountedSearchStepsThroughOneListOfMatches() {
        var engine = TextEngine(text: String(repeating: "word ", count: 10_000), caret: 0)
        _ = engine.search("word")
        let seconds = timed { _ = engine.perform(.searchNext, count: 9999) }
        XCTAssertLessThan(seconds, 2)
        // The search goes from behind the cursor to the second word, 9999 more go round to the first.
        XCTAssertEqual(engine.selectedRange, NSRange(location: 0, length: 4))
        // Round after round: from the second of ten words, 10003 steps end on the fifth.
        var round = TextEngine(text: String(repeating: "word ", count: 10), caret: 0)
        _ = round.search("word")
        XCTAssertEqual(round.selectedRange, NSRange(location: 5, length: 4))
        let notice = round.perform(.searchNext, count: 10_003).notice
        XCTAssertEqual(round.selectedRange, NSRange(location: 20, length: 4))
        XCTAssertEqual(notice, .wrapped)
    }

    /// A count is the same as so many single steps, also with overlapping
    /// matches, empty ones and select mode.
    func testCountedSearchMatchesSingleSteps() {
        let texts = ["aaaa ab aaa\nba aab", "one two\u{0C}one\n\ntwo one", "xx x xxx\nx", "word, word; Word\n word"]
        let patterns = ["aa", "a+", "o", "^", "\\b", "x*", "(?=w)", "word", "one|two", "a\\w*", "$", "z", "ab|a", "a?b?", "(?<=a)b", "\\s*"]
        for text in texts {
            for pattern in patterns {
                for caret in [0, 3, (text as NSString).length / 2] {
                    for backward in [false, true] {
                        for select in [false, true] {
                            for count in [2, 3, 7] {
                                var counted = TextEngine(text: text, caret: caret), single = counted
                                if select { _ = counted.perform(.toggleSelect); _ = single.perform(.toggleSelect) }
                                counted.searchQuery = pattern; single.searchQuery = pattern
                                let command: TextEngine.Command = backward ? .searchPrevious : .searchNext
                                let notice = counted.perform(command, count: count).notice
                                var notices: [TextEngine.Notice?] = []
                                for _ in 0..<count { notices.append(single.perform(command).notice) }
                                let label = "\(text.debugDescription) \(pattern) caret \(caret) \(backward ? "N" : "n") select \(select) \(count)"
                                XCTAssertEqual(counted.selections, single.selections, label)
                                XCTAssertEqual(counted.primaryIndex, single.primaryIndex, label)
                                if notices.contains(.noMatch) { XCTAssertEqual(notice, .noMatch, label) }
                                else if notices.contains(.wrapped) { XCTAssertEqual(notice, .wrapped, label) }
                            }
                        }
                    }
                }
            }
        }
    }

    func testClosestPairWithManyClosersWithoutPartner() {
        let text = String(repeating: "1) a\n", count: 4000) + "(b)"
        var engine = TextEngine(text: text, caret: 0)
        let seconds = timed { _ = engine.perform(.selectObject(.closestPair, around: false)) }
        XCTAssertLessThan(seconds, 1)
        XCTAssertEqual(engine.selectedRange, NSRange(location: 0, length: 1), "no pair around the start")
        var inside = TextEngine(text: text, caret: (text as NSString).length - 2)
        _ = inside.perform(.selectObject(.closestPair, around: false))
        XCTAssertEqual(inside.selectedRange, NSRange(location: (text as NSString).length - 2, length: 1))
        // The nearest closing bracket behind the cursor and its partner, also one in front of the selection.
        var nested = TextEngine(text: "x) (a [b) c] d)", caret: 7)
        _ = nested.perform(.selectObject(.closestPair, around: true))
        XCTAssertEqual(nested.selectedRange, NSRange(location: 3, length: 6), "(a [b)")
    }

    func testCountedOpenLineAtOneCaretOpensOneLine() {
        var engine = TextEngine(text: "abc", caret: 0)
        let outcome = engine.performAtPrimary(.insert(.lineBelow), count: 3)
        XCTAssertEqual(engine.string, "abc\n")
        XCTAssertEqual(engine.selections.count, 1)
        XCTAssertEqual(outcome.notice, .primaryOnly)
        engine.sync(text: "abc\nfoo", selection: NSRange(location: 7, length: 0))
        _ = engine.perform(.escape)
        XCTAssertEqual(engine.string, "abc\nfoo")
        var above = TextEngine(text: "abc", caret: 0)
        _ = above.performAtPrimary(.insert(.lineAbove), count: 3)
        XCTAssertEqual(above.string, "\nabc")
        // Text editor 2 types at every caret: there the count stays.
        var all = TextEngine(text: "abc", caret: 0)
        _ = all.perform(.insert(.lineBelow), count: 3)
        XCTAssertEqual(all.string, "abc\n\n\n")
        XCTAssertEqual(all.selections.count, 3)
    }

    func testPastingACopiedEmptyLineBelowTheLastLine() {
        var engine = TextEngine(text: "abc\n\nd", caret: 4), parser = HelixParser()
        press("y", on: &engine, parser: &parser)
        XCTAssertEqual(engine.register?.values, ["\n"])
        press("g e p", on: &engine, parser: &parser)
        XCTAssertEqual(engine.string, "abc\n\nd\n")
        var twice = TextEngine(text: "abc\n\nd", caret: 4), twiceParser = HelixParser()
        press("y g e 2 p", on: &twice, parser: &twiceParser)
        XCTAssertEqual(twice.string, "abc\n\nd\n\n")
        var line = TextEngine(text: "abc\nx\nd", caret: 4), lineParser = HelixParser()
        press("x y g e p", on: &line, parser: &lineParser)
        XCTAssertEqual(line.string, "abc\nx\nd\nx")
        var empty = TextEngine(text: "", caret: 0)
        empty.register = TextEngine.Register("\n")
        _ = empty.perform(.paste(before: false))
        XCTAssertEqual(empty.string, "\n")
    }

    func testFindLineBreakOfWindowsText() {
        var engine = TextEngine(text: "ab\r\ncd\r\nef", caret: 0)
        _ = engine.perform(.find("\n", forward: true, inclusive: true))
        XCTAssertEqual(engine.selections.map(\.head), [4])
        _ = engine.perform(.find("\n", forward: true, inclusive: false), count: 1)
        XCTAssertEqual(engine.cursor, 5)
        var back = TextEngine(text: "ab\r\ncd", caret: 5)
        _ = back.perform(.find("\n", forward: false, inclusive: true))
        XCTAssertEqual(back.cursor, 2)
    }

    func testStarOverAPageBreakFindsItself() {
        var engine = TextEngine(text: "foo\u{0C}bar x foo\u{0C}bar", caret: 0)
        engine.selections = [TextEngine.Selection(anchor: 0, head: 7)]
        _ = engine.perform(.searchSelection)
        let notice = engine.perform(.searchNext).notice
        XCTAssertNil(notice)
        XCTAssertEqual(engine.selectedRange, NSRange(location: 10, length: 7))
    }
}
