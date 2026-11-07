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
    static let locale = Locale(identifier: "de_DE")
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

/// A short excerpt of a hit around its match, for the result row: a long
/// paragraph or PDF line (up to 2 000 characters) would otherwise show its
/// first lines without the searched term.
public struct ContentSearchSnippet: Sendable, Equatable {
    public let text: String
    /// The match inside `text`, when the query was found.
    public let match: Range<String.Index>?
    /// Text before the match, the match and the text after it, so a row can
    /// emphasise the middle part without index arithmetic.
    public var parts: (before: Substring, match: Substring, after: Substring) {
        guard let match else { return (text[...], "", "") }
        return (text[..<match.lowerBound], text[match], text[match.upperBound...])
    }
}

extension ContentSearchHit {
    /// The excerpt around the first match of `query` (case and diacritic
    /// insensitive like `matches`): the whole phrase when it occurs, else
    /// the earliest single term. Cut on word boundaries with „…“; line
    /// breaks become spaces. Without a match: the start of the text.
    public func snippet(for query: String, radius: Int = 80) -> ContentSearchSnippet {
        ContentSearchHit.snippet(of: text, query: query, radius: radius)
    }

    static func snippet(of text: String, query: String, radius: Int) -> ContentSearchSnippet {
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        let radius = max(radius, 1)
        var found: Range<String.Index>?
        if !terms.isEmpty {
            found = text.range(of: terms.joined(separator: " "), options: options, locale: locale)
            if found == nil {
                found = terms.compactMap { text.range(of: $0, options: options, locale: locale) }
                    .min { $0.lowerBound < $1.lowerBound }
            }
        }
        let anchor = found ?? (text.startIndex..<text.startIndex)
        let reach = found == nil ? radius * 2 : radius
        var start = text.index(anchor.lowerBound, offsetBy: -reach, limitedBy: text.startIndex) ?? text.startIndex
        var end = text.index(anchor.upperBound, offsetBy: reach, limitedBy: text.endIndex) ?? text.endIndex
        // Word boundaries: never start or end inside a word that was cut.
        if start > text.startIndex, let space = text[start..<anchor.lowerBound].firstIndex(where: \.isWhitespace) {
            start = text.index(after: space)
        }
        if end < text.endIndex, let space = text[anchor.upperBound..<end].lastIndex(where: \.isWhitespace) {
            end = space
        }
        func flat(_ part: Substring) -> String {
            String(part.map { $0.isNewline ? " " : $0 })
        }
        var before = flat(text[start..<anchor.lowerBound]), after = flat(text[anchor.upperBound..<end])
        if start > text.startIndex { before = "…" + before.drop(while: \.isWhitespace) }
        if end < text.endIndex {
            after = String(after.reversed().drop(while: \.isWhitespace).reversed()) + "…"
        }
        guard found != nil else { return ContentSearchSnippet(text: before + after, match: nil) }
        let middle = flat(text[anchor])
        let joined = before + middle + after
        let lower = joined.utf8.index(joined.startIndex, offsetBy: before.utf8.count)
        let upper = joined.utf8.index(lower, offsetBy: middle.utf8.count)
        return ContentSearchSnippet(text: joined, match: lower..<upper)
    }
}
