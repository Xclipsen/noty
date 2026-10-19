import Foundation

public enum TextFont: String, Codable, CaseIterable, Sendable { case system, serif, monospaced }
public enum TextColor: String, Codable, CaseIterable, Sendable { case black, white, blue, red }

public enum TextAlignment: String, Codable, CaseIterable, Sendable { case left, center, right, justified }
/// Marker colours for highlighted text (schema 9). nil keeps the original yellow.
public enum HighlightColor: String, Codable, CaseIterable, Sendable { case yellow, green, blue, pink, orange, purple }

public struct TextBoxStyle: Codable, Equatable, Sendable {
    public var font: TextFont
    public var fontSize: Double
    public var bold: Bool
    public var italic: Bool
    public var underline: Bool
    public var color: TextColor
    public var highlighted: Bool?
    public var alignment: TextAlignment?
    public var indent: Double?
    public var link: String?
    public var fontName: String?
    public var ink: InkColor?
    public var strikethrough: Bool?
    /// -1 subscript, 0 normal, 1 superscript.
    public var baseline: Int?
    /// Schema 9: black/white follows the background like the automatic pen;
    /// `color` keeps the last resolved value, `ink` stays nil.
    public var automaticColor: Bool?
    public var highlightColor: HighlightColor?
    public init(font: TextFont = .system, fontSize: Double = 17, bold: Bool = false,
                italic: Bool = false, underline: Bool = false, color: TextColor = .black) {
        self.font = font; self.fontSize = fontSize; self.bold = bold; self.italic = italic
        self.underline = underline; self.color = color
    }
    public var usesExtendedStyle: Bool { fontName != nil || ink != nil || strikethrough != nil || baseline != nil }
    public var usesColorFormat: Bool { automaticColor != nil || highlightColor != nil }
    public func validate() throws {
        guard fontName == nil || (!fontName!.isEmpty && fontName!.utf8.count <= 200),
              baseline == nil || (-1...1).contains(baseline!),
              automaticColor != true || (ink == nil && (color == .black || color == .white)) else { throw StorageError.invalidDocument }
        if let ink { try ink.validate() }
        guard fontSize.isFinite, (8...96).contains(fontSize),
              indent == nil || (indent!.isFinite && (0...240).contains(indent!)),
              link == nil || (link!.utf8.count <= 2048 && URL(string: link!)?.scheme.map({ ["https", "http", "mailto"].contains($0.lowercased()) }) == true)
        else { throw StorageError.invalidDocument }
    }
}

/// Nonoverlapping UTF-16 ranges, matching native UITextView selections.
public struct TextRun: Codable, Equatable, Sendable {
    public var location: Int
    public var length: Int
    public var style: TextBoxStyle
    public init(location: Int, length: Int, style: TextBoxStyle) {
        self.location = location; self.length = length; self.style = style
    }
}

/// Text content rectangle in canonical page points, zero native text insets.
/// Negative x/y address the extra PDF writing area to the left/above.
public struct TextBox: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public var text: String
    public var style: TextBoxStyle
    public var runs: [TextRun]?
    public var flowID: UUID?
    public var flowRegion: TextFlowRegion?
    public init(id: UUID = UUID(), x: Double = 40, y: Double = 40, width: Double = 220,
                height: Double = 28, text: String = "", style: TextBoxStyle = TextBoxStyle()) {
        self.id = id; self.x = x; self.y = y; self.width = width; self.height = height
        self.text = text; self.style = style
    }
    public var rect: PageRect { PageRect(x: x, y: y, width: width, height: height) }
    public var usesTextFlowFormat: Bool { flowID != nil || style.usesExtendedStyle || (runs ?? []).contains { $0.style.usesExtendedStyle } }
    public var usesColorFormat: Bool { style.usesColorFormat || (runs ?? []).contains { $0.style.usesColorFormat } }
    public var usesRichText: Bool {
        runs != nil || style.highlighted != nil || style.alignment != nil || style.indent != nil || style.link != nil
    }
    public func validate() throws {
        guard [x, y, width, height, style.fontSize].allSatisfy(\.isFinite),
              abs(x) <= 14_400, abs(y) <= 14_400, (1...14_400).contains(width),
              (1...14_400).contains(height), (8...96).contains(style.fontSize),
              text.utf8.count <= 1_000_000 else { throw StorageError.invalidDocument }
        guard (flowID == nil) == (flowRegion == nil) else { throw StorageError.invalidDocument }
        try style.validate()
        let units = Array(text.utf16)
        func boundary(_ i: Int) -> Bool {
            i == 0 || i == units.count || !(0xDC00...0xDFFF).contains(units[i])
        }
        var end = 0
        guard (runs?.count ?? 0) <= 50_000 else { throw StorageError.invalidDocument }
        for run in runs ?? [] {
            guard run.location >= end, run.location <= units.count, run.length > 0,
                  run.length <= units.count - run.location,
                  boundary(run.location), boundary(run.location + run.length) else { throw StorageError.invalidDocument }
            try run.style.validate(); end = run.location + run.length
        }
    }
}

extension Page {
    public func independentCopy() -> Page {
        var copy = self; copy.id = UUID()
        copy.textBoxes = textBoxes?.map { box in var copy = box; copy.id = UUID(); if copy.flowID != nil { copy.flowID = UUID() }; return copy }
        copy.images = images?.map { image in var copy = image; copy.id = UUID(); return copy }
        copy.shapes = shapes?.map { shape in var copy = shape; copy.id = UUID(); return copy }
        return copy
    }
    /// A legacy field is represented at exactly its former glyph origin without
    /// writing a migration just because the document was opened.
    public var effectiveTextBoxes: [TextBox] {
        if let textBoxes { return textBoxes }
        guard !text.isEmpty else { return [] }
        let size = geometry?.displaySize ?? .a4
        let inset = geometry == nil ? 5.0 : 8.0
        return [TextBox(id: id, x: size.width * 48 / 595 + inset,
            y: size.height * 625 / 842 + 8, width: size.width * 499 / 595 - 2 * inset,
            height: size.height * 169 / 842 - 16, text: text,
            style: TextBoxStyle(color: paperColor == .dark ? .white : .black))]
    }
    public var searchableText: String { effectiveTextBoxes.map(\.text).joined(separator: "\n") }
    public var textBounds: PageRect {
        let size = geometry?.displaySize ?? .a4
        return PageRect(x: -(margins?.left ?? 0), y: -(margins?.top ?? 0),
            width: size.width + (margins?.left ?? 0) + (margins?.right ?? 0),
            height: size.height + (margins?.top ?? 0) + (margins?.bottom ?? 0))
    }
}

extension Notebook {
    /// Every text write path calls this; it only ever raises the schema.
    public mutating func raiseSchemaForTextColors(_ boxes: [TextBox]) {
        if boxes.contains(where: \.usesColorFormat) { schemaVersion = max(9, schemaVersion) }
    }
    public func preparedForTextEditing() throws -> Notebook {
        var next = try preparedForPageEditing()
        next.schemaVersion = max(4, next.schemaVersion)
        for index in next.pages.indices {
            next.pages[index].textBoxes = next.pages[index].effectiveTextBoxes
            next.pages[index].text = ""
        }
        for index in next.deletedPages?.indices ?? 0..<0 {
            var entry = next.deletedPages![index]
            var page = entry.page
            page.textBoxes = page.effectiveTextBoxes; page.text = ""
            entry = DeletedPage(page: page, originalIndex: entry.originalIndex, deletedAt: entry.deletedAt,
                nextPageID: entry.nextPageID, previousPageID: entry.previousPageID, reason: entry.reason)
            next.deletedPages![index] = entry
        }
        try next.validate()
        return next
    }

    public mutating func replaceTextBoxes(_ boxes: [TextBox], pageID: UUID) throws {
        var next = try preparedForTextEditing()
        if boxes.contains(where: \.usesTextFlowFormat) { next.schemaVersion = max(8, next.schemaVersion) }
        if boxes.contains(where: \.usesRichText) { next.schemaVersion = max(7, next.schemaVersion) }
        next.raiseSchemaForTextColors(boxes)
        guard let index = next.pages.firstIndex(where: { $0.id == pageID }) else { throw PageOperationError.missingPage }
        let bounds = next.pages[index].textBounds
        for box in boxes {
            try box.validate()
            guard box.x >= bounds.x - 0.01, box.y >= bounds.y - 0.01,
                  box.x + box.width <= bounds.x + bounds.width + 0.01,
                  box.y + box.height <= bounds.y + bounds.height + 0.01 else { throw StorageError.invalidDocument }
        }
        next.pages[index].textBoxes = boxes
        try next.validate(); self = next
    }
}
