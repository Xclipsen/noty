import XCTest
@testable import NotebookCore

/// Fixes from the shapes/images/laser audit (Build 110): export crop,
/// shapes drawn at the page edge, width-independent scaling, unfilled lines,
/// named image limits and a thinned (not cut) laser trail.
final class ShapeImageLaserFixTests: XCTestCase {
    private let page = PageRect(x: 0, y: 0, width: 595, height: 842)

    // MARK: Export crop

    func testCropPixelsRoundInwardsAndNeverIncludeCutAwayPixels() {
        let full = ImageObject.cropPixels(.init(x: 0, y: 0, width: 1, height: 1), width: 4096, height: 3072)
        XCTAssertTrue(full == (0, 0, 4096, 3072))
        // Left half of a screenshot: exactly columns 0..<2048, nothing of the right half.
        let left = ImageObject.cropPixels(.init(x: 0, y: 0, width: 0.5, height: 1), width: 4096, height: 3072)
        XCTAssertTrue(left == (0, 0, 2048, 3072))
        // Edges between pixels round inwards: 0.3333 of 10 px starts at pixel 4, ends before 7.
        let inner = ImageObject.cropPixels(.init(x: 1.0 / 3, y: 0.25, width: 1.0 / 3, height: 0.5), width: 10, height: 10)
        XCTAssertTrue(inner == (4, 3, 2, 4), "\(inner)")
        // Floating-point noise does not drop a whole row.
        let noisy = ImageObject.cropPixels(.init(x: 0.1, y: 0.2, width: 0.7, height: 0.6), width: 1000, height: 1000)
        XCTAssertTrue(noisy == (100, 200, 700, 600), "\(noisy)")
        // A crop narrower than one rendition pixel still yields one pixel inside the image.
        let tiny = ImageObject.cropPixels(.init(x: 0.98, y: 0.98, width: 0.02, height: 0.02), width: 20, height: 20)
        XCTAssertEqual(tiny.width, 1); XCTAssertEqual(tiny.height, 1)
        XCTAssertLessThan(tiny.x, 20); XCTAssertLessThan(tiny.y, 20)
    }

    // MARK: Shapes drawn at the page edge

    func testArrowStartedNearTheEdgeIsKeptOnThePageInsteadOfDropped() throws {
        let raw = ShapeObject(kind: .arrow, start: .init(x: 5, y: 300), end: .init(x: 200, y: 300), lineWidth: 2)
        XCTAssertFalse(page.contains(raw.bounds, tolerance: 0.02), "the audit case: rejected before the fix")
        let fitted = DrawnShapeFitting.fitted(raw, in: page)
        XCTAssertNoThrow(try fitted.validate())
        XCTAssertTrue(page.contains(fitted.bounds, tolerance: 0.02))
        XCTAssertEqual(fitted.start, .init(x: 10, y: 300))
        XCTAssertEqual(fitted.end, raw.end, "the tip did not move")
    }

    func testLineDraggedOverTheEdgeEndsAtTheEdgeKeepingItsDirection() throws {
        let raw = ShapeObject(kind: .line, start: .init(x: 500, y: 400), end: .init(x: 700, y: 500), lineWidth: 4)
        let fitted = DrawnShapeFitting.fitted(raw, in: page)
        XCTAssertTrue(page.contains(fitted.bounds, tolerance: 0.02))
        XCTAssertEqual(fitted.start, raw.start)
        XCTAssertEqual(fitted.end.x, 593, accuracy: 1e-9)
        XCTAssertEqual((fitted.end.y - 400) / (fitted.end.x - 500), 0.5, accuracy: 1e-9, "same direction")
        XCTAssertNoThrow(try fitted.validate())
    }

    func testRectangleAndEllipseCornersStopAtTheEdge() throws {
        for kind in [ShapeKind.rectangle, .ellipse] {
            let raw = ShapeObject(kind: kind, start: .init(x: 400, y: 700), end: .init(x: 640, y: 900), lineWidth: 6)
            let fitted = DrawnShapeFitting.fitted(raw, in: page)
            XCTAssertTrue(page.contains(fitted.bounds, tolerance: 0.02), "\(kind)")
            XCTAssertEqual(fitted.start, raw.start)
            XCTAssertEqual(fitted.end, .init(x: 592, y: 839))
            XCTAssertNoThrow(try fitted.validate())
        }
        // Inside the page nothing changes; a shape with vertices is not touched.
        let inside = ShapeObject(kind: .rectangle, start: .init(x: 100, y: 100), end: .init(x: 200, y: 200))
        XCTAssertEqual(DrawnShapeFitting.fitted(inside, in: page), inside)
        let polyline = ShapeObject(kind: .line, vertices: [.init(x: -20, y: 0), .init(x: 50, y: 50), .init(x: 90, y: 0)])
        XCTAssertEqual(DrawnShapeFitting.fitted(polyline, in: page), polyline)
    }

    func testLinesAndArrowsAreNeverFillable() {
        XCTAssertFalse(ShapeKind.line.isFillable); XCTAssertFalse(ShapeKind.arrow.isFillable)
        XCTAssertTrue(ShapeKind.rectangle.isFillable); XCTAssertTrue(ShapeKind.ellipse.isFillable); XCTAssertTrue(ShapeKind.polygon.isFillable)
        let line = ShapeObject(kind: .line, start: .init(x: 10, y: 10), end: .init(x: 90, y: 10))
        XCTAssertTrue(ShapeEraseMask.canErasePartially(line), "an unfilled solid line can be cut")
    }

    // MARK: Scaling

    func testScaledLineWidthIsHeldInRangeInsteadOfLimitingTheScale() {
        let thin = ShapeObject(kind: .line, start: .init(x: 0, y: 0), end: .init(x: 100, y: 0), lineWidth: 0.5)
        XCTAssertEqual(thin.scaledLineWidth(0.25), 0.5, "a 0.5-pt shape still shrinks, only the width stops")
        let one = ShapeObject(kind: .line, start: .init(x: 0, y: 0), end: .init(x: 100, y: 0), lineWidth: 1)
        XCTAssertEqual(one.scaledLineWidth(0.3), 0.5)
        XCTAssertEqual(one.scaledLineWidth(2), 2)
        let thick = ShapeObject(kind: .line, start: .init(x: 0, y: 0), end: .init(x: 100, y: 0), lineWidth: 12)
        XCTAssertEqual(thick.scaledLineWidth(5), 40)
        XCTAssertEqual(thick.scaledLineWidth(.infinity), 12)
        var scaled = thin; scaled.lineWidth = thin.scaledLineWidth(0.25)
        XCTAssertNoThrow(try scaled.validate())
    }

    // MARK: Named image limits

    func testImageLimitProblemNamesFullPageAndFullNotebook() throws {
        func photo(_ reference: ImageAssetReference) -> ImageObject {
            ImageObject(asset: reference, pixelWidth: 400, pixelHeight: 300, x: 40, y: 40, width: 240, height: 180)
        }
        var document = Notebook.blank(title: "Grenzen")
        let pageID = document.pages[0].id
        let many = (0..<ImageLimits.maximumImagesPerPage).map { _ in photo(.declared(10)) }
        try document.replaceImages(many, pageID: pageID)
        XCTAssertNil(document.imageLimitProblem(replacing: pageID, with: many))
        // Pasting or duplicating one more: the page is full, not a „damaged file“.
        XCTAssertEqual(document.imageLimitProblem(replacing: pageID, with: many + [photo(.declared(10))]), .pageFull)
        XCTAssertNil(document.imageLimitProblem(replacing: pageID, with: Array(many.dropLast())))

        var budget = Notebook.blank(title: "Budget")
        let budgetPage = budget.pages[0].id
        let images = (0..<25).map { seed in photo(.declared(20_000_000, seed: seed)) }
        try budget.replaceImages(images, pageID: budgetPage)
        XCTAssertEqual(budget.uniqueImageAssetBytes, 500_000_000)
        // A copy of an original already present adds nothing …
        var copy = images[0]; copy.id = UUID()
        XCTAssertNil(budget.imageLimitProblem(replacing: budgetPage, with: images + [copy]))
        // … a new original over the budget is named with its size.
        let extra = photo(.declared(3_000_000, seed: 99))
        XCTAssertEqual(budget.imageLimitProblem(replacing: budgetPage, with: images + [extra]),
                       .notebookFull(used: 500_000_000, adding: 3_000_000))
        var rejected = budget
        XCTAssertThrowsError(try rejected.replaceImages(images + [extra], pageID: budgetPage), "matches the validation")
        // Swapping one original for another of the same size stays within the budget.
        XCTAssertNil(budget.imageLimitProblem(replacing: budgetPage, with: Array(images.dropFirst()) + [photo(.declared(20_000_000, seed: 77))]))
    }

    // MARK: Laser „bis zum Absetzen“

    func testLongUntilLiftStrokeKeepsItsBeginningWhileTouching() {
        var trail = LaserTrail(mode: .trail, fade: .untilLift)
        trail.begin(at: .init(x: 0, y: 0), time: 0)
        for step in 1...5_000 { trail.move(to: .init(x: Double(step), y: Double(step % 7)), time: Double(step) / 240) }
        XCTAssertLessThanOrEqual(trail.samples.count, LaserTrail.maximumSamples)
        XCTAssertEqual(trail.samples.first?.point, .init(x: 0, y: 0), "the start of the trail is still there")
        XCTAssertEqual(trail.samples.last?.point, .init(x: 5_000, y: Double(5_000 % 7)))
        // Thinned evenly: no gap anywhere is much larger than the thinning step.
        let gaps = zip(trail.samples, trail.samples.dropFirst()).map { $1.point.x - $0.point.x }
        XCTAssertLessThanOrEqual(gaps.max() ?? 0, 4)
        XCTAssertTrue(trail.segments(at: 30, levels: 3)[0].count >= trail.samples.count - 1)
    }

    func testThinningKeepsSeparateStrokesApart() {
        var trail = LaserTrail(mode: .trail, fade: .untilLift)
        trail.begin(at: .init(x: 0, y: 0), time: 0)
        for step in 1...3_000 { trail.move(to: .init(x: Double(step), y: 0), time: Double(step) / 240) }
        trail.begin(at: .init(x: 0, y: 500), time: 20)
        for step in 1...3_000 { trail.move(to: .init(x: Double(step), y: 500), time: 20 + Double(step) / 240) }
        XCTAssertLessThanOrEqual(trail.samples.count, LaserTrail.maximumSamples)
        let strokes = Dictionary(grouping: trail.samples, by: \.stroke)
        XCTAssertEqual(strokes.count, 2)
        for (_, samples) in strokes {
            XCTAssertEqual(samples.first?.point.x, 0); XCTAssertEqual(samples.last?.point.x, 3_000)
        }
        // Never a segment from one stroke to the other.
        XCTAssertFalse(trail.segments(at: 40, levels: 1)[0].contains { abs($0.start.y - $0.end.y) > 1 })
    }
}
