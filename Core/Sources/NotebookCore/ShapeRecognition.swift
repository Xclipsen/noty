import Foundation

/// Conservative recognition after an explicit hold, never on normal writing.
public enum ShapeRecognition {
    public static func recognize(_ points: [PagePoint]) -> ShapeKind? {
        guard points.count >= 5, points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }),
              let first = points.first, let last = points.last else { return nil }
        let xs = points.map(\.x), ys = points.map(\.y)
        let left = xs.min()!, right = xs.max()!, top = ys.min()!, bottom = ys.max()!
        let width = right - left, height = bottom - top, diagonal = hypot(width, height)
        guard diagonal >= 24 else { return nil }
        let distance = hypot(last.x - first.x, last.y - first.y)
        // A single-stroke arrow: straight shaft, then two short wings around its tip.
        if let tipIndex = points.indices.max(by: { hypot(points[$0].x-first.x, points[$0].y-first.y) < hypot(points[$1].x-first.x, points[$1].y-first.y) }),
           tipIndex >= points.count / 2, tipIndex < points.count - 2 {
            let tip = points[tipIndex], length = hypot(tip.x-first.x, tip.y-first.y)
            if length >= 40 {
                let shaft = points[0...tipIndex]
                let deviations = shaft.map { abs((tip.y-first.y)*$0.x - (tip.x-first.x)*$0.y + tip.x*first.y-tip.y*first.x) / length }
                let wings = points[(tipIndex+1)...]
                let sides = wings.map { ((tip.x-first.x)*($0.y-tip.y) - (tip.y-first.y)*($0.x-tip.x)) / length }
                if deviations.max()! <= max(3, length*0.035),
                   wings.allSatisfy({ hypot($0.x-tip.x, $0.y-tip.y) <= length*0.38 }),
                   sides.min()! < -4, sides.max()! > 4 { return .arrow }
            }
        }
        if distance > diagonal * 0.75 {
            let deviation = points.map { abs((last.y - first.y) * $0.x - (last.x - first.x) * $0.y + last.x * first.y - last.y * first.x) / distance }.max()!
            return deviation <= max(3, diagonal * 0.035) ? .line : nil
        }
        guard distance < diagonal * 0.18, width >= 12, height >= 12 else { return nil }
        let edgeError = points.reduce(0) { $0 + min(abs($1.x - left), abs($1.x - right), abs($1.y - top), abs($1.y - bottom)) } / Double(points.count)
        if edgeError < min(width, height) * 0.055 { return .rectangle }
        let ellipseError = points.reduce(0) {
            $0 + abs(hypot(($1.x - (left + right) / 2) / (width / 2), ($1.y - (top + bottom) / 2) / (height / 2)) - 1)
        } / Double(points.count)
        return ellipseError < 0.13 ? .ellipse : nil
    }
}
