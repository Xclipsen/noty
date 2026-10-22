import XCTest
@testable import NotebookCore

/// Weiches Einrasten (Textneubau Stufe 2): targets, reach in screen points,
/// speed threshold, hysteresis, suppression and guides.
final class SoftSnappingTests: XCTestCase {
    private func p(_ x: Double, _ y: Double) -> PagePoint { PagePoint(x: x, y: y) }
    private func r(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> PageRect { PageRect(x: x, y: y, width: w, height: h) }
    private let slow = 50.0

    func testEdgesAndCentresOfOtherObjectsWithinFiveScreenPoints() {
        let other = SnapObject(frame: r(100, 100, 80, 40))
        var snapper = SoftSnapper(scene: SnapScene(objects: [other]))
        let moving = SnapMoving(frame: r(300, 300, 50, 20))
        // Left edge 300 + (-196) = 104 → 4 pt from 100 at zoom 1: snaps.
        XCTAssertEqual(snapper.snap(p(-196, 37), moving: moving, scale: 1, speed: slow), p(-200, 37))
        XCTAssertTrue(snapper.newlyEngaged)
        let feedback = snapper.feedback(for: p(-200, 37), moving: moving)
        XCTAssertEqual(feedback.guides.map(\.axis), [.x])
        XCTAssertEqual(feedback.guides.first?.value, 100)
        XCTAssertEqual(feedback.guides.first?.span, 100...357, "guide reaches from the other object to the moved one")

        // 6 screen points away: nothing (fresh drag).
        var fresh = SoftSnapper(scene: SnapScene(objects: [other]))
        XCTAssertEqual(fresh.snap(p(-194, 37), moving: moving, scale: 1, speed: slow), p(-194, 37))
        XCTAssertFalse(fresh.isEngaged)
        // Zoomed in 2×: 5 screen points are 2.5 page points.
        XCTAssertEqual(fresh.snap(p(-197, 37), moving: moving, scale: 2, speed: slow), p(-197, 37))
        XCTAssertEqual(fresh.snap(p(-197.6, 37), moving: moving, scale: 2, speed: slow), p(-200, 37))
        // Zoomed out: 5 screen points at 0.5 are 10 page points.
        var far = SoftSnapper(scene: SnapScene(objects: [other]))
        XCTAssertEqual(far.snap(p(-208, 37), moving: moving, scale: 0.5, speed: slow), p(-200, 37))

        // Centres: the moved centre (325) onto the other centre (140), y centre 120.
        var centred = SoftSnapper(scene: SnapScene(objects: [other]))
        let snapped = centred.snap(p(-183, -188.5), moving: moving, scale: 1, speed: slow)
        XCTAssertEqual(snapped, p(-185, -190))
        XCTAssertEqual(Set(centred.feedback(for: snapped, moving: moving).guides.map(\.kind)), [.center])
        // Right edge onto left edge (side by side): 350 − 248 = 102 → 100.
        var touching = SoftSnapper(scene: SnapScene(objects: [other]))
        XCTAssertEqual(touching.snap(p(-248, 400), moving: moving, scale: 1, speed: slow).x, -250)
    }

    func testFastDraggingNeverSnapsAndSlowingDownDoes() {
        var snapper = SoftSnapper(scene: SnapScene(objects: [SnapObject(frame: r(100, 100, 80, 40))]))
        let moving = SnapMoving(frame: r(300, 300, 50, 20))
        XCTAssertEqual(snapper.snap(p(-198, 0), moving: moving, scale: 1, speed: 900), p(-198, 0))
        XCTAssertEqual(snapper.snap(p(-198, 0), moving: moving, scale: 1, speed: 251), p(-198, 0))
        XCTAssertEqual(snapper.snap(p(-198, 0), moving: moving, scale: 1, speed: 249), p(-200, 0))
        // Engaged: a sudden fast move keeps it only within the release distance.
        XCTAssertEqual(snapper.snap(p(-196, 0), moving: moving, scale: 1, speed: 900), p(-200, 0))
        XCTAssertEqual(snapper.snap(p(-185, 0), moving: moving, scale: 1, speed: 900), p(-185, 0))
    }

    func testHysteresisHoldsThenReleasesAfterASmallMovement() {
        var snapper = SoftSnapper(scene: SnapScene(objects: [SnapObject(frame: r(100, 100, 80, 40))]))
        let moving = SnapMoving(frame: r(300, 300, 50, 20))
        XCTAssertEqual(snapper.snap(p(-204.5, 0), moving: moving, scale: 1, speed: slow).x, -200)
        // 7 points past the target: still held (release 8 screen points).
        XCTAssertEqual(snapper.snap(p(-193, 0), moving: moving, scale: 1, speed: slow).x, -200)
        XCTAssertFalse(snapper.newlyEngaged)
        // A little further: released, follows the touch again.
        XCTAssertEqual(snapper.snap(p(-191.5, 0), moving: moving, scale: 1, speed: slow).x, -191.5)
        XCTAssertFalse(snapper.isEngaged)
        XCTAssertTrue(snapper.feedback(for: p(-191.5, 0), moving: moving).isEmpty)
        // Coming back slowly engages again (and ticks again).
        XCTAssertEqual(snapper.snap(p(-196, 0), moving: moving, scale: 1, speed: slow).x, -200)
        XCTAssertTrue(snapper.newlyEngaged)
        // A closer target replaces the held one.
        var two = SoftSnapper(scene: SnapScene(objects: [SnapObject(frame: r(100, 100, 80, 40)), SnapObject(frame: r(106, 400, 10, 10))]))
        XCTAssertEqual(two.snap(p(-198, 0), moving: moving, scale: 1, speed: slow).x, -200)
        XCTAssertEqual(two.snap(p(-195, 0), moving: moving, scale: 1, speed: slow).x, -194)
        XCTAssertTrue(two.newlyEngaged)
    }

    func testSecondFingerSuppressesAndReleases() {
        var snapper = SoftSnapper(scene: SnapScene(objects: [SnapObject(frame: r(100, 100, 80, 40))]))
        let moving = SnapMoving(frame: r(300, 300, 50, 20))
        XCTAssertEqual(snapper.snap(p(-198, 0), moving: moving, scale: 1, speed: slow).x, -200)
        XCTAssertEqual(snapper.snap(p(-198, 0), moving: moving, scale: 1, speed: slow, suppressed: true), p(-198, 0))
        XCTAssertFalse(snapper.isEngaged)
        XCTAssertEqual(snapper.snap(p(-198, 0), moving: moving, scale: 1, speed: slow).x, -200, "lifting the finger allows it again")
    }

    func testBaselinesOfOtherTextFields() {
        // Other field: baseline at 132. Moved field: baseline 14 below its top.
        let other = SnapObject(frame: r(100, 118, 120, 20), baseline: 132)
        var snapper = SoftSnapper(scene: SnapScene(objects: [other]))
        let moving = SnapMoving(frame: r(400, 300, 80, 20), baselineOffset: 14)
        // Baseline 300 + 14 − 184 = 130 → 132 (top, centre and bottom are 2 off as well: same result).
        let snapped = snapper.snap(p(0, -184), moving: moving, scale: 1, speed: slow)
        XCTAssertEqual(snapped.y, -182)
    }

    func testPaperLinesAndGridAreNoTargets() {
        // Feedback zu Build 62: nothing clicks onto lined or squared paper.
        // Where lined paper has a line (y 160, baseline 157.5) or grid paper a
        // column (x 48), and where ruled lines begin (x 32), nothing engages.
        var paper = SoftSnapper(scene: SnapScene())
        let field = SnapMoving(frame: r(400, 300, 80, 20), baselineOffset: 14)
        XCTAssertEqual(paper.snap(p(0, -157), moving: field, scale: 1, speed: slow), p(0, -157))
        XCTAssertFalse(paper.isEngaged)
        let image = SnapMoving(frame: r(200, 200, 100, 50))
        XCTAssertEqual(paper.snap(p(-151, -39), moving: image, scale: 1, speed: slow), p(-151, -39))
        XCTAssertEqual(paper.snap(p(-167, 7), moving: image, scale: 1, speed: slow), p(-167, 7))
        XCTAssertTrue(paper.feedback(for: p(-167, 7), moving: image).isEmpty)
        XCTAssertEqual(MoveSnapSession(scene: SnapScene()).adjusted(point: p(31, 159)), p(31, 159), "width points and anchors stay where they are")
    }

    func testPageEdgesCentreAndWritingSpace() {
        let moving = SnapMoving(frame: r(200, 200, 100, 50))
        // Page centre: 250 + 46 = 296 → 297.5.
        var centre = SoftSnapper(scene: SnapScene(page: r(0, 0, 595, 842)))
        XCTAssertEqual(centre.snap(p(46, 0), moving: moving, scale: 1, speed: slow).x, 47.5)
        XCTAssertEqual(centre.feedback(for: p(47.5, 0), moving: moving).guides.first?.span, 0...842, "page guides cross the page")
        // Page edges and the larger writing space beside a PDF.
        var edges = SoftSnapper(scene: SnapScene(page: r(0, 0, 595, 842), limits: r(-300, 0, 895, 842)))
        XCTAssertEqual(edges.snap(p(-497, 0), moving: moving, scale: 1, speed: slow).x, -500)
        XCTAssertEqual(edges.feedback(for: p(-500, 0), moving: moving).guides.first?.kind, .page)
    }

    func testEqualGapsBetweenThreeAndMoreObjects() {
        // A [0,50] and B [150,200] in one row; moving 40 wide: centred at 80…120 (gaps 30/30).
        let a = SnapObject(frame: r(0, 100, 50, 30)), b = SnapObject(frame: r(150, 100, 50, 30))
        var between = SoftSnapper(scene: SnapScene(objects: [a, b]))
        let moving = SnapMoving(frame: r(0, 300, 40, 30))
        let t = between.snap(p(82, -195), moving: moving, scale: 1, speed: slow)
        XCTAssertEqual(t.x, 80)
        let marks = between.feedback(for: t, moving: moving).marks
        XCTAssertEqual(marks.count, 2)
        XCTAssertEqual(Set(marks.map { $0.to - $0.from }), [30])
        // Repeat the gap of a row: A, B (gap 100), moving right of B: 200 + 100 = 300.
        var repeated = SoftSnapper(scene: SnapScene(objects: [a, b]))
        let next = repeated.snap(p(303, -200), moving: moving, scale: 1, speed: slow)
        XCTAssertEqual(next.x, 300)
        let gaps = repeated.feedback(for: next, moving: moving).marks
        XCTAssertEqual(gaps.map { $0.to - $0.from }, [100, 100])
        XCTAssertEqual(gaps.first?.cross, 115, "drawn in the middle of the shared height")
        // Not in the row (no vertical overlap): no spacing target.
        var apart = SoftSnapper(scene: SnapScene(objects: [a, b]))
        XCTAssertEqual(apart.snap(p(303, 0), moving: moving, scale: 1, speed: slow).x, 303)
        // Vertical gaps work the same way.
        let c = SnapObject(frame: r(0, 0, 50, 20)), d = SnapObject(frame: r(0, 60, 50, 20))
        var column = SoftSnapper(scene: SnapScene(objects: [c, d]))
        XCTAssertEqual(column.snap(p(0, 118), moving: SnapMoving(frame: r(0, 2, 50, 20)), scale: 1, speed: slow).y, 118)
    }

    func testPointsSnapForWidthPointsAndShapeAnchors() {
        let session = MoveSnapSession(scene: SnapScene(objects: [SnapObject(frame: r(100, 100, 80, 40))], page: r(0, 0, 595, 842)))
        session.speed = slow
        XCTAssertEqual(session.adjusted(point: p(183, 300), axes: [.x]), p(180, 300))
        XCTAssertEqual(session.feedback(point: p(180, 300), axes: [.x]).guides.first?.value, 180)
        // An anchor onto a corner (both axes) and onto the centre.
        let anchors = MoveSnapSession(scene: SnapScene(objects: [SnapObject(frame: r(100, 100, 80, 40))]))
        XCTAssertEqual(anchors.adjusted(point: p(97, 143)), p(100, 140))
        XCTAssertEqual(anchors.adjusted(point: p(139, 121)), p(140, 120))
    }

    func testMovePathSnapsBeforeTheLimitsAndHidesClampedGuides() {
        let session = MoveSnapSession(scene: SnapScene(objects: [SnapObject(frame: r(500, 100, 40, 40))]))
        session.speed = slow
        let frame = r(100, 300, 60, 20)
        // Snaps x onto 500 (left edges) inside the page.
        let shift = ObjectMovement.translation(moving: frame, by: p(397, 0), within: r(0, 0, 595, 842), snapping: session)
        XCTAssertEqual(shift, p(400, 0))
        XCTAssertEqual(session.feedback(for: shift, moving: frame).guides.count, 1)
        // On a narrower page the snapped frame would stick out: clamped, no guide.
        let clamped = ObjectMovement.translation(moving: frame, by: p(397, 0), within: r(0, 0, 555, 842), snapping: session)
        XCTAssertEqual(clamped, p(395, 0))
        XCTAssertTrue(session.feedback(for: clamped, moving: frame).isEmpty)
        // Snapping by a different frame (shape geometry instead of its touch padding).
        let padded = MoveSnapSession(scene: SnapScene(objects: [SnapObject(frame: r(300, 0, 10, 10))]))
        padded.snapFrame = r(110, 300, 40, 20)
        XCTAssertEqual(padded.adjusted(p(188, 0), moving: frame), p(190, 0))
        let arrow = ShapeObject(kind: .arrow, start: p(10, 10), end: p(110, 10), lineWidth: 4)
        XCTAssertEqual(arrow.snapFrame, r(8, 8, 104, 4), "shapes align by their outline, not the arrow's touch padding")
        // Suppressed sessions leave the move alone.
        padded.suppressed = true
        XCTAssertEqual(padded.adjusted(p(188, 0), moving: frame), p(188, 0))
    }

    func testDragSpeedInScreenPointsPerSecond() {
        var speed = DragSpeed()
        XCTAssertEqual(speed.add(p(0, 0), at: 0), 0)
        // 10 points in 10 ms = 1000 pt/s, smoothed.
        let fast = speed.add(p(10, 0), at: 0.01)
        XCTAssertGreaterThan(fast, 150); XCTAssertLessThan(fast, 1000)
        for i in 2...10 { speed.add(p(Double(i) * 10, 0), at: Double(i) * 0.01) }
        XCTAssertGreaterThan(speed.value, 800)
        // A pause, then a tiny move: slow at once.
        speed.add(p(101, 0), at: 1.1)
        XCTAssertLessThan(speed.value, SnapParameters.standard.slowSpeed)
        // Same timestamp: no division by zero.
        XCTAssertTrue(speed.add(p(200, 0), at: 1.1).isFinite)
    }
}
