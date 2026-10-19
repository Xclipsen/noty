import Foundation

public enum PolygonKind: String, Sendable {
    case triangle, rightTriangle, equilateralTriangle, isoscelesTriangle, rectangle, square, rhombus, parallelogram, trapezoid, quadrilateral, pentagon, hexagon, heptagon, octagon, polygon, star
}

/// Result of an explicit hold. Rotations snap with `LineSnapping`; only
/// axis-aligned rectangles/ellipses and arrows map to editable `ShapeObject`s,
/// everything else becomes a native ink outline (no format change).
public enum RecognizedShape: Equatable, Sendable {
    case line(start: PagePoint, end: PagePoint)
    case arrow(start: PagePoint, tip: PagePoint)
    case ellipse(center: PagePoint, radiusX: Double, radiusY: Double, degrees: Double)
    case polygon(PolygonKind, [PagePoint])

    public func object(color: InkColor, lineWidth: Double) -> ShapeObject? {
        switch self {
        case .line: return nil
        case let .arrow(start, tip): return ShapeObject(kind: .arrow, start: start, end: tip, color: color, lineWidth: lineWidth)
        case let .ellipse(center, rx, ry, degrees):
            let quarter = degrees / 90
            guard quarter == quarter.rounded() else { return nil }
            let swap = Int(abs(quarter)) % 2 == 1
            let w = swap ? ry : rx, h = swap ? rx : ry
            return ShapeObject(kind: .ellipse, start: .init(x: center.x - w, y: center.y - h), end: .init(x: center.x + w, y: center.y + h),
                               color: color, lineWidth: lineWidth)
        case let .polygon(kind, vertices):
            guard kind == .rectangle || kind == .square, vertices.count == 4,
                  zip(vertices, vertices.dropFirst() + [vertices[0]]).allSatisfy({ abs($0.x - $1.x) < 1e-6 || abs($0.y - $1.y) < 1e-6 }) else { return nil }
            let xs = vertices.map(\.x), ys = vertices.map(\.y)
            return ShapeObject(kind: .rectangle, start: .init(x: xs.min()!, y: ys.min()!), end: .init(x: xs.max()!, y: ys.max()!),
                               color: color, lineWidth: lineWidth)
        }
    }
    /// Dense path for a native stroke. Polygon corners repeat, so the stroke's
    /// spline keeps them sharp; closed outlines end at their start.
    public func outline(spacing: Double = 8) -> [PagePoint] {
        let step = max(1, spacing.isFinite ? spacing : 8)
        func segment(_ a: PagePoint, _ b: PagePoint) -> [PagePoint] {
            let count = max(1, Int((hypot(b.x - a.x, b.y - a.y) / step).rounded(.up)))
            return (0..<count).map { i in let t = Double(i) / Double(count); return .init(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t) }
        }
        switch self {
        case let .line(start, end), let .arrow(start, end): return segment(start, end) + [end]
        case let .ellipse(center, rx, ry, degrees):
            let perimeter = .pi * (3 * (rx + ry) - sqrt((3 * rx + ry) * (rx + 3 * ry)))
            let count = min(160, max(24, Int(perimeter / step)))
            let unit = LineSnapping.direction(degrees)
            let points = (0..<count).map { i -> PagePoint in
                let t = Double(i) / Double(count) * 2 * .pi
                let a = rx * cos(t), b = ry * sin(t)
                return .init(x: center.x + a * unit.x - b * unit.y, y: center.y + a * unit.y + b * unit.x)
            }
            return points + [points[0]]
        case let .polygon(_, vertices):
            guard let first = vertices.first else { return [] }
            var path: [PagePoint] = []
            for (a, b) in zip(vertices, vertices.dropFirst() + [first]) {
                path += [a, a] + segment(a, b)
            }
            return path + [first, first, first]
        }
    }
}

/// Live adjustment of a held (recognised) shape while the Pencil stays down,
/// like Apple Notes: the shape follows the tip until lifting, then the result
/// is committed as one step.
/// - Lines: the start stays, the end follows the tip (angle snapping as before).
/// - Arrows: scale uniformly about the start (direction kept), so the shaft
///   grows/shrinks with the tip's distance from the start.
/// - Closed shapes (ellipse/circle, polygons): scale uniformly about their
///   centre by the tip's distance from the centre relative to where the
///   shape was recognised. Pulling outward enlarges, pushing inward shrinks;
///   circles stay circles, axis-aligned rectangles stay editable rectangles.
public struct HeldShapeAdjustment: Equatable, Sendable {
    public let base: RecognizedShape
    /// Tip position (canonical page points) when the shape was recognised.
    public let grab: PagePoint
    /// Smallest extent a scaled shape may reach.
    public static let minimumExtent = 6.0
    public static let maximumScale = 20.0
    public init(shape: RecognizedShape, grab: PagePoint) { base = shape; self.grab = grab }

    /// Fixed point of the adjustment.
    public var anchor: PagePoint {
        switch base {
        case let .line(start, _), let .arrow(start, _): start
        case let .ellipse(center, _, _, _): center
        case let .polygon(_, vertices):
            vertices.isEmpty ? grab : PagePoint(x: vertices.map(\.x).reduce(0, +) / Double(vertices.count),
                                                y: vertices.map(\.y).reduce(0, +) / Double(vertices.count))
        }
    }

    /// The shape for the current tip position; the base shape while the tip
    /// rests within 2 pt of where it was recognised.
    public func shape(at tip: PagePoint) -> RecognizedShape {
        guard tip.x.isFinite, tip.y.isFinite, hypot(tip.x - grab.x, tip.y - grab.y) >= 2 else { return base }
        if case let .line(start, _) = base { return .line(start: start, end: LineSnapping.end(from: start, to: tip)) }
        let pivot = anchor
        let reach = hypot(grab.x - pivot.x, grab.y - pivot.y)
        guard reach >= 8 else { return base }
        let requested = hypot(tip.x - pivot.x, tip.y - pivot.y) / reach
        let extent = Self.extent(of: base)
        let minimum = extent > 0 ? min(1, Self.minimumExtent / extent) : 1
        return Self.scaled(base, by: min(Self.maximumScale, max(minimum, requested)), about: pivot)
    }

    static func extent(of shape: RecognizedShape) -> Double {
        switch shape {
        case let .line(a, b), let .arrow(a, b): return hypot(b.x - a.x, b.y - a.y)
        case let .ellipse(_, rx, ry, _): return 2 * min(rx, ry)
        case let .polygon(_, vertices):
            guard let minX = vertices.map(\.x).min(), let maxX = vertices.map(\.x).max(),
                  let minY = vertices.map(\.y).min(), let maxY = vertices.map(\.y).max() else { return 0 }
            return min(maxX - minX, maxY - minY)
        }
    }

    static func scaled(_ shape: RecognizedShape, by factor: Double, about pivot: PagePoint) -> RecognizedShape {
        func map(_ p: PagePoint) -> PagePoint { .init(x: pivot.x + (p.x - pivot.x) * factor, y: pivot.y + (p.y - pivot.y) * factor) }
        switch shape {
        case let .line(a, b): return .line(start: map(a), end: map(b))
        case let .arrow(a, b): return .arrow(start: map(a), tip: map(b))
        case let .ellipse(center, rx, ry, degrees): return .ellipse(center: map(center), radiusX: rx * factor, radiusY: ry * factor, degrees: degrees)
        case let .polygon(kind, vertices): return .polygon(kind, vertices.map(map))
        }
    }
}

/// Conservative recognition after an explicit hold, never on normal writing.
public enum ShapeRecognition {
    /// An explicit hold tolerates a visibly wavy line; ordinary writing never
    /// calls this fallback. Reject loops, dots and open multi-part scribbles.
    public static func lineAfterHold(_ points: [PagePoint]) -> Bool {
        guard points.count >= 2, let first = points.first, let last = points.last,
              points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return false }
        let length = hypot(last.x - first.x, last.y - first.y)
        guard length >= 24 else { return false }
        let dx = last.x - first.x, dy = last.y - first.y
        let offset = last.x * first.y - last.y * first.x
        var deviation = 0.0, traveled = 0.0
        for index in points.indices {
            let point = points[index]
            deviation = max(deviation, abs(dy * point.x - dx * point.y + offset) / length)
            if index > 0 { traveled += hypot(point.x - points[index - 1].x, point.y - points[index - 1].y) }
        }
        return deviation <= max(12, length * 0.18) && traveled <= length * 1.8
    }
    public static func recognize(_ points: [PagePoint]) -> ShapeKind? {
        switch shape(points) {
        case .line: return .line
        case .arrow: return .arrow
        case .ellipse: return .ellipse
        case let .polygon(kind, _): return kind == .rectangle || kind == .square ? .rectangle : nil
        case nil: return nil
        }
    }
    public static func shape(_ points: [PagePoint]) -> RecognizedShape? {
        guard points.count >= 5, points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }),
              let first = points.first, let last = points.last else { return nil }
        let xs = points.map(\.x), ys = points.map(\.y)
        let width = xs.max()! - xs.min()!, height = ys.max()! - ys.min()!, diagonal = hypot(width, height)
        guard diagonal >= 24 else { return nil }
        let distance = hypot(last.x - first.x, last.y - first.y)
        // A single-stroke arrow: straight shaft, then two short wings around its tip.
        if let tipIndex = points.indices.max(by: { hypot(points[$0].x-first.x, points[$0].y-first.y) < hypot(points[$1].x-first.x, points[$1].y-first.y) }),
           tipIndex >= points.count / 2, tipIndex < points.count - 2 {
            let tip = points[tipIndex], length = hypot(tip.x-first.x, tip.y-first.y)
            if length >= 40 {
                let shaft = points[0...tipIndex]
                let deviations = shaft.map { abs((tip.y-first.y)*$0.x - (tip.x-first.x)*$0.y + tip.x*first.y-tip.y*first.x) / length }
                let wings = points[(tipIndex+1)...]
                let sides = wings.map { ((tip.x-first.x)*($0.y-tip.y) - (tip.y-first.y)*($0.x-tip.x)) / length }
                if deviations.max()! <= max(3, length*0.035),
                   wings.allSatisfy({ hypot($0.x-tip.x, $0.y-tip.y) <= length*0.38 }),
                   sides.min()! < -4, sides.max()! > 4 { return .arrow(start: first, tip: LineSnapping.end(from: first, to: tip)) }
            }
        }
        if distance > diagonal * 0.75 {
            let deviation = points.map { abs((last.y - first.y) * $0.x - (last.x - first.x) * $0.y + last.x * first.y - last.y * first.x) / distance }.max()!
            return deviation <= max(3, diagonal * 0.035) ? .line(start: first, end: LineSnapping.end(from: first, to: last)) : nil
        }
        guard width >= 12, height >= 12 else { return nil }
        // Forgiving closure: an overshoot past the start is cut off, a gap of
        // up to a fifth of the outline is closed.
        let loop = trimmedOvershoot(points)
        let length = zip(loop, loop.dropFirst()).reduce(0) { $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) }
        guard let end = loop.last, hypot(end.x - first.x, end.y - first.y) <= max(diagonal * 0.2, length * 0.2) else { return nil }
        return closedShape(loop, diagonal: diagonal)
    }
    /// Cuts a closing overshoot at the point (in the last part) nearest the start.
    static func trimmedOvershoot(_ points: [PagePoint]) -> [PagePoint] {
        guard let first = points.first, points.count > 8 else { return points }
        let fractions = StraightStroke.arcFractions(points)
        let tail = points.indices.filter { fractions[$0] >= 0.6 }
        guard let nearest = tail.min(by: { hypot(points[$0].x - first.x, points[$0].y - first.y) < hypot(points[$1].x - first.x, points[$1].y - first.y) }),
              nearest < points.count - 1 else { return points }
        return Array(points[...nearest])
    }

    // MARK: Closed outlines

    private static func closedShape(_ points: [PagePoint], diagonal: Double) -> RecognizedShape? {
        let samples = resampleLoop(points, count: 120)
        guard samples.count >= 12 else { return nil }
        let ellipse = fitEllipse(samples)
        var vertices = loopCorners(samples, epsilon: max(3, diagonal * 0.05))
        vertices = mergeStraight(vertices, minimumTurn: 22, minimumEdge: diagonal * 0.08)
        let polygonError = vertices.count >= 3 ? meanDistance(samples, polygon: vertices) / diagonal : .infinity
        let ellipseError = ellipse.error / diagonal
        // Corners with straight edges make a polygon; a round outline (even a
        // lumpy one whose bumps look like corners) bulges between them.
        // Round outlines yield at least five or six corners here, so up to four
        // corners tolerate rounded drawing (the chord then cuts the corner arcs).
        if (3...12).contains(vertices.count), polygonError < 0.04,
           edgeBulge(samples, corners: vertices) < (vertices.count <= 4 ? 0.065 : 0.035),
           let polygon = classify(vertices) { return polygon }
        return ellipseError < 0.06 && ellipse.maximum / diagonal < 0.1 ? ellipse.shape : nil
    }
    /// Uniform arc-length samples of a closed loop (slow or held parts do not weigh more).
    static func resampleLoop(_ points: [PagePoint], count: Int) -> [PagePoint] {
        var loop = points
        if let first = points.first, let last = points.last, hypot(last.x - first.x, last.y - first.y) > 0.01 { loop.append(first) }
        var distances = [0.0]
        for i in loop.indices.dropFirst() { distances.append(distances[i - 1] + hypot(loop[i].x - loop[i - 1].x, loop[i].y - loop[i - 1].y)) }
        guard let total = distances.last, total > 0 else { return [] }
        var result: [PagePoint] = [], cursor = 1
        for k in 0..<count {
            let target = total * Double(k) / Double(count)
            while cursor < loop.count - 1, distances[cursor] < target { cursor += 1 }
            let span = distances[cursor] - distances[cursor - 1]
            let t = span > 0 ? (target - distances[cursor - 1]) / span : 0
            let a = loop[cursor - 1], b = loop[cursor]
            result.append(.init(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
        }
        return result
    }
    /// Mean and largest absolute deviation from the fitted ellipse/circle.
    private static func fitEllipse(_ samples: [PagePoint]) -> (shape: RecognizedShape, error: Double, maximum: Double) {
        let n = Double(samples.count)
        let cx = samples.reduce(0) { $0 + $1.x } / n, cy = samples.reduce(0) { $0 + $1.y } / n
        var sxx = 0.0, syy = 0.0, sxy = 0.0
        for p in samples { sxx += (p.x - cx) * (p.x - cx); syy += (p.y - cy) * (p.y - cy); sxy += (p.x - cx) * (p.y - cy) }
        let theta = 0.5 * atan2(2 * sxy, sxx - syy)
        let u = (x: cos(theta), y: sin(theta))
        let a = samples.map { ($0.x - cx) * u.x + ($0.y - cy) * u.y }, b = samples.map { -($0.x - cx) * u.y + ($0.y - cy) * u.x }
        let midA = (a.max()! + a.min()!) / 2, midB = (b.max()! + b.min()!) / 2
        let rx = max(0.5, (a.max()! - a.min()!) / 2), ry = max(0.5, (b.max()! - b.min()!) / 2)
        let center = PagePoint(x: cx + u.x * midA - u.y * midB, y: cy + u.y * midA + u.x * midB)
        if min(rx, ry) / max(rx, ry) >= 0.8 {
            let distances = samples.map { hypot($0.x - center.x, $0.y - center.y) }
            let r = distances.reduce(0, +) / n
            return (.ellipse(center: center, radiusX: r, radiusY: r, degrees: 0), distances.reduce(0) { $0 + abs($1 - r) } / n,
                    distances.map { abs($0 - r) }.max()!)
        }
        let deviations = zip(a, b).map { abs(hypot(($0.0 - midA) / rx, ($0.1 - midB) / ry) - 1) * (rx + ry) / 2 }
        // Hold only produces circles (ellipses are drawn with the shape tool):
        // an oval is recognised by its ellipse fit and becomes a centred circle
        // of the mean drawn radius.
        let radius = samples.reduce(0) { $0 + hypot($1.x - center.x, $1.y - center.y) } / n
        return (.ellipse(center: center, radiusX: radius, radiusY: radius, degrees: 0), deviations.reduce(0, +) / n, deviations.max()!)
    }
    /// Douglas–Peucker on a loop, starting at its most distant (corner-like) point.
    static func loopCorners(_ samples: [PagePoint], epsilon: Double) -> [PagePoint] {
        let n = Double(samples.count)
        let cx = samples.reduce(0) { $0 + $1.x } / n, cy = samples.reduce(0) { $0 + $1.y } / n
        let start = samples.indices.max { hypot(samples[$0].x - cx, samples[$0].y - cy) < hypot(samples[$1].x - cx, samples[$1].y - cy) }!
        let loop = Array(samples[start...] + samples[..<start])
        let far = loop.indices.max { hypot(loop[$0].x - loop[0].x, loop[$0].y - loop[0].y) < hypot(loop[$1].x - loop[0].x, loop[$1].y - loop[0].y) }!
        let firstHalf = simplify(Array(loop[0...far]), epsilon: epsilon)
        let secondHalf = simplify(Array(loop[far...]) + [loop[0]], epsilon: epsilon)
        return firstHalf + secondHalf.dropFirst().dropLast()
    }
    static func simplify(_ points: [PagePoint], epsilon: Double) -> [PagePoint] {
        guard points.count > 2 else { return points }
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
        return points.indices.filter { keep[$0] }.map { points[$0] }
    }
    static func segmentDistance(_ p: PagePoint, _ a: PagePoint, _ b: PagePoint) -> Double {
        let dx = b.x - a.x, dy = b.y - a.y, length = dx * dx + dy * dy
        guard length > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = min(1, max(0, ((p.x - a.x) * dx + (p.y - a.y) * dy) / length))
        return hypot(p.x - a.x - t * dx, p.y - a.y - t * dy)
    }
    private static func turn(_ a: PagePoint, _ b: PagePoint, _ c: PagePoint) -> Double {
        let u = (x: b.x - a.x, y: b.y - a.y), v = (x: c.x - b.x, y: c.y - b.y)
        let lengths = hypot(u.x, u.y) * hypot(v.x, v.y)
        guard lengths > 0 else { return 0 }
        return acos(min(1, max(-1, (u.x * v.x + u.y * v.y) / lengths))) * 180 / .pi
    }
    /// Drops nearly straight or crowded vertices, weakest first.
    static func mergeStraight(_ input: [PagePoint], minimumTurn: Double, minimumEdge: Double) -> [PagePoint] {
        var vertices = input
        while vertices.count > 3 {
            let count = vertices.count
            let scores = vertices.indices.map { i -> Double in
                let previous = vertices[(i + count - 1) % count], next = vertices[(i + 1) % count]
                let angle = turn(previous, vertices[i], next)
                let short = min(hypot(vertices[i].x - previous.x, vertices[i].y - previous.y), hypot(next.x - vertices[i].x, next.y - vertices[i].y)) < minimumEdge
                return angle < minimumTurn || short ? angle : .infinity
            }
            guard let weakest = scores.indices.min(by: { scores[$0] < scores[$1] }), scores[weakest].isFinite else { break }
            vertices.remove(at: weakest)
        }
        return vertices
    }
    /// Mean deviation of each edge's middle part from its chord, relative to the edge length.
    static func edgeBulge(_ samples: [PagePoint], corners: [PagePoint]) -> Double {
        let indices = corners.compactMap { corner in samples.firstIndex { $0 == corner } }
        guard indices.count == corners.count, indices.count >= 3 else { return .infinity }
        let m = samples.count
        var total = 0.0
        for (k, start) in indices.enumerated() {
            let end = indices[(k + 1) % indices.count]
            let span = (end - start + m) % m
            let a = samples[start], b = samples[end], length = hypot(b.x - a.x, b.y - a.y)
            guard span >= 2, length > 0 else { continue }
            let inner = (1..<span).filter { (0.3...0.7).contains(Double($0) / Double(span)) }.map { samples[(start + $0) % m] }
            guard !inner.isEmpty else { continue }
            total += inner.reduce(0) { $0 + abs((b.x - a.x) * ($1.y - a.y) - (b.y - a.y) * ($1.x - a.x)) / length } / Double(inner.count) / length
        }
        return total / Double(indices.count)
    }
    static func meanDistance(_ samples: [PagePoint], polygon: [PagePoint]) -> Double {
        let edges = Array(zip(polygon, polygon.dropFirst() + [polygon[0]]))
        return samples.reduce(0) { sum, p in sum + edges.map { segmentDistance(p, $0.0, $0.1) }.min()! } / Double(samples.count)
    }

    // MARK: Polygon classification and snapping

    private static func centroid(_ points: [PagePoint]) -> PagePoint {
        .init(x: points.reduce(0) { $0 + $1.x } / Double(points.count), y: points.reduce(0) { $0 + $1.y } / Double(points.count))
    }
    private static func degrees(_ a: PagePoint, _ b: PagePoint) -> Double { atan2(b.y - a.y, b.x - a.x) * 180 / .pi }
    private static func rotate(_ points: [PagePoint], by delta: Double, around pivot: PagePoint) -> [PagePoint] {
        guard delta != 0 else { return points }
        let c = cos(delta * .pi / 180), s = sin(delta * .pi / 180)
        return points.map { .init(x: pivot.x + ($0.x - pivot.x) * c - ($0.y - pivot.y) * s, y: pivot.y + ($0.x - pivot.x) * s + ($0.y - pivot.y) * c) }
    }
    /// Smallest rotation that snaps one of the given directions (0 if none is near a snap).
    static func snapDelta(_ angles: [Double]) -> Double {
        angles.compactMap { angle in LineSnapping.target(angle).map { $0 - angle } }.min { abs($0) < abs($1) } ?? 0
    }
    /// Rotation snapped on an edge; exact on axes where the snap is 0°/90°.
    private static func snapEdges(_ vertices: [PagePoint]) -> [PagePoint] {
        let edges = zip(vertices, vertices.dropFirst() + [vertices[0]]).map { degrees($0.0, $0.1) }
        let delta = snapDelta(edges)
        guard delta != 0 else { return vertices }
        let rotated = rotate(vertices, by: delta, around: centroid(vertices))
        return straightenAxes(rotated)
    }
    /// After a rotation onto the axes, equalise the coordinates of axis-parallel edges exactly.
    private static func straightenAxes(_ vertices: [PagePoint]) -> [PagePoint] {
        var result = vertices
        let count = result.count
        for i in 0..<count {
            let j = (i + 1) % count, a = result[i], b = result[j]
            let angle = degrees(a, b)
            let quarter = (angle / 90).rounded()
            guard abs(angle - quarter * 90) < 1e-6 else { continue }
            if Int(abs(quarter)) % 2 == 0 { let y = (a.y + b.y) / 2; result[i].y = y; result[j].y = y }
            else { let x = (a.x + b.x) / 2; result[i].x = x; result[j].x = x }
        }
        return result
    }
    private static func regular(_ count: Int, center: PagePoint, radius: Double, startDegrees: Double, clockwise: Bool, radii: [Double]? = nil) -> [PagePoint] {
        (0..<count).map { k in
            let angle = (startDegrees + Double(k) * 360 / Double(count) * (clockwise ? 1 : -1)) * .pi / 180
            let r = radii?[k % radii!.count] ?? radius
            return .init(x: center.x + r * cos(angle), y: center.y + r * sin(angle))
        }
    }
    private static func signedArea(_ v: [PagePoint]) -> Double {
        zip(v, v.dropFirst() + [v[0]]).reduce(0) { $0 + $1.0.x * $1.1.y - $1.1.x * $1.0.y } / 2
    }
    private static func spread(_ values: [Double]) -> Double {
        let mean = values.reduce(0, +) / Double(values.count)
        guard mean > 0 else { return .infinity }
        return (values.max()! - values.min()!) / mean
    }
    private static func isConvex(_ v: [PagePoint]) -> Bool {
        let n = v.count
        let turns = v.indices.map { i -> Double in
            let a = v[(i + n - 1) % n], b = v[i], c = v[(i + 1) % n]
            return (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x)
        }
        return turns.allSatisfy { $0 > 0 } || turns.allSatisfy { $0 < 0 }
    }
    /// Angle between two directions as undirected lines, 0…90°.
    private static func lineDifference(_ a: Double, _ b: Double) -> Double {
        let d = abs((a - b).truncatingRemainder(dividingBy: 180)); return min(d, 180 - d)
    }
    /// Parallelogram (both side pairs near parallel) or symmetric trapezoid (one pair).
    static func parallelQuad(_ v: [PagePoint]) -> RecognizedShape? {
        let e = (0..<4).map { degrees(v[$0], v[($0 + 1) % 4]) }
        let first = lineDifference(e[0], e[2]) <= 12, second = lineDifference(e[1], e[3]) <= 12
        if first && second {
            let a = (x: ((v[1].x - v[0].x) + (v[2].x - v[3].x)) / 2, y: ((v[1].y - v[0].y) + (v[2].y - v[3].y)) / 2)
            let b = (x: ((v[3].x - v[0].x) + (v[2].x - v[1].x)) / 2, y: ((v[3].y - v[0].y) + (v[2].y - v[1].y)) / 2)
            let c = centroid(v)
            var shape = [PagePoint(x: c.x - a.x / 2 - b.x / 2, y: c.y - a.y / 2 - b.y / 2), PagePoint(x: c.x + a.x / 2 - b.x / 2, y: c.y + a.y / 2 - b.y / 2),
                         PagePoint(x: c.x + a.x / 2 + b.x / 2, y: c.y + a.y / 2 + b.y / 2), PagePoint(x: c.x - a.x / 2 + b.x / 2, y: c.y - a.y / 2 + b.y / 2)]
            let angle = atan2(a.y, a.x) * 180 / .pi
            shape = straightenAxes(rotate(shape, by: (LineSnapping.target(angle) ?? angle) - angle, around: c))
            return .polygon(.parallelogram, shape)
        }
        guard first || second else { return nil }
        // Work with the parallel pair as edges 0→1 and 3→2, then restore the order.
        let shift = first ? 0 : 1
        let w = (0..<4).map { v[($0 + shift) % 4] }
        let l1 = hypot(w[1].x - w[0].x, w[1].y - w[0].y), l2 = hypot(w[2].x - w[3].x, w[2].y - w[3].y)
        guard l1 > 0, l2 > 0 else { return nil }
        let raw = atan2((w[1].y - w[0].y) / l1 + (w[2].y - w[3].y) / l2, (w[1].x - w[0].x) / l1 + (w[2].x - w[3].x) / l2) * 180 / .pi
        let u = LineSnapping.direction(LineSnapping.target(raw) ?? raw), n = (x: -u.y, y: u.x)
        let c = centroid(w)
        func local(_ p: PagePoint) -> (s: Double, t: Double) { ((p.x - c.x) * u.x + (p.y - c.y) * u.y, (p.x - c.x) * n.x + (p.y - c.y) * n.y) }
        let p = w.map(local)
        let axis = ((p[0].s + p[1].s) / 2 + (p[2].s + p[3].s) / 2) / 2
        let lower = (p[0].t + p[1].t) / 2, upper = (p[2].t + p[3].t) / 2
        let half1 = abs(p[1].s - p[0].s) / 2 * (p[1].s >= p[0].s ? 1 : -1), half2 = abs(p[2].s - p[3].s) / 2 * (p[2].s >= p[3].s ? 1 : -1)
        let ideal = [(axis - half1, lower), (axis + half1, lower), (axis + half2, upper), (axis - half2, upper)].map {
            PagePoint(x: c.x + u.x * $0.0 + n.x * $0.1, y: c.y + u.y * $0.0 + n.y * $0.1)
        }
        return .polygon(.trapezoid, straightenAxes((0..<4).map { ideal[($0 - shift + 4) % 4] }))
    }
    static func classify(_ vertices: [PagePoint]) -> RecognizedShape? {
        let n = vertices.count
        guard (3...12).contains(n) else { return nil }
        let center = centroid(vertices)
        let radii = vertices.map { hypot($0.x - center.x, $0.y - center.y) }
        let sides = zip(vertices, vertices.dropFirst() + [vertices[0]]).map { hypot($1.x - $0.x, $1.y - $0.y) }
        let interior = vertices.indices.map { 180 - turn(vertices[($0 + n - 1) % n], vertices[$0], vertices[($0 + 1) % n]) }
        let clockwise = signedArea(vertices) >= 0
        let meanRadius = radii.reduce(0, +) / Double(n)
        let polar = vertices.map { degrees(center, $0) }
        // Pentagram drawn in one stroke: five tips visited every second one.
        if n == 5 {
            let order = polar.indices.sorted { polar[$0] < polar[$1] }
            var rank = Array(repeating: 0, count: 5); for (r, i) in order.enumerated() { rank[i] = r }
            let steps = Set((0..<5).map { (rank[($0 + 1) % 5] - rank[$0] + 5) % 5 })
            if steps == [2] || steps == [3], spread(radii) < 0.35 {
                let tips = regular(5, center: center, radius: meanRadius, startDegrees: polar[0], clockwise: true)
                let delta = snapDelta(tips.map { degrees(center, $0) })
                let star = rotate(tips, by: delta, around: center)
                let path = steps == [2] ? [0, 2, 4, 1, 3] : [0, 3, 1, 4, 2]
                return .polygon(.star, path.map { star[$0] })
            }
        }
        // Star outline: alternating outer tips and inner corners.
        if n % 2 == 0, (8...12).contains(n) {
            let even = stride(from: 0, to: n, by: 2).map { radii[$0] }, odd = stride(from: 1, to: n, by: 2).map { radii[$0] }
            let (outer, inner, offset) = even.reduce(0, +) > odd.reduce(0, +) ? (even, odd, 0) : (odd, even, 1)
            let outerMean = outer.reduce(0, +) / Double(outer.count), innerMean = inner.reduce(0, +) / Double(inner.count)
            if outer.min()! > inner.max()!, innerMean / outerMean < 0.75, spread(outer) < 0.35, spread(inner) < 0.45 {
                var star = regular(n, center: center, radius: outerMean, startDegrees: polar[offset], clockwise: clockwise, radii: [outerMean, innerMean])
                star = rotate(star, by: snapDelta(stride(from: 0, to: n, by: 2).map { degrees(center, star[$0]) }), around: center)
                return .polygon(.star, star)
            }
        }
        guard interior.allSatisfy({ $0 > 15 }), n <= 8 else { return nil }
        switch n {
        case 3:
            let largest = interior.indices.max { interior[$0] < interior[$1] }!
            if (78...102).contains(interior[largest]) {
                // Right triangle; legs within 25 % become an isosceles right triangle.
                let a = vertices[largest], b = vertices[(largest + 1) % 3], c = vertices[(largest + 2) % 3]
                var leg1 = hypot(b.x - a.x, b.y - a.y), leg2 = hypot(c.x - a.x, c.y - a.y)
                if min(leg1, leg2) / max(leg1, leg2) >= 0.75 { let leg = (leg1 + leg2) / 2; leg1 = leg; leg2 = leg }
                let u = (x: (b.x - a.x) / hypot(b.x - a.x, b.y - a.y), y: (b.y - a.y) / hypot(b.x - a.x, b.y - a.y))
                let side = (c.x - a.x) * -u.y + (c.y - a.y) * u.x >= 0 ? 1.0 : -1.0
                var triangle = [a, PagePoint(x: a.x + u.x * leg1, y: a.y + u.y * leg1), PagePoint(x: a.x - u.y * leg2 * side, y: a.y + u.x * leg2 * side)]
                let delta = snapDelta([degrees(a, triangle[1]), degrees(a, triangle[2])])
                triangle = straightenAxes(rotate(triangle, by: delta, around: a))
                return .polygon(.rightTriangle, (0..<3).map { triangle[($0 - largest + 3) % 3] })
            }
            if interior.allSatisfy({ abs($0 - 60) <= 15 }) {
                let triangle = regular(3, center: center, radius: meanRadius, startDegrees: polar[0], clockwise: clockwise)
                return .polygon(.equilateralTriangle, snapEdges(triangle))
            }
            // Isosceles when two sides (meeting at the apex) are within 20 %.
            if let apex = (0..<3).first(where: { k in
                let left = sides[(k + 2) % 3], right = sides[k]; return min(left, right) / max(left, right) >= 0.8 }) {
                let top = vertices[apex], p = vertices[(apex + 1) % 3], q = vertices[(apex + 2) % 3]
                let baseLength = hypot(q.x - p.x, q.y - p.y)
                let mid = PagePoint(x: (p.x + q.x) / 2, y: (p.y + q.y) / 2)
                var u = (x: (q.x - p.x) / baseLength, y: (q.y - p.y) / baseLength)
                let angle = degrees(p, q), snapped = LineSnapping.target(angle) ?? angle
                u = LineSnapping.direction(snapped)
                let normal = (x: -u.y, y: u.x)
                let height = (top.x - mid.x) * normal.x + (top.y - mid.y) * normal.y
                let half = baseLength / 2
                var triangle = [PagePoint(x: mid.x + normal.x * height, y: mid.y + normal.y * height),
                                PagePoint(x: mid.x - u.x * half, y: mid.y - u.y * half), PagePoint(x: mid.x + u.x * half, y: mid.y + u.y * half)]
                triangle = straightenAxes(triangle)
                return .polygon(.isoscelesTriangle, (0..<3).map { triangle[($0 - apex + 3) % 3] })
            }
            return .polygon(.triangle, snapEdges(vertices))
        case 4:
            let convex = isConvex(vertices)
            // Equal sides with clearly oblique angles stay a rhombus (diamond).
            let rightTolerance = spread(sides) < 0.25 ? 10.0 : 18.0
            if convex, interior.allSatisfy({ abs($0 - 90) <= rightTolerance }) {
                let edges = zip(vertices, vertices.dropFirst() + [vertices[0]]).map { degrees($0.0, $0.1) * .pi / 180 }
                let theta = LineSnapping.angle(atan2(edges.reduce(0) { $0 + sin(4 * $1) }, edges.reduce(0) { $0 + cos(4 * $1) }) / 4 * 180 / .pi)
                let u = LineSnapping.direction(theta)
                let a = vertices.map { ($0.x - center.x) * u.x + ($0.y - center.y) * u.y }
                let b = vertices.map { -($0.x - center.x) * u.y + ($0.y - center.y) * u.x }
                var ha = (a.max()! - a.min()!) / 2, hb = (b.max()! - b.min()!) / 2
                let mid = PagePoint(x: center.x + u.x * (a.max()! + a.min()!) / 2 - u.y * (b.max()! + b.min()!) / 2,
                                    y: center.y + u.y * (a.max()! + a.min()!) / 2 + u.x * (b.max()! + b.min()!) / 2)
                let square = min(ha, hb) / max(ha, hb) >= 0.75
                if square { let h = (ha + hb) / 2; ha = h; hb = h }
                let signs: [(Double, Double)] = clockwise ? [(-1, -1), (1, -1), (1, 1), (-1, 1)] : [(-1, -1), (-1, 1), (1, 1), (1, -1)]
                let corners = signs.map { s in
                    PagePoint(x: mid.x + u.x * ha * s.0 - u.y * hb * s.1, y: mid.y + u.y * ha * s.0 + u.x * hb * s.1)
                }
                return .polygon(square ? .square : .rectangle, straightenAxes(corners))
            }
            if convex, spread(sides) < 0.25 {
                let d1 = (x: vertices[2].x - vertices[0].x, y: vertices[2].y - vertices[0].y)
                let d2 = (x: vertices[3].x - vertices[1].x, y: vertices[3].y - vertices[1].y)
                let u = LineSnapping.direction(LineSnapping.angle(atan2(d1.y, d1.x) * 180 / .pi))
                let p = abs(d1.x * u.x + d1.y * u.y) / 2, q = abs(-d2.x * u.y + d2.y * u.x) / 2
                let side = (-d2.x * u.y + d2.y * u.x) >= 0 ? 1.0 : -1.0
                let rhombus = [PagePoint(x: center.x - u.x * p, y: center.y - u.y * p),
                               PagePoint(x: center.x + u.y * q * side, y: center.y - u.x * q * side),
                               PagePoint(x: center.x + u.x * p, y: center.y + u.y * p),
                               PagePoint(x: center.x - u.y * q * side, y: center.y + u.x * q * side)]
                return .polygon(.rhombus, straightenAxes(rhombus))
            }
            if convex, let shape = parallelQuad(vertices) { return shape }
            return .polygon(.quadrilateral, snapEdges(vertices))
        default:
            // 5–8 corners on a convex outline: a regular n-gon of the drawn size.
            let kind: PolygonKind = [5: .pentagon, 6: .hexagon, 7: .heptagon, 8: .octagon][n] ?? .polygon
            let turns = vertices.indices.map { i -> Double in
                let a = vertices[(i + n - 1) % n], b = vertices[i], c = vertices[(i + 1) % n]
                return (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x)
            }
            guard turns.allSatisfy({ $0 > 0 }) || turns.allSatisfy({ $0 < 0 }), spread(radii) < 0.5 else { return nil }
            return .polygon(kind, snapEdges(regular(n, center: center, radius: meanRadius, startDegrees: polar[0], clockwise: clockwise)))
        }
    }
}
