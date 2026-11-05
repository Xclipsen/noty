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
    /// What a recognised scribble erases (`isScribble`): strokes (indices
    /// into `strokes`) and shapes (ids) that lie mostly inside its hull
    /// (`coveredStrokes`/`coveredShapes`) **and** that it actually reaches.
    ///
    /// Audit 7f8bfe7 (Fund 1): shading inside a frame looks like a scribble,
    /// so it removed the frame, its label and itself. Now
    /// - a stroke goes only when the scribble's line touches it (`reach` plus
    ///   the stroke's half width, `strokeWidths`), a shape only when at least
    ///   two separate scribble passes touch its outline – a frame the shading
    ///   stays inside of is left alone;
    /// - shading of an area: when the scribble lies mostly (≥ 60 %) inside a
    ///   closed outline – a rectangle/ellipse/polygon or a closed pen stroke,
    ///   filled or not – and covers a good part (≥ 25 %) of it, nothing is
    ///   erased at all, neither the outline nor what it encloses. A scribble
    ///   that runs over and beyond the outline still erases.
    /// Erasing too little is harmless (the eraser still works); erasing the
    /// wrong content is not.
    public static func erasure(scribble: [PagePoint], strokes: [[PagePoint]], strokeWidths: [Double] = [],
                               shapes: [ShapeObject], padding: Double, reach: Double) -> (strokes: [Int], shapes: [UUID]) {
        guard scribble.count >= 2 else { return ([], []) }
        let width = { (index: Int) -> Double in index < strokeWidths.count && strokeWidths[index].isFinite ? max(0, strokeWidths[index]) : 0 }
        if shadesEnclosure(scribble: scribble, strokes: strokes, shapes: shapes) { return ([], []) }
        let strokeHits = coveredStrokes(scribble: scribble, strokes: strokes, padding: padding).filter {
            contacts(scribble, strokes[$0], reach: reach + width($0) / 2) >= 1
        }
        let covered = Set(coveredShapes(scribble: scribble, shapes: shapes, padding: padding))
        let shapeHits = shapes.filter { shape in
            guard covered.contains(shape.id) else { return false }
            let lines = shape.outlinePolylines.map { line in line.closed && !line.points.isEmpty ? line.points + [line.points[0]] : line.points }
            return lines.reduce(0) { $0 + contacts(scribble, $1, reach: reach + shape.lineWidth / 2) } >= 2
        }.map(\.id)
        return (strokeHits, shapeHits)
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

    /// Whether the scribble is shading inside a closed outline (see `erasure`).
    static func shadesEnclosure(scribble: [PagePoint], strokes: [[PagePoint]], shapes: [ShapeObject]) -> Bool {
        let hullArea = abs(area(convexHull(scribble)))
        guard hullArea > 0 else { return false }
        let closedShapes = shapes.filter(\.isFillable).compactMap { $0.outlinePolylines.first(where: \.closed)?.points }
        let closedStrokes = strokes.filter(isClosedLoop)
        for outline in closedShapes + closedStrokes where outline.count >= 3 {
            let enclosed = abs(area(outline))
            guard enclosed > 0, hullArea >= enclosed * 0.25 else { continue }
            let region = LassoRegion(points: outline)
            let inside = scribble.filter(region.contains).count
            if Double(inside) >= Double(scribble.count) * 0.6 { return true }
        }
        return false
    }
    /// A pen stroke that ends where it began around some area (a drawn frame or circle).
    static func isClosedLoop(_ points: [PagePoint]) -> Bool {
        guard points.count >= 8, let first = points.first, let last = points.last else { return false }
        let xs = points.map(\.x), ys = points.map(\.y)
        let w = xs.max()! - xs.min()!, h = ys.max()! - ys.min()!
        guard min(w, h) >= 8 else { return false }
        return hypot(last.x - first.x, last.y - first.y) <= max(8, 0.15 * max(w, h))
    }
    /// Signed shoelace area of a polygon.
    static func area(_ polygon: [PagePoint]) -> Double {
        guard polygon.count >= 3 else { return 0 }
        return zip(polygon, polygon.dropFirst() + [polygon[0]]).reduce(0) { $0 + $1.0.x * $1.1.y - $1.1.x * $1.0.y } / 2
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
