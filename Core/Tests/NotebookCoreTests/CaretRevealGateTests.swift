import XCTest
@testable import NotebookCore

final class CaretRevealGateTests: XCTestCase {
    private let page = UUID()
    private func point(_ width: Double = 1180, _ height: Double = 820) -> ViewportResumePoint {
        ViewportResumePoint(size: PageSize(width: width, height: height), zoom: 2.4, offset: PagePoint(x: 310, y: 1720), pageID: page)
    }

    func testSourcesFollowTheCaretRevealKind() {
        XCTAssertEqual(CaretRevealGate.Source(nil), .passive)
        XCTAssertEqual(CaretRevealGate.Source(.navigation), .navigation)
        XCTAssertEqual(CaretRevealGate.Source(.typing), .typing)
        XCTAssertEqual(CaretRevealGate.Source(.typewriter), .typing)
    }

    func testWithoutAnAppSwitchEverythingWorksAsBefore() {
        var gate = CaretRevealGate()
        for source in [CaretRevealGate.Source.passive, .navigation, .typing] {
            XCTAssertTrue(gate.admit(source, now: 5, lastUserInput: nil))
        }
        XCTAssertNil(gate.resume(size: point().size, pageID: page, now: 5, lastUserInput: nil))
    }

    func testNothingRevealsWhileInactive() {
        var gate = CaretRevealGate()
        gate.deactivate(at: 10, resume: point())
        // Committed marked text, keyboard hiding, snapshot resizes.
        for source in [CaretRevealGate.Source.passive, .navigation, .typing] {
            XCTAssertFalse(gate.admit(source, now: 10.2, lastUserInput: 10.1))
        }
        XCTAssertTrue(gate.holding)
    }

    func testKeyboardAndLayoutAfterTheReturnDoNotMoveTheView() {
        var gate = CaretRevealGate()
        gate.deactivate(at: 10, resume: point())
        gate.activate(at: 20)
        // The keyboard comes back, at once and long after: still no reveal.
        XCTAssertFalse(gate.admit(.passive, now: 20.1, lastUserInput: 9))
        XCTAssertFalse(gate.admit(.passive, now: 60, lastUserInput: 9))
        // A touch (e.g. on the toolbar) alone does not end the hold for passive events.
        XCTAssertFalse(gate.admit(.passive, now: 61, lastUserInput: 60.5))
        XCTAssertTrue(gate.holding)
    }

    func testSystemCaretEventsAtTheReturnAreIgnoredButTheUsersAreNot() {
        var gate = CaretRevealGate()
        gate.deactivate(at: 10, resume: point())
        gate.activate(at: 20)
        // UIKit restoring the responder or selection: no touch, no key since the return.
        XCTAssertFalse(gate.admit(.navigation, now: 20.3, lastUserInput: 9.8))
        XCTAssertTrue(gate.holding)
        // The user taps into the text (or presses an arrow key).
        XCTAssertTrue(gate.admit(.navigation, now: 20.6, lastUserInput: 20.5))
        XCTAssertFalse(gate.holding)
        // From now on the keyboard may make room for the caret again.
        XCTAssertTrue(gate.admit(.passive, now: 20.7, lastUserInput: 20.5))
    }

    func testCaretMovesWithoutATouchCountAfterTheSettleWindow() {
        // Space-bar trackpad on the software keyboard: no touch in the app's window.
        var gate = CaretRevealGate()
        gate.deactivate(at: 10, resume: point())
        gate.activate(at: 20)
        XCTAssertFalse(gate.admit(.navigation, now: 20 + CaretRevealGate.settleWindow - 0.01, lastUserInput: nil))
        XCTAssertTrue(gate.admit(.navigation, now: 20 + CaretRevealGate.settleWindow, lastUserInput: nil))
        XCTAssertFalse(gate.holding)
    }

    func testTypingAfterTheReturnRevealsAndEndsTheHold() {
        var gate = CaretRevealGate()
        gate.deactivate(at: 10, resume: point())
        gate.activate(at: 20)
        XCTAssertTrue(gate.admit(.typing, now: 20.2, lastUserInput: nil))
        XCTAssertFalse(gate.holding)
        XCTAssertTrue(gate.admit(.passive, now: 20.3, lastUserInput: nil))
    }

    func testTouchesBeforeTheSwitchDoNotCount() {
        var gate = CaretRevealGate()
        gate.deactivate(at: 10, resume: point())
        gate.activate(at: 20)
        XCTAssertFalse(gate.userActed(lastUserInput: 19.99))
        XCTAssertTrue(gate.userActed(lastUserInput: 20))
        XCTAssertFalse(gate.userActed(lastUserInput: nil))
    }

    func testResumePointOnlyForTheSameSizeAndPageBeforeTheUserActs() {
        var gate = CaretRevealGate()
        gate.deactivate(at: 10, resume: point())
        let size = point().size
        // Snapshot in the other orientation: not this size.
        XCTAssertNil(gate.resume(size: PageSize(width: 820, height: 1180), pageID: page, now: 11, lastUserInput: nil))
        // Back at the left size while still inactive, and right after the return.
        XCTAssertEqual(gate.resume(size: PageSize(width: 1180.2, height: 819.8), pageID: page, now: 11, lastUserInput: nil), point())
        gate.activate(at: 20)
        XCTAssertEqual(gate.resume(size: size, pageID: page, now: 20.5, lastUserInput: 9), point())
        // Another page (selected from elsewhere), a touch since the return, or the window ended.
        XCTAssertNil(gate.resume(size: size, pageID: UUID(), now: 20.5, lastUserInput: nil))
        XCTAssertNil(gate.resume(size: size, pageID: page, now: 20.5, lastUserInput: 20.4))
        XCTAssertNil(gate.resume(size: size, pageID: page, now: 20 + CaretRevealGate.settleWindow, lastUserInput: nil))
    }

    func testNoResumePointWhenNoneWasTaken() {
        var gate = CaretRevealGate()
        gate.deactivate(at: 10, resume: nil)
        XCTAssertNil(gate.resume(size: point().size, pageID: page, now: 11, lastUserInput: nil))
    }

    func testRepeatedDeactivationKeepsTheFirstState() {
        var gate = CaretRevealGate()
        gate.deactivate(at: 10, resume: point())
        gate.deactivate(at: 11, resume: point(820, 1180))
        XCTAssertEqual(gate.resumePoint, point())
        XCTAssertEqual(gate.deactivatedAt, 10)
        // Activation without a deactivation changes nothing.
        var fresh = CaretRevealGate()
        fresh.activate(at: 5)
        XCTAssertNil(fresh.returnedAt)
        XCTAssertTrue(fresh.admit(.passive, now: 5, lastUserInput: nil))
    }

    func testASecondSwitchHoldsAgain() {
        var gate = CaretRevealGate()
        gate.deactivate(at: 10, resume: point())
        gate.activate(at: 20)
        XCTAssertTrue(gate.admit(.typing, now: 21, lastUserInput: 21))
        gate.deactivate(at: 30, resume: point())
        gate.activate(at: 40)
        XCTAssertTrue(gate.holding)
        XCTAssertFalse(gate.admit(.passive, now: 40.2, lastUserInput: 21))
        XCTAssertFalse(gate.admit(.navigation, now: 40.2, lastUserInput: 21))
    }
}
