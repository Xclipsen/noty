import Foundation
import XCTest
@testable import NotebookCore

/// Build-50 feedback: the precision eraser cuts a shape instead of removing it whole.
final class ShapeEraseMaskTests: XCTestCase {
    private let rectangle = ShapeObject(kind: .rectangle, start: .init(x: 100, y: 100), end: .init(x: 300, y: 200), lineWidth: 2)

    func testUntouchedShapeKeepsItsWholeClosedOutline() throws {
        let mask = ShapeEraseMask(rectangle)
        XCTAssertFalse(mask.isTouched)
        let runs = mask.runs
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs[0].first, runs[0].last, "closed")
        XCTAssertEqual(runs[0].first, PagePoint(x: 100, y: 100))
    }

    func testCuttingTheTopEdgeLeavesOneOpenPieceAroundTheRest() throws {
        var mask = ShapeEraseMask(rectangle)
        // Vertical swipe through the middle of the top edge, eraser 16 pt wide.
        XCTAssertTrue(mask.erase(from: .init(x: 200, y: 80), to: .init(x: 200, y: 120), radius: 8))
        XCTAssertTrue(mask.isTouched)
        let runs = mask.runs
        XCTAssertEqual(runs.count, 1, "the pieces meeting at the outline's start are joined")
        let piece = try XCTUnwrap(runs.first)
        // The gap is the eraser width plus the line width, centred on x = 200.
        XCTAssertEqual(try XCTUnwrap(piece.first).y, 100); XCTAssertEqual(try XCTUnwrap(piece.last).y, 100)
        XCTAssertEqual(try XCTUnwrap(piece.first).x, 210, accuracy: 1.01)
        XCTAssertEqual(try XCTUnwrap(piece.last).x, 190, accuracy: 1.01)
        XCTAssertFalse(piece.contains { $0.y == 100 && abs($0.x - 200) < 9 })
        // Erasing the same place again changes nothing.
        XCTAssertFalse(mask.erase(from: .init(x: 200, y: 80), to: .init(x: 200, y: 120), radius: 8))
    }

    func testTwoCutsSplitTheOutlineAndMissesLeaveItWhole() {
        var mask = ShapeEraseMask(rectangle)
        XCTAssertFalse(mask.erase(from: .init(x: 150, y: 140), to: .init(x: 250, y: 160), radius: 8), "inside, away from the line")
        XCTAssertFalse(mask.isTouched)
        mask.erase(from: .init(x: 80, y: 150), to: .init(x: 120, y: 150), radius: 5)
        mask.erase(from: .init(x: 280, y: 150), to: .init(x: 320, y: 150), radius: 5)
        XCTAssertEqual(mask.runs.count, 2)
    }

    func testErasingEverythingLeavesNoInkAndLinesStayOpen() {
        let line = ShapeObject(kind: .line, start: .init(x: 0, y: 0), end: .init(x: 100, y: 0), lineWidth: 4)
        var mask = ShapeEraseMask(line)
        XCTAssertEqual(mask.runs.count, 1)
        XCTAssertNotEqual(mask.runs[0].first, mask.runs[0].last)
        mask.erase(from: .init(x: 50, y: -20), to: .init(x: 50, y: 20), radius: 3)
        XCTAssertEqual(mask.runs.count, 2)
        mask.erase(from: .init(x: -10, y: 0), to: .init(x: 110, y: 0), radius: 3)
        XCTAssertTrue(mask.runs.isEmpty)
    }

    func testArrowHeadAndEllipseAreCutAlongTheirDrawnLines() {
        let arrow = ShapeObject(kind: .arrow, start: .init(x: 0, y: 0), end: .init(x: 200, y: 0), lineWidth: 2)
        var mask = ShapeEraseMask(arrow)
        XCTAssertEqual(mask.runs.count, 3, "shaft and two head strokes")
        mask.erase(from: .init(x: 100, y: -10), to: .init(x: 100, y: 10), radius: 4)
        XCTAssertEqual(mask.runs.count, 4)

        let ellipse = ShapeObject(kind: .ellipse, start: .init(x: 0, y: 0), end: .init(x: 200, y: 100), lineWidth: 2)
        var round = ShapeEraseMask(ellipse)
        // Rightmost point of the ellipse is (200, 50).
        XCTAssertTrue(round.erase(from: .init(x: 190, y: 50), to: .init(x: 210, y: 50), radius: 6))
        XCTAssertEqual(round.runs.count, 1)
        XCTAssertFalse(round.runs[0].contains { hypot($0.x - 200, $0.y - 50) < 6 })
    }

    func testOnlySolidUnfilledShapesAreCut() {
        XCTAssertTrue(ShapeEraseMask.canErasePartially(rectangle))
        var filled = rectangle; filled.fill = InkColor(1, 0, 0)
        XCTAssertFalse(ShapeEraseMask.canErasePartially(filled))
        var dashed = rectangle; dashed.pattern = .dashed
        XCTAssertFalse(ShapeEraseMask.canErasePartially(dashed))
    }

    func testEraserOverOnlyTheFillRemovesTheFillAndTheOutlineKeepsTheShape() {
        // Nutzer zu Build 62: the fill is a thing of its own for the erasers.
        func q(_ x: Double, _ y: Double) -> PagePoint { PagePoint(x: x, y: y) }
        var filled = ShapeObject(kind: .rectangle, start: q(100, 100), end: q(300, 200), lineWidth: 2)
        filled.fill = InkColor(0.2, 0.4, 0.9, 0.3)
        // Inside only (eraser radius 3 stays 10+ pt from the outline).
        XCTAssertEqual(filled.eraseTarget(from: q(150, 150), to: q(250, 150), radius: 3), .fill)
        XCTAssertNil(filled.removingFill.fill)
        XCTAssertEqual(filled.removingFill.kind, filled.kind)
        // Touching the outline (also coming from inside): the shape as before.
        XCTAssertEqual(filled.eraseTarget(from: q(150, 150), to: q(150, 205), radius: 3), .stroke)
        XCTAssertEqual(filled.eraseTarget(from: q(50, 101), to: q(80, 101), radius: 20), .stroke)
        // Outside: nothing.
        XCTAssertEqual(filled.eraseTarget(from: q(10, 10), to: q(50, 10), radius: 3), .none)
        // Unfilled shape swept inside: nothing; invisible fill counts as none.
        let empty = ShapeObject(kind: .ellipse, start: q(100, 100), end: q(300, 200), lineWidth: 2)
        XCTAssertEqual(empty.eraseTarget(from: q(180, 150), to: q(220, 150), radius: 3), .none)
        var clear = empty; clear.fill = InkColor(0, 0, 0, 0)
        XCTAssertEqual(clear.eraseTarget(from: q(180, 150), to: q(220, 150), radius: 3), .none)
        var ellipse = empty; ellipse.fill = InkColor(0, 0, 0, 0.5)
        XCTAssertEqual(ellipse.eraseTarget(from: q(180, 150), to: q(220, 150), radius: 3), .fill)
        XCTAssertEqual(ellipse.eraseTarget(from: q(200, 150), to: q(200, 230), radius: 3), .stroke)
        // A line has no inside.
        let line = ShapeObject(kind: .line, start: q(0, 0), end: q(100, 0), lineWidth: 4)
        XCTAssertEqual(line.eraseTarget(from: q(50, 30), to: q(50, 2.5), radius: 1), .stroke)
        XCTAssertEqual(line.eraseTarget(from: q(50, 30), to: q(50, 10), radius: 1), .none)
    }
}
