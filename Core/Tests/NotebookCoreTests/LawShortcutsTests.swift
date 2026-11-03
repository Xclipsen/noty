import XCTest
@testable import NotebookCore

final class LawShortcutsTests: XCTestCase {
    func testIDsAreUnique() {
        let ids = LawShortcuts.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
        for row in LawShortcuts.all { XCTAssertEqual(LawShortcuts.shortcut(id: row.id), row) }
    }

    /// One combination, one meaning: in the notebook, and with the focus,
    /// where the menu „Gesetze“ stays active as well.
    func testCombosAreUniquePerContext() {
        for context in LawShortcuts.Context.allCases {
            var seen: [LawShortcuts.Combo: String] = [:]
            for row in LawShortcuts.shortcuts(in: context) {
                guard let combo = row.combo else { continue }
                XCTAssertNil(seen[combo], "\(combo) doppelt in \(context): \(seen[combo] ?? "") und \(row.id)")
                seen[combo] = row.id
            }
        }
        XCTAssertEqual(LawShortcuts.shortcuts(in: .focus).count, LawShortcuts.all.count)
        XCTAssertTrue(LawShortcuts.shortcuts(in: .notebook).allSatisfy { $0.context == .notebook })
    }

    func testNothingReservedIsUsed() {
        let reserved = Set(LawShortcuts.reserved.map(\.combo))
        for row in LawShortcuts.all {
            guard let combo = row.combo else { continue }
            XCTAssertFalse(reserved.contains(combo), "\(row.id) belegt \(combo)")
        }
        // The list itself, as the plan names it.
        let named: [LawShortcuts.Combo] = [
            .init("h", [.command]), .init(.space, [.command]), .init(.tab, [.command]),
            .init("3", [.command, .shift]), .init("4", [.command, .shift]), .init("5", [.command, .shift]),
            .init("d", [.command, .option]), .init("w", [.command]), .init(",", [.command]), .init("q", [.command]),
            .init("m", [.command]), .init("f", [.command, .control]), .init("`", [.command])]
        for combo in named { XCTAssertTrue(reserved.contains(combo), "\(combo) fehlt in der Sperrliste") }
    }

    /// The notebook keeps every shortcut it has; the focus takes over only
    /// those it says it displaces, and says so only where it really does.
    func testConflictsWithTheNotebookAreDeliberate() {
        let notebook = Dictionary(LawShortcuts.notebookShortcuts.map { ($0.combo, $0.title) }, uniquingKeysWith: { first, _ in first })
        for row in LawShortcuts.all {
            guard let combo = row.combo else { XCTAssertNil(row.displaces, row.id); continue }
            let taken = notebook[combo]
            switch row.context {
            case .notebook:
                XCTAssertNil(taken, "\(row.id) (\(combo)) trifft „\(taken ?? "")“ im Heft")
                XCTAssertNil(row.displaces, row.id)
            case .focus:
                if taken != nil { XCTAssertNotNil(row.displaces, "\(row.id) (\(combo)) verdrängt „\(taken ?? "")“ ohne Angabe") }
                else { XCTAssertNil(row.displaces, "\(row.id) (\(combo)) verdrängt nichts") }
            }
        }
        // The resolutions the plan asks for.
        let displaced = Set(LawShortcuts.all.filter { $0.displaces != nil }.compactMap(\.combo))
        for combo: LawShortcuts.Combo in [.init("g", [.command]), .init(.up, [.command]), .init(.down, [.command]),
                                          .init("f", [.command]), .init("z", [.command]), .init("z", [.command, .shift])] {
            XCTAssertTrue(displaced.contains(combo), "\(combo)")
        }
    }

    /// Keys that would otherwise type only exist with the focus, on the
    /// window's responder; the menu carries ⌘ combinations only.
    func testRoutes() {
        for row in LawShortcuts.all {
            guard let combo = row.combo else { XCTAssertEqual(row.route, .menu, row.id); continue }
            if !combo.usesCommand {
                XCTAssertEqual(row.context, .focus, row.id)
                XCTAssertEqual(row.route, .keyCommand, row.id)
            }
            if row.route == .menu { XCTAssertTrue(combo.usesCommand, row.id) }
        }
        // ⌘Z next to „Bearbeiten › Widerrufen“ of the system: never a menu entry.
        XCTAssertEqual(LawShortcuts.shortcut(for: .init("z", [.command]), in: .focus)?.route, .keyCommand)
        XCTAssertNil(LawShortcuts.shortcut(for: .init("z", [.command]), in: .notebook))
    }

    func testTableAsPlanned() {
        func action(_ combo: LawShortcuts.Combo, _ context: LawShortcuts.Context = .focus) -> LawShortcuts.Action? {
            LawShortcuts.shortcut(for: combo, in: context)?.action
        }
        XCTAssertEqual(action(.init("l", [.command, .shift]), .notebook), .toggleWindow)
        XCTAssertEqual(action(.init("l", [.command, .option]), .notebook), .parkWindow)
        XCTAssertEqual(action(.init("l", [.command]), .notebook), .lookup)
        XCTAssertEqual(action(.init(.escape)), .escape)
        XCTAssertEqual(action(.init("f", [.command])), .find)
        XCTAssertEqual(action(.init("g", [.command])), .hit(forward: true))
        XCTAssertEqual(action(.init("g", [.command, .shift])), .hit(forward: false))
        XCTAssertEqual(action(.init(.enter)), .hit(forward: true))
        XCTAssertEqual(action(.init(.enter, [.shift])), .hit(forward: false))
        XCTAssertEqual(action(.init(.left)), .section(-1))
        XCTAssertEqual(action(.init(.right)), .section(1))
        XCTAssertEqual(action(.init(.down)), .scrollLines(1))
        XCTAssertEqual(action(.init(.up, [.option])), .scrollScreens(-1))
        XCTAssertEqual(action(.init(.space)), .scrollScreens(1))
        XCTAssertEqual(action(.init(.space, [.shift])), .scrollScreens(-1))
        XCTAssertEqual(action(.init(.up, [.command])), .edge(end: false))
        XCTAssertEqual(action(.init(.down, [.command])), .edge(end: true))
        XCTAssertEqual(action(.init("+", [.command])), .font(1))
        XCTAssertEqual(action(.init("-", [.command])), .font(-1))
        XCTAssertEqual(action(.init("0", [.command])), .font(0))
        XCTAssertEqual(action(.init("d", [.command])), .bookmark)
        XCTAssertEqual(action(.init("t", [.command])), .chooseLaw)
        XCTAssertEqual(action(.init("t", [.command, .shift])), .contents)
        XCTAssertEqual(action(.init("b", [.command, .option])), .list)
        XCTAssertEqual(action(.init("p", [.command, .option])), .toggleView)
        XCTAssertEqual(action(.init("h", [.command, .shift])), .lastColor)
        XCTAssertEqual(action(.init(.delete)), .removeMark)
        XCTAssertEqual(action(.init("z", [.command])), .undoMark)
        XCTAssertEqual(action(.init("z", [.command, .shift])), .redoMark)
        for number in 1...5 {
            let row = LawShortcuts.shortcut(for: .init("\(number)"), in: .focus)
            XCTAssertEqual(row?.action, .color(number))
            XCTAssertEqual(row?.requiresSelection, true)
        }
        XCTAssertNil(LawShortcuts.shortcut(for: .init("6"), in: .focus))
        XCTAssertEqual(LawShortcuts.shortcut(id: "focus.remove")?.requiresSelection, true)
        XCTAssertEqual(LawShortcuts.colorNames.count, 5)
        // Docking only as menu entries (⌃⌘arrow is too close to the iPadOS window keys).
        let docking = LawShortcuts.all.filter { if case .dock = $0.action { return true }; return $0.action == .float }
        XCTAssertEqual(docking.count, 4)
        XCTAssertTrue(docking.allSatisfy { $0.combo == nil })
        XCTAssertFalse(LawShortcuts.all.contains { $0.combo?.modifiers == [.control, .command] })
    }

    func testLabelsAndOverview() {
        XCTAssertEqual(LawShortcuts.Combo("l", [.command, .shift]).label, "⇧⌘L")
        XCTAssertEqual(LawShortcuts.Combo("b", [.command, .option]).label, "⌥⌘B")
        XCTAssertEqual(LawShortcuts.Combo(.up, [.option]).label, "⌥↑")
        XCTAssertEqual(LawShortcuts.Combo(.space, [.shift]).label, "⇧Leertaste")
        let overview = LawShortcuts.overview()
        XCTAssertEqual(overview.first?.group, "Fenster")
        let rows = overview.flatMap(\.rows)
        XCTAssertEqual(rows.first { $0.title == "Nächster Treffer" }?.keys, "⌘G, ↩")
        XCTAssertEqual(rows.first { $0.title == "Bildschirmseite weiter" }?.keys, "⌥↓, Leertaste")
        XCTAssertFalse(rows.contains { $0.title == "Links andocken" })
        XCTAssertFalse(LawShortcuts.overview(in: .notebook).flatMap(\.rows).contains { $0.title == "Nächster Treffer" })
    }

    /// Helix `GESETZE`: Esc and `Space l` close, `P` parks, `m1`–`m5`/`mm` mark,
    /// `d`/`M` remove, `u`/`U` undo and redo the marks.
    func testHelixLawKeys() {
        func action(_ keys: String) -> HelixAction? { HelixKeymap.binding(keys, in: .law)?.action }
        XCTAssertEqual(action("<Esc>"), .cancelPanel)
        XCTAssertEqual(action("<Space> l"), .laws)
        XCTAssertEqual(HelixKeymap.binding("<Space> l", in: .law)?.title, "Gesetzessammlung schließen")
        XCTAssertEqual(HelixKeymap.binding("<Space> l", in: .page)?.title, "Gesetzessammlung")
        XCTAssertEqual(action("P"), .lawPark)
        XCTAssertEqual(HelixKeymap.binding("m", in: .law)?.target, .menu)
        for number in 1...5 { XCTAssertEqual(action("m \(number)"), .lawColor(number)) }
        XCTAssertEqual(action("m m"), .lawMark(true))
        XCTAssertEqual(action("d"), .lawMark(false))
        XCTAssertEqual(action("M"), .lawMark(false))
        XCTAssertEqual(action("u"), .undo)
        XCTAssertEqual(action("U"), .redo)
        // The text's `m` menu and the page's `d` stay theirs.
        XCTAssertEqual(HelixKeymap.binding("m m", in: .text)?.action, .text(.matchBracket))
        XCTAssertEqual(HelixKeymap.binding("d", in: .page)?.action, .deleteObject)
        let menu = HelixKeymap.menu("m", in: .law)
        XCTAssertEqual(menu?.entries.map(\.key).sorted(), ["1", "2", "3", "4", "5", "m"])

        var parser = HelixParser()
        XCTAssertEqual(parser.feed("m", context: .law), .pending(menu: menu))
        XCTAssertEqual(parser.feed("3", context: .law), .action(.lawColor(3), count: nil, repeats: false))
        // A count still names a paragraph.
        _ = parser.feed("1", context: .law); _ = parser.feed("4", context: .law)
        XCTAssertEqual(parser.feed("4", context: .law), .pending(menu: nil))
        XCTAssertEqual(parser.feed("G", context: .law), .action(.gotoPage, count: 144, repeats: false))
    }

    /// No key of `GESETZE` means two things.
    func testHelixLawRowsAreUnique() {
        let keys = HelixKeymap.rows(in: .law).map(\.keys)
        let doubled = Dictionary(grouping: keys, by: { $0 }).filter { $0.value.count > 1 }.keys
        XCTAssertEqual(Array(doubled), [])
    }
}
