import Foundation
import XCTest
@testable import NotebookCore

final class PageObjectHitTestTests: XCTestCase {
    private func content(texts: [TextBox] = [], images: [ImageObject] = [], shapes: [ShapeObject] = []) -> PageContent {
        var page = Page(); page.textBoxes = texts; page.images = images; page.shapes = shapes
        return PageContent(page: page)
    }

    func testTopmostFollowsDrawnLayersTextOverShapesOverImages() {
        let image = ImageObject.test(bytes: Data([1]), x: 0, y: 0, width: 200, height: 200)
        let shape = ShapeObject(kind: .rectangle, start: .init(x: 20, y: 20), end: .init(x: 180, y: 180),
                                fill: InkColor(0, 0, 0, 0.2))
        let text = TextBox(x: 50, y: 50, width: 100, height: 30)
        let all = content(texts: [text], images: [image], shapes: [shape])
        XCTAssertEqual(PageObjectHitTest.topmost(at: .init(x: 60, y: 60), in: all), .text(text.id))
        XCTAssertEqual(PageObjectHitTest.topmost(at: .init(x: 100, y: 150), in: all), .shape(shape.id))
        XCTAssertEqual(PageObjectHitTest.topmost(at: .init(x: 5, y: 5), in: all), .image(image.id))
        XCTAssertNil(PageObjectHitTest.topmost(at: .init(x: 300, y: 300), in: all))
    }

    /// Integration 22.10.2026: text fields count only on their text lines
    /// (Textneubau Stufe 1) and unfilled shapes only on their stroke (Formen
    /// Tag 2), so a tap on an empty field part inside an unfilled outline
    /// reaches the image below; a visible fill still takes the tap.
    func testEmptyFieldPartAndUnfilledShapeReachThrough() {
        let image = ImageObject.test(bytes: Data([4]), x: 0, y: 0, width: 300, height: 300)
        var outline = ShapeObject(kind: .rectangle, start: .init(x: 20, y: 20), end: .init(x: 280, y: 280), lineWidth: 2)
        let field = TextBox(x: 40, y: 40, width: 200, height: 200, text: "oben")
        let lines: (TextBox, PagePoint) -> Bool = { box, point in point.y >= box.y && point.y <= box.y + 20 }
        let inner = PagePoint(x: 120, y: 150)
        XCTAssertEqual(PageObjectHitTest.all(at: inner, in: content(texts: [field], images: [image], shapes: [outline]), textHit: lines),
                       [.image(image.id)])
        XCTAssertEqual(PageObjectHitTest.topmost(at: .init(x: 120, y: 50), in: content(texts: [field], images: [image], shapes: [outline]), textHit: lines),
                       .text(field.id))
        XCTAssertEqual(PageObjectHitTest.topmost(at: .init(x: 20, y: 150), in: content(texts: [field], images: [image], shapes: [outline]), textHit: lines),
                       .shape(outline.id), "the stroke still counts")
        outline.fill = InkColor(0, 0, 1, 0)
        XCTAssertEqual(PageObjectHitTest.topmost(at: inner, in: content(texts: [field], images: [image], shapes: [outline]), textHit: lines),
                       .image(image.id), "an invisible fill (0 %) is no fill")
        outline.fill = InkColor(0, 0, 1, 0.35)
        XCTAssertEqual(PageObjectHitTest.all(at: inner, in: content(texts: [field], images: [image], shapes: [outline]), textHit: lines),
                       [.shape(outline.id), .image(image.id)])
    }

    func testLaterEntryOfTheSameTypeWins() {
        let lower = TextBox(x: 0, y: 0, width: 100, height: 40), upper = TextBox(x: 50, y: 0, width: 100, height: 40)
        XCTAssertEqual(PageObjectHitTest.topmost(at: .init(x: 70, y: 20), in: content(texts: [lower, upper])), .text(upper.id))
    }

    func testPageTextAndLockedImagesAreNoObjects() {
        var flow = TextBox(x: 0, y: 0, width: 400, height: 400); flow.flowID = UUID(); flow.flowRegion = .page
        let locked = ImageObject.test(bytes: Data([2]), x: 0, y: 0, width: 400, height: 400, locked: true)
        XCTAssertNil(PageObjectHitTest.topmost(at: .init(x: 100, y: 100), in: content(texts: [flow], images: [locked])))
        let free = TextBox(x: 90, y: 90, width: 40, height: 20)
        XCTAssertEqual(PageObjectHitTest.topmost(at: .init(x: 100, y: 100), in: content(texts: [flow, free], images: [locked])), .text(free.id))
    }

    func testToleranceWidensTheTarget() {
        let text = TextBox(x: 100, y: 100, width: 50, height: 20)
        let page = content(texts: [text])
        XCTAssertNil(PageObjectHitTest.topmost(at: .init(x: 95, y: 110), in: page))
        XCTAssertEqual(PageObjectHitTest.topmost(at: .init(x: 95, y: 110), in: page, tolerance: 8), .text(text.id))
        XCTAssertNil(PageObjectHitTest.topmost(at: .init(x: 95, y: 110), in: page, tolerance: .nan))
    }

    func testRotatedImageUsesItsRotatedRectangle() {
        // 200 × 20 bar rotated by 90°: vertical around the centre (100, 10).
        let bar = ImageObject.test(bytes: Data([3]), x: 0, y: 0, width: 200, height: 20, rotation: 90)
        XCTAssertTrue(PageObjectHitTest.hits(bar, at: .init(x: 100, y: 90)))
        XCTAssertFalse(PageObjectHitTest.hits(bar, at: .init(x: 20, y: 10)), "the unrotated end is empty")
        var tilted = bar; tilted.rotation = 45
        XCTAssertTrue(PageObjectHitTest.hits(tilted, at: .init(x: 100 + 50, y: 10 + 50)))
        XCTAssertFalse(PageObjectHitTest.hits(tilted, at: .init(x: 100 + 50, y: 10 - 50)))
    }

    func testShapeOutlinesAndFill() {
        let line = ShapeObject(kind: .line, start: .init(x: 0, y: 0), end: .init(x: 100, y: 0), lineWidth: 4)
        XCTAssertTrue(PageObjectHitTest.hits(line, at: .init(x: 50, y: 1.5)))
        XCTAssertFalse(PageObjectHitTest.hits(line, at: .init(x: 50, y: 10)))
        XCTAssertTrue(PageObjectHitTest.hits(line, at: .init(x: 50, y: 10), tolerance: 9))
        let arrow = ShapeObject(kind: .arrow, start: .init(x: 0, y: 0), end: .init(x: 100, y: 0), lineWidth: 2)
        XCTAssertTrue(PageObjectHitTest.hits(arrow, at: .init(x: 95, y: 8)), "arrowhead")
        let open = ShapeObject(kind: .rectangle, start: .init(x: 0, y: 0), end: .init(x: 100, y: 60), lineWidth: 2)
        XCTAssertTrue(PageObjectHitTest.hits(open, at: .init(x: 100, y: 30)))
        XCTAssertFalse(PageObjectHitTest.hits(open, at: .init(x: 50, y: 30)), "an unfilled inside stays empty")
        var filled = open; filled.fill = InkColor(1, 0, 0, 0.2)
        XCTAssertTrue(PageObjectHitTest.hits(filled, at: .init(x: 50, y: 30)))
        let ellipse = ShapeObject(kind: .ellipse, start: .init(x: 0, y: 0), end: .init(x: 200, y: 100), lineWidth: 2)
        XCTAssertTrue(PageObjectHitTest.hits(ellipse, at: .init(x: 200, y: 50)))
        XCTAssertTrue(PageObjectHitTest.hits(ellipse, at: .init(x: 100, y: 0.5)))
        XCTAssertFalse(PageObjectHitTest.hits(ellipse, at: .init(x: 100, y: 50)))
        XCTAssertFalse(PageObjectHitTest.hits(ellipse, at: .init(x: 5, y: 5)), "corner of the frame is outside")
    }

    func testPolylineAndPolygonFollowTheirVertices() {
        // Knickpfeil: right, then down; the straight start-end chord is empty.
        let bent = ShapeObject(kind: .arrow, vertices: [.init(x: 0, y: 0), .init(x: 100, y: 0), .init(x: 100, y: 100)], lineWidth: 2)
        XCTAssertTrue(PageObjectHitTest.hits(bent, at: .init(x: 50, y: 0.5)))
        XCTAssertTrue(PageObjectHitTest.hits(bent, at: .init(x: 100.5, y: 60)))
        XCTAssertFalse(PageObjectHitTest.hits(bent, at: .init(x: 50, y: 50)), "chord from start to end is no stroke")
        XCTAssertTrue(PageObjectHitTest.hits(bent, at: .init(x: 95, y: 92)), "arrowhead on the last segment")
        let triangle = ShapeObject(kind: .polygon, vertices: [.init(x: 0, y: 0), .init(x: 100, y: 0), .init(x: 0, y: 100)], lineWidth: 2)
        XCTAssertTrue(PageObjectHitTest.hits(triangle, at: .init(x: 50, y: 50.5)), "slanted edge")
        XCTAssertTrue(PageObjectHitTest.hits(triangle, at: .init(x: 0.5, y: 50)), "closing edge back to the first vertex")
        XCTAssertFalse(PageObjectHitTest.hits(triangle, at: .init(x: 20, y: 20)), "an unfilled inside stays empty")
        XCTAssertFalse(PageObjectHitTest.hits(triangle, at: .init(x: 90, y: 90)), "outside, though inside the frame")
        var filled = triangle; filled.fill = InkColor(0, 0, 1, 0.2)
        XCTAssertTrue(PageObjectHitTest.hits(filled, at: .init(x: 20, y: 20)))
        XCTAssertFalse(PageObjectHitTest.hits(filled, at: .init(x: 90, y: 90)))
        XCTAssertEqual(PageObjectHitTest.topmost(at: .init(x: 20, y: 20), in: content(shapes: [filled])), .shape(filled.id))
    }

    func testAppOutlineOverridesTheApproximation() {
        let shape = ShapeObject(kind: .line, start: .init(x: 0, y: 0), end: .init(x: 100, y: 0))
        let page = content(shapes: [shape])
        XCTAssertNil(PageObjectHitTest.topmost(at: .init(x: 50, y: 0), in: page, shapeHit: { _, _ in false }))
        XCTAssertEqual(PageObjectHitTest.topmost(at: .init(x: 500, y: 500), in: page, shapeHit: { _, _ in true }), .shape(shape.id))
    }
}
