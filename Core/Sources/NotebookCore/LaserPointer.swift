import Foundation

/// Laser pointer: "Punkt" shows only a glowing dot with a short comet tail,
/// "Spur" leaves a glowing trail that fades. Display only: never part of a
/// notebook, undo history, preview, backup or PDF export.
public enum LaserMode: String, Codable, CaseIterable, Sendable { case dot, trail }

/// How long the trail stays visible ("Spur").
public enum LaserFade: String, Codable, CaseIterable, Sendable {
    case short, medium, long, untilLift
    /// Seconds a trail point stays after it was drawn; nil keeps the whole
    /// stroke until the Pencil lifts, then it fades together.
    public var lifetime: Double? {
        switch self {
        case .short: 0.7
        case .medium: 1.5
        case .long: 3
        case .untilLift: nil
        }
    }
}

public struct LaserPointerStyle: Equatable, Sendable {
    public var color: InkColor
    public var mode: LaserMode
    public var fade: LaserFade
    public init(color: InkColor, mode: LaserMode, fade: LaserFade) { self.color = color; self.mode = mode; self.fade = fade }
}

public struct LaserSegment: Equatable, Sendable {
    public var start: PagePoint
    public var end: PagePoint
}

/// Trail samples (viewport surface coordinates) with their timing. Pure
/// geometry/timing so fading and stroke separation are testable without UIKit.
public struct LaserTrail: Equatable, Sendable {
    public struct Sample: Equatable, Sendable {
        public var point: PagePoint
        public var time: Double
        public var stroke: Int
    }
    /// Comet tail behind the dot in "Punkt" mode.
    public static let dotTail = 0.18
    /// Fade after lifting: the dot, and the whole stroke in "bis zum Absetzen".
    public static let liftFade = 0.35
    public static let maximumSamples = 4_000

    public var mode: LaserMode
    public var fade: LaserFade
    public private(set) var samples: [Sample] = []
    /// Current pointer while touching, afterwards the last one while it fades.
    public private(set) var pointer: PagePoint?
    public private(set) var touching = false
    private var stroke = 0
    private var pointerLift: Double?
    private var lifts: [Int: Double] = [:]

    public init(mode: LaserMode = .trail, fade: LaserFade = .medium) { self.mode = mode; self.fade = fade }

    /// Starts a stroke; true if nothing was visible before (a new pointing session).
    @discardableResult
    public mutating func begin(at point: PagePoint, time: Double) -> Bool {
        let fresh = isEmpty(at: time)
        if touching { end(time: time) }
        stroke += 1; touching = true; pointer = point; pointerLift = nil
        append(point, time: time)
        return fresh
    }
    public mutating func move(to point: PagePoint, time: Double) {
        guard touching else { return }
        pointer = point
        if let last = samples.last, last.stroke == stroke, hypot(last.point.x - point.x, last.point.y - point.y) < 0.2 { return }
        append(point, time: max(time, samples.last?.time ?? time))
    }
    public mutating func end(time: Double) {
        guard touching else { return }
        touching = false; pointerLift = time; lifts[stroke] = time
    }
    public mutating func clear() { samples = []; pointer = nil; touching = false; pointerLift = nil; lifts = [:] }

    private mutating func append(_ point: PagePoint, time: Double) {
        samples.append(Sample(point: point, time: time, stroke: stroke))
        if samples.count > Self.maximumSamples { samples.removeFirst(samples.count - Self.maximumSamples) }
    }

    /// Visibility 0…1 of a trail sample.
    public func opacity(_ sample: Sample, at now: Double) -> Double {
        var value = 1.0
        if let lifetime = mode == .dot ? Self.dotTail : fade.lifetime { value = 1 - (now - sample.time) / lifetime }
        if mode == .trail, fade == .untilLift, let lift = lifts[sample.stroke] { value = min(value, 1 - (now - lift) / Self.liftFade) }
        return min(1, max(0, value))
    }
    public func pointerOpacity(at now: Double) -> Double {
        guard pointer != nil else { return 0 }
        guard let pointerLift else { return 1 }
        return min(1, max(0, 1 - (now - pointerLift) / Self.liftFade))
    }
    public func isEmpty(at now: Double) -> Bool {
        !touching && pointerOpacity(at: now) <= 0 && samples.allSatisfy { opacity($0, at: now) <= 0 }
    }
    /// Drops everything no longer visible; the oldest end of a trail shrinks away.
    public mutating func prune(at now: Double) {
        let trail = self
        samples.removeAll { trail.opacity($0, at: now) <= 0 }
        let strokes = Set(samples.map(\.stroke))
        lifts = lifts.filter { strokes.contains($0.key) }
        if !touching, pointerOpacity(at: now) <= 0 { pointer = nil; pointerLift = nil }
    }

    /// Segments grouped into `levels` opacity bands (index 0 = most opaque).
    /// Strokes never connect; a lone sample is a zero-length segment (a dot).
    public func segments(at now: Double, levels: Int) -> [[LaserSegment]] {
        let count = max(1, levels)
        var result = Array(repeating: [LaserSegment](), count: count)
        for index in samples.indices {
            let sample = samples[index]
            let previous = index > 0 && samples[index - 1].stroke == sample.stroke ? samples[index - 1] : nil
            let alone = previous == nil && (index + 1 == samples.count || samples[index + 1].stroke != sample.stroke)
            guard previous != nil || alone else { continue }
            let older = previous ?? sample
            let alpha = opacity(older, at: now)
            guard alpha > 0 else { continue }
            let level = min(count - 1, Int((1 - alpha) * Double(count)))
            result[level].append(LaserSegment(start: older.point, end: sample.point))
        }
        return result
    }
    public static func levelOpacity(_ level: Int, levels: Int) -> Double { 1 - Double(level) / Double(max(1, levels)) }
}
