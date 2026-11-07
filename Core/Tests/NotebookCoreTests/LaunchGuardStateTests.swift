import XCTest
@testable import NotebookCore

final class LaunchGuardStateTests: XCTestCase {
    func testFinishedLaunchStaysNormal() {
        var state = LaunchGuardState()
        XCTAssertEqual(state.begin().mode, .normal)
        state.enter(.library)
        state.finish()
        let next = state.begin()
        XCTAssertEqual(next, .init(mode: .normal, interrupted: 0, phase: nil))
        XCTAssertNil(LaunchGuardState.notice(for: next))
    }

    func testOneInterruptedLaunchSkipsRestoreAndNamesPhase() {
        var state = LaunchGuardState()
        _ = state.begin()
        state.enter(.library)
        state.enter(.editorOpen)
        // Crash: no finish.
        let next = state.begin()
        XCTAssertEqual(next, .init(mode: .skipRestore, interrupted: 1, phase: .editorOpen))
        let notice = LaunchGuardState.notice(for: next) ?? ""
        XCTAssertTrue(notice.contains("beim Öffnen des Hefts unterbrochen"))
        XCTAssertTrue(notice.contains("nicht automatisch geöffnet"))
        XCTAssertFalse(notice.contains("sicheren Modus"))
    }

    func testTwoInterruptedLaunchesRunSafe() {
        var state = LaunchGuardState()
        _ = state.begin()
        _ = state.begin()
        let third = state.begin()
        XCTAssertEqual(third.mode, .safe)
        XCTAssertEqual(third.interrupted, 2)
        XCTAssertEqual(third.phase, .starting)
        XCTAssertTrue(LaunchGuardState.notice(for: third)?.contains("sicheren Modus") == true)
        XCTAssertEqual(state.begin().mode, .safe)
    }

    func testRecoveredLaunchResetsOnTheNextLaunch() {
        var state = LaunchGuardState()
        _ = state.begin()
        XCTAssertEqual(state.begin().mode, .skipRestore)
        state.finish()
        XCTAssertEqual(state.begin().mode, .normal)
        XCTAssertEqual(state.streak, 0)
    }

    func testOpeningANotebookLaterRearmsAndCountsOnTheStreak() {
        var state = LaunchGuardState()
        _ = state.begin()
        XCTAssertEqual(state.begin().mode, .skipRestore)
        state.finish()
        XCTAssertFalse(state.enter(.library), "the library never re-arms")
        XCTAssertFalse(state.inProgress)
        XCTAssertTrue(state.enter(.editorOpen))
        XCTAssertFalse(state.enter(.lawWindow), "already armed")
        // Crash in the notebook the user opened by hand.
        let next = state.begin()
        XCTAssertEqual(next, .init(mode: .safe, interrupted: 2, phase: .lawWindow))
    }

    func testResetToNormal() {
        var state = LaunchGuardState()
        _ = state.begin(); _ = state.begin(); _ = state.begin()
        state.resetToNormal()
        XCTAssertEqual(state.begin().mode, .normal)
    }

    func testUnknownPhaseIsIgnored() {
        var state = LaunchGuardState(inProgress: true, streak: 0, phase: "future-phase")
        XCTAssertEqual(state.begin(), .init(mode: .skipRestore, interrupted: 1, phase: nil))
        XCTAssertEqual(LaunchGuardState.notice(for: .init(mode: .skipRestore, interrupted: 1, phase: nil)),
                       "Der letzte Start wurde unterbrochen. Das zuletzt geöffnete Heft wurde nicht automatisch geöffnet.")
    }
}
