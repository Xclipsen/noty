import Foundation

public enum SearchContentKind: String, Codable, Sendable { case text, pdf, image, handwriting, task }
public struct ContentSearchHit: Identifiable, Sendable {
    public let id: UUID
    public let documentID: UUID
    public let pageID: UUID
    public let pageNumber: Int
    public let title: String
    public let text: String
    public let kind: SearchContentKind
    public let bounds: PageRect
    public let seam: SearchSeam?
    /// Where this hit stands in the flow: set when it is chosen (`crossingRange`).
    public var flowRange: NSRange?
    public init(documentID: UUID, pageID: UUID, pageNumber: Int, title: String, text: String,
                kind: SearchContentKind, bounds: PageRect, seam: SearchSeam? = nil) {
        id = UUID(); self.documentID = documentID; self.pageID = pageID; self.pageNumber = pageNumber
        self.title = title; self.text = String(text.prefix(2_000)); self.kind = kind; self.bounds = bounds; self.seam = seam
    }
    private static let locale = Locale(identifier: "de_DE")
    public func matches(_ query: String) -> Bool {
        if seam != nil { return crossingRange(query) != nil }
        let terms = query.split(whereSeparator: \.isWhitespace)
        return !terms.isEmpty && terms.allSatisfy { text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive], locale: Self.locale) != nil }
    }
    /// The phrase over the page change of a `seam` line, in flow offsets. It
    /// must cross that change: what stands on one page is that page's own hit.
    /// White space counts as one space, the change may fall on any of it.
    public func crossingRange(_ query: String) -> NSRange? {
        let terms = query.split(whereSeparator: \.isWhitespace)
        guard let seam, !terms.isEmpty else { return nil }
        let source = text as NSString
        var folded: [unichar] = [], places: [Int] = []
        for index in 0..<source.length {
            let unit = source.character(at: index)
            if UnicodeScalar(unit).map(CharacterSet.whitespacesAndNewlines.contains) == true {
                if folded.last != 32 { folded.append(32); places.append(index) }
            } else { folded.append(unit); places.append(index) }
        }
        let line = String(decoding: folded, as: UTF16.self) as NSString
        let phrase = terms.joined(separator: " ")
        var from = 0
        while from < line.length {
            let found = line.range(of: phrase, options: [.caseInsensitive, .diacriticInsensitive],
                                   range: NSRange(location: from, length: line.length - from), locale: Self.locale)
            guard found.location != NSNotFound, found.length > 0 else { return nil }
            let start = places[found.location], end = places[NSMaxRange(found) - 1] + 1
            if start < seam.location, end > seam.location { return NSRange(location: seam.flowStart + start, length: end - start) }
            from = found.location + 1
        }
        return nil
    }
}
