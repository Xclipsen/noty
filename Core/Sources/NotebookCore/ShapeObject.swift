import Foundation

/// `polygon` (schema 13): a closed outline through `ShapeObject.points`.
/// The shape tool does not draw it (`toolKinds`); it comes from held strokes.
public enum ShapeKind: String, Codable, CaseIterable, Sendable {
    case line, arrow, rectangle, ellipse, polygon
    /// Kinds the shape tool draws by dragging from `start` to `end`.
    public static let toolKinds: [ShapeKind] = [.line, .arrow, .rectangle, .ellipse]
}
public enum StrokePattern: String, Codable, CaseIterable, Sendable { case solid, dashed, dotted }

/// Endpoints remain oriented, including descending/vertical lines and arrows.
///
/// Schema 13 adds `points`, the vertices of a polyline (`line`/`arrow` with at
/// least one corner; an arrow's head sits on its last segment) or of a closed
/// `polygon`. `start`/`end` then equal the first/last vertex, so readers of
/// the two endpoints keep a meaningful value. Rectangles and ellipses never
/// carry points; straight lines/arrows keep the schema-6 form without them.
public struct ShapeObject: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var kind: ShapeKind
    public var start: PagePoint
    public var end: PagePoint
    public var color: InkColor
    public var lineWidth: Double
    public var pattern: StrokePattern
    public var fill: InkColor?
    public var points: [PagePoint]?
    /// Most vertices a polyline/polygon may carry.
    public static let maximumVertices = 64
    /// Lowest notebook schema that knows `points` and `polygon`.
    public static let vertexSchemaVersion = 13
    public init(id: UUID = UUID(), kind: ShapeKind, start: PagePoint, end: PagePoint,
                color: InkColor = InkColor(0, 0, 0), lineWidth: Double = 2,
                pattern: StrokePattern = .solid, fill: InkColor? = nil, points: [PagePoint]? = nil) {
        self.id = id; self.kind = kind; self.start = start; self.end = end
        self.color = color; self.lineWidth = lineWidth; self.pattern = pattern; self.fill = fill; self.points = points
    }
    /// A line/arrow (a polyline from three vertices on) or a polygon through
    /// `vertices`; start/end follow the first/last vertex.
    public init(id: UUID = UUID(), kind: ShapeKind, vertices: [PagePoint], color: InkColor = InkColor(0, 0, 0),
                lineWidth: Double = 2, pattern: StrokePattern = .solid, fill: InkColor? = nil) {
        self.init(id: id, kind: kind, start: vertices.first ?? .init(x: 0, y: 0), end: vertices.last ?? .init(x: 0, y: 0),
                  color: color, lineWidth: lineWidth, pattern: pattern, fill: fill,
                  points: kind == .polygon || vertices.count > 2 ? vertices : nil)
    }
    /// Needs schema 13 (older builds would ignore `points` and draw a straight line).
    public var usesVertexFormat: Bool { points != nil || kind == .polygon }
    /// Path vertices of lines, arrows and polygons, in drawn order.
    public var vertices: [PagePoint] { points ?? [start, end] }
    public var frame: PageRect {
        let corners = kind == .rectangle || kind == .ellipse ? [start, end] : vertices
        let xs = corners.map(\.x), ys = corners.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else {
            return .init(x: 0, y: 0, width: 0, height: 0)
        }
        return .init(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
    public var padding: Double { kind == .arrow ? max(10, lineWidth * 3) : lineWidth / 2 }
    public var bounds: PageRect {
        let r = frame, p = padding
        return .init(x: r.x - p, y: r.y - p, width: r.width + 2 * p, height: r.height + 2 * p)
    }
    public func validate() throws {
        let corners = [start, end] + (points ?? [])
        guard corners.allSatisfy({ $0.x.isFinite && $0.y.isFinite && abs($0.x) <= 14_400 && abs($0.y) <= 14_400 }),
              lineWidth.isFinite, (0.5...40).contains(lineWidth) else { throw StorageError.invalidDocument }
        switch kind {
        case .rectangle, .ellipse:
            guard points == nil, hypot(end.x - start.x, end.y - start.y) >= 1, frame.width >= 1, frame.height >= 1 else {
                throw StorageError.invalidDocument
            }
        case .line, .arrow:
            if let points {
                guard (3...Self.maximumVertices).contains(points.count), points.first == start, points.last == end,
                      Self.length(points) >= 1 else { throw StorageError.invalidDocument }
                // The arrow head needs a direction: a last segment of some length.
                if kind == .arrow {
                    let a = points[points.count - 2]
                    guard hypot(end.x - a.x, end.y - a.y) >= 1 else { throw StorageError.invalidDocument }
                }
            } else {
                guard hypot(end.x - start.x, end.y - start.y) >= 1 else { throw StorageError.invalidDocument }
            }
        case .polygon:
            guard let points, (3...Self.maximumVertices).contains(points.count), points.first == start, points.last == end,
                  frame.width >= 1, frame.height >= 1 else { throw StorageError.invalidDocument }
        }
        try color.validate(); try fill?.validate()
    }
    static func length(_ points: [PagePoint]) -> Double {
        zip(points, points.dropFirst()).reduce(0) { $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) }
    }
    public func translated(x: Double, y: Double) -> ShapeObject {
        mapped { PagePoint(x: $0.x + x, y: $0.y + y) }
    }
    /// Every stored point (start, end, vertices) through `transform`.
    public func mapped(_ transform: (PagePoint) -> PagePoint) -> ShapeObject {
        var result = self
        result.start = transform(start); result.end = transform(end)
        result.points = points?.map(transform)
        return result
    }

    /// Head wings of an arrow (wing point, tip), along its last segment.
    public var arrowHead: [(wing: PagePoint, tip: PagePoint)] {
        guard kind == .arrow else { return [] }
        let v = vertices, tip = end, from = v.count >= 2 ? v[v.count - 2] : start
        let angle = atan2(tip.y - from.y, tip.x - from.x)
        let length = max(10, lineWidth * 3)
        return [-0.5, 0.5].map { side in
            (PagePoint(x: tip.x - length * cos(angle + side), y: tip.y - length * sin(angle + side)), tip)
        }
    }
    /// The straight lines that are drawn (not ellipses): open polylines or
    /// closed outlines in page coordinates. Shared by the renderer and the
    /// precision eraser, so a cut follows exactly what is visible.
    public var strokeLines: [(points: [PagePoint], closed: Bool)] {
        switch kind {
        case .line: return [(vertices, false)]
        case .arrow: return [(vertices, false)] + arrowHead.map { ([$0.wing, $0.tip], false) }
        case .polygon: return [(vertices, true)]
        case .rectangle:
            let r = frame
            return [([PagePoint(x: r.x, y: r.y), PagePoint(x: r.x + r.width, y: r.y),
                      PagePoint(x: r.x + r.width, y: r.y + r.height), PagePoint(x: r.x, y: r.y + r.height)], true)]
        case .ellipse: return []
        }
    }
}

extension PageRect {
    public func contains(_ rect: PageRect, tolerance: Double = 0.01) -> Bool {
        rect.x >= x - tolerance && rect.y >= y - tolerance
            && rect.x + rect.width <= x + width + tolerance && rect.y + rect.height <= y + height + tolerance
    }
    public func union(_ rect: PageRect) -> PageRect {
        let left = min(x, rect.x), top = min(y, rect.y)
        return .init(x: left, y: top, width: max(x + width, rect.x + rect.width) - left,
                     height: max(y + height, rect.y + rect.height) - top)
    }
}

/// Atomic content replacement for mixed selections and their shared undo step.
public struct PageContent: Equatable, Sendable {
    public var drawing: Data
    public var textBoxes: [TextBox]
    public var images: [ImageObject]
    public var shapes: [ShapeObject]
    public init(page: Page) {
        drawing = page.drawing; textBoxes = page.effectiveTextBoxes
        images = page.images ?? []; shapes = page.shapes ?? []
    }
}

extension Notebook {
    /// Polylines/polygons need schema 13; removing them never lowers it.
    mutating func raiseSchemaForShapes(_ shapes: [ShapeObject]) {
        if shapes.contains(where: \.usesVertexFormat) { schemaVersion = max(ShapeObject.vertexSchemaVersion, schemaVersion) }
    }
    public mutating func replaceShapes(_ shapes: [ShapeObject], pageID: UUID) throws {
        var next = try preparedForPageEditing()
        guard let index = next.pages.firstIndex(where: { $0.id == pageID }) else { throw PageOperationError.missingPage }
        next.schemaVersion = max(6, next.schemaVersion); next.pages[index].shapes = shapes
        next.raiseSchemaForShapes(shapes)
        try next.validate(); self = next
    }
    public mutating func replaceContent(_ content: PageContent, pageID: UUID) throws {
        var next = try preparedForTextEditing()
        guard let index = next.pages.firstIndex(where: { $0.id == pageID }) else { throw PageOperationError.missingPage }
        next.schemaVersion = max(6, next.schemaVersion)
        if content.textBoxes.contains(where: \.usesTextFlowFormat) { next.schemaVersion = max(8, next.schemaVersion) }
        if content.textBoxes.contains(where: \.usesRichText) { next.schemaVersion = max(7, next.schemaVersion) }
        next.raiseSchemaForTextColors(content.textBoxes)
        next.pages[index].drawing = content.drawing
        next.pages[index].textBoxes = content.textBoxes
        next.pages[index].images = content.images
        next.pages[index].shapes = content.shapes
        next.raiseSchemaForShapes(content.shapes)
        next.raiseSchemaForImageAssets()
        let bounds = next.pages[index].textBounds
        guard content.textBoxes.allSatisfy({ bounds.contains($0.rect) }) else { throw StorageError.invalidDocument }
        try next.validate(); self = next
    }
}
