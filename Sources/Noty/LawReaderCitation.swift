import SwiftUI
import NotebookCore

// Gesetzesverweise aus dem Heft (docs/PARAGRAPH-LINKS.md): Der Leser im
// Gesetzesfenster nimmt den Sprung `LawLibraryModel.citationJump` entgegen und
// bietet danach „Zurück zur Notiz“ an (`LawLibraryModel.citationReturn`).

extension LawReaderView {
    /// Opens the section a notebook citation asked for, once. Only the
    /// reader of the law window takes it; `false` when nothing was waiting.
    /// A newer jump arriving meanwhile wins: after every wait this one only
    /// goes on while it is still the current one.
    @discardableResult
    func takeCitationJump() async -> Bool {
        guard inPanel, let jump = laws.citationJump else { return false }
        guard let entry = laws.entries.first(where: { $0.id == jump.lawID }) else {
            // Catalogue not there yet: the jump waits for it (`entries.count`).
            if laws.entries.isEmpty { return true }
            laws.citationJump = nil
            if laws.citationReturn?.id == jump.id { settleReturn(jump, moved: false) }
            return false
        }
        laws.citationJump = nil
        citationJumpID = jump.id
        defer { if citationJumpID == jump.id { citationJumpID = nil } }
        let before = "\(selectedID)|\(sectionID)"
        let missing = "\(LawCitationText.reference(jump.key, paragraph: jump.paragraph, abbr: entry.abbr)) ist in der aktuellen Fassung nicht enthalten."
        let outcome = await open(entry, target: jump.key, paragraph: jump.paragraph)
        guard citationJumpID == jump.id else { return true }
        switch outcome {
        case .opened, .superseded:
            break
        case .missingSection:
            if selectedID.isEmpty {
                // A fresh reader: the law opens at its beginning with the note,
                // never an empty window.
                let fallback = await open(entry, resume: true)
                guard citationJumpID == jump.id else { return true }
                if fallback == .opened || loadError.isEmpty { loadError = missing }
            } else {
                loadError = missing
            }
        case .failed:
            // E.g. offline and not downloaded: the error stays; a fresh reader
            // still shows where it was read last.
            if selectedID.isEmpty {
                let error = loadError
                citationJumpID = nil
                await openInitial()
                guard citationJumpID == nil, laws.citationJump == nil else { return true }
                if loadError.isEmpty { loadError = error }
            }
        }
        if laws.citationReturn?.id == jump.id { settleReturn(jump, moved: "\(selectedID)|\(sectionID)" != before) }
        return true
    }

    /// After a jump: the way back follows what is shown now. Nothing moved in
    /// a window that was already visible: there is nothing to go back to.
    private func settleReturn(_ jump: LawCitationJump, moved: Bool) {
        guard var back = laws.citationReturn, back.id == jump.id else { return }
        if !moved && !back.chained && back.phase == .visible {
            laws.restoreReading(back.citedLawSpots)
            laws.citationReturn = nil
            return
        }
        back.lawID = selectedID
        back.sectionID = sectionID.isEmpty ? nil : sectionID
        laws.citationReturn = back
    }

    /// Another section or law than the cited one: the way back is no longer offered.
    func citationNavigated() {
        guard inPanel, citationJumpID == nil, let back = laws.citationReturn, let target = back.sectionID else { return }
        if selectedID != back.lawID || sectionID != target { laws.citationReturn = nil }
    }

    /// „Zurück zur Notiz“: the window as it was before the citation opened it
    /// (closed, at the edge, or visible at the earlier reading spot). Every
    /// cited law gets its own reading spot back (or none, if never read).
    func returnFromCitation() async {
        guard let back = laws.citationReturn else { return }
        laws.citationReturn = nil
        laws.restoreReading(back.citedLawSpots)
        switch back.phase {
        case .closed:
            panel.close()
            if let spot = back.spot { laws.rememberReading(spot) }
        case .parked, .visible:
            if let spot = back.spot, let entry = laws.entries.first(where: { $0.id == spot.lawId }) {
                await resume(entry, at: spot)
            }
            if back.phase == .parked { panel.park() }
        }
    }

    /// Small and quiet above the section: only after a citation jump.
    @ViewBuilder var citationBack: some View {
        if inPanel, let back = laws.citationReturn, laws.citationJump == nil {
            HStack(spacing: 0) {
                Button { Task { await returnFromCitation() } } label: {
                    Label("Zurück zur Notiz", systemImage: "chevron.backward")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.notyAccent)
                        .padding(.horizontal, 10).frame(minHeight: 30)
                        .background(Color.white.opacity(0.08), in: Capsule(style: .continuous))
                        .frame(minHeight: 44).contentShape(Rectangle())
                }
                .buttonStyle(NotyPressStyle())
                .accessibilityHint(back.phase == .closed ? "Schließt die Gesetze wieder"
                    : back.phase == .parked ? "Schiebt die Gesetze wieder an den Rand" : "Zeigt wieder die vorherige Stelle")
                .notyTooltip("Zurück zur Notiz")
                Spacer(minLength: 0)
            }
            .padding(.leading, LawReadingStyle.textLeading - 6).padding(.bottom, -10)
            .transition(.opacity)
        }
    }
}

/// Wording of citations for the card and the reader.
enum LawCitationText {
    /// „§ 35a Abs. 2 EStG“ from a section key; keys of administrative rules
    /// (e.g. „9.1“ of LStR) read „R 9.1“ only when the label says so, which the
    /// caller passes as `label` when the section is known.
    static func reference(_ key: String, paragraph: String?, abbr: String, label: String? = nil) -> String {
        var text = label ?? "§ \(key)"
        if let paragraph { text += " Abs. \(paragraph)" }
        return text + " " + abbr
    }
}
