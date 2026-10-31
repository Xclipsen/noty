import XCTest
@testable import NotebookCore

final class HelixParserTests: XCTestCase {
    private func feed(_ keys: String, _ context: HelixContext = .text) -> (result: HelixParseResult, parser: HelixParser) {
        var parser = HelixParser(), result = HelixParseResult.unbound
        for token in keys.split(separator: " ") { result = parser.feed(String(token), context: context) }
        return (result, parser)
    }
    private func text(_ command: TextEngine.Command, count: Int? = nil, repeats: Bool = false) -> HelixParseResult {
        .action(.text(command), count: count, repeats: repeats)
    }

    func testCounts() {
        XCTAssertEqual(feed("w").result, text(.word(.nextStart, long: false), repeats: true))
        XCTAssertEqual(feed("1 2 j").result, text(.move(.down), count: 12, repeats: true))
        XCTAssertEqual(feed("1 0 x").result, text(.extendLine, count: 10, repeats: true))
        XCTAssertEqual(feed("9 9 9 9 9 9 l").result, text(.move(.right), count: 9_999, repeats: true))
    }

    func testAZeroOnlyContinuesACount() {
        XCTAssertEqual(feed("0").result, .unbound)
        XCTAssertTrue(feed("0").parser.isIdle)
    }

    func testCountBeforeAMenu() {
        XCTAssertEqual(feed("5 G").result, text(.gotoLine, count: 5))
        XCTAssertEqual(feed("G").result, text(.gotoLine))
        XCTAssertEqual(feed("5 g g").result, text(.gotoFileStart, count: 5))
        XCTAssertEqual(feed("5 G", .page).result, .action(.gotoPage, count: 5, repeats: false))
        XCTAssertEqual(feed("5 g g", .page).result, .action(.firstPage, count: 5, repeats: false))
    }

    func testDigitsInsideAMenuAreNoCount() {
        XCTAssertEqual(feed("g 5").result, .unbound)
        XCTAssertTrue(feed("g 5").parser.isIdle)
    }

    func testMenusShowTheirNextKeys() {
        guard case .pending(let menu?) = feed("g").result else { return XCTFail("no menu") }
        XCTAssertEqual(menu.title, "Gehe zu")
        XCTAssertEqual(menu.entries.map(\.key).sorted(), ["e", "g", "h", "l", "s"])
        XCTAssertEqual(feed("g").parser.menu, menu)
        XCTAssertEqual(feed("g g").parser.menu, nil)
        guard case .pending(let page?) = feed("g", .page).result else { return XCTFail("no menu") }
        XCTAssertEqual(page.entries.map(\.key).sorted(), ["e", "g", "n", "p"])
    }

    func testSubmenus() {
        guard case .pending(let root?) = feed("<Space>", .page).result else { return XCTFail("no menu") }
        XCTAssertEqual(root.title, "Menü")
        XCTAssertEqual(root.entries.first { $0.key == "t" }?.isMenu, true)
        XCTAssertEqual(root.entries.first { $0.key == "s" }?.isMenu, false)
        guard case .pending(let tools?) = feed("<Space> t", .page).result else { return XCTFail("no menu") }
        XCTAssertEqual(tools.title, "Werkzeuge")
        XCTAssertEqual(feed("<Space> t p", .text).result, .action(.tool(.pen), count: nil, repeats: false))
        XCTAssertEqual(feed("t p", .page).result, .action(.tool(.pen), count: nil, repeats: false))
    }

    func testAKeyThatWaitsForACharacter() {
        XCTAssertEqual(feed("f").result, .pending(menu: HelixMenu(title: HelixPrompt.findForward.title, entries: [])))
        XCTAssertEqual(feed("f x").result, text(.find("x", forward: true, inclusive: true)))
        XCTAssertEqual(feed("3 t x").result, text(.find("x", forward: true, inclusive: false), count: 3))
        XCTAssertEqual(feed("F x").result, text(.find("x", forward: false, inclusive: true)))
        XCTAssertEqual(feed("T x").result, text(.find("x", forward: false, inclusive: false)))
        XCTAssertEqual(feed("r ä").result, text(.replace("ä")))
        XCTAssertEqual(feed("f 5").result, text(.find("5", forward: true, inclusive: true)))
        XCTAssertEqual(feed("f 😀").result, text(.find("😀", forward: true, inclusive: true)))
        XCTAssertEqual(feed("f <CR>").result, text(.find("\n", forward: true, inclusive: true)))
        XCTAssertEqual(feed("r <Tab>").result, text(.replace("\t")))
        XCTAssertEqual(feed("f <Space>").result, text(.find(" ", forward: true, inclusive: true)))
        XCTAssertEqual(feed("f ^d").result, .unbound)
        XCTAssertTrue(feed("f ^d").parser.isIdle)
    }

    func testTextObjects() {
        XCTAssertEqual(feed("m i w").result, text(.selectObject(.word, around: false)))
        XCTAssertEqual(feed("m a W").result, text(.selectObject(.longWord, around: true)))
        XCTAssertEqual(feed("m i p").result, text(.selectObject(.paragraph, around: false)))
        XCTAssertEqual(feed("m a (").result, text(.selectObject(.pair("("), around: true)))
        XCTAssertEqual(feed("2 m i \"").result, text(.selectObject(.pair("\""), around: false), count: 2))
        XCTAssertEqual(feed("m i m").result, text(.selectObject(.closestPair, around: false)))
        XCTAssertEqual(feed("m i q").result, .unbound)
        XCTAssertEqual(feed("m m").result, text(.matchBracket))
        guard case .pending(let menu?) = feed("m i").result else { return XCTFail("no menu") }
        XCTAssertTrue(["w", "p", "(", "[", "{", "\"", "'"].allSatisfy { key in menu.entries.contains { $0.key == key } })
    }

    func testSurround() {
        XCTAssertEqual(feed("m s \"").result, text(.surroundAdd("\"")))
        XCTAssertEqual(feed("m s <CR>").result, text(.surroundAdd("\n")))
        XCTAssertEqual(feed("m d (").result, text(.surroundDelete("(")))
        XCTAssertEqual(feed("m d m").result, text(.surroundDelete(nil)))
        XCTAssertEqual(feed("m r ( [").result, text(.surroundReplace("(", with: "[")))
        XCTAssertEqual(feed("m r m [").result, text(.surroundReplace(nil, with: "[")))
        XCTAssertEqual(feed("2 m r ( [").result, text(.surroundReplace("(", with: "["), count: 2))
        guard case .pending(let menu?) = feed("m r (").result else { return XCTFail("no menu") }
        XCTAssertEqual(menu.title, "Ersetzen durch")
    }

    func testEscapeDropsAStartedSequence() {
        for keys in ["5", "g", "f", "m", "m i", "m r", "m r (", "<Space>", "<Space> t", "1 2 g"] {
            for escape in ["<Esc>", "^[", "^c"] {
                var parser = feed(keys).parser
                XCTAssertEqual(parser.feed(escape, context: .text), .cancelled, keys)
                XCTAssertTrue(parser.isIdle)
                XCTAssertNil(parser.menu)
                XCTAssertEqual(parser.display, "")
            }
        }
    }

    func testEscapeWithNothingStartedIsACommandInTheEditor() {
        for token in ["<Esc>", "^[", "^c"] {
            XCTAssertEqual(feed(token).result, .action(.escape, count: nil, repeats: false))
            XCTAssertEqual(feed(token, .page).result, .action(.escape, count: nil, repeats: false))
        }
    }

    func testUnboundDropsTheSequence() {
        var parser = HelixParser()
        XCTAssertEqual(parser.feed("3", context: .text), .pending(menu: nil))
        XCTAssertEqual(parser.feed("Q", context: .text), .unbound)
        XCTAssertTrue(parser.isIdle)
        XCTAssertEqual(parser.feed("g", context: .text), .pending(menu: HelixKeymap.menu("g", in: .text)))
        XCTAssertEqual(parser.feed("Q", context: .text), .unbound)
        XCTAssertEqual(parser.feed("w", context: .text), text(.word(.nextStart, long: false), repeats: true))
    }

    func testDisplay() {
        XCTAssertEqual(feed("1 2").parser.display, "12")
        XCTAssertEqual(feed("5 g").parser.display, "5g")
        XCTAssertEqual(feed("m i").parser.display, "mi")
        XCTAssertEqual(feed("m r (").parser.display, "mr(")
        XCTAssertEqual(feed("<Space> t").parser.display, "Space t")
    }

    func testResetLeavesNothingBehind() {
        var parser = feed("3 m r (").parser
        parser.reset()
        XCTAssertTrue(parser.isIdle)
        XCTAssertEqual(parser.feed("w", context: .text), text(.word(.nextStart, long: false), repeats: true))
    }

    func testRepeatFlagComesFromTheTable() {
        XCTAssertEqual(feed("j", .page).result, .action(.scroll(x: 0, y: 1), count: nil, repeats: true))
        XCTAssertEqual(feed("d").result, text(.delete))
        XCTAssertEqual(feed("d", .library).result, .action(.trashItem, count: nil, repeats: false))
    }

    func testSameKeyByContext() {
        XCTAssertEqual(feed("i", .page).result, .action(.write, count: nil, repeats: false))
        XCTAssertEqual(feed("i").result, text(.insert(.before)))
        XCTAssertEqual(feed("i", .library).result, .unbound)
        XCTAssertEqual(feed("<CR>", .library).result, .action(.openItem, count: nil, repeats: false))
        XCTAssertEqual(feed("<CR>", .page).result, .action(.write, count: nil, repeats: false))
        XCTAssertEqual(feed("<CR>").result, .unbound)
        XCTAssertEqual(feed("m", .library).result, .action(.moveItem, count: nil, repeats: false))
        XCTAssertEqual(feed("m", .page).result, .unbound)
        XCTAssertEqual(feed("<Space> m", .page).result, .action(.bookmark, count: nil, repeats: false))
    }
}
