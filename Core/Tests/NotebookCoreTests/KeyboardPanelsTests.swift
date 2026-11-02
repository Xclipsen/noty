import XCTest
@testable import NotebookCore

final class KeyboardPanelsTests: XCTestCase {
    func testListStartsAtTheFirstEntryAndStopsAtTheEnds() {
        XCTAssertNil(KeyList.moved(nil, dy: 1, count: 0))
        XCTAssertEqual(KeyList.moved(nil, dy: -1, count: 3), 0)
        XCTAssertEqual(KeyList.moved(0, dy: -1, count: 3), 0)
        XCTAssertEqual(KeyList.moved(2, dy: 1, count: 3), 2)
        XCTAssertEqual(KeyList.moved(1, dy: 1, columns: 2, count: 9), 3)
        XCTAssertEqual(KeyList.moved(3, dx: -1, columns: 2, count: 9), 2)
        XCTAssertEqual(KeyList.moved(7, dy: 1, columns: 2, count: 9), 8)
        XCTAssertEqual(KeyList.clamped(5, count: 2), 1)
        XCTAssertNil(KeyList.clamped(5, count: 0))
        XCTAssertNil(KeyList.clamped(nil, count: 4))
    }

    func testRingReadsLinesFromTheLeft() {
        let places: [KeyOptionRing.Place<String>] = [
            .init(id: "below", x: 0, y: 200), .init(id: "right", x: 300, y: 104), .init(id: "off", x: 0, y: 150, enabled: false),
            .init(id: "left", x: 10, y: 100), .init(id: "title", x: 10, y: 20)]
        XCTAssertEqual(KeyOptionRing.order(places), ["title", "left", "right", "below"])
    }

    func testRingStepsAndGoesRound() {
        let order = ["a", "b", "c"]
        XCTAssertEqual(KeyOptionRing.step(from: nil, by: 1, in: order), "a")
        XCTAssertEqual(KeyOptionRing.step(from: nil, by: -1, in: order), "c")
        XCTAssertEqual(KeyOptionRing.step(from: "gone", by: 1, in: order), "a")
        XCTAssertEqual(KeyOptionRing.step(from: "a", by: 1, in: order), "b")
        XCTAssertEqual(KeyOptionRing.step(from: "c", by: 1, in: order), "a")
        XCTAssertEqual(KeyOptionRing.step(from: "a", by: -1, in: order), "c")
        XCTAssertNil(KeyOptionRing.step(from: "c", by: 1, in: order, wraps: false))
        XCTAssertNil(KeyOptionRing.step(from: "a", by: -1, in: order, wraps: false))
        XCTAssertNil(KeyOptionRing.step(from: "a", by: 1, in: [String]()))
    }

    func testChoiceGoesRound() {
        XCTAssertEqual(KeyChoice.stepped(2, by: 1, in: [1, 2, 3]), 3)
        XCTAssertEqual(KeyChoice.stepped(3, by: 1, in: [1, 2, 3]), 1)
        XCTAssertEqual(KeyChoice.stepped(1, by: -1, in: [1, 2, 3]), 3)
        XCTAssertEqual(KeyChoice.stepped(9, by: 1, in: [1, 2, 3]), 1)
    }

    func testSliderStaysOnItsGrid() {
        XCTAssertEqual(KeyChoice.stepped(4, by: 1, in: 1...12, step: 0.5), 4.5)
        XCTAssertEqual(KeyChoice.stepped(12, by: 1, in: 1...12, step: 0.5), 12)
        XCTAssertEqual(KeyChoice.stepped(1, by: -1, in: 1...12, step: 0.5), 1)
    }

    func testWidthStops() {
        XCTAssertEqual(KeyChoice.widths(in: 1...11, count: 6), [1, 3, 5, 7, 9, 11])
        XCTAssertEqual(KeyChoice.widths(in: 1...1.5, count: 6), [1, 1.5])
        XCTAssertEqual(KeyChoice.widths(in: 2...4, count: 1), [2])
    }

    func testChoiceCursorKeepsInsideShorterRows() {
        var cursor = KeyChoiceCursor(rows: [6, 3, 1], row: 0, column: 5)
        cursor.move(dx: 0, dy: 1)
        XCTAssertEqual([cursor.row, cursor.column], [1, 2])
        cursor.move(dx: 1, dy: 0)
        XCTAssertEqual(cursor.column, 2)
        cursor.move(dx: 0, dy: 1)
        XCTAssertEqual([cursor.row, cursor.column], [2, 0])
        cursor.move(dx: 0, dy: 1)
        XCTAssertEqual(cursor.row, 0)
        XCTAssertTrue(cursor.pick(4))
        XCTAssertEqual(cursor.column, 3)
        XCTAssertFalse(cursor.pick(7))
        XCTAssertEqual(cursor.column, 3)
        cursor.move(dx: -9, dy: -1)
        XCTAssertEqual([cursor.row, cursor.column], [2, 0])
    }

    func testChoiceCursorWithoutRows() {
        var cursor = KeyChoiceCursor(rows: [])
        cursor.move(dx: 1, dy: 1)
        XCTAssertFalse(cursor.pick(1))
    }

    func testInputLine() {
        XCTAssertEqual(KeyInputLine.apply("j", to: "ab"), .text("abj"))
        XCTAssertEqual(KeyInputLine.apply("ä", to: ""), .text("ä"))
        XCTAssertEqual(KeyInputLine.apply("<Space>", to: "a"), .text("a "))
        XCTAssertEqual(KeyInputLine.apply("<BS>", to: "ab"), .text("a"))
        XCTAssertEqual(KeyInputLine.apply("<BS>", to: ""), .ignored)
        XCTAssertEqual(KeyInputLine.apply("<CR>", to: "a"), .submit)
        XCTAssertEqual(KeyInputLine.apply("<Esc>", to: "a"), .cancel)
        for token in ["<Tab>", "<Down>", "^n"] { XCTAssertEqual(KeyInputLine.apply(token, to: "a"), .step(1), token) }
        for token in ["<S-Tab>", "<Up>", "^p"] { XCTAssertEqual(KeyInputLine.apply(token, to: "a"), .step(-1), token) }
        for token in ["<Left>", "^d", "<A-;>", "\u{7f}"] { XCTAssertEqual(KeyInputLine.apply(token, to: "a"), .ignored, token) }
        XCTAssertEqual(KeyInputLine.pasted("x\ny\r\nz", to: "a"), "ax y z")
    }

    private final class Panel {}

    func testPanelStackActiveIsTheNewest() {
        var stack = KeyPanelStack<Panel>()
        let sheet = Panel(), page = Panel(), question = Panel()
        XCTAssertNil(stack.active)
        stack.enter(sheet); stack.enter(sheet)
        XCTAssertEqual(stack.panels.count, 1)
        stack.enter(page); stack.enter(question)
        XCTAssertTrue(stack.active === question)
        XCTAssertTrue(stack.leave(sheet), "a pushed page's predecessor goes after it appeared")
        XCTAssertTrue(stack.active === question)
        XCTAssertTrue(stack.leave(question))
        XCTAssertFalse(stack.leave(question))
        XCTAssertTrue(stack.active === page)
        stack.removeAll { _ in true }
        XCTAssertTrue(stack.isEmpty)
    }

    func testFocusTargetAfterEveryClosing() {
        func target(host: Bool = false, editor: Bool = false, held: Bool = false, editing: Bool = false, library: Bool = false) -> KeyFocusTarget {
            KeyFocusTarget.resolve(hasPanelHost: host, inEditor: editor, heldText: held, editorActive: editing, libraryActive: library)
        }
        XCTAssertEqual(target(host: true, editor: true, held: true, editing: true), .panelHost, "a sheet wins over what lies below it")
        XCTAssertEqual(target(editor: true, held: true), .heldText)
        XCTAssertEqual(target(editor: true, editing: true), .page)
        XCTAssertEqual(target(editor: true, library: true), .none, "a sheet of the editor without own keys: nothing to claim yet")
        XCTAssertEqual(target(library: true), .library)
        XCTAssertEqual(target(), .none)
    }

    func testDigitsCountOutsideTheColourPanel() {
        var parser = HelixParser()
        XCTAssertEqual(parser.feed("4", context: .color), .action(.pickEntry(4), count: nil, repeats: false))
        XCTAssertEqual(parser.feed("4", context: .sidebar), .pending(menu: nil))
        XCTAssertEqual(parser.feed("j", context: .sidebar), .action(.listMove(1), count: 4, repeats: true))
    }

    func testPanelBindings() {
        let lists: [HelixContext] = [.sidebar, .list, .dialog]
        for context in lists {
            for (keys, action) in [("j", HelixAction.listMove(1)), ("k", .listMove(-1)), ("<Down>", .listMove(1)), ("<Up>", .listMove(-1)),
                                   ("^n", .listMove(1)), ("^p", .listMove(-1)), ("g g", .listFirst), ("g e", .listLast), ("<CR>", .confirm), ("<Esc>", .cancelPanel)] {
                XCTAssertEqual(HelixKeymap.binding(keys, in: context)?.action, action, "\(keys) in \(context)")
            }
        }
        XCTAssertEqual(HelixKeymap.binding("<Space>", in: .dialog)?.action, .toggleOption)
        XCTAssertEqual(HelixKeymap.binding("<Tab>", in: .dialog)?.action, .listMove(1))
        XCTAssertEqual(HelixKeymap.binding("<S-Tab>", in: .dialog)?.action, .listMove(-1))
        XCTAssertEqual(HelixKeymap.binding("h", in: .dialog)?.action, .adjustOption(-1))
        XCTAssertEqual(HelixKeymap.binding("l", in: .sidebar)?.action, .listColumn(1))
        XCTAssertEqual(HelixKeymap.binding("d", in: .sidebar)?.action, .pageItem(.trash))
        XCTAssertEqual(HelixKeymap.binding("<Space> s", in: .sidebar)?.action, .sidebar)
        XCTAssertEqual(HelixKeymap.binding("/", in: .list)?.action, .typeFilter)
        XCTAssertEqual(HelixKeymap.binding("<Esc>", in: .law)?.action, .cancelPanel)
        XCTAssertEqual(HelixKeymap.binding("<Space> l", in: .law)?.action, .laws)
        XCTAssertEqual(HelixKeymap.binding("n", in: .law)?.action, .page(1))
        XCTAssertEqual(HelixKeymap.binding("j", in: .law)?.action, .scroll(x: 0, y: 1))
        XCTAssertEqual(HelixKeymap.binding("l", in: .color)?.action, .focusItem(dx: 1, dy: 0))
        XCTAssertEqual(HelixKeymap.binding("<CR>", in: .color)?.action, .confirm)
    }

    func testSearchListLeavesLettersForTheField() {
        let letters = HelixKeymap.rows(in: .list).filter { $0.tokens.count == 1 && $0.tokens[0].count == 1 }.map(\.keys).sorted()
        XCTAssertEqual(letters, ["/", ":", "g", "j", "k"], "every other letter goes on into the search field")
    }

    func testPanelsStandInOverviewAndPalette() {
        for context in [HelixContext.sidebar, .list, .dialog, .law, .color] {
            XCTAssertFalse(HelixKeymap.groups(in: context).isEmpty, "\(context)")
            XCTAssertFalse(HelixKeymap.commands(in: context).isEmpty, "\(context)")
            XCTAssertFalse(HelixKeymap.commands(in: context).contains { $0.action == .cancelPanel }, "\(context)")
        }
        XCTAssertEqual(HelixKeymap.menu("<Space>", in: .sidebar)?.entries.first { $0.key == "s" }?.title, "Seitenleiste")
    }

    func testPaletteDirectCommandsNeedAnOpenDocument() {
        XCTAssertEqual(KeyPalette.direct("12", in: .sidebar), .page(12))
        XCTAssertEqual(KeyPalette.direct("w", in: .law), .save)
        XCTAssertNil(KeyPalette.direct("12", in: .dialog))
        XCTAssertNil(KeyPalette.direct("q", in: .list))
    }
}
