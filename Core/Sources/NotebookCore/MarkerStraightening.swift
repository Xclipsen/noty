import Foundation

/// Angle snapping for everything made straight (straight marker, held lines,
/// recognised lines/arrows). Horizontal/vertical snap strongly; multiples of
/// 45° and 30° only within a narrow band. Elsewhere the drawn angle stays.
public enum LineSnapping {
    public static let strongTolerance = 10.0
    public static let diagonalTolerance = 5.0
    public static let thirtyTolerance = 4.0

    /// Direction in degrees (any range), snapped or unchanged.
    public static func angle(_ degrees: Double) -> Double { target(degrees) ?? degrees }
    /// The snap angle within reach, or nil when the drawn angle stays.
    public static func target(_ degrees: Double) -> Double? {
        guard degrees.isFinite else { return nil }
        for (step, tolerance) in [(90.0, strongTolerance), (45.0, diagonalTolerance), (30.0, thirtyTolerance)] {
            let nearest = (degrees / step).rounded() * step
            if abs(degrees - nearest) <= tolerance { return nearest }
        }
        return nil
    }
    /// Exact unit vectors on the axes, so snapped lines are truly level/plumb.
    static func direction(_ degrees: Double) -> (x: Double, y: Double) {
        let quarter = degrees / 90
        if quarter == quarter.rounded() {
            switch ((Int(quarter) % 4) + 4) % 4 { case 0: return (1, 0); case 1: return (0, 1); case 2: return (-1, 0); default: return (0, -1) }
        }
        let radians = degrees * .pi / 180
        return (cos(radians), sin(radians))
    }
    /// Keeps `start` and the length; only the direction snaps.
    public static func end(from start: PagePoint, to end: PagePoint) -> PagePoint {
        let dx = end.x - start.x, dy = end.y - start.y, length = hypot(dx, dy)
        guard length > 0, length.isFinite else { return end }
        let unit = direction(angle(atan2(dy, dx) * 180 / .pi))
        return PagePoint(x: start.x + unit.x * length, y: start.y + unit.y * length)
    }
    /// Least-squares line through a stroke, snapped and clipped to its extent,
    /// oriented from the first towards the last drawn point.
    public static func fit(_ points: [PagePoint]) -> (start: PagePoint, end: PagePoint)? {
        guard let first = points.first, let last = points.last, points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return nil }
        let count = Double(points.count)
        let cx = points.reduce(0) { $0 + $1.x } / count, cy = points.reduce(0) { $0 + $1.y } / count
        var sxx = 0.0, syy = 0.0, sxy = 0.0
        for point in points { sxx += (point.x - cx) * (point.x - cx); syy += (point.y - cy) * (point.y - cy); sxy += (point.x - cx) * (point.y - cy) }
        var degrees = 0.5 * atan2(2 * sxy, sxx - syy) * 180 / .pi
        var unit = direction(degrees)
        if (last.x - first.x) * unit.x + (last.y - first.y) * unit.y < 0 { degrees += 180 }
        unit = direction(angle(degrees))
        let offsets = points.map { ($0.x - cx) * unit.x + ($0.y - cy) * unit.y }
        let low = offsets.min()!, high = offsets.max()!
        return (PagePoint(x: cx + unit.x * low, y: cy + unit.y * low), PagePoint(x: cx + unit.x * high, y: cy + unit.y * high))
    }
}

/// Optional straight highlighter: a finished marker stroke becomes one
/// straight segment through its points. 0°/90° dominate, 45°/30° multiples
/// snap narrowly (`LineSnapping`). Horizontal lines sit at the stroke's mean
/// height, so a wobbly pass over a text line lands centred on it.
public enum MarkerStraightening {
    /// Strokes shorter than this (taps, dots) stay as drawn.
    public static let minimumLength = 6.0
    /// Softens highlighter colours so text below stays readable (red, blue …).
    public static let opacityFactor = 0.55

    public static func line(_ points: [PagePoint]) -> (start: PagePoint, end: PagePoint)? {
        guard !points.isEmpty, points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return nil }
        let xs = points.map(\.x), ys = points.map(\.y)
        guard max(xs.max()! - xs.min()!, ys.max()! - ys.min()!) >= minimumLength else { return nil }
        return LineSnapping.fit(points)
    }
}

/// Opacity of new highlighter strokes per tip. PencilKit's chisel marker ink
/// renders translucently by itself (multiplied over what lies below); the
/// round tip uses monoline ink, which composites normally, so its colour
/// carries the whole highlighter transparency. Text and ink below stay
/// readable; overlapping separate strokes darken (alpha over alpha).
public enum MarkerInk {
    public static let chiselOpacity = MarkerStraightening.opacityFactor
    public static let roundOpacity = 0.42
    public static func opacity(for tip: MarkerTip) -> Double { tip == .round ? roundOpacity : chiselOpacity }
}

/// Point model of a straightened native stroke. Attributes (size, force,
/// opacity, tilt) are sampled from the drawn points by arc length, so a long
/// hold at the end only shapes the line's end, not half of it.
public enum StraightStroke {
    public static func sampleCount(length: Double) -> Int {
        guard length.isFinite else { return 8 }
        return min(64, max(8, Int(length / 16) + 2))
    }
    /// Index of the drawn point at each of `count` evenly spaced arc-length fractions.
    public static func sampleIndices(along points: [PagePoint], count: Int) -> [Int] {
        guard count > 0 else { return [] }
        return sampleIndices(along: points, fractions: count == 1 ? [0] : (0..<count).map { Double($0) / Double(count - 1) })
    }
    /// Cumulative arc length of a path, normalised to 0…1 (all 0 for a dot).
    public static func arcFractions(_ points: [PagePoint]) -> [Double] {
        guard !points.isEmpty else { return [] }
        var distances = [0.0]
        for index in points.indices.dropFirst() {
            let step = hypot(points[index].x - points[index - 1].x, points[index].y - points[index - 1].y)
            distances.append(distances[index - 1] + (step.isFinite ? step : 0))
        }
        let total = distances.last!
        return total > 0 ? distances.map { $0 / total } : distances
    }
    /// Index of the drawn point at each arc-length fraction (fractions ascending).
    public static func sampleIndices(along points: [PagePoint], fractions: [Double]) -> [Int] {
        guard !points.isEmpty else { return [] }
        guard points.count > 1 else { return fractions.map { _ in 0 } }
        let distances = arcFractions(points)
        guard distances.last! > 0 else { return fractions.map { Int(($0 * Double(points.count - 1)).rounded()) } }
        var result: [Int] = [], cursor = 0
        for fraction in fractions {
            while cursor < points.count - 1, distances[cursor] < fraction - 1e-9 { cursor += 1 }
            result.append(cursor)
        }
        return result
    }
}
