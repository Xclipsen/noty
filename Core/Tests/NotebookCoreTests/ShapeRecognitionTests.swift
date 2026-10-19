import Foundation
import XCTest
@testable import NotebookCore

final class ShapeRecognitionTests: XCTestCase {
    /// Hand-like stroke through the given corners: dense samples plus a small deterministic wobble.
    private func stroke(_ corners: [PagePoint], closed: Bool = true, wobble: Double = 1.2, step: Double = 4) -> [PagePoint] {
        let path = closed ? corners + [corners[0]] : corners
        var result: [PagePoint] = [], index = 0
        for (a, b) in zip(path, path.dropFirst()) {
            let count = max(1, Int(hypot(b.x - a.x, b.y - a.y) / step))
            for i in 0..<count {
                let t = Double(i) / Double(count); index += 1
                result.append(.init(x: a.x + (b.x - a.x) * t + sin(Double(index) * 1.7) * wobble, y: a.y + (b.y - a.y) * t + cos(Double(index) * 2.3) * wobble))
            }
        }
        return result + [path.last!]
    }
    private func ellipse(cx: Double, cy: Double, rx: Double, ry: Double, degrees: Double = 0, wobble: Double = 1) -> [PagePoint] {
        let r = degrees * .pi / 180
        return (0...72).map { i in
            let t = Double(i) / 72 * 2 * .pi, a = rx * cos(t) + sin(Double(i) * 1.3) * wobble, b = ry * sin(t)
            return .init(x: cx + a * cos(r) - b * sin(r), y: cy + a * sin(r) + b * cos(r))
        }
    }
    private func regular(_ n: Int, radius: Double, start: Double = -90, center: PagePoint = .init(x: 300, y: 300), radii: [Double]? = nil) -> [PagePoint] {
        (0..<n).map { k in
            let angle = (start + Double(k) * 360 / Double(n)) * .pi / 180, r = radii?[k % radii!.count] ?? radius
            return .init(x: center.x + r * cos(angle), y: center.y + r * sin(angle))
        }
    }
    private func kind(_ shape: RecognizedShape?) -> PolygonKind? { if case let .polygon(kind, _)? = shape { return kind }; return nil }
    private func edgeAngles(_ shape: RecognizedShape?) -> [Double] {
        guard case let .polygon(_, v)? = shape else { return [] }
        return zip(v, v.dropFirst() + [v[0]]).map { atan2($1.y - $0.y, $1.x - $0.x) * 180 / .pi }
    }

    func testRoundOutlinesBecomeCircles() throws {
        guard case let .ellipse(_, rx, ry, _)? = ShapeRecognition.shape(ellipse(cx: 200, cy: 200, rx: 60, ry: 57)) else { return XCTFail("circle") }
        XCTAssertEqual(rx, ry)
        // Ovals (also tilted) become a centred circle of the mean drawn radius; ellipses belong to the shape tool.
        for degrees in [0.0, 6, 32] {
            guard case let .ellipse(center, rx, ry, rotation)? = ShapeRecognition.shape(ellipse(cx: 200, cy: 200, rx: 80, ry: 40, degrees: degrees)) else { return XCTFail("oval \(degrees)") }
            XCTAssertEqual(rx, ry); XCTAssertEqual(rotation, 0)
            XCTAssertEqual(center.x, 200, accuracy: 3); XCTAssertEqual(center.y, 200, accuracy: 3)
            XCTAssertGreaterThan(rx, 40); XCTAssertLessThan(rx, 80)
        }
        let object = try XCTUnwrap(ShapeRecognition.shape(ellipse(cx: 200, cy: 200, rx: 80, ry: 40))?.object(color: InkColor(0, 0, 0), lineWidth: 2))
        XCTAssertEqual(object.kind, .ellipse); XCTAssertEqual(object.frame.width, object.frame.height, accuracy: 1e-9)
        XCTAssertEqual(ShapeRecognition.recognize(ellipse(cx: 200, cy: 200, rx: 70, ry: 40)), .ellipse)
    }
    func testSquareRectangleAndRotatedRectangle() throws {
        let square = ShapeRecognition.shape(stroke([.init(x: 100, y: 100), .init(x: 196, y: 103), .init(x: 194, y: 197), .init(x: 102, y: 195)]))
        XCTAssertEqual(kind(square), .square)
        let object = try XCTUnwrap(square?.object(color: InkColor(0, 0, 0), lineWidth: 3))
        XCTAssertEqual(object.kind, .rectangle); XCTAssertEqual(object.frame.width, object.frame.height, accuracy: 1e-9)
        let rectangle = ShapeRecognition.shape(stroke([.init(x: 100, y: 100), .init(x: 300, y: 100), .init(x: 300, y: 180), .init(x: 100, y: 180)]))
        XCTAssertEqual(kind(rectangle), .rectangle)
        XCTAssertEqual(rectangle.flatMap { $0.object(color: InkColor(0, 0, 0), lineWidth: 2) }?.kind, .rectangle)
        // 20° stays rotated: native outline, not an axis-aligned object.
        let rotated = ShapeRecognition.shape(stroke(regular(4, radius: 1, start: 0).enumerated().map { i, _ in
            let corners = [(-100.0, -40.0), (100, -40), (100, 40), (-100, 40)], r = 20 * Double.pi / 180, c = corners[i]
            return PagePoint(x: 300 + c.0 * cos(r) - c.1 * sin(r), y: 300 + c.0 * sin(r) + c.1 * cos(r))
        }))
        XCTAssertEqual(kind(rotated), .rectangle)
        XCTAssertNil(rotated?.object(color: InkColor(0, 0, 0), lineWidth: 2))
        XCTAssertEqual(ShapeRecognition.recognize([.init(x: 50, y: 50), .init(x: 150, y: 50), .init(x: 150, y: 150), .init(x: 50, y: 150), .init(x: 50, y: 50)]), .rectangle)
    }
    private func sideLengths(_ shape: RecognizedShape?) -> [Double] {
        guard case let .polygon(_, v)? = shape else { return [] }
        return zip(v, v.dropFirst() + [v[0]]).map { hypot($1.x - $0.x, $1.y - $0.y) }
    }
    func testTriangles() {
        // Obtuse, all sides different: stays a clean straight-edged triangle.
        let triangle = ShapeRecognition.shape(stroke([.init(x: 100, y: 300), .init(x: 320, y: 297), .init(x: 174, y: 233)]))
        XCTAssertEqual(kind(triangle), .triangle)
        XCTAssertTrue(edgeAngles(triangle).contains { abs($0) < 1e-9 || abs(abs($0) - 180) < 1e-9 }, "base snaps level")
        // Roughly equal angles (73°/59°/48°) become equilateral.
        let equilateral = ShapeRecognition.shape(stroke([.init(x: 100, y: 300), .init(x: 260, y: 297), .init(x: 150, y: 120)]))
        XCTAssertEqual(kind(equilateral), .equilateralTriangle)
        XCTAssertEqual(Set(sideLengths(equilateral).map { ($0 * 1e6).rounded() }).count, 1)
        // Two sides within 20 %: isosceles with a level base.
        let isosceles = ShapeRecognition.shape(stroke([.init(x: 200, y: 100), .init(x: 268, y: 302), .init(x: 130, y: 298)]))
        XCTAssertEqual(kind(isosceles), .isoscelesTriangle)
        if case let .polygon(_, v)? = isosceles {
            XCTAssertEqual(hypot(v[1].x - v[0].x, v[1].y - v[0].y), hypot(v[2].x - v[0].x, v[2].y - v[0].y), accuracy: 1e-6)
            XCTAssertEqual(v[1].y, v[2].y, accuracy: 1e-9)
        }
        // Legs within 25 % around a right angle: isosceles right triangle.
        let isoRight = ShapeRecognition.shape(stroke([.init(x: 100, y: 100), .init(x: 104, y: 250), .init(x: 236, y: 246)]))
        XCTAssertEqual(kind(isoRight), .rightTriangle)
        if case let .polygon(_, v)? = isoRight {
            XCTAssertEqual(hypot(v[0].x - v[1].x, v[0].y - v[1].y), hypot(v[2].x - v[1].x, v[2].y - v[1].y), accuracy: 1e-6)
        }
        let right = ShapeRecognition.shape(stroke([.init(x: 100, y: 100), .init(x: 103, y: 260), .init(x: 240, y: 258)]))
        XCTAssertEqual(kind(right), .rightTriangle)
        if case let .polygon(_, v)? = right {
            let a = (x: v[0].x - v[1].x, y: v[0].y - v[1].y), b = (x: v[2].x - v[1].x, y: v[2].y - v[1].y)
            XCTAssertEqual(a.x * b.x + a.y * b.y, 0, accuracy: 1e-6)
            XCTAssertEqual(v[0].x, v[1].x, accuracy: 1e-9); XCTAssertEqual(v[1].y, v[2].y, accuracy: 1e-9)
        }
        XCTAssertEqual(kind(ShapeRecognition.shape(stroke(regular(3, radius: 90)))), .equilateralTriangle)
    }
    func testQuadrilateralsAreRegularised() {
        // Sides within 25 % and right angles: a square.
        let square = ShapeRecognition.shape(stroke([.init(x: 100, y: 100), .init(x: 220, y: 104), .init(x: 216, y: 200), .init(x: 98, y: 196)], wobble: 2))
        XCTAssertEqual(kind(square), .square)
        XCTAssertEqual(Set(sideLengths(square).map { ($0 * 1e6).rounded() }).count, 1)
        // Both side pairs parallel, unequal sides, slanted: parallelogram with level base.
        let parallelogram = ShapeRecognition.shape(stroke([.init(x: 100, y: 100), .init(x: 300, y: 103), .init(x: 352, y: 182), .init(x: 150, y: 180)], wobble: 2))
        XCTAssertEqual(kind(parallelogram), .parallelogram)
        if case let .polygon(_, v)? = parallelogram {
            let sorted = v.sorted { $0.y < $1.y }
            XCTAssertEqual(sorted[0].y, sorted[1].y, accuracy: 1e-9); XCTAssertEqual(sorted[2].y, sorted[3].y, accuracy: 1e-9)
            XCTAssertEqual(abs(sorted[1].x - sorted[0].x), abs(sorted[3].x - sorted[2].x), accuracy: 1e-6)
        }
        // One parallel pair: symmetric trapezoid.
        let trapezoid = ShapeRecognition.shape(stroke([.init(x: 150, y: 100), .init(x: 254, y: 98), .init(x: 318, y: 222), .init(x: 80, y: 218)], wobble: 2))
        XCTAssertEqual(kind(trapezoid), .trapezoid)
        if case let .polygon(_, v)? = trapezoid {
            let sorted = v.sorted { $0.y < $1.y }
            XCTAssertEqual(sorted[0].y, sorted[1].y, accuracy: 1e-9); XCTAssertEqual(sorted[2].y, sorted[3].y, accuracy: 1e-9)
            XCTAssertEqual(sorted[0].x + sorted[1].x, sorted[2].x + sorted[3].x, accuracy: 1e-6, "symmetric")
        }
        // A kite-like irregular quad keeps straight edges only.
        XCTAssertEqual(kind(ShapeRecognition.shape(stroke([.init(x: 100, y: 100), .init(x: 300, y: 130), .init(x: 260, y: 260), .init(x: 120, y: 200)], wobble: 2))), .quadrilateral)
    }
    func testRegularisationBoundaries() {
        func box(_ w: Double, _ h: Double) -> RecognizedShape? {
            ShapeRecognition.shape(stroke([.init(x: 100, y: 100), .init(x: 100 + w, y: 100), .init(x: 100 + w, y: 100 + h), .init(x: 100, y: 100 + h)]))
        }
        XCTAssertEqual(kind(box(150, 120)), .square, "sides 80 %")
        XCTAssertEqual(kind(box(150, 95)), .rectangle, "sides 63 %")
        // Right triangle with clearly unequal legs keeps their lengths.
        let right = ShapeRecognition.shape(stroke([.init(x: 100, y: 100), .init(x: 100, y: 300), .init(x: 210, y: 300)]))
        XCTAssertEqual(kind(right), .rightTriangle)
        let legs = sideLengths(right).sorted()
        XCTAssertEqual(legs[0], 110, accuracy: 3); XCTAssertEqual(legs[1], 200, accuracy: 3)
        // Rhombus needs near-equal sides; a long parallelogram is not one.
        XCTAssertEqual(kind(ShapeRecognition.shape(stroke([.init(x: 300, y: 200), .init(x: 380, y: 300), .init(x: 300, y: 400), .init(x: 220, y: 300)]))), .rhombus)
        // Round outlines never become polygons and vice versa.
        XCTAssertFalse(isEllipse(ShapeRecognition.shape(stroke(regular(6, radius: 100)))))
    }
    func testRhombusPentagonHexagonAndStars() {
        let diamond = ShapeRecognition.shape(stroke([.init(x: 300, y: 200), .init(x: 362, y: 300), .init(x: 300, y: 398), .init(x: 240, y: 300)]))
        XCTAssertEqual(kind(diamond), .rhombus)
        if case let .polygon(_, v)? = diamond { XCTAssertEqual(v[0].x, v[2].x, accuracy: 1e-9); XCTAssertEqual(v[1].y, v[3].y, accuracy: 1e-9) }
        let pentagon = ShapeRecognition.shape(stroke(regular(5, radius: 100, start: -88)))
        XCTAssertEqual(kind(pentagon), .pentagon)
        XCTAssertTrue(edgeAngles(pentagon).contains { abs($0) < 1e-9 || abs(abs($0) - 180) < 1e-9 }, "flat edge snaps level")
        XCTAssertEqual(kind(ShapeRecognition.shape(stroke(regular(6, radius: 100, start: 2)))), .hexagon)
        XCTAssertEqual(kind(ShapeRecognition.shape(stroke(regular(10, radius: 100, radii: [110, 45])))), .star)
        let tips = regular(5, radius: 110, start: -92)
        XCTAssertEqual(kind(ShapeRecognition.shape(stroke([tips[0], tips[2], tips[4], tips[1], tips[3]]))), .star)
    }
    func testLinesAndArrowsSnap() {
        guard case let .line(start, end)? = ShapeRecognition.shape((0...30).map { PagePoint(x: Double($0) * 4, y: 80 + Double($0) * 0.2) }) else { return XCTFail("line") }
        XCTAssertEqual(start.y, end.y)
        let shaft = (0...30).map { PagePoint(x: Double($0) * 5, y: 100 + Double($0) * 0.3) }
        let wings = [PagePoint(x: 135, y: 92), .init(x: 150, y: 109), .init(x: 135, y: 124)]
        guard case let .arrow(_, tip)? = ShapeRecognition.shape(shaft + wings) else { return XCTFail("arrow") }
        XCTAssertEqual(tip.y, 100)
    }
    func testScribblesAndWritingStayFreehand() {
        XCTAssertNil(ShapeRecognition.shape((0...50).map { .init(x: Double($0) * 4, y: Double($0 % 7) * 15) }))
        // "mmm": arches along a baseline.
        XCTAssertNil(ShapeRecognition.shape((0...90).map { i -> PagePoint in PagePoint(x: Double(i) * 2, y: 100 - abs(sin(Double(i) / 10)) * 30) }))
        // Closed random scribble.
        let scribble = (0...80).map { i -> PagePoint in
            let t = Double(i)
            let x: Double = 200 + sin(t * 0.9) * 60 + cos(t * 2.1) * 30
            return PagePoint(x: x, y: 200 + cos(t * 1.3) * 50)
        }
        XCTAssertNil(ShapeRecognition.shape(scribble + [scribble[0]]))
        // Figure eight and a lumpy blob with a dent stay freehand.
        XCTAssertNil(ShapeRecognition.shape((0...96).map { i -> PagePoint in let t = Double(i) / 96 * 2 * .pi; return PagePoint(x: 200 + 60 * sin(t), y: 200 + 90 * sin(t) * cos(t)) }))
        XCTAssertNil(ShapeRecognition.shape((0...96).map { i -> PagePoint in
            let t = Double(i) / 96 * 2 * .pi; let r = 80 * (1 - 0.45 * exp(-pow((t - 2) * 2.5, 2))) * (1 + 0.15 * sin(5 * t))
            return PagePoint(x: 200 + r * cos(t), y: 200 + r * sin(t))
        }))
        // Spiral does not close.
        XCTAssertNil(ShapeRecognition.shape((0...120).map { i -> PagePoint in let t = Double(i) / 10; return PagePoint(x: 200 + t * 8 * cos(t), y: 200 + t * 8 * sin(t)) }))
        XCTAssertNil(ShapeRecognition.shape([.init(x: 0, y: 0), .init(x: 1, y: 1)]))
    }
    func testOutlineRepeatsCornersAndCloses() {
        let outline = RecognizedShape.polygon(.square, [.init(x: 0, y: 0), .init(x: 40, y: 0), .init(x: 40, y: 40), .init(x: 0, y: 40)]).outline(spacing: 10)
        XCTAssertEqual(outline.first, outline.last)
        XCTAssertEqual(outline.filter { $0 == PagePoint(x: 40, y: 0) }.count, 3)
        let circle = RecognizedShape.ellipse(center: .init(x: 0, y: 0), radiusX: 50, radiusY: 50, degrees: 0).outline()
        XCTAssertEqual(circle.first, circle.last)
        XCTAssertTrue(circle.allSatisfy { abs(hypot($0.x, $0.y) - 50) < 1e-9 })
    }

    // MARK: Sloppy, everyday drawing

    /// Keeps the first `share` of a path (unclosed gap) or appends an overshoot.
    private func portion(_ points: [PagePoint], share: Double) -> [PagePoint] {
        if share <= 1 { return Array(points.prefix(Int(Double(points.count) * share))) }
        return points + Array(points.dropFirst().prefix(Int(Double(points.count) * (share - 1))))
    }
    private func lumpyCircle(radius: Double = 80, turns: Double = 1, wobble: Double = 4) -> [PagePoint] {
        (0...Int(96 * turns)).map { i -> PagePoint in
            let t = Double(i) / 96 * 2 * .pi
            let r = radius * (1 + 0.06 * sin(3 * t + 0.4)) + sin(Double(i) * 2.1) * wobble
            return PagePoint(x: 300 + r * cos(t), y: 300 + r * 0.95 * sin(t))
        }
    }
    private func isEllipse(_ shape: RecognizedShape?) -> Bool { if case .ellipse? = shape { return true }; return false }
    private func isRegular(_ shape: RecognizedShape?) -> Bool {
        guard case let .polygon(_, v)? = shape else { return false }
        let c = PagePoint(x: v.map(\.x).reduce(0, +) / Double(v.count), y: v.map(\.y).reduce(0, +) / Double(v.count))
        let radii = v.map { hypot($0.x - c.x, $0.y - c.y) }
        return radii.max()! - radii.min()! < 1e-6
    }
    func testSloppyCirclesWithGapOrOvershoot() {
        XCTAssertTrue(isEllipse(ShapeRecognition.shape(lumpyCircle())))
        XCTAssertTrue(isEllipse(ShapeRecognition.shape(lumpyCircle(turns: 0.85))), "15 % gap")
        XCTAssertTrue(isEllipse(ShapeRecognition.shape(lumpyCircle(turns: 1.15))), "overshoot")
        XCTAssertTrue(isEllipse(ShapeRecognition.shape(portion(ellipse(cx: 200, cy: 200, rx: 90, ry: 45, degrees: 4, wobble: 3), share: 0.84))))
    }
    func testSloppyRectanglesAndRoundedCorners() {
        let square = stroke([.init(x: 100, y: 104), .init(x: 205, y: 96), .init(x: 198, y: 203), .init(x: 95, y: 196)], wobble: 3)
        XCTAssertEqual(kind(ShapeRecognition.shape(square)), .square)
        XCTAssertEqual(kind(ShapeRecognition.shape(portion(square, share: 0.85))), .square, "15 % gap")
        XCTAssertEqual(kind(ShapeRecognition.shape(portion(square, share: 1.12))), .square, "overshoot")
        // Rounded corners (radius ~15 % of the short side).
        var rounded: [PagePoint] = []
        let corners = [(130.0, 130.0, -90.0), (270, 130, 0), (270, 200, 90), (130, 200, 180)]
        for (index, corner) in corners.enumerated() {
            for step in 0...6 { let a = (corner.2 - 90 + Double(step) * 15) * .pi / 180; rounded.append(.init(x: corner.0 + 20 * cos(a), y: corner.1 + 20 * sin(a))) }
            let next = corners[(index + 1) % 4], a = (corner.2) * .pi / 180, b = (next.2 - 90) * .pi / 180
            let from = PagePoint(x: corner.0 + 20 * cos(a), y: corner.1 + 20 * sin(a)), to = PagePoint(x: next.0 + 20 * cos(b), y: next.1 + 20 * sin(b))
            for step in 1..<10 { let t = Double(step) / 10; rounded.append(.init(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t)) }
        }
        XCTAssertEqual(kind(ShapeRecognition.shape(rounded + [rounded[0]])), .rectangle)
        XCTAssertEqual(kind(ShapeRecognition.shape(stroke([.init(x: 300, y: 196), .init(x: 368, y: 305), .init(x: 296, y: 402), .init(x: 236, y: 296)], wobble: 3))), .rhombus)
    }
    func testSloppyTriangles() {
        let triangle = stroke([.init(x: 100, y: 300), .init(x: 262, y: 290), .init(x: 160, y: 118)], wobble: 3)
        XCTAssertEqual(kind(ShapeRecognition.shape(triangle)), .equilateralTriangle)
        XCTAssertEqual(kind(ShapeRecognition.shape(portion(triangle, share: 0.85))), .equilateralTriangle, "15 % gap")
        let obtuse = stroke([.init(x: 100, y: 300), .init(x: 322, y: 297), .init(x: 176, y: 231)], wobble: 3)
        XCTAssertEqual(kind(ShapeRecognition.shape(portion(obtuse, share: 0.85))), .triangle, "15 % gap")
        XCTAssertEqual(kind(ShapeRecognition.shape(stroke([.init(x: 100, y: 100), .init(x: 110, y: 262), .init(x: 250, y: 250)], wobble: 3))), .rightTriangle)
    }
    func testRegularPolygonsUpToOctagon() {
        for (n, expected) in [(5, PolygonKind.pentagon), (6, .hexagon), (7, .heptagon), (8, .octagon)] {
            // Uneven corner radii and wobble still give a clean regular n-gon.
            let corners = regular(n, radius: 120, start: 7).enumerated().map { i, p -> PagePoint in
                let f = 1 + (i % 2 == 0 ? 0.06 : -0.05); return PagePoint(x: 300 + (p.x - 300) * f, y: 300 + (p.y - 300) * f)
            }
            let shape = ShapeRecognition.shape(stroke(corners, wobble: 2))
            XCTAssertEqual(kind(shape), expected, "\(n)-gon")
            XCTAssertTrue(isRegular(shape), "\(n)-gon regular")
        }
    }
}

