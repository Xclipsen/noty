import Foundation

/// Anchor points of a selected shape, each dragged on its own (instead of
/// only scaling the whole shape):
/// - lines/arrows: both ends; polylines and polygons: every vertex
///   (an arrow's last vertex is its tip),
/// - rectangles: the four corners (the opposite corner stays),
/// - ellipses/circles: the four side points top, right, bottom, left
///   (the opposite side stays).
extension ShapeObject {
    public var anchors: [PagePoint] {
        switch kind {
        case .line, .arrow, .polygon: return vertices
        case .rectangle:
            let r = frame
            return [.init(x: r.x, y: r.y), .init(x: r.x + r.width, y: r.y),
                    .init(x: r.x + r.width, y: r.y + r.height), .init(x: r.x, y: r.y + r.height)]
        case .ellipse:
            let r = frame
            return [.init(x: r.x + r.width / 2, y: r.y), .init(x: r.x + r.width, y: r.y + r.height / 2),
                    .init(x: r.x + r.width / 2, y: r.y + r.height), .init(x: r.x, y: r.y + r.height / 2)]
        }
    }

    /// The shape with anchor `index` at `point`; nil when the index is unknown
    /// or the result would be invalid (too small, degenerate head). Callers
    /// always start from the shape as it was when the drag began, so a
    /// rectangle/ellipse dragged across its opposite side simply flips.
    public func movingAnchor(_ index: Int, to point: PagePoint) -> ShapeObject? {
        guard point.x.isFinite, point.y.isFinite, anchors.indices.contains(index) else { return nil }
        var result = self
        switch kind {
        case .line, .arrow, .polygon:
            if var vertices = points {
                vertices[index] = point
                result.points = vertices; result.start = vertices[0]; result.end = vertices[vertices.count - 1]
            } else if index == 0 { result.start = point } else { result.end = point }
        case .rectangle:
            let opposite = anchors[(index + 2) % 4]
            result.start = .init(x: min(point.x, opposite.x), y: min(point.y, opposite.y))
            result.end = .init(x: max(point.x, opposite.x), y: max(point.y, opposite.y))
        case .ellipse:
            let r = frame
            var minX = r.x, minY = r.y, maxX = r.x + r.width, maxY = r.y + r.height
            switch index {
            case 0: minY = point.y
            case 1: maxX = point.x
            case 2: maxY = point.y
            default: minX = point.x
            }
            result.start = .init(x: min(minX, maxX), y: min(minY, maxY))
            result.end = .init(x: max(minX, maxX), y: max(minY, maxY))
        }
        return (try? result.validate()) != nil ? result : nil
    }
}
