import Foundation

public enum NotebookCover: String, Codable, CaseIterable, Sendable {
    case blue, purple, green, yellow, coral, gray
}

public enum PaperFormat: String, Codable, CaseIterable, Sendable {
    case a4, a5, a3, letter
    public var size: PageSize {
        switch self {
        case .a4: .init(width: 595, height: 842)
        case .a5: .init(width: 420, height: 595)
        case .a3: .init(width: 842, height: 1191)
        case .letter: .init(width: 612, height: 792)
        }
    }
}

public struct NotebookAppearance: Codable, Equatable, Sendable {
    public var coverEnabled = true
    public var cover: NotebookCover = .blue
    public var format: PaperFormat = .a4
    public var landscape = false
    public var paper: PaperStyle = .blank
    public var color: PaperColor = .white
    public init() {}
    public var geometry: PDFPageGeometry {
        let size = format.size
        let box = PageRect(x: 0, y: 0, width: landscape ? size.height : size.width,
                          height: landscape ? size.width : size.height)
        return try! PDFPageGeometry(mediaBox: box, cropBox: box, rotation: 0)
    }
    public func validate() throws {
        guard paper != .legacyTest else { throw StorageError.invalidDocument }
    }
}

extension Notebook {
    public static func blank(title: String, appearance: NotebookAppearance) throws -> Notebook {
        try appearance.validate()
        var result = blank(title: title)
        result.schemaVersion = 7; result.appearance = appearance
        result.pages[0].geometry = appearance.geometry
        result.pages[0].paper = appearance.paper; result.pages[0].paperColor = appearance.color
        try result.validate()
        return result
    }
}

extension Notebook {
    /// Recolours the serialized handwriting of one page. The closure receives
    /// each stroke's canonical render bounds and colour and asks `convert`
    /// for its replacement (nil keeps the stroke). PencilKit stays in the app;
    /// the selection rules live here. Return the original bytes when nothing changed.
    public typealias InkRecolor = (_ drawing: Data, _ convert: (_ renderBounds: PageRect, _ color: InkColor) -> InkColor?) throws -> Data

    /// Changes the paper default of an existing notebook: every new standard
    /// page and the trailing writing draft follow it. Cover and format stay.
    /// - `.newPagesOnly`: only the default.
    /// - `.emptyPages`: additionally the listed empty paper pages (ids decided by
    ///   the app, which can inspect PencilKit data).
    /// - `.wholeNotebook`: every active paper page takes the new paper style and
    ///   colour; when the colour flips, neutral ink/text/shapes swap black↔white
    ///   (`PaperInkInversion`). PDF pages keep their scan and everything over it;
    ///   their writing margins switch colour and only content lying completely
    ///   in the margins is swapped. Images and the page trash stay untouched.
    /// One validated value replacement; returns how many active pages changed.
    @discardableResult
    public mutating func setPageDefaults(paper: PaperStyle, color: PaperColor, scope: PageDefaultsScope,
                                         emptyPageIDs: Set<UUID> = [], recolorDrawing: InkRecolor? = nil) throws -> Int {
        guard paper != .legacyTest else { throw StorageError.invalidDocument }
        // Legacy virtual page text derives its colour from the paper colour and
        // therefore already follows it; it is left virtual (no materialisation).
        var next = try preparedForPageEditing()
        next.schemaVersion = max(7, next.schemaVersion)
        var appearance = next.appearance ?? next.inferredAppearance
        appearance.paper = paper; appearance.color = color
        next.appearance = appearance
        var changed = 0
        for index in next.pages.indices {
            let original = next.pages[index]
            var page = original
            switch scope {
            case .newPagesOnly:
                continue
            case .emptyPages:
                guard emptyPageIDs.contains(page.id), page.pdfReference == nil, let style = page.paper, style != .legacyTest,
                      page.margins == nil, page.effectiveTextBoxes.allSatisfy({ $0.text.isEmpty }),
                      (page.images ?? []).isEmpty, (page.shapes ?? []).isEmpty else { continue }
                if style != paper || (page.paperColor ?? .white) != color { page.paper = paper; page.paperColor = color }
            case .wholeNotebook:
                if page.pdfReference == nil {
                    // Prototype test sheets have no own paper geometry: unchanged.
                    guard let style = page.paper, style != .legacyTest else { continue }
                    if style != paper { page.paper = paper }
                    if (page.paperColor ?? .white) != color {
                        page.paperColor = color
                        try Self.invertInk(of: &page, to: color, onlyMargins: false, recolorDrawing: recolorDrawing)
                    }
                    // Writing space continues the sheet: same paper, same colour.
                    if var margins = page.margins { margins.style = paper; margins.color = color; page.margins = margins }
                } else if var margins = page.margins, margins.color != color {
                    margins.color = color; page.margins = margins
                    try Self.invertInk(of: &page, to: color, onlyMargins: true, recolorDrawing: recolorDrawing)
                }
            }
            if page != original { next.pages[index] = page; changed += 1 }
        }
        try next.validate(); self = next
        return changed
    }

    /// „Seite anpassen“: one paper page's own style and colour. Its writing
    /// space follows (same paper); a colour flip swaps neutral ink/text/shapes
    /// like `.wholeNotebook`. The notebook defaults stay unchanged.
    public mutating func setPaper(_ style: PaperStyle, color: PaperColor, pageID: UUID, recolorDrawing: InkRecolor? = nil) throws {
        guard style != .legacyTest else { throw StorageError.invalidDocument }
        var next = try preparedForPageEditing()
        guard let index = next.pages.firstIndex(where: { $0.id == pageID }), next.pages[index].writingSpaceExtendsPaper else {
            throw PageOperationError.missingPage
        }
        var page = next.pages[index]
        page.paper = style
        if (page.paperColor ?? .white) != color {
            page.paperColor = color
            try Self.invertInk(of: &page, to: color, onlyMargins: false, recolorDrawing: recolorDrawing)
        }
        if var margins = page.margins { margins.style = style; margins.color = color; page.margins = margins }
        next.pages[index] = page
        try next.validate(); self = next
    }

    /// Compatibility entry: empty listed paper pages follow, written pages stay.
    @discardableResult
    public mutating func setPageDefaults(paper: PaperStyle, color: PaperColor, alsoEmptyPages emptyPageIDs: Set<UUID> = []) throws -> Int {
        try setPageDefaults(paper: paper, color: color, scope: emptyPageIDs.isEmpty ? .newPagesOnly : .emptyPages,
                            emptyPageIDs: emptyPageIDs)
    }

    private static func invertInk(of page: inout Page, to color: PaperColor, onlyMargins: Bool,
                                  recolorDrawing: InkRecolor?) throws {
        let snapshot = page
        if !page.drawing.isEmpty {
            // Converting written pages without the app's PencilKit step would
            // leave handwriting invisible: refuse instead of half converting.
            guard let recolorDrawing else { throw StorageError.invalidDocument }
            page.drawing = try recolorDrawing(page.drawing) { bounds, ink in
                guard !onlyMargins || snapshot.liesInMargins(bounds) else { return nil }
                return PaperInkInversion.converted(ink, to: color)
            }
        }
        page.textBoxes = page.textBoxes?.map { box in
            guard !onlyMargins || snapshot.textBoxLiesInMargins(box) else { return box }
            return PaperInkInversion.converted(box, to: color)
        }
        page.shapes = page.shapes?.map { shape in
            guard !onlyMargins || snapshot.liesInMargins(shape.bounds) else { return shape }
            return PaperInkInversion.converted(shape, to: color)
        }
    }

    /// Notebooks created before appearances existed: keep the library preview
    /// (no cover), the format of the latest paper page and – like the trailing
    /// writing draft – the paper style and colour of the latest paper page.
    var inferredAppearance: NotebookAppearance {
        var value = NotebookAppearance(); value.coverEnabled = false
        if let size = pages.last(where: { $0.pdfReference == nil && $0.paper != .legacyTest })?.geometry?.displaySize {
            for format in PaperFormat.allCases {
                if format.size == size { value.format = format; value.landscape = false }
                else if format.size.width == size.height && format.size.height == size.width { value.format = format; value.landscape = true }
            }
        }
        if let latest = pages.last(where: { $0.pdfReference == nil && $0.paper != nil && $0.paper != .legacyTest }),
           let style = latest.paper {
            value.paper = style; value.color = latest.paperColor ?? .white
        }
        return value
    }

    /// The notebook's current standard page: the stored default, or for older
    /// notebooks without one the paper the trailing writing draft would get.
    /// What "Seitenstandard ändern" starts from; never `.legacyTest`.
    public var pageDefaults: NotebookAppearance { appearance ?? inferredAppearance }
}
