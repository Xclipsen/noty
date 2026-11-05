import Foundation

/// The edge a ruler stroke keeps to, in the stroke's own coordinates (page
/// points; directions are the same in sheet and page coordinates). Fixed for
/// the whole stroke: the ruler does not move while it is drawn.
public struct RulerGuide: Equatable, Sendable {
    /// A point on the ruler's edge.
    public var edge: PagePoint
    /// Unit vector away from the ruler.
    public var outward: PagePoint
    /// Half the visible ink width: the ink lies beside the edge, not under it.
    public var inkOffset: Double
    /// Capture zone beyond the edge (about 10 screen points).
    public var capture: Double
    public init(edge: PagePoint, outward: PagePoint, inkOffset: Double, capture: Double) {
        let length = hypot(outward.x, outward.y)
        self.edge = edge
        self.outward = length > 0 ? PagePoint(x: outward.x / length, y: outward.y / length) : PagePoint(x: 0, y: 1)
        self.inkOffset = max(0, inkOffset.isFinite ? inkOffset : 0)
        self.capture = max(0, capture.isFinite ? capture : 0)
    }
    /// Of the pen from the edge; positive outside the ruler.
    public func distance(_ point: PagePoint) -> Double { (point.x - edge.x) * outward.x + (point.y - edge.y) * outward.y }
    public func captures(_ point: PagePoint) -> Bool { distance(point) <= capture }
    /// Straight onto the ink line (the edge, half an ink width further out).
    public func onLine(_ point: PagePoint) -> PagePoint {
        let shift = distance(point) - inkOffset
        return PagePoint(x: point.x - outward.x * shift, y: point.y - outward.y * shift)
    }
    /// Unchanged on its side, otherwise slid onto the ink line: the ink never reaches under the ruler.
    public func kept(_ point: PagePoint) -> PagePoint { distance(point) < inkOffset ? onLine(point) : point }
    /// The pen touches the edge (with a little play for an unsteady hand).
    func touches(_ point: PagePoint) -> Bool { distance(point) <= inkOffset + capture / 4 }
}

/// A stroke drawn at noty's ruler (`WorksheetView+Ruler.swift`).
/// - Its way is straight along the edge, from the projection of its start (or
///   of the point where it first touched the edge) to the projection of its
///   end, when most of it ran in the capture zone: an unsteady hand
///   (±2 pt), a start a few points beside the edge, no hook, no wobble.
/// - Otherwise it stays free and only slides along the edge where it would
///   cross it. A stroke that starts in the zone but leaves it (a perpendicular
///   from the edge) is free, too: projected it would collapse to a dot.
/// - `handedOver`: PencilKit drew the stroke until it reached the zone
///   (`priorLength` of it); that part stays as drawn, the approach up to the
///   edge, too.
public struct RulerStroke: Sendable {
    public struct Point: Equatable, Sendable {
        public var location: PagePoint
        /// Index of the sample whose time and tilt this point carries.
        public var sample: Int
        public init(location: PagePoint, sample: Int) { self.location = location; self.sample = sample }
    }
    public let guide: RulerGuide
    public let handedOver: Bool
    public private(set) var samples: [PagePoint] = []
    private var length: Double
    private var capturedLength = 0.0
    private var contact: Int?
    /// Spacing of the points on a straight way.
    public static let spacing = 6.0

    public init(guide: RulerGuide, handedOver: Bool = false, priorLength: Double = 0) {
        self.guide = guide; self.handedOver = handedOver
        length = max(0, priorLength.isFinite ? priorLength : 0)
    }
    public mutating func add(_ point: PagePoint) {
        guard point.x.isFinite, point.y.isFinite else { return }
        if let last = samples.last {
            let step = hypot(point.x - last.x, point.y - last.y)
            length += step
            let middle = PagePoint(x: (point.x + last.x) / 2, y: (point.y + last.y) / 2)
            if contact != nil, guide.captures(middle) { capturedLength += step }
        }
        samples.append(point)
        if contact == nil, guide.touches(point) || (!handedOver && samples.count == 1 && guide.captures(point)) {
            contact = samples.count - 1
        }
    }
    public var isStraight: Bool {
        guard let contact, !samples.isEmpty else { return false }
        if length <= 1e-9 { return guide.captures(samples[contact]) }
        return capturedLength >= length / 2
    }
    /// The way to draw: straight along the edge or free, never across it.
    public var path: [Point] {
        guard isStraight, let contact, let last = samples.indices.last else {
            return samples.enumerated().map { Point(location: guide.kept($1), sample: $0) }
        }
        var result = (0..<contact).map { Point(location: guide.kept(samples[$0]), sample: $0) }
        let a = guide.onLine(samples[contact]), b = guide.onLine(samples[last])
        let distance = hypot(b.x - a.x, b.y - a.y)
        guard distance > 1e-9 else { return result + [Point(location: a, sample: contact)] }
        let steps = max(1, Int((distance / Self.spacing).rounded(.up)))
        for step in 0...steps {
            let t = Double(step) / Double(steps)
            result.append(Point(location: PagePoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t),
                                sample: contact + Int((t * Double(last - contact)).rounded())))
        }
        return result
    }

    /// The parts of `path` inside `rect` (the page): cut where the way leaves
    /// it, like `HeldShapeFitting` cuts a line, so a slanted stroke keeps its
    /// direction instead of bending along the edge. Several parts when it
    /// comes back; nothing when it lies outside. A single point stays a dot.
    public static func pieces(_ path: [Point], inside rect: PageRect) -> [[Point]] {
        guard rect.width > 0, rect.height > 0 else { return [] }
        func inside(_ p: PagePoint) -> Bool { p.x >= rect.x && p.x <= rect.x + rect.width && p.y >= rect.y && p.y <= rect.y + rect.height }
        func same(_ a: PagePoint, _ b: PagePoint) -> Bool { abs(a.x - b.x) < 1e-9 && abs(a.y - b.y) < 1e-9 }
        if path.count == 1 { return inside(path[0].location) ? [path] : [] }
        var pieces: [[Point]] = [], current: [Point] = []
        func close() { if current.count > 1 { pieces.append(current) }; current = [] }
        for (a, b) in zip(path, path.dropFirst()) {
            guard let (c, d) = HeldShapeFitting.clip(a.location, b.location, to: rect) else { close(); continue }
            if !same(c, a.location) { close() }
            if current.isEmpty { current.append(Point(location: c, sample: same(c, a.location) ? a.sample : b.sample)) }
            if !same(d, current.last!.location) { current.append(Point(location: d, sample: b.sample)) }
            if !same(d, b.location) { close() }
        }
        close()
        return pieces
    }
}
