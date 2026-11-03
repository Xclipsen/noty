import SwiftUI
import Combine
import NotebookCore

// Schnittstelle der Markier-Bedienung im Gesetzesleser (Schritt 0b, docs/LAW-REWORK.md).
//
// `LawReaderView` erzeugt je Leser einen `LawMarkController` und gibt ihn per
// `.environmentObject` an seine Unteransichten und Sheets. Tastatur- (B2) und
// Design-Paket (C) programmieren nur gegen diese Schnittstelle; das
// Markier-Paket (A2) tauscht die Umsetzung dahinter aus.
//
// Zustand (nur lesen, ändert sich auf dem Main Actor):
// - `selectionActive`: Textauswahl oder angetippte Markierungen vorhanden
//   (wie `LawTextSelection.active`).
// - `canUndo`: Es gibt eine Markierung, die „Letzte Markierung rückgängig“
//   entfernen würde. `canRedo`: vorerst immer `false`.
// - `syncBadge`: einfacher Abgleichstatus aus `LawLibraryModel`.
//
// Befehle:
// - `mark(color:)`: markiert die aktuelle Textauswahl; `nil` = Farbe des Stifts.
// - `removeSelection()`: entfernt die Markierungen unter der Auswahl.
// - `recolor(_:)`: Umfärben; vorerst ohne Wirkung (gibt es heute nicht).
// - `undo()`: wie „Letzte Markierung rückgängig“ (entfernt die zuletzt
//   gespeicherte Markierung dieser Fassung).
// - `redo()`: vorerst ohne Wirkung (gibt es heute nicht).
//
// Heute leitet der Controller nur an das bestehende Verhalten des Lesers
// weiter (`connectMarkController()` unten); ohne verbundenen Leser sind alle
// Befehle ohne Wirkung.

/// Abgleichstatus der persönlichen Gesetzesdaten für eine kleine Anzeige.
struct LawMarkSyncBadge: Equatable {
    enum State: Equatable {
        /// Ohne Konto, Abgleich aus oder Anmeldung abgelaufen: bleibt auf diesem iPad.
        case local
        case syncing
        /// Angemeldet; so viele eigene Änderungen sind noch nicht gesendet.
        case pending(Int)
        /// Angemeldet, nichts offen.
        case synced
    }
    var state = State.local
    /// Klartext wie bisher im Menü des Lesers (`LawLibraryModel.syncStatus`).
    var detail = "Lokal gespeichert"
}

@MainActor
final class LawMarkController: ObservableObject {
    @Published private(set) var selectionActive = false
    @Published private(set) var canUndo = false
    var canRedo: Bool { false }
    @Published private(set) var syncBadge = LawMarkSyncBadge()

    func mark(color: String?) { actions?.mark(color) }
    func removeSelection() { actions?.removeSelection() }
    /// Dokumentierter No-op: Umfärben gibt es noch nicht.
    func recolor(_ color: String) {}
    func undo() { actions?.undo() }
    /// Dokumentierter No-op: Wiederholen gibt es noch nicht.
    func redo() {}

    // MARK: Brücke zum bestehenden Verhalten

    struct Actions {
        var mark: (String?) -> Void
        var removeSelection: () -> Void
        var undo: () -> Void
    }
    private var actions: Actions?
    private var watching: [AnyCancellable] = []

    /// Verbindet den Controller mit dem Leser; erneut aufgerufen, ersetzt es
    /// die vorige Verbindung (z. B. nach einem Stiftwechsel).
    func connect(laws: LawLibraryModel, selection: LawTextSelection, actions: Actions) {
        self.actions = actions
        watching = []
        selection.$range.combineLatest(selection.$marks)
            .map { range, marks in range.length > 0 || !marks.isEmpty }
            .removeDuplicates()
            .sink { [weak self] active in self?.selectionActive = active }
            .store(in: &watching)
        // objectWillChange kommt vor der Änderung: danach neu lesen.
        laws.objectWillChange.receive(on: DispatchQueue.main)
            .sink { [weak self, weak laws] _ in if let laws { self?.refreshBadge(laws) } }
            .store(in: &watching)
        refreshBadge(laws)
    }
    /// Löst die Verbindung (der Leser verschwindet); hält keinen Leserstand fest.
    func disconnect() {
        actions = nil
        watching = []
    }
    func update(canUndo: Bool) { if self.canUndo != canUndo { self.canUndo = canUndo } }

    private func refreshBadge(_ laws: LawLibraryModel) {
        let state: LawMarkSyncBadge.State
        if laws.user == nil || laws.sessionExpired || !laws.syncEnabled { state = .local }
        else if laws.syncing { state = .syncing }
        else if laws.pendingCount > 0 { state = .pending(laws.pendingCount) }
        else { state = .synced }
        let next = LawMarkSyncBadge(state: state, detail: laws.syncStatus)
        if next != syncBadge { syncBadge = next }
    }
}

extension LawReaderView {
    /// The annotation „Letzte Markierung rückgängig“ removes.
    var lastAnnotation: LawPersonalItem? { marks.last { $0.kind == "annotation" } }
    /// Today's behaviour behind `LawMarkController`: the selection bar's
    /// „Markieren“/„Markierung entfernen“ and the menu's undo.
    func connectMarkController() {
        markController.connect(laws: laws, selection: textSelection, actions: .init(
            mark: { color in if textSelection.range.length > 0 { mark(textSelection.range, color: color) } },
            removeSelection: { if !textSelection.marks.isEmpty { unmark(textSelection.marks) } },
            undo: { if let last = lastAnnotation { Task { await laws.remove(last) } } }))
    }
}
