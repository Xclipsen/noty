import Foundation
import XCTest
@testable import NotebookCore

/// Regressions for the eraser and lasso audits of 7f8bfe7.
final class EraserLassoAuditTests: XCTestCase {
    private func p(_ x: Double, _ y: Double) -> PagePoint { PagePoint(x: x, y: y) }
    /// Back-and-forth passes along x, drifting downwards by `drift` per pass.
    private func hatch(from: Double, to: Double, y: Double, passes: Int, drift: Double) -> [PagePoint] {
        var points: [PagePoint] = []
        for pass in 0..<passes {
            let forward = pass % 2 == 0
            for i in 0...25 {
                let t = Double(i) / 25
                points.append(p(forward ? from + (to - from) * t : to - (to - from) * t, y + Double(pass) * drift))
            }
        }
        return points
    }
    private func word(_ x: Double, _ y: Double) -> [PagePoint] {
        (0...30).map { i -> PagePoint in let t = Double(i); return p(x + t * 2, y + sin(t / 3) * 6) }
    }
    private func polyline(_ corners: [PagePoint]) -> [PagePoint] {
        zip(corners, corners.dropFirst()).flatMap { a, b in (0..<10).map { i -> PagePoint in
            let t = Double(i) / 10; return p(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t) } } + [corners.last!]
    }
    private func rows(over x: ClosedRange<Double>, y: ClosedRange<Double>) -> [PagePoint] {
        var points: [PagePoint] = []
        for row in 0...14 {
            let py = y.lowerBound + (y.upperBound - y.lowerBound) * Double(row) / 14
            let from = row.isMultiple(of: 2) ? x.lowerBound : x.upperBound, to = row.isMultiple(of: 2) ? x.upperBound : x.lowerBound
            for step in 0...6 { points.append(p(from + (to - from) * Double(step) / 6, py)) }
        }
        return points
    }

    // MARK: Radierer Fund 1 – Schraffur ist kein Durchkritzeln

    func testShadingInsideAShapeKeepsTheShapeItsLabelAndItself() {
        let box = ShapeObject(kind: .rectangle, start: p(100, 100), end: p(200, 160))
        let label = word(120, 130)
        // Shading 3 pt inside the edges, as in the audit.
        let shading = hatch(from: 103, to: 197, y: 103, passes: 18, drift: 3)
        XCTAssertTrue(ScribbleErase.isScribble(shading), "shading still looks like a scribble")
        XCTAssertEqual(ScribbleErase.coveredShapes(scribble: shading, shapes: [box], padding: 4), [box.id], "the old rule took the frame")
        let erased = ScribbleErase.erasure(scribble: shading, strokes: [label], strokeWidths: [2], shapes: [box], padding: 4, reach: 2)
        XCTAssertEqual(erased.strokes, [])
        XCTAssertEqual(erased.shapes, [])
        // Filled shape: the same.
        var filled = box; filled.fill = InkColor(0, 0, 1, 0.2)
        XCTAssertEqual(ScribbleErase.erasure(scribble: shading, strokes: [label], shapes: [filled], padding: 4, reach: 2).strokes, [])
    }

    func testShadingInsideAHandDrawnFrameKeepsFrameAndLabel() {
        let frame = polyline([p(100, 100), p(200, 100), p(200, 160), p(100, 160), p(100, 100)])
        let label = word(120, 130)
        let shading = hatch(from: 103, to: 197, y: 103, passes: 18, drift: 3)
        XCTAssertEqual(Set(ScribbleErase.coveredStrokes(scribble: shading, strokes: [frame, label], padding: 4)), [0, 1], "the old rule took both")
        let erased = ScribbleErase.erasure(scribble: shading, strokes: [frame, label], strokeWidths: [2, 2], shapes: [], padding: 4, reach: 2)
        XCTAssertEqual(erased.strokes, [])
    }

    func testScribbleOverAWordInsideALargeFrameStillErasesTheWord() {
        let page = ShapeObject(kind: .rectangle, start: p(0, 0), end: p(500, 700))
        let target = word(120, 105), elsewhere = word(300, 400)
        let scribble = hatch(from: 100, to: 200, y: 100, passes: 8, drift: 2)
        XCTAssertTrue(ScribbleErase.isScribble(scribble))
        let erased = ScribbleErase.erasure(scribble: scribble, strokes: [target, elsewhere], strokeWidths: [2, 2], shapes: [page], padding: 4, reach: 2)
        XCTAssertEqual(erased.strokes, [0])
        XCTAssertEqual(erased.shapes, [])
    }

    func testScribbleOverAndBeyondShapesStillRemovesThem() {
        let line = ShapeObject(kind: .line, start: p(110, 120), end: p(190, 130))
        let box = ShapeObject(kind: .rectangle, start: p(120, 110), end: p(180, 140))
        let far = ShapeObject(kind: .ellipse, start: p(400, 400), end: p(460, 440))
        let half = ShapeObject(kind: .line, start: p(150, 125), end: p(450, 125))
        let points = rows(over: 100...200, y: 100...150)
        XCTAssertTrue(ScribbleErase.isScribble(points))
        let erased = ScribbleErase.erasure(scribble: points, strokes: [], shapes: [line, box, far, half], padding: 4, reach: 2)
        XCTAssertEqual(Set(erased.shapes), [line.id, box.id])
    }

    func testOnlyInkTheScribbleReachesIsErased() {
        let points = rows(over: 100...200, y: 100...150)
        // Rows lie 3.57 pt apart; a dash between two rows is never touched.
        let between = polyline([p(140, 123.2), p(160, 123.2)])
        let crossed = polyline([p(150, 105), p(150, 145)])
        let erased = ScribbleErase.erasure(scribble: points, strokes: [between, crossed], strokeWidths: [0, 0], shapes: [], padding: 4, reach: 1)
        XCTAssertEqual(erased.strokes, [1])
    }

    // MARK: Radierer Fund 2 – Linien mit gespeicherter Füllung

    func testLinesWithAStoredFillAreCutByThePrecisionEraser() {
        let line = ShapeObject(kind: .line, start: p(0, 0), end: p(100, 0), fill: InkColor(1, 0, 0, 0.2))
        XCTAssertFalse(line.hasVisibleFill)
        XCTAssertTrue(ShapeEraseMask.canErasePartially(line))
        let arrow = ShapeObject(kind: .arrow, start: p(0, 0), end: p(100, 0), fill: InkColor(1, 0, 0, 0.2))
        XCTAssertTrue(ShapeEraseMask.canErasePartially(arrow))
        var mask = ShapeEraseMask(line)
        XCTAssertTrue(mask.erase(from: p(50, -10), to: p(50, 10), radius: 3))
        XCTAssertEqual(mask.runs.count, 2, "cut in the middle, not removed whole")
        // A visible fill keeps removing the shape whole; strength 0 is no fill.
        let filled = ShapeObject(kind: .rectangle, start: p(0, 0), end: p(50, 50), fill: InkColor(1, 0, 0, 0.2))
        XCTAssertFalse(ShapeEraseMask.canErasePartially(filled))
        var clear = filled; clear.fill = InkColor(1, 0, 0, 0)
        XCTAssertTrue(ShapeEraseMask.canErasePartially(clear))
    }

    // MARK: Lasso Fund 6 – Nicht-Null-Windung

    private func spiral(turns: Double, from r0: Double, to r1: Double, center: PagePoint = PagePoint(x: 200, y: 200)) -> [PagePoint] {
        let count = Int(turns * 120)
        return (0...count).map { i in
            let t = Double(i) / Double(count), angle = t * turns * 2 * .pi, r = r0 + (r1 - r0) * t
            return PagePoint(x: center.x + r * cos(angle), y: center.y + r * sin(angle))
        }
    }

    func testLassoDrawnTwiceAroundContentSelectsIt() {
        let lasso = LassoRegion(points: spiral(turns: 2, from: 60, to: 50))
        let inner = word(185, 200)
        XCTAssertTrue(lasso.contains(p(200, 200)))
        XCTAssertTrue(lasso.intersectsPolyline(inner))
        XCTAssertTrue(lasso.containsPolyline(inner))
        XCTAssertFalse(lasso.contains(p(300, 200)))
    }

    func testOvershootingTheStartKeepsTheDoublyWoundStrip() {
        // 420°: radius 50 → 40; between the first and the second pass at 30°.
        let lasso = LassoRegion(points: spiral(turns: 420.0 / 360, from: 50, to: 40))
        let angle = 30.0 * .pi / 180
        XCTAssertTrue(lasso.contains(p(200 + 45 * cos(angle), 200 + 45 * sin(angle))))
        XCTAssertTrue(lasso.contains(p(200, 200)))
    }

    // MARK: Lasso Leistung – gleiche Ergebnisse wie vorher

    /// The former polyline test (every path point against every edge), with the same `contains`.
    private func reference(_ lasso: LassoRegion, _ path: [PagePoint], radius: Double, closed: Bool) -> Bool {
        let points = lasso.points
        guard points.count >= 3, !path.isEmpty else { return false }
        if path.contains(where: lasso.contains) { return true }
        if closed, points.contains(where: LassoRegion(points: path).contains) { return true }
        func distance(_ q: PagePoint, _ a: PagePoint, _ b: PagePoint) -> Double {
            let dx = b.x - a.x, dy = b.y - a.y
            let t = min(1, max(0, ((q.x - a.x) * dx + (q.y - a.y) * dy) / max(0.00000001, dx * dx + dy * dy)))
            return hypot(q.x - a.x - t * dx, q.y - a.y - t * dy)
        }
        func side(_ a: PagePoint, _ b: PagePoint, _ q: PagePoint) -> Double { (b.x - a.x) * (q.y - a.y) - (b.y - a.y) * (q.x - a.x) }
        for edge in points.indices {
            let a = points[edge], b = points[(edge + 1) % points.count]
            for q in path where distance(q, a, b) <= radius + 0.0001 { return true }
            let count = closed ? path.count : path.count - 1
            for index in 0..<count {
                let c = path[index], d = path[(index + 1) % path.count]
                if side(a, b, c) * side(a, b, d) < 0, side(c, d, a) * side(c, d, b) < 0 { return true }
                if distance(a, c, d) <= radius + 0.0001 || distance(b, c, d) <= radius + 0.0001 { return true }
            }
        }
        return false
    }

    func testFasterPolylineTestGivesTheFormerResults() {
        var generator = SystemRandomNumberGenerator()
        func random(_ range: ClosedRange<Double>) -> Double { Double.random(in: range, using: &generator) }
        for _ in 0..<300 {
            let center = p(random(100...300), random(100...300))
            let lasso = LassoRegion(points: (0..<Int(random(3...40))).map { i in
                let angle = Double(i) * random(0.2...1.2), r = random(20...120)
                return p(center.x + r * cos(angle), center.y + r * sin(angle))
            })
            let start = p(random(0...400), random(0...400))
            var path = [start]
            for _ in 0..<Int(random(0...20)) { path.append(p(path.last!.x + random(-15...15), path.last!.y + random(-15...15))) }
            let radius = [0.0, 1, 4].randomElement(using: &generator)!
            for closed in [false, true] {
                XCTAssertEqual(lasso.intersectsPolyline(path, radius: radius, closed: closed), reference(lasso, path, radius: radius, closed: closed))
            }
        }
    }

    func testConcaveLassoOverManyStrokesIsQuick() {
        // A comb-shaped lasso of about 600 points; 1500 short strokes in the gaps between its teeth.
        var outline: [PagePoint] = []
        for tooth in 0..<150 {
            let x = Double(tooth) * 4
            outline += [p(x, 0), p(x, 400), p(x + 2, 400), p(x + 2, 0)]
        }
        outline += [p(600, -100), p(0, -100)]
        let lasso = LassoRegion(points: outline)
        let strokes = (0..<1500).map { i -> [PagePoint] in
            let x = Double(i % 150) * 4 + 3, y = 20 + Double(i / 150) * 30
            return (0...20).map { p(x, y + Double($0)) }
        }
        let start = Date()
        let hits = strokes.filter { lasso.intersectsPolyline($0, radius: 0.5) }.count
        XCTAssertEqual(hits, 0)
        XCTAssertLessThan(Date().timeIntervalSince(start), 5, "debug build, generous bound")
    }

    // MARK: Lasso Fund 5 – gedrehte Bilder

    func testRotatedImageIsSelectedByItselfNotItsBounds() {
        let image = ImageObject(asset: ImageAssetReference(of: Data([1])), pixelWidth: 100, pixelHeight: 100,
                                x: 100, y: 100, width: 100, height: 100, rotation: 45)
        let bounds = image.rotatedBounds
        XCTAssertLessThan(bounds.x, 80)
        let corner = LassoRegion(points: [p(82, 82), p(92, 82), p(92, 92), p(82, 92)])
        XCTAssertTrue(corner.intersects(bounds), "the empty corner lies in the bounds")
        XCTAssertFalse(corner.selects(image))
        XCTAssertFalse(PageObjectHitTest.hits(image, at: p(87, 87)), "like a tap")
        XCTAssertTrue(LassoRegion(points: [p(145, 145), p(155, 145), p(155, 155), p(145, 155)]).selects(image))
        XCTAssertTrue(LassoRegion(points: [p(60, 60), p(240, 60), p(240, 240), p(60, 240)]).selects(image))
        // Its corners: the top corner straight above the centre.
        XCTAssertEqual(image.rotatedCorners.map(\.y).min()!, 150 - 50 * 2.squareRoot(), accuracy: 0.0001)
    }

    // MARK: Lasso Fund 2 – automatische Textfarbe umfärben

    func testRecolouringAnAutomaticColourFieldStaysValid() throws {
        var style = TextBoxStyle(color: .black); style.automaticColor = true
        var box = TextBox(text: "Hallo", style: style)
        box.runs = [TextRun(location: 0, length: 2, style: style)]
        var broken = box; broken.style.ink = InkColor(1, 0, 0)
        XCTAssertThrowsError(try broken.style.validate(), "the former recolouring")
        let red = box.recolored(InkColor(1, 0, 0))
        XCTAssertNoThrow(try red.style.validate())
        XCTAssertNoThrow(try red.runs?.forEach { try $0.style.validate() })
        XCTAssertNil(red.style.automaticColor)
        XCTAssertEqual(red.style.ink, InkColor(1, 0, 0))
        XCTAssertEqual(red.runs?.first?.style.ink, InkColor(1, 0, 0))
        XCTAssertNoThrow(try red.validate())
    }

    // MARK: Lasso Fund 7 – Versatz von Kopien

    func testCopiesNeverLandOnTheOriginal() {
        let page = PageRect(x: 0, y: 0, width: 600, height: 800)
        let middle = PasteOffset.offset(for: PageRect(x: 100, y: 100, width: 50, height: 50), in: page)
        XCTAssertEqual(middle.dx, 24); XCTAssertEqual(middle.dy, 24)
        let corner = PasteOffset.offset(for: PageRect(x: 550, y: 750, width: 50, height: 50), in: page)
        XCTAssertEqual(corner.dx, -24); XCTAssertEqual(corner.dy, -24)
        let tight = PasteOffset.offset(for: PageRect(x: 15, y: 0, width: 580, height: 50), in: page)
        XCTAssertEqual(tight.dx, -15, "as far as the page allows")
        let full = PasteOffset.offset(for: PageRect(x: 0, y: 0, width: 600, height: 50), in: page)
        XCTAssertEqual(full.dx, 0)
        let outside = PasteOffset.offset(for: PageRect(x: -20, y: 790, width: 50, height: 50), in: page)
        XCTAssertEqual(outside.dx, 20); XCTAssertEqual(outside.dy, -40)
    }
}
