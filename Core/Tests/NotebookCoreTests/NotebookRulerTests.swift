import XCTest
@testable import NotebookCore

final class NotebookRulerTests: XCTestCase {
    private func point(_ x: Double, _ y: Double) -> PagePoint { PagePoint(x: x, y: y) }

    func testTheBandAndItsEdges() {
        let ruler = NotebookRuler(x: 500, y: 300)
        XCTAssertTrue(ruler.contains(point(5, 340)), "it runs across the whole screen")
        XCTAssertFalse(ruler.contains(point(500, 350)))
        XCTAssertEqual(ruler.side(of: point(500, 900)), 1, "every stroke has a side, also far away")
        XCTAssertEqual(ruler.side(of: point(500, 310)), 1, "on the band: the nearer edge")
        XCTAssertEqual(ruler.side(of: point(500, 10)), -1)
    }

    func testEdgeLineFollowsTheAngle() {
        let line = NotebookRuler(x: 0, y: 0, angle: 90).edgeLine(side: 1)
        XCTAssertEqual(line.start.x, -44, accuracy: 1e-9)
        XCTAssertEqual(line.start.y, 0, accuracy: 1e-9)
        XCTAssertEqual(line.outward.x, -1, accuracy: 1e-9)
        XCTAssertEqual(line.end.y, 100, accuracy: 1e-9)
    }

    func testAStrokeCannotCrossTheEdge() {
        let start = point(0, 100), outward = point(0, 1)
        XCTAssertEqual(NotebookRuler.kept(point(30, 140), start: start, outward: outward), point(30, 140), "free on its side")
        XCTAssertEqual(NotebookRuler.kept(point(30, 60), start: start, outward: outward), point(30, 100), "behind it the pen slides along")
        XCTAssertEqual(NotebookRuler.kept(point(30, 100), start: start, outward: outward), point(30, 100))
        // Turned by 45°: straight back onto the line.
        let turned = NotebookRuler.kept(point(0, 0), start: point(10, 0), outward: point(sqrt(0.5), sqrt(0.5)))
        XCTAssertEqual(turned.x, 5, accuracy: 1e-9)
        XCTAssertEqual(turned.y, 5, accuracy: 1e-9)
        XCTAssertEqual(NotebookRuler.kept(point(1, 1), start: point(2, 2), outward: point(0, 0)), point(1, 1))
    }

    func testTwoFingersTurnAboutTheirMiddle() {
        let ruler = NotebookRuler(x: 100, y: 100)
        let turned = ruler.transformed(from: (point(90, 100), point(110, 100)), to: (point(100, 90), point(100, 110)))
        XCTAssertEqual(turned.angle, 90, accuracy: 1e-9)
        XCTAssertEqual(turned.x, 100, accuracy: 1e-9)
        XCTAssertEqual(turned.y, 100, accuracy: 1e-9)
        let moved = ruler.transformed(from: (point(0, 0), point(10, 0)), to: (point(20, 30), point(30, 30)))
        XCTAssertEqual(moved.x, 120, accuracy: 1e-9)
        XCTAssertEqual(moved.y, 130, accuracy: 1e-9)
    }

    func testAngleStaysInOneHalfTurn() {
        XCTAssertEqual(NotebookRuler(x: 0, y: 0, angle: 190).angle, 10, accuracy: 1e-9)
        XCTAssertEqual(NotebookRuler(x: 0, y: 0, angle: -100).angle, 80, accuracy: 1e-9)
        XCTAssertEqual(NotebookRuler(x: 0, y: 0, angle: 90).angle, 90)
    }

    func testSnappingAndStayingOnTheScreen() {
        XCTAssertEqual(NotebookRuler(x: 0, y: 0, angle: 44).snapped.angle, 45)
        XCTAssertEqual(NotebookRuler(x: 0, y: 0, angle: 37).snapped.angle, 37)
        XCTAssertEqual(NotebookRuler(x: -50, y: 900).clamped(width: 800, height: 600), NotebookRuler(x: 40, y: 560))
    }
}
