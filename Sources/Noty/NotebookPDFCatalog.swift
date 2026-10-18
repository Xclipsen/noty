import PDFKit
import PencilKit
import NotebookCore

/// Only the main actor owns PDFKit objects. Page order never mutates source PDFs.
@MainActor
final class NotebookPDFCatalog {
    private let sources: [UUID: PDFDocument]
    private let sourceBytes: [UUID: Data]
    private let legacy: PDFDocument?
    private let legacyBytes: Data?
    private let legacyIndices: [UUID: Int]
    private var outlines: [NotebookOutlineItem] = []
    private(set) var outlineWasTruncated = false

    init(_ document: Notebook, reusing old: NotebookPDFCatalog? = nil) throws {
        try document.validate()
        var documents: [UUID: PDFDocument] = [:]
        var bytes: [UUID: Data] = [:]
        for source in document.pdfSources ?? [] {
            let pdf: PDFDocument
            if old?.sourceBytes[source.id] == source.data, let cached = old?.sources[source.id] { pdf = cached }
            else if old?.legacyBytes == source.data, let cached = old?.legacy { pdf = cached }
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
            guard let pdf = old?.legacyBytes == data ? old?.legacy : PDFDocument(data: data),
                  !pdf.isLocked, pdf.pageCount == document.pages.count else { throw StorageError.invalidDocument }
            legacy = pdf
        } else { legacy = nil }
        legacyIndices = Dictionary(uniqueKeysWithValues: document.pages.enumerated().map { ($0.element.id, $0.offset) })
        if document.pdfSources == nil, document.pdf == nil,
           (document.pages.count != 1 || document.pages[0].geometry != nil) { throw StorageError.invalidDocument }
        for page in document.pages + (document.deletedPages ?? []).map(\.page) {
            let source = sourcePage(for: page)
            if page.pdfReference != nil || document.pdf != nil {
                guard source?.pageRef != nil else { throw StorageError.invalidDocument }
            }
            _ = try PageLayout(page: page, source: source?.pageRef)
        }
        var remaining = 2_048
        var visited = Set<ObjectIdentifier>()
        func branches(_ parent: PDFOutline, pdf: PDFDocument, sourceID: UUID?, path: String, depth: Int) -> [NotebookOutlineItem] {
            guard depth <= 16, remaining > 0, visited.insert(ObjectIdentifier(parent)).inserted else {
                outlineWasTruncated = true; return []
            }
            var rows: [NotebookOutlineItem] = []
            for index in 0..<parent.numberOfChildren {
                guard remaining > 0 else { outlineWasTruncated = true; break }
                guard let child = parent.child(at: index) else { continue }
                remaining -= 1
                let key = "\(path)/\(index)"
                var pageID: UUID?
                let destination = child.destination ?? (child.action as? PDFActionGoTo)?.destination
                if let target = destination?.page {
                    let position = pdf.index(for: target)
                    if let sourceID {
                        pageID = document.pages.first { $0.pdfReference == PDFPageReference(sourceID: sourceID, pageIndex: position) }?.id
                    } else if document.pages.indices.contains(position) { pageID = document.pages[position].id }
                }
                let children = branches(child, pdf: pdf, sourceID: sourceID, path: key, depth: depth + 1)
                rows.append(NotebookOutlineItem(id: key, title: String((child.label ?? "Eintrag").prefix(180)),
                    pageID: pageID, children: children.isEmpty ? nil : children))
            }
            return rows
        }
        if let legacy, let root = legacy.outlineRoot {
            outlines = branches(root, pdf: legacy, sourceID: nil, path: "legacy", depth: 0)
        } else {
            for (index, source) in (document.pdfSources ?? []).enumerated() {
                guard let pdf = sources[source.id], let root = pdf.outlineRoot else { continue }
                let rows = branches(root, pdf: pdf, sourceID: source.id, path: source.id.uuidString, depth: 0)
                if (document.pdfSources?.count ?? 0) == 1 { outlines.append(contentsOf: rows) }
                else if !rows.isEmpty {
                    outlines.append(NotebookOutlineItem(id: source.id.uuidString, title: "PDF \(index + 1)", pageID: nil, children: rows))
                }
            }
        }
    }

    func sourcePage(for page: Page) -> PDFPage? {
        if let ref = page.pdfReference { return sources[ref.sourceID]?.page(at: ref.pageIndex) }
        if let index = legacyIndices[page.id] { return legacy?.page(at: index) }
        return nil
    }

    var outline: [NotebookOutlineItem] { outlines }
}
