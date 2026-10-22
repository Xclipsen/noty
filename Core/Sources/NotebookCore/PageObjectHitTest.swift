import Foundation

/// A selectable object on a page, by stable ID (never by array position).
/// Handwriting is no object here: it belongs to the ink tools and the lasso.
public enum PageObjectReference: Hashable, Sendable {
    case text(UUID)
    case image(UUID)
    case shape(UUID)
}

/// Which object a finger tap at a page point means, independent of the
/// layer that will later edit it (Nutzerfeedback Tag 1: with an ink tool
/// active, a finger tap selects the object, the Pencil keeps drawing).
///
/// Order follows the drawn layers (`Page.exportLayers`): text above shapes
/// above images; within a type the later entry lies on top. Page text
/// (`flowID`/`flowRegion`) is no object and locked images stay background,
/// exactly as for the lasso.
public enum PageObjectHitTest {
    /// `point` in canonical page coordinates (no margins, no screen zoom);
    /// `tolerance` widens every object by that many page units (finger size
    /// divided by the current zoom). `shapeHit` lets the app use its real
    /// drawn outline; without it a geometric approximation applies.
    public static func topmost(at point: PagePoint, in content: PageContent, tolerance: Double = 0,
                               shapeHit: ((ShapeObject, PagePoint) -> Bool)? = nil) -> PageObjectReference? {
        guard point.x.isFinite, point.y.isFinite else { return nil }
        let tolerance = tolerance.isFinite ? max(0, tolerance) : 0
        if let box = content.textBoxes.reversed().first(where: { $0.allowsObjectSelection && contains($0.rect, point, tolerance) }) {
            return .text(box.id)
        }
        if let shape = content.shapes.reversed().first(where: { shapeHit?($0, point) ?? hits($0, at: point, tolerance: tolerance) }) {
            return .shape(shape.id)
        }
        if let image = content.images.reversed().first(where: { !$0.locked && hits($0, at: point, tolerance: tolerance) }) {
            return .image(image.id)
        }
        return nil
    }

    /// Inside the rotated image rectangle (rotation in degrees about its centre).
    public static func hits(_ image: ImageObject, at point: PagePoint, tolerance: Double = 0) -> Bool {
        let radians = image.rotation * .pi / 180
        let dx = point.x - (image.x + image.width / 2), dy = point.y - (image.y + image.height / 2)
        let localX = cos(radians) * dx + sin(radians) * dy
        let localY = -sin(radians) * dx + cos(radians) * dy
        return abs(localX) <= image.width / 2 + tolerance && abs(localY) <= image.height / 2 + tolerance
    }

    /// Geometric approximation of a shape's outline (filled: also its inside).
    /// Kinds without their own rule use the padded bounds.
    public static func hits(_ shape: ShapeObject, at point: PagePoint, tolerance: Double = 0) -> Bool {
        let reach = shape.lineWidth / 2 + tolerance
        let frame = shape.frame
        if shape.kind == .line || shape.kind == .arrow {
            // Every segment of a polyline (schema 13); the arrowhead reaches
            // `padding` around the tip.
            let v = shape.vertices
            return zip(v, v.dropFirst()).contains { distance(point, $0, $1) <= reach }
                || (shape.kind == .arrow && hypot(point.x - shape.end.x, point.y - shape.end.y) <= shape.padding + tolerance)
        } else if shape.kind == .polygon {
            // Closed outline through its vertices (schema 13); filled: also inside.
            let v = shape.vertices
            guard v.count > 1 else { return contains(shape.bounds, point, tolerance) }
            if shape.hasVisibleFill && inside(point, polygon: v) { return true }
            return v.indices.contains { distance(point, v[$0], v[($0 + 1) % v.count]) <= reach }
        } else if shape.kind == .rectangle {
            let inside = point.x >= frame.x && point.x <= frame.x + frame.width && point.y >= frame.y && point.y <= frame.y + frame.height
            if inside && shape.hasVisibleFill { return true }
            let corners = [PagePoint(x: frame.x, y: frame.y), PagePoint(x: frame.x + frame.width, y: frame.y),
                           PagePoint(x: frame.x + frame.width, y: frame.y + frame.height), PagePoint(x: frame.x, y: frame.y + frame.height)]
            return corners.indices.contains { distance(point, corners[$0], corners[($0 + 1) % 4]) <= reach }
        } else if shape.kind == .ellipse {
            let rx = frame.width / 2, ry = frame.height / 2
            guard rx > 0, ry > 0 else { return contains(shape.bounds, point, tolerance) }
            let nx = (point.x - (frame.x + rx)) / rx, ny = (point.y - (frame.y + ry)) / ry
            let radial = hypot(nx, ny)
            if radial <= 1 && shape.hasVisibleFill { return true }
            // Radial distance scaled back by the radius in that direction.
            let length = hypot(nx * rx, ny * ry)
            let outline = radial > 0 ? length / radial : min(rx, ry)
            return abs(radial - 1) * outline <= reach
        }
        return contains(shape.bounds, point, tolerance)
    }

    static func contains(_ rect: PageRect, _ point: PagePoint, _ tolerance: Double) -> Bool {
        point.x >= rect.x - tolerance && point.x <= rect.x + rect.width + tolerance
            && point.y >= rect.y - tolerance && point.y <= rect.y + rect.height + tolerance
    }

    /// Even-odd point-in-polygon test.
    private static func inside(_ point: PagePoint, polygon v: [PagePoint]) -> Bool {
        var result = false, j = v.count - 1
        for i in v.indices {
            if (v[i].y > point.y) != (v[j].y > point.y),
               point.x < (v[j].x - v[i].x) * (point.y - v[i].y) / (v[j].y - v[i].y) + v[i].x { result.toggle() }
            j = i
        }
        return result
    }

    private static func distance(_ point: PagePoint, _ a: PagePoint, _ b: PagePoint) -> Double {
        let vx = b.x - a.x, vy = b.y - a.y
        let length = vx * vx + vy * vy
        let t = length > 0 ? max(0, min(1, ((point.x - a.x) * vx + (point.y - a.y) * vy) / length)) : 0
        return hypot(point.x - (a.x + t * vx), point.y - (a.y + t * vy))
    }
}
