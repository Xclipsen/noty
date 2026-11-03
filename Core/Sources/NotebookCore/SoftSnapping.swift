import Foundation

// MARK: Weiches Einrasten (Textneubau Stufe 2)
//
// Moving text fields, images, shapes and lasso selections clicks softly onto
// edges and centres of other objects, the first baseline of other text fields,
// equal gaps between three or more objects and the page edges and centre.
// Paper lines and grid squares are deliberately no targets (Feedback zu
// Build 62: nothing may click onto lined or squared paper). Only a slow movement within a few screen points engages;
// fast dragging never snaps, a small movement past the threshold releases.
// Pure geometry here; the UI only reports touches and draws the guides.

/// `.x`: a vertical guide (positions along x); `.y`: a horizontal guide.
public enum SnapAxis: Hashable, Sendable { case x, y }

/// What a guide aligns to. Lower raw values win an exact tie.
public enum SnapKind: Int, Comparable, Sendable {
    case edge, center, baseline, spacing, page
    public static func < (lhs: SnapKind, rhs: SnapKind) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Another object on the page (axis-aligned bounds; rotated objects count by
/// their rotated bounds). `baseline`: page y of the first text line of an
/// unrotated text field.
public struct SnapObject: Equatable, Sendable {
    public var frame: PageRect
    public var baseline: Double?
    public init(frame: PageRect, baseline: Double? = nil) { self.frame = frame; self.baseline = baseline }
}

/// Everything a drag may snap to, collected once when the drag begins.
public struct SnapScene: Equatable, Sendable {
    /// Other objects (never the moved ones).
    public var objects: [SnapObject]
    /// The page (edges and centre); `limits`: the whole writing space when it is larger.
    public var page: PageRect?
    public var limits: PageRect?
    public init(objects: [SnapObject] = [], page: PageRect? = nil, limits: PageRect? = nil) {
        self.objects = objects; self.page = page; self.limits = limits
    }
}

/// What moves: a frame (with the first baseline of a single text field) or
/// a single point (width point of a field, anchor of a shape).
public struct SnapMoving: Equatable, Sendable {
    public var frame: PageRect
    /// First baseline below `frame.y` (unrotated text field only).
    public var baselineOffset: Double?
    public var isPoint: Bool
    public var axes: Set<SnapAxis>
    public init(frame: PageRect, baselineOffset: Double? = nil, axes: Set<SnapAxis> = [.x, .y]) {
        self.frame = frame; self.baselineOffset = baselineOffset; self.isPoint = false; self.axes = axes
    }
    public static func point(_ point: PagePoint, axes: Set<SnapAxis> = [.x, .y]) -> SnapMoving {
        var moving = SnapMoving(frame: PageRect(x: point.x, y: point.y, width: 0, height: 0), axes: axes)
        moving.isPoint = true
        return moving
    }
}

/// Thresholds in screen points (independent of the zoom).
public struct SnapParameters: Equatable, Sendable {
    /// Engages within this distance …
    public var reach: Double
    /// … and holds until the unsnapped position is farther than this.
    public var release: Double
    /// Engages only while the touch moves slower (screen points per second).
    public var slowSpeed: Double
    public init(reach: Double = 5, release: Double = 8, slowSpeed: Double = 250) {
        self.reach = reach; self.release = release; self.slowSpeed = slowSpeed
    }
    public static let standard = SnapParameters()
}

/// A guide line: `.x` vertical at x = `value`, `.y` horizontal at y = `value`;
/// `span` along the line.
public struct SnapGuide: Equatable, Sendable {
    public var axis: SnapAxis
    public var value: Double
    public var span: ClosedRange<Double>
    public var kind: SnapKind
    public init(axis: SnapAxis, value: Double, span: ClosedRange<Double>, kind: SnapKind) {
        self.axis = axis; self.value = value; self.span = span; self.kind = kind
    }
}

/// An equal gap: along `axis` from `from` to `to`, drawn at `cross`.
public struct SpacingMark: Equatable, Sendable {
    public var axis: SnapAxis
    public var from: Double
    public var to: Double
    public var cross: Double
    public init(axis: SnapAxis, from: Double, to: Double, cross: Double) {
        self.axis = axis; self.from = from; self.to = to; self.cross = cross
    }
}

/// Guides for the current position (empty: nothing engaged).
public struct SnapFeedback: Equatable, Sendable {
    public var guides: [SnapGuide] = []
    public var marks: [SpacingMark] = []
    public init(guides: [SnapGuide] = [], marks: [SpacingMark] = []) { self.guides = guides; self.marks = marks }
    public var isEmpty: Bool { guides.isEmpty && marks.isEmpty }
}

/// Speed of a touch in screen points per second, smoothed over ~50 ms. A
/// pause (no events) makes the next small movement slow again.
public struct DragSpeed: Equatable, Sendable {
    public static let smoothing = 0.05
    public private(set) var value: Double = 0
    private var last: PagePoint?
    private var lastTime: Double = 0
    public init() {}
    @discardableResult
    public mutating func add(_ point: PagePoint, at time: Double) -> Double {
        defer { last = point; lastTime = time }
        guard let last, point.x.isFinite, point.y.isFinite else { value = 0; return value }
        let dt = time - lastTime
        guard dt > 0.0005 else { return value }
        let instant = hypot(point.x - last.x, point.y - last.y) / dt
        let alpha = 1 - exp(-dt / Self.smoothing)
        value += alpha * (instant - value)
        return value
    }
}

/// The snapping state of one drag (hysteresis per axis).
public struct SoftSnapper: Equatable, Sendable {
    public var scene: SnapScene
    public var parameters: SnapParameters
    /// A target engaged on one axis: feature `offset` (from the frame's
    /// origin on that axis) sits on `target`.
    struct Engagement: Equatable, Sendable {
        var offset: Double
        var target: Double
        var kind: SnapKind
        var role: Role
        var span: ClosedRange<Double>?
        var spacing: Spacing?
        func same(_ other: Engagement) -> Bool {
            kind == other.kind && abs(offset - other.offset) < 1e-6 && abs(target - other.target) < 1e-6
        }
    }
    struct Spacing: Equatable, Sendable {
        var before: PageRect?
        var after: PageRect?
        var reference: [SpacingMark]
    }
    enum Role: Equatable, Sendable { case edge, center, baseline, point }
    private var engaged: [SnapAxis: Engagement] = [:]
    /// The last `snap` engaged a target that was not engaged before (haptics).
    public private(set) var newlyEngaged = false

    public init(scene: SnapScene, parameters: SnapParameters = .standard) {
        self.scene = scene; self.parameters = parameters
    }

    public var isEngaged: Bool { !engaged.isEmpty }

    /// The translation to use instead of `proposed`.
    /// - Parameters: scale: screen points per page point (zoom); speed: of
    ///   the touch in screen points per second; suppressed: a second finger
    ///   or the setting turns snapping off for now (and releases it).
    public mutating func snap(_ proposed: PagePoint, moving: SnapMoving, scale: Double, speed: Double,
                              suppressed: Bool = false) -> PagePoint {
        newlyEngaged = false
        guard !suppressed, scale.isFinite, scale > 0, proposed.x.isFinite, proposed.y.isFinite else { engaged = [:]; return proposed }
        let reach = parameters.reach / scale, release = parameters.release / scale
        let slow = speed.isFinite && speed <= parameters.slowSpeed
        var result = proposed
        for axis in [SnapAxis.x, .y] {
            guard moving.axes.contains(axis) else { engaged[axis] = nil; continue }
            let shift = axis == .x ? proposed.x : proposed.y
            let origin = Self.low(moving.frame, axis) + shift
            func distance(_ e: Engagement) -> Double { e.target - (origin + e.offset) }
            var best: (Engagement, Double)?
            if slow {
                for candidate in candidates(axis, moving: moving, translation: proposed) {
                    let delta = distance(candidate)
                    guard abs(delta) <= reach else { continue }
                    if let current = best, abs(current.1) < abs(delta) - 1e-9 || (abs(abs(current.1) - abs(delta)) <= 1e-9 && current.0.kind <= candidate.kind) { continue }
                    best = (candidate, delta)
                }
            }
            let current = engaged[axis].map { ($0, distance($0)) }
            if let current, abs(current.1) <= release, best.map({ abs($0.1) >= abs(current.1) - 1e-9 }) ?? true {
                result = Self.adding(current.1, to: result, axis)
            } else if let best {
                if !(current.map { $0.0.same(best.0) } ?? false) { newlyEngaged = true }
                engaged[axis] = best.0
                result = Self.adding(best.1, to: result, axis)
            } else {
                engaged[axis] = nil
            }
        }
        return result
    }

    /// Guides for the translation finally used (after the page limits): an
    /// axis whose snapped position was clamped away shows nothing.
    public func feedback(for translation: PagePoint, moving: SnapMoving) -> SnapFeedback {
        var feedback = SnapFeedback()
        for axis in [SnapAxis.x, .y] {
            guard let engagement = engaged[axis] else { continue }
            let frame = Self.moved(moving.frame, by: translation)
            guard abs(Self.low(frame, axis) + engagement.offset - engagement.target) < 0.01 else { continue }
            let cross = Self.other(axis)
            if let spacing = engagement.spacing {
                var marks = spacing.reference
                if let before = spacing.before {
                    marks.append(SpacingMark(axis: axis, from: Self.high(before, axis), to: Self.low(frame, axis), cross: Self.crossMiddle(before, frame, axis)))
                }
                if let after = spacing.after {
                    marks.append(SpacingMark(axis: axis, from: Self.high(frame, axis), to: Self.low(after, axis), cross: Self.crossMiddle(frame, after, axis)))
                }
                feedback.marks += marks
                continue
            }
            var span = Self.low(frame, cross)...Self.high(frame, cross)
            if let own = engagement.span { span = Self.union(span, own) }
            // Every other object aligned the same way joins the guide.
            if engagement.kind == .edge || engagement.kind == .center || engagement.kind == .baseline {
                for object in scene.objects where Self.values(of: object, axis, kind: engagement.kind).contains(where: { abs($0 - engagement.target) < 0.01 }) {
                    span = Self.union(span, Self.low(object.frame, cross)...Self.high(object.frame, cross))
                }
            }
            feedback.guides.append(SnapGuide(axis: axis, value: engagement.target, span: span, kind: engagement.kind))
        }
        return feedback
    }

    // MARK: Candidates

    private func features(_ moving: SnapMoving, _ axis: SnapAxis) -> [(offset: Double, role: Role)] {
        if moving.isPoint { return [(0, .point)] }
        let size = axis == .x ? moving.frame.width : moving.frame.height
        var result: [(Double, Role)] = [(0, .edge), (size / 2, .center), (size, .edge)]
        if axis == .y, let baseline = moving.baselineOffset, baseline.isFinite { result.append((baseline, .baseline)) }
        return result
    }

    func candidates(_ axis: SnapAxis, moving: SnapMoving, translation: PagePoint) -> [Engagement] {
        let cross = Self.other(axis)
        var targets: [(value: Double, kind: SnapKind, span: ClosedRange<Double>?)] = []
        for object in scene.objects {
            let span = Self.low(object.frame, cross)...Self.high(object.frame, cross)
            for kind in [SnapKind.edge, .center, .baseline] {
                for value in Self.values(of: object, axis, kind: kind) { targets.append((value, kind, span)) }
            }
        }
        if let page = scene.page {
            let span = Self.low(page, cross)...Self.high(page, cross)
            targets += [(Self.low(page, axis), .page, span), (Self.high(page, axis), .page, span)]
            targets.append((Self.middle(page, axis), .center, span)) // page centre counts as a centre
        }
        if let limits = scene.limits {
            let span = Self.low(limits, cross)...Self.high(limits, cross)
            for value in [Self.low(limits, axis), Self.high(limits, axis)]
            where scene.page.map({ abs(Self.low($0, axis) - value) > 0.5 && abs(Self.high($0, axis) - value) > 0.5 }) ?? true {
                targets.append((value, .page, span))
            }
        }

        var result: [Engagement] = []
        for feature in features(moving, axis) {
            for target in targets {
                let accepts: Bool
                switch (feature.role, target.kind) {
                case (.point, _): accepts = true
                case (.edge, .edge), (.edge, .page): accepts = true
                case (.center, .center): accepts = true
                case (.baseline, .baseline): accepts = true
                default: accepts = false
                }
                guard accepts else { continue }
                result.append(Engagement(offset: feature.offset, target: target.value, kind: target.kind, role: feature.role, span: target.span))
            }
        }
        if !moving.isPoint { result += spacingCandidates(axis, frame: Self.moved(moving.frame, by: translation)) }
        return result
    }

    /// Equal gaps (three or more objects in a row): centred between the
    /// nearest neighbours, or one more gap of a size already used in the row.
    /// `frame`: the moved frame where the touch wants it (row membership by its cross extent).
    private func spacingCandidates(_ axis: SnapAxis, frame: PageRect) -> [Engagement] {
        let cross = Self.other(axis)
        let row = scene.objects.map(\.frame).filter {
            Self.low($0, cross) < Self.high(frame, cross) && Self.high($0, cross) > Self.low(frame, cross)
        }
        guard row.count >= 2 else { return [] }
        let size = Self.high(frame, axis) - Self.low(frame, axis), middle = Self.middle(frame, axis)
        let before = row.filter { Self.high($0, axis) <= middle }.max { Self.high($0, axis) < Self.high($1, axis) }
        let after = row.filter { Self.low($0, axis) >= middle }.min { Self.low($0, axis) < Self.low($1, axis) }
        let sorted = row.sorted { Self.low($0, axis) < Self.low($1, axis) }
        var gaps: [(PageRect, PageRect, Double)] = []
        for (p, q) in zip(sorted, sorted.dropFirst()) {
            let gap = Self.low(q, axis) - Self.high(p, axis)
            if gap > 0.5 { gaps.append((p, q, gap)) }
        }
        func mark(_ p: PageRect, _ q: PageRect) -> SpacingMark {
            SpacingMark(axis: axis, from: Self.high(p, axis), to: Self.low(q, axis), cross: Self.crossMiddle(p, q, axis))
        }
        var result: [Engagement] = []
        if let before, let after {
            let room = Self.low(after, axis) - Self.high(before, axis) - size
            if room >= 0 {
                result.append(Engagement(offset: 0, target: Self.high(before, axis) + room / 2, kind: .spacing, role: .edge, span: nil,
                                         spacing: Spacing(before: before, after: after, reference: [])))
            }
        }
        for (p, q, gap) in gaps {
            if let before, before != p {
                let target = Self.high(before, axis) + gap
                if after.map({ target + size <= Self.low($0, axis) + 0.01 }) ?? true {
                    result.append(Engagement(offset: 0, target: target, kind: .spacing, role: .edge, span: nil,
                                             spacing: Spacing(before: before, after: nil, reference: [mark(p, q)])))
                }
            }
            if let after, after != q {
                let target = Self.low(after, axis) - gap - size
                if before.map({ target >= Self.high($0, axis) - 0.01 }) ?? true {
                    result.append(Engagement(offset: 0, target: target, kind: .spacing, role: .edge, span: nil,
                                             spacing: Spacing(before: nil, after: after, reference: [mark(p, q)])))
                }
            }
        }
        return result
    }

    // MARK: Geometry helpers

    private static func values(of object: SnapObject, _ axis: SnapAxis, kind: SnapKind) -> [Double] {
        switch kind {
        case .edge: return [low(object.frame, axis), high(object.frame, axis)]
        case .center: return [middle(object.frame, axis)]
        case .baseline: return axis == .y ? object.baseline.map { [$0] } ?? [] : []
        default: return []
        }
    }
    static func other(_ axis: SnapAxis) -> SnapAxis { axis == .x ? .y : .x }
    static func low(_ r: PageRect, _ axis: SnapAxis) -> Double { axis == .x ? r.x : r.y }
    static func high(_ r: PageRect, _ axis: SnapAxis) -> Double { axis == .x ? r.x + r.width : r.y + r.height }
    static func middle(_ r: PageRect, _ axis: SnapAxis) -> Double { (low(r, axis) + high(r, axis)) / 2 }
    static func moved(_ r: PageRect, by t: PagePoint) -> PageRect { PageRect(x: r.x + t.x, y: r.y + t.y, width: r.width, height: r.height) }
    static func adding(_ delta: Double, to point: PagePoint, _ axis: SnapAxis) -> PagePoint {
        axis == .x ? PagePoint(x: point.x + delta, y: point.y) : PagePoint(x: point.x, y: point.y + delta)
    }
    static func union(_ a: ClosedRange<Double>, _ b: ClosedRange<Double>) -> ClosedRange<Double> {
        min(a.lowerBound, b.lowerBound)...max(a.upperBound, b.upperBound)
    }
    /// Middle of the shared cross extent of two neighbours (their mean middle if none).
    static func crossMiddle(_ a: PageRect, _ b: PageRect, _ axis: SnapAxis) -> Double {
        let cross = other(axis)
        let lower = max(low(a, cross), low(b, cross)), upper = min(high(a, cross), high(b, cross))
        return lower <= upper ? (lower + upper) / 2 : (middle(a, cross) + middle(b, cross)) / 2
    }
}

/// One drag's snapping for the move path (`ObjectMovement`) and for single
/// points (width points of a field, anchors of a shape). The UI updates zoom,
/// speed and suppression per touch event before asking.
public final class MoveSnapSession: MoveSnapping {
    public private(set) var snapper: SoftSnapper
    /// Snapped by this frame instead of the one the move path clamps with
    /// (e.g. shapes by their geometry, not their touch padding).
    public var snapFrame: PageRect?
    public var baselineOffset: Double?
    /// Screen points per page point.
    public var scale: Double = 1
    /// Touch speed in screen points per second.
    public var speed: Double = 0
    /// A second finger is down (or anything else that pauses snapping).
    public var suppressed = false

    public init(scene: SnapScene, parameters: SnapParameters = .standard) {
        snapper = SoftSnapper(scene: scene, parameters: parameters)
    }
    public var newlyEngaged: Bool { snapper.newlyEngaged }

    private func moving(_ frame: PageRect) -> SnapMoving {
        SnapMoving(frame: snapFrame ?? frame, baselineOffset: baselineOffset)
    }
    public func adjusted(_ translation: PagePoint, moving frame: PageRect) -> PagePoint {
        snapper.snap(translation, moving: moving(frame), scale: scale, speed: speed, suppressed: suppressed)
    }
    public func feedback(for translation: PagePoint, moving frame: PageRect) -> SnapFeedback {
        snapper.feedback(for: translation, moving: moving(frame))
    }
    /// A single point (only along `axes`).
    public func adjusted(point: PagePoint, axes: Set<SnapAxis> = [.x, .y]) -> PagePoint {
        let moving = SnapMoving.point(point, axes: axes)
        let shift = snapper.snap(PagePoint(x: 0, y: 0), moving: moving, scale: scale, speed: speed, suppressed: suppressed)
        return PagePoint(x: point.x + shift.x, y: point.y + shift.y)
    }
    /// Guides for the point finally used.
    public func feedback(point: PagePoint, axes: Set<SnapAxis> = [.x, .y]) -> SnapFeedback {
        snapper.feedback(for: PagePoint(x: 0, y: 0), moving: .point(point, axes: axes))
    }
}

extension ShapeObject {
    /// What a shape aligns by: its drawn outline (geometry plus half the
    /// stroke), not the larger touch padding of `bounds` (arrows).
    public var snapFrame: PageRect {
        let f = frame, half = lineWidth / 2
        return PageRect(x: f.x - half, y: f.y - half, width: f.width + lineWidth, height: f.height + lineWidth)
    }
}
