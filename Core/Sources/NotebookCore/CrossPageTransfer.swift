import Foundation

/// Uniform mapping of canonical source-page coordinates into canonical
/// target-page coordinates: `p' = p * scale + translation`. The scale keeps the
/// moved objects at their on-screen size when pages are displayed with
/// different normalized-width scales.
public struct CrossPageMove: Equatable, Sendable {
    public let scale: Double
    public let translation: PagePoint

    public init(scale: Double, translation: PagePoint) {
        self.scale = scale; self.translation = translation
    }

    /// `sourceStart`: canonical point on the source page where the drag began.
    /// `surfacePoint`: current finger position in notebook surface coordinates.
    /// The start point lands below the finger on the target page; all other
    /// points keep their on-screen offset to it.
    public init?(sourceOrigin: PagePoint, sourceScale: Double, targetOrigin: PagePoint, targetScale: Double,
                 sourceStart: PagePoint, surfacePoint: PagePoint) {
        guard [sourceOrigin.x, sourceOrigin.y, targetOrigin.x, targetOrigin.y, sourceStart.x, sourceStart.y,
               surfacePoint.x, surfacePoint.y, sourceScale, targetScale].allSatisfy(\.isFinite),
              sourceScale > 0, targetScale > 0 else { return nil }
        let k = sourceScale / targetScale
        self.init(scale: k, translation: PagePoint(
            x: (surfacePoint.x - targetOrigin.x) / targetScale - sourceStart.x * k,
            y: (surfacePoint.y - targetOrigin.y) / targetScale - sourceStart.y * k))
    }

    public init?(source: NotebookPagePlacement, target: NotebookPagePlacement, sourceStart: PagePoint, surfacePoint: PagePoint) {
        self.init(sourceOrigin: .init(x: source.contentFrame.x, y: source.contentFrame.y), sourceScale: source.scale,
                  targetOrigin: .init(x: target.contentFrame.x, y: target.contentFrame.y), targetScale: target.scale,
                  sourceStart: sourceStart, surfacePoint: surfacePoint)
    }

    public func apply(_ point: PagePoint) -> PagePoint {
        .init(x: point.x * scale + translation.x, y: point.y * scale + translation.y)
    }
    public func apply(_ rect: PageRect) -> PageRect {
        let origin = apply(PagePoint(x: rect.x, y: rect.y))
        return .init(x: origin.x, y: origin.y, width: rect.width * scale, height: rect.height * scale)
    }
    public func translated(by offset: PagePoint) -> CrossPageMove {
        .init(scale: scale, translation: .init(x: translation.x + offset.x, y: translation.y + offset.y))
    }
}

extension NotebookPagePlacement {
    /// Inverse of `surfaceRect(for:)` for a single point.
    public func contentPoint(forSurface point: PagePoint) -> PagePoint {
        .init(x: (point.x - contentFrame.x) / scale, y: (point.y - contentFrame.y) / scale)
    }
    public func surfacePoint(forContent point: PagePoint) -> PagePoint {
        .init(x: contentFrame.x + point.x * scale, y: contentFrame.y + point.y * scale)
    }
}

public enum CrossPageTransferError: Error, LocalizedError, Equatable {
    case doesNotFit, invalidObject, conflict
    public var errorDescription: String? {
        switch self {
        case .doesNotFit: "Die Auswahl ist zu groß für diese Seite und wurde nicht verschoben."
        case .invalidObject: "Die Auswahl kann in dieser Größe nicht auf diese Seite verschoben werden."
        case .conflict: "Die Seiten wurden inzwischen geändert. Bitte die Auswahl erneut setzen."
        }
    }
}

/// Non-ink members of a moved selection (ink is PencilKit data and is mapped
/// by the app with the same `CrossPageMove`).
public struct MovedObjects: Equatable, Sendable {
    public var textBoxes: [TextBox]
    public var images: [ImageObject]
    public var shapes: [ShapeObject]
    public init(textBoxes: [TextBox] = [], images: [ImageObject] = [], shapes: [ShapeObject] = []) {
        self.textBoxes = textBoxes; self.images = images; self.shapes = shapes
    }
    public var isEmpty: Bool { textBoxes.isEmpty && images.isEmpty && shapes.isEmpty }
    /// Union of the outer bounds used for page-limit checks.
    public var bounds: PageRect? {
        let rects = textBoxes.map(\.rect) + images.map(\.rotatedBounds) + shapes.map(\.bounds)
        return rects.dropFirst().reduce(rects.first) { $0?.union($1) }
    }
    public func translated(by offset: PagePoint) -> MovedObjects {
        var result = self
        for i in result.textBoxes.indices { result.textBoxes[i].x += offset.x; result.textBoxes[i].y += offset.y }
        for i in result.images.indices { result.images[i].x += offset.x; result.images[i].y += offset.y }
        result.shapes = result.shapes.map { $0.translated(x: offset.x, y: offset.y) }
        return result
    }
}

public enum CrossPageTransfer {
    /// Objects keep their identities. Flow segments are never transferable.
    public static func move(_ objects: MovedObjects, by move: CrossPageMove) throws -> MovedObjects {
        guard move.scale.isFinite, move.scale > 0 else { throw CrossPageTransferError.invalidObject }
        var result = objects
        do {
            result.textBoxes = try objects.textBoxes.map {
                try $0.scaled(by: move.scale, around: .init(x: 0, y: 0), translation: move.translation)
            }
        } catch { throw CrossPageTransferError.invalidObject }
        for i in result.images.indices {
            let origin = move.apply(PagePoint(x: result.images[i].x, y: result.images[i].y))
            result.images[i].x = origin.x; result.images[i].y = origin.y
            result.images[i].width *= move.scale; result.images[i].height *= move.scale
            guard (try? result.images[i].validate()) != nil else { throw CrossPageTransferError.invalidObject }
        }
        for i in result.shapes.indices {
            result.shapes[i].start = move.apply(result.shapes[i].start)
            result.shapes[i].end = move.apply(result.shapes[i].end)
            result.shapes[i].lineWidth *= move.scale
            guard (try? result.shapes[i].validate()) != nil else { throw CrossPageTransferError.invalidObject }
        }
        return result
    }

    /// Smallest offset that moves `frame` completely into `limits`; nil when
    /// the frame is larger than the limits. Nothing is ever clipped silently.
    public static func shift(for frame: PageRect, into limits: PageRect, tolerance: Double = 0.01) -> PagePoint? {
        guard [frame.x, frame.y, frame.width, frame.height].allSatisfy(\.isFinite),
              frame.width <= limits.width + tolerance, frame.height <= limits.height + tolerance else { return nil }
        func axis(_ start: Double, _ length: Double, _ lower: Double, _ size: Double) -> Double {
            if start < lower { return lower - start }
            if start + length > lower + size { return max(lower - start, lower + size - start - length) }
            return 0
        }
        return .init(x: axis(frame.x, frame.width, limits.x, limits.width),
                     y: axis(frame.y, frame.height, limits.y, limits.height))
    }

    /// Removes the moved members from their source page (ink is handled by the app).
    public static func removing(texts: Set<UUID>, images: Set<UUID>, shapes: Set<UUID>, from content: PageContent) -> PageContent {
        var result = content
        result.textBoxes.removeAll { texts.contains($0.id) }
        result.images.removeAll { images.contains($0.id) }
        result.shapes.removeAll { shapes.contains($0.id) }
        return result
    }

    /// Appends moved objects to the target content. Identities stay unchanged
    /// unless they would collide inside the target page; then fresh IDs are used.
    /// Every object must lie inside `limits` (the target's writable bounds).
    public static func inserting(_ objects: MovedObjects, into target: PageContent, limits: PageRect)
        throws -> (content: PageContent, objects: MovedObjects) {
        var used = Set(target.textBoxes.map(\.id) + target.images.map(\.id) + target.shapes.map(\.id))
        func unique(_ id: UUID) -> UUID {
            var value = id
            while used.contains(value) { value = UUID() }
            used.insert(value); return value
        }
        var inserted = objects
        for i in inserted.textBoxes.indices {
            guard limits.contains(inserted.textBoxes[i].rect), inserted.textBoxes[i].allowsObjectSelection else {
                throw CrossPageTransferError.doesNotFit
            }
            inserted.textBoxes[i].id = unique(inserted.textBoxes[i].id)
        }
        for i in inserted.images.indices {
            guard inserted.images[i].fits(in: limits) else { throw CrossPageTransferError.doesNotFit }
            inserted.images[i].id = unique(inserted.images[i].id)
        }
        for i in inserted.shapes.indices {
            guard limits.contains(inserted.shapes[i].bounds, tolerance: 0.02) else { throw CrossPageTransferError.doesNotFit }
            inserted.shapes[i].id = unique(inserted.shapes[i].id)
        }
        var result = target
        result.textBoxes += inserted.textBoxes; result.images += inserted.images; result.shapes += inserted.shapes
        return (result, inserted)
    }
}

/// One page of an atomic multi-page content change.
public struct PageContentReplacement: Equatable, Sendable {
    public let pageID: UUID
    public let expected: PageContent
    public let replacement: PageContent
    public init(pageID: UUID, expected: PageContent, replacement: PageContent) {
        self.pageID = pageID; self.expected = expected; self.replacement = replacement
    }
    public var inverted: PageContentReplacement { .init(pageID: pageID, expected: replacement, replacement: expected) }
}

extension Notebook {
    /// All pages change together or none does. Every expected state is checked
    /// first; the complete candidate is validated once, so an object may leave
    /// one page and arrive on another with the same identity.
    public mutating func replaceContents(_ changes: [PageContentReplacement]) throws {
        guard !changes.isEmpty, Set(changes.map(\.pageID)).count == changes.count else { throw StorageError.invalidDocument }
        for change in changes {
            guard let page = pages.first(where: { $0.id == change.pageID }) else { throw PageOperationError.missingPage }
            guard PageContent(page: page) == change.expected else { throw CrossPageTransferError.conflict }
        }
        var next = try preparedForTextEditing()
        next.schemaVersion = max(6, next.schemaVersion)
        for change in changes {
            guard let index = next.pages.firstIndex(where: { $0.id == change.pageID }) else { throw PageOperationError.missingPage }
            let content = change.replacement
            if content.textBoxes.contains(where: \.usesTextFlowFormat) { next.schemaVersion = max(8, next.schemaVersion) }
            if content.textBoxes.contains(where: \.usesRichText) { next.schemaVersion = max(7, next.schemaVersion) }
            next.raiseSchemaForTextColors(content.textBoxes)
            next.pages[index].drawing = content.drawing
            next.pages[index].textBoxes = content.textBoxes
            next.pages[index].images = content.images
            next.pages[index].shapes = content.shapes
            let bounds = next.pages[index].textBounds
            guard content.textBoxes.allSatisfy({ bounds.contains($0.rect) }) else { throw StorageError.invalidDocument }
        }
        try next.validate(); self = next
    }
}
