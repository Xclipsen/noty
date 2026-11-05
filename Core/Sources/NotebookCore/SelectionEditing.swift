import Foundation

// Lasso and selection fixes from the audit of 7f8bfe7 (Lasso Fund 2, 5, 7),
// kept apart from the shape and text styling code.

extension ImageObject {
    /// The four corners of the rotated image (rotation in degrees about its
    /// centre, like `PageObjectHitTest.hits(_:at:)`), in drawing order.
    public var rotatedCorners: [PagePoint] {
        let radians = rotation * .pi / 180, c = cos(radians), s = sin(radians)
        let cx = x + width / 2, cy = y + height / 2
        return [(-width / 2, -height / 2), (width / 2, -height / 2), (width / 2, height / 2), (-width / 2, height / 2)].map { u, v in
            PagePoint(x: cx + u * c - v * s, y: cy + u * s + v * c)
        }
    }
}

extension LassoRegion {
    /// Whether a lasso selects `image`: it touches, crosses or encloses the
    /// rotated image itself, not merely the empty corners of its axis-aligned
    /// bounds (Fund 5; a tap already used the rotated rectangle).
    public func selects(_ image: ImageObject) -> Bool {
        intersectsPolyline(image.rotatedCorners, closed: true)
    }
}

extension TextBox {
    /// The field in the explicit colour `ink`: style and every run. Automatic
    /// colour (black/white after the background) ends, since that flag is
    /// only valid without an own ink (`TextBoxStyle.validate`, Fund 2).
    public func recolored(_ ink: InkColor) -> TextBox {
        var result = self
        result.style.ink = ink; result.style.automaticColor = nil
        result.runs = runs?.map { run in var run = run; run.style.ink = ink; run.style.automaticColor = nil; return run }
        return result
    }
}

/// Where a copy (duplicate or paste) goes beside its original `frame` on a
/// page `bounds` (Fund 7): `step` right/down, to the left/up when there is
/// no room, otherwise as far as the page allows – never exactly on top of
/// the original unless the copy fills the page along that axis. A frame
/// that sticks out is moved back onto the page.
///
/// `direction` (signs per axis) continues a series of copies the way it
/// went so far; `isTaken(dx, dy)` reports an offset at which the copy would
/// lie exactly on the original or an earlier copy. Then the copy is
/// staggered further, first in the free direction, then farther away, so
/// pasting or duplicating five times at the edge or in a corner gives five
/// different places (Review: the copies jumped 526 ↔ 550, the second one
/// onto the original). Only when every place on the page is taken does it
/// fall back to the first choice.
public enum PasteOffset {
    public static func offset(for frame: PageRect, in bounds: PageRect, step: Double = 24,
                              direction: (x: Double, y: Double) = (1, 1),
                              isTaken: (Double, Double) -> Bool = { _, _ in false }) -> (dx: Double, dy: Double) {
        func room(_ low: Double, _ high: Double, _ minimum: Double, _ maximum: Double) -> (before: Double, after: Double) {
            (low - minimum, maximum - high)
        }
        let x = room(frame.x, frame.x + frame.width, bounds.x, bounds.x + bounds.width)
        let y = room(frame.y, frame.y + frame.height, bounds.y, bounds.y + bounds.height)
        func axis(_ room: (before: Double, after: Double), _ sign: Double) -> Double {
            let (before, after) = room
            if before < 0 { return -before }
            if after < 0 { return max(after, -before) }
            if sign < 0 {
                if before >= step { return -step }
                if after >= step { return step }
            } else {
                if after >= step { return step }
                if before >= step { return -step }
            }
            return after >= before ? after : -before
        }
        let sx: Double = direction.x < 0 ? -1 : 1, sy: Double = direction.y < 0 ? -1 : 1
        let first = (dx: axis(x, sx), dy: axis(y, sy))
        guard isTaken(first.dx, first.dy) else { return first }
        // A frame outside the page is first moved back onto it; staggering
        // then goes on from there (both shifts within the page).
        func clamp(_ value: Double, _ room: (before: Double, after: Double)) -> Double {
            if room.before < 0 || room.after < 0 { return axis(room, 1) }
            return min(max(value, -room.before), room.after)
        }
        let reach = max(bounds.width, bounds.height) / max(step, 0.5)
        let rings = Int(min(400, max(1, reach.rounded(.up) + 1)))
        var tried = Set<[Double]>()
        for ring in 1...rings {
            let distance = Double(ring) * step
            // Corners of the ring first (diagonal staggering), then its axes.
            let candidates: [(Double, Double)] = [(sx, sy), (-sx, sy), (sx, -sy), (-sx, -sy), (sx, 0), (0, sy), (-sx, 0), (0, -sy)]
            for (ax, ay) in candidates {
                let dx = clamp(ax * distance, x), dy = clamp(ay * distance, y)
                guard tried.insert([dx, dy]).inserted else { continue }
                if abs(dx) < 0.001, abs(dy) < 0.001, x.before >= 0, x.after >= 0, y.before >= 0, y.after >= 0 { continue }
                if !isTaken(dx, dy) { return (dx, dy) }
            }
        }
        return first
    }
}

/// Which of several overlapping selection handles a touch takes: the one
/// whose dot is nearest; a scale corner within `cornerBias` screen points of
/// that one wins (Review: a polygon point on a corner of the frame lay above
/// the scale corner and took every touch). Both stay reachable: a point
/// handle still wins when the touch is clearly nearer to its dot.
public enum SelectionHandlePriority {
    public static let cornerBias = 6.0
    /// `distances`: screen points from the touch to each handle's centre.
    public static func preferred(distances: [Double], isCorner: [Bool], cornerBias: Double = cornerBias) -> Int? {
        guard !distances.isEmpty, distances.count == isCorner.count else { return nil }
        return distances.indices.min { a, b in
            let da = distances[a] - (isCorner[a] ? cornerBias : 0), db = distances[b] - (isCorner[b] ? cornerBias : 0)
            return da == db ? isCorner[a] && !isCorner[b] : da < db
        }
    }
}
