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
public enum PasteOffset {
    public static func offset(for frame: PageRect, in bounds: PageRect, step: Double = 24) -> (dx: Double, dy: Double) {
        func axis(_ low: Double, _ high: Double, _ minimum: Double, _ maximum: Double) -> Double {
            let before = low - minimum, after = maximum - high
            if before < 0 { return -before }
            if after < 0 { return max(after, -before) }
            if after >= step { return step }
            if before >= step { return -step }
            return after >= before ? after : -before
        }
        return (axis(frame.x, frame.x + frame.width, bounds.x, bounds.x + bounds.width),
                axis(frame.y, frame.y + frame.height, bounds.y, bounds.y + bounds.height))
    }
}
