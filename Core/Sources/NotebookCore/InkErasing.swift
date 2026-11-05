import Foundation

/// Geometry for whole-stroke erasing: the eraser sweeps a capsule (segment
/// plus radius) and hits every stroke polyline it touches.
public enum StrokeHitTest {
    public static func distance(_ p: PagePoint, segment a: PagePoint, _ b: PagePoint) -> Double {
        let dx = b.x - a.x, dy = b.y - a.y, length = dx * dx + dy * dy
        guard length > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = min(1, max(0, ((p.x - a.x) * dx + (p.y - a.y) * dy) / length))
        return hypot(p.x - a.x - t * dx, p.y - a.y - t * dy)
    }
    public static func distance(segment a: PagePoint, _ b: PagePoint, segment c: PagePoint, _ d: PagePoint) -> Double {
        func cross(_ o: PagePoint, _ p: PagePoint, _ q: PagePoint) -> Double { (p.x - o.x) * (q.y - o.y) - (p.y - o.y) * (q.x - o.x) }
        let d1 = cross(c, d, a), d2 = cross(c, d, b), d3 = cross(a, b, c), d4 = cross(a, b, d)
        if ((d1 > 0 && d2 < 0) || (d1 < 0 && d2 > 0)) && ((d3 > 0 && d4 < 0) || (d3 < 0 && d4 > 0)) { return 0 }
        return min(distance(a, segment: c, d), distance(b, segment: c, d), distance(c, segment: a, b), distance(d, segment: a, b))
    }
    /// True when the swept eraser capsule `a→b` (radius) touches the stroke polyline.
    public static func hits(sweep a: PagePoint, _ b: PagePoint, radius: Double, stroke: [PagePoint]) -> Bool {
        guard let first = stroke.first else { return false }
        if stroke.count == 1 { return distance(first, segment: a, b) <= radius }
        return zip(stroke, stroke.dropFirst()).contains { distance(segment: a, b, segment: $0, $1) <= radius }
    }
}

/// "Durchkritzeln löscht": a dense back-and-forth scribble over existing pen
/// ink removes the strokes it scribbles out (`erasure`). Ordinary writing and
/// single zig-zag lines are never classified; shading and hatching across
/// empty paper erase nothing.
public enum ScribbleErase {
    public static let minimumReversals = 3

    public static func isScribble(_ points: [PagePoint]) -> Bool {
        guard points.count >= 12, points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }), let motion = passes(points) else { return false }
        guard motion.main >= 12, motion.main >= motion.cross * 1.4 else { return false }
        let length = zip(points, points.dropFirst()).reduce(0) { $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) }
        guard length >= motion.main * 3.2 else { return false }
        guard motion.spans.count >= minimumReversals else { return false }
        // Passes go back over the same span instead of travelling along a line.
        let mean = motion.spans.reduce(0, +) / Double(motion.spans.count)
        return mean >= max(8, motion.main * 0.45)
    }

    /// The scribble's main axis (`axis`, the points' principal direction),
    /// its extent along and across it, and the reversals along it with
    /// hysteresis against jitter (`hysteresis`, by default a quarter of the
    /// extent): `turns` are the indices of the turning points, `spans` the
    /// distance each completed pass covered. `erasure` uses every turn of
    /// 4 pt and more, also the short ones in the tip of a shaded triangle.
    static func passes(_ points: [PagePoint], hysteresis: Double? = nil) -> (axis: (x: Double, y: Double), main: Double, cross: Double, turns: [Int], spans: [Double])? {
        guard points.count >= 2 else { return nil }
        let n = Double(points.count)
        let cx = points.reduce(0) { $0 + $1.x } / n, cy = points.reduce(0) { $0 + $1.y } / n
        var sxx = 0.0, syy = 0.0, sxy = 0.0
        for p in points { sxx += (p.x - cx) * (p.x - cx); syy += (p.y - cy) * (p.y - cy); sxy += (p.x - cx) * (p.y - cy) }
        let theta = 0.5 * atan2(2 * sxy, sxx - syy), u = (x: cos(theta), y: sin(theta))
        let along = points.map { ($0.x - cx) * u.x + ($0.y - cy) * u.y }
        let across = points.map { -($0.x - cx) * u.y + ($0.y - cy) * u.x }
        let main = along.max()! - along.min()!, cross = across.max()! - across.min()!
        let threshold = hysteresis ?? max(4, main * 0.25)
        var direction = 0.0, extreme = along[0], extremeIndex = 0, passStart = along[0]
        var spans: [Double] = [], turns: [Int] = []
        for (index, t) in along.enumerated().dropFirst() {
            if direction == 0 {
                if abs(t - along[0]) >= threshold { direction = t > along[0] ? 1 : -1; extreme = t; extremeIndex = index }
            } else if (t - extreme) * direction > 0 { extreme = t; extremeIndex = index }
            else if (extreme - t) * direction >= threshold {
                spans.append(abs(extreme - passStart)); turns.append(extremeIndex)
                passStart = extreme; extreme = t; extremeIndex = index; direction = -direction
            }
        }
        return (u, main, cross, turns, spans)
    }

    /// Indices of strokes mostly inside the scribble's hull (expanded by `padding`).
    public static func coveredStrokes(scribble: [PagePoint], strokes: [[PagePoint]], padding: Double, minimumShare: Double = 0.5) -> [Int] {
        let hull = convexHull(scribble)
        guard hull.count >= 3 else { return [] }
        let xs = hull.map(\.x), ys = hull.map(\.y)
        let box = (minX: xs.min()! - padding, maxX: xs.max()! + padding, minY: ys.min()! - padding, maxY: ys.max()! + padding)
        func inside(_ p: PagePoint) -> Bool {
            guard p.x >= box.minX, p.x <= box.maxX, p.y >= box.minY, p.y <= box.maxY else { return false }
            var winding = false
            for (a, b) in zip(hull, hull.dropFirst() + [hull[0]]) where (a.y > p.y) != (b.y > p.y) {
                if p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x { winding.toggle() }
            }
            return winding || zip(hull, hull.dropFirst() + [hull[0]]).contains { StrokeHitTest.distance(p, segment: $0, $1) <= padding }
        }
        return strokes.indices.filter { index in
            let points = strokes[index]
            guard !points.isEmpty else { return false }
            return Double(points.filter(inside).count) / Double(points.count) >= minimumShare
        }
    }

    /// Shapes whose drawn outline lies mostly inside the scribble's hull, like
    /// strokes (`coveredStrokes` over outlines sampled about every 3 pt): a
    /// scribble over a shape removes it together with covered ink.
    public static func coveredShapes(scribble: [PagePoint], shapes: [ShapeObject], padding: Double, minimumShare: Double = 0.5) -> [UUID] {
        let outlines = shapes.map { shape in
            shape.outlinePolylines.flatMap { line in sampled(line.closed && !line.points.isEmpty ? line.points + [line.points[0]] : line.points, spacing: 3) }
        }
        return coveredStrokes(scribble: scribble, strokes: outlines, padding: padding, minimumShare: minimumShare).map { shapes[$0].id }
    }
    /// What a recognised scribble (`isScribble`) erases: strokes (indices into
    /// `strokes`) and shapes (ids).
    ///
    /// Shading and scribbling out are the same back-and-forth motion; they
    /// differ in where the passes meet the ink. Shading turns *at* the lines
    /// that bound it (or ends on them), scribbling out runs *across* what it
    /// removes. So, without looking for closed outlines (review of dc7d6f2):
    /// - **Crossing** (`ScribblePath.assess`): the scribble's centre line
    ///   crosses the stroke/outline at least 20° steep, and runs on for
    ///   `margin` (`touch` – `reach` plus the line's half width – plus 2 pt)
    ///   on both sides before it turns. A pass that turns on a line or just
    ///   over it does not cross it. Crossings in the middle of a pass count
    ///   once per pass, crossings near a turn once per turn (the two passes
    ///   around an overshoot are one place).
    /// - **Along the passes:** a straight stroke/line within 25° of the passes
    ///   is never crossed; it counts as crossed twice when passes run on both
    ///   sides of it (at least `margin` away) and one touches it.
    /// - **Resting turns:** a turn (or the start/end) whose tip lies within
    ///   `touch + 1.5` of ink that is not crossed there rests on it.
    /// - A stroke/shape that lies mostly inside the scribble's hull
    ///   (`coveredStrokes`/`coveredShapes`) is scribbled out with at least two
    ///   crossing places and fewer than twice as many resting turns (a frame
    ///   the shading turns on with a few overshoots stays).
    /// - **Shading:** when at least 60 % of the tips rest on ink that stays,
    ///   nothing is erased, not even a label the shading runs over.
    /// - Otherwise, once something is scribbled out, also what else inside
    ///   the hull the scribble crosses once or touches – not a line that turns
    ///   rest on and that spans more than 3/4 of the scribble's height (a
    ///   frame's side) – and dots, umlauts and commas (≤ 7 pt) within
    ///   `touch + 3`.
    /// A scribble that erases nothing stays an ordinary stroke. Erasing too
    /// little is harmless (scribble again, or use the eraser); erasing the
    /// wrong content is not.
    public static func erasure(scribble: [PagePoint], strokes: [[PagePoint]], strokeWidths: [Double] = [],
                               shapes: [ShapeObject], padding: Double, reach: Double) -> (strokes: [Int], shapes: [UUID]) {
        guard scribble.count >= 2, scribble.allSatisfy({ $0.x.isFinite && $0.y.isFinite }), let motion = passes(scribble, hysteresis: 4) else { return ([], []) }
        let path = ScribblePath(points: scribble, turns: motion.turns, axis: motion.axis)
        let width = { (index: Int) -> Double in index < strokeWidths.count && strokeWidths[index].isFinite ? max(0, strokeWidths[index]) : 0 }
        let coveredStrokeSet = Set(coveredStrokes(scribble: scribble, strokes: strokes, padding: padding))
        let coveredShapeSet = Set(coveredShapes(scribble: scribble, shapes: shapes, padding: padding))
        var targets: [Target] = strokes.indices.map { index in
            Target(lines: [strokes[index]], touch: max(0, reach) + width(index) / 2, covered: coveredStrokeSet.contains(index))
        }
        targets += shapes.map { shape in
            Target(lines: shape.outlinePolylines.map { $0.closed && !$0.points.isEmpty ? $0.points + [$0.points[0]] : $0.points },
                   touch: max(0, reach) + max(0, shape.lineWidth) / 2, covered: coveredShapeSet.contains(shape.id))
        }
        let assessed = targets.map { path.assess($0) }
        var erased = Set(assessed.indices.filter { targets[$0].covered && assessed[$0].erases })
        // Shading: most turns end on ink that stays.
        let small = Set(strokes.indices.filter { isSmall(strokes[$0]) })
        let resting = path.tips.indices.filter { tip in
            assessed.indices.contains { !erased.contains($0) && !small.contains($0) && assessed[$0].resting.contains(tip) }
        }
        if Double(resting.count) >= Double(path.tips.count) * 0.6 { return ([], []) }
        // What goes along with ink that is scribbled out (see above).
        if !erased.isEmpty {
            for index in targets.indices where targets[index].covered && !erased.contains(index) {
                let target = targets[index], assessment = assessed[index]
                let isMark = small.contains(index)
                let across = target.lines.flatMap { $0 }.map { -$0.x * motion.axis.y + $0.y * motion.axis.x }
                let short = (across.max() ?? 0) - (across.min() ?? 0) <= 0.75 * motion.cross
                if assessment.crossed > 0 || (short && !assessment.resting.isEmpty)
                    || ((isMark || short || assessment.resting.isEmpty)
                        && target.lines.contains { contacts(scribble, $0, reach: isMark ? target.touch + 3 : target.touch) >= 1 }) {
                    erased.insert(index)
                }
            }
        }
        return (strokes.indices.filter(erased.contains), shapes.indices.filter { erased.contains(strokes.count + $0) }.map { shapes[$0].id })
    }

    /// Separate runs of scribble segments that come within `reach` of `line`.
    static func contacts(_ scribble: [PagePoint], _ line: [PagePoint], reach: Double) -> Int {
        guard !line.isEmpty, scribble.count >= 2 else { return 0 }
        let xs = line.map(\.x), ys = line.map(\.y)
        let box = (minX: xs.min()! - reach, maxX: xs.max()! + reach, minY: ys.min()! - reach, maxY: ys.max()! + reach)
        var count = 0, touching = false
        for (a, b) in zip(scribble, scribble.dropFirst()) {
            let near = max(a.x, b.x) >= box.minX && min(a.x, b.x) <= box.maxX && max(a.y, b.y) >= box.minY && min(a.y, b.y) <= box.maxY
                && StrokeHitTest.hits(sweep: a, b, radius: reach, stroke: line)
            if near && !touching { count += 1 }
            touching = near
        }
        return count
    }

    /// A dot, umlaut or comma: at most 7 pt in either direction.
    static func isSmall(_ points: [PagePoint]) -> Bool {
        guard !points.isEmpty else { return false }
        let xs = points.map(\.x), ys = points.map(\.y)
        return xs.max()! - xs.min()! <= 7 && ys.max()! - ys.min()! <= 7
    }

    /// A stroke or a shape outline as polylines; `touch` is how close the
    /// scribble's centre line comes when the two inks meet.
    struct Target {
        var lines: [[PagePoint]]
        var touch: Double
        var covered: Bool
        var margin: Double { touch + 2 }
    }
    struct Assessment {
        /// Separate crossing places (see `erasure`).
        var crossings: Int
        /// Passes that validly cross the target.
        var crossed: Int
        /// Lies along the passes with passes on both sides.
        var sandwiched: Bool
        /// Tips (`ScribblePath.tips`) that rest on the target.
        var resting: Set<Int>
        var erases: Bool {
            let places = sandwiched ? max(crossings, 2) : crossings
            return places >= 2 && resting.count < 2 * places
        }
    }

    /// The scribble as a path: arc length per point and the pass boundaries
    /// (start, turning points, end) along it.
    struct ScribblePath {
        let points: [PagePoint]
        let arc: [Double]
        /// Arc positions of start, turns and end; pass `k` runs from `bounds[k]` to `bounds[k + 1]`.
        let bounds: [Double]
        let tips: [PagePoint]
        let axis: (x: Double, y: Double)

        init(points: [PagePoint], turns: [Int], axis: (x: Double, y: Double)) {
            self.points = points; self.axis = axis
            var arc = [0.0]
            for (a, b) in zip(points, points.dropFirst()) { arc.append(arc.last! + hypot(b.x - a.x, b.y - a.y)) }
            self.arc = arc
            let indices = [0] + turns.filter { $0 > 0 && $0 < points.count - 1 } + [points.count - 1]
            bounds = indices.map { arc[$0] }
            tips = indices.map { points[$0] }
        }

        func assess(_ target: Target) -> Assessment {
            let lines = target.lines.filter { !$0.isEmpty }
            guard !lines.isEmpty else { return Assessment(crossings: 0, crossed: 0, sandwiched: false, resting: []) }
            let all = lines.flatMap { $0 }
            let xs = all.map(\.x), ys = all.map(\.y), pad = target.touch + 2
            let box = (minX: xs.min()! - pad, maxX: xs.max()! + pad, minY: ys.min()! - pad, maxY: ys.max()! + pad)
            let margin = target.margin
            var midPasses = Set<Int>(), nearTurns = Set<Int>(), crossedPasses = Set<Int>()
            for i in points.indices.dropLast() {
                let a = points[i], b = points[i + 1]
                guard max(a.x, b.x) >= box.minX, min(a.x, b.x) <= box.maxX, max(a.y, b.y) >= box.minY, min(a.y, b.y) <= box.maxY else { continue }
                let r = (x: b.x - a.x, y: b.y - a.y), rLength = hypot(r.x, r.y)
                guard rLength > 0 else { continue }
                for line in lines where line.count >= 2 {
                    for j in line.indices.dropLast() {
                        let c = line[j], d = line[j + 1], s = (x: d.x - c.x, y: d.y - c.y), sLength = hypot(s.x, s.y)
                        let denominator = r.x * s.y - r.y * s.x
                        guard sLength > 0, abs(denominator) >= sin(20 * Double.pi / 180) * rLength * sLength else { continue }
                        let t = ((c.x - a.x) * s.y - (c.y - a.y) * s.x) / denominator
                        let u = ((c.x - a.x) * r.y - (c.y - a.y) * r.x) / denominator
                        guard t >= 0, t < 1, u >= 0, u <= 1 else { continue }
                        let position = arc[i] + t * rLength
                        let pass = max(0, min(bounds.count - 2, (bounds.lastIndex { $0 <= position } ?? 0)))
                        let fromStart = position - bounds[pass], toEnd = bounds[pass + 1] - position
                        guard min(fromStart, toEnd) >= margin else { continue }
                        crossedPasses.insert(pass)
                        if min(fromStart, toEnd) < max(3 * margin, 0.25 * (bounds[pass + 1] - bounds[pass])) {
                            nearTurns.insert(fromStart <= toEnd ? pass : pass + 1)
                        } else {
                            midPasses.insert(pass)
                        }
                    }
                }
            }
            let resting = Set(tips.indices.filter { tip in
                !nearTurns.contains(tip) && !midPasses.contains(tip - 1) && !midPasses.contains(tip)
                    && lines.contains { line in line.count == 1 ? hypot(tips[tip].x - line[0].x, tips[tip].y - line[0].y) <= target.touch + 1.5
                        : zip(line, line.dropFirst()).contains { StrokeHitTest.distance(tips[tip], segment: $0, $1) <= target.touch + 1.5 } }
            })
            return Assessment(crossings: midPasses.count + nearTurns.count, crossed: crossedPasses.count, sandwiched: sandwiched(all, target), resting: resting)
        }

        /// A straight target along the passes (within 25°) with scribble on
        /// both sides of it, at least `margin` away, and touched by it.
        func sandwiched(_ all: [PagePoint], _ target: Target) -> Bool {
            guard all.count >= 2 else { return false }
            let n = Double(all.count)
            let cx = all.reduce(0) { $0 + $1.x } / n, cy = all.reduce(0) { $0 + $1.y } / n
            var sxx = 0.0, syy = 0.0, sxy = 0.0
            for p in all { sxx += (p.x - cx) * (p.x - cx); syy += (p.y - cy) * (p.y - cy); sxy += (p.x - cx) * (p.y - cy) }
            let theta = 0.5 * atan2(2 * sxy, sxx - syy), v = (x: cos(theta), y: sin(theta))
            guard abs(v.x * axis.x + v.y * axis.y) >= cos(25 * Double.pi / 180) else { return false }
            let along = all.map { ($0.x - cx) * v.x + ($0.y - cy) * v.y }, across = all.map { -($0.x - cx) * v.y + ($0.y - cy) * v.x }
            let length = along.max()! - along.min()!, thickness = across.max()! - across.min()!
            guard length >= 12, length >= thickness * 3 else { return false }
            let side = thickness / 2 + target.margin
            var above = false, below = false
            for p in points {
                let t = (p.x - cx) * v.x + (p.y - cy) * v.y
                guard t >= along.min()!, t <= along.max()! else { continue }
                let offset = -(p.x - cx) * v.y + (p.y - cy) * v.x
                if offset >= side { above = true } else if offset <= -side { below = true }
            }
            guard above, below else { return false }
            return target.lines.contains { ScribbleErase.contacts(points, $0, reach: target.touch) >= 1 }
        }
    }

    /// The polyline with extra points so no gap exceeds `spacing`.
    static func sampled(_ points: [PagePoint], spacing: Double) -> [PagePoint] {
        guard let first = points.first else { return [] }
        var result = [first]
        for (a, b) in zip(points, points.dropFirst()) {
            let steps = max(1, Int((hypot(b.x - a.x, b.y - a.y) / max(0.5, spacing)).rounded(.up)))
            for step in 1...steps {
                let t = Double(step) / Double(steps)
                result.append(PagePoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
            }
        }
        return result
    }

    static func convexHull(_ points: [PagePoint]) -> [PagePoint] {
        let sorted = points.sorted { $0.x == $1.x ? $0.y < $1.y : $0.x < $1.x }
        guard sorted.count >= 3 else { return sorted }
        func cross(_ o: PagePoint, _ a: PagePoint, _ b: PagePoint) -> Double { (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x) }
        var lower: [PagePoint] = [], upper: [PagePoint] = []
        for p in sorted {
            while lower.count >= 2, cross(lower[lower.count - 2], lower[lower.count - 1], p) <= 0 { lower.removeLast() }
            lower.append(p)
        }
        for p in sorted.reversed() {
            while upper.count >= 2, cross(upper[upper.count - 2], upper[upper.count - 1], p) <= 0 { upper.removeLast() }
            upper.append(p)
        }
        return Array(lower.dropLast() + upper.dropLast())
    }
}
