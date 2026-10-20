import Foundation

public enum ShapeKind: String, Codable, CaseIterable, Sendable { case line, arrow, rectangle, ellipse }
public enum StrokePattern: String, Codable, CaseIterable, Sendable { case solid, dashed, dotted }

/// Endpoints remain oriented, including descending/vertical lines and arrows.
public struct ShapeObject: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var kind: ShapeKind
    public var start: PagePoint
    public var end: PagePoint
    public var color: InkColor
    public var lineWidth: Double
    public var pattern: StrokePattern
    public var fill: InkColor?
    public init(id: UUID = UUID(), kind: ShapeKind, start: PagePoint, end: PagePoint,
                color: InkColor = InkColor(0, 0, 0), lineWidth: Double = 2,
                pattern: StrokePattern = .solid, fill: InkColor? = nil) {
        self.id = id; self.kind = kind; self.start = start; self.end = end
        self.color = color; self.lineWidth = lineWidth; self.pattern = pattern; self.fill = fill
    }
    public var frame: PageRect {
        .init(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
    }
    public var padding: Double { kind == .arrow ? max(10, lineWidth * 3) : lineWidth / 2 }
    public var bounds: PageRect {
        let r = frame, p = padding
        return .init(x: r.x - p, y: r.y - p, width: r.width + 2 * p, height: r.height + 2 * p)
    }
    public func validate() throws {
        guard [start.x, start.y, end.x, end.y, lineWidth].allSatisfy(\.isFinite),
              [start.x, start.y, end.x, end.y].allSatisfy({ abs($0) <= 14_400 }),
              (0.5...40).contains(lineWidth), hypot(end.x - start.x, end.y - start.y) >= 1,
              (kind == .line || kind == .arrow || (frame.width >= 1 && frame.height >= 1)) else {
            throw StorageError.invalidDocument
        }
        try color.validate(); try fill?.validate()
    }
    public func translated(x: Double, y: Double) -> ShapeObject {
        var result = self
        result.start.x += x; result.end.x += x; result.start.y += y; result.end.y += y
        return result
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
    public mutating func replaceShapes(_ shapes: [ShapeObject], pageID: UUID) throws {
        var next = try preparedForPageEditing()
        guard let index = next.pages.firstIndex(where: { $0.id == pageID }) else { throw PageOperationError.missingPage }
        next.schemaVersion = max(6, next.schemaVersion); next.pages[index].shapes = shapes
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
        next.raiseSchemaForImageAssets()
        let bounds = next.pages[index].textBounds
        guard content.textBoxes.allSatisfy({ bounds.contains($0.rect) }) else { throw StorageError.invalidDocument }
        try next.validate(); self = next
    }
}
