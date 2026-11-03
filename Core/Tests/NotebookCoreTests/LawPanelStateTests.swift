import XCTest
@testable import NotebookCore

final class LawPanelStateTests: XCTestCase {
    func testClosedOpensVisibleAndKeepsArrangement() {
        var state = LawPanelState(isOpen: false, isStashed: true, isDocked: true, edge: .left)
        XCTAssertEqual(state.phase, .closed)
        XCTAssertFalse(state.isStashed, "a closed window is never parked")
        XCTAssertTrue(state.open())
        XCTAssertEqual(state.phase, .visible)
        XCTAssertTrue(state.isDocked)
        XCTAssertEqual(state.edge, .left)
        XCTAssertFalse(state.open(), "opening a visible window changes nothing")
    }

    func testCloseFromEveryPhaseRemembersEdgeAndDocking() {
        for start in [LawPanelState(isOpen: true, isDocked: true, edge: .bottom),
                      LawPanelState(isOpen: true, isStashed: true, isDocked: true, edge: .bottom)] {
            var state = start
            XCTAssertTrue(state.close())
            XCTAssertEqual(state.phase, .closed)
            XCTAssertEqual(state.edge, .bottom)
            XCTAssertTrue(state.isDocked)
            // The next opening is visible again, never parked.
            state.open()
            XCTAssertEqual(state.phase, .visible)
        }
        var closed = LawPanelState()
        XCTAssertFalse(closed.close())
    }

    func testParkAndUnpark() {
        var state = LawPanelState(isOpen: true, edge: .right)
        XCTAssertTrue(state.park())
        XCTAssertEqual(state.phase, .parked)
        XCTAssertFalse(state.park())
        XCTAssertTrue(state.unpark())
        XCTAssertEqual(state.phase, .visible)
        XCTAssertFalse(state.unpark())
        // Dragged past the other edge: parked there.
        XCTAssertTrue(state.park(at: .left))
        XCTAssertEqual(state.edge, .left)
        XCTAssertTrue(state.park(at: .bottom), "moving a parked window's edge is a change")
        XCTAssertEqual(state.edge, .bottom)
        // Nothing to park or bring out while closed.
        var closed = LawPanelState(edge: .right)
        XCTAssertFalse(closed.park(at: .left))
        XCTAssertEqual(closed.phase, .closed)
        XCTAssertEqual(closed.edge, .right)
        XCTAssertFalse(closed.unpark())
        XCTAssertEqual(closed.phase, .closed)
    }

    func testToggleIsTheMenuSwitch() {
        var state = LawPanelState()
        state.toggle(); XCTAssertEqual(state.phase, .visible)
        state.toggle(); XCTAssertEqual(state.phase, .closed)
        state.open(); state.park()
        state.toggle(); XCTAssertEqual(state.phase, .visible, "a parked window is brought out, not closed")
    }

    func testTogglePark() {
        var state = LawPanelState()
        state.togglePark(); XCTAssertEqual(state.phase, .visible)
        state.togglePark(); XCTAssertEqual(state.phase, .parked)
        state.togglePark(); XCTAssertEqual(state.phase, .visible)
    }

    func testDockAndFloatShowTheWindow() {
        var state = LawPanelState(isOpen: true, isStashed: true, edge: .right)
        XCTAssertTrue(state.dock(.bottom))
        XCTAssertEqual(state, LawPanelState(isOpen: true, isDocked: true, edge: .bottom))
        XCTAssertFalse(state.dock(.bottom))
        XCTAssertTrue(state.float())
        XCTAssertEqual(state, LawPanelState(isOpen: true, isDocked: false, edge: .bottom))
        XCTAssertTrue(state.float(.left))
        XCTAssertEqual(state.edge, .left)
        var closed = LawPanelState()
        closed.dock(.left)
        XCTAssertEqual(closed.phase, .visible)
    }

    func testDropsMatchTheMenuActions() {
        var state = LawPanelState(isOpen: true, edge: .right)
        XCTAssertFalse(state.apply(.stay))
        state.apply(.dock(.left))
        XCTAssertEqual(state, LawPanelState(isOpen: true, isDocked: true, edge: .left))
        state.apply(.float(.bottom))
        XCTAssertEqual(state, LawPanelState(isOpen: true, isDocked: false, edge: .bottom))
        state.apply(.stash(.bottom))
        XCTAssertEqual(state.phase, .parked)
        XCTAssertFalse(state.isDocked)
    }
}

final class LawPanelKeyboardTests: XCTestCase {
    private let size = PageSize(width: 1180, height: 820)

    func testDockedBottomWindowStaysDockedAboveTheKeyboard() {
        // 820 − 400 would be too low to dock; the keyboard must not change that.
        let bottom = LawPanelLayout(size: size, width: 380, height: 360, docked: true, edge: .bottom, keyboard: 400)
        XCTAssertTrue(bottom.docked)
        XCTAssertEqual(bottom.frame, PageRect(x: 0, y: 60, width: 1180, height: 360))
        // The notebooks keep their place: the workspace ignores the keyboard.
        XCTAssertEqual(bottom.notebookFrame, PageRect(x: 0, y: 0, width: 1180, height: 454))
        XCTAssertEqual(bottom.hiddenShift, 760)
    }

    func testBottomWindowShrinksOnlyWhenItNoLongerFits() {
        let floating = LawPanelLayout(size: size, width: 380, height: 500, docked: false, edge: .bottom, keyboard: 450)
        XCTAssertEqual(floating.frame, PageRect(x: 10, y: 10, width: 1160, height: 350))
        let docked = LawPanelLayout(size: size, width: 380, height: 500, docked: true, edge: .bottom, keyboard: 450)
        XCTAssertEqual(docked.frame, PageRect(x: 0, y: 0, width: 1180, height: 370))
    }

    func testSideWindowsGetShorter() {
        let right = LawPanelLayout(size: size, width: 380, height: 360, docked: true, edge: .right, keyboard: 300)
        XCTAssertEqual(right.frame, PageRect(x: 800, y: 0, width: 380, height: 520))
        XCTAssertEqual(right.notebookFrame, PageRect(x: 0, y: 0, width: 794, height: 820))
        let left = LawPanelLayout(size: size, width: 380, height: 360, docked: false, edge: .left, keyboard: 300)
        XCTAssertEqual(left.frame, PageRect(x: 10, y: 10, width: 380, height: 500))
        XCTAssertEqual(left.hiddenShift, 390)
    }

    func testWithoutKeyboardNothingChanges() {
        for edge in LawPanelEdge.allCases {
            for docked in [true, false] {
                let plain = LawPanelLayout(size: size, width: 380, height: 360, docked: docked, edge: edge)
                let zero = LawPanelLayout(size: size, width: 380, height: 360, docked: docked, edge: edge, keyboard: 0)
                XCTAssertEqual(plain.frame, zero.frame)
                XCTAssertEqual(plain.hiddenShift, zero.hiddenShift)
            }
        }
        XCTAssertEqual(LawPanelLayout(size: size, width: 380, height: 360, docked: false, edge: .right, keyboard: -5).keyboard, 0)
        XCTAssertEqual(LawPanelLayout(size: size, width: 380, height: 360, docked: false, edge: .right, keyboard: 5000).freeHeight, 0)
    }
}
