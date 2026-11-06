// Vorschau und Öffnen von Gesetzesverweisen im Heft (docs/PARAGRAPH-LINKS.md).
// Die Seite (WorksheetView) meldet Hover/Tippen hierher; EditorWorkspace zeigt
// die Karte und öffnet das Gesetzesfenster.
import SwiftUI
import NotebookCore

/// How the citation was reached; decides what a tap/click does.
enum LawCitationInput: Equatable { case pencilHover, pointerHover, touch }

/// Shared model (one scene: UIApplicationSupportsMultipleScenes = false).
@MainActor
final class LawCitationPreviewModel: ObservableObject {
    static let shared = LawCitationPreviewModel()

    struct Presentation: Equatable {
        var citation: LawCitation
        /// Rect of the citation in window coordinates (for placing the card next to it).
        var anchor: CGRect
        var input: LawCitationInput
        var pageID: UUID?
    }

    @Published private(set) var presentation: Presentation?

    /// Built from the law catalog; nil while the collection is off, has no
    /// catalog, or the user turned links off. Pages scan with this.
    @Published private(set) var scanner: LawCitationScanner?
    /// Bumps whenever `scanner` changes, so pages rescan.
    @Published private(set) var scannerGeneration = 0

    // Called by the page (WorksheetView). All coordinates in window space.
    func hover(_ citation: LawCitation, anchor: CGRect, input: LawCitationInput, pageID: UUID?) {
        // TODO(Preview-Agent)
    }
    func endHover() {
        // TODO(Preview-Agent)
    }
    /// Finger tap on an underline: shows the card (second tap on the card opens).
    func tap(_ citation: LawCitation, anchor: CGRect, pageID: UUID?) {
        // TODO(Preview-Agent)
    }
    /// Pointer click: opens the law window at the citation directly.
    func open(_ citation: LawCitation) {
        // TODO(Preview-Agent)
    }
    func dismiss() {
        // TODO(Preview-Agent)
    }
    /// Pencil touched the paper, page scrolled/zoomed or page changed: hide at once.
    func pageInteractionBegan() {
        // TODO(Preview-Agent)
    }
}
