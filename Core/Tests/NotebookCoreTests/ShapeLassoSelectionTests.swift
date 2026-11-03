import Foundation
import XCTest
@testable import NotebookCore

/// Nutzer 22.10.2026: Auswahl innerhalb einer ungefüllten Form wählt die Form
/// nicht mit; nur ihr Strich zählt. Gefüllte Formen zählen mit ihrer Fläche.
final class ShapeLassoSelectionTests: XCTestCase {
    private func p(_ x: Double, _ y: Double) -> PagePoint { .init(x: x, y: y) }
    /// Rectangular lasso from (x0, y0) to (x1, y1).
    private func lasso(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double) -> LassoRegion {
        LassoRegion(points: [p(x0, y0), p(x1, y0), p(x1, y1), p(x0, y1)])
    }
    private var unfilled: [ShapeObject] {
        [ShapeObject(kind: .rectangle, start: p(100, 100), end: p(300, 300)),
         ShapeObject(kind: .ellipse, start: p(100, 100), end: p(300, 300)),
         ShapeObject(kind: .polygon, vertices: [p(100, 100), p(300, 100), p(300, 300), p(100, 300)]),
         // Closed polyline: a line through the four corners back to its start.
         ShapeObject(kind: .line, vertices: [p(100, 100), p(300, 100), p(300, 300), p(100, 300), p(100, 100)])]
    }

    func testLassoAroundInkInsideAnUnfilledShapeLeavesTheShape() {
        let inner = lasso(170, 170, 230, 230)
        for shape in unfilled { XCTAssertFalse(inner.selects(shape), "\(shape.kind)") }
        // The old rule (bounding box) would have selected every one of them.
        for shape in unfilled { XCTAssertTrue(inner.intersects(shape.bounds)) }
    }

    func testLassoAcrossOrAroundTheStrokeSelects() {
        let across = lasso(80, 180, 140, 220)   // crosses the left edge
        let around = lasso(50, 50, 350, 350)     // encloses the whole shape
        for shape in unfilled {
            XCTAssertTrue(across.selects(shape), "\(shape.kind)")
            XCTAssertTrue(around.selects(shape), "\(shape.kind)")
        }
    }

    func testHalfTheLineWidthCounts() {
        let thick = ShapeObject(kind: .rectangle, start: p(100, 100), end: p(300, 300), lineWidth: 10)
        XCTAssertTrue(lasso(104, 150, 140, 200).selects(thick), "lasso 4 pt from the centre line, the stroke reaches 5 pt")
        XCTAssertFalse(lasso(110, 150, 140, 200).selects(thick))
    }

    func testFilledShapesCountWithTheirArea() {
        let inner = lasso(170, 170, 230, 230)
        for var shape in unfilled where shape.isFillable {
            shape.fill = InkColor(0, 0.48, 1, 0.35)
            XCTAssertTrue(inner.selects(shape), "\(shape.kind)")
            shape.fill?.alpha = 0
            XCTAssertFalse(inner.selects(shape), "invisible fill: \(shape.kind)")
        }
        // A fill on a line is never drawn, so it does not count either.
        var line = unfilled[3]; line.fill = InkColor(0, 0, 0, 1)
        XCTAssertFalse(inner.selects(line))
    }

    func testFingerTapInsideAnUnfilledShapeReachesTheObjectBelow() {
        let image = ImageObject.test(bytes: Data([1]), x: 150, y: 150, width: 100, height: 100)
        for shape in unfilled {
            var page = Page(); page.images = [image]; page.shapes = [shape]
            let content = PageContent(page: page)
            XCTAssertEqual(PageObjectHitTest.topmost(at: p(200, 200), in: content, tolerance: 10), .image(image.id), "\(shape.kind)")
            XCTAssertEqual(PageObjectHitTest.topmost(at: p(100, 200), in: content, tolerance: 10), .shape(shape.id), "stroke: \(shape.kind)")
            guard shape.isFillable else { continue }
            var filled = shape; filled.fill = InkColor(1, 0, 0, 0.1)
            page.shapes = [filled]
            XCTAssertEqual(PageObjectHitTest.topmost(at: p(200, 200), in: PageContent(page: page), tolerance: 10), .shape(shape.id))
            filled.fill?.alpha = 0; page.shapes = [filled]
            XCTAssertEqual(PageObjectHitTest.topmost(at: p(200, 200), in: PageContent(page: page), tolerance: 10), .image(image.id))
        }
    }

    func testOpenLinesAndArrowsAreSelectedOnlyAlongTheirStroke() {
        let arrow = ShapeObject(kind: .arrow, start: p(100, 100), end: p(300, 100), lineWidth: 2)
        XCTAssertTrue(lasso(180, 90, 220, 110).selects(arrow))
        XCTAssertFalse(lasso(180, 104, 220, 109).selects(arrow), "beside the stroke, inside its padded bounds")
        XCTAssertTrue(lasso(285, 102, 292, 108).selects(arrow), "the head's wing")
    }
}
