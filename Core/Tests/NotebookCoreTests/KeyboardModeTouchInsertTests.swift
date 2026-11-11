import XCTest
import NotebookCore

/// The engine half of `KeyboardRouter.setMode(.insert)`: a tap in the text
/// and the hardware keyboard going away both leave NOR and SEL this way, so
/// that the on-screen keyboard writes.
final class KeyboardModeTouchInsertTests: XCTestCase {
    private func leaveByTouch(_ engine: inout TextEngine) {
        engine.sync(text: engine.string, selection: engine.selectedRange, mode: .insert)
    }

    func testNormalModeWithASelectionBecomesInsertModeAtTheShownSelection() {
        var engine = TextEngine(text: "eins\nzwei\ndrei", caret: 6)
        engine.perform(.extendLine)
        XCTAssertEqual(engine.mode, .normal)
        let shown = engine.selectedRange
        XCTAssertEqual(shown, NSRange(location: 5, length: 5))

        leaveByTouch(&engine)

        XCTAssertEqual(engine.mode, .insert)
        XCTAssertEqual(engine.string, "eins\nzwei\ndrei")
        XCTAssertEqual(engine.selectedRange, shown)
    }

    func testSelectModeAndSeveralSelectionsBecomeOneInsertSelection() {
        var engine = TextEngine(text: "eins\nzwei\ndrei", caret: 1)
        engine.perform(.copyToNextLine)
        engine.perform(.toggleSelect)
        XCTAssertEqual(engine.mode, .select)
        XCTAssertEqual(engine.selections.count, 2)
        let primary = engine.selectedRange

        leaveByTouch(&engine)

        XCTAssertEqual(engine.mode, .insert)
        XCTAssertEqual(engine.selections.count, 1)
        XCTAssertEqual(engine.selectedRange, primary)
    }

    /// What the on-screen keyboard types afterwards arrives as native typing;
    /// a later Esc (keyboard back) only switches to NOR.
    func testNativeTypingAfterwardsIsKeptAndEscOnlyChangesTheMode() {
        var engine = TextEngine(text: "\teins", caret: 2)
        engine.perform(.insert(.lineBelow))
        engine.perform(.escape)
        XCTAssertEqual(engine.string, "\teins\n")
        leaveByTouch(&engine)

        engine.sync(text: "\teins\nab", selection: NSRange(location: 8, length: 0))
        XCTAssertEqual(engine.mode, .insert)
        let outcome = engine.perform(.escape)

        XCTAssertTrue(outcome.edits.isEmpty)
        XCTAssertEqual(engine.string, "\teins\nab")
        XCTAssertEqual(engine.mode, .normal)
    }
}
