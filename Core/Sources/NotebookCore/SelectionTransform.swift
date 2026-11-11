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
            // Page coordinates round (339.1 + 255.9 against 595): an edge that lies
            // on the anchor up to rounding error does not limit the scale.
            guard distance < -Self.tolerance else { continue }
            // `frame` lies inside `allowed`, so every edge has room for scale 1:
            // anything below, or just above, is rounding again and must not
            // reach font sizes and stroke widths as 0.9999999999999999.
            let limit = room / -distance
            upper = min(upper, limit < 1 + Self.tolerance ? 1 : limit)
        }
        let s = min(max(minimumScale, requested), max(minimumScale, upper))
        // The same for the move: a limit missed by rounding error only keeps the requested value.
        func held(_ wanted: Double, _ low: Double, _ high: Double) -> Double {
            let value = max(low, min(wanted, high))
            return abs(value - wanted) <= Self.tolerance ? wanted : value
        }
        self = Self(scale: s, anchor: anchor, translation: .init(
            x: held(translation.x, allowed.x - (anchor.x + (frame.x - anchor.x) * s),
                    allowed.x + allowed.width - (anchor.x + (frame.x + frame.width - anchor.x) * s)),
            y: held(translation.y, allowed.y - (anchor.y + (frame.y - anchor.y) * s),
                    allowed.y + allowed.height - (anchor.y + (frame.y + frame.height - anchor.y) * s))))
    }
    /// Page units and scale ratio: far above the rounding error of page
    /// coordinates (about 1e-13), far below the 0.01 the objects' own page
    /// checks allow (`TextBox.fits`, `ImageObject.fits`).
    private static let tolerance = 1e-6
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
