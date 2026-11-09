import PDFKit
import PencilKit
import NotebookCore

/// Only the main actor owns PDFKit objects. Page order never mutates source PDFs.
/// Rebuilt after every page operation, reusing the previous catalogue: parsed
/// documents, source page geometries and the raw outline survive as long as
/// their bytes do, so a page operation costs dictionary lookups per page
/// instead of PDFPage objects and linear outline searches. Every check is
/// still evaluated for every active and trashed page.
@MainActor
final class NotebookPDFCatalog {
    private let sources: [UUID: PDFDocument]
    private let sourceBytes: [UUID: Data]
    private let legacy: PDFDocument?
    private let legacyBytes: Data?
    private let legacyIndices: [UUID: Int]
    private var outlines: [NotebookOutlineItem] = []
    private(set) var outlineWasTruncated = false
    /// Source page geometries by document (CoreGraphics boxes, no PDFPage).
    private var geometries: [ObjectIdentifier: [Int: PDFPageGeometry]] = [:]
    /// The outline as read from the PDFs, before page IDs are resolved.
    private var rawOutline: RawOutline?

    private struct RawEntry {
        let key: String
        let title: String
        /// Zero-based page position in its PDF.
        let position: Int?
        let children: [RawEntry]
    }
    private struct RawGroup {
        /// nil: rows go directly into the outline (one source or legacy).
        let groupID: String?
        let groupTitle: String
        let sourceID: UUID?
        let rows: [RawEntry]
    }
    private struct RawOutline {
        /// Documents (in order) the outline was read from.
        let identity: [ObjectIdentifier]
        let groups: [RawGroup]
        let truncated: Bool
    }

    init(_ document: Notebook, reusing old: NotebookPDFCatalog? = nil) throws {
        try document.validate()
        var documents: [UUID: PDFDocument] = [:]
        var bytes: [UUID: Data] = [:]
        for source in document.pdfSources ?? [] {
            let pdf: PDFDocument
            if Self.same(old?.sourceBytes[source.id], source.data), let cached = old?.sources[source.id] { pdf = cached }
            else if Self.same(old?.legacyBytes, source.data), let cached = old?.legacy { pdf = cached }
            else {
                guard let parsed = PDFDocument(data: source.data), !parsed.isLocked else { throw StorageError.invalidDocument }
                pdf = parsed
            }
            guard pdf.pageCount == source.pageCount else { throw StorageError.invalidDocument }
            documents[source.id] = pdf; bytes[source.id] = source.data
        }
        sources = documents; sourceBytes = bytes
        legacyBytes = document.pdf
        if let data = document.pdf {
            guard let pdf = Self.same(old?.legacyBytes, data) ? old?.legacy : PDFDocument(data: data),
                  !pdf.isLocked, pdf.pageCount == document.pages.count else { throw StorageError.invalidDocument }
            legacy = pdf
        } else { legacy = nil }
        legacyIndices = Dictionary(uniqueKeysWithValues: document.pages.enumerated().map { ($0.element.id, $0.offset) })
        if document.pdfSources == nil, document.pdf == nil,
           (document.pages.count != 1 || document.pages[0].geometry != nil) { throw StorageError.invalidDocument }
        // Geometries of documents this catalogue keeps; others are dropped.
        if let old {
            let kept = Set((Array(documents.values) + [legacy].compactMap { $0 }).map(ObjectIdentifier.init))
            geometries = old.geometries.filter { kept.contains($0.key) }
        }
        for page in document.pages + (document.deletedPages ?? []).map(\.page) {
            let located = locate(page)
            let sourceGeometry: PDFPageGeometry?
            if let (pdf, index) = located { sourceGeometry = try geometry(of: pdf, at: index) } else { sourceGeometry = nil }
            if page.pdfReference != nil || document.pdf != nil {
                guard sourceGeometry != nil else { throw StorageError.invalidDocument }
            }
            // Same rule as PageLayout(page:source:), from the cached boxes.
            let resolved = sourceGeometry ?? page.geometry ?? .testPaper
            if let stored = page.geometry, stored != resolved { throw StorageError.invalidDocument }
        }
        let identity = ([legacy].compactMap { $0 } + (document.pdfSources ?? []).compactMap { documents[$0.id] }).map(ObjectIdentifier.init)
        let raw = old?.rawOutline.flatMap { $0.identity == identity ? $0 : nil } ?? Self.readOutline(document, sources: documents, legacy: legacy, identity: identity)
        rawOutline = raw
        outlineWasTruncated = raw.truncated
        outlines = Self.resolve(raw, in: document)
    }

    /// Equal bytes; shared storage (the usual case after a page operation)
    /// is recognised without comparing up to 150 MB byte by byte.
    private static func same(_ old: Data?, _ new: Data) -> Bool {
        guard let old, old.count == new.count else { return false }
        let shared = old.withUnsafeBytes { a in new.withUnsafeBytes { b in a.baseAddress == b.baseAddress } }
        return shared || old == new
    }

    /// The document and zero-based page index behind a page, if any.
    private func locate(_ page: Page) -> (PDFDocument, Int)? {
        if let ref = page.pdfReference {
            guard let pdf = sources[ref.sourceID], ref.pageIndex >= 0, ref.pageIndex < pdf.pageCount else { return nil }
            return (pdf, ref.pageIndex)
        }
        if let index = legacyIndices[page.id], let legacy, index < legacy.pageCount { return (legacy, index) }
        return nil
    }

    /// The page's boxes through the document's CGPDFDocument (the pages
    /// PDFPage.pageRef returns); nil when the page cannot be read.
    private func geometry(of pdf: PDFDocument, at index: Int) throws -> PDFPageGeometry? {
        let id = ObjectIdentifier(pdf)
        if let cached = geometries[id]?[index] { return cached }
        guard let page = pdf.documentRef?.page(at: index + 1) ?? pdf.page(at: index)?.pageRef else { return nil }
        let value = try PDFPageGeometry(page)
        geometries[id, default: [:]][index] = value
        return value
    }

    private static func readOutline(_ document: Notebook, sources: [UUID: PDFDocument], legacy: PDFDocument?,
                                    identity: [ObjectIdentifier]) -> RawOutline {
        var remaining = 2_048
        var truncated = false
        var visited = Set<ObjectIdentifier>()
        func branches(_ parent: PDFOutline, pdf: PDFDocument, path: String, depth: Int) -> [RawEntry] {
            guard depth <= 16, remaining > 0, visited.insert(ObjectIdentifier(parent)).inserted else {
                truncated = true; return []
            }
            var rows: [RawEntry] = []
            for index in 0..<parent.numberOfChildren {
                guard remaining > 0 else { truncated = true; break }
                guard let child = parent.child(at: index) else { continue }
                remaining -= 1
                let key = "\(path)/\(index)"
                let destination = child.destination ?? (child.action as? PDFActionGoTo)?.destination
                let position = destination?.page.map { pdf.index(for: $0) }
                let children = branches(child, pdf: pdf, path: key, depth: depth + 1)
                rows.append(RawEntry(key: key, title: String((child.label ?? "Eintrag").prefix(180)), position: position, children: children))
            }
            return rows
        }
        var groups: [RawGroup] = []
        if let legacy, let root = legacy.outlineRoot {
            groups = [RawGroup(groupID: nil, groupTitle: "", sourceID: nil, rows: branches(root, pdf: legacy, path: "legacy", depth: 0))]
        } else {
            let all = document.pdfSources ?? []
            for (index, source) in all.enumerated() {
                guard let pdf = sources[source.id], let root = pdf.outlineRoot else { continue }
                let rows = branches(root, pdf: pdf, path: source.id.uuidString, depth: 0)
                if all.count == 1 { groups.append(RawGroup(groupID: nil, groupTitle: "", sourceID: source.id, rows: rows)) }
                else if !rows.isEmpty {
                    groups.append(RawGroup(groupID: source.id.uuidString, groupTitle: "PDF \(index + 1)", sourceID: source.id, rows: rows))
                }
            }
        }
        return RawOutline(identity: identity, groups: groups, truncated: truncated)
    }

    /// Page IDs for the outline: one dictionary per notebook state. The first
    /// page showing a source page wins, as before.
    private static func resolve(_ raw: RawOutline, in document: Notebook) -> [NotebookOutlineItem] {
        var byReference: [PDFPageReference: UUID] = [:]
        for page in document.pages {
            if let ref = page.pdfReference, byReference[ref] == nil { byReference[ref] = page.id }
        }
        func items(_ rows: [RawEntry], sourceID: UUID?) -> [NotebookOutlineItem] {
            rows.map { row in
                var pageID: UUID?
                if let position = row.position {
                    if let sourceID { pageID = byReference[PDFPageReference(sourceID: sourceID, pageIndex: position)] }
                    else if document.pages.indices.contains(position) { pageID = document.pages[position].id }
                }
                let children = items(row.children, sourceID: sourceID)
                return NotebookOutlineItem(id: row.key, title: row.title, pageID: pageID, children: children.isEmpty ? nil : children)
            }
        }
        var result: [NotebookOutlineItem] = []
        for group in raw.groups {
            let rows = items(group.rows, sourceID: group.sourceID)
            if let groupID = group.groupID {
                result.append(NotebookOutlineItem(id: groupID, title: group.groupTitle, pageID: nil, children: rows))
            } else { result.append(contentsOf: rows) }
        }
        return result
    }

    func sourcePage(for page: Page) -> PDFPage? {
        if let ref = page.pdfReference { return sources[ref.sourceID]?.page(at: ref.pageIndex) }
        if let index = legacyIndices[page.id] { return legacy?.page(at: index) }
        return nil
    }

    var outline: [NotebookOutlineItem] { outlines }
}

/// The check every PDF import passes, with a reason the user can act on.
/// CoreGraphics only: PDFKit stays on the main actor, this runs off it.
enum PDFImportCheck {
    nonisolated static func pages(of data: Data) throws -> (data: Data, geometries: [PDFPageGeometry]) {
        guard let provider = CGDataProvider(data: data as CFData), let pdf = CGPDFDocument(provider) else { throw StorageError.unreadablePDF }
        guard pdf.isUnlocked || pdf.unlockWithPassword("") else { throw StorageError.lockedPDF }
        guard pdf.numberOfPages > 0 else { throw StorageError.unreadablePDF }
        guard pdf.numberOfPages <= 500 else { throw StorageError.tooManyPDFPages(pdf.numberOfPages) }
        let geometries = try (1...pdf.numberOfPages).map { number in
            guard let page = pdf.page(at: number) else { throw StorageError.unreadablePDF }
            return try PDFPageGeometry(page)
        }
        return (data, geometries)
    }
}
