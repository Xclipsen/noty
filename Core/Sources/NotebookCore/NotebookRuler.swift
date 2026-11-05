import Foundation

/// noty's own ruler: a band over the screen, in viewport points, so its size
/// does not follow the zoom (PencilKit's ruler lives in the zoomed canvas and
/// offers no way to place or size it). Display only: what it leaves behind are
/// ordinary PencilKit strokes. Strokes at its edge: `RulerStroke`.
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
    /// Exactly on a multiple of 15° (after `snapped`): the moment to tick.
    public var isSnapped: Bool {
        let steps = angle / 15
        return abs(steps - steps.rounded()) < 1e-9
    }
    /// The angle as a protractor reads it: 0…179°, counter-clockwise (the
    /// screen's y axis points down, `angle` turns clockwise).
    public var displayDegrees: Int {
        let value = Int((-angle).rounded())
        return ((value % 180) + 180) % 180
    }
    /// The middle stays reachable on the screen.
    public func clamped(width: Double, height: Double) -> NotebookRuler {
        clamped(to: PageRect(x: 0, y: 0, width: width, height: height))
    }
    /// The middle stays in `area` (`parkingArea`), 40 pt from its sides.
    public func clamped(to area: PageRect) -> NotebookRuler {
        let inset = min(40, max(0, area.width / 2), max(0, area.height / 2))
        let minX = area.x + inset, maxX = max(minX, area.x + area.width - inset)
        let minY = area.y + inset, maxY = max(minY, area.y + area.height - inset)
        return NotebookRuler(x: min(max(x, minX), maxX), y: min(max(y, minY), maxY), angle: angle)
    }
    /// Where the middle may be parked: not under the toolbar (`top`, side
    /// bars higher than half the screen) or the keyboard (`bottom`, bars
    /// wider than half the screen at the bottom). Small floating palettes do
    /// not count; with too little room left the whole screen does.
    public static func parkingArea(width: Double, height: Double, top: Double, bottom: Double, obstructions: [PageRect]) -> PageRect {
        var left = 0.0, right = width, upper = max(0, top), lower = height - max(0, bottom)
        for bar in obstructions where bar.width > 0 && bar.height > 0 {
            if bar.height > height / 2 {
                if bar.x <= 1 { left = max(left, bar.x + bar.width) }
                else if bar.x + bar.width >= width - 1 { right = min(right, bar.x) }
            } else if bar.width > width / 2 {
                if bar.y <= 1 { upper = max(upper, bar.y + bar.height) }
                else if bar.y + bar.height >= height - 1 { lower = min(lower, bar.y) }
            }
        }
        guard right - left >= 80, lower - upper >= 80 else { return PageRect(x: 0, y: 0, width: width, height: height) }
        return PageRect(x: left, y: upper, width: right - left, height: lower - upper)
    }
    /// Its place as a share of the screen: after a turn of the iPad it stands
    /// where it stood, relative to the new size.
    public func rescaled(from old: PageSize, to new: PageSize) -> NotebookRuler {
        guard old.width > 0, old.height > 0, new.width > 0, new.height > 0 else { return self }
        return NotebookRuler(x: x / old.width * new.width, y: y / old.height * new.height, angle: angle)
    }

    /// Capture zone beyond each edge, viewport (screen) points: a stroke that
    /// starts or arrives there follows the ruler, anything further away is an
    /// ordinary PencilKit stroke with its pressure.
    public static let captureDistance = 10.0
    /// Distance of `point` from the edge of `side`; positive outside the band.
    public func edgeDistance(_ point: PagePoint, side: Double) -> Double { across(point) * (side < 0 ? -1 : 1) - Self.width / 2 }
    /// On the band or in the capture zone of its nearer edge.
    public func captures(_ point: PagePoint) -> Bool { edgeDistance(point, side: side(of: point)) <= Self.captureDistance }
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

/// A hand on the ruler: which touches move or turn it, and when.
public enum RulerHand {
    public struct Touch: Sendable {
        public var onBand: Bool
        /// `UITouch.majorRadius`, points.
        public var majorRadius: Double
        public init(onBand: Bool, majorRadius: Double) { self.onBand = onBand; self.majorRadius = majorRadius }
    }
    /// Larger is a resting palm or the side of the hand, not a finger.
    public static let largeTouchRadius = 24.0
    /// Fingers rest on a ruler while the other hand writes: it moves only after this way (screen points).
    public static let moveThreshold = 8.0
    static func finger(_ touch: Touch) -> Bool { touch.majorRadius.isFinite && touch.majorRadius <= largeTouchRadius }
    /// Of touches landing in one event: the first finger on the band, then
    /// one more finger anywhere (two fingers landing together turn it).
    /// None while a stroke is drawn: the edge stays where it is.
    public static func fingers(_ touches: [Touch], strokeActive: Bool) -> [Int] {
        guard !strokeActive, let first = touches.indices.first(where: { touches[$0].onBand && finger(touches[$0]) }) else { return [] }
        let second = touches.indices.first { $0 != first && finger(touches[$0]) }
        return [first] + (second.map { [$0] } ?? [])
    }
    /// A later second finger turns it, a palm does not.
    public static func joins(_ touch: Touch) -> Bool { finger(touch) }
    /// `moved`: way of each finger since it landed.
    public static func begins(moved: [Double]) -> Bool { moved.contains { $0 >= moveThreshold } }
}
