import XCTest
@testable import NotebookCore

/// A launch caused by a file, a notification or the widget must not end under
/// the automatically reopened last notebook.
final class LaunchReopenGateTests: XCTestCase {
    func testNormalLaunchReopensOnceTheSceneIsActive() {
        let gate = LaunchReopenGate()
        XCTAssertEqual(gate.decision(sceneActive: false), .wait)
        XCTAssertEqual(gate.decision(sceneActive: true), .reopen)
    }
    func testExplicitReasonSkipsTheReopenBeforeAndAfterActivation() {
        var gate = LaunchReopenGate()
        gate.noteExplicitReason()
        XCTAssertEqual(gate.decision(sceneActive: false), .skip)
        XCTAssertEqual(gate.decision(sceneActive: true), .skip)
    }
    func testReasonArrivingWhileWaitingForTheSceneWins() {
        var gate = LaunchReopenGate()
        XCTAssertEqual(gate.decision(sceneActive: false), .wait)
        gate.noteExplicitReason()
        XCTAssertEqual(gate.decision(sceneActive: true), .skip)
    }
    func testReasonArrivingAfterTheDecisionStillShowsAtTheLastCheck() {
        var gate = LaunchReopenGate()
        XCTAssertEqual(gate.decision(sceneActive: true), .reopen)
        XCTAssertFalse(gate.explicitReason)
        gate.noteExplicitReason()
        gate.noteExplicitReason()
        XCTAssertTrue(gate.explicitReason)
        XCTAssertEqual(gate.decision(sceneActive: true), .skip)
    }
}
