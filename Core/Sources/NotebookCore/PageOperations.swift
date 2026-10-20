import Foundation

public enum PaperColor: String, Codable, CaseIterable, Sendable { case white, dark }

/// Insets are in displayed page points, independent of the source PDF's rotation.
/// Ink and text remain in their original content coordinates, possibly negative.
public struct PageMargins: Codable, Equatable, Sendable {
    public var left: Double
    public var right: Double
    public var top: Double
    public var bottom: Double
    public var style: PaperStyle
    public var color: PaperColor
    public init(left: Double = 0, right: Double = 0, top: Double = 0, bottom: Double = 0,
                style: PaperStyle = .blank, color: PaperColor = .white) {
        self.left = left; self.right = right; self.top = top; self.bottom = bottom
        self.style = style; self.color = color
    }
    public var isEmpty: Bool { left == 0 && right == 0 && top == 0 && bottom == 0 }
    public func validate() throws {
        guard [left, right, top, bottom].allSatisfy({ $0.isFinite && (0...14_400).contains($0) }),
              style != .legacyTest else { throw StorageError.invalidDocument }
    }

    public func scaled(from source: PageSize, to destination: PageSize) throws -> PageMargins {
        try validate()
        guard [source.width, source.height, destination.width, destination.height]
            .allSatisfy({ $0.isFinite && $0 > 0 }) else { throw StorageError.invalidDocument }
        let result = PageMargins(left: left * (destination.width / source.width),
            right: right * (destination.width / source.width),
            top: top * (destination.height / source.height),
            bottom: bottom * (destination.height / source.height), style: style, color: color)
        try result.validate()
        return result
    }
}

public enum PaperStyle: String, Codable, CaseIterable, Sendable {
    case blank, lined, grid, legacyTest

    public static var geometry: PDFPageGeometry {
        try! PDFPageGeometry(mediaBox: .init(x: 0, y: 0, width: 595, height: 842),
                             cropBox: .init(x: 0, y: 0, width: 595, height: 842), rotation: 0)
    }
}

public struct PDFPageReference: Codable, Equatable, Hashable, Sendable {
    public var sourceID: UUID
    public var pageIndex: Int
    public init(sourceID: UUID, pageIndex: Int) { self.sourceID = sourceID; self.pageIndex = pageIndex }
}

/// Original bytes are immutable through page operations. Many pages can share a source.
public struct PDFSource: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let data: Data
    public let pageCount: Int
    public init(id: UUID = UUID(), data: Data, pageCount: Int) {
        self.id = id; self.data = data; self.pageCount = pageCount
    }
}

public struct DeletedPage: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID { page.id }
    public let page: Page
    public let originalIndex: Int
    public let deletedAt: Date
    public let nextPageID: UUID?
    public let previousPageID: UUID?
    public var reason: PageTrashReason?
}

public enum PageTrashReason: String, Codable, Sendable { case marginReduction, cleared }

public enum PageOperationError: Error, LocalizedError {
    case missingPage, invalidOrder, lastPage, pageLimit, trashLimit
    public var errorDescription: String? {
        switch self {
        case .missingPage: "Diese Seite ist nicht mehr vorhanden. Bitte die Seitenliste erneut öffnen."
        case .invalidOrder: "Die gewünschte Seitenposition ist ungültig."
        case .lastPage: "Die letzte Seite eines Hefts bleibt erhalten."
        case .pageLimit: "Ein Heft unterstützt derzeit höchstens 500 aktive Seiten."
        case .trashLimit: "Der Seitenpapierkorb enthält bereits 500 Seiten. Bitte zunächst ein neues Heft verwenden."
        }
    }
}

extension Notebook {
    /// A whole import shares percentages, not the reference page's point values.
    /// The displayed crop dimensions include PDF rotation; legacy ink stays A4.
    /// For a paper page the group (`wholeImport`) is every active paper sheet;
    /// each keeps its own paper style and colour in the extra space.
    public func marginsByPage(_ margins: PageMargins, relativeTo id: UUID, wholeImport: Bool, standardPageUnits: Bool = false) throws -> [UUID: PageMargins] {
        try margins.validate()
        let document = try preparedForPageEditing()
        guard let reference = document.pages.first(where: { $0.id == id }) else { throw PageOperationError.missingPage }
        let base = reference.geometry?.displaySize ?? .a4
        let targets: [Page]
        if let sourceID = reference.pdfReference?.sourceID {
            targets = document.pages.filter { wholeImport ? $0.pdfReference?.sourceID == sourceID : $0.id == id }
        } else {
            guard reference.writingSpaceExtendsPaper else { throw PageOperationError.missingPage }
            targets = document.pages.filter { wholeImport ? $0.writingSpaceExtendsPaper : $0.id == id }
        }
        return try Dictionary(uniqueKeysWithValues: targets.map { page in
            let value = page.id == id || standardPageUnits ? margins : try margins.scaled(from: base, to: page.geometry?.displaySize ?? .a4)
            return (page.id, try page.writingSpace(value))
        })
    }

    /// Pure value migration; no existing ID, coordinates, ink or text changes.
    public func preparedForPageEditing() throws -> Notebook {
        try validate()
        if pdfSources != nil { return self }
        var result = self
        result.schemaVersion = max(3, schemaVersion)
        result.pdfSources = []
        result.deletedPages = []
        if let pdf {
            let source = PDFSource(data: pdf, pageCount: pages.count)
            result.pdfSources = [source]
            for index in result.pages.indices {
                result.pages[index].pdfReference = PDFPageReference(sourceID: source.id, pageIndex: index)
            }
        } else {
            guard pages.count == 1, pages[0].geometry == nil else { throw StorageError.invalidDocument }
            result.pages[0].paper = .legacyTest
        }
        result.pdf = nil
        try result.validate()
        return result
    }

    public static func blank(title: String) -> Notebook {
        var result = Notebook()
        result.title = title
        result.schemaVersion = 3
        result.pdfSources = []
        result.deletedPages = []
        result.pages[0].paper = .blank
        result.pages[0].geometry = PaperStyle.geometry
        return result
    }

    @discardableResult
    public mutating func insertPaper(_ style: PaperStyle, color: PaperColor = .white, at index: Int, geometry: PDFPageGeometry? = nil) throws -> UUID {
        var next = try preparedForPageEditing()
        guard next.pages.count < 500 else { throw PageOperationError.pageLimit }
        guard (0...next.pages.count).contains(index), style != .legacyTest else { throw PageOperationError.invalidOrder }
        let geometry = geometry ?? next.appearance?.geometry ?? PaperStyle.geometry
        if geometry != PaperStyle.geometry { next.schemaVersion = max(7, next.schemaVersion) }
        var page = Page(); page.paper = style; page.paperColor = color; page.geometry = geometry
        next.pages.insert(page, at: index)
        try next.validate(); self = next
        return page.id
    }

    /// Geometry comes from actual PDFKit validation before this Core operation.
    @discardableResult
    public mutating func insertPDF(_ data: Data, geometries: [PDFPageGeometry], at index: Int) throws -> [UUID] {
        var next = try preparedForPageEditing()
        guard !geometries.isEmpty, next.pages.count + geometries.count <= 500 else { throw PageOperationError.pageLimit }
        guard (0...next.pages.count).contains(index) else { throw PageOperationError.invalidOrder }
        let source = PDFSource(data: data, pageCount: geometries.count)
        let additions = geometries.enumerated().map { offset, geometry in
            var page = Page(); page.geometry = geometry
            page.pdfReference = PDFPageReference(sourceID: source.id, pageIndex: offset)
            return page
        }
        next.pdfSources?.append(source)
        next.pages.insert(contentsOf: additions, at: index)
        try next.validate(); self = next
        return additions.map(\.id)
    }

    @discardableResult
    public mutating func duplicatePage(_ id: UUID) throws -> UUID {
        var next = try preparedForPageEditing()
        guard next.pages.count < 500 else { throw PageOperationError.pageLimit }
        guard let index = next.pages.firstIndex(where: { $0.id == id }) else { throw PageOperationError.missingPage }
        let copy = next.pages[index].independentCopy()
        next.pages.insert(copy, at: index + 1)
        try next.validate(); self = next
        return copy.id
    }

    public mutating func reorderPages(_ ids: [UUID]) throws {
        guard ids.count == pages.count, Set(ids).count == ids.count, Set(ids) == Set(pages.map(\.id)) else {
            throw PageOperationError.invalidOrder
        }
        if ids == pages.map(\.id) { return }
        var next = try preparedForPageEditing()
        let lookup = Dictionary(uniqueKeysWithValues: next.pages.map { ($0.id, $0) })
        next.pages = try ids.map { id in
            guard let page = lookup[id] else { throw PageOperationError.missingPage }; return page
        }
        try next.validate(); self = next
    }

    /// Destination is the final zero-based index, after removing the source page.
    public mutating func movePage(_ id: UUID, to index: Int) throws {
        guard let old = pages.firstIndex(where: { $0.id == id }) else { throw PageOperationError.missingPage }
        guard pages.indices.contains(index) else { throw PageOperationError.invalidOrder }
        var order = pages.map(\.id); order.remove(at: old); order.insert(id, at: index)
        try reorderPages(order)
    }

    public mutating func trashPage(_ id: UUID, at date: Date = Date()) throws {
        guard pages.count > 1 else { throw PageOperationError.lastPage }
        var next = try preparedForPageEditing()
        guard (next.deletedPages?.count ?? 0) < 500 else { throw PageOperationError.trashLimit }
        guard let index = next.pages.firstIndex(where: { $0.id == id }) else { throw PageOperationError.missingPage }
        let entry = DeletedPage(page: next.pages[index], originalIndex: index, deletedAt: date,
            nextPageID: index + 1 < next.pages.count ? next.pages[index + 1].id : nil,
            previousPageID: index > 0 ? next.pages[index - 1].id : nil)
        next.pages.remove(at: index); next.deletedPages?.insert(entry, at: 0)
        try next.validate(); self = next
    }

    /// Older margin snapshots already identify their original page through
    /// previousPageID. Verify the source and geometry before replacing anything.
    public func marginRestoreTarget(for entry: DeletedPage) -> UUID? {
        if entry.reason == .cleared, let target = entry.previousPageID,
           let current = pages.first(where: { $0.id == target }),
           current.pdfReference == entry.page.pdfReference, current.geometry == entry.page.geometry { return target }
        guard entry.reason == .marginReduction, let target = entry.previousPageID,
              let current = pages.first(where: { $0.id == target }),
              entry.page.pdfReference != nil || (entry.page.writingSpaceExtendsPaper && current.writingSpaceExtendsPaper),
              current.pdfReference == entry.page.pdfReference, current.geometry == entry.page.geometry else { return nil }
        return target
    }

    @discardableResult
    public mutating func restorePage(_ id: UUID) throws -> UUID {
        var next = try preparedForPageEditing()
        guard let offset = next.deletedPages?.firstIndex(where: { $0.id == id }),
              let entry = next.deletedPages?[offset] else { throw PageOperationError.missingPage }
        if let target = next.marginRestoreTarget(for: entry),
           let index = next.pages.firstIndex(where: { $0.id == target }) {
            let savedCurrent = next.pages[index].independentCopy()
            let backup = DeletedPage(page: savedCurrent, originalIndex: index, deletedAt: Date(),
                nextPageID: index + 1 < next.pages.count ? next.pages[index + 1].id : nil,
                previousPageID: target, reason: entry.reason)
            var restored = entry.page; restored.id = target
            next.pages[index] = restored
            next.deletedPages?.remove(at: offset)
            next.deletedPages?.insert(backup, at: 0)
            try next.validate(); self = next
            return target
        }
        // Deleted ordinary pages, or margin snapshots whose original is gone,
        // restore independently. Never guess a replacement by array position.
        guard next.pages.count < 500 else { throw PageOperationError.pageLimit }
        let index: Int
        if let following = entry.nextPageID, let position = next.pages.firstIndex(where: { $0.id == following }) { index = position }
        else if let preceding = entry.previousPageID, let position = next.pages.firstIndex(where: { $0.id == preceding }) { index = position + 1 }
        else { index = min(entry.originalIndex, next.pages.count) }
        next.deletedPages?.remove(at: offset); next.pages.insert(entry.page, at: index)
        try next.validate(); self = next
        return entry.page.id
    }

    public mutating func toggleBookmark(_ id: UUID) throws {
        var next = try preparedForPageEditing()
        guard let index = next.pages.firstIndex(where: { $0.id == id }) else { throw PageOperationError.missingPage }
        next.pages[index].bookmarked = !(next.pages[index].bookmarked ?? false)
        try next.validate(); self = next
    }

    public mutating func setMargins(_ margins: PageMargins, pageIDs: [UUID]) throws {
        try margins.validate()
        var next = try preparedForPageEditing()
        guard !pageIDs.isEmpty, Set(pageIDs).count == pageIDs.count else { throw PageOperationError.missingPage }
        for id in pageIDs {
            guard let index = next.pages.firstIndex(where: { $0.id == id }),
                  next.pages[index].pdfReference != nil || next.pages[index].writingSpaceExtendsPaper else {
                throw PageOperationError.missingPage
            }
            let value = try next.pages[index].writingSpace(margins)
            next.pages[index].margins = value.isEmpty ? nil : value
        }
        next.raiseSchemaForPaperWritingSpace()
        try next.validate(); self = next
    }

    /// Writing space on paper needs schema 10: older builds lock such a
    /// notebook instead of rejecting it into an older recovery copy.
    mutating func raiseSchemaForPaperWritingSpace() {
        let all = pages + (deletedPages ?? []).map(\.page)
        if all.contains(where: { $0.writingSpaceExtendsPaper && $0.margins != nil }) { schemaVersion = max(10, schemaVersion) }
    }

    /// Complete pre-trim snapshots receive new IDs. Their previousPageID links
    /// to the original page; restoring swaps its full state with a trash backup.
    public mutating func applyMargins(_ margins: PageMargins, pageIDs: [UUID],
                                     trimmedDrawings: [UUID: Data] = [:]) throws {
        guard !pageIDs.isEmpty, Set(pageIDs).count == pageIDs.count else { throw PageOperationError.missingPage }
        try applyMargins(Dictionary(uniqueKeysWithValues: pageIDs.map { ($0, margins) }), trimmedDrawings: trimmedDrawings)
    }

    public mutating func applyMargins(_ assignments: [UUID: PageMargins], trimmedDrawings: [UUID: Data] = [:]) throws {
        var next = try preparedForPageEditing()
        guard !assignments.isEmpty, Set(assignments.keys).isSubset(of: Set(next.pages.map(\.id))),
              Set(trimmedDrawings.keys).isSubset(of: Set(assignments.keys)) else { throw StorageError.invalidDocument }
        guard (next.deletedPages?.count ?? 0) + trimmedDrawings.count <= 500 else { throw PageOperationError.trashLimit }
        for index in next.pages.indices {
            let id = next.pages[index].id
            guard let requested = assignments[id] else { continue }
            guard next.pages[index].pdfReference != nil || next.pages[index].writingSpaceExtendsPaper else { throw PageOperationError.missingPage }
            let margins = try next.pages[index].writingSpace(requested)
            if let drawing = trimmedDrawings[id] {
                let copy = next.pages[index].independentCopy()
                let entry = DeletedPage(page: copy, originalIndex: index, deletedAt: Date(),
                    nextPageID: index + 1 < next.pages.count ? next.pages[index + 1].id : nil,
                    previousPageID: id, reason: .marginReduction)
                next.deletedPages?.insert(entry, at: 0)
                next.pages[index].drawing = drawing
            }
            next.pages[index].margins = margins.isEmpty ? nil : margins
        }
        next.raiseSchemaForPaperWritingSpace()
        try next.validate()
        self = next
    }
}
