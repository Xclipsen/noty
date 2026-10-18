import Foundation

public struct CopiedPage: Sendable {
    public let page: Page
    public let source: PDFSource?
    public let schemaVersion: Int
}

extension Notebook {
    public func copyPage(_ id: UUID) throws -> CopiedPage {
        let document = try preparedForPageEditing()
        guard let page = document.pages.first(where: { $0.id == id }) else { throw PageOperationError.missingPage }
        return CopiedPage(page: page, source: document.pdfSources?.first { $0.id == page.pdfReference?.sourceID }, schemaVersion: document.schemaVersion)
    }

    @discardableResult
    public mutating func pastePage(_ payload: CopiedPage, after anchor: UUID) throws -> UUID {
        var next = try preparedForPageEditing()
        guard let index = next.pages.firstIndex(where: { $0.id == anchor }) else { throw PageOperationError.missingPage }
        guard next.pages.count < 500 else { throw PageOperationError.pageLimit }
        var page = payload.page.independentCopy()
        next.schemaVersion = max(next.schemaVersion, payload.schemaVersion)
        if let source = payload.source {
            let local = next.pdfSources?.first { $0.data == source.data && $0.pageCount == source.pageCount }
            let target = local ?? PDFSource(data: source.data, pageCount: source.pageCount)
            if local == nil { next.pdfSources?.append(target) }
            page.pdfReference?.sourceID = target.id
        }
        next.pages.insert(page, at: index + 1)
        try next.validate(); self = next; return page.id
    }

    public mutating func movePage(_ id: UUID, after anchor: UUID) throws {
        guard pages.contains(where: { $0.id == id }), pages.contains(where: { $0.id == anchor }) else { throw PageOperationError.missingPage }
        if id == anchor { return }
        var order = pages.map(\.id); order.removeAll { $0 == id }
        let index = order.firstIndex(of: anchor)!
        order.insert(id, at: index + 1)
        try reorderPages(order)
    }

    public mutating func clearPage(_ id: UUID) throws {
        var next = try preparedForPageEditing()
        guard let index = next.pages.firstIndex(where: { $0.id == id }) else { throw PageOperationError.missingPage }
        guard (next.deletedPages?.count ?? 0) < 500 else { throw PageOperationError.trashLimit }
        let saved = next.pages[index].independentCopy()
        next.deletedPages?.insert(DeletedPage(page: saved, originalIndex: index, deletedAt: Date(),
            nextPageID: nil, previousPageID: id, reason: .cleared), at: 0)
        next.schemaVersion = max(7, next.schemaVersion)
        next.pages[index].drawing = Data(); next.pages[index].text = ""
        next.pages[index].textBoxes = nil; next.pages[index].images = nil; next.pages[index].shapes = nil
        try next.validate(); self = next
    }
}
