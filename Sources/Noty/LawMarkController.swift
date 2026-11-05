import SwiftUI
import UIKit
import Combine
import NotebookCore

// Markier-Bedienung im Gesetzesleser (Paket A2, docs/LAW-REWORK.md).
//
// `LawReaderView` erzeugt je Leser einen `LawMarkController` und gibt ihn per
// `.environmentObject` an seine Unteransichten und Sheets; Text- und PDF-Ansicht
// erreichen ihn über `LawTextSelection.controller`.
//
// Zustand (nur lesen, Main Actor):
// - `selectionActive`: Text- oder PDF-Auswahl oder angetippte Markierung.
// - `canUndo`/`canRedo`: eigener Stapel dieses Lesers (keine fremden oder
//   synchronisierten Markierungen).
// - `toast`: kurze Meldung, ggf. mit „Rückgängig“ (≈ 4 s, mit VoiceOver 10 s);
//   Stiftmarkierungen (Farbe `nil`) melden „Markiert · Rückgängig“.
// - `adjusting`: „Bereich anpassen“ läuft für diese Markierung.
// - `lastColor`: zuletzt benutzte Farbe (⇧⌘H).
// - `syncBadge`: Abgleichstatus aus `LawLibraryModel.syncState` (inklusive
//   Fehler und abgelehnter Einträge) samt Klartext.
//
// Befehle (Tastatur, Leiste, Menüs):
// - `mark(color:)`: Auswahl (Text oder PDF) markieren; bei angetippter
//   Markierung umfärben; im „Bereich anpassen“ übernehmen. `nil` = Stiftfarbe.
// - `removeSelection()`: ausgewählten Text aus Markierungen entfernen (teilt),
//   angetippte bzw. von der PDF-Auswahl berührte Markierungen ganz entfernen.
// - `recolor(_:)`: angetippte Markierungen umfärben (löschen + neu).
// - `undo()`/`redo()`: Pläne des eigenen Stapels, jeweils mit neuen IDs.
// - `copySelection()`, `adjustSelectedMark()`, `applyAdjusting()`, `clearSelection()`.
//
// Jede Änderung ist ein Plan (Core `LawMarkEditing`) und wird über
// `LawLibraryModel.commit(plan:)` als ein atomarer Schreibvorgang
// (`commit(puts:removes:)`) geschrieben; Änderungen laufen nacheinander.

/// Abgleichstatus der persönlichen Gesetzesdaten für eine kleine Anzeige.
struct LawMarkSyncBadge: Equatable {
    /// Strukturierter Zustand des Daten-Pakets (Gast, pausiert, abgelaufen,
    /// läuft, Fehler, ausstehend, abgelehnt, synchronisiert).
    var status = LawSyncStatus(state: .guest)
    /// Klartext (`LawLibraryModel.syncStatus`).
    var detail = "Nur auf diesem iPad"
}

/// A short message under the reader, optionally offering undo.
struct LawMarkToast: Equatable, Identifiable {
    let id = UUID()
    var message: String
    var undo: Bool
}

/// What the controller needs to know about the reader right now.
struct LawMarkContext {
    var document: LawDocument
    var section: LawSection?
    /// Text shown for `section` (HTML rendering or plain), `LawTextSelection.text`.
    var renderedText: String
    /// Colour of new marks without explicit colour (the Pencil's).
    var penHex: String
}

/// The PDF view while it is shown (implemented by `NativeLawPDF.Coordinator`).
@MainActor
protocol LawPDFMarkHost: AnyObject {
    var hasPDFSelection: Bool { get }
    var pdfSelectionText: String? { get }
    /// Payloads for the current PDF selection (one per page), without colour.
    func pdfSelectionPayloads() -> [[String: LawJSON]]
    /// Marks the current PDF selection touches.
    func marksTouchedBySelection() -> [String]
    func clearPDFSelection()
    /// Text under a PDF mark (for copying).
    func text(ofMark id: String) -> String?
}

@MainActor
final class LawMarkController: ObservableObject {
    @Published private(set) var selectionActive = false
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    @Published private(set) var syncBadge = LawMarkSyncBadge()
    @Published private(set) var toast: LawMarkToast?
    /// „Bereich anpassen“: the mark whose bounds the text selection replaces.
    @Published private(set) var adjusting: String?
    @Published private(set) var lastColor = UserDefaults.standard.string(forKey: "noty.laws.markColor") ?? LawMarkEditing.defaultColor

    private(set) weak var laws: LawLibraryModel?
    private(set) weak var selection: LawTextSelection?
    weak var pdfHost: LawPDFMarkHost?
    private var context: () -> LawMarkContext? = { nil }
    /// Law version shown in the reader (for the PDF's provision positions).
    var document: LawDocument? { context()?.document }
    private var watching: [AnyCancellable] = []
    /// Own undo/redo stacks (Core `LawMarkHistory`): older steps follow the
    /// new IDs of every replay; another owner empties them.
    private var history = LawMarkHistory()
    private var queue: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?

    // MARK: Connection

    /// Verbindet den Controller mit dem Leser; erneut aufgerufen, ersetzt es
    /// die vorige Verbindung (z. B. nach einem Stiftwechsel). Der Stapel bleibt.
    func connect(laws: LawLibraryModel, selection: LawTextSelection, context: @escaping () -> LawMarkContext?) {
        self.laws = laws; self.selection = selection; self.context = context
        selection.controller = self
        watching = []
        selection.$range.combineLatest(selection.$marks, selection.$pdfSelection)
            .map { range, marks, pdf in range.length > 0 || !marks.isEmpty || pdf }
            .removeDuplicates()
            .sink { [weak self] active in self?.selectionActive = active }
            .store(in: &watching)
        // objectWillChange kommt vor der Änderung: danach neu lesen.
        laws.objectWillChange.receive(on: DispatchQueue.main)
            .sink { [weak self, weak laws] _ in if let laws { self?.refreshBadge(laws); self?.followOwner(laws) } }
            .store(in: &watching)
        refreshBadge(laws)
        followOwner(laws)
    }
    /// Sign-in, sign-out or another account: the steps of the previous owner
    /// can no longer be undone (they would write its entries for the new one).
    private func followOwner(_ laws: LawLibraryModel) {
        history.align(owner: laws.owner)
        refreshStacks()
    }
    /// Löst die Verbindung (der Leser verschwindet); hält keinen Leserstand fest.
    func disconnect() {
        context = { nil }
        watching = []
    }
    private func refreshBadge(_ laws: LawLibraryModel) {
        let next = LawMarkSyncBadge(status: laws.syncState, detail: laws.syncStatus)
        if next != syncBadge { syncBadge = next }
    }

    // MARK: Commands

    func mark(color: String?) {
        guard let selection else { return }
        let color = resolved(color)
        if adjusting != nil { applyAdjusting(color: color); return }
        if let pdfHost, pdfHost.hasPDFSelection { markPDFSelection(color: color); return }
        if selection.range.length > 0 { markText(selection.range, color: color); return }
        if !selection.marks.isEmpty { recolor(color) }
    }
    func removeSelection() {
        guard let selection else { return }
        if let pdfHost, pdfHost.hasPDFSelection {
            let touched = pdfHost.marksTouchedBySelection()
            pdfHost.clearPDFSelection()
            removeMarks(touched)
            return
        }
        if selection.range.length > 0, !selection.tapped {
            removeText(selection.range)
            selection.clear()
            return
        }
        if !selection.marks.isEmpty { removeMarks(selection.marks) }
    }
    func recolor(_ color: String) {
        guard let selection, !selection.marks.isEmpty else { return }
        let color = resolved(color), ids = selection.marks
        remember(color)
        perform(toast: nil, selectCreated: true) { laws, context in
            var change = LawMarkChange()
            let items = ids.compactMap(laws.liveItem)
            let text = items.filter { $0.payload["kind"]?.string == "text" && $0.textAnchor?.sectionId == context?.section?.id }
            if let context, let section = context.section, !text.isEmpty {
                let ranges = laws.markRanges(in: section, of: laws.annotations(law: context.document.id, version: context.document.version))
                let plan = try LawMarkEditing.plan(.recolor(text.map(\.id), color: color), existing: ranges, sectionId: section.id,
                                                   textLength: (LawTextAnchor.canonical(section.text) as NSString).length)
                change = try laws.change(for: plan, section: section, document: context.document)
            }
            // PDF marks and text marks of other sections: same entry, new colour, new ID.
            for item in items where !text.contains(item) && LawMarkEditing.colorKey(item.payload["color"]?.string) != color {
                var addition = item.recreation
                addition.payload["color"] = .string(color)
                change.removals.append(item); change.additions.append(addition)
            }
            return change
        }
    }
    func undo() { replay(undo: true) }
    func redo() { replay(undo: false) }
    func copySelection() {
        guard let selection else { return }
        var text: String?
        if let pdfHost, pdfHost.hasPDFSelection { text = pdfHost.pdfSelectionText }
        else if selection.range.length > 0, NSMaxRange(selection.range) <= (selection.text as NSString).length {
            text = (selection.text as NSString).substring(with: selection.range)
        } else if let id = selection.marks.first {
            text = originalRange(of: id).map { (selection.text as NSString).substring(with: $0) } ?? pdfHost?.text(ofMark: id)
        }
        guard let text, !text.isEmpty else { return }
        UIPasteboard.general.string = text
        show(LawMarkToast(message: "Kopiert", undo: false))
    }
    /// „Bereich anpassen“: puts the text selection on the tapped mark; the next
    /// colour (or ✓) replaces the mark's bounds by the adjusted selection.
    func adjustSelectedMark() {
        guard let selection, selection.tapped, let id = selection.marks.first, let range = originalRange(of: id),
              laws?.liveItem(id)?.payload["kind"]?.string == "text", let view = selection.view else { return }
        adjusting = id
        selection.tapped = false
        view.becomeFirstResponder()
        view.selectedRange = range
    }
    func applyAdjusting(color: String? = nil) {
        guard let id = adjusting, let selection, selection.range.length > 0, let item = laws?.liveItem(id) else { endAdjusting(); return }
        let color = color ?? LawMarkEditing.colorKey(item.payload["color"]?.string)
        remember(color)
        let range = selection.range
        endAdjusting()
        selection.clear()
        textPlan(range, toast: nil) { start, end in
            // Mark dropped, then the adjusted range in its (or the chosen) colour.
            [.removeMarks([id]), .add(start: start, end: end, color: color)]
        }
    }
    func endAdjusting() { if adjusting != nil { adjusting = nil } }
    func clearSelection() {
        pdfHost?.clearPDFSelection()
        selection?.clear()
        endAdjusting()
    }
    func dismissToast() { toastTask?.cancel(); toast = nil }
    /// The toast's „Rückgängig“.
    func undoFromToast() { dismissToast(); undo() }

    // MARK: Used by the text and PDF views

    func markText(_ range: NSRange, color: String?) {
        // Without colour it comes from Apple Pencil: no bar, so the toast offers undo.
        let toast = color == nil ? "Markiert" : nil
        let color = resolved(color)
        remember(color)
        selection?.clear()
        textPlan(range, toast: toast) { start, end in [.add(start: start, end: end, color: color)] }
    }
    /// Removes `range` of the rendered text from every mark (eraser, selection).
    func removeText(_ range: NSRange) {
        textPlan(range, toast: "Markierung entfernt") { start, end in [.remove(start: start, end: end)] }
    }
    func removeMarks(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        let ids = Array(Set(ids))
        selection?.select(mark: nil)
        perform(toast: ids.count == 1 ? "Markierung entfernt" : "\(ids.count) Markierungen entfernt") { laws, _ in
            LawMarkChange(removals: ids.compactMap(laws.liveItem))
        }
    }
    /// Removes any personal entries (list), with undo.
    func removeItems(_ items: [LawPersonalItem]) {
        let marks = items.filter { $0.kind == "annotation" }.count, bookmarks = items.count - marks
        let message = marks > 0 && bookmarks == 0 ? (marks == 1 ? "Markierung entfernt" : "\(marks) Markierungen entfernt")
            : (bookmarks == 1 && marks == 0 ? "Lesezeichen entfernt" : "\(items.count) Einträge entfernt")
        perform(toast: message) { laws, _ in LawMarkChange(removals: items.compactMap { laws.liveItem($0.id) }) }
    }
    /// New PDF marks (stroke or selection); `color` nil = Pencil colour.
    func addPDF(_ payloads: [[String: LawJSON]], color: String? = nil) {
        guard !payloads.isEmpty, let document = context()?.document else { return }
        let toast = color == nil ? "Markiert" : nil
        let color = resolved(color)
        remember(color)
        perform(toast: toast) { _, _ in
            LawMarkChange(additions: payloads.map { payload in
                var payload = payload
                payload["lawId"] = .string(document.id); payload["versionId"] = .string(document.version)
                payload["color"] = .string(color)
                return LawMarkAddition(payload: payload)
            })
        }
    }
    private func markPDFSelection(color: String) {
        guard let pdfHost else { return }
        let payloads = pdfHost.pdfSelectionPayloads()
        pdfHost.clearPDFSelection()
        addPDF(payloads, color: color)
    }

    // MARK: Internals

    private func resolved(_ color: String?) -> String { LawMarkEditing.colorKey(color ?? context()?.penHex) }
    private func remember(_ color: String) {
        guard lastColor != color else { return }
        lastColor = color
        UserDefaults.standard.set(color, forKey: "noty.laws.markColor")
    }
    /// Range of a text mark in the rendered text of the shown section.
    func originalRange(of id: String) -> NSRange? {
        guard let selection, let anchor = laws?.liveItem(id)?.textAnchor, anchor.sectionId == context()?.section?.id else { return nil }
        return LawTextAnchor.originalRange(text: selection.text, anchor: anchor)
    }
    /// Plans edits on the canonical range of `range` (rendered text) in the
    /// shown section; the edits run one after another in one undo step.
    private func textPlan(_ range: NSRange, toast: String?, edits: @escaping (Int, Int) -> [LawMarkEdit]) {
        guard let context = context(), let section = context.section else { return }
        let rendered = context.renderedText
        guard range.location >= 0, NSMaxRange(range) <= (rendered as NSString).length,
              !LawTextAnchor.canonical((rendered as NSString).substring(with: range)).isEmpty else { return }
        // The rendered text (HTML) may differ from the stored section text.
        guard let anchor = LawTextAnchor.anchor(rendered: rendered, range: range, sectionText: section.text, sectionID: section.id) else {
            show(LawMarkToast(message: "Bitte etwas mehr Text auswählen.", undo: false)); return
        }
        let document = context.document
        perform(toast: toast) { laws, _ in
            let canonical = LawTextAnchor.canonical(section.text)
            let length = (canonical as NSString).length
            var marks = laws.markRanges(in: section, of: laws.annotations(law: document.id, version: document.version))
            var plan = LawMarkPlan()
            for edit in edits(anchor.start, anchor.end) {
                let step = try LawMarkEditing.plan(edit, existing: marks, sectionId: section.id, textLength: length)
                plan = plan.then(step)
                marks = LawMarkEditing.apply(step, to: marks)
            }
            return try laws.change(for: plan, section: section, document: document)
        }
    }
    /// Runs `build` after every earlier change has been written, on the then
    /// current items, and records the result for undo.
    /// `selectCreated`: a single new mark stays selected (recolouring in a row).
    private func perform(toast: String?, selectCreated: Bool = false, _ build: @escaping @MainActor (LawLibraryModel, LawMarkContext?) throws -> LawMarkChange?) {
        let previous = queue
        queue = Task { @MainActor [weak self] in
            await previous?.value
            guard let self, let laws = self.laws else { return }
            do {
                guard let change = try build(laws, self.context()), !change.isEmpty else { return }
                guard let applied = try await laws.commit(plan: change) else { return }
                self.history.record(applied)
                self.refreshStacks()
                if selectCreated, let selection = self.selection, selection.tapped {
                    selection.select(mark: applied.created.count == 1 ? applied.created[0] : nil)
                }
                if let toast { self.show(LawMarkToast(message: toast, undo: true)) }
            } catch {
                self.show(LawMarkToast(message: error.localizedDescription, undo: false))
            }
        }
    }
    /// Undo/redo: the created entries are deleted, the removed ones come back
    /// with new IDs (deleted IDs stay blocked on the server); the remaining
    /// steps follow those IDs (`LawMarkHistory`), so undo works step by step
    /// also after dependent changes (mark → extend → undo → undo).
    private func replay(undo: Bool) {
        if let laws { history.align(owner: laws.owner) }
        guard let step = undo ? history.popUndo() : history.popRedo() else { refreshStacks(); return }
        refreshStacks()
        let previous = queue
        selection?.select(mark: nil)
        queue = Task { @MainActor [weak self] in
            await previous?.value
            guard let self else { return }
            guard let laws = self.laws, step.owner == laws.owner else {
                // Signed in or out meanwhile: the step belonged to another owner.
                if let laws = self.laws { self.history.align(owner: laws.owner) }
                self.refreshStacks(); return
            }
            let replay = LawMarkHistory.replay(step, live: laws.liveItem)
            if replay.isEmpty { self.show(LawMarkToast(message: "Nichts mehr rückgängig zu machen", undo: false)); self.refreshStacks(); return }
            let change = LawMarkChange(removals: replay.removals,
                                       additions: replay.additions.map { LawMarkAddition(kind: $0.kind, payload: $0.payload, id: $0.id) })
            do {
                if let done = try await laws.commit(plan: change) {
                    if undo { self.history.didUndo(done, renamed: replay.renamed) } else { self.history.didRedo(done, renamed: replay.renamed) }
                }
            } catch {
                // Nothing was written: the step stays available.
                self.history.putBack(step, undo: undo)
                self.show(LawMarkToast(message: error.localizedDescription, undo: false))
            }
            self.refreshStacks()
        }
    }
    private func refreshStacks() {
        if canUndo != history.canUndo { canUndo = history.canUndo }
        if canRedo != history.canRedo { canRedo = history.canRedo }
    }
    func show(_ next: LawMarkToast) {
        toastTask?.cancel()
        toast = next
        let id = next.id
        toastTask = Task { @MainActor [weak self] in
            // VoiceOver users need time to reach „Rückgängig“.
            try? await Task.sleep(for: .seconds(UIAccessibility.isVoiceOverRunning ? 10 : next.undo ? 4 : 2.5))
            guard !Task.isCancelled, let self, self.toast?.id == id else { return }
            self.toast = nil
        }
    }
}

extension LawReaderView {
    /// Connects the controller with this reader's state.
    func connectMarkController() {
        markController.connect(laws: laws, selection: textSelection) {
            guard let document else { return nil }
            return LawMarkContext(document: document, section: section, renderedText: textSelection.text, penHex: pen.hex)
        }
    }
}
