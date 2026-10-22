import Foundation

public enum LassoMode: String, CaseIterable, Sendable { case freeform, rectangle }

/// Selection geometry in canonical page points, independent of zoom and UIKit.
public struct LassoRegion: Sendable {
    public let points: [PagePoint]
    public init(points: [PagePoint]) { self.points = points }
    /// Includes boundary contact, crossing segments, and a lasso wholly inside
    /// an object. Bounding-box overlap alone is deliberately insufficient.
    public func intersects(_ rect: PageRect) -> Bool {
        intersectsPolyline([.init(x: rect.x, y: rect.y), .init(x: rect.x + rect.width, y: rect.y),
            .init(x: rect.x + rect.width, y: rect.y + rect.height), .init(x: rect.x, y: rect.y + rect.height)], closed: true)
    }
    public func intersectsPolyline(_ path: [PagePoint], radius: Double = 0, closed: Bool = false) -> Bool {
        guard points.count >= 3, !path.isEmpty else { return false }
        if path.contains(where: contains) { return true }
        if closed, points.contains(where: LassoRegion(points: path).contains) { return true }
        let radius = max(0, radius)
        func distance(_ p: PagePoint, _ a: PagePoint, _ b: PagePoint) -> Double {
            let dx = b.x - a.x, dy = b.y - a.y
            let t = min(1, max(0, ((p.x - a.x) * dx + (p.y - a.y) * dy) / max(0.00000001, dx * dx + dy * dy)))
            return hypot(p.x - a.x - t * dx, p.y - a.y - t * dy)
        }
        func side(_ a: PagePoint, _ b: PagePoint, _ p: PagePoint) -> Double {
            (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x)
        }
        for edge in points.indices {
            let a = points[edge], b = points[(edge + 1) % points.count]
            for p in path where distance(p, a, b) <= radius + 0.0001 { return true }
            let count = closed ? path.count : path.count - 1
            for index in 0..<count {
                let c = path[index], d = path[(index + 1) % path.count]
                if side(a, b, c) * side(a, b, d) < 0, side(c, d, a) * side(c, d, b) < 0 { return true }
                if distance(a, c, d) <= radius + 0.0001 || distance(b, c, d) <= radius + 0.0001 { return true }
            }
        }
        return false
    }
    public func contains(_ point: PagePoint) -> Bool {
        guard points.count >= 3, point.x.isFinite, point.y.isFinite else { return false }
        var inside = false
        for index in points.indices {
            let a = points[index], b = points[(index + 1) % points.count]
            let cross = (b.x - a.x) * (point.y - a.y) - (b.y - a.y) * (point.x - a.x)
            if abs(cross) < 0.0001, point.x >= min(a.x, b.x) - 0.0001, point.x <= max(a.x, b.x) + 0.0001,
               point.y >= min(a.y, b.y) - 0.0001, point.y <= max(a.y, b.y) + 0.0001 { return true }
            if (a.y > point.y) != (b.y > point.y), point.x < (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x { inside.toggle() }
        }
        return inside
    }
    public func containsPolyline(_ path: [PagePoint], closed: Bool = false) -> Bool {
        guard !path.isEmpty, path.allSatisfy(contains) else { return false }
        func side(_ a: PagePoint, _ b: PagePoint, _ p: PagePoint) -> Double {
            (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x)
        }
        let count = closed ? path.count : path.count - 1
        for index in 0..<count {
            let a = path[index], b = path[(index + 1) % path.count]
            for edge in points.indices {
                let c = points[edge], d = points[(edge + 1) % points.count]
                if side(a, b, c) * side(a, b, d) < -0.0000001,
                   side(c, d, a) * side(c, d, b) < -0.0000001 { return false }
            }
        }
        return true
    }
    public func contains(_ rect: PageRect) -> Bool {
        containsPolyline([.init(x: rect.x, y: rect.y), .init(x: rect.x + rect.width, y: rect.y),
            .init(x: rect.x + rect.width, y: rect.y + rect.height), .init(x: rect.x, y: rect.y + rect.height)], closed: true)
    }
}

public enum SelectionOutline {
    /// Visible gap between selected content and its contour, in screen points.
    /// Like the native PencilKit lasso of the early builds: every stroke and
    /// object is encircled at a small distance instead of a box or one hull.
    public static let screenGap = 7.0

    /// Zoom in steps of ~20 %, so pinching does not rebuild the contour per frame.
    public static func zoomBucket(_ displayScale: Double) -> Double {
        guard displayScale.isFinite, displayScale > 0 else { return 1 }
        return pow(1.2, (log(displayScale) / log(1.2)).rounded())
    }

    /// The gap in page points for the current zoom (constant on screen).
    public static func gap(displayScale: Double) -> Double { screenGap / zoomBucket(displayScale) }

    /// Spacing of centre-line samples: fine enough that the rounded offset
    /// contour stays smooth, coarse enough for large selections.
    public static func sampleSpacing(gap: Double) -> Double { max(1, gap * 0.6) }

    /// A tight outer contour for handwriting; no rectangular empty selection box.
    public static func hull(_ points: [PagePoint]) -> [PagePoint] {
        let sorted = points.filter { $0.x.isFinite && $0.y.isFinite }.sorted { $0.x == $1.x ? $0.y < $1.y : $0.x < $1.x }
        var unique: [PagePoint] = []
        for p in sorted where unique.last != p { unique.append(p) }
        guard unique.count > 2 else { return unique }
        func cross(_ a: PagePoint, _ b: PagePoint, _ c: PagePoint) -> Double {
            (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
        }
        var lower: [PagePoint] = [], upper: [PagePoint] = []
        for p in unique {
            while lower.count > 1 && cross(lower[lower.count - 2], lower[lower.count - 1], p) <= 0 { lower.removeLast() }
            lower.append(p)
        }
        for p in unique.reversed() {
            while upper.count > 1 && cross(upper[upper.count - 2], upper[upper.count - 1], p) <= 0 { upper.removeLast() }
            upper.append(p)
        }
        return Array(lower.dropLast()) + Array(upper.dropLast())
    }
}

/// Throttled haptic ticks along a drag (drawing a lasso, moving a selection):
/// one tick per `spacing` points travelled (screen points, so zoom does not
/// change the rhythm), never two within `minimumInterval` seconds. Fast
/// movement does not build up a backlog of ticks.
public struct MotionTicks: Equatable, Sendable {
    public var spacing: Double
    public var minimumInterval: Double
    private var last: PagePoint?
    private var travelled = 0.0
    private var lastTick: Double?
    public init(spacing: Double = 44, minimumInterval: Double = 0.08) {
        self.spacing = max(1, spacing); self.minimumInterval = max(0, minimumInterval)
    }
    /// Starts a new drag at `point` (no tick).
    public mutating func begin(at point: PagePoint, time: Double) {
        last = point.x.isFinite && point.y.isFinite ? point : nil
        travelled = 0; lastTick = time
    }
    /// True when this movement should tick.
    public mutating func move(to point: PagePoint, at time: Double) -> Bool {
        guard point.x.isFinite, point.y.isFinite, time.isFinite else { return false }
        defer { last = point }
        guard let last else { return false }
        // At most one tick is ever owed, however far a throttled flick went.
        travelled = min(spacing, travelled + hypot(point.x - last.x, point.y - last.y))
        guard travelled >= spacing, lastTick.map({ time - $0 >= minimumInterval }) ?? true else { return false }
        travelled = 0; lastTick = time
        return true
    }
}
