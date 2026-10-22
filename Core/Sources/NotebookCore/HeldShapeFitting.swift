import Foundation

/// Fits a held (recognised) shape onto the page instead of dropping it when
/// the Pencil left the page or canvas during the stroke. `padding` is the
/// stroke's half width (or an arrow's head reach) that must stay on the page.
/// - Lines and arrows are clipped to the page: the part beyond the edge was
///   never visible, the drawn direction stays.
/// - Closed shapes and polylines keep their size and are moved just far
///   enough onto the page (`allowShift`); a shape larger than the page is
///   not fitted.
/// nil: nothing sensible remains, the freehand stroke is kept.
public enum HeldShapeFitting {
    public static func fit(_ shape: RecognizedShape, in bounds: PageRect, padding: Double, allowShift: Bool = true) -> RecognizedShape? {
        let pad = max(0, padding.isFinite ? padding : 0)
        let inner = PageRect(x: bounds.x + pad, y: bounds.y + pad, width: bounds.width - 2 * pad, height: bounds.height - 2 * pad)
        guard inner.width > 0, inner.height > 0 else { return nil }
        guard let (minX, minY, maxX, maxY) = extent(of: shape) else { return nil }
        if minX >= inner.x, maxX <= inner.x + inner.width, minY >= inner.y, maxY <= inner.y + inner.height { return shape }
        switch shape {
        case let .line(start, end):
            guard let (a, b) = clip(start, end, to: inner), hypot(b.x - a.x, b.y - a.y) >= minimumLength else { return nil }
            return .line(start: a, end: b)
        case let .arrow(start, tip):
            guard let (a, b) = clip(start, tip, to: inner), hypot(b.x - a.x, b.y - a.y) >= minimumLength else { return nil }
            return .arrow(start: a, tip: b)
        case .ellipse, .polygon, .polyline:
            guard allowShift, maxX - minX <= inner.width, maxY - minY <= inner.height else { return nil }
            let dx = minX < inner.x ? inner.x - minX : (maxX > inner.x + inner.width ? inner.x + inner.width - maxX : 0)
            let dy = minY < inner.y ? inner.y - minY : (maxY > inner.y + inner.height ? inner.y + inner.height - maxY : 0)
            return translated(shape, dx: dx, dy: dy)
        }
    }

    /// Shorter remains (a stroke that mostly ran off the page) keep the freehand ink.
    public static let minimumLength = 8.0

    /// Liang–Barsky clipping of the segment `a→b` to `rect`; nil when it lies outside.
    public static func clip(_ a: PagePoint, _ b: PagePoint, to rect: PageRect) -> (PagePoint, PagePoint)? {
        let dx = b.x - a.x, dy = b.y - a.y
        var t0 = 0.0, t1 = 1.0
        for (p, q) in [(-dx, a.x - rect.x), (dx, rect.x + rect.width - a.x), (-dy, a.y - rect.y), (dy, rect.y + rect.height - a.y)] {
            if p == 0 {
                if q < 0 { return nil }
            } else {
                let r = q / p
                if p < 0 { if r > t1 { return nil }; t0 = max(t0, r) } else { if r < t0 { return nil }; t1 = min(t1, r) }
            }
        }
        return (PagePoint(x: a.x + t0 * dx, y: a.y + t0 * dy), PagePoint(x: a.x + t1 * dx, y: a.y + t1 * dy))
    }

    /// Exact bounding box (an ellipse analytically, not its sampled outline:
    /// the editable ellipse object is validated by its true frame).
    static func extent(of shape: RecognizedShape) -> (Double, Double, Double, Double)? {
        let points: [PagePoint]
        switch shape {
        case let .line(a, b), let .arrow(a, b): points = [a, b]
        case let .ellipse(center, rx, ry, degrees):
            let angle = degrees * .pi / 180
            let hx = hypot(rx * cos(angle), ry * sin(angle)), hy = hypot(rx * sin(angle), ry * cos(angle))
            points = [.init(x: center.x - hx, y: center.y - hy), .init(x: center.x + hx, y: center.y + hy)]
        case let .polygon(_, vertices), let .polyline(vertices, _): points = vertices
        }
        guard !points.isEmpty, points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return nil }
        return (points.map(\.x).min()!, points.map(\.y).min()!, points.map(\.x).max()!, points.map(\.y).max()!)
    }

    static func translated(_ shape: RecognizedShape, dx: Double, dy: Double) -> RecognizedShape {
        func move(_ p: PagePoint) -> PagePoint { .init(x: p.x + dx, y: p.y + dy) }
        switch shape {
        case let .line(a, b): return .line(start: move(a), end: move(b))
        case let .arrow(a, b): return .arrow(start: move(a), tip: move(b))
        case let .ellipse(center, rx, ry, degrees): return .ellipse(center: move(center), radiusX: rx, radiusY: ry, degrees: degrees)
        case let .polygon(kind, vertices): return .polygon(kind, vertices.map(move))
        case let .polyline(vertices, arrow): return .polyline(vertices.map(move), arrow: arrow)
        }
    }
}
