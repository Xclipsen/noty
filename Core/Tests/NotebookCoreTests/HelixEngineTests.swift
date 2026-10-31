import XCTest
import Foundation
@testable import NotebookCore

final class HelixEngineTests: XCTestCase {
    /// Runs tokens the way the app will: parser in NOR/SEL, typing in INS.
    @discardableResult
    private func press(_ keys: String, on engine: inout TextEngine, parser: inout HelixParser) -> [TextEngine.Outcome] {
        var results: [TextEngine.Outcome] = []
        let tokens = keys.split(separator: " ").map(String.init)
        var index = 0
        func prompt() -> String {
            var query = ""
            index += 1
            while index < tokens.count, tokens[index] != "<CR>" { query += tokens[index] == "<Space>" ? " " : tokens[index]; index += 1 }
            return query
        }
        while index < tokens.count {
            let token = tokens[index]
            if engine.mode == .insert {
                switch token {
                case "<Esc>": results.append(engine.perform(.escape))
                case "<BS>": results.append(engine.deleteBackward())
                case "<CR>": results.append(engine.insertText("\n"))
                case "<Space>": results.append(engine.insertText(" "))
                default: results.append(engine.insertText(token))
                }
            } else {
                let result = parser.feed(token, context: .text)
                switch result {
                case .action(.text(let command), let count, _, let register):
                    engine.selectedRegister = register
                    results.append(engine.perform(command, count: count))
                    engine.record(token, result)
                case .action(let action, _, _, _) where [.selectPrompt, .splitPrompt, .searchPrompt(backward: false), .searchPrompt(backward: true)].contains(action):
                    // As `KeyboardRouter`: the state before the input line is where the jump goes.
                    let start = engine, query = prompt()
                    switch action {
                    case .selectPrompt: results.append(engine.selectMatches(query))
                    case .splitPrompt: results.append(engine.splitMatches(query))
                    case .searchPrompt(let backward): results.append(engine.search(query, backward: backward))
                    default: break
                    }
                    engine.rememberJump(from: start)
                    engine.recordPrompt(action, query: query)
                default: engine.record(token, result)
                }
            }
            index += 1
        }
        return results
    }
    private func run(_ text: String, _ keys: String, caret: Int = 0, pairs: Bool = false) -> TextEngine {
        var engine = TextEngine(text: text, caret: caret), parser = HelixParser()
        engine.autoPairs = pairs
        press(keys, on: &engine, parser: &parser)
        return engine
    }
    private func marked(_ text: NSString, _ ranges: [NSRange]) -> String {
        let result = NSMutableString(string: text as String)
        for range in ranges.reversed() { result.insert("|", at: NSMaxRange(range)); result.insert("|", at: range.location) }
        return result as String
    }
    private func marks(_ engine: TextEngine) -> String { marked(engine.text, engine.selections.map(\.range)) }
    private func cursors(_ engine: TextEngine) -> String {
        marked(engine.text, engine.selections.map { range in
            let cursor = range.head > range.anchor ? engine.text.previousBoundary(range.head) : range.head
            return NSRange(location: cursor, length: engine.text.nextBoundary(cursor) - cursor)
        })
    }

    // MARK: Against the real editor

    func testGoldenCasesOfTheRealEditor() {
        for row in HelixGoldenCases.rows {
            var engine = run(row.text, row.keys)
            if engine.mode != .normal { engine.perform(.escape) }
            XCTAssertEqual(marks(engine), row.selections, "\(row.keys.debugDescription) on \(row.text.debugDescription)")
            XCTAssertEqual(cursors(engine), row.cursors, "cursor: \(row.keys.debugDescription) on \(row.text.debugDescription)")
        }
    }

    func testGoldenCasesWithAutomaticPairs() {
        for row in HelixGoldenCases.pairRows {
            var engine = run(row.text, row.keys, pairs: true)
            if engine.mode != .normal { engine.perform(.escape) }
            XCTAssertEqual(marks(engine), row.selections, "\(row.keys.debugDescription) on \(row.text.debugDescription)")
            XCTAssertEqual(cursors(engine), row.cursors, "cursor: \(row.keys.debugDescription) on \(row.text.debugDescription)")
        }
    }

    // MARK: Typical flows

    func testTypicalFlows() {
        XCTAssertEqual(run("hello world", "w d").string, "world")
        XCTAssertEqual(run("hello world\nnext\n", "x d").string, "next\n")
        XCTAssertEqual(run("a\nb\nc\n", "x x d").string, "c\n")
        var engine = run("Text", "% y")
        XCTAssertEqual(engine.register?.values, ["Text"])
        engine.perform(.paste(before: false))
        XCTAssertEqual(engine.string, "TextText")
        XCTAssertEqual(run("wort", "m s \"").string, "\"w\"ort")
        XCTAssertEqual(run("wort", "m i w m s \"").string, "\"wort\"")
        XCTAssertEqual(run("1\n2\n3\n4\n5\n6", "5 G").cursor, 8)
    }

    func testMatchInnerWordThenChangeIsWhatVimCallsCiw() {
        var engine = run("ein wort hier", "f o m i w c")
        XCTAssertEqual(engine.mode, .insert)
        XCTAssertEqual(engine.string, "ein  hier")
        engine.insertText("satz")
        XCTAssertEqual(engine.string, "ein satz hier")
    }

    func testCopyToNextLineThenTypingWritesInBoth() {
        var engine = run("eins\nzwei\ndrei", "C i")
        XCTAssertEqual(engine.selections.count, 2)
        engine.insertText("X")
        XCTAssertEqual(engine.string, "Xeins\nXzwei\ndrei")
        engine.insertText("Y")
        engine.deleteBackward()
        engine.perform(.escape)
        XCTAssertEqual(engine.string, "Xeins\nXzwei\ndrei")
        XCTAssertEqual(engine.mode, .normal)
        XCTAssertEqual(cursors(engine), "X|e|ins\nX|z|wei\ndrei")
        // The new line is the primary selection, `,` keeps it.
        engine.perform(.keepPrimary)
        XCTAssertEqual(cursors(engine), "Xeins\nX|z|wei\ndrei")
    }

    // MARK: Esc

    func testEscapeGoesBackOneLevel() {
        var engine = TextEngine(text: "eins zwei\ndrei")
        engine.perform(.insert(.before))
        XCTAssertEqual(engine.perform(.escape).leavesText, false)
        XCTAssertEqual(engine.mode, .normal)
        engine.perform(.toggleSelect)
        engine.perform(.word(.nextStart, long: false))
        XCTAssertEqual(engine.perform(.escape).leavesText, false)
        XCTAssertEqual(engine.mode, .normal)
        XCTAssertTrue(engine.hasWideSelection)
        XCTAssertEqual(engine.perform(.escape).leavesText, false)
        XCTAssertFalse(engine.hasWideSelection)
        XCTAssertTrue(engine.perform(.escape).leavesText)
    }

    func testEscapeDropsSecondarySelectionsBeforeLeaving() {
        var engine = run("ab\ncd", "C")
        XCTAssertEqual(engine.selections.count, 2)
        XCTAssertFalse(engine.perform(.escape).leavesText)
        XCTAssertEqual(engine.selections.count, 1)
        XCTAssertTrue(engine.perform(.escape).leavesText)
    }

    // MARK: Several selections

    func testEditsComeBackToFrontAndReproduceTheText() {
        let flows = ["C i X", "% s e <CR> d", "% s e <CR> c X", "m s (", "C m s (", "x x J", "% >", "C ~", "% s e <CR> r ü", "C r x", "x x y C p", "m i w m d (", "o Q", "C o"]
        for flow in flows {
            let text = "(eins) eine\nzwei\n\ndrei eis"
            var engine = TextEngine(text: text), parser = HelixParser()
            var current = text
            for outcome in press(flow, on: &engine, parser: &parser) {
                let applied = NSMutableString(string: current)
                var limit = Int.max
                for edit in outcome.edits {
                    XCTAssertLessThanOrEqual(NSMaxRange(edit.range), limit, "edits overlap or run forward in \(flow)")
                    limit = edit.range.location
                    applied.replaceCharacters(in: edit.range, with: edit.replacement)
                }
                if let whole = outcome.combinedEdit {
                    let combined = NSMutableString(string: current)
                    combined.replaceCharacters(in: whole.range, with: whole.replacement)
                    XCTAssertEqual(combined as String, applied as String, flow)
                }
                current = applied as String
            }
            XCTAssertEqual(current, engine.string, flow)
        }
    }

    func testOverlappingSelectionsMerge() {
        // Both cursors reach the same line.
        var engine = run("aa\naa", "C k")
        XCTAssertEqual(engine.selections.count, 1)
        XCTAssertEqual(engine.primaryIndex, 0)
        // Line selections of two neighbours grow into each other.
        engine = run("a\nb\nc\nd", "C x x")
        XCTAssertEqual(engine.selections.count, 1)
        XCTAssertEqual(engine.selectedRange, NSRange(location: 0, length: 6))
    }

    func testOffsetsOfLaterSelectionsFollowEarlierEdits() {
        var engine = run("ab cd\nef gh", "C m s (")
        XCTAssertEqual(marks(engine), "|(a)|b cd\n|(e)|f gh")
        engine.perform(.yank)
        XCTAssertEqual(engine.register?.values, ["(a)", "(e)"])
        engine.perform(.collapse)
        engine.perform(.paste(before: false))
        XCTAssertEqual(engine.string, "(a)(a)b cd\n(e)(e)f gh")
    }

    func testRegisterKeepsOneValuePerSelection() {
        var engine = run("ab\ncd\nef", "C y , ")
        XCTAssertEqual(engine.register?.values, ["a", "c"])
        XCTAssertFalse(engine.register?.isLinewise ?? true)
        XCTAssertEqual(engine.register?.joined, "a\nc")
        // More selections than values: the last value goes on.
        engine = TextEngine(text: "a\nb\nc")
        engine.register = .init(values: ["1", "2"])
        engine.perform(.copyToNextLine, count: 2)
        engine.perform(.replaceWithRegister)
        XCTAssertEqual(engine.string, "1\n2\n2")
    }

    func testRegisterFromThePasteboardWorksAsOneValue() {
        var engine = TextEngine(text: "a\nb")
        engine.register = .init("neu\n")
        XCTAssertEqual(engine.register?.isLinewise, true)
        engine.perform(.paste(before: true))
        XCTAssertEqual(engine.string, "neu\na\nb")
    }

    func testYankReportsOnlyARealChange() {
        var engine = TextEngine(text: "a\n", caret: 2)
        XCTAssertTrue(engine.selections[0].isEmpty)
        XCTAssertFalse(engine.perform(.yank).yanked)
        XCTAssertNil(engine.register)
        engine = TextEngine(text: "a\n")
        XCTAssertTrue(engine.perform(.delete).yanked)
    }

    // MARK: Deliberate differences (docs/KEYBOARD.md)

    func testLastLineWithoutBreakCountsAsALine() {
        var engine = run("a\nb", "j x d")
        XCTAssertEqual(engine.string, "a")
        XCTAssertEqual(engine.register?.values, ["b\n"])
        XCTAssertEqual(engine.register?.isLinewise, true)
        XCTAssertEqual(engine.cursor, 0)
        XCTAssertEqual(run("a\nb", "j x y p").string, "a\nb\nb")
        XCTAssertEqual(marks(run("a\nb", "j x y p")), "a\nb\n|b|")
        XCTAssertEqual(run("a\nb", "j x y P").string, "a\nb\nb")
        XCTAssertEqual(run("abc", "x y p").string, "abc\nabc")
        XCTAssertEqual(run("a\nb", "j X d").string, "a")
        // A pasted line needs no break behind the last one, in an empty text either.
        XCTAssertEqual(run("a\nb", "x d p").string, "b\na")
        XCTAssertEqual(run("abc\n", "x d p").string, "abc")
    }

    func testOnlyLineSelectionsTakeTheBreakBefore() {
        XCTAssertEqual(run("a\nbc", "j m i w d").string, "a\n")
        XCTAssertEqual(run("a\nbc", "j x ; d").string, "a\nb")
        // `y` leaves the selection a line selection.
        XCTAssertEqual(run("a\nbc", "j x y d").string, "a")
    }

    func testChangingAllLinesLeavesNoStrayBreak() {
        var engine = run("a\nb", "x x c")
        XCTAssertEqual(engine.string, "")
        engine = run("a\nb\n", "x x c")
        XCTAssertEqual(engine.string, "\n")
        XCTAssertEqual(engine.mode, .insert)
        XCTAssertEqual(engine.cursor, 0)
    }

    func testAppendAtTheEndAddsNoBreak() {
        var engine = run("ab", "g l a")
        engine.insertText("X")
        XCTAssertEqual(engine.string, "abX")
        engine.perform(.escape)
        XCTAssertEqual(engine.string, "abX")
        XCTAssertEqual(marks(engine), "a|bX|")
    }

    func testPairsAtTheEndOfATextWithoutBreak() {
        XCTAssertEqual(run("(ab)", "f b m i (").selectedRange, NSRange(location: 1, length: 2))
        XCTAssertEqual(run("(ab)", "f ) m d (").string, "ab")
        XCTAssertEqual(run("\"ab\"", "l m a \"").selectedRange, NSRange(location: 0, length: 4))
    }

    func testNewLinesKeepTheIndentUntilEscFindsThemUnused() {
        var engine = run("  eins", "o")
        XCTAssertEqual(engine.string, "  eins\n  ")
        XCTAssertEqual(engine.cursor, 9)
        XCTAssertEqual(engine.perform(.escape).edits.count, 1, "an edit the app applies, too")
        XCTAssertEqual(engine.string, "  eins\n")
    }

    func testColumnsCountGraphemesNotCells() {
        // Helix counts a tab as four cells and an emoji as two.
        XCTAssertEqual(run("😀ab\ncde", "l j").cursor, 6)
        XCTAssertEqual(run("\tab\ncde", "l j").cursor, 5)
    }

    func testBrokenPatternsAreSearchedLiterally() {
        XCTAssertEqual(run("x (a b", "/ ( a <CR>").selectedRange, NSRange(location: 2, length: 2))
    }

    // MARK: Characters

    func testGraphemesStayWhole() {
        let family = "👨‍👩‍👧", flag = "🇩🇪", combined = "e\u{301}"
        let text = "a\(family)b\(flag)c\(combined)"
        var engine = TextEngine(text: text)
        engine.perform(.move(.right))
        XCTAssertEqual(engine.selectedRange, NSRange(location: 1, length: (family as NSString).length))
        engine.perform(.delete)
        XCTAssertEqual(engine.string, "ab\(flag)c\(combined)")
        engine.perform(.move(.right), count: 1)
        XCTAssertEqual(engine.selectedRange.length, (flag as NSString).length)
        engine.perform(.replace("x"))
        XCTAssertEqual(engine.string, "abxc\(combined)")
        engine.perform(.move(.right), count: 2)
        XCTAssertEqual(engine.selectedRange.length, 2)
        engine.perform(.replace("😀"))
        XCTAssertEqual(engine.string, "abxc😀")
        XCTAssertEqual(engine.selectedRange.length, 2)
    }

    func testOffsetsInsideAGraphemeSnapToItsBoundaries() {
        var engine = TextEngine(text: "a😀b", caret: 2)
        XCTAssertEqual(engine.cursor, 1)
        engine.sync(text: "a😀b", selection: NSRange(location: 2, length: 1))
        XCTAssertEqual(engine.selectedRange, NSRange(location: 1, length: 2))
    }

    func testFindsEmojiAndUmlautsByGrapheme() {
        XCTAssertEqual(run("ab 😀 c", "f 😀").selectedRange, NSRange(location: 0, length: 5))
        XCTAssertEqual(run("Grüße", "f ß").string, "Grüße")
        XCTAssertEqual(run("Grüße", "f ß d").string, "e")
    }

    func testUmlautsAreWordCharacters() {
        XCTAssertEqual(run("Äpfel über", "e").selectedRange, NSRange(location: 0, length: 5))
        XCTAssertEqual(run("Äpfel über", "f b m i w d").string, "Äpfel ")
    }

    func testCaseChangesMayChangeTheLength() {
        var engine = run("Maß x", "% ~")
        XCTAssertEqual(engine.string, "mASS X")
        XCTAssertEqual(engine.selectedRange, NSRange(location: 0, length: 6))
        engine = run("ÄÖ", "% `")
        XCTAssertEqual(engine.string, "äö")
    }

    func testEveryCommandSurvivesSmallTexts() {
        var commands = HelixKeymap.bindings.compactMap { binding -> TextEngine.Command? in
            if case .text(let command)? = binding.action { return command }
            return nil
        }
        for prompt in HelixPrompt.allCases {
            for character in ["w", "p", "m", "(", ")", "\"", "😀", "ß", "\n"] {
                if case .text(let command)? = prompt.action(character) { commands.append(command) }
            }
        }
        commands += [.surroundReplace(nil, with: "["), .surroundReplace("(", with: "😀"), .surroundDelete(nil)]
        let texts = ["", "\n", "\n\n", "a", "😀", "a\nb", "(a)", "\"", "a\n", " ", "\t\n ", "👨‍👩‍👧\n👨‍👩‍👧"]
        for text in texts {
            for first in commands {
                for second in stride(from: 0, to: commands.count, by: 4).map({ commands[$0] }) {
                    for caret in [0, (text as NSString).length] {
                        for count in [nil, 3] as [Int?] {
                            var engine = TextEngine(text: text, caret: caret)
                            engine.register = .init(values: ["x", "y\n"])
                            if count == 3 { engine.perform(.copyToNextLine); engine.perform(.toggleSelect) }
                            engine.perform(first, count: count)
                            if engine.mode == .insert { engine.insertText("ä"); engine.deleteBackward(); engine.perform(.escape) }
                            engine.perform(second)
                            if engine.mode == .insert { engine.insertText("\n"); engine.perform(.escape) }
                            for range in engine.selections {
                                XCTAssertTrue(range.from >= 0 && range.to <= engine.text.length)
                                XCTAssertTrue(range.head == engine.text.alignedDown(range.head) || range.head == engine.text.length)
                            }
                            XCTAssertTrue(engine.selections.indices.contains(engine.primaryIndex))
                            XCTAssertEqual(zip(engine.selections, engine.selections.dropFirst()).filter { $0.to > $1.from }.count, 0)
                        }
                    }
                }
            }
        }
    }

    // MARK: Layout

    /// Lines of 4 units, as a view with soft wrap.
    private struct Wrapped: TextEngineLayout {
        var visibleLines = 6
        func verticalTarget(from offset: Int, lines: Int, goal: Double?, in text: NSString) -> (offset: Int, goal: Double) {
            let column = goal.map { Int($0) } ?? offset % 4
            let row = max(0, offset / 4 + lines)
            return (min(text.length, row * 4 + column), Double(column))
        }
    }

    func testVerticalMotionsAskTheInjectedLayout() {
        var engine = TextEngine(text: "abcdefghijklmnop")
        engine.layout = Wrapped()
        engine.perform(.move(.right))
        engine.perform(.move(.down))
        XCTAssertEqual(engine.cursor, 5)
        engine.perform(.move(.down), count: 2)
        XCTAssertEqual(engine.cursor, 13)
        engine.perform(.screen(-0.5))
        XCTAssertEqual(engine.cursor, 1)
        XCTAssertEqual(run("a\nb\nc", "j j").cursor, 4)
    }

    func testVerticalMotionsKeepTheColumnOverShortLines() {
        XCTAssertEqual(run("abcd\n\nabcd", "l l j j").cursor, 8)
        // Any other motion forgets it.
        XCTAssertEqual(run("abcd\n\nabcd", "l l j h j j").cursor, 10)
    }

    func testScreenMotionsExtendInSelectMode() {
        var engine = TextEngine(text: "a\nb\nc\nd\ne\n")
        engine.layout = LogicalLineLayout(visibleLines: 4)
        engine.perform(.toggleSelect)
        engine.perform(.screen(0.5))
        XCTAssertEqual(engine.selectedRange, NSRange(location: 0, length: 5))
    }

    // MARK: The app's text

    func testSyncKeepsSelectionsWhileNothingChanged() {
        var engine = run("ab\ncd", "C")
        engine.sync(text: "ab\ncd", selection: engine.selectedRange)
        XCTAssertEqual(engine.selections.count, 2)
        // A caret on the primary cursor is how the app may show it.
        engine.sync(text: "ab\ncd", selection: NSRange(location: engine.cursor, length: 0))
        XCTAssertEqual(engine.selections.count, 2)
        engine.sync(text: "ab\ncd", selection: NSRange(location: 1, length: 0))
        XCTAssertEqual(engine.selections.count, 1)
        XCTAssertEqual(engine.selectedRange, NSRange(location: 1, length: 1))
    }

    func testSyncTakesUndoneOrShorterText() {
        var engine = run("ab cd", "w")
        engine.sync(text: "x", selection: NSRange(location: 40, length: 5))
        XCTAssertEqual(engine.string, "x")
        XCTAssertEqual(engine.selectedRange, NSRange(location: 1, length: 0))
    }

    func testNativeTypingComesInThroughSync() {
        // `i`: the cursor stays on the character behind the typed text.
        var engine = run("abc", "l i")
        engine.sync(text: "aXYbc", selection: NSRange(location: 3, length: 0))
        engine.perform(.escape)
        XCTAssertEqual(cursors(engine), "aXY|b|c")
        // `a`: the selection takes the typed text.
        engine = run("abc", "l a")
        engine.sync(text: "abXYc", selection: NSRange(location: 4, length: 0))
        engine.perform(.escape)
        XCTAssertEqual(marks(engine), "a|bXY|c")
        XCTAssertEqual(cursors(engine), "abX|Y|c")
        // A tap opens insert mode somewhere else.
        engine.sync(text: "abXYc", selection: NSRange(location: 2, length: 0), mode: .insert)
        XCTAssertEqual(engine.mode, .insert)
        XCTAssertEqual(engine.cursor, 2)
        // A tap wins over a selection that ends in the same place.
        engine = run("ab cd", "w")
        engine.sync(text: "ab cd", selection: NSRange(location: engine.cursor, length: 0), mode: .insert)
        XCTAssertTrue(engine.selections[0].isEmpty)
        XCTAssertEqual(engine.cursor, 2)
    }

    // MARK: Search

    func testSearchNotices() {
        var engine = TextEngine(text: "foo bar")
        XCTAssertEqual(engine.search("zzz").notice, .noMatch)
        XCTAssertEqual(engine.selectedRange, NSRange(location: 0, length: 1))
        XCTAssertEqual(engine.searchQuery, "zzz")
        engine = TextEngine(text: "foo bar")
        XCTAssertNil(engine.search("bar").notice)
        XCTAssertEqual(engine.perform(.searchNext).notice, .wrapped)
        XCTAssertEqual(engine.selectedRange, NSRange(location: 4, length: 3))
    }

    func testSelectMatchesWithoutHitKeepsTheSelectionAndSetsTheSearch() {
        var engine = run("foo bar", "x")
        XCTAssertEqual(engine.selectMatches("z").notice, .noMatch)
        XCTAssertEqual(engine.selectedRange, NSRange(location: 0, length: 7))
        XCTAssertEqual(engine.searchQuery, "z")
    }

    // MARK: Odds and ends

    func testIndentUnit() {
        var engine = TextEngine(text: "a\n\nb")
        engine.indentUnit = "    "
        engine.perform(.selectAll)
        engine.perform(.indent)
        XCTAssertEqual(engine.string, "    a\n\n    b")
        engine.perform(.unindent)
        XCTAssertEqual(engine.string, "a\n\nb")
    }

    func testInsertModeIgnoresCommands() {
        var engine = TextEngine(text: "abc", mode: .insert)
        XCTAssertTrue(engine.selections[0].isEmpty)
        XCTAssertEqual(engine.perform(.delete).edits, [])
        XCTAssertEqual(engine.string, "abc")
    }

    func testBackspaceOverGraphemesAndAtTheStart() {
        var engine = TextEngine(text: "a😀", caret: 3, mode: .insert)
        engine.deleteBackward()
        XCTAssertEqual(engine.string, "a")
        engine.deleteBackward()
        XCTAssertEqual(engine.deleteBackward().edits, [])
        XCTAssertEqual(engine.string, "")
    }

    func testCarriageReturnLineFeedIsOneBreak() {
        XCTAssertEqual(run("a\r\nb", "x").selectedRange, NSRange(location: 0, length: 3))
        XCTAssertEqual(run("a\r\nb", "j").cursor, 3)
        XCTAssertEqual(run("a\r\nb", "x d").string, "b")
    }

    // MARK: One caret (a page's text view)

    /// `%`, `s` foo: three selections, the primary on the first match.
    private func threeMatches() -> TextEngine {
        var engine = TextEngine(text: "foo x foo y foo")
        engine.perform(.selectAll)
        engine.selectMatches("foo")
        XCTAssertEqual(engine.selections.count, 3)
        return engine
    }

    func testChangeAtPrimaryLeavesTheHiddenSelections() {
        var engine = threeMatches()
        let outcome = engine.performAtPrimary(.change)
        XCTAssertEqual(engine.string, " x foo y foo")
        XCTAssertEqual(engine.mode, .insert)
        XCTAssertEqual(engine.selections.count, 1)
        XCTAssertEqual(engine.register?.values, ["foo"], "only what was deleted")
        XCTAssertEqual(outcome.notice, .primaryOnly)
    }

    func testOpeningALineAtPrimaryLeavesTheHiddenSelections() {
        for (command, expected) in [(TextEngine.Command.insert(.lineBelow), "foo x foo y foo\n"), (.insert(.lineAbove), "\nfoo x foo y foo")] {
            var engine = threeMatches()
            XCTAssertEqual(engine.performAtPrimary(command).notice, .primaryOnly)
            XCTAssertEqual(engine.string, expected)
            XCTAssertEqual(engine.selections.count, 1)
        }
        var engine = threeMatches()
        XCTAssertEqual(engine.performAtPrimary(.insert(.before)).notice, .primaryOnly)
        XCTAssertEqual(engine.selections.count, 1)
    }

    func testEverythingElseStillWorksOnAllSelections() {
        var engine = threeMatches()
        XCTAssertNil(engine.performAtPrimary(.delete).notice)
        XCTAssertEqual(engine.string, " x  y ")
    }

    func testOneSelectionHasNothingToGiveUp() {
        var engine = TextEngine(text: "foo")
        engine.perform(.selectAll)
        XCTAssertNil(engine.performAtPrimary(.change).notice)
        XCTAssertEqual(engine.string, "")
    }

    func testPlainPerformKeepsTypingAtAllCarets() {
        // Text editor 2 shows and types at all of them.
        var engine = threeMatches()
        engine.perform(.change)
        XCTAssertEqual(engine.selections.count, 3)
        engine.insertText("b")
        XCTAssertEqual(engine.string, "b x b y b")
    }

    // MARK: Formats under `~`, `` ` ``, `r`

    private func formatted() -> TextBox {
        var box = TextBox(x: 0, y: 0, width: 100, height: 100, text: "ab cd ef")
        var bold = box.style; bold.bold = true
        box.runs = [TextRun(location: 3, length: 2, style: bold)]
        return box
    }
    private func boldRanges(_ box: TextBox) -> [NSRange] {
        box.styleRuns.filter(\.style.bold).map { NSRange(location: $0.location, length: $0.length) }
    }

    func testCaseAndReplaceKeepFormatsInsideASelection() {
        for (command, expected) in [(TextEngine.Command.switchCase, "AB CD EF"), (.replace("x"), "xxxxxxxx")] {
            let box = formatted()
            var engine = TextEngine(text: box.text)
            engine.perform(.selectAll)
            let edits = engine.perform(command).textEdits(in: box)
            XCTAssertEqual(edits.count, 3, "cut at the runs, not per grapheme")
            let result = box.applying(edits)
            XCTAssertEqual(result.text, expected)
            XCTAssertEqual(boldRanges(result), [NSRange(location: 3, length: 2)])
        }
    }

    func testLowercaseKeepsFormatsAndSeveralSelectionsStayApart() {
        var box = formatted(); box.text = "AB CD EF"
        var engine = TextEngine(text: box.text)
        engine.perform(.selectAll)
        engine.selectMatches("[A-Z]+")
        let edits = engine.perform(.lowercase).textEdits(in: box)
        XCTAssertEqual(edits.map(\.range.location), [0, 3, 6])
        XCTAssertEqual(boldRanges(box.applying(edits)), [NSRange(location: 3, length: 2)])
    }

    func testOtherEditsAndOtherLengthsStayWhole() {
        var box = formatted(); box.text = "ßb cd ef"
        var engine = TextEngine(text: box.text)
        engine.perform(.selectAll)
        XCTAssertEqual(engine.perform(.switchCase).textEdits(in: box).count, 1, "`ß` to `SS` has no same places")
        // `R` writes a new text, also of the same length.
        box.text = "ab cd ef"
        var replacing = TextEngine(text: box.text)
        replacing.register = TextEngine.Register("12345678")
        replacing.perform(.selectAll)
        XCTAssertEqual(replacing.perform(.replaceWithRegister).textEdits(in: box).count, 1)
    }

    func testNoCutInsideAComposedCharacter() {
        let edit = TextListEditing.Edit(range: NSRange(location: 0, length: 4), replacement: "😀😀")
        XCTAssertEqual(TextListEditing.split([edit], at: [1, 2, 3]).map(\.replacement), ["😀", "😀"])
    }

    // MARK: Registers

    func testNamedRegistersStayApartFromTheDefaultOne() {
        var engine = TextEngine(text: "eins zwei"), parser = HelixParser()
        let yanked = press("w \" a y", on: &engine, parser: &parser)
        XCTAssertEqual(engine.register, nil)
        XCTAssertEqual(engine.registers["a"]?.values, ["eins "])
        XCTAssertFalse(yanked.last?.yanked ?? true, "the system pasteboard only follows the default register")
        XCTAssertTrue(press("y", on: &engine, parser: &parser).last?.yanked ?? false)
        XCTAssertEqual(engine.register?.values, ["eins "])
    }
    func testTheBlackHoleKeepsEverything() {
        var engine = run("eins zwei", "w y w \" _ d")
        XCTAssertEqual(engine.register?.values, ["eins "])
        XCTAssertEqual(engine.registers.count, 0)
        XCTAssertEqual(engine.string, "eins ")
        engine.selectedRegister = "_"
        XCTAssertNil(engine.perform(.paste(before: false)).notice)
        XCTAssertEqual(engine.string, "eins ")
    }
    func testClipboardRegistersMeanTheDefaultOne() {
        for name in ["+", "*", "\\\""] {
            var engine = TextEngine(text: "ab")
            engine.selectedRegister = String(name.suffix(1))
            XCTAssertTrue(engine.perform(.yank).yanked, name)
            XCTAssertEqual(engine.register?.values, ["a"], name)
        }
    }
    func testAnEmptyNamedRegisterSaysSo() {
        var engine = TextEngine(text: "ab")
        engine.selectedRegister = "z"
        XCTAssertEqual(engine.perform(.paste(before: false)).notice, .registerEmpty)
        XCTAssertEqual(engine.string, "ab")
        engine.selectedRegister = "z"
        XCTAssertEqual(engine.perform(.replaceWithRegister).notice, .registerEmpty)
        XCTAssertNil(engine.selectedRegister, "every command uses the name up")
    }

    // MARK: `.` after native typing

    /// What the app does: `sync` brings the typed text, the engine sees no keys.
    private func native(_ engine: inout TextEngine, _ text: String, caret: Int) {
        engine.sync(text: text, selection: NSRange(location: caret, length: 0))
    }
    func testDotRepeatsWhatWasTypedNatively() {
        var engine = run("ab cd\n", "w i")
        XCTAssertEqual(engine.cursor, 0)
        native(&engine, "xyab cd\n", caret: 2)
        engine.perform(.escape)
        var parser = HelixParser()
        press("g l .", on: &engine, parser: &parser)
        XCTAssertEqual(engine.string, "xyab cxyd\n")
    }
    func testDotCoversAutocorrectionAndDeletion() {
        var engine = TextEngine(text: "ab\ncd\n", caret: 1), parser = HelixParser()
        press("a", on: &engine, parser: &parser)
        // Autocorrection replaced what stood before the caret: a deletion and new text.
        native(&engine, "aXYZ\ncd\n", caret: 4)
        engine.perform(.escape)
        press("j g l .", on: &engine, parser: &parser)
        XCTAssertEqual(engine.string, "aXYZ\ncXYZ\n", "the replaced letter goes, the new text comes")
    }
    func testDotCarriesTheRestOfAPair() {
        var engine = TextEngine(text: "\nab\n"), parser = HelixParser()
        press("i", on: &engine, parser: &parser)
        native(&engine, "(x)\nab\n", caret: 2)
        engine.perform(.escape)
        press("j .", on: &engine, parser: &parser)
        XCTAssertEqual(engine.string, "(x)\nab(x)\n")
    }
    func testATapEndsTheRunThatDotWouldRepeat() {
        var engine = TextEngine(text: "ab\n"), parser = HelixParser()
        press("i x <Esc>", on: &engine, parser: &parser)
        press("i", on: &engine, parser: &parser)
        engine.sync(text: "xqab\n", selection: NSRange(location: 2, length: 0), mode: .insert)
        engine.perform(.escape)
        press(".", on: &engine, parser: &parser)
        XCTAssertEqual(engine.string.filter { $0 == "q" }.count, 1)
        XCTAssertEqual(engine.string.filter { $0 == "x" }.count, 2, "the last finished run stays: \(engine.string)")
    }
    func testDotIsOneStepAtPrimaryOnly() {
        var engine = TextEngine(text: "a b a\n"), parser = HelixParser()
        press("% s a <CR>", on: &engine, parser: &parser)
        XCTAssertEqual(engine.selections.count, 2)
        var copy = TextEngine(text: "x\n")
        press("i y <Esc>", on: &copy, parser: &parser)
        var seed = engine
        press("i y <Esc>", on: &seed, parser: &parser)
        XCTAssertEqual(seed.string, "yay b yay\n".replacingOccurrences(of: "yay", with: "ya"))
        let outcome = seed.performAtPrimary(.repeatInsert)
        XCTAssertEqual(outcome.notice, .primaryOnly)
        XCTAssertEqual(seed.selections.count, 1)
        XCTAssertEqual(seed.string.filter { $0 == "y" }.count, 3, seed.string)
    }

    // MARK: Macros

    func testAMacroPlaysAsOneStepAndKeepsTheRestOfTheText() {
        var engine = TextEngine(text: "aaa\nbbb\nccc\nddd\n"), parser = HelixParser()
        press("Q A x <Esc> j Q", on: &engine, parser: &parser)
        let before = engine.string
        let outcome = press("2 q", on: &engine, parser: &parser).last
        XCTAssertEqual(engine.string, "aaax\nbbbx\ncccx\nddd\n")
        XCTAssertEqual(outcome?.edits.count, 2, "two inserts, what lies between is untouched and keeps its format")
        XCTAssertTrue(outcome?.edits.allSatisfy { $0.range.length == 0 } ?? false)
        let applied = NSMutableString(string: before)
        for edit in outcome?.edits ?? [] { applied.replaceCharacters(in: edit.range, with: edit.replacement) }
        XCTAssertEqual(applied as String, engine.string)
        if let combined = outcome?.combinedEdit {
            let whole = NSMutableString(string: before)
            whole.replaceCharacters(in: combined.range, with: combined.replacement)
            XCTAssertEqual(whole as String, engine.string)
        } else { XCTFail("no combined edit") }
    }
    func testAMacroReplaysNativeTyping() {
        var engine = TextEngine(text: "ab\ncd\n"), parser = HelixParser()
        press("Q A", on: &engine, parser: &parser)
        native(&engine, "abä\ncd\n", caret: 3)
        engine.perform(.escape)
        press("j Q q", on: &engine, parser: &parser)
        XCTAssertEqual(engine.string, "abä\ncdä\n")
    }
    func testAMacroNeverCallsItself() {
        var engine = TextEngine(text: "ab\n"), parser = HelixParser()
        press("Q A x <Esc> Q Q q A y <Esc> q Q", on: &engine, parser: &parser)
        let before = engine.string
        let outcome = press("q", on: &engine, parser: &parser).last
        XCTAssertEqual(outcome?.notice, .macroStopped)
        XCTAssertEqual(engine.string, "abxxyxy\n", "`A y` ran once, both inner `q` stopped: \(before)")
        XCTAssertEqual(engine.mode, .normal)
    }
    func testMacrosCallingEachOtherEndAndCountsRunOut() {
        var engine = TextEngine(text: "ab\n"), parser = HelixParser()
        press("\" a Q \" b q l Q \" b Q \" a q h Q", on: &engine, parser: &parser)
        press("\" a 9 9 9 9 q", on: &engine, parser: &parser)
        XCTAssertEqual(engine.mode, .normal)
        // Multiplying counts run into the limit, whatever they nest to.
        var big = TextEngine(text: "ab\n")
        press("\" a Q l Q \" b Q 9 9 9 9 \" a q Q", on: &big, parser: &parser)
        press("\" c Q 9 9 9 9 \" b q Q", on: &big, parser: &parser)
        let outcome = press("9 9 9 9 \" c q", on: &big, parser: &parser).last
        XCTAssertEqual(outcome?.notice, nil, "a count in front of the register falls away")
        let limited = press("\" c 9 9 9 9 q", on: &big, parser: &parser).last
        XCTAssertEqual(limited?.notice, .macroStopped)
    }
    func testAStoppedMacroDoesNotStayInInsertMode() {
        var engine = TextEngine(text: "ab\n"), parser = HelixParser()
        press("Q i x <Esc> Q", on: &engine, parser: &parser)
        engine.macroBudget = 0
        press("9 9 9 9 q", on: &engine, parser: &parser)
        XCTAssertEqual(engine.mode, .normal)
    }
    func testOnlyTextCommandsGoIntoAMacro() {
        var engine = TextEngine(text: "ab\n"), parser = HelixParser()
        press("Q", on: &engine, parser: &parser)
        XCTAssertEqual(engine.recordingRegister, "@")
        XCTAssertFalse(engine.record("u", .action(.undo, count: nil, repeats: false)))
        XCTAssertTrue(engine.record("l", .action(.text(.move(.right)), count: nil, repeats: true)))
        press("Q", on: &engine, parser: &parser)
        XCTAssertEqual(engine.macros["@"], [.key("l")])
    }
    func testACancelledSequenceLeavesNothingInTheRecording() {
        var engine = TextEngine(text: "ab\n"), parser = HelixParser()
        press("Q", on: &engine, parser: &parser)
        _ = engine.record("g", .pending(menu: nil))
        // Esc in a text never reaches the parser: `KeyboardRouter.escape(in:)` reports it.
        _ = engine.record("<Esc>", .cancelled)
        _ = engine.record("l", .action(.text(.move(.right)), count: nil, repeats: true))
        press("Q", on: &engine, parser: &parser)
        XCTAssertEqual(engine.macros["@"], [.key("l")])
    }
    func testLeavingTheTextEndsARecordingAndKeepsIt() {
        var engine = TextEngine(text: "ab\n"), parser = HelixParser()
        press("\" a Q l", on: &engine, parser: &parser)
        engine.textEnded()
        XCTAssertNil(engine.recordingRegister)
        XCTAssertEqual(engine.macros["a"], [.key("l")])
    }
    func testAMacroInAPageTypesAtThePrimaryOnly() {
        var engine = TextEngine(text: "a b a a\n"), parser = HelixParser()
        press("Q c x <Esc> Q g g % s a <CR>", on: &engine, parser: &parser)
        XCTAssertEqual(engine.selections.count, 2)
        let outcome = engine.performAtPrimary(.playMacro)
        XCTAssertEqual(outcome.notice, .primaryOnly)
    }
    func testAMacroCountsLogicalLinesAndHandsTheLayoutBack() {
        struct Wide: TextEngineLayout {
            var visibleLines: Int { 7 }
            func verticalTarget(from offset: Int, lines: Int, goal: Double?, in text: NSString) -> (offset: Int, goal: Double) { (0, 0) }
        }
        var engine = TextEngine(text: "a\nb\nc\n"), parser = HelixParser()
        engine.layout = Wide()
        press("Q Q", on: &engine, parser: &parser)
        engine.macros["@"] = [.key("j")]
        press("q", on: &engine, parser: &parser)
        XCTAssertEqual(engine.cursor, 2)
        XCTAssertEqual(engine.layout.visibleLines, 7)
        press("j", on: &engine, parser: &parser)
        XCTAssertEqual(engine.cursor, 0, "back at the app's layout")
    }

    // MARK: Composed edits

    func testComposedEditsAreTheSameAsTheSteps() {
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<300 {
            var text = "abcdefghij" as NSString
            let start = text
            var composer = EditComposer(length: text.length), outcome = TextEngine.Outcome()
            for _ in 0..<Int.random(in: 1...8, using: &generator) {
                var step = TextEngine.Outcome()
                let location = Int.random(in: 0...text.length, using: &generator)
                let length = Int.random(in: 0...min(3, text.length - location), using: &generator)
                step.edits = [.init(range: NSRange(location: location, length: length), replacement: String(repeating: "x", count: Int.random(in: 0...3, using: &generator)))]
                text = text.replacingCharacters(in: step.edits[0].range, with: step.edits[0].replacement) as NSString
                composer.add(step)
            }
            composer.finish(in: text, into: &outcome)
            let applied = NSMutableString(string: start as String)
            for edit in outcome.edits { applied.replaceCharacters(in: edit.range, with: edit.replacement) }
            XCTAssertEqual(applied as String, text as String)
        }
    }

    // MARK: Jump list

    func testJumpsFollowNativeTyping() {
        var engine = TextEngine(text: "eins\nzwei\n"), parser = HelixParser()
        press("j ^s g g", on: &engine, parser: &parser)
        engine.sync(text: "xxeins\nzwei\n", selection: NSRange(location: 0, length: 1))
        press("^o", on: &engine, parser: &parser)
        XCTAssertEqual(engine.cursor, 7, "the saved `z` moved with the text")
    }
    func testJumpsIntoRemovedTextAreClamped() {
        var engine = TextEngine(text: "eins\nzwei\n"), parser = HelixParser()
        press("g e ^s g g", on: &engine, parser: &parser)
        engine.sync(text: "e", selection: NSRange(location: 0, length: 1))
        press("^o", on: &engine, parser: &parser)
        XCTAssertLessThanOrEqual(engine.primary.to, engine.text.length)
    }
    func testJumpsBelongToOneText() {
        var engine = TextEngine(text: "eins\nzwei\n"), parser = HelixParser(), owner = UUID()
        engine.useJumps(of: owner)
        press("j ^s g g", on: &engine, parser: &parser)
        engine.useJumps(of: owner)
        press("^o", on: &engine, parser: &parser)
        XCTAssertEqual(engine.cursor, 5, "same text, same list")
        owner = UUID()
        engine.useJumps(of: owner)
        press("g g ^o", on: &engine, parser: &parser)
        XCTAssertEqual(engine.cursor, 5, "`gg` saved it, a new list knows nothing older")
        press("^o", on: &engine, parser: &parser)
        XCTAssertEqual(engine.cursor, 5)
    }
    func testTheJumpListHasALimit() {
        var engine = TextEngine(text: String(repeating: "x\n", count: 50)), parser = HelixParser()
        for line in 1...40 { press("\(line) G ^s", on: &engine, parser: &parser) }
        XCTAssertLessThanOrEqual(engine.jumps.count, 30)
        press("9 9 ^o", on: &engine, parser: &parser)
        XCTAssertGreaterThan(engine.cursor, 0, "the oldest places fell out; too far back stays")
    }
}
