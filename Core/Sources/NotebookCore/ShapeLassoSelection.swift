import Foundation

/// Nutzer 22.10.2026: „Wenn man in einer Form etwas auswählt, wählt es die
/// Form auch mit aus – das sollte nicht so sein, es sei denn, sie ist
/// ausgefüllt.“ An unfilled shape is only its stroke, like handwriting: the
/// lasso must touch, cross or enclose the drawn outline (half the line width
/// counts). Only a visible fill (`hasVisibleFill`, any strength above 0) makes
/// the inside count, also for a lasso drawn wholly inside it.
extension ShapeObject {
    /// Drawn outline as polylines in page coordinates: `strokeLines`, the
    /// ellipse sampled closely enough for selection (≤ ~1 % of its radius off).
    public var outlinePolylines: [(points: [PagePoint], closed: Bool)] {
        guard kind == .ellipse else { return strokeLines }
        let r = frame, rx = r.width / 2, ry = r.height / 2
        let count = 72
        let points = (0..<count).map { index -> PagePoint in
            let angle = Double(index) / Double(count) * 2 * .pi
            return PagePoint(x: r.x + rx + rx * cos(angle), y: r.y + ry + ry * sin(angle))
        }
        return [(points, true)]
    }
}

extension LassoRegion {
    /// Whether a lasso selects `shape` (see above). Bounding-box overlap alone never does.
    public func selects(_ shape: ShapeObject) -> Bool {
        let outlines = shape.outlinePolylines
        for line in outlines where !line.points.isEmpty {
            // Closed outlines as an explicit closing segment: `closed: true`
            // would also accept a lasso inside the outline.
            let path = line.closed ? line.points + [line.points[0]] : line.points
            if intersectsPolyline(path, radius: shape.lineWidth / 2) { return true }
        }
        if shape.hasVisibleFill, let area = outlines.first?.points, area.count >= 3 {
            let inside = LassoRegion(points: area)
            if points.contains(where: inside.contains) { return true }
        }
        return false
    }
}

/// Nutzer zu Build 62: a lasso takes a text field only when it touches or
/// encloses the field's text (its laid-out line areas), not when it merely
/// crosses the empty part of the frame – the same rule as a tap
/// (`PageObjectHitTest`). Like shapes, a filled field counts by its whole
/// surface and a field with only a frame by its frame line.
extension LassoRegion {
    /// - Parameter lines: used rects of the laid-out text lines in the field's
    ///   own unrotated page units (origin: the text frame's top-left corner).
    ///   Empty (no laid-out text): the text frame counts.
    public func selects(_ box: TextBox, lines: [PageRect]) -> Bool {
        let p = box.fieldPadding
        let visible = [box.pagePoint(.init(x: -p, y: -p)), box.pagePoint(.init(x: box.width + p, y: -p)),
                       box.pagePoint(.init(x: box.width + p, y: box.height + p)), box.pagePoint(.init(x: -p, y: box.height + p))]
        if box.fill != nil, intersectsPolyline(visible, closed: true) { return true }
        // The frame line only (open polyline: a lasso inside does not count).
        if box.border != nil, intersectsPolyline(visible + [visible[0]], radius: TextBox.fieldBorderWidth / 2) { return true }
        let areas = lines.filter { $0.width > 0.01 && $0.height > 0.01 }
        guard !areas.isEmpty else { return intersectsPolyline(box.textCorners, closed: true) }
        for line in areas {
            let corners = [box.pagePoint(.init(x: line.x, y: line.y)), box.pagePoint(.init(x: line.x + line.width, y: line.y)),
                           box.pagePoint(.init(x: line.x + line.width, y: line.y + line.height)),
                           box.pagePoint(.init(x: line.x, y: line.y + line.height))]
            if intersectsPolyline(corners, closed: true) { return true }
        }
        return false
    }
}
