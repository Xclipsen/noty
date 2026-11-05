import XCTest
@testable import NotebookCore

/// Review findings on object selection, shapes, images, laser and lasso
/// (feat/fix2-objects).
final class ObjectSelectionReviewTests: XCTestCase {

    // MARK: Befund 3 – Laser „bis zum Absetzen“ dünnt gleichmäßig aus

    /// One long stroke back and forth across a 1000-pt screen, one point per pt.
    private func longStroke(_ count: Int) -> (trail: LaserTrail, length: Double) {
        var trail = LaserTrail(mode: .trail, fade: .untilLift)
        func point(_ i: Int) -> PagePoint {
            let lap = i / 1_000, along = Double(i % 1_000)
            return PagePoint(x: lap % 2 == 0 ? along : 1_000 - along, y: 100 + Double(lap % 600))
        }
        trail.begin(at: point(0), time: 0)
        var length = 0.0
        for i in 1..<count {
            let a = point(i - 1), b = point(i)
            length += hypot(b.x - a.x, b.y - a.y)
            trail.move(to: b, time: Double(i) / 240)
        }
        return (trail, length)
    }

    func testUntilLiftThinsEvenlyAtEveryLength() {
        for count in [5_000, 15_000, 30_000, 100_000] {
            let (trail, length) = longStroke(count)
            let samples = trail.samples
            XCTAssertLessThanOrEqual(samples.count, LaserTrail.maximumSamples, "\(count)")
            XCTAssertGreaterThan(samples.count, LaserTrail.maximumSamples / 4, "\(count): the budget is used, not wasted")
            XCTAssertEqual(samples.first?.point, PagePoint(x: 0, y: 100), "\(count): the beginning stays")
            XCTAssertEqual(samples.last?.point, trail.pointer, "\(count): the end follows the pointer")
            let gaps = zip(samples, samples.dropFirst()).map { hypot($1.point.x - $0.point.x, $1.point.y - $0.point.y) }
            let largest = gaps.max() ?? 0
            // Bounded by what the budget allows for this length (the old
            // repeated halving left a chord over 8 048 points at 30 000).
            XCTAssertLessThanOrEqual(largest, 4 * length / Double(LaserTrail.maximumSamples) + 2, "\(count)")
            // Even: the oldest part is not coarser than the newest.
            let sorted = gaps.sorted(), median = sorted[sorted.count / 2]
            XCTAssertLessThanOrEqual(largest, 2 * median + 2, "\(count)")
            let half = gaps.count / 2
            let older = gaps[..<half].reduce(0, +) / Double(half), newer = gaps[half...].reduce(0, +) / Double(gaps.count - half)
            XCTAssertLessThan(abs(older - newer), 0.5 * max(older, newer) + 0.5, "\(count)")
        }
    }

    func testThinningEndsWithTheTrailAndManyTinyStrokesStayBounded() {
        var trail = LaserTrail(mode: .trail, fade: .untilLift)
        var time = 0.0
        for stroke in 0..<3_000 {
            trail.begin(at: .init(x: Double(stroke % 100), y: Double(stroke / 100)), time: time)
            trail.move(to: .init(x: Double(stroke % 100) + 0.5, y: Double(stroke / 100)), time: time + 0.01)
            trail.end(time: time + 0.01); time += 0.02
        }
        XCTAssertLessThanOrEqual(trail.samples.count, LaserTrail.maximumSamples)
        XCTAssertEqual(trail.samples.last?.point, PagePoint(x: 99.5, y: 29), "the newest stroke is kept")
        trail.prune(at: time + 10)
        XCTAssertTrue(trail.samples.isEmpty)
        // A new session starts unthinned again: dense samples are kept.
        trail.begin(at: .init(x: 0, y: 0), time: time + 20)
        for step in 1...10 { trail.move(to: .init(x: Double(step) * 0.5, y: 0), time: time + 20 + Double(step) * 0.01) }
        XCTAssertEqual(trail.samples.count, 11)
    }

    // MARK: Befund 6 – Kopien am Rand nie übereinander

    /// Pastes `times` copies the way the app does: beside the previous copy,
    /// in the direction of the series, never onto a taken place.
    private func series(of frame: PageRect, in page: PageRect, times: Int) -> [PagePoint] {
        var taken = [PagePoint(x: frame.x, y: frame.y)]
        var previous: PageRect?
        for _ in 0..<times {
            let reference = previous ?? frame
            let direction = previous.map { ($0.x - frame.x, $0.y - frame.y) } ?? (1, 1)
            let step = PasteOffset.offset(for: reference, in: page, direction: direction) { dx, dy in
                taken.contains { abs($0.x - (reference.x + dx)) < 0.5 && abs($0.y - (reference.y + dy)) < 0.5 }
            }
            let placed = PageRect(x: reference.x + step.dx, y: reference.y + step.dy, width: frame.width, height: frame.height)
            XCTAssertTrue(placed.x >= page.x - 0.001 && placed.x + placed.width <= page.x + page.width + 0.001)
            XCTAssertTrue(placed.y >= page.y - 0.001 && placed.y + placed.height <= page.y + page.height + 0.001)
            taken.append(PagePoint(x: placed.x, y: placed.y)); previous = placed
        }
        return taken
    }

    private func assertDistinct(_ places: [PagePoint], file: StaticString = #filePath, line: UInt = #line) {
        for i in places.indices {
            for j in places.indices where j > i {
                XCTAssertFalse(abs(places[i].x - places[j].x) < 0.5 && abs(places[i].y - places[j].y) < 0.5,
                               "copy \(j) lies on \(i): \(places)", file: file, line: line)
            }
        }
    }

    func testFivePastesAtTheRightEdgeAreAllDifferent() {
        let page = PageRect(x: 0, y: 0, width: 600, height: 800)
        let places = series(of: PageRect(x: 550, y: 300, width: 50, height: 50), in: page, times: 5)
        assertDistinct(places)
        // They step on to the left instead of jumping back and forth.
        XCTAssertEqual(places.map(\.x), [550, 526, 502, 478, 454, 430])
    }

    func testFivePastesInTheCornerAreAllDifferent() {
        let page = PageRect(x: 0, y: 0, width: 600, height: 800)
        let places = series(of: PageRect(x: 550, y: 750, width: 50, height: 50), in: page, times: 5)
        assertDistinct(places)
        XCTAssertEqual(places.last, PagePoint(x: 430, y: 630))
    }

    func testFiveCopiesOnAPageAsWideAsTheSelectionStillDiffer() {
        // No room sideways at all: they go down (and up) instead.
        let page = PageRect(x: 0, y: 0, width: 600, height: 800)
        assertDistinct(series(of: PageRect(x: 0, y: 750, width: 600, height: 50), in: page, times: 5))
    }

    func testDuplicatingWithoutDirectionAvoidsTheOriginal() {
        // ⌘D on the copy just made, without a known series: the default
        // direction would lead back onto the original.
        let page = PageRect(x: 0, y: 0, width: 600, height: 800)
        let original = PagePoint(x: 550, y: 750), copy = PageRect(x: 526, y: 726, width: 50, height: 50)
        let step = PasteOffset.offset(for: copy, in: page) { dx, dy in
            abs(copy.x + dx - original.x) < 0.5 && abs(copy.y + dy - original.y) < 0.5
        }
        XCTAssertFalse(abs(copy.x + step.dx - original.x) < 0.5 && abs(copy.y + step.dy - original.y) < 0.5)
    }

    func testAFullPageFallsBackToTheFirstChoice() {
        let page = PageRect(x: 0, y: 0, width: 60, height: 60)
        let step = PasteOffset.offset(for: PageRect(x: 0, y: 0, width: 50, height: 50), in: page) { _, _ in true }
        XCTAssertEqual(step.dx, 10); XCTAssertEqual(step.dy, 10)
    }

    // MARK: Befund 4 – Skalierecken vor Formpunkten

    func testScaleCornerWinsWithinAFewPointsAndAPointStaysReachable() {
        // Polygon point on the frame corner: its dot ~10 pt from the corner dot.
        XCTAssertEqual(SelectionHandlePriority.preferred(distances: [5, 5], isCorner: [false, true]), 1, "between both: the corner")
        XCTAssertEqual(SelectionHandlePriority.preferred(distances: [3, 7], isCorner: [false, true]), 1, "a few points nearer the point: still the corner")
        XCTAssertEqual(SelectionHandlePriority.preferred(distances: [0, 10], isCorner: [false, true]), 0, "on the point's dot: the point")
        XCTAssertEqual(SelectionHandlePriority.preferred(distances: [10, 0], isCorner: [false, true]), 1)
        XCTAssertEqual(SelectionHandlePriority.preferred(distances: [4, 9], isCorner: [false, false]), 0, "two points: the nearer one")
        XCTAssertNil(SelectionHandlePriority.preferred(distances: [], isCorner: []))
    }

    // MARK: Befund 8 – Kleinkram

    func testTransferHoldsLineWidthLikeScaling() throws {
        let shape = ShapeObject(kind: .rectangle, start: .init(x: 10, y: 10), end: .init(x: 60, y: 60),
                                color: InkColor(0, 0, 0), lineWidth: 30)
        let move = CrossPageMove(scale: 2, translation: .init(x: 0, y: 0))
        let moved = try CrossPageTransfer.move(MovedObjects(textBoxes: [], images: [], shapes: [shape]), by: move)
        XCTAssertEqual(moved.shapes.first?.lineWidth, ShapeObject.lineWidthRange.upperBound)
        let thin = ShapeObject(kind: .line, start: .init(x: 10, y: 10), end: .init(x: 60, y: 60), color: InkColor(0, 0, 0), lineWidth: 0.6)
        let shrunk = try CrossPageTransfer.move(MovedObjects(textBoxes: [], images: [], shapes: [thin]),
                                                by: CrossPageMove(scale: 0.5, translation: .init(x: 0, y: 0)))
        XCTAssertEqual(shrunk.shapes.first?.lineWidth, ShapeObject.lineWidthRange.lowerBound)
    }

    func testTappingAFilledSelfCrossingPolygonUsesNonzeroWinding() {
        // A pentagram: its centre is wound twice (even/odd: outside, the
        // drawn fill and the lasso: inside).
        let star = (0..<5).map { k -> PagePoint in
            let angle = -Double.pi / 2 + Double(k) * 4 * Double.pi / 5
            return PagePoint(x: 100 + 80 * cos(angle), y: 100 + 80 * sin(angle))
        }
        let shape = ShapeObject(kind: .polygon, vertices: star, color: InkColor(0, 0, 0), lineWidth: 2, fill: InkColor(1, 0, 0))
        XCTAssertTrue(shape.hasVisibleFill)
        XCTAssertTrue(PageObjectHitTest.hits(shape, at: .init(x: 100, y: 100)))
        XCTAssertTrue(LassoRegion(points: star).contains(.init(x: 100, y: 100)), "same rule as the lasso")
        XCTAssertFalse(PageObjectHitTest.hits(shape, at: .init(x: 100, y: 15)), "outside stays outside")
    }

    func testImageLimitOfAnUndoOrTransferIsNamed() throws {
        func photo(_ reference: ImageAssetReference) -> ImageObject {
            ImageObject(asset: reference, pixelWidth: 400, pixelHeight: 300, x: 40, y: 40, width: 240, height: 180)
        }
        var notebook = Notebook.blank(title: "Grenzen")
        let page = notebook.pages[0].id
        try notebook.replaceImages([photo(.declared(10))], pageID: page)
        var candidate = notebook
        candidate.pages[0].images = (0...ImageLimits.maximumImagesPerPage).map { _ in photo(.declared(10)) }
        XCTAssertEqual(notebook.imageLimitProblem(installing: candidate), .pageFull)
        XCTAssertEqual(notebook.imageLimitProblem(replacing: [page: candidate.pages[0].images ?? []]), .pageFull)
        XCTAssertNil(notebook.imageLimitProblem(installing: notebook))

        var budget = Notebook.blank(title: "Budget")
        let budgetPage = budget.pages[0].id
        try budget.replaceImages((0..<25).map { seed in photo(.declared(20_000_000, seed: seed)) }, pageID: budgetPage)
        var over = budget
        over.pages[0].images?.append(photo(.declared(3_000_000, seed: 99)))
        XCTAssertEqual(budget.imageLimitProblem(installing: over), .notebookFull(used: 500_000_000, adding: 3_000_000))
    }
}
