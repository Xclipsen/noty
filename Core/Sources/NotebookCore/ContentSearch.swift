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
    public init(documentID: UUID, pageID: UUID, pageNumber: Int, title: String, text: String,
                kind: SearchContentKind, bounds: PageRect) {
        id = UUID(); self.documentID = documentID; self.pageID = pageID; self.pageNumber = pageNumber
        self.title = title; self.text = String(text.prefix(2_000)); self.kind = kind; self.bounds = bounds
    }
    public func matches(_ query: String) -> Bool {
        let terms = query.split(whereSeparator: \.isWhitespace)
        return !terms.isEmpty && terms.allSatisfy { text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "de_DE")) != nil }
    }
}
