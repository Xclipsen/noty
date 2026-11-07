import SwiftUI
import NotebookCore

// Gesetzesverweise aus dem Heft (docs/PARAGRAPH-LINKS.md): Der Leser im
// Gesetzesfenster nimmt den Sprung `LawLibraryModel.citationJump` entgegen und
// bietet danach „Zurück zur Notiz“ an (`LawLibraryModel.citationReturn`).
// Querverweise im Gesetzestext selbst führen innerhalb des Lesers weiter und
// zurück („Zurück zu § 10 EStG“, `crossBack`, nur im Speicher).

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
        // A note's citation starts a new trail; cross-references before it are done.
        crossBack = []
        // The text's place before the first jump, for the way back.
        if var back = laws.citationReturn, back.id == jump.id, !back.chained, back.textOffset == nil,
           !viewPDF, !selectedID.isEmpty, let offset = textSelection.view?.contentOffset.y {
            back.textOffset = offset; back.offsetPlace = "\(selectedID)|\(sectionID)"
            laws.citationReturn = back
        }
        let before = "\(selectedID)|\(sectionID)|\(viewPDF)"
        var missing = "\(LawCitationText.reference(jump.key, paragraph: jump.paragraph, abbr: entry.abbr)) ist in \(jump.version == nil ? "der aktuellen Fassung" : jump.year.map { "der Fassung für \($0)" } ?? "dieser Fassung") nicht enthalten."
        var outcome = await open(entry, version: jump.version, target: jump.key, paragraph: jump.paragraph)
        guard citationJumpID == jump.id else { return true }
        var notice: String?
        if outcome == .failed, jump.version != nil {
            // The tax year's version could not be loaded (offline, not on this
            // iPad): the current one instead, saying so.
            outcome = await open(entry, target: jump.key, paragraph: jump.paragraph)
            guard citationJumpID == jump.id else { return true }
            missing = "\(LawCitationText.reference(jump.key, paragraph: jump.paragraph, abbr: entry.abbr)) ist in der aktuellen Fassung nicht enthalten."
            if outcome == .opened {
                notice = (jump.year.map { "Fassung für \($0)" } ?? "Diese Fassung") + " nicht verfügbar – aktuelle Fassung gezeigt"
            }
        }
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
        if let notice { loadError = notice }
        // Moved: another section, PDF → text, or the text scrolled to an Absatz.
        let moved = "\(selectedID)|\(sectionID)|\(viewPDF)" != before || (outcome == .opened && jump.paragraph != nil)
        if laws.citationReturn?.id == jump.id { settleReturn(jump, moved: moved) }
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
    /// Following cross-references from the cited section keeps the way back to the note.
    func citationNavigated() {
        guard inPanel, citationJumpID == nil, let back = laws.citationReturn, let target = back.sectionID else { return }
        let atCited = selectedID == back.lawID && sectionID == target
        let viaCrossReferences = crossBack.first.map { $0.lawID == back.lawID && $0.sectionID == target } ?? false
        if !atCited && !viaCrossReferences { laws.citationReturn = nil }
    }

    /// „Zurück zur Notiz“: the window as it was before the citation opened it
    /// (closed, at the edge, or visible at the earlier reading spot). Every
    /// cited law gets its own reading spot back (or none, if never read).
    func returnFromCitation() async {
        guard let back = laws.citationReturn else { return }
        laws.citationReturn = nil
        crossBack = []
        laws.restoreReading(back.citedLawSpots)
        switch back.phase {
        case .closed:
            panel.close()
            if let spot = back.spot { laws.rememberReading(spot) }
        case .parked, .visible:
            if let spot = back.spot, let entry = laws.entries.first(where: { $0.id == spot.lawId }) {
                // Text or PDF (with its page) as it was (`resume`), the text at its offset.
                await resume(entry, at: spot)
                if let offset = back.textOffset, back.offsetPlace == "\(selectedID)|\(sectionID)",
                   spot.lawId == selectedID, spot.sectionId == sectionID, !viewPDF {
                    restore(offset: offset)
                }
            }
            if back.phase == .parked { panel.park() }
        }
    }

    // MARK: Cross-references in the law text

    /// A tapped „§ 10 Abs. 3“ in the text: that section (and Absatz) in the
    /// reader, the place before on `crossBack`. In the same law the open
    /// version stays; another law opens in its current version.
    func followCrossReference(_ citation: LawCitation) {
        guard let target = laws.entries.first(where: { $0.id == citation.lawID }), let doc = document,
              let here = section, let current = entry else { return }
        textSelection.clear()
        let step = LawCrossBack(lawID: selectedID, versionID: doc.version, sectionID: here.id,
                                label: "\(here.label) \(current.abbr)", offset: viewPDF ? nil : textSelection.view?.contentOffset.y)
        crossBack.append(step)
        if crossBack.count > 30 { crossBack.removeFirst(crossBack.count - 30) }
        let key = citation.reference.key, paragraph = citation.reference.paragraph
        if citation.lawID == selectedID, let shown = doc.sections.first(where: { $0.id == key || $0.keys.contains(key) }) {
            crossNavigating = true; defer { crossNavigating = false }
            showSection(shown)
            jump(to: paragraph)
            return
        }
        Task {
            crossNavigating = true
            let outcome = await open(target, version: citation.lawID == selectedID ? doc.version : nil, target: key, paragraph: paragraph)
            crossNavigating = false
            guard outcome == .missingSection || outcome == .failed else { return }
            // Nothing moved: no step back to offer.
            crossBack.removeAll { $0.id == step.id }
            if outcome == .missingSection {
                loadError = "\(LawCitationText.reference(key, paragraph: paragraph, abbr: target.abbr)) ist in dieser Fassung nicht enthalten."
            }
        }
    }

    /// „Zurück zu § 10 EStG“: one step back, with the text where it was.
    func crossReferenceBack() async {
        guard let step = crossBack.popLast(), let target = laws.entries.first(where: { $0.id == step.lawID }) else { return }
        textSelection.clear()
        crossNavigating = true; defer { crossNavigating = false }
        if step.lawID == selectedID, step.versionID == document?.version, let shown = document?.sections.first(where: { $0.id == step.sectionID }) {
            if viewPDF { viewPDF = false }
            showSection(shown)
        } else {
            guard await open(target, version: step.versionID, target: step.sectionID, resume: true) == .opened else { return }
        }
        if let offset = step.offset, sectionID == step.sectionID { restore(offset: offset) }
    }

    /// Small and quiet above the section: only after a citation jump.
    /// Also the way back along cross-references („Zurück zu § 10 EStG“).
    @ViewBuilder var citationBack: some View {
        let back = inPanel && laws.citationJump == nil ? laws.citationReturn : nil
        let step = crossBack.last
        if back != nil || step != nil {
            HStack(spacing: 6) {
                if let step {
                    backButton("Zurück zu \(step.label)", hint: "Zeigt wieder die Stelle vor dem Querverweis") {
                        Task { await crossReferenceBack() }
                    }
                }
                if let back {
                    backButton(step == nil ? "Zurück zur Notiz" : "Zur Notiz",
                               hint: back.phase == .closed ? "Schließt die Gesetze wieder"
                                   : back.phase == .parked ? "Schiebt die Gesetze wieder an den Rand" : "Zeigt wieder die vorherige Stelle") {
                        Task { await returnFromCitation() }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, LawReadingStyle.textLeading - 6).padding(.bottom, -10)
            .transition(.opacity)
        }
    }

    private func backButton(_ title: String, hint: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: "chevron.backward")
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .foregroundStyle(Color.notyAccent)
                .padding(.horizontal, 10).frame(minHeight: 30)
                .background(Color.white.opacity(0.08), in: Capsule(style: .continuous))
                .frame(minHeight: 44).contentShape(Rectangle())
        }
        .buttonStyle(NotyPressStyle())
        .accessibilityHint(hint)
        .notyTooltip(title)
    }
}

/// One step back along cross-references in the reader (in memory only).
struct LawCrossBack: Equatable, Identifiable {
    var id = UUID()
    var lawID: String
    var versionID: String
    var sectionID: String
    /// „§ 10 EStG“ for „Zurück zu § 10 EStG“.
    var label: String
    /// Scroll offset of the text then (nil: shown as PDF).
    var offset: CGFloat?
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
