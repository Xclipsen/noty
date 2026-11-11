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

    // MARK: Background launch (calendar refresh without a scene)

    /// The next process: only the three stored values survive.
    private func relaunched(_ state: LaunchGuardState) -> LaunchGuardState {
        LaunchGuardState(inProgress: state.inProgress, streak: state.streak, phase: state.phase)
    }

    func testBackgroundLaunchIsNotAnInterruptedStart() {
        var background = LaunchGuardState()
        XCTAssertEqual(background.begin().mode, .normal)
        XCTAssertTrue(background.backgroundLaunch())
        XCTAssertFalse(background.backgroundLaunch(), "set aside once")
        // The suspended process is ended; the user starts the app.
        var next = relaunched(background)
        XCTAssertEqual(next.begin(), .init(mode: .normal, interrupted: 0, phase: nil))
    }

    func testTwoBackgroundLaunchesNeverReachTheSafeMode() {
        var first = LaunchGuardState()
        _ = first.begin(); first.backgroundLaunch()
        var second = relaunched(first)
        XCTAssertEqual(second.begin().mode, .normal)
        second.backgroundLaunch()
        var third = relaunched(second)
        XCTAssertEqual(third.begin().mode, .normal)
        third.backgroundLaunch()
        var fourth = relaunched(third)
        XCTAssertEqual(fourth.begin(), .init(mode: .normal, interrupted: 0, phase: nil))
    }

    /// Without the background signal a second start cannot tell an ended
    /// background process from a crash before the first frame: that still counts.
    func testCrashBeforeTheFirstFrameStillCounts() {
        var crashed = LaunchGuardState()
        _ = crashed.begin()
        var next = relaunched(crashed)
        XCTAssertEqual(next.begin(), .init(mode: .skipRestore, interrupted: 1, phase: .starting))
    }

    func testBackgroundLaunchShownLaterCountsACrash() {
        var state = LaunchGuardState()
        _ = state.begin()
        state.backgroundLaunch()
        // Loaded in the background; nothing of it is stored while set aside.
        XCTAssertFalse(state.enter(.library))
        XCTAssertFalse(state.inProgress)
        XCTAssertNil(state.phase)
        // The user opens the app: the same process shows its scene.
        XCTAssertTrue(state.foreground())
        XCTAssertTrue(state.inProgress)
        XCTAssertEqual(state.phase, LaunchPhase.library.rawValue)
        XCTAssertFalse(state.foreground(), "armed once")
        state.enter(.editorOpen)
        // Crash before the run settled.
        var next = relaunched(state)
        XCTAssertEqual(next.begin(), .init(mode: .skipRestore, interrupted: 1, phase: .editorOpen))
    }

    func testBackgroundLaunchShownLaterAndSettledStaysNormal() {
        var state = LaunchGuardState()
        _ = state.begin()
        state.backgroundLaunch()
        state.foreground()
        state.finish()
        var next = relaunched(state)
        XCTAssertEqual(next.begin().mode, .normal)
    }

    /// A real crash, then a background launch the user never saw: the start
    /// after it still skips the restore, counted once, with the crash's phase.
    func testBackgroundLaunchKeepsTheVerdictAboutTheRunBefore() {
        var crashed = LaunchGuardState()
        _ = crashed.begin()
        crashed.enter(.library); crashed.enter(.editorOpen)
        var background = relaunched(crashed)
        XCTAssertEqual(background.begin().mode, .skipRestore)
        background.backgroundLaunch()
        // Neither a later phase nor a clean end of the unseen run changes it.
        background.enter(.library)
        background.finish()
        XCTAssertEqual(relaunched(background), relaunched(crashed))
        var next = relaunched(background)
        XCTAssertEqual(next.begin(), .init(mode: .skipRestore, interrupted: 1, phase: .editorOpen))
        // A second real crash right after: safe mode, as without the background launch.
        var again = relaunched(next)
        XCTAssertEqual(again.begin().mode, .safe)
    }

    /// The same process shown later continues the streak `begin()` counted.
    func testBackgroundLaunchAfterACrashShownLaterKeepsTheStreak() {
        var crashed = LaunchGuardState()
        _ = crashed.begin()
        var background = relaunched(crashed)
        XCTAssertEqual(background.begin().mode, .skipRestore)
        background.backgroundLaunch()
        XCTAssertTrue(background.foreground())
        XCTAssertEqual(background.streak, 1)
        var next = relaunched(background)
        XCTAssertEqual(next.begin().mode, .safe)
    }

    /// A scene connected in the background finishes the run first; the
    /// refresh then still sets it aside.
    func testBackgroundLaunchAfterACleanBackgroundSceneIsSetAsideToo() {
        var crashed = LaunchGuardState()
        _ = crashed.begin()
        var background = relaunched(crashed)
        _ = background.begin()
        background.finish()
        XCTAssertTrue(background.backgroundLaunch())
        var next = relaunched(background)
        XCTAssertEqual(next.begin().mode, .skipRestore)
    }

    /// A refresh in a process the user had opened changes nothing.
    func testRefreshAfterAForegroundStartChangesNothing() {
        var crashed = LaunchGuardState()
        _ = crashed.begin()
        var state = relaunched(crashed)
        XCTAssertEqual(state.begin().mode, .skipRestore)
        XCTAssertFalse(state.foreground())
        state.finish()
        let settled = state
        XCTAssertFalse(state.backgroundLaunch())
        XCTAssertEqual(state, settled)
        var next = relaunched(state)
        XCTAssertEqual(next.begin().mode, .normal)
    }

    func testNormalRestartClearsASetAsideRun() {
        var state = LaunchGuardState()
        _ = state.begin()
        state.backgroundLaunch()
        state.resetToNormal()
        XCTAssertFalse(state.setAside)
        XCTAssertFalse(state.backgroundLaunch())
        XCTAssertFalse(state.foreground())
        XCTAssertFalse(state.inProgress)
    }
}
