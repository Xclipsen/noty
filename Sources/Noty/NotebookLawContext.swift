// Gesetzesbezug eines Hefts (docs/PARAGRAPH-LINKS.md, P2): Standardgesetz für
// bloße „§ 35a“ und Veranlagungsjahr für die Fassung. Geräteeinstellung je
// Heft-ID in UserDefaults, nicht Teil des Hefts oder Backups.
import SwiftUI
import NotebookCore

struct NotebookLawContext: Equatable, Sendable {
    var defaultLawID: String? = nil
    var taxYear: Int? = nil
}

@MainActor
final class NotebookLawPreferences: ObservableObject {
    static let shared = NotebookLawPreferences()
    /// Bumps on every change, so pages rescan.
    @Published private(set) var generation = 0
    func context(for documentID: UUID?) -> NotebookLawContext {
        NotebookLawContext() // TODO(Editor-Agent)
    }
    func set(_ context: NotebookLawContext, for documentID: UUID) {
        // TODO(Editor-Agent)
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
}
