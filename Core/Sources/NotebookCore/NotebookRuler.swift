import Foundation

/// noty's own ruler: a band over the screen, in viewport points, so its size
/// does not follow the zoom (PencilKit's ruler lives in the zoomed canvas and
/// offers no way to place or size it). Display only: what it leaves behind are
/// ordinary PencilKit strokes.
public struct NotebookRuler: Equatable, Codable, Sendable {
    public static let width = 88.0

    public var x: Double
    public var y: Double
    /// Degrees in -90 < angle ≤ 90: a ruler turned by 180° is the same ruler.
    public var angle: Double
    public init(x: Double, y: Double, angle: Double = 0) { self.x = x; self.y = y; self.angle = Self.normalized(angle) }

    static func normalized(_ degrees: Double) -> Double {
        var value = degrees.truncatingRemainder(dividingBy: 180)
        if value <= -90 { value += 180 }
        if value > 90 { value -= 180 }
        return value
    }
    private var direction: PagePoint { PagePoint(x: cos(angle * .pi / 180), y: sin(angle * .pi / 180)) }
    /// Points to the edge of side +1.
    private var normal: PagePoint { let d = direction; return PagePoint(x: -d.y, y: d.x) }
    private func across(_ point: PagePoint) -> Double {
        let n = normal
        return (point.x - x) * n.x + (point.y - y) * n.y
    }

    /// The band has no end: it runs across the whole screen.
    public func contains(_ point: PagePoint) -> Bool { abs(across(point)) <= Self.width / 2 }

    /// The side (+1 or -1) a stroke starting at `point` stays on: like a real
    /// ruler it cannot be crossed. A start on the band belongs to the nearer edge.
    public func side(of point: PagePoint) -> Double { across(point) >= 0 ? 1 : -1 }
    /// Two points on the edge of `side` and its outward direction.
    public func edgeLine(side: Double) -> (start: PagePoint, end: PagePoint, outward: PagePoint) {
        let n = normal, d = direction, half = Self.width / 2 * side
        let start = PagePoint(x: x + n.x * half, y: y + n.y * half)
        return (start, PagePoint(x: start.x + d.x * 100, y: start.y + d.y * 100), PagePoint(x: n.x * side, y: n.y * side))
    }

    public func translated(x dx: Double, y dy: Double) -> NotebookRuler { NotebookRuler(x: x + dx, y: y + dy, angle: angle) }
    /// The move of two fingers: rotated about their midpoint, then along with it.
    public func transformed(from a: (PagePoint, PagePoint), to b: (PagePoint, PagePoint)) -> NotebookRuler {
        let delta = atan2(b.1.y - b.0.y, b.1.x - b.0.x) - atan2(a.1.y - a.0.y, a.1.x - a.0.x)
        let from = PagePoint(x: (a.0.x + a.1.x) / 2, y: (a.0.y + a.1.y) / 2)
        let to = PagePoint(x: (b.0.x + b.1.x) / 2, y: (b.0.y + b.1.y) / 2)
        let dx = x - from.x, dy = y - from.y
        return NotebookRuler(x: to.x + dx * cos(delta) - dy * sin(delta), y: to.y + dx * sin(delta) + dy * cos(delta),
                             angle: angle + delta * 180 / .pi)
    }
    /// Close to a multiple of 15° it stays exactly there.
    public var snapped: NotebookRuler {
        let target = (angle / 15).rounded() * 15
        guard abs(target - angle) <= 1.2 else { return self }
        return NotebookRuler(x: x, y: y, angle: target)
    }
    /// The middle stays reachable on the screen.
    public func clamped(width: Double, height: Double) -> NotebookRuler {
        let inset = min(40, width / 2, height / 2)
        return NotebookRuler(x: min(max(x, inset), max(inset, width - inset)), y: min(max(y, inset), max(inset, height - inset)), angle: angle)
    }
    /// `point` unchanged on the `outward` side of the line through `start`,
    /// otherwise moved straight onto it: the pen slides along the edge.
    public static func kept(_ point: PagePoint, start: PagePoint, outward: PagePoint) -> PagePoint {
        let length = outward.x * outward.x + outward.y * outward.y
        guard length > 0 else { return point }
        let distance = ((point.x - start.x) * outward.x + (point.y - start.y) * outward.y) / length
        guard distance < 0 else { return point }
        return PagePoint(x: point.x - outward.x * distance, y: point.y - outward.y * distance)
    }
}
