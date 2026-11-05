import XCTest
@testable import NotebookCore

/// Strokes along noty's own ruler (Build 109 überarbeitet): capture zone,
/// projection onto the edge, page clipping, shared ink profile, hand rules.
final class RulerStrokeTests: XCTestCase {
    private func point(_ x: Double, _ y: Double) -> PagePoint { PagePoint(x: x, y: y) }
    /// Edge at y = 100, the ruler above it, the page below; ink 2 pt wide.
    private let guide = RulerGuide(edge: PagePoint(x: 0, y: 100), outward: PagePoint(x: 0, y: 1), inkOffset: 1, capture: 10)
    private func stroke(_ points: [PagePoint], handedOver: Bool = false, priorLength: Double = 0) -> RulerStroke {
        var stroke = RulerStroke(guide: guide, handedOver: handedOver, priorLength: priorLength)
        for point in points { stroke.add(point) }
        return stroke
    }

    // MARK: Punkt 3 – gerade Linien

    func testWobbleInTheCaptureZoneBecomesAStraightLineOnTheEdge() {
        // ±2 pt around 4 pt beside the edge: the old `kept` left the outward wobble.
        let points = stride(from: 0.0, through: 200, by: 5).enumerated().map { index, x in point(x, 104 + (index % 2 == 0 ? 2 : -2)) }
        let result = stroke(points)
        XCTAssertTrue(result.isStraight)
        let path = result.path
        XCTAssertFalse(path.isEmpty)
        for entry in path { XCTAssertEqual(entry.location.y, 101, accuracy: 1e-9, "on the ink line beside the edge") }
        XCTAssertEqual(path.first!.location.x, 0, accuracy: 1e-9)
        XCTAssertEqual(path.last!.location.x, 200, accuracy: 1e-9)
        XCTAssertEqual(path.first!.sample, 0)
        XCTAssertEqual(path.last!.sample, points.count - 1)
    }

    func testAStartBesideTheEdgeMakesNoHook() {
        // Start 8 pt away, then along the edge: the start was kept, a hook.
        let points = [point(0, 108)] + stride(from: 5.0, through: 200, by: 5).map { point($0, 102) }
        let path = stroke(points).path
        XCTAssertEqual(path.first!.location.y, 101, accuracy: 1e-9)
        XCTAssertTrue(path.allSatisfy { abs($0.location.y - 101) < 1e-9 })
    }

    func testFarFromTheEdgeTheStrokeStaysFree() {
        let points = stride(from: 0.0, through: 100, by: 5).enumerated().map { index, x in point(x, 150 + (index % 2 == 0 ? 20 : -20)) }
        let result = stroke(points)
        XCTAssertFalse(result.isStraight)
        XCTAssertEqual(result.path.map(\.location), points, "handwriting beside the ruler is not touched")
    }

    func testAFreeStrokeNeverCrossesTheEdge() {
        // Comes from far away, runs into the ruler, goes back: the part behind the edge slides along it.
        let points = [point(0, 200), point(20, 150), point(40, 60), point(60, 150), point(80, 200)]
        let result = stroke(points, handedOver: true)
        XCTAssertFalse(result.isStraight)
        XCTAssertTrue(result.path.allSatisfy { $0.location.y >= 101 - 1e-9 })
        XCTAssertEqual(result.path[2].location, point(40, 101))
        XCTAssertEqual(result.path[0].location, point(0, 200))
    }

    func testMostlyAlongTheEdgeAfterAFreeApproach() {
        // Handed over by PencilKit 10 pt away: the approach stays as drawn,
        // from the contact on the stroke runs straight along the edge.
        let points = [point(0, 110), point(5, 105), point(10, 101.5)] + stride(from: 20.0, through: 300, by: 10).map { point($0, 102 + ($0.truncatingRemainder(dividingBy: 20) == 0 ? 1.5 : -1)) }
        let result = stroke(points, handedOver: true, priorLength: 30)
        XCTAssertTrue(result.isStraight)
        let path = result.path
        XCTAssertEqual(path[0].location, point(0, 110), "the approach is not flattened")
        XCTAssertEqual(path[1].location, point(5, 105))
        XCTAssertTrue(path.dropFirst(2).allSatisfy { abs($0.location.y - 101) < 1e-9 })
        XCTAssertEqual(path.last!.location.x, 300, accuracy: 1e-9)
    }

    func testHandwritingThatTouchesTheEdgeStaysFree() {
        // A long word, its last letter dips into the zone: no straight line.
        let points = [point(0, 104), point(10, 115), point(20, 104), point(30, 115)]
        let result = stroke(points, handedOver: true, priorLength: 400)
        XCTAssertFalse(result.isStraight)
        XCTAssertEqual(result.path[1].location, point(10, 115))
    }

    func testAStrokeAwayFromTheEdgeIsNoDot() {
        // A perpendicular from the edge: starts in the zone, leaves it.
        let points = stride(from: 0.0, through: 120, by: 4).map { point(50, 103 + $0) }
        let result = stroke(points)
        XCTAssertFalse(result.isStraight)
        XCTAssertEqual(result.path.last!.location, point(50, 223))
    }

    func testADotOnTheEdge() {
        let result = stroke([point(30, 104)])
        XCTAssertTrue(result.isStraight)
        XCTAssertEqual(result.path.map(\.location), [point(30, 101)])
    }

    // MARK: Punkt 8 – Abstand zur Kante

    func testTheInkLiesItsVisibleHalfWidthBesideTheEdge() {
        let wide = RulerGuide(edge: point(0, 100), outward: point(0, 1), inkOffset: 3, capture: 10)
        XCTAssertEqual(wide.onLine(point(40, 95)), point(40, 103))
        XCTAssertEqual(wide.distance(point(40, 95)), -5, accuracy: 1e-9)
        XCTAssertEqual(wide.kept(point(40, 102)), point(40, 103), "the ink edge never reaches under the ruler")
        XCTAssertEqual(wide.kept(point(40, 120)), point(40, 120))
        // Turned: outward is normalised.
        let turned = RulerGuide(edge: point(0, 0), outward: point(2, 2), inkOffset: 0, capture: 10)
        let on = turned.onLine(point(10, 0))
        XCTAssertEqual(on.x, 5, accuracy: 1e-9)
        XCTAssertEqual(on.y, -5, accuracy: 1e-9)
    }

    // MARK: Punkt 5 – Seitenrand

    func testADiagonalOverThePageEdgeIsCutNotBent() {
        let path = (0...20).map { RulerStroke.Point(location: point(Double($0) * 10, Double($0) * 5), sample: $0) }
        let pieces = RulerStroke.pieces(path, inside: PageRect(x: 0, y: 0, width: 150, height: 150))
        XCTAssertEqual(pieces.count, 1)
        let last = pieces[0].last!.location
        XCTAssertEqual(last.x, 150, accuracy: 1e-9)
        XCTAssertEqual(last.y, 75, accuracy: 1e-9, "the direction stays: no L along the edge")
        XCTAssertTrue(pieces[0].allSatisfy { $0.location.x <= 150 + 1e-9 })
    }

    func testLeavingAndReturningKeepsWhatFits() {
        let raw = [point(10, 10), point(100, 10), point(200, 10), point(200, 60), point(100, 60), point(10, 60)]
        let path = raw.enumerated().map { RulerStroke.Point(location: $1, sample: $0) }
        let pieces = RulerStroke.pieces(path, inside: PageRect(x: 0, y: 0, width: 150, height: 150))
        XCTAssertEqual(pieces.count, 2, "both parts on the page are drawn")
        XCTAssertEqual(pieces[0].last!.location, point(150, 10))
        XCTAssertEqual(pieces[1].first!.location, point(150, 60))
        XCTAssertEqual(pieces[1].last!.location, point(10, 60))
        XCTAssertTrue(RulerStroke.pieces(path.map { .init(location: point($0.location.x + 1000, 0), sample: $0.sample) },
                                         inside: PageRect(x: 0, y: 0, width: 150, height: 150)).isEmpty)
        XCTAssertEqual(RulerStroke.pieces([.init(location: point(5, 5), sample: 0)], inside: PageRect(x: 0, y: 0, width: 10, height: 10)).count, 1)
    }

    // MARK: Punkt 1b – Strichbild gemeinsam und dauerhaft

    func testTheInkProfileIsSharedAndSurvivesARestart() {
        var profiles = InkPointProfiles()
        profiles.learn("pen", widthRatio: 1.8, opacity: 0.9, force: 0.6, altitude: 1.0, azimuth: 0.5)
        // Another page, another view, the next launch: decoded from what was stored.
        let restored = InkPointProfiles(data: profiles.encoded())
        XCTAssertEqual(restored["pen"]?.widthRatio ?? 0, 1.8, accuracy: 1e-9)
        XCTAssertEqual(restored["pen"]?.opacity ?? 0, 0.9, accuracy: 1e-9)
        XCTAssertNil(restored["pencil"], "per ink type")
        XCTAssertEqual(InkPointProfiles(data: Data("kaputt".utf8)), InkPointProfiles())
        XCTAssertEqual(InkPointProfiles(data: nil), InkPointProfiles())
    }

    func testOneOddStrokeDoesNotMakeTheWidthJump() {
        var profiles = InkPointProfiles()
        for _ in 0..<10 { profiles.learn("pen", widthRatio: 2, opacity: 1, force: 1, altitude: 1, azimuth: 0) }
        profiles.learn("pen", widthRatio: 0.5, opacity: 1, force: 1, altitude: 1, azimuth: 0)
        let ratio = profiles["pen"]!.widthRatio
        XCTAssertGreaterThan(ratio, 1.7, "a light stroke moves it a little, not to its own width")
        XCTAssertLessThan(ratio, 2)
        profiles.learn("pen", widthRatio: .nan, opacity: 1, force: 1, altitude: 1, azimuth: 0)
        profiles.learn("pen", widthRatio: 0, opacity: 1, force: 1, altitude: 1, azimuth: 0)
        XCTAssertEqual(profiles["pen"]!.widthRatio, ratio, "nothing measured, nothing learned")
    }

    // MARK: Punkte 2 und 4 – wann der Linealweg bereit ist

    func testTheRulerWayIsReadyOnEveryEditablePageAndAStrokeIsNeverCutOff() {
        XCTAssertTrue(EditorInteractionPolicy.rulerStrokeEnabled(ruler: true, editable: true, inkTool: true, running: false),
                      "also on a visible page that is not selected yet")
        XCTAssertTrue(EditorInteractionPolicy.rulerStrokeEnabled(ruler: true, editable: false, inkTool: true, running: true),
                      "a backup commit locks the page: the running stroke goes on")
        XCTAssertTrue(EditorInteractionPolicy.rulerStrokeEnabled(ruler: false, editable: true, inkTool: false, running: true))
        XCTAssertFalse(EditorInteractionPolicy.rulerStrokeEnabled(ruler: true, editable: false, inkTool: true, running: false))
        XCTAssertFalse(EditorInteractionPolicy.rulerStrokeEnabled(ruler: true, editable: true, inkTool: false, running: false))
        XCTAssertFalse(EditorInteractionPolicy.rulerStrokeEnabled(ruler: false, editable: true, inkTool: true, running: false))
    }

    // MARK: Punkt 1a – wann ein Strich zum Lineal gehört

    func testOnlyStrokesAtTheEdgeFollowTheRuler() {
        let ruler = NotebookRuler(x: 500, y: 300)
        XCTAssertTrue(ruler.captures(point(500, 300)), "on the band")
        XCTAssertTrue(ruler.captures(point(10, 352)), "8 pt beside the lower edge")
        XCTAssertTrue(ruler.captures(point(10, 248)), "beside the upper edge")
        XCTAssertFalse(ruler.captures(point(10, 360)), "handwriting 16 pt away stays PencilKit")
        XCTAssertEqual(ruler.edgeDistance(point(0, 354), side: 1), 10, accuracy: 1e-9)
        XCTAssertEqual(ruler.edgeDistance(point(0, 330), side: 1), -14, accuracy: 1e-9)
    }

    // MARK: Punkte 6 und 11 – Finger und Hand auf dem Lineal

    func testTwoFingersLandingTogetherBothCount() {
        let touches = [RulerHand.Touch(onBand: false, majorRadius: 8), RulerHand.Touch(onBand: true, majorRadius: 9)]
        XCTAssertEqual(RulerHand.fingers(touches, strokeActive: false), [1, 0], "the one on the band first, the second turns")
        XCTAssertEqual(RulerHand.fingers([RulerHand.Touch(onBand: false, majorRadius: 8)], strokeActive: false), [])
    }

    func testAHandOnTheRulerDoesNotMoveIt() {
        XCTAssertEqual(RulerHand.fingers([RulerHand.Touch(onBand: true, majorRadius: 40)], strokeActive: false), [], "a palm")
        XCTAssertEqual(RulerHand.fingers([RulerHand.Touch(onBand: true, majorRadius: 8), RulerHand.Touch(onBand: true, majorRadius: 45)],
                                         strokeActive: false), [0])
        XCTAssertEqual(RulerHand.fingers([RulerHand.Touch(onBand: true, majorRadius: 8)], strokeActive: true), [], "the Pencil draws")
        XCTAssertFalse(RulerHand.begins(moved: [3, 7.9]), "resting fingers")
        XCTAssertTrue(RulerHand.begins(moved: [1, 8]))
        XCTAssertFalse(RulerHand.joins(RulerHand.Touch(onBand: false, majorRadius: 40)))
        XCTAssertTrue(RulerHand.joins(RulerHand.Touch(onBand: false, majorRadius: 10)))
    }

    // MARK: Punkt 14 – Kleinigkeiten

    func testTheMiddleStaysInTheFreeArea() {
        let area = NotebookRuler.parkingArea(width: 1000, height: 800, top: 60, bottom: 300,
                                             obstructions: [PageRect(x: 0, y: 60, width: 70, height: 740)])
        XCTAssertEqual(area, PageRect(x: 70, y: 60, width: 930, height: 440), "toolbar on top and left, keyboard below")
        XCTAssertEqual(NotebookRuler(x: 500, y: 790).clamped(to: area), NotebookRuler(x: 500, y: 460))
        XCTAssertEqual(NotebookRuler(x: 5, y: 10).clamped(to: area), NotebookRuler(x: 110, y: 100))
        // A small floating palette does not shrink the area; too little room keeps the whole screen.
        XCTAssertEqual(NotebookRuler.parkingArea(width: 1000, height: 800, top: 0, bottom: 0,
                                                 obstructions: [PageRect(x: 400, y: 300, width: 100, height: 100)]),
                       PageRect(x: 0, y: 0, width: 1000, height: 800))
        XCTAssertEqual(NotebookRuler.parkingArea(width: 1000, height: 300, top: 150, bottom: 140, obstructions: []),
                       PageRect(x: 0, y: 0, width: 1000, height: 300))
    }

    func testATurnOfTheIPadKeepsThePlaceAsAShare() {
        let turned = NotebookRuler(x: 300, y: 600, angle: 30).rescaled(from: PageSize(width: 1200, height: 800), to: PageSize(width: 800, height: 1200))
        XCTAssertEqual(turned.x, 200, accuracy: 1e-9)
        XCTAssertEqual(turned.y, 900, accuracy: 1e-9)
        XCTAssertEqual(turned.angle, 30)
        XCTAssertEqual(NotebookRuler(x: 3, y: 4).rescaled(from: PageSize(width: 0, height: 0), to: PageSize(width: 10, height: 10)), NotebookRuler(x: 3, y: 4))
    }

    func testTheAngleReadsLikeAProtractor() {
        XCTAssertEqual(NotebookRuler(x: 0, y: 0, angle: 0).displayDegrees, 0)
        XCTAssertEqual(NotebookRuler(x: 0, y: 0, angle: -30).displayDegrees, 30, "turned up to the right")
        XCTAssertEqual(NotebookRuler(x: 0, y: 0, angle: 30).displayDegrees, 150, "turned down to the right")
        XCTAssertEqual(NotebookRuler(x: 0, y: 0, angle: 90).displayDegrees, 90)
        XCTAssertEqual(NotebookRuler(x: 0, y: 0, angle: 0.3).displayDegrees, 0, "never 180")
    }

    func testSnappingIsReported() {
        XCTAssertTrue(NotebookRuler(x: 0, y: 0, angle: 44).snapped.isSnapped)
        XCTAssertFalse(NotebookRuler(x: 0, y: 0, angle: 37).snapped.isSnapped)
        XCTAssertTrue(NotebookRuler(x: 0, y: 0, angle: -90).isSnapped)
    }
}
