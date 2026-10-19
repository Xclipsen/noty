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

/// One worksheet; each PDF page has its own PencilKit drawing and fixed text box.
public struct Notebook: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 9
    // Existing callers retain the legacy representation until a structural edit.
    public var schemaVersion: Int = 2
    public var id: UUID = UUID()
    public var title: String = "Testheft"
    public var pdf: Data?
    public var pages: [Page] = [Page()]
    public var pdfSources: [PDFSource]?
    public var deletedPages: [DeletedPage]?
    public var appearance: NotebookAppearance?
    public init() {}

    public static func decode(_ data: Data) throws -> Notebook {
        struct Header: Decodable { var schemaVersion: Int }
        let version = try JSONDecoder().decode(Header.self, from: data).schemaVersion
        guard (1...currentSchemaVersion).contains(version) else { throw StorageError.unsupportedSchema(version) }
        let notebook = try JSONDecoder().decode(Self.self, from: data)
        try notebook.validate()
        return notebook
    }

    public func validate() throws {
        guard (1...Self.currentSchemaVersion).contains(schemaVersion) else { throw StorageError.unsupportedSchema(schemaVersion) }
        let deleted = deletedPages ?? []
        let allPages = pages + deleted.map(\.page)
        if let appearance {
            guard schemaVersion >= 7 else { throw StorageError.invalidDocument }
            try appearance.validate()
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
              Set(allImages.map(\.id)).isDisjoint(with: Set(allTextBoxes.map(\.id))),
              allImages.reduce(0, { $0 + $1.data.count }) <= 40_000_000 else { throw StorageError.invalidDocument }
        guard !pages.isEmpty,
              pages.count <= 500, deleted.count <= 500,
              Set(allPages.map(\.id)).count == allPages.count else { throw StorageError.invalidDocument }
        for page in allPages {
            if let shapes = page.shapes {
                guard schemaVersion >= 6, shapes.count <= 500 else { throw StorageError.invalidDocument }
                for shape in shapes {
                    try shape.validate()
                    guard page.textBounds.contains(shape.bounds, tolerance: 0.02) else { throw StorageError.invalidDocument }
                }
            }
            if let images = page.images {
                guard schemaVersion >= 5, images.count <= 50 else { throw StorageError.invalidDocument }
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
              sources.allSatisfy({ !$0.data.isEmpty && $0.data.count <= 20_000_000 && (1...500).contains($0.pageCount) }),
              sources.reduce(0, { $0 + $1.data.count }) <= 100_000_000 else { throw StorageError.invalidDocument }
        let lookup = Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0.pageCount) })
        for page in allPages {
            if let reference = page.pdfReference {
                guard page.paper == nil, let count = lookup[reference.sourceID],
                      page.paperColor == nil, (0..<count).contains(reference.pageIndex) else { throw StorageError.invalidDocument }
            } else {
                guard page.margins == nil, let style = page.paper,
                      style == .legacyTest ? page.geometry == nil : (schemaVersion >= 7 ? page.geometry != nil : page.geometry == PaperStyle.geometry) else {
                    throw StorageError.invalidDocument
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

/// Confined to NotebookRepository in the app; no concurrent writers.
/// Both files contain complete snapshots, including the original PDF.
public final class NotebookStore {
    public let directory: URL
    private var lastGood: Data?
    private var lastGoodDocument: Notebook?
    public private(set) var recovered = false

    public init(directory: URL) { self.directory = directory }
    private var primary: URL { directory.appendingPathComponent("notebook.json") }
    private var recovery: URL { directory.appendingPathComponent("recovery.json") }

    public func load() throws -> Notebook {
        recovered = false
        for url in [primary, recovery] {
            if let data = try? Data(contentsOf: url) {
                do {
                    let notebook = try Notebook.decode(data)
                    lastGood = data
                    lastGoodDocument = notebook
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
        return Notebook()
    }

    public func save(_ notebook: Notebook) throws {
        // A background flush of unchanged content must not rotate away history.
        if !recovered, lastGoodDocument == notebook,
           FileManager.default.fileExists(atPath: primary.path) { return }
        let data = try JSONEncoder().encode(notebook)
        _ = try Notebook.decode(data)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let old = lastGoodDocument, old.schemaVersion < notebook.schemaVersion, let lastGood {
            let archive = directory.appendingPathComponent("Migrations/\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
            // A failed archive write aborts the upgrade before changing either snapshot.
            try lastGood.write(to: archive.appendingPathComponent("notebook-v\(old.schemaVersion).json"), options: .atomic)
        }
        // Rotate only previously decoded good bytes, never a corrupt primary file.
        try (lastGood ?? data).write(to: recovery, options: .atomic)
        try data.write(to: primary, options: .atomic)
        lastGood = data
        lastGoodDocument = notebook
        recovered = false
    }
}
