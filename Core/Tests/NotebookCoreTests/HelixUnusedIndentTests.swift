import XCTest
import NotebookCore

/// Esc takes the indent of a new line back only for the insert run that
/// opened that line. The range must never outlive that Esc: the engine is one
/// shared value for every text of the app.
final class HelixUnusedIndentTests: XCTestCase {
    func testEscTakesTheIndentOfAnUnusedNewLineBack() {
        var engine = TextEngine(text: "\tfoo", caret: 1)
        engine.perform(.insert(.lineBelow))
        XCTAssertEqual(engine.string, "\tfoo\n\t")
        let outcome = engine.perform(.escape)
        XCTAssertEqual(engine.string, "\tfoo\n")
        XCTAssertEqual(outcome.edits.count, 1)
        XCTAssertEqual(engine.mode, .normal)
    }

    /// Insert mode that began with a tap (`sync(mode: .insert)`) has no insert
    /// run: Esc only switches to NOR.
    func testEscAfterTapInsertDoesNotDeleteAtAnOldIndentRange() {
        var engine = TextEngine(text: "\tfoo", caret: 1)
        engine.perform(.insert(.lineBelow))
        engine.perform(.escape)
        XCTAssertEqual(engine.string, "\tfoo\n")

        engine.sync(text: "\tfoo\nHallo", selection: NSRange(location: 10, length: 0), mode: .insert)
        let outcome = engine.perform(.escape)

        XCTAssertTrue(outcome.edits.isEmpty)
        XCTAssertNil(outcome.combinedEdit)
        XCTAssertEqual(engine.string, "\tfoo\nHallo")
        XCTAssertEqual(engine.mode, .normal)
    }

    func testOldIndentRangeDoesNotReachAnotherText() {
        var engine = TextEngine(text: "\tfoo", caret: 1)
        engine.perform(.insert(.lineBelow))
        engine.perform(.escape)
        engine.textEnded()
        engine.sync(text: "", selection: NSRange(location: 0, length: 0), mode: .insert)
        engine.sync(text: "Bilanz 2026", selection: NSRange(location: 11, length: 0), mode: .insert)
        let outcome = engine.perform(.escape)
        XCTAssertTrue(outcome.edits.isEmpty)
        XCTAssertEqual(engine.string, "Bilanz 2026")
    }

    /// The text is shorter than the old range: this used to end the process.
    func testEscInAShorterTextAfterAnIndentTakeBack() {
        var engine = TextEngine(text: "\tfoo", caret: 1)
        engine.perform(.insert(.lineBelow))
        engine.perform(.escape)
        engine.sync(text: "ab", selection: NSRange(location: 2, length: 0), mode: .insert)
        let outcome = engine.perform(.escape)
        XCTAssertTrue(outcome.edits.isEmpty)
        XCTAssertEqual(engine.string, "ab")
        XCTAssertEqual(engine.mode, .normal)
    }

    /// Every Esc decides anew: a second insert run that wrote on its line
    /// keeps the text, whatever the run before it left.
    func testASecondInsertRunThatWroteKeepsItsLine() {
        var engine = TextEngine(text: "\tfoo", caret: 1)
        engine.perform(.insert(.lineBelow))
        engine.perform(.escape)
        XCTAssertEqual(engine.string, "\tfoo\n")

        engine.perform(.insert(.lineBelow))
        let opened = engine.string
        engine.sync(text: opened + "x", selection: NSRange(location: (opened as NSString).length + 1, length: 0))
        let outcome = engine.perform(.escape)
        XCTAssertTrue(outcome.edits.isEmpty)
        XCTAssertEqual(engine.string, opened + "x")
    }

    /// Esc in NOR after a take-back must not touch the text either.
    func testEscInNormalModeAfterATakeBackChangesNothing() {
        var engine = TextEngine(text: "\tfoo", caret: 1)
        engine.perform(.insert(.lineBelow))
        engine.perform(.escape)
        let outcome = engine.perform(.escape)
        XCTAssertTrue(outcome.edits.isEmpty)
        XCTAssertEqual(engine.string, "\tfoo\n")
    }
}
