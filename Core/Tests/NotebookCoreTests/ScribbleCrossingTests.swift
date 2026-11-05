import Foundation
import XCTest
@testable import NotebookCore

/// Durchkritzeln vs. Schraffur with generated handwriting (review of dc7d6f2):
/// wobbly pen lines, cursive words, dots, hand-drawn frames and scribbles
/// whose turns scatter around the ink, sampled every 3 pt like PencilKit's
/// `interpolatedPoints(by: .distance(3))`. Every case runs over 25 seeds.
final class ScribbleCrossingTests: XCTestCase {
    // MARK: Generated handwriting

    struct Rng {
        var state: UInt64
        mutating func next() -> Double {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return Double((z ^ (z >> 31)) >> 11) / Double(1 << 53)
        }
        mutating func range(_ a: Double, _ b: Double) -> Double { a + (b - a) * next() }
    }
    static let seeds: [UInt64] = Array(1...25)

    private func p(_ x: Double, _ y: Double) -> PagePoint { PagePoint(x: x, y: y) }

    /// Points every `spacing` pt along the polyline (PencilKit's interpolation).
    private func resampled(_ points: [PagePoint], spacing: Double = 3) -> [PagePoint] {
        guard var last = points.first else { return [] }
        var result = [last], carry = 0.0
        for b in points.dropFirst() {
            var a = last
            var length = hypot(b.x - a.x, b.y - a.y)
            while carry + length >= spacing, length > 0 {
                let t = (spacing - carry) / length
                a = p(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t)
                result.append(a); length = hypot(b.x - a.x, b.y - a.y); carry = 0
            }
            carry += length; last = b
        }
        if let end = points.last, let tail = result.last, hypot(end.x - tail.x, end.y - tail.y) > 0.5 { result.append(end) }
        return result
    }
    /// A hand-drawn path through `corners`: each leg slightly bowed, with tremor.
    private func hand(_ corners: [PagePoint], _ rng: inout Rng, bow: Double = 1.2, tremor: Double = 0.25) -> [PagePoint] {
        var dense: [PagePoint] = []
        for (a, b) in zip(corners, corners.dropFirst()) {
            let length = hypot(b.x - a.x, b.y - a.y), steps = max(1, Int(length.rounded(.up)))
            let n = (x: -(b.y - a.y) / max(length, 1e-9), y: (b.x - a.x) / max(length, 1e-9)), bend = rng.range(-bow, bow)
            for step in (dense.isEmpty ? 0 : 1)...steps {
                let t = Double(step) / Double(steps), off = sin(t * .pi) * bend
                dense.append(p(a.x + (b.x - a.x) * t + n.x * off + rng.range(-tremor, tremor),
                               a.y + (b.y - a.y) * t + n.y * off + rng.range(-tremor, tremor)))
            }
        }
        return resampled(dense)
    }
    private func line(_ a: PagePoint, _ b: PagePoint, _ rng: inout Rng) -> [PagePoint] { hand([a, b], &rng) }
    /// A cursive word as one stroke: `letters` loops of 5–9 pt (some 13 pt ascenders) on `baseline`.
    private func cursive(x: Double, baseline: Double, letters: Int, _ rng: inout Rng) -> [PagePoint] {
        var dense: [PagePoint] = []
        for letter in 0..<letters {
            let height = rng.next() < 0.25 ? rng.range(11, 14) : rng.range(5, 9), width = rng.range(6, 8)
            let x0 = x + Double(letter) * 7
            for step in 0..<24 {
                let t = Double(step) / 24
                dense.append(p(x0 + width * t + 2.2 * sin(2 * .pi * t) + rng.range(-0.2, 0.2),
                               baseline - height * (1 - cos(2 * .pi * t)) / 2 + rng.range(-0.2, 0.2)))
            }
        }
        dense.append(p(x + Double(letters) * 7 + 2, baseline))
        return resampled(dense)
    }
    /// Printed letters as separate strokes (l, o, e, i-stem, n), 7 pt apart.
    private func printed(x: Double, baseline: Double, letters: Int, _ rng: inout Rng) -> [[PagePoint]] {
        (0..<letters).map { letter in
            let x0 = x + Double(letter) * 8
            switch letter % 4 {
            case 0: return line(p(x0 + 2, baseline - 13), p(x0 + 1, baseline), &rng)
            case 1: return resampled((0...30).map { i in let a = Double(i) / 30 * 2 * .pi + 0.3
                return p(x0 + 3 + 3 * cos(a) + rng.range(-0.2, 0.2), baseline - 3.5 + 3.5 * sin(a)) })
            case 2: return hand([p(x0, baseline - 7), p(x0 + 1, baseline), p(x0 + 2, baseline - 6), p(x0 + 5, baseline - 6), p(x0 + 5.5, baseline)], &rng, bow: 0.4)
            default: return line(p(x0 + 2, baseline - 7), p(x0 + 2, baseline), &rng)
            }
        }
    }
    private func dot(_ x: Double, _ y: Double) -> [PagePoint] { [p(x, y), p(x + 0.8, y + 0.6)] }
    private func comma(_ x: Double, _ y: Double) -> [PagePoint] { resampled([p(x, y), p(x + 0.5, y + 2), p(x - 1, y + 4.5)], spacing: 1) }
    /// A hand-drawn closed ellipse that overlaps its start a little.
    private func circle(center c: PagePoint, rx: Double, ry: Double, _ rng: inout Rng) -> [PagePoint] {
        let start = rng.range(0, 2 * .pi), wobble = rng.range(0.9, 1.08)
        return resampled((0...160).map { i in
            let t = Double(i) / 160, a = start + t * (2 * .pi + 0.35), r = 1 + (wobble - 1) * t
            return p(c.x + rx * r * cos(a) + rng.range(-0.3, 0.3), c.y + ry * r * sin(a) + rng.range(-0.3, 0.3))
        })
    }

    /// Left and right edge of a closed polygon at height `y`.
    private func span(_ polygon: [PagePoint], at y: Double) -> (Double, Double)? {
        var xs: [Double] = []
        for (a, b) in zip(polygon, polygon.dropFirst() + [polygon[0]]) where (a.y <= y) != (b.y <= y) {
            xs.append(a.x + (b.x - a.x) * (y - a.y) / (b.y - a.y))
        }
        guard let lo = xs.min(), let hi = xs.max(), hi - lo > 2 else { return nil }
        return (lo, hi)
    }
    /// Zig-zag rows from `top` to `bottom` about `step` pt apart; each turn
    /// lies at `edges(y)` moved outwards by `offset()` (negative: inside).
    private func zigzag(top: Double, bottom: Double, step: Double, _ rng: inout Rng,
                        edges: (Double) -> (Double, Double)?, offset: (inout Rng) -> Double) -> [PagePoint] {
        var turns: [PagePoint] = [], y = top, left = rng.next() < 0.5
        while y <= bottom {
            if let (lo, hi) = edges(y) {
                let o = offset(&rng)
                turns.append(p(left ? lo - o : hi + o, y)); left.toggle()
            }
            y += step * rng.range(0.8, 1.2)
            if y > bottom, y - bottom < step, turns.last.map({ $0.y < bottom - 1 }) ?? false { y = bottom }
        }
        return hand(turns, &rng, bow: 0.8, tremor: 0.2)
    }
    /// Shading inside `polygon`: turns from 2.5 pt inside to 1.5 pt over its lines.
    private func shading(_ polygon: [PagePoint], _ rng: inout Rng, inset: ClosedRange<Double> = -2.5...1.5) -> [PagePoint] {
        let ys = polygon.map(\.y)
        return zigzag(top: ys.min()! + 2, bottom: ys.max()! - 2, step: 3.2, &rng, edges: { span(polygon, at: $0) },
                      offset: { $0.range(inset.lowerBound, inset.upperBound) })
    }
    /// Scribbling out the box `x × y`: turns 5–9 pt beyond its left and right
    /// edges unless `overshoot` says otherwise, rows 4 pt apart.
    private func scribbleOut(x: ClosedRange<Double>, y: ClosedRange<Double>, _ rng: inout Rng,
                             overshoot: ClosedRange<Double> = 5...9, step: Double = 4) -> [PagePoint] {
        zigzag(top: y.lowerBound, bottom: y.upperBound, step: step, &rng, edges: { _ in (x.lowerBound, x.upperBound) },
               offset: { $0.range(overshoot.lowerBound, overshoot.upperBound) })
    }
    /// Mirrored at the diagonal: rows become columns.
    private func swapped(_ points: [PagePoint]) -> [PagePoint] { points.map { p($0.y, $0.x) } }
    private func ellipse(_ c: PagePoint, _ rx: Double, _ ry: Double) -> (Double) -> (Double, Double)? {
        { y in let d = 1 - pow((y - c.y) / ry, 2); return d > 0 ? (c.x - rx * d.squareRoot(), c.x + rx * d.squareRoot()) : nil }
    }

    /// The app's call: padding and reach from a 2 pt pen, every stroke 2 pt wide.
    private func erase(_ scribble: [PagePoint], _ strokes: [[PagePoint]], _ shapes: [ShapeObject] = [],
                       file: StaticString = #filePath, line: UInt = #line) -> (strokes: Set<Int>, shapes: Set<UUID>) {
        XCTAssertTrue(ScribbleErase.isScribble(scribble), "not recognised as a scribble", file: file, line: line)
        let result = ScribbleErase.erasure(scribble: scribble, strokes: strokes, strokeWidths: strokes.map { _ in 2 },
                                           shapes: shapes, padding: 4, reach: 2)
        return (Set(result.strokes), Set(result.shapes))
    }

    // MARK: Wegkritzeln löscht

    func testScribblingOutACursiveWordTakesItsDotsAndUmlautsButNotTheNeighbours() {
        for seed in Self.seeds {
            var rng = Rng(state: seed)
            let word = cursive(x: 100, baseline: 120, letters: 6, &rng)
            let iDot = dot(rng.range(112, 118), 104), umlaut1 = dot(rng.range(128, 131), 106), umlaut2 = dot(rng.range(133, 136), 106)
            let commaMark = comma(146, 121)
            let before = cursive(x: 40, baseline: 120, letters: 6, &rng), after = cursive(x: 162, baseline: 120, letters: 5, &rng)
            let scribble = scribbleOut(x: 100...148, y: 102...127, &rng, overshoot: 2...6)
            let erased = erase(scribble, [word, iDot, umlaut1, umlaut2, commaMark, before, after])
            XCTAssertEqual(erased.strokes, [0, 1, 2, 3, 4], "seed \(seed)")
        }
    }

    func testScribblingOutPrintedLettersTakesEveryLetter() {
        for seed in Self.seeds {
            var rng = Rng(state: seed)
            let letters = printed(x: 100, baseline: 130, letters: 6, &rng)
            let iDot = dot(150, 119)
            let scribble = scribbleOut(x: 100...147, y: 112...134, &rng, overshoot: 3...8, step: 3.5)
            XCTAssertEqual(erase(scribble, letters + [iDot]).strokes, Set(0...6), "seed \(seed)")
        }
    }

    func testScribblingOutShapesWithLittleOvershootRemovesThem() {
        for seed in Self.seeds {
            var rng = Rng(state: seed)
            let box = ShapeObject(kind: .rectangle, start: p(100, 100), end: p(200, 150))
            // Turns 5–9 pt past the edges, the rows within the box's height.
            XCTAssertEqual(erase(scribbleOut(x: 100...200, y: 101...149, &rng), [], [box]).shapes, [box.id], "rectangle, seed \(seed)")
            let oval = ShapeObject(kind: .ellipse, start: p(100, 100), end: p(190, 150))
            // No overshoot at all: the passes span exactly the ellipse's width.
            XCTAssertEqual(erase(scribbleOut(x: 100...190, y: 101...149, &rng, overshoot: -1...1), [], [oval]).shapes, [oval.id], "ellipse, seed \(seed)")
            let line = ShapeObject(kind: .line, start: p(105, 125), end: p(195, 128))
            XCTAssertEqual(erase(scribbleOut(x: 100...200, y: 110...140, &rng), [], [line]).shapes, [line.id], "parallel line, seed \(seed)")
        }
    }

    func testScribblingOutAHandDrawnCircleWithItsWord() {
        for seed in Self.seeds {
            var rng = Rng(state: seed)
            let ring = circle(center: p(150, 120), rx: 40, ry: 20, &rng)
            let word = cursive(x: 128, baseline: 126, letters: 6, &rng)
            let erased = erase(scribbleOut(x: 110...190, y: 101...139, &rng, overshoot: 0...4), [ring, word])
            XCTAssertEqual(erased.strokes, [0, 1], "seed \(seed)")
        }
    }

    func testScribblingOutAnAnswerInABoxTakesBoxAndAnswer() {
        for seed in Self.seeds {
            var rng = Rng(state: seed)
            let box = ShapeObject(kind: .rectangle, start: p(100, 100), end: p(180, 130))
            let answer = cursive(x: 110, baseline: 124, letters: 8, &rng)
            let question = cursive(x: 20, baseline: 124, letters: 9, &rng)
            let erased = erase(scribbleOut(x: 100...180, y: 101...129, &rng), [answer, question], [box])
            XCTAssertEqual(erased.strokes, [0], "seed \(seed)")
            XCTAssertEqual(erased.shapes, [box.id], "seed \(seed)")
            // A box from four pen strokes, scribbled a little over all its sides.
            let sides = [line(p(100, 100), p(180, 100), &rng), line(p(180, 100), p(180, 130), &rng),
                         line(p(180, 130), p(100, 130), &rng), line(p(100, 130), p(100, 100), &rng)]
            XCTAssertEqual(erase(scribbleOut(x: 100...180, y: 93...137, &rng), sides + [answer]).strokes, Set(0...4), "pen box, seed \(seed)")
        }
    }

    func testOnlyWhatTheScribbleCrossesGoes() {
        for seed in Self.seeds {
            var rng = Rng(state: seed)
            let target = cursive(x: 100, baseline: 120, letters: 5, &rng)
            // Below the scribbled band and only touched by the turns' ends.
            let underline = line(p(95, 132), p(145, 133), &rng)
            let erased = erase(scribbleOut(x: 100...135, y: 104...122, &rng, overshoot: 3...6), [target, underline])
            XCTAssertEqual(erased.strokes, [0], "seed \(seed)")
        }
    }

    // MARK: Schraffur löscht nichts

    func testShadingInFiguresFromSeveralStrokesErasesNothing() {
        for seed in Self.seeds {
            var rng = Rng(state: seed)
            let triangle = [p(100, 200), p(180, 130), p(260, 200)]
            let sides = [line(triangle[0], triangle[1], &rng), line(triangle[1], triangle[2], &rng), line(triangle[2], triangle[0], &rng)]
            let label = cursive(x: 268, baseline: 205, letters: 3, &rng), corner = printed(x: 176, baseline: 126, letters: 1, &rng)[0]
            XCTAssertEqual(erase(shading(triangle, &rng), sides + [label, corner]).strokes, [], "triangle, seed \(seed)")
            // Kept clear of the border ("mit Abstand zum Rand").
            XCTAssertEqual(erase(shading(triangle, &rng, inset: -4...(-2)), sides + [label, corner]).strokes, [], "triangle with gap, seed \(seed)")

            let box = [p(100, 100), p(200, 100), p(200, 150), p(100, 150)]
            let edges = [line(box[0], box[1], &rng), line(box[1], box[2], &rng), line(box[2], box[3], &rng), line(box[3], box[0], &rng)]
            let caption = cursive(x: 120, baseline: 165, letters: 6, &rng)
            XCTAssertEqual(erase(shading(box, &rng), edges + [caption]).strokes, [], "box, seed \(seed)")

            // A bar of a chart (left, top and right side on the axis), shaded up and down.
            let bar = [p(120, 100), p(150, 100), p(150, 200), p(120, 200)]
            let barSides = [line(p(120, 200), p(120, 100), &rng), line(p(120, 100), p(150, 100), &rng), line(p(150, 100), p(150, 200), &rng)]
            let axis = line(p(60, 200), p(260, 200), &rng), value = cursive(x: 124, baseline: 95, letters: 3, &rng)
            XCTAssertEqual(erase(swapped(shading(swapped(bar), &rng)), barSides + [axis, value]).strokes, [], "bar, seed \(seed)")
        }
    }

    func testShadingInsideAFrameKeepsTheLabelItRunsOver() {
        for seed in Self.seeds {
            var rng = Rng(state: seed)
            let box = [p(100, 100), p(200, 100), p(200, 160), p(100, 160)]
            let edges = [line(box[0], box[1], &rng), line(box[1], box[2], &rng), line(box[2], box[3], &rng), line(box[3], box[0], &rng)]
            let label = cursive(x: 125, baseline: 134, letters: 6, &rng)
            XCTAssertEqual(erase(shading(box, &rng), edges + [label]).strokes, [], "pen frame, seed \(seed)")
            let frame = ShapeObject(kind: .rectangle, start: box[0], end: box[2])
            let erased = erase(shading(box, &rng), [label], [frame])
            XCTAssertEqual(erased.strokes, [], "shape, seed \(seed)")
            XCTAssertEqual(erased.shapes, [], "shape, seed \(seed)")
        }
    }

    func testShadingInShapesErasesNothing() {
        for seed in Self.seeds {
            var rng = Rng(state: seed)
            let vertices = [p(100, 200), p(180, 130), p(260, 200)]
            let triangle = ShapeObject(kind: .polygon, vertices: vertices)
            let label = cursive(x: 90, baseline: 220, letters: 4, &rng)
            XCTAssertEqual(erase(shading(vertices, &rng), [label], [triangle]).shapes, [], "polygon, seed \(seed)")
            let lines = [ShapeObject(kind: .line, start: vertices[0], end: vertices[1]), ShapeObject(kind: .line, start: vertices[1], end: vertices[2]),
                         ShapeObject(kind: .line, start: vertices[2], end: vertices[0])]
            let erased = erase(shading(vertices, &rng), [label], lines)
            XCTAssertEqual(erased.shapes, [], "three lines, seed \(seed)")
            XCTAssertEqual(erased.strokes, [], "three lines, seed \(seed)")
            let rectangle = ShapeObject(kind: .rectangle, start: p(100, 100), end: p(200, 150))
            XCTAssertEqual(erase(shading([p(100, 100), p(200, 100), p(200, 150), p(100, 150)], &rng), [], [rectangle]).shapes, [], "rectangle, seed \(seed)")
            let oval = ShapeObject(kind: .ellipse, start: p(100, 100), end: p(200, 150))
            let inside = zigzag(top: 103, bottom: 147, step: 3.2, &rng, edges: ellipse(p(150, 125), 50, 25), offset: { $0.range(-2.5, 1.5) })
            XCTAssertEqual(erase(inside, [], [oval]).shapes, [], "ellipse, seed \(seed)")
        }
    }

    func testSloppyShadingWithSingleOvershootsKeepsTheFrame() {
        for seed in Self.seeds {
            var rng = Rng(state: seed)
            let box = [p(100, 100), p(200, 100), p(200, 150), p(100, 150)]
            let frame = ShapeObject(kind: .rectangle, start: box[0], end: box[2])
            let edges = [line(box[0], box[1], &rng), line(box[1], box[2], &rng), line(box[2], box[3], &rng), line(box[3], box[0], &rng)]
            // Two of fifteen turns run 6–10 pt over the line.
            var turn = 0
            let sloppy = zigzag(top: 102, bottom: 148, step: 3.2, &rng, edges: { span(box, at: $0) }, offset: { rng in
                turn += 1; return turn == 4 || turn == 9 ? rng.range(6, 10) : rng.range(-2.5, 1.5)
            })
            XCTAssertEqual(erase(sloppy, [], [frame]).shapes, [], "shape, seed \(seed)")
            XCTAssertEqual(erase(sloppy, edges).strokes, [], "pen frame, seed \(seed)")
        }
    }

    func testShadingOnEmptyPaperErasesNothing() {
        for seed in Self.seeds {
            var rng = Rng(state: seed)
            let elsewhere = cursive(x: 300, baseline: 300, letters: 5, &rng)
            let shade = scribbleOut(x: 100...180, y: 100...140, &rng, step: 3)
            XCTAssertEqual(erase(shade, [elsewhere]).strokes, [], "seed \(seed)")
        }
    }

    /// The review: narrow "ll"/"lll" and an underline drawn four times count
    /// as scribbles. Crossing nothing, they erase nothing and stay strokes.
    func testHandwritingThatLooksLikeAScribbleKeepsEverything() {
        for seed in Self.seeds {
            var rng = Rng(state: seed)
            let word = cursive(x: 100, baseline: 120, letters: 5, &rng)
            // Narrow "lll" right after the word, touching its last stroke.
            let ll = hand([p(138, 120), p(139.5, 103), p(140.5, 120), p(142, 103), p(143, 120), p(144.5, 103), p(145.5, 120)], &rng, bow: 0.3)
            XCTAssertTrue(ScribbleErase.isScribble(ll), "seed \(seed)")
            XCTAssertEqual(erase(ll, [word]).strokes, [], "lll, seed \(seed)")
            let underline = hand([p(98, 124), p(140, 125), p(99, 125.5), p(141, 126), p(100, 127)], &rng, bow: 0.5)
            XCTAssertTrue(ScribbleErase.isScribble(underline), "seed \(seed)")
            XCTAssertEqual(erase(underline, [word]).strokes, [], "underline, seed \(seed)")
        }
    }

    func testScribblingOutAWordBetweenCloseNeighboursKeepsThem() {
        for seed in Self.seeds {
            var rng = Rng(state: seed)
            let word = cursive(x: 100, baseline: 120, letters: 6, &rng)
            let before = cursive(x: 51, baseline: 120, letters: 6, &rng), after = cursive(x: 149, baseline: 120, letters: 6, &rng)
            // Turns end in the 5 pt gaps, up to 1 pt short of the neighbours.
            let erased = erase(scribbleOut(x: 100...144, y: 102...124, &rng, overshoot: 0...4), [word, before, after])
            XCTAssertEqual(erased.strokes, [0], "seed \(seed)")
        }
    }

    /// The limit, "lieber zu wenig": a scribble whose turns lie on a
    /// rectangle's sides is shading of that rectangle – it keeps it. Its turns
    /// have to run about 5 pt (centre to centre, 3 pt beyond a 2 pt line) over
    /// the sides; an ellipse goes without (see above).
    func testTurnsOnARectanglesSidesKeepIt() {
        for seed in Self.seeds {
            var rng = Rng(state: seed)
            let box = ShapeObject(kind: .rectangle, start: p(100, 100), end: p(200, 150))
            let answer = cursive(x: 120, baseline: 130, letters: 6, &rng)
            let erased = erase(scribbleOut(x: 100...200, y: 101...149, &rng, overshoot: -1...2), [answer], [box])
            XCTAssertEqual(erased.shapes, [], "seed \(seed)")
            XCTAssertEqual(erased.strokes, [], "seed \(seed)")
        }
    }
}
