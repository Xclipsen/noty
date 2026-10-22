import Foundation

/// Gliederung of a text document (Textneubau Stufe 4, docs/TEXT-REBUILD-62.md §4):
/// the paragraphs of its flow styled as title, heading or subheading
/// (`TextStylePreset.matching` of the paragraph's first character), in
/// reading order, each with the place to jump to. Pure and read-only; no
/// format of its own. Free fields, handwriting and objects are not part of it.
public struct TextOutlineEntry: Equatable, Identifiable, Sendable {
    /// Stable within one flow state: segment and paragraph start.
    public var id: String { "\(boxID.uuidString)-\(range.location)" }
    /// `.title`, `.heading` or `.subheading`.
    public let preset: TextStylePreset
    /// Hierarchical indentation: the number of enclosing outline levels
    /// above this entry (a heading below a title is 1, a document with only
    /// headings starts at 0).
    public let depth: Int
    /// Paragraph text without surrounding white space, shortened with „…“.
    public let text: String
    public let pageID: UUID
    public let pageIndex: Int
    /// The flow segment holding the paragraph start.
    public let boxID: UUID
    /// Paragraph content in that segment (UTF-16, without its line break; a
    /// paragraph continuing on the next page ends with the segment).
    public let range: NSRange
    /// Style of the paragraph's last character (typing continues in it).
    public let style: TextBoxStyle

    public init(preset: TextStylePreset, depth: Int, text: String, pageID: UUID, pageIndex: Int, boxID: UUID,
                range: NSRange, style: TextBoxStyle) {
        self.preset = preset; self.depth = depth; self.text = text
        self.pageID = pageID; self.pageIndex = pageIndex; self.boxID = boxID; self.range = range; self.style = style
    }

    /// Caret behind the heading text (where one continues writing), as the
    /// editor's jump to an open task or the end of the flow.
    public var focus: TextFlowFocus {
        TextFlowFocus(pageID: pageID, boxID: boxID, selection: NSRange(location: NSMaxRange(range), length: 0), typingStyle: style)
    }
}

extension TextStylePreset {
    /// Outline rank: title 0, heading 1, subheading 2; nil for body text and captions.
    public var outlineRank: Int? {
        switch self { case .title: 0; case .heading: 1; case .subheading: 2; case .body, .caption: nil }
    }
}

extension Notebook {
    /// Characters of an outline entry before it is shortened with „…“.
    public static let outlineTextLimit = 60

    /// The outline of a text document's flow; empty for notebooks.
    public var textOutline: [TextOutlineEntry] { textOutline(limit: Self.outlineTextLimit) }

    public func textOutline(limit: Int) -> [TextOutlineEntry] {
        guard isTextDocument else { return [] }
        let indices = Dictionary(pages.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
        var result: [TextOutlineEntry] = []
        var open: [Int] = [] // ranks of the enclosing entries
        // A paragraph split over two pages starts in the earlier segment only.
        var atParagraphStart = true
        for segment in textFlowSegments {
            let box = segment.box
            let text = box.text as NSString
            let length = text.length
            guard length > 0 else { continue }
            var location = 0
            while location < length {
                var start = 0, end = 0, contentsEnd = 0
                text.getParagraphStart(&start, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: location, length: 0))
                defer { location = max(end, location + 1) }
                let continuing = location == 0 && !atParagraphStart
                guard !continuing, contentsEnd > start else { continue }
                guard let rank = TextStylePreset.matching(box.style(at: start)).outlineRank,
                      let preset = TextStylePreset.allCases.first(where: { $0.outlineRank == rank }) else { continue }
                let shown = Self.outlineText(text.substring(with: NSRange(location: start, length: contentsEnd - start)), limit: limit)
                guard !shown.isEmpty, let pageIndex = indices[segment.pageID] else { continue }
                while let last = open.last, last >= rank { open.removeLast() }
                result.append(TextOutlineEntry(preset: preset, depth: open.count, text: shown, pageID: segment.pageID,
                                               pageIndex: pageIndex, boxID: box.id,
                                               range: NSRange(location: start, length: contentsEnd - start),
                                               style: box.style(at: contentsEnd - 1)))
                open.append(rank)
            }
            let last = text.character(at: length - 1)
            atParagraphStart = last == 0x0A || last == 0x0D || last == 0x2029
        }
        return result
    }

    /// White space collapsed to single spaces, at most `limit` characters
    /// (the last one replaced by „…“ when shortened).
    static func outlineText(_ raw: String, limit: Int) -> String {
        let words = raw.split(whereSeparator: { $0.isWhitespace })
        let joined = words.joined(separator: " ")
        guard limit > 1, joined.count > limit else { return joined }
        return joined.prefix(limit - 1).trimmingCharacters(in: .whitespaces) + "…"
    }
}
