import Foundation
import XCTest
@testable import NotebookCore

final class KeyboardCommandsTests: XCTestCase {
    private func parse(_ keys: String, _ context: KeyContext = .text) -> KeyParseResult {
        var parser = KeySequenceParser(), result = KeyParseResult.unbound
        for key in keys.split(separator: " ") { result = parser.feed(String(key), context: context) }
        return result
    }
    private func action(_ keys: String, _ context: KeyContext = .text) -> (KeyAction, Int, Bool)? {
        guard case .action(let action, let count, let explicit, _) = parse(keys, context) else { return nil }
        return (action, count, explicit)
    }

    func testCountsSequencesAndOperators() throws {
        XCTAssertEqual(action("j", .page)?.0, .scroll(x: 0, y: 1))
        XCTAssertEqual(action("1 2 j", .page)?.1, 12)
        XCTAssertEqual(action("g g", .page)?.0, .firstPage)
        let goTo = try XCTUnwrap(action("5 G", .page))
        XCTAssertEqual(goTo.0, .lastPage); XCTAssertEqual(goTo.1, 5); XCTAssertTrue(goTo.2)
        XCTAssertEqual(action("t p", .page)?.0, .tool(.pen))
        XCTAssertEqual(action("t E", .page)?.0, .tool(.precisionEraser))
        XCTAssertEqual(action("d d")?.0, .operateLine(.delete))
        XCTAssertEqual(action("3 d d")?.1, 3)
        XCTAssertEqual(action("c w")?.0, .operate(.change, .wordForward))
        let double = try XCTUnwrap(action("2 d 3 w"))
        XCTAssertEqual(double.0, .operate(.delete, .wordForward)); XCTAssertEqual(double.1, 6)
        XCTAssertEqual(action("d g g")?.0, .operate(.delete, .documentStart))
        XCTAssertEqual(action("c i w")?.0, .operate(.change, .innerWord))
        XCTAssertEqual(action("y $")?.0, .operate(.yank, .lineEnd))
        XCTAssertEqual(action("y y")?.0, .operateLine(.yank))
    }

    func testZeroIsLineStartUnlessItExtendsACount() {
        XCTAssertEqual(action("0")?.0, .move(.lineStart))
        XCTAssertEqual(action("1 0 j")?.1, 10)
        XCTAssertEqual(action("d 0")?.0, .operate(.delete, .lineStart))
        XCTAssertEqual(action("1 0 d d")?.1, 10)
    }

    func testEscapeAndUnknownKeysDropAStartedSequence() {
        var parser = KeySequenceParser()
        XCTAssertEqual(parser.feed("3", context: .text), .pending)
        XCTAssertEqual(parser.feed("d", context: .text), .pending)
        XCTAssertEqual(parser.display, "3d")
        XCTAssertEqual(parser.feed("<Esc>", context: .text), .pending)
        XCTAssertTrue(parser.isIdle)
        XCTAssertEqual(parser.feed("<Esc>", context: .text), .action(.cancel, count: 1, explicitCount: false, repeats: false), "a second Esc acts")
        XCTAssertEqual(parser.feed("g", context: .page), .pending)
        XCTAssertEqual(parser.feed("Q", context: .page), .unbound)
        XCTAssertTrue(parser.isIdle)
        XCTAssertEqual(parser.feed("d", context: .text), .pending)
        XCTAssertEqual(parser.feed("Q", context: .text), .unbound)
        XCTAssertTrue(parser.isIdle)
    }

    func testContextsKeepTheirMeaning() {
        XCTAssertEqual(action("d d", .library)?.0, .trashItem)
        XCTAssertEqual(action("d d", .page)?.0, .deleteObject)
        XCTAssertEqual(action("j", .library)?.0, .focusItem(dx: 0, dy: 1))
        XCTAssertEqual(action("j", .text)?.0, .move(.down))
        XCTAssertEqual(action("d", .visual)?.0, .operateSelection(.delete))
        XCTAssertEqual(action("i", .page)?.0, .write(.here))
        XCTAssertEqual(action("i", .text)?.0, .insert(.here))
    }

    func testKeymapHasNoBindingHiddenBehindAnother() {
        for context in KeyContext.allCases {
            let rows = KeyMap.bindings.filter { $0.contexts.contains(context) }
            let keys = rows.map(\.keys)
            XCTAssertEqual(Set(keys).count, keys.count, "duplicate keys in \(context): \(keys)")
            for row in rows {
                for other in rows where other.keys != row.keys {
                    XCTAssertFalse(other.keys.hasPrefix(row.keys + " "), "\(row.keys) hides \(other.keys) in \(context)")
                }
            }
        }
    }

    func testEveryBindingIsReachableThroughTheParser() {
        for context in KeyContext.allCases {
            for row in KeyMap.bindings where row.contexts.contains(context) {
                if context == .text, KeyMap.operators[row.keys] != nil { continue } // operators wait for a motion
                guard case .action(let found, _, _, _) = parse(row.keys, context) else { return XCTFail("\(row.keys) in \(context)") }
                XCTAssertEqual(found, row.action, row.keys)
            }
        }
    }

    func testPalette() {
        XCTAssertEqual(KeyPalette.direct(" w "), .save)
        XCTAssertEqual(KeyPalette.direct("q"), .close)
        XCTAssertEqual(KeyPalette.direct("wq"), .close)
        XCTAssertEqual(KeyPalette.direct("12"), .page(12))
        XCTAssertNil(KeyPalette.direct("0"))
        XCTAssertNil(KeyPalette.direct("pdf"))
        XCTAssertNotNil(KeyPalette.score("pdf", in: "Als PDF exportieren"))
        XCTAssertNil(KeyPalette.score("xyz", in: "Als PDF exportieren"))
        XCTAssertLessThan(KeyPalette.score("st", in: "Stift")!, KeyPalette.score("st", in: "Lasso starten")!)
        XCTAssertEqual(KeyPalette.score("", in: "Alles"), 0)
    }
}

final class TextMotionsTests: XCTestCase {
    private func motion(_ motion: TextMotion, _ text: String, _ caret: Int, count: Int = 1) -> Int? {
        TextMotions.target(motion, in: text as NSString, from: caret, count: count)
    }
    private func deleted(_ motion: TextMotion, _ text: String, _ caret: Int, count: Int = 1) -> String {
        let value = text as NSString
        return value.replacingCharacters(in: TextMotions.range(of: motion, in: value, from: caret, count: count).range, with: "")
    }

    func testCharacterMotionsStayOnTheLineAndOnACharacter() {
        let text = "ab\ncd"
        XCTAssertEqual(motion(.right, text, 0), 1)
        XCTAssertEqual(motion(.right, text, 1), 1, "never behind the line's last character")
        XCTAssertEqual(motion(.left, text, 3), 3, "never onto the previous line")
        XCTAssertEqual(motion(.right, text, 3, count: 9), 4)
        XCTAssertEqual(motion(.lineEnd, text, 3), 4)
        XCTAssertEqual(motion(.lineStart, text, 4), 3)
        XCTAssertEqual(TextMotions.normalCaret(text as NSString, 2), 1)
        XCTAssertEqual(TextMotions.normalCaret("" as NSString, 0), 0)
        XCTAssertEqual(TextMotions.normalCaret("a\n\nb" as NSString, 2), 2, "an empty line keeps its place")
    }

    func testComposedCharactersMoveAsOne() {
        let text = "a👍🏽b"
        XCTAssertEqual(motion(.right, text, 0), 1)
        XCTAssertEqual(motion(.right, text, 1), 5)
        XCTAssertEqual(motion(.left, text, 5), 1)
        XCTAssertEqual(TextMotions.deleteCharacter(in: text as NSString, at: 1, before: false)?.range, NSRange(location: 1, length: 4))
    }

    func testWordMotions() {
        let text = "eins, zwei drei"
        XCTAssertEqual(motion(.wordForward, text, 0), 4, "punctuation is a word")
        XCTAssertEqual(motion(.wordForward, text, 4), 6)
        XCTAssertEqual(motion(.wordForward, text, 0, count: 3), 11)
        XCTAssertEqual(motion(.wordBackward, text, 11), 6)
        XCTAssertEqual(motion(.wordBackward, text, 6), 4)
        XCTAssertEqual(motion(.wordEnd, text, 0), 3)
        XCTAssertEqual(motion(.wordEnd, text, 3), 4)
        XCTAssertEqual(motion(.wordForward, "ä ö", 0), 2, "umlauts are letters")
        XCTAssertEqual(motion(.wordForward, "a\n\nb", 0), 2, "an empty line is a stop")
        XCTAssertEqual(motion(.wordForward, "ende", 2), 4)
        XCTAssertEqual(motion(.wordBackward, "ende", 0), 0)
    }

    func testDocumentAndParagraphMotions() {
        let text = "eins\n\n  zwei\ndrei"
        XCTAssertEqual(motion(.documentStart, text, 9), 0)
        XCTAssertEqual(motion(.documentEnd, text, 0), 13)
        XCTAssertEqual(motion(.paragraphForward, text, 0), 5)
        XCTAssertEqual(motion(.paragraphForward, text, 5), (text as NSString).length)
        XCTAssertEqual(motion(.paragraphBackward, text, 9), 5)
        XCTAssertEqual(motion(.paragraphBackward, text, 5), 0)
        XCTAssertEqual(motion(.lineFirstNonBlank, text, 11), 8)
        XCTAssertNil(motion(.down, text, 0), "the app follows the laid-out lines")
    }

    func testOperatorRanges() {
        XCTAssertEqual(deleted(.wordForward, "eins zwei", 0), "zwei")
        XCTAssertEqual(deleted(.wordForward, "eins\nzwei", 0), "\nzwei", "dw keeps the line break")
        XCTAssertEqual(deleted(.wordEnd, "eins zwei", 0), " zwei")
        XCTAssertEqual(deleted(.lineEnd, "eins zwei\ndrei", 5), "eins \ndrei")
        XCTAssertEqual(deleted(.lineStart, "eins zwei", 5), "zwei")
        XCTAssertEqual(deleted(.wordBackward, "eins zwei", 5), "zwei")
        XCTAssertEqual(deleted(.innerWord, "eins zwei drei", 6), "eins  drei")
        XCTAssertEqual(deleted(.right, "abc", 0, count: 2), "c")
        XCTAssertEqual(deleted(.down, "a\nb\nc", 0), "c")
        XCTAssertEqual(deleted(.up, "a\nb\nc", 2), "c")
        XCTAssertEqual(deleted(.documentEnd, "a\nb\nc", 2), "a")
        XCTAssertEqual(deleted(.documentStart, "a\nb\nc", 2), "c")
        XCTAssertTrue(TextMotions.range(of: .down, in: "a\nb", from: 0).linewise)
        XCTAssertFalse(TextMotions.range(of: .wordForward, in: "a b", from: 0).linewise)
    }

    func testChangeLeavesWhatDeleteTakes() {
        func changed(_ motion: TextMotion, _ text: String, _ caret: Int, count: Int = 1) -> String {
            let value = text as NSString
            return value.replacingCharacters(in: TextMotions.changeRange(of: motion, in: value, from: caret, count: count), with: "")
        }
        XCTAssertEqual(changed(.wordForward, "foo bar", 0), " bar", "cw keeps the space")
        XCTAssertEqual(changed(.wordForward, "foo bar baz", 0, count: 2), " baz")
        XCTAssertEqual(changed(.wordForward, "foo  bar", 3), "foobar", "on spaces like dw")
        XCTAssertEqual(changed(.down, "a\nb\nc", 0), "\nc", "cj keeps an empty line")
        XCTAssertEqual(changed(.up, "a\nb\nc", 2), "\nc")
        XCTAssertEqual(changed(.documentEnd, "a\nb\nc", 2), "a\n")
        XCTAssertEqual(changed(.documentStart, "a\nb\nc", 2), "\nc")
        XCTAssertEqual(changed(.lineEnd, "abc\nd", 1), "a\nd")
        XCTAssertEqual(("aaa\n\nccc" as NSString).substring(with: TextMotions.lineContent(in: "aaa\n\nccc" as NSString, at: 5)), "ccc", "cc after an empty line")
        XCTAssertEqual(TextMotions.lineContent(in: "aaa\n\nccc" as NSString, at: 4).length, 0)
    }

    func testVerticalOperatorsDoNothingWithoutALine() {
        XCTAssertEqual(TextMotions.range(of: .down, in: "nur\nzwei" as NSString, from: 5).range.length, 0, "dj on the last line")
        XCTAssertEqual(TextMotions.range(of: .down, in: "solo" as NSString, from: 1).range.length, 0)
        XCTAssertEqual(TextMotions.range(of: .up, in: "nur\nzwei" as NSString, from: 1).range.length, 0, "dk on the first line")
    }

    func testWholeLines() {
        let text = "eins\nzwei\ndrei" as NSString
        XCTAssertEqual(text.substring(with: TextMotions.lineRange(in: text, at: 6)), "zwei\n")
        XCTAssertEqual(text.substring(with: TextMotions.lineRange(in: text, at: 0, count: 2)), "eins\nzwei\n")
        XCTAssertEqual(text.substring(with: TextMotions.lineRange(in: text, at: 11)), "\ndrei", "the last line takes the break before it")
        XCTAssertEqual(text.substring(with: TextMotions.lineRange(in: text, at: 11, trailingBreakOnly: true)), "drei")
        XCTAssertEqual(TextMotions.lineRange(in: "solo" as NSString, at: 1), NSRange(location: 0, length: 4))
    }

    func testPaste() {
        let text = "eins\nzwei" as NSString
        func apply(_ edit: TextMotions.Edit) -> String { text.replacingCharacters(in: edit.range, with: edit.replacement) }
        XCTAssertEqual(apply(TextMotions.paste("neu\n", linewise: true, in: text, at: 1, before: false)), "eins\nneu\nzwei")
        XCTAssertEqual(apply(TextMotions.paste("neu\n", linewise: true, in: text, at: 6, before: true)), "eins\nneu\nzwei")
        let last = TextMotions.paste("neu\n", linewise: true, in: text, at: 6, before: false)
        XCTAssertEqual(apply(last), "eins\nzwei\nneu"); XCTAssertEqual(last.caret, 10)
        let inline = TextMotions.paste("xy", linewise: false, in: text, at: 1, before: false)
        XCTAssertEqual(apply(inline), "eixyns\nzwei"); XCTAssertEqual(inline.caret, 3)
        XCTAssertEqual(apply(TextMotions.paste("xy", linewise: false, in: text, at: 1, before: true)), "exyins\nzwei")
    }

    func testJoinAndEntries() {
        let text = "eins\n   zwei\n\ndrei" as NSString
        let join = TextMotions.joinLines(in: text, at: 1)
        XCTAssertEqual(join?.range, NSRange(location: 4, length: 4)); XCTAssertEqual(join?.replacement, " ")
        XCTAssertEqual(TextMotions.joinLines(in: "ende" as NSString, at: 0), nil)
        XCTAssertEqual(TextMotions.insertion(.lineEnd, in: text, at: 1).caret, 4)
        XCTAssertEqual(TextMotions.insertion(.lineStart, in: text, at: 10).caret, 8)
        XCTAssertEqual(TextMotions.insertion(.afterCaret, in: text, at: 0).caret, 1)
        XCTAssertEqual(TextMotions.insertion(.afterCaret, in: text, at: 3).caret, 4)
        let below = TextMotions.insertion(.lineBelow, in: text, at: 1)
        XCTAssertEqual(below.range.location, 4); XCTAssertEqual(below.replacement, "\n"); XCTAssertEqual(below.caret, 5)
        let above = TextMotions.insertion(.lineAbove, in: text, at: 6)
        XCTAssertEqual(above.range.location, 5); XCTAssertEqual(above.caret, 5)
    }
}
