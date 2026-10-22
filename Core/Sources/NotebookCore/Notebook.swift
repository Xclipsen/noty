import Foundation

public struct Page: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID = UUID()
    public var drawing: Data = Data()
    public var text: String = ""
    public var textBoxes: [TextBox]?
    public var images: [ImageObject]?
    public var shapes: [ShapeObject]?
    /// nil preserves the original fixed-A4 coordinate system without moving ink.
    public var geometry: PDFPageGeometry?
    public var pdfReference: PDFPageReference?
    public var paper: PaperStyle?
    public var paperColor: PaperColor?
    public var bookmarked: Bool?
    public var margins: PageMargins?
    public init() {}
}

/// What a library document is (Textneubau Stufe 3, docs/TEXT-REBUILD-62.md §4).
/// Stored only as `textDocument` (schema 15); a missing `kind` is a notebook,
/// so notebooks stay byte-identical in their former schema.
public enum DocumentKind: String, Codable, CaseIterable, Sendable {
    case notebook, textDocument
}

/// One worksheet; each PDF page has its own PencilKit drawing and fixed text box.
public struct Notebook: Codable, Equatable, Sendable {
    /// 10: PDF sources above 20 MB (Build 46 rejects them as invalid and would
    /// fall back to an older revision; schema 10 makes it refuse the notebook).
    /// 11: writing space beside paper pages (right/below, in the page's own paper).
    /// 12: image originals as package assets (`ImageObject.asset`), no longer
    /// embedded; notebooks with images are raised to 12 in memory on load.
    /// 13: polyline/polygon shapes (`ShapeObject.points`, kind `polygon`);
    /// older builds would draw them as straight lines, so they refuse them.
    /// 14: free text fields only (Textneubau): rotation, automatic width and
    /// page text migrated to fields (`flowRegion` without `flowID`).
    /// 15: text documents (`kind == .textDocument`): one text flow over paper
    /// pages, handwriting and objects fixed on their page. Notebooks are never
    /// raised to 15; older builds refuse text documents instead of showing
    /// them as notebooks.
    public static let currentSchemaVersion = 15
    /// Lowest schema of a text document.
    public static let textDocumentSchemaVersion = 15
    /// Lowest schema whose image objects reference assets instead of embedding.
    public static let imageAssetSchemaVersion = 12
    // Existing callers retain the legacy representation until a structural edit.
    public var schemaVersion: Int = 2
    public var id: UUID = UUID()
    public var title: String = "Testheft"
    public var pdf: Data?
    public var pages: [Page] = [Page()]
    public var pdfSources: [PDFSource]?
    public var deletedPages: [DeletedPage]?
    public var appearance: NotebookAppearance?
    /// nil: a notebook (Heft). `.textDocument` only from schema 15.
    public var kind: DocumentKind?
    public init() {}

    public var documentKind: DocumentKind { kind ?? .notebook }
    public var isTextDocument: Bool { kind == .textDocument }

    /// Validated notebook as it lives in memory (images of schema 5–11 raised
    /// to 12). Embedded legacy bytes are dropped: only for pure checks. Paths
    /// that keep or copy a notebook use `NotebookDecoding.decode`.
    public static func decode(_ data: Data) throws -> Notebook {
        try NotebookDecoding.decode(data).notebook
    }

    /// The in-memory rules: non-empty image layers need schema 12.
    public func validate() throws { try validate(legacyImages: false) }

    /// `legacyImages`: the stored form of schema 5–11, whose image layers
    /// embedded their originals (checked while decoding, ≤ 40 MB per object).
    func validate(legacyImages: Bool) throws {
        guard (1...Self.currentSchemaVersion).contains(schemaVersion) else { throw StorageError.unsupportedSchema(schemaVersion) }
        let deleted = deletedPages ?? []
        let allPages = pages + deleted.map(\.page)
        if let appearance {
            guard schemaVersion >= 7 else { throw StorageError.invalidDocument }
            try appearance.validate()
        }
        if let kind {
            // Notebooks never store a kind; text documents need schema 15.
            guard kind == .textDocument, schemaVersion >= Self.textDocumentSchemaVersion else { throw StorageError.invalidDocument }
            try validateTextDocument()
        }
        let allTextBoxes = allPages.flatMap { $0.textBoxes ?? [] }
        guard Set(allTextBoxes.map(\.id)).count == allTextBoxes.count else { throw StorageError.invalidDocument }
        let allImages = allPages.flatMap { $0.images ?? [] }
        let shapeIDs = allPages.flatMap { ($0.shapes ?? []).map(\.id) }
        let otherIDs = allTextBoxes.map(\.id) + allImages.map(\.id)
        guard Set(shapeIDs).count == shapeIDs.count, Set(shapeIDs).isDisjoint(with: Set(otherIDs)) else {
            throw StorageError.invalidDocument
        }
        guard Set(allImages.map(\.id)).count == allImages.count,
              Set(allImages.map(\.id)).isDisjoint(with: Set(allTextBoxes.map(\.id))) else { throw StorageError.invalidDocument }
        try Self.validateImageAssets(allImages)
        guard !pages.isEmpty,
              pages.count <= 500, deleted.count <= 500,
              Set(allPages.map(\.id)).count == allPages.count else { throw StorageError.invalidDocument }
        for page in allPages {
            if let shapes = page.shapes {
                guard schemaVersion >= 6, shapes.count <= 500 else { throw StorageError.invalidDocument }
                for shape in shapes {
                    if shape.usesVertexFormat { guard schemaVersion >= ShapeObject.vertexSchemaVersion else { throw StorageError.invalidDocument } }
                    try shape.validate()
                    guard page.textBounds.contains(shape.bounds, tolerance: 0.02) else { throw StorageError.invalidDocument }
                }
            }
            if let images = page.images {
                guard schemaVersion >= 5, images.count <= ImageLimits.maximumImagesPerPage,
                      legacyImages || images.isEmpty || schemaVersion >= Self.imageAssetSchemaVersion else {
                    throw StorageError.invalidDocument
                }
                for image in images {
                    try image.validate()
                    guard image.fits(in: page.textBounds) else { throw StorageError.invalidDocument }
                }
            }
            if let boxes = page.textBoxes {
                guard schemaVersion >= 4, page.text.isEmpty, boxes.count <= 200 else { throw StorageError.invalidDocument }
                let flows = boxes.compactMap(\.flowID)
                guard Set(flows).count == flows.count else { throw StorageError.invalidDocument }
                for box in boxes {
                    if box.usesTextFlowFormat { guard schemaVersion >= 8 else { throw StorageError.invalidDocument } }
                    if box.usesRichText { guard schemaVersion >= 7 else { throw StorageError.invalidDocument } }
                    if box.usesColorFormat { guard schemaVersion >= 9 else { throw StorageError.invalidDocument } }
                    if box.usesFieldFormat { guard schemaVersion >= TextBox.fieldSchemaVersion else { throw StorageError.invalidDocument } }
                    try box.validate()
                }
            }
            if let geometry = page.geometry {
                guard schemaVersion >= 2 else { throw StorageError.invalidDocument }
                try geometry.validate()
            }
        }
        guard let sources = pdfSources else {
            guard deletedPages == nil, allPages.allSatisfy({ $0.pdfReference == nil && $0.paper == nil
                && $0.paperColor == nil && $0.bookmarked == nil && $0.margins == nil }) else {
                throw StorageError.invalidDocument
            }
            return
        }
        guard schemaVersion >= 3, pdf == nil, sources.count <= 500,
              Set(sources.map(\.id)).count == sources.count,
              sources.allSatisfy({ !$0.data.isEmpty && $0.data.count <= PDFSource.maximumBytes && (1...500).contains($0.pageCount) }),
              sources.reduce(0, { $0 + $1.data.count }) <= PDFSource.maximumTotalBytes else { throw StorageError.invalidDocument }
        if sources.contains(where: { $0.data.count > PDFSource.legacyMaximumBytes }) {
            guard schemaVersion >= 10 else { throw StorageError.invalidDocument }
        }
        let lookup = Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0.pageCount) })
        for page in allPages {
            if let reference = page.pdfReference {
                guard page.paper == nil, let count = lookup[reference.sourceID],
                      page.paperColor == nil, (0..<count).contains(reference.pageIndex) else { throw StorageError.invalidDocument }
            } else {
                guard let style = page.paper,
                      style == .legacyTest ? page.geometry == nil : (schemaVersion >= 7 ? page.geometry != nil : page.geometry == PaperStyle.geometry) else {
                    throw StorageError.invalidDocument
                }
                // Schema 11: a paper sheet may grow right/down; the extra space is
                // the same paper, so lines and colour continue without a seam.
                if let margins = page.margins {
                    guard schemaVersion >= 11, style != .legacyTest, margins.left == 0, margins.top == 0,
                          margins.style == style, margins.color == (page.paperColor ?? .white) else {
                        throw StorageError.invalidDocument
                    }
                }
            }
            if let margins = page.margins {
                try margins.validate()
                let size = page.geometry?.displaySize ?? .a4
                guard size.width + margins.left + margins.right <= 14_400,
                      size.height + margins.top + margins.bottom <= 14_400 else { throw StorageError.invalidDocument }
            }
        }
        for entry in deleted {
            if entry.reason == .cleared { guard schemaVersion >= 7 else { throw StorageError.invalidDocument } }
            guard entry.originalIndex >= 0, entry.originalIndex < 500,
                  entry.deletedAt.timeIntervalSince1970.isFinite,
                  entry.nextPageID != entry.page.id, entry.previousPageID != entry.page.id else {
                throw StorageError.invalidDocument
            }
        }
    }
}

extension Notebook {
    /// Every reference valid; the unique originals (each hash once, active
    /// pages and page trash) at most 500 MB; objects sharing a hash agree on
    /// byte count and pixel size, so each original is checked once.
    static func validateImageAssets(_ images: [ImageObject]) throws {
        var seen: [String: ImageObject] = [:]
        var total = 0
        for image in images {
            guard image.asset.isValid else { throw StorageError.invalidDocument }
            if let first = seen[image.asset.sha256] {
                guard first.asset.byteCount == image.asset.byteCount, first.pixelWidth == image.pixelWidth,
                      first.pixelHeight == image.pixelHeight else { throw StorageError.invalidDocument }
                continue
            }
            seen[image.asset.sha256] = image
            total += image.asset.byteCount
            guard total <= ImageLimits.maximumNotebookBytes else { throw StorageError.invalidDocument }
        }
    }
}

public enum StorageError: Error, LocalizedError {
    case invalidDocument
    case unreadableCopies
    case unsupportedSchema(Int)

    public var errorDescription: String? {
        switch self {
        case .invalidDocument: "Die Datei enthält kein unterstütztes noty-Dokument."
        case .unreadableCopies: "Arbeitsstand und Wiederherstellungskopie sind nicht lesbar."
        case .unsupportedSchema(let version): "Dokumentformat \(version) wird von dieser noty-Version nicht unterstützt."
        }
    }
}

/// Read-only access to the prototype files (notebook.json, recovery.json),
/// used once by RevisionStore to migrate them; both are complete snapshots,
/// including the original PDF. They are never written or changed again.
public final class NotebookStore {
    public let directory: URL
    public private(set) var recovered = false

    public init(directory: URL) { self.directory = directory }
    private var primary: URL { directory.appendingPathComponent("notebook.json") }
    private var recovery: URL { directory.appendingPathComponent("recovery.json") }

    public func load() throws -> Notebook { try loadDecoded().notebook }

    /// Like `load`, with embedded legacy image bytes (if any).
    func loadDecoded() throws -> DecodedNotebook {
        recovered = false
        for url in [primary, recovery] {
            if let data = try? Data(contentsOf: url) {
                do {
                    let notebook = try NotebookDecoding.decode(data)
                    recovered = url == recovery
                    return notebook
                } catch StorageError.unsupportedSchema(let version) {
                    // An older app must not fall back and overwrite a newer format.
                    throw StorageError.unsupportedSchema(version)
                } catch { continue }
            }
        }
        // Never replace unreadable existing data with an empty notebook.
        let fm = FileManager.default
        guard !fm.fileExists(atPath: primary.path),
              !fm.fileExists(atPath: recovery.path) else { throw StorageError.unreadableCopies }
        let empty = Notebook()
        return DecodedNotebook(notebook: empty, storedSchemaVersion: empty.schemaVersion, inlineImageBytes: [:])
    }
}
