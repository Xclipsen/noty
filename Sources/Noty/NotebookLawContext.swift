// Gesetzesbezug eines Hefts (docs/PARAGRAPH-LINKS.md, P2): Standardgesetz für
// bloße „§ 35a“ und Veranlagungsjahr für die Fassung. Geräteeinstellung je
// Heft-ID in UserDefaults, nicht Teil des Hefts oder Backups.
import SwiftUI
import NotebookCore

struct NotebookLawContext: Equatable, Sendable {
    var defaultLawID: String? = nil
    var taxYear: Int? = nil
    /// Document id of the notebook the page belongs to (set per page by the
    /// editor; never stored). Copies keep page ids, so a quote needs both.
    var notebookID: UUID? = nil
    /// „Als Zitat einfügen“ is possible on this page: a writable notebook (no
    /// restored copy, no text document), an existing page (not the draft).
    var canQuote = false
    /// Nothing stored for the notebook (only the stored fields count).
    var isEmpty: Bool { defaultLawID == nil && taxYear == nil }
}

/// The law context of every notebook on this iPad, by the notebook's document
/// id (`Notebook.id`; a restored copy has its own id and starts without one).
/// Stored as one JSON object under `key`:
/// `{"<UUID>": {"law": "estg", "year": 2024, "at": <seconds since 2001>}}`,
/// at most `limit` notebooks (the least recently changed go first). Never
/// written into a notebook, a backup or the app sync.
@MainActor
final class NotebookLawPreferences: ObservableObject {
    static let shared = NotebookLawPreferences()
    static let key = "noty.laws.notebookContext"
    static let limit = 400
    /// Years the picker offers (and stored values are accepted from).
    static let firstYear = 2015
    static var lastYear: Int { Calendar(identifier: .gregorian).component(.year, from: Date()) + 1 }

    /// Bumps on every change, so pages rescan.
    @Published private(set) var generation = 0

    private struct Stored: Codable, Equatable {
        var law: String?
        var year: Int?
        var at: Double
    }
    private var stored: [String: Stored]
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let decoded = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode([String: Stored].self, from: $0) } ?? [:]
        // Anything malformed is dropped on read, never trusted.
        stored = decoded.filter { UUID(uuidString: $0.key) != nil && Self.valid($0.value) }
    }

    private static func valid(_ value: Stored) -> Bool {
        (value.law == nil || LawEntry.safeID(value.law!)) && (value.year == nil || (1990...2100).contains(value.year!))
            && value.at.isFinite && (value.law != nil || value.year != nil)
    }

    func context(for documentID: UUID?) -> NotebookLawContext {
        guard let documentID, let value = stored[documentID.uuidString] else { return NotebookLawContext() }
        return NotebookLawContext(defaultLawID: value.law, taxYear: value.year)
    }

    func set(_ context: NotebookLawContext, for documentID: UUID) {
        let id = documentID.uuidString
        var next = stored
        if context.isEmpty {
            next[id] = nil
        } else {
            let value = Stored(law: context.defaultLawID.flatMap { LawEntry.safeID($0) ? $0 : nil },
                               year: context.taxYear.flatMap { (1990...2100).contains($0) ? $0 : nil },
                               at: Date().timeIntervalSinceReferenceDate)
            guard Self.valid(value) else { return }
            next[id] = value
        }
        if next.count > Self.limit {
            let oldest = next.sorted { $0.value.at < $1.value.at }.prefix(next.count - Self.limit).map(\.key)
            for key in oldest where key != id { next[key] = nil }
        }
        guard next != stored else { return }
        stored = next
        if let data = try? JSONEncoder().encode(next) { defaults.set(data, forKey: Self.key) }
        generation += 1
    }
}

/// „Als Zitat einfügen“ from the card: the editor showing `pageID` inserts a
/// text field with `text` and `source` just below `below` (canonical page coordinates).
struct LawQuoteRequest: Equatable, Identifiable {
    let id = UUID()
    var pageID: UUID
    var below: PageRect
    var text: String
    var source: String
    /// `NotebookLawContext.notebookID` of the page; a request without it is
    /// refused (a duplicated notebook or a restored copy has the same page ids).
    var notebookID: UUID? = nil
}
