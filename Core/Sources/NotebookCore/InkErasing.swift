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
/// ink removes the strokes it covers. Ordinary writing, hatching across empty
/// paper and single zig-zag lines are never classified/erased.
public enum ScribbleErase {
    public static let minimumReversals = 3

    public static func isScribble(_ points: [PagePoint]) -> Bool {
        guard points.count >= 12, points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return false }
        let n = Double(points.count)
        let cx = points.reduce(0) { $0 + $1.x } / n, cy = points.reduce(0) { $0 + $1.y } / n
        var sxx = 0.0, syy = 0.0, sxy = 0.0
        for p in points { sxx += (p.x - cx) * (p.x - cx); syy += (p.y - cy) * (p.y - cy); sxy += (p.x - cx) * (p.y - cy) }
        let theta = 0.5 * atan2(2 * sxy, sxx - syy), u = (x: cos(theta), y: sin(theta))
        let along = points.map { ($0.x - cx) * u.x + ($0.y - cy) * u.y }
        let across = points.map { -($0.x - cx) * u.y + ($0.y - cy) * u.x }
        let main = along.max()! - along.min()!, cross = across.max()! - across.min()!
        guard main >= 12, main >= cross * 1.4 else { return false }
        let length = zip(points, points.dropFirst()).reduce(0) { $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) }
        guard length >= main * 3.2 else { return false }
        // Reversals along the main axis, with hysteresis against jitter.
        let threshold = max(4, main * 0.25)
        var direction = 0.0, extreme = along[0], passStart = along[0], passes: [Double] = []
        for t in along.dropFirst() {
            if direction == 0 {
                if abs(t - along[0]) >= threshold { direction = t > along[0] ? 1 : -1; extreme = t }
            } else if (t - extreme) * direction > 0 { extreme = t }
            else if (extreme - t) * direction >= threshold {
                passes.append(abs(extreme - passStart)); passStart = extreme; extreme = t; direction = -direction
            }
        }
        guard passes.count >= minimumReversals else { return false }
        // Passes go back over the same span instead of travelling along a line.
        let mean = passes.reduce(0, +) / Double(passes.count)
        return mean >= max(8, main * 0.45)
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
