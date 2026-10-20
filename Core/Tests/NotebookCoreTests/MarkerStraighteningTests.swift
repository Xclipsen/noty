import Foundation
import XCTest
@testable import NotebookCore

final class MarkerStraighteningTests: XCTestCase {
    func testWobblyHorizontalPassBecomesLevelLineAtMeanHeight() throws {
        let points = (0...20).map { PagePoint(x: 100 + Double($0) * 10, y: 300 + ($0 % 2 == 0 ? 3 : -3) + Double($0) * 0.4) }
        let line = try XCTUnwrap(MarkerStraightening.line(points))
        XCTAssertEqual(line.start.y, line.end.y)
        XCTAssertEqual(line.start.x, 100); XCTAssertEqual(line.end.x, 300)
        XCTAssertEqual(line.start.y, points.map(\.y).reduce(0, +) / Double(points.count), accuracy: 0.0001)
    }
    func testVerticalAndBackwardStrokesKeepTheirDirectionAndSnapTo90Degrees() throws {
        let up = try XCTUnwrap(MarkerStraightening.line([.init(x: 50, y: 400), .init(x: 54, y: 250), .init(x: 52, y: 100)]))
        XCTAssertEqual(up.start.x, up.end.x); XCTAssertEqual(up.start.y, 400); XCTAssertEqual(up.end.y, 100)
        let back = try XCTUnwrap(MarkerStraightening.line([.init(x: 300, y: 10), .init(x: 100, y: 14)]))
        XCTAssertEqual(back.start.x, 300); XCTAssertEqual(back.end.x, 100)
    }
    func testTapsStayUntouchedAndColourIsSoftened() {
        XCTAssertNil(MarkerStraightening.line([.init(x: 1, y: 1), .init(x: 3, y: 2)]))
        XCTAssertNil(MarkerStraightening.line([]))
        XCTAssertLessThan(MarkerStraightening.opacityFactor, 1)
    }
    func testDiagonalMarkerKeepsItsAngleOrSnapsNarrowly() throws {
        // 20°: no snap nearby, stays at the drawn angle (not forced to 0°/90°).
        let free = try XCTUnwrap(MarkerStraightening.line((0...20).map { PagePoint(x: Double($0) * 10, y: Double($0) * 10 * tan(20 * .pi / 180)) }))
        XCTAssertEqual(atan2(free.end.y - free.start.y, free.end.x - free.start.x) * 180 / .pi, 20, accuracy: 0.01)
        // 43°: snaps to 45°.
        let diagonal = try XCTUnwrap(MarkerStraightening.line((0...20).map { PagePoint(x: Double($0) * 10, y: Double($0) * 10 * tan(43 * .pi / 180)) }))
        XCTAssertEqual(atan2(diagonal.end.y - diagonal.start.y, diagonal.end.x - diagonal.start.x) * 180 / .pi, 45, accuracy: 0.0001)
    }
}

final class LineSnappingTests: XCTestCase {
    func testStrongAxesDominateAndNarrowSnapsInBetween() {
        XCTAssertEqual(LineSnapping.angle(8), 0); XCTAssertEqual(LineSnapping.angle(-9.5), 0)
        XCTAssertEqual(LineSnapping.angle(82), 90); XCTAssertEqual(LineSnapping.angle(185), 180); XCTAssertEqual(LineSnapping.angle(-95), -90)
        XCTAssertEqual(LineSnapping.angle(41), 45); XCTAssertEqual(LineSnapping.angle(139), 135); XCTAssertEqual(LineSnapping.angle(-49), -45)
        XCTAssertEqual(LineSnapping.angle(33), 30); XCTAssertEqual(LineSnapping.angle(57), 60)
        XCTAssertEqual(LineSnapping.angle(122), 120); XCTAssertEqual(LineSnapping.angle(151), 150); XCTAssertEqual(LineSnapping.angle(-27), -30)
        // Away from every snap: unchanged.
        XCTAssertEqual(LineSnapping.angle(15), 15); XCTAssertEqual(LineSnapping.angle(38), 38)
        XCTAssertEqual(LineSnapping.angle(52), 52); XCTAssertEqual(LineSnapping.angle(70), 70); XCTAssertEqual(LineSnapping.angle(105), 105)
        // The weak bands stay narrower than the strong one.
        XCTAssertLessThan(LineSnapping.diagonalTolerance, LineSnapping.strongTolerance)
        XCTAssertLessThan(LineSnapping.thirtyTolerance, LineSnapping.strongTolerance)
    }
    func testEndKeepsStartAndLengthAndIsExactOnAxes() {
        let start = PagePoint(x: 10, y: 20)
        let level = LineSnapping.end(from: start, to: .init(x: 110, y: 27))
        XCTAssertEqual(level.y, 20); XCTAssertEqual(level.x, 10 + hypot(100, 7), accuracy: 1e-9)
        let up = LineSnapping.end(from: start, to: .init(x: 14, y: -80))
        XCTAssertEqual(up.x, 10); XCTAssertLessThan(up.y, 20)
        let diagonal = LineSnapping.end(from: start, to: .init(x: 110, y: 113))
        XCTAssertEqual(diagonal.x - start.x, diagonal.y - start.y, accuracy: 1e-9)
        let free = LineSnapping.end(from: start, to: .init(x: 110, y: 60))
        XCTAssertEqual(free.x, 110, accuracy: 1e-9); XCTAssertEqual(free.y, 60, accuracy: 1e-9)
        XCTAssertEqual(LineSnapping.end(from: start, to: start), start)
    }
    func testFitFollowsDrawingDirection() throws {
        let back = try XCTUnwrap(LineSnapping.fit((0...10).map { PagePoint(x: 200 - Double($0) * 10, y: 50 + Double($0) * 10 * tan(31 * .pi / 180)) }))
        XCTAssertGreaterThan(back.start.x, back.end.x)
        XCTAssertEqual(atan2(back.end.y - back.start.y, back.end.x - back.start.x) * 180 / .pi, 150, accuracy: 0.0001)
        XCTAssertNil(LineSnapping.fit([]))
    }
    func testStraightStrokeSamplesByArcLengthNotByHoldDuration() {
        // 11 drawn points over 100 pt, then 40 stationary points from holding still.
        let drawn = (0...10).map { PagePoint(x: Double($0) * 10, y: 0) } + Array(repeating: PagePoint(x: 100, y: 0), count: 40)
        let indices = StraightStroke.sampleIndices(along: drawn, count: 11)
        XCTAssertEqual(indices.count, 11)
        XCTAssertEqual(Array(indices.prefix(10)), Array(0...9))
        XCTAssertEqual(indices.last, 10)
        XCTAssertEqual(indices, indices.sorted())
        XCTAssertEqual(StraightStroke.sampleIndices(along: [.init(x: 1, y: 1)], count: 3), [0, 0, 0])
        XCTAssertEqual(StraightStroke.sampleIndices(along: Array(repeating: .init(x: 1, y: 1), count: 5), count: 3), [0, 2, 4])
        XCTAssertTrue(StraightStroke.sampleIndices(along: [], count: 3).isEmpty)
    }
}
