import Foundation
import XCTest
@testable import NotebookCore

/// A held stroke that left the page/canvas is still straightened/recognised:
/// lines and arrows are clipped to the page, closed shapes moved onto it.
final class HeldShapeFittingTests: XCTestCase {
    private let page = PageRect(x: 0, y: 0, width: 595, height: 842)

    private func assertPoint(_ p: PagePoint, _ x: Double, _ y: Double, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(p.x, x, accuracy: 1e-9, file: file, line: line)
        XCTAssertEqual(p.y, y, accuracy: 1e-9, file: file, line: line)
    }

    func testShapeInsideThePageIsUnchanged() {
        let line = RecognizedShape.line(start: .init(x: 100, y: 100), end: .init(x: 400, y: 100))
        XCTAssertEqual(HeldShapeFitting.fit(line, in: page, padding: 4), line)
        let circle = RecognizedShape.ellipse(center: .init(x: 300, y: 400), radiusX: 50, radiusY: 50, degrees: 0)
        XCTAssertEqual(HeldShapeFitting.fit(circle, in: page, padding: 4), circle)
    }

    func testMarkerLineBeyondTheRightEdgeIsClippedToTheEdgeMinusItsHalfWidth() throws {
        let line = RecognizedShape.line(start: .init(x: 400, y: 200), end: .init(x: 700, y: 200))
        guard case let .line(start, end) = try XCTUnwrap(HeldShapeFitting.fit(line, in: page, padding: 10)) else { return XCTFail("line expected") }
        assertPoint(start, 400, 200)
        assertPoint(end, 585, 200)
    }

    func testDiagonalLineKeepsItsDirectionWhenClippedAtTwoEdges() throws {
        let line = RecognizedShape.line(start: .init(x: -100, y: -100), end: .init(x: 200, y: 200))
        guard case let .line(start, end) = try XCTUnwrap(HeldShapeFitting.fit(line, in: page, padding: 0)) else { return XCTFail("line expected") }
        assertPoint(start, 0, 0)
        assertPoint(end, 200, 200)
    }

    func testArrowKeepsItsStartAndEndsAtTheEdgeIncludingTheHeadReach() throws {
        let arrow = RecognizedShape.arrow(start: .init(x: 300, y: 500), tip: .init(x: 300, y: 900))
        guard case let .arrow(start, tip) = try XCTUnwrap(HeldShapeFitting.fit(arrow, in: page, padding: 12)) else { return XCTFail("arrow expected") }
        assertPoint(start, 300, 500)
        assertPoint(tip, 300, 830)
    }

    func testLineMostlyOffThePageKeepsTheFreehandStroke() {
        let line = RecognizedShape.line(start: .init(x: 590, y: 300), end: .init(x: 900, y: 300))
        XCTAssertNil(HeldShapeFitting.fit(line, in: page, padding: 2))
        XCTAssertNil(HeldShapeFitting.fit(.line(start: .init(x: 700, y: 10), end: .init(x: 900, y: 10)), in: page, padding: 2))
    }

    func testClosedShapeIsMovedOntoThePageWithoutResizing() throws {
        let rect = RecognizedShape.polygon(.rectangle, [.init(x: 550, y: 100), .init(x: 650, y: 100), .init(x: 650, y: 160), .init(x: 550, y: 160)])
        guard case let .polygon(kind, vertices) = try XCTUnwrap(HeldShapeFitting.fit(rect, in: page, padding: 1)) else { return XCTFail("polygon expected") }
        XCTAssertEqual(kind, .rectangle)
        assertPoint(vertices[0], 494, 100)
        assertPoint(vertices[2], 594, 160)
        // Still an editable axis-aligned rectangle for the pen.
        XCTAssertNotNil(RecognizedShape.polygon(kind, vertices).object(color: InkColor(0, 0, 0), lineWidth: 2))

        let circle = RecognizedShape.ellipse(center: .init(x: 20, y: 400), radiusX: 50, radiusY: 50, degrees: 0)
        guard case let .ellipse(center, rx, ry, _) = try XCTUnwrap(HeldShapeFitting.fit(circle, in: page, padding: 2)) else { return XCTFail("ellipse expected") }
        XCTAssertEqual(rx, 50); XCTAssertEqual(ry, 50)
        XCTAssertEqual(center.y, 400)
        XCTAssertGreaterThanOrEqual(center.x - 50, 2 - 1e-9)
    }

    func testClosedShapeIsNotMovedWhileResizingOrWhenLargerThanThePage() {
        let circle = RecognizedShape.ellipse(center: .init(x: 20, y: 400), radiusX: 50, radiusY: 50, degrees: 0)
        XCTAssertNil(HeldShapeFitting.fit(circle, in: page, padding: 2, allowShift: false))
        let huge = RecognizedShape.ellipse(center: .init(x: 300, y: 400), radiusX: 400, radiusY: 50, degrees: 0)
        XCTAssertNil(HeldShapeFitting.fit(huge, in: page, padding: 2))
    }

    func testWritingMarginsWithNegativeOriginAreRespected() throws {
        // PDF page with a left writing margin: canonical x starts at -200.
        let bounds = PageRect(x: -200, y: 0, width: 795, height: 842)
        let line = RecognizedShape.line(start: .init(x: 0, y: 50), end: .init(x: -400, y: 50))
        guard case let .line(_, end) = try XCTUnwrap(HeldShapeFitting.fit(line, in: bounds, padding: 3)) else { return XCTFail("line expected") }
        assertPoint(end, -197, 50)
    }

    func testFittedObjectPassesTheModelBoundsCheck() throws {
        // The pen commits rectangles/arrows as objects; the notebook validates
        // their bounds (including the arrow head) against the page.
        let arrow = RecognizedShape.arrow(start: .init(x: 100, y: 100), tip: .init(x: 100, y: 1000))
        let width = 3.0
        let padding = try XCTUnwrap(arrow.object(color: InkColor(0, 0, 0), lineWidth: width)).padding + 0.05
        let fitted = try XCTUnwrap(HeldShapeFitting.fit(arrow, in: page, padding: padding))
        let object = try XCTUnwrap(fitted.object(color: InkColor(0, 0, 0), lineWidth: width))
        XCTAssertNoThrow(try object.validate())
        XCTAssertTrue(page.contains(object.bounds, tolerance: 0.02))
    }

    func testClipRejectsSegmentsOutsideAndHandlesAxisParallelOnes() {
        XCTAssertNil(HeldShapeFitting.clip(.init(x: -10, y: 5), .init(x: -1, y: 50), to: page))
        let vertical = HeldShapeFitting.clip(.init(x: 10, y: -50), .init(x: 10, y: 50), to: page)
        XCTAssertEqual(vertical?.0, PagePoint(x: 10, y: 0))
        XCTAssertEqual(vertical?.1, PagePoint(x: 10, y: 50))
    }
}
