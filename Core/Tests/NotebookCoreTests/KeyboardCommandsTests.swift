import Foundation
import XCTest
@testable import NotebookCore

final class KeyboardCommandsTests: XCTestCase {
    private let keyG = 10, keyJ = 13, keyShift = 225

    func testGateLetsEveryNewPressOfOneKeyThrough() {
        var gate = KeyPressGate()
        XCTAssertTrue(gate.began(key: keyJ, time: 1.0))
        XCTAssertFalse(gate.ended(key: keyJ))
        XCTAssertTrue(gate.began(key: keyJ, time: 1.2))
        // Without a key-up in between, too (the focus moved while the key was down).
        XCTAssertTrue(gate.began(key: keyJ, time: 1.4))
    }

    func testGateRefusesOnlyTheSecondDeliveryOfOneEvent() {
        var gate = KeyPressGate()
        XCTAssertTrue(gate.began(key: keyJ, time: 1.0))
        XCTAssertFalse(gate.began(key: keyJ, time: 1.0))
        XCTAssertFalse(gate.began(key: keyJ, time: 1.0))
        // ⇧ and a letter in one event: both new, both only once.
        XCTAssertTrue(gate.began(key: keyShift, time: 2.0))
        XCTAssertTrue(gate.began(key: keyG, time: 2.0))
        XCTAssertFalse(gate.began(key: keyShift, time: 2.0))
        XCTAssertFalse(gate.began(key: keyG, time: 2.0))
    }

    func testGateSurvivesAStalePressTime() {
        var gate = KeyPressGate()
        XCTAssertTrue(gate.began(key: keyG, time: 1.0))
        _ = gate.ended(key: keyG)
        XCTAssertTrue(gate.began(key: keyG, time: 1.0))
    }

    func testGateRemembersSwallowedPressesUntilTheirKeyUp() {
        var gate = KeyPressGate()
        _ = gate.began(key: keyJ, time: 1.0)
        gate.swallow(key: keyJ)
        XCTAssertTrue(gate.ended(key: keyJ))
        XCTAssertFalse(gate.ended(key: keyJ))
        // The key-up was lost: the next, unused press is not taken for a swallowed one.
        _ = gate.began(key: keyJ, time: 2.0)
        gate.swallow(key: keyJ)
        _ = gate.began(key: keyJ, time: 3.0)
        XCTAssertFalse(gate.ended(key: keyJ))
    }

    func testRepeatedKeysCompleteSequencesThroughTheGate() {
        var gate = KeyPressGate(), parser = HelixParser()
        func press(_ token: String, key: Int, time: Double) -> HelixParseResult? {
            defer { _ = gate.ended(key: key) }
            guard gate.began(key: key, time: time) else { return nil }
            return parser.feed(token, context: .library)
        }
        guard case .pending(let menu)? = press("g", key: keyG, time: 1.0) else { return XCTFail("g opens a menu") }
        XCTAssertEqual(menu?.title, "Gehe zu")
        guard case .action(.focusFirstItem, _, _)? = press("g", key: keyG, time: 1.1) else { return XCTFail("gg") }
        XCTAssertTrue(parser.isIdle)
    }

    func testLines() {
        let text = "eins\nzwei\r\n\ndrei" as NSString
        XCTAssertEqual(TextLines.start(text, 7), 5)
        XCTAssertEqual(TextLines.end(text, 7), 9)
        XCTAssertEqual(TextLines.start(text, 11), 11, "an empty line is its own line")
        XCTAssertEqual(TextLines.end(text, 11), 11)
        XCTAssertEqual(TextLines.end(text, 99), text.length)
        XCTAssertTrue(TextLines.isBreak(0x2028))
        XCTAssertFalse(TextLines.isBreak(32))
    }

    /// What the app reads to choose between wide caret and native selection.
    func testPrimaryWidthIsItsOwn() {
        var engine = TextEngine(text: "ab cd\nef")
        XCTAssertFalse(engine.primaryIsWide)
        engine.perform(.word(.nextStart, long: false))
        XCTAssertTrue(engine.primaryIsWide)
        engine.perform(.collapse)
        XCTAssertFalse(engine.primaryIsWide)
        engine.perform(.selectAll)
        engine.selectMatches("a|cd")
        XCTAssertEqual(engine.selections.count, 2)
        XCTAssertEqual(engine.selectedRange, NSRange(location: 0, length: 1))
        XCTAssertFalse(engine.primaryIsWide, "the primary selection counts, not the second one")
        XCTAssertTrue(engine.hasWideSelection)
    }

    /// A caret on the primary cursor is how the app shows NOR: several
    /// selections stay until the view really reports something else.
    func testTheShownCursorKeepsAllSelections() {
        var engine = TextEngine(text: "ab cd\nef")
        engine.perform(.selectAll)
        engine.selectMatches("a|cd")
        engine.sync(text: "ab cd\nef", selection: NSRange(location: 0, length: 0))
        XCTAssertEqual(engine.selections.count, 2)
        engine.sync(text: "ab cd\nef", selection: NSRange(location: 4, length: 0))
        XCTAssertEqual(engine.selections.count, 1)
    }

    func testPalette() {
        XCTAssertEqual(KeyPalette.direct(" w "), .save)
        XCTAssertEqual(KeyPalette.direct("q"), .close)
        XCTAssertEqual(KeyPalette.direct("wq"), .close)
        XCTAssertEqual(KeyPalette.direct("12"), .page(12))
        XCTAssertNil(KeyPalette.direct("0"))
        XCTAssertNil(KeyPalette.direct("pdf"))
        XCTAssertNotNil(KeyPalette.score("pdf", in: "Als PDF exportieren"))
        XCTAssertNil(KeyPalette.score("xyz", in: "Als PDF exportieren"))
        XCTAssertLessThan(KeyPalette.score("st", in: "Stift")!, KeyPalette.score("st", in: "Lasso starten")!)
        XCTAssertEqual(KeyPalette.score("", in: "Alles"), 0)
    }
}
