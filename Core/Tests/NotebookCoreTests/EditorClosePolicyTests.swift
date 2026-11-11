import XCTest
@testable import NotebookCore

final class EditorClosePolicyTests: XCTestCase {
    private typealias State = EditorClosePolicy.SaveState

    func testSavedEditorOffersNothing() {
        XCTAssertNil(EditorClosePolicy.abandonReason(State(failed: false, reason: nil, retrying: false)))
        // A stale message of an earlier, meanwhile repeated attempt is no reason.
        XCTAssertNil(EditorClosePolicy.abandonReason(State(failed: false, reason: "Kein Speicherplatz", retrying: true)))
    }

    func testErrorWaitingForTheUserOffersClosingWithItsReason() {
        XCTAssertEqual(EditorClosePolicy.abandonReason(State(failed: true, reason: "Bildoriginal fehlt.", retrying: false)), "Bildoriginal fehlt.")
    }

    /// Disk full and other errors the automatic retry keeps trying: leaving
    /// must be possible as well, and the message says that noty keeps trying.
    func testErrorStillRetriedOffersClosingToo() throws {
        let reason = try XCTUnwrap(EditorClosePolicy.abandonReason(State(failed: true, reason: "Kein Speicherplatz", retrying: true)))
        XCTAssertTrue(reason.hasPrefix("Kein Speicherplatz"))
        XCTAssertTrue(reason.hasSuffix(EditorClosePolicy.retryNote))
    }

    func testFailureWithoutMessageStillOffersClosing() {
        XCTAssertEqual(EditorClosePolicy.abandonReason(State(failed: true, reason: nil, retrying: false)), EditorClosePolicy.unknownReason)
        XCTAssertEqual(EditorClosePolicy.abandonReason(State(failed: true, reason: "", retrying: false)), EditorClosePolicy.unknownReason)
    }

    func testWorkspaceWithoutFailureOffersNothing() {
        XCTAssertNil(EditorClosePolicy.abandonOffer([]))
        XCTAssertNil(EditorClosePolicy.abandonOffer([State(failed: false, reason: nil, retrying: false), State(failed: false, reason: "alt", retrying: true)]))
    }

    /// One view waits for the user, the other is still retried: one
    /// confirmation gives up both, so the workspace really closes afterwards
    /// instead of keeping a view that is no longer writable.
    func testMixedFailuresAreGivenUpTogether() throws {
        let panes = [State(failed: true, reason: "Kein Speicherplatz", retrying: true),
                     State(failed: false, reason: nil, retrying: false),
                     State(failed: true, reason: "Bildoriginal fehlt.", retrying: false)]
        let offer = try XCTUnwrap(EditorClosePolicy.abandonOffer(panes))
        XCTAssertEqual(offer.panes, [0, 2])
        XCTAssertEqual(offer.reason, "Bildoriginal fehlt.")
    }

    func testOnlyRetriedFailureIsOfferedForTheWorkspace() throws {
        let offer = try XCTUnwrap(EditorClosePolicy.abandonOffer([State(failed: false, reason: nil, retrying: false),
                                                                    State(failed: true, reason: "Kein Speicherplatz", retrying: true)]))
        XCTAssertEqual(offer.panes, [1])
        XCTAssertTrue(offer.reason.hasSuffix(EditorClosePolicy.retryNote))
    }
}
