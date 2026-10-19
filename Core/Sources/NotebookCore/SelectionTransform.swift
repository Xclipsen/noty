import Foundation

/// A single affine transform for every member of a mixed selection. Clamp at
/// the page and format limits instead of dropping a whole drag with no feedback.
public struct SelectionTransform: Equatable, Sendable {
    public let scale: Double
    public let translation: PagePoint
    public let anchor: PagePoint
    public init(frame: PageRect, anchor: PagePoint, translation: PagePoint, scale: Double,
                limits: PageRect, minimumScale: Double = 0.01, maximumScale: Double = 100) {
        let allowed = limits.union(frame) // existing edge overhang must not freeze ink
        let requested = scale.isFinite ? scale : 1
        var upper = maximumScale
        for (distance, room) in [(frame.x - anchor.x, anchor.x - allowed.x),
                                  (anchor.x - frame.x - frame.width, allowed.x + allowed.width - anchor.x),
                                  (frame.y - anchor.y, anchor.y - allowed.y),
                                  (anchor.y - frame.y - frame.height, allowed.y + allowed.height - anchor.y)] {
            if distance < 0 { upper = min(upper, room / -distance) }
        }
        let s = min(max(minimumScale, requested), max(minimumScale, upper))
        self = Self(scale: s, anchor: anchor, translation: .init(
            x: max(allowed.x - (anchor.x + (frame.x - anchor.x) * s),
                   min(translation.x, allowed.x + allowed.width - (anchor.x + (frame.x + frame.width - anchor.x) * s))),
            y: max(allowed.y - (anchor.y + (frame.y - anchor.y) * s),
                   min(translation.y, allowed.y + allowed.height - (anchor.y + (frame.y + frame.height - anchor.y) * s)))))
    }
    private init(scale: Double, anchor: PagePoint, translation: PagePoint) {
        self.scale = scale; self.anchor = anchor; self.translation = translation
    }
    public func apply(_ point: PagePoint) -> PagePoint {
        .init(x: anchor.x + (point.x - anchor.x) * scale + translation.x,
              y: anchor.y + (point.y - anchor.y) * scale + translation.y)
    }
    public static func projectedScale(start: PagePoint, current: PagePoint, anchor: PagePoint) -> Double {
        let x = start.x - anchor.x, y = start.y - anchor.y
        return max(0.001, ((current.x - anchor.x) * x + (current.y - anchor.y) * y) / max(0.0001, x * x + y * y))
    }
}
