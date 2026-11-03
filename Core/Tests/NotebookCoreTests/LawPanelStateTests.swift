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

    func testDockedBottomWindowStaysDockedAndOnlyItsOwnFieldLiftsIt() {
        // 820 − 400 would be too low to dock; the keyboard must not change that.
        let typing = LawPanelLayout(size: size, width: 380, height: 360, docked: true, edge: .bottom, keyboard: 400, avoidsKeyboard: true)
        XCTAssertTrue(typing.docked)
        XCTAssertEqual(typing.frame, PageRect(x: 0, y: 60, width: 1180, height: 360))
        XCTAssertEqual(typing.hiddenShift, 760)
        // Typing in a notebook: the window keeps its place (behind the
        // keyboard) and never covers the notebook text being typed.
        let notebook = LawPanelLayout(size: size, width: 380, height: 360, docked: true, edge: .bottom, keyboard: 400)
        XCTAssertTrue(notebook.docked)
        XCTAssertEqual(notebook.frame, PageRect(x: 0, y: 460, width: 1180, height: 360))
        XCTAssertEqual(notebook.hiddenShift, 360)
        // The notebooks end at the keyboard (820 − 400) like before the law window.
        XCTAssertEqual(notebook.notebookFrame, PageRect(x: 0, y: 0, width: 1180, height: 420))
        XCTAssertEqual(notebook.notebookOverhang, 34)
        XCTAssertLessThanOrEqual(notebook.notebookFrame.height, notebook.freeHeight)
    }

    func testBottomWindowShrinksOnlyWhenItNoLongerFits() {
        let floating = LawPanelLayout(size: size, width: 380, height: 500, docked: false, edge: .bottom, keyboard: 450, avoidsKeyboard: true)
        XCTAssertEqual(floating.frame, PageRect(x: 10, y: 10, width: 1160, height: 350))
        let docked = LawPanelLayout(size: size, width: 380, height: 500, docked: true, edge: .bottom, keyboard: 450, avoidsKeyboard: true)
        XCTAssertEqual(docked.frame, PageRect(x: 0, y: 0, width: 1180, height: 370))
    }

    func testSideWindowsGetShorterOnlyWhileTheirFieldTypes() {
        let right = LawPanelLayout(size: size, width: 380, height: 360, docked: true, edge: .right, keyboard: 300, avoidsKeyboard: true)
        XCTAssertEqual(right.frame, PageRect(x: 800, y: 0, width: 380, height: 520))
        XCTAssertEqual(right.notebookFrame, PageRect(x: 0, y: 0, width: 794, height: 520))
        XCTAssertEqual(right.notebookOverhang, 300)
        let left = LawPanelLayout(size: size, width: 380, height: 360, docked: false, edge: .left, keyboard: 300, avoidsKeyboard: true)
        XCTAssertEqual(left.frame, PageRect(x: 10, y: 10, width: 380, height: 500))
        XCTAssertEqual(left.hiddenShift, 390)
        let still = LawPanelLayout(size: size, width: 380, height: 360, docked: true, edge: .right, keyboard: 300)
        XCTAssertEqual(still.frame, PageRect(x: 800, y: 0, width: 380, height: 820))
    }

    func testNotebooksGiveWayToTheKeyboardLikeBeforeTheLawWindow() {
        for edge in LawPanelEdge.allCases {
            for typing in [true, false] {
                // Not docked: the whole width, down to the keyboard; panes at the
                // bottom reach on under it by the keyboard height (as before).
                let floating = LawPanelLayout(size: size, width: 380, height: 360, docked: false, edge: edge, keyboard: 320, avoidsKeyboard: typing)
                XCTAssertEqual(floating.notebookFrame, PageRect(x: 0, y: 0, width: 1180, height: 500))
                XCTAssertEqual(floating.notebookOverhang, 320)
            }
        }
        // A short keyboard (hardware keyboard bar) under a window docked at the bottom: nothing to give way.
        let bar = LawPanelLayout(size: size, width: 380, height: 360, docked: true, edge: .bottom, keyboard: 55)
        XCTAssertEqual(bar.notebookFrame, PageRect(x: 0, y: 0, width: 1180, height: 454))
        XCTAssertEqual(bar.notebookOverhang, 0)
        XCTAssertEqual(bar.frame, PageRect(x: 0, y: 460, width: 1180, height: 360))
        // The window never lies over the notebook area while a notebook types.
        for edge in LawPanelEdge.allCases {
            for keyboard in [0.0, 55, 320, 400] {
                let l = LawPanelLayout(size: size, width: 380, height: 360, docked: true, edge: edge, keyboard: keyboard)
                let n = l.notebookFrame, f = l.frame
                let overlaps = n.x < f.x + f.width && f.x < n.x + n.width && n.y < f.y + f.height && f.y < n.y + n.height
                XCTAssertFalse(overlaps, "\(edge) \(keyboard)")
            }
        }
    }

    func testDropZonesAndResizeLimitFollowTheFreeHeight() {
        let docked = LawPanelLayout(size: size, width: 380, height: 360, docked: true, edge: .bottom, keyboard: 400)
        // Resting under the keyboard: a short drag does not park it.
        XCTAssertEqual(docked.drop(translation: PagePoint(x: 0, y: 50), location: PagePoint(x: 600, y: 300)), .float(.bottom))
        // The bottom zone is the keyboard's top edge, not the hidden screen edge.
        let floating = LawPanelLayout(size: size, width: 380, height: 360, docked: false, edge: .right, keyboard: 400)
        XCTAssertEqual(floating.drop(translation: PagePoint(x: -300, y: 200), location: PagePoint(x: 600, y: 380)), .dock(.bottom))
        let none = LawPanelLayout(size: size, width: 380, height: 360, docked: false, edge: .right)
        XCTAssertEqual(none.drop(translation: PagePoint(x: -300, y: 200), location: PagePoint(x: 600, y: 380)), .float(.right))
        // A lifted window pushed mostly below the keyboard's edge parks.
        let lifted = LawPanelLayout(size: size, width: 380, height: 360, docked: false, edge: .bottom, keyboard: 400, avoidsKeyboard: true)
        XCTAssertEqual(lifted.drop(translation: PagePoint(x: 0, y: 220), location: PagePoint(x: 600, y: 400)), .stash(.bottom))
        // Resize handle: above the keyboard, never below the minimum.
        XCTAssertEqual(LawPanelLayout(size: size, width: 380, height: 360, docked: false, edge: .bottom, keyboard: 400).heightLimit, 336)
        XCTAssertEqual(docked.heightLimit, LawPanelLayout.minimumHeight)
        XCTAssertEqual(none.heightLimit, 736)
        XCTAssertEqual(LawPanelLayout(size: size, width: 380, height: 360, docked: true, edge: .bottom).heightLimit, 520)
        XCTAssertEqual(none.widthLimit, 854)
    }

    func testWithoutKeyboardNothingChanges() {
        for edge in LawPanelEdge.allCases {
            for docked in [true, false] {
                let plain = LawPanelLayout(size: size, width: 380, height: 360, docked: docked, edge: edge)
                for typing in [true, false] {
                    let zero = LawPanelLayout(size: size, width: 380, height: 360, docked: docked, edge: edge, keyboard: 0, avoidsKeyboard: typing)
                    XCTAssertEqual(plain.frame, zero.frame)
                    XCTAssertEqual(plain.hiddenShift, zero.hiddenShift)
                    XCTAssertEqual(plain.notebookFrame, zero.notebookFrame)
                    XCTAssertEqual(zero.notebookOverhang, 0)
                }
            }
        }
        XCTAssertEqual(LawPanelLayout(size: size, width: 380, height: 360, docked: false, edge: .right, keyboard: -5).keyboard, 0)
        XCTAssertEqual(LawPanelLayout(size: size, width: 380, height: 360, docked: false, edge: .right, keyboard: 5000).freeHeight, 0)
    }
}
