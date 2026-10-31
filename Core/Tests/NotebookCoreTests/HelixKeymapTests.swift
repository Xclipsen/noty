import XCTest
@testable import NotebookCore

final class HelixKeymapTests: XCTestCase {
    func testEveryKeyHasOneMeaningPerContext() {
        for context in HelixContext.allCases {
            let keys = HelixKeymap.rows(in: context).map(\.keys)
            XCTAssertEqual(keys.count, Set(keys).count, "\(context): \(keys.filter { key in keys.filter { $0 == key }.count > 1 })")
        }
    }

    func testMenusAreRealNodes() {
        for context in HelixContext.allCases {
            let rows = HelixKeymap.rows(in: context)
            for row in rows {
                // Every prefix of a sequence is a menu, so nothing is reachable only by accident.
                for length in 1..<max(1, row.tokens.count) {
                    let prefix = row.tokens[..<length].joined(separator: " ")
                    XCTAssertEqual(HelixKeymap.binding(prefix, in: context)?.target, .menu, "\(row.keys) in \(context)")
                }
                if row.target == .menu {
                    XCTAssertFalse(HelixKeymap.menu(row.keys, in: context)?.entries.isEmpty ?? true, "\(row.keys) in \(context) is empty")
                }
                XCTAssertFalse(row.title.isEmpty)
                XCTAssertFalse(row.group.isEmpty)
            }
        }
    }

    func testNoDestructiveKeyRepeats() {
        let destructive: Set<String> = ["d", "c", "p", "P", "R", "r", "~", "`", "J", ">", "<", "y", "D"]
        for row in HelixKeymap.bindings where destructive.contains(row.keys) { XCTAssertFalse(row.repeats, row.keys) }
        for row in HelixKeymap.bindings where row.tokens.first == "m" && row.tokens.count > 1 { XCTAssertFalse(row.repeats, row.keys) }
        for row in HelixKeymap.bindings {
            switch row.action {
            case .text(.delete)?, .text(.change)?, .text(.paste)?, .text(.replaceWithRegister)?, .trashItem?, .deleteObject?, .undo?, .redo?:
                XCTAssertFalse(row.repeats, row.keys)
            default: break
            }
        }
        for keys in ["w", "j", "x", "n"] { XCTAssertEqual(HelixKeymap.binding(keys, in: .text)?.repeats, true, keys) }
    }

    func testKeysThatMeanTheSameEverywhere() {
        for context in HelixContext.allCases {
            XCTAssertEqual(HelixKeymap.binding(":", in: context)?.action, .palette)
            XCTAssertEqual(HelixKeymap.binding("g", in: context)?.target, .menu)
            XCTAssertEqual(HelixKeymap.binding("<Space>", in: context)?.target, .menu)
            XCTAssertEqual(HelixKeymap.binding("<Space> ?", in: context)?.action, .palette)
            XCTAssertEqual(HelixKeymap.binding("<Space> h", in: context)?.action, .help, "the overview needs one way in every context")
            XCTAssertEqual(HelixKeymap.binding("<Space> f", in: context)?.action, .searchAll)
            XCTAssertEqual(HelixKeymap.binding("<Space> e", in: context)?.target, .menu)
            XCTAssertEqual(HelixKeymap.binding("<Space> e p", in: context)?.action, .export(.pdf))
        }
        for context in [HelixContext.page, .text] {
            XCTAssertEqual(HelixKeymap.binding("z", in: context)?.target, .menu)
            XCTAssertEqual(HelixKeymap.binding("z z", in: context)?.action, .fit)
            XCTAssertEqual(HelixKeymap.binding("u", in: context)?.action, .undo)
            XCTAssertEqual(HelixKeymap.binding("U", in: context)?.action, .redo)
            XCTAssertEqual(HelixKeymap.binding("<Esc>", in: context)?.action, .escape)
            XCTAssertEqual(HelixKeymap.binding("^[", in: context)?.action, .escape)
            XCTAssertEqual(HelixKeymap.binding("^c", in: context)?.action, .escape)
            XCTAssertEqual(HelixKeymap.binding("<Space> s", in: context)?.action, .sidebar)
            XCTAssertEqual(HelixKeymap.binding("<Space> o", in: context)?.action, .outline)
            XCTAssertEqual(HelixKeymap.binding("<Space> t", in: context)?.target, .menu)
        }
        XCTAssertEqual(HelixKeymap.binding("?", in: .library)?.action, .help)
        XCTAssertEqual(HelixKeymap.binding("?", in: .page)?.action, .help)
        XCTAssertEqual(HelixKeymap.binding("/", in: .library)?.action, .search)
        XCTAssertEqual(HelixKeymap.binding("/", in: .text)?.action, .searchPrompt(backward: false))
    }

    func testPageBindings() {
        let expected: [(String, HelixAction)] = [
            ("j", .scroll(x: 0, y: 1)), ("<Up>", .scroll(x: 0, y: -1)), ("^d", .scrollScreen(0.5)), ("^b", .scrollScreen(-0.9)),
            ("g g", .firstPage), ("g e", .lastPage), ("g n", .page(1)), ("g p", .page(-1)), ("G", .gotoPage), ("+", .zoom(1)), ("-", .zoom(-1)),
            ("t t", .tool(.text)), ("<Tab>", .nextObject(1)), ("<S-Tab>", .nextObject(-1)), ("<CR>", .write), ("i", .write),
            ("d", .deleteObject), ("y", .copyObject), ("p", .pasteObject), ("%", .selectAll), ("D", .duplicateObject), ("<Space> m", .bookmark)]
        for (keys, action) in expected { XCTAssertEqual(HelixKeymap.binding(keys, in: .page)?.action, action, keys) }
        // The space bar belongs to the menu now.
        XCTAssertEqual(HelixKeymap.binding("<Space>", in: .page)?.target, .menu)
    }

    func testLibraryBindings() {
        let expected: [(String, HelixAction)] = [
            ("j", .focusItem(dx: 0, dy: 1)), ("<Left>", .focusItem(dx: -1, dy: 0)), ("g g", .focusFirstItem), ("g e", .focusLastItem),
            ("<CR>", .openItem), ("o", .openItem), ("-", .parentFolder), ("<BS>", .parentFolder), ("/", .search), ("n", .newNotebook),
            ("N", .newTextDocument), ("f", .newFolder), ("r", .renameItem), ("d", .trashItem), ("y", .duplicateItem), ("P", .pinItem),
            ("m", .moveItem), ("<Space> e n", .export(.noty))]
        for (keys, action) in expected { XCTAssertEqual(HelixKeymap.binding(keys, in: .library)?.action, action, keys) }
    }

    func testTextBindings() {
        let commands: [(String, TextEngine.Command)] = [
            ("h", .move(.left)), ("<Down>", .move(.down)), ("W", .word(.nextStart, long: true)), ("b", .word(.previousStart, long: false)), ("E", .word(.nextEnd, long: true)),
            ("g g", .gotoFileStart), ("g e", .gotoLastLine), ("g h", .gotoLineStart), ("g l", .gotoLineEnd), ("g s", .gotoFirstNonBlank), ("G", .gotoLine),
            ("%", .selectAll), ("x", .extendLine), ("X", .extendToLineBounds), (";", .collapse), ("<A-;>", .flip), (",", .keepPrimary), ("C", .copyToNextLine),
            ("d", .delete), ("c", .change), ("y", .yank), ("p", .paste(before: false)), ("P", .paste(before: true)), ("R", .replaceWithRegister),
            ("~", .switchCase), ("`", .lowercase), ("J", .joinLines), (">", .indent), ("<", .unindent), ("i", .insert(.before)), ("a", .insert(.after)),
            ("I", .insert(.lineStart)), ("A", .insert(.lineEnd)), ("o", .insert(.lineBelow)), ("O", .insert(.lineAbove)), ("v", .toggleSelect), ("m m", .matchBracket),
            ("n", .searchNext), ("N", .searchPrevious), ("*", .searchSelection), ("^d", .screen(0.5)), ("^u", .screen(-0.5)), ("^f", .screen(1)), ("^b", .screen(-1))]
        for (keys, command) in commands { XCTAssertEqual(HelixKeymap.binding(keys, in: .text)?.action, .text(command), keys) }
        XCTAssertEqual(HelixKeymap.binding("s", in: .text)?.action, .selectPrompt)
        XCTAssertEqual(HelixKeymap.binding("?", in: .text)?.action, .searchPrompt(backward: true))
        XCTAssertEqual(HelixKeymap.binding("t", in: .text)?.target, .prompt(.tillForward))
        XCTAssertEqual(HelixKeymap.binding("m", in: .text)?.target, .menu)
    }

    func testToolsUnderBothPrefixes() {
        let short = HelixKeymap.rows(in: .page).filter { $0.tokens.first == "t" && $0.tokens.count == 2 }
        let long = HelixKeymap.rows(in: .page).filter { $0.tokens.prefix(2) == ["<Space>", "t"] && $0.tokens.count == 3 }
        XCTAssertEqual(short.map { $0.tokens[1] }, long.map { $0.tokens[2] })
        XCTAssertEqual(short.map(\.action), long.map(\.action))
        XCTAssertGreaterThanOrEqual(short.count, 11)
    }

    func testPaletteHasEveryCommandOnce() {
        for context in HelixContext.allCases {
            let commands = HelixKeymap.commands(in: context)
            XCTAssertEqual(commands.count, Set(commands.map(\.title)).count)
            XCTAssertFalse(commands.contains { $0.action == nil || $0.action == .palette || $0.action == .escape })
        }
        XCTAssertTrue(HelixKeymap.commands(in: .page).contains { $0.title == "Lesezeichen" })
    }

    func testOverviewHasGroupsInTableOrder() {
        let groups = HelixKeymap.groups(in: .text)
        XCTAssertEqual(groups.first?.name, "Überall")
        XCTAssertTrue(groups.map(\.name).contains("Auswählen und umschließen"))
        XCTAssertFalse(groups.contains { $0.rows.contains { $0.target == .menu } })
        XCTAssertTrue(groups.flatMap(\.rows).contains { $0.keys == "f" })
    }

    func testLabels() {
        XCTAssertEqual(HelixKeymap.binding("g g", in: .text)?.label, "gg")
        XCTAssertEqual(HelixKeymap.binding("^d", in: .text)?.label, "⌃d")
        XCTAssertEqual(HelixKeymap.binding("<A-;>", in: .text)?.label, "⌥;")
        XCTAssertEqual(HelixKeymap.binding("<Space> t p", in: .page)?.label, "Space tp")
        XCTAssertEqual(HelixKeymap.binding("<Esc>", in: .text)?.label, "Esc")
    }
}
