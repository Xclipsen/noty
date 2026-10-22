import Foundation

/// Precision eraser on a shape (Build-50 feedback: "soll nur einen Teil
/// radieren"). The shape's visible line is sampled densely; the eraser
/// removes the samples it sweeps over, and the remaining runs become native
/// ink in the shape's colour and width. Only solid, unfilled shapes are cut;
/// a fill or dash pattern has no ink equivalent, so such shapes keep being
/// removed whole.
public struct ShapeEraseMask: Equatable, Sendable {
    struct Track: Equatable, Sendable {
        var points: [PagePoint]
        var closed: Bool
        var erased: [Bool]
    }
    public let shape: ShapeObject
    private(set) var tracks: [Track]

    public init(_ shape: ShapeObject, spacing: Double = 1) {
        self.shape = shape
        let step = max(0.25, spacing.isFinite ? spacing : 1)
        tracks = Self.lines(of: shape).map { line in
            let points = Self.resample(line.points, closed: line.closed, spacing: step)
            return Track(points: points, closed: line.closed, erased: Array(repeating: false, count: points.count))
        }
    }

    /// Whether the eraser may cut this shape into ink instead of removing it whole.
    public static func canErasePartially(_ shape: ShapeObject) -> Bool { shape.fill == nil && shape.pattern == .solid }

    /// Any sample erased so far.
    public var isTouched: Bool { tracks.contains { $0.erased.contains(true) } }

    /// Sweeps the eraser capsule `from → to` with `radius` (the eraser's half
    /// width; half the line width is added so the gap is as wide as the eraser).
    /// Returns whether a sample was newly erased.
    @discardableResult
    public mutating func erase(from: PagePoint, to: PagePoint, radius: Double) -> Bool {
        guard [from.x, from.y, to.x, to.y, radius].allSatisfy(\.isFinite) else { return false }
        let reach = max(0, radius) + shape.lineWidth / 2
        let box = PageRect(x: min(from.x, to.x) - reach, y: min(from.y, to.y) - reach,
                           width: abs(to.x - from.x) + 2 * reach, height: abs(to.y - from.y) + 2 * reach)
        var changed = false
        for t in tracks.indices {
            for i in tracks[t].points.indices where !tracks[t].erased[i] {
                let p = tracks[t].points[i]
                guard p.x >= box.x, p.x <= box.x + box.width, p.y >= box.y, p.y <= box.y + box.height,
                      Self.distance(p, from, to) <= reach else { continue }
                tracks[t].erased[i] = true; changed = true
            }
        }
        return changed
    }

    /// Remaining visible pieces, each an open polyline in page coordinates. A
    /// closed outline that was cut once becomes one piece running across its
    /// former start; an untouched closed outline ends on its first point.
    public var runs: [[PagePoint]] {
        var result: [[PagePoint]] = []
        for track in tracks {
            guard !track.points.isEmpty else { continue }
            guard track.erased.contains(true) else {
                result.append(track.closed ? track.points + [track.points[0]] : track.points); continue
            }
            var pieces: [[PagePoint]] = [], current: [PagePoint] = []
            for (point, erased) in zip(track.points, track.erased) {
                if erased { if !current.isEmpty { pieces.append(current); current = [] } } else { current.append(point) }
            }
            if !current.isEmpty { pieces.append(current) }
            // The outline's start is arbitrary: join the pieces meeting there.
            if track.closed, pieces.count > 1, track.erased.first == false, track.erased.last == false {
                let last = pieces.removeLast(); pieces[0] = last + pieces[0]
            }
            result += pieces.filter { $0.count >= 2 }
        }
        return result
    }

    // MARK: Geometry (same lines as the app's ShapeRendering)

    static func lines(of shape: ShapeObject) -> [(points: [PagePoint], closed: Bool)] {
        let frame = shape.frame
        switch shape.kind {
        case .line, .arrow, .rectangle, .polygon: return shape.strokeLines
        case .ellipse:
            let rx = frame.width / 2, ry = frame.height / 2
            let center = PagePoint(x: frame.x + rx, y: frame.y + ry)
            let perimeter = .pi * (3 * (rx + ry) - sqrt(max(0, (3 * rx + ry) * (rx + 3 * ry))))
            let count = min(4_000, max(48, Int(perimeter.rounded(.up))))
            return [((0..<count).map { i in
                let t = Double(i) / Double(count) * 2 * .pi
                return PagePoint(x: center.x + rx * cos(t), y: center.y + ry * sin(t))
            }, true)]
        }
    }

    /// Points every `spacing` along the polyline (closing segment included when closed).
    static func resample(_ points: [PagePoint], closed: Bool, spacing: Double) -> [PagePoint] {
        guard points.count > 1 else { return points }
        let corners = closed ? points + [points[0]] : points
        var result: [PagePoint] = []
        for (a, b) in zip(corners, corners.dropFirst()) {
            let count = max(1, Int((hypot(b.x - a.x, b.y - a.y) / spacing).rounded(.up)))
            for i in 0..<count {
                let t = Double(i) / Double(count)
                result.append(PagePoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
            }
        }
        if !closed, let last = points.last { result.append(last) }
        return result
    }

    static func distance(_ p: PagePoint, _ a: PagePoint, _ b: PagePoint) -> Double {
        let dx = b.x - a.x, dy = b.y - a.y, length = dx * dx + dy * dy
        let t = length > 0 ? min(1, max(0, ((p.x - a.x) * dx + (p.y - a.y) * dy) / length)) : 0
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }
}
