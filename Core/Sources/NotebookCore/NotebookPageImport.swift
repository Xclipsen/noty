import Foundation

/// Pages of another notebook (a checked `.noty` file) as pages of this one
/// (docs/STORAGE.md, „Seiten aus .noty einfügen“). The file's notebook is never
/// opened or stored itself: its active pages are copied with new page and
/// object IDs, its PDF originals with new source IDs (an identical original
/// already in this notebook is reused), its image originals by hash. Page
/// trash, title, cover and appearance of the file stay out.
public enum PageImportError: Error, LocalizedError, Equatable {
    /// Text documents keep one text flow across their pages; it cannot be split.
    case textDocument
    /// The image originals of both together exceed the notebook limit.
    case imagesFull(used: Int, adding: Int)

    public var errorDescription: String? {
        switch self {
        case .textDocument:
            "Textdokumente lassen sich nicht als Seiten einfügen, und in ein Textdokument lassen sich keine Heftseiten einfügen."
        case .imagesFull(let used, let adding):
            "Die Bilder der Datei (\(ImageLimits.megabytes(adding))) passen nicht mehr in dieses Heft: Es enthält schon \(ImageLimits.megabytes(used)) Bilder, höchstens \(ImageLimits.megabytes(ImageLimits.maximumNotebookBytes)) sind möglich."
        }
    }
}

public struct PageImportResult: Equatable, Sendable {
    /// The new pages in their order.
    public let pageIDs: [UUID]
    /// Image originals the new pages reference that this notebook did not
    /// hold before: they must be staged in the package's asset store before
    /// the next commit (sorted by hash).
    public let newAssets: [ImageAssetReference]
}

extension Notebook {
    /// Inserts copies of all active pages of `source` at `index`. All or
    /// nothing: on any error this notebook is unchanged.
    @discardableResult
    public mutating func insertPages(of source: Notebook, at index: Int) throws -> PageImportResult {
        guard !isTextDocument, !source.isTextDocument else { throw PageImportError.textDocument }
        try source.validate()
        // Legacy forms of the file (one embedded PDF, page text, text flow)
        // become today's in-memory forms first; nothing of the file is stored.
        let incoming = try source.migratedTextFlow().preparedForTextEditing()
        var next = try preparedForPageEditing()
        guard next.pages.count + incoming.pages.count <= 500 else { throw PageOperationError.pageLimit }
        guard (0...next.pages.count).contains(index) else { throw PageOperationError.invalidOrder }

        // Only the originals the active pages use; identical bytes are shared.
        let used = Set(incoming.pages.compactMap { $0.pdfReference?.sourceID })
        var sources = next.pdfSources ?? []
        var sourceIDs: [UUID: UUID] = [:]
        for original in incoming.pdfSources ?? [] where used.contains(original.id) {
            if let same = sources.first(where: { $0.pageCount == original.pageCount && $0.data.count == original.data.count && $0.data == original.data }) {
                sourceIDs[original.id] = same.id
            } else {
                let copy = PDFSource(data: original.data, pageCount: original.pageCount)
                sources.append(copy)
                sourceIDs[original.id] = copy.id
            }
        }
        guard sources.count <= 500, sources.reduce(0, { $0 + $1.data.count }) <= PDFSource.maximumTotalBytes else {
            throw PageOperationError.sourceLimit
        }

        let additions = try incoming.pages.map { page -> Page in
            var copy = page.independentCopy()
            if let reference = copy.pdfReference {
                guard let id = sourceIDs[reference.sourceID] else { throw StorageError.invalidDocument }
                copy.pdfReference = PDFPageReference(sourceID: id, pageIndex: reference.pageIndex)
            }
            return copy
        }

        // Image originals by hash: one already in this notebook adds no bytes.
        let present = Set(next.allImages.map(\.asset.sha256))
        var seen = Set<String>()
        let newAssets = additions.flatMap { $0.images ?? [] }.map(\.asset)
            .filter { !present.contains($0.sha256) && seen.insert($0.sha256).inserted }
            .sorted { $0.sha256 < $1.sha256 }
        let usedBytes = next.uniqueImageAssetBytes
        let addingBytes = newAssets.reduce(0) { $0 + $1.byteCount }
        guard usedBytes + addingBytes <= ImageLimits.maximumNotebookBytes else {
            throw PageImportError.imagesFull(used: usedBytes, adding: addingBytes)
        }

        // The pages keep their formats: the notebook's schema rises to the
        // file's (never lowered, never to the text-document-only 15).
        if incoming.schemaVersion > next.schemaVersion {
            if next.schemaVersion >= TextBox.fieldSchemaVersion || incoming.schemaVersion >= TextBox.fieldSchemaVersion {
                next = try next.migratedTextFlow().preparedForTextEditing()
            }
            next.schemaVersion = max(next.schemaVersion, incoming.schemaVersion == Self.textDocumentSchemaVersion
                ? TextBox.fieldSchemaVersion : incoming.schemaVersion)
        }
        if !newAssets.isEmpty || additions.contains(where: { !($0.images ?? []).isEmpty }) {
            next.schemaVersion = max(next.schemaVersion, Self.imageAssetSchemaVersion)
        }
        next.pdfSources = sources
        next.raiseSchemaForLargeSources()
        next.pages.insert(contentsOf: additions, at: index)
        try next.validate()
        self = next
        return PageImportResult(pageIDs: additions.map(\.id), newAssets: newAssets)
    }
}
