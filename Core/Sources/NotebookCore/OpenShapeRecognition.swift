import Foundation

/// Open strokes after an explicit hold: arrows (straight or with corners, the
/// head drawn as two wings or a single hook in the same stroke) and
/// polylines with corners. Closed outlines stay with `closedShape`.
extension ShapeRecognition {
    /// Arrow with its head at the end of the stroke, or – only with wings on
    /// both sides – at its start (head drawn first).
    static func arrowShape(_ points: [PagePoint]) -> RecognizedShape? {
        arrow(headAtEndOf: points, bothWings: false) ?? arrow(headAtEndOf: points.reversed(), bothWings: true)
    }

    /// The wavy-line fallback (`lineAfterHold`) wins unless a clear corner
    /// (≥ 40°) exists: a slightly bent line is meant to be straight.
    static func openPolyline(_ points: [PagePoint]) -> RecognizedShape? {
        guard let vertices = fitPolyline(points), vertices.count >= 3 else { return nil }
        if lineAfterHold(points), (1..<(vertices.count - 1)).allSatisfy({ turn(vertices[$0 - 1], vertices[$0], vertices[$0 + 1]) < 40 }) {
            return nil
        }
        return .polyline(vertices, arrow: false)
    }

    // MARK: Arrow head

    static func arrow(headAtEndOf raw: [PagePoint], bothWings: Bool) -> RecognizedShape? {
        // Hand tremor would lengthen the path and blur the head's turns.
        let smooth = smoothed(resampleOpen(raw, spacing: max(1.5, ShapeObject.length(raw) / 300)))
        let total = ShapeObject.length(smooth)
        guard total >= 48 else { return nil }
        let s = resampleOpen(smooth, spacing: max(1.5, total / 240))
        let n = s.count
        guard n >= 12 else { return nil }
        let arc = arcLengths(s)
        guard let head = findHead(s, arc: arc, bothWings: bothWings), head.tip >= 1 else { return nil }
        // Smoothing rounds the tip off: take the drawn sample nearby that
        // reaches farthest along the approach.
        var back = head.tip
        while back > 0, arc[head.tip] - arc[back] < max(16, head.wing * 2) { back -= 1 }
        let rough = s[head.tip], approach = (x: rough.x - s[back].x, y: rough.y - s[back].y)
        let tip = raw.filter { hypot($0.x - rough.x, $0.y - rough.y) <= max(4, head.wing * 0.4) }
            .max { $0.x * approach.x + $0.y * approach.y < $1.x * approach.x + $1.y * approach.y } ?? rough
        let body = Array(s[0..<head.tip]) + [tip]
        guard let start = body.first else { return nil }
        let chord = hypot(tip.x - start.x, tip.y - start.y)
        let bodyLength = arc[head.tip]
        guard bodyLength >= 30 else { return nil }
        // A head whose shaft returns to its start is a closed outline with an
        // overshoot (triangle, square): those stay closed shapes.
        let (bx, by) = (body.map(\.x), body.map(\.y))
        let bodyDiagonal = hypot(bx.max()! - bx.min()!, by.max()! - by.min()!)
        guard chord >= bodyDiagonal * 0.3 else { return nil }
        let deviation = body.map { segmentDistance($0, start, tip) }.max() ?? 0
        if chord >= 30, deviation <= max(4, chord * 0.06) {
            return .arrow(start: start, tip: LineSnapping.end(from: start, to: tip))
        }
        if let vertices = fitPolyline(body), vertices.count >= 3 {
            // The last segment carries the head; it has to be clearly longer.
            let a = vertices[vertices.count - 2], b = vertices[vertices.count - 1]
            if hypot(b.x - a.x, b.y - a.y) >= head.wing * 1.2 { return .polyline(vertices, arrow: true) }
        }
        if chord >= 30, deviation <= max(12, chord * 0.18), bodyLength <= chord * 1.5 {
            return .arrow(start: start, tip: LineSnapping.end(from: start, to: tip))
        }
        return nil
    }

    /// First sample (from 40 % of the stroke on) after which the rest of the
    /// stroke stays near and behind it like an arrow head: small against the
    /// shaft, never clearly ahead along it, its farthest point 12–75° off the
    /// shaft (a wing). `tip`: the most forward sample there; `wing`: the head size.
    static func findHead(_ s: [PagePoint], arc: [Double], bothWings: Bool) -> (tip: Int, wing: Double)? {
        let n = s.count, total = arc[n - 1]
        for k in 1..<(n - 2) where arc[k] >= total * 0.4 {
            let t = s[k]
            var wing = 0.0, far = k
            for i in (k + 1)..<n {
                let d = hypot(s[i].x - t.x, s[i].y - t.y)
                if d > wing { wing = d; far = i }
            }
            // Size of the shaft: its farthest point from the tip.
            let shaft = s[0...k].reduce(0) { max($0, hypot($1.x - t.x, $1.y - t.y)) }
            guard wing >= max(6, shaft * 0.04), wing <= shaft * 0.4, total - arc[k] <= wing * 5 + 10 else { continue }
            // Shaft direction just before the tip, over a window of a few head sizes.
            let window = min(arc[k] * 0.6, max(16, wing * 2.5))
            var j = k
            while j > 0, arc[k] - arc[j] < window { j -= 1 }
            let from = s[j], length = hypot(t.x - from.x, t.y - from.y)
            guard length > 0, (j...k).allSatisfy({ segmentDistance(s[$0], from, t) <= max(2.5, window * 0.06) }) else { continue }
            let d = (x: (t.x - from.x) / length, y: (t.y - from.y) / length)
            let ahead = max(2, wing * 0.25)
            guard ((k + 1)..<n).allSatisfy({ (s[$0].x - t.x) * d.x + (s[$0].y - t.y) * d.y <= ahead }) else { continue }
            let w = s[far]
            let back = -((w.x - t.x) * d.x + (w.y - t.y) * d.y) / wing
            let barb = acos(min(1, max(-1, back))) * 180 / .pi
            guard (12...75).contains(barb) else { continue }
            let sides = ((k + 1)..<n).map { d.x * (s[$0].y - t.y) - d.y * (s[$0].x - t.x) }
            let reach = max(3, wing * 0.3)
            let two = sides.min()! <= -reach && sides.max()! >= reach
            if bothWings && !two { return nil }
            // A single hook: one clear side, a typical barb angle, a short barb.
            if !two, !(15...65).contains(barb) || wing > shaft * 0.3 { return nil }
            // The tip itself lies just after k along the stroke (not where a
            // wing returns to it: the shaft must not include the first wing).
            let tip = (k..<n).filter { arc[$0] - arc[k] <= max(4, wing * 0.3) }
                .max { (s[$0].x * d.x + s[$0].y * d.y) < (s[$1].x * d.x + s[$1].y * d.y) } ?? k
            return (tip, wing)
        }
        return nil
    }

    // MARK: Polyline

    /// Straight segments meeting at corners (≥ 28°), each snapped like a line
    /// and intersected at its neighbours. nil: no clean polyline (curves,
    /// scribbles, too many corners). Two vertices: a straight stroke.
    static func fitPolyline(_ raw: [PagePoint]) -> [PagePoint]? {
        let total = ShapeObject.length(raw)
        guard raw.count >= 2, total >= 30 else { return nil }
        let s = resampleOpen(raw, spacing: max(1, total / 200))
        guard s.count >= 8 else { return nil }
        let xs = s.map(\.x), ys = s.map(\.y)
        let diagonal = hypot(xs.max()! - xs.min()!, ys.max()! - ys.min()!)
        let minimumSegment = max(10, total * 0.06)
        var corners = simplifyIndices(s, epsilon: max(3, diagonal * 0.045))
        // Drop nearly straight or crowded corners, weakest first (ends stay).
        while corners.count > 2 {
            let scores = (1..<(corners.count - 1)).map { i -> Double in
                let a = s[corners[i - 1]], b = s[corners[i]], c = s[corners[i + 1]]
                let angle = turn(a, b, c)
                let short = min(hypot(b.x - a.x, b.y - a.y), hypot(c.x - b.x, c.y - b.y)) < minimumSegment
                return angle < 28 || short ? angle : .infinity
            }
            guard let weakest = scores.indices.min(by: { scores[$0] < scores[$1] }), scores[weakest].isFinite else { break }
            corners.remove(at: weakest + 1)
        }
        guard (2...8).contains(corners.count) else { return nil }
        guard corners.count > 2 else { return [s[0], s[s.count - 1]] }
        // A least-squares line per segment (its middle part), direction snapped.
        var lines: [(point: PagePoint, direction: (x: Double, y: Double))] = []
        for (a, b) in zip(corners, corners.dropFirst()) {
            let span = b - a
            let inner = Array(s[(a + span / 6)...(b - span / 6)])
            guard let line = fitLine(inner.count >= 2 ? inner : [s[a], s[b]], from: s[a], to: s[b]) else { return nil }
            lines.append(line)
        }
        var vertices = [project(s[0], on: lines[0])]
        for i in 1..<lines.count {
            let original = s[corners[i]]
            if let p = intersect(lines[i - 1], lines[i]), hypot(p.x - original.x, p.y - original.y) <= minimumSegment {
                vertices.append(p)
            } else { vertices.append(original) }
        }
        vertices.append(project(s[s.count - 1], on: lines[lines.count - 1]))
        // Verify: every segment long enough and straight (no arcs), small mean error.
        for (index, (a, b)) in zip(corners, corners.dropFirst()).enumerated() {
            let p = vertices[index], q = vertices[index + 1], length = hypot(q.x - p.x, q.y - p.y)
            guard length >= minimumSegment * 0.8 else { return nil }
            let part = s[a...b], span = b - a
            guard part.allSatisfy({ segmentDistance($0, p, q) <= max(5, length * 0.1) }) else { return nil }
            // Arcs bulge from the chord of their own samples; drawn straight edges do not.
            let chordA = s[a], chordB = s[b], chord = hypot(chordB.x - chordA.x, chordB.y - chordA.y)
            let middle = part.enumerated().filter { (0.3...0.7).contains(Double($0.offset) / Double(max(1, span))) }.map(\.element)
            if !middle.isEmpty, middle.reduce(0, { $0 + segmentDistance($1, chordA, chordB) }) / Double(middle.count) > max(2.5, chord * 0.05) { return nil }
        }
        let mean = s.reduce(0) { sum, p in
            sum + zip(vertices, vertices.dropFirst()).map { segmentDistance(p, $0.0, $0.1) }.min()!
        } / Double(s.count)
        guard mean <= max(2.5, diagonal * 0.035) else { return nil }
        return vertices
    }

    /// Principal direction through `points`, oriented from `from` to `to` and snapped.
    static func fitLine(_ points: [PagePoint], from: PagePoint, to: PagePoint) -> (point: PagePoint, direction: (x: Double, y: Double))? {
        let n = Double(points.count)
        let cx = points.reduce(0) { $0 + $1.x } / n, cy = points.reduce(0) { $0 + $1.y } / n
        var sxx = 0.0, syy = 0.0, sxy = 0.0
        for p in points { sxx += (p.x - cx) * (p.x - cx); syy += (p.y - cy) * (p.y - cy); sxy += (p.x - cx) * (p.y - cy) }
        var degrees = 0.5 * atan2(2 * sxy, sxx - syy) * 180 / .pi
        let u = (x: cos(degrees * .pi / 180), y: sin(degrees * .pi / 180))
        if (to.x - from.x) * u.x + (to.y - from.y) * u.y < 0 { degrees += 180 }
        guard degrees.isFinite else { return nil }
        return (PagePoint(x: cx, y: cy), LineSnapping.direction(LineSnapping.angle(degrees)))
    }
    static func project(_ p: PagePoint, on line: (point: PagePoint, direction: (x: Double, y: Double))) -> PagePoint {
        let t = (p.x - line.point.x) * line.direction.x + (p.y - line.point.y) * line.direction.y
        return .init(x: line.point.x + t * line.direction.x, y: line.point.y + t * line.direction.y)
    }
    /// Intersection of two lines; nil when (nearly) parallel.
    static func intersect(_ a: (point: PagePoint, direction: (x: Double, y: Double)),
                          _ b: (point: PagePoint, direction: (x: Double, y: Double))) -> PagePoint? {
        let cross = a.direction.x * b.direction.y - a.direction.y * b.direction.x
        guard abs(cross) > 0.2 else { return nil }
        let dx = b.point.x - a.point.x, dy = b.point.y - a.point.y
        let t = (dx * b.direction.y - dy * b.direction.x) / cross
        return .init(x: a.point.x + t * a.direction.x, y: a.point.y + t * a.direction.y)
    }

    // MARK: Sampling

    /// Moving average over five samples (ends kept).
    static func smoothed(_ points: [PagePoint]) -> [PagePoint] {
        guard points.count > 4 else { return points }
        return points.indices.map { i in
            guard i >= 2, i < points.count - 2 else { return points[i] }
            let window = points[(i - 2)...(i + 2)]
            return PagePoint(x: window.reduce(0) { $0 + $1.x } / 5, y: window.reduce(0) { $0 + $1.y } / 5)
        }
    }

    /// Uniform arc-length samples of an open stroke, both ends included.
    static func resampleOpen(_ points: [PagePoint], spacing: Double) -> [PagePoint] {
        guard let first = points.first, let last = points.last, points.count > 1 else { return points }
        let step = max(0.25, spacing.isFinite ? spacing : 1)
        var result = [first], carried = 0.0
        for (a, b) in zip(points, points.dropFirst()) {
            let length = hypot(b.x - a.x, b.y - a.y)
            guard length > 0 else { continue }
            var t = step - carried
            while t <= length {
                result.append(.init(x: a.x + (b.x - a.x) * t / length, y: a.y + (b.y - a.y) * t / length))
                t += step
            }
            carried = length - (t - step)
        }
        if let end = result.last, hypot(end.x - last.x, end.y - last.y) > step * 0.25 { result.append(last) }
        else { result[result.count - 1] = last }
        return result
    }
    static func arcLengths(_ points: [PagePoint]) -> [Double] {
        var result = [0.0]
        for (a, b) in zip(points, points.dropFirst()) { result.append(result[result.count - 1] + hypot(b.x - a.x, b.y - a.y)) }
        return result
    }
    /// Douglas–Peucker on an open stroke; indices of the kept samples (both ends).
    static func simplifyIndices(_ points: [PagePoint], epsilon: Double) -> [Int] {
        guard points.count > 2 else { return Array(points.indices) }
        var keep = Array(repeating: false, count: points.count); keep[0] = true; keep[points.count - 1] = true
        var stack = [(0, points.count - 1)]
        while let (from, to) = stack.popLast() {
            guard to > from + 1 else { continue }
            var best = from, distance = 0.0
            for i in (from + 1)..<to {
                let d = segmentDistance(points[i], points[from], points[to])
                if d > distance { distance = d; best = i }
            }
            if distance > epsilon { keep[best] = true; stack += [(from, best), (best, to)] }
        }
        return points.indices.filter { keep[$0] }
    }
}
