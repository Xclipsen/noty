import SwiftUI
import NotebookCore

/// Which input started a lookup; that field keeps what was typed there.
enum LawLookupField { case query, number }

/// How `LawReaderView.open` ended.
enum LawOpenOutcome {
    case opened
    /// The document loaded, but this version has no such section (nothing changed).
    case missingSection
    /// The document could not be loaded (`loadError` says why; nothing changed).
    case failed
    /// A newer request replaced this one.
    case superseded
}

extension LawReaderView {
    /// Opens the law and section the reader showed last (or the first law).
    func openInitial() async {
        // A citation waiting for this reader wins over the last reading spot.
        guard selectedID.isEmpty, !loading, laws.citationJump == nil, citationJumpID == nil,
              let entry = laws.entries.first(where: { $0.id == laws.lastReadingSpot?.lawId }) ?? laws.entries.first else { return }
        await resume(entry)
    }
    /// Picking the current law keeps the reading position; another law continues
    /// at its last read spot instead of jumping to the beginning.
    func choose(_ entry: LawEntry) async {
        guard entry.id != selectedID else { return }
        endCrossTrail()
        await resume(entry)
    }
    /// Continues `entry` where it was read (B10): the remembered version if
    /// the catalogue still has it (otherwise the current one), the section,
    /// and text or PDF with its page. The scroll offset is not restored yet.
    /// `spot`: another remembered place of `entry` (the way back after a citation).
    func resume(_ entry: LawEntry, at place: LawReadingSpot? = nil) async {
        let spot = place ?? laws.readingSpot(law: entry.id)
        let version = spot?.versionId.flatMap { id in entry.versions.contains { $0.id == id } ? id : nil }
        // A request after this one (e.g. a citation jump) keeps its own place.
        guard await open(entry, version: version, target: spot?.sectionId, resume: true) == .opened else { return }
        // Only a PDF already on this iPad: reopening never starts a large download.
        let request = requestID
        guard spot?.view == .pdf, selectedID == entry.id, !viewPDF, let doc = document,
              await laws.pdfIsOffline(entry, version: doc.version), selectedID == entry.id, requestID == request else { return }
        pdfTarget = spot?.pdfPage
        await togglePDF()
        // No PDF (offline, missing): the text stays without an error line.
        if !viewPDF { pdfTarget = nil; loadError = "" }
    }
    /// Remembers where the reader is; the current version is stored as nil,
    /// so a newer version opens once it arrives.
    func rememberReading() {
        guard !selectedID.isEmpty, !sectionID.isEmpty, let doc = document else { return }
        let current = entry?.currentVersion == doc.version
        laws.rememberReading(LawReadingSpot(lawId: selectedID, versionId: current ? nil : doc.version, view: viewPDF ? .pdf : .text,
                                            sectionId: sectionID, pdfPage: viewPDF ? pdfPage : nil))
    }
    /// `resume`: a remembered target that no longer exists opens the beginning
    /// silently instead of reporting a missing citation.
    @discardableResult
    func open(_ entry: LawEntry, version: String? = nil, target: String? = nil, paragraph: String? = nil, resume: Bool = false, from field: LawLookupField? = nil) async -> LawOpenOutcome {
        let request = UUID(); requestID = request
        endCrossTrail()
        loading = true; loadError = ""
        defer { if requestID == request { loading = false } }
        let measurement = Diagnostics.begin("law.load")
        do {
            let doc = try await laws.document(entry, version: version)
            guard !Task.isCancelled, requestID == request else { return .superseded }
            Diagnostics.end(measurement, ["sections": doc.sections.count])
            let found = target.flatMap { key in doc.sections.first { $0.id == key || $0.keys.contains(key) } }
            if target != nil && found == nil && !resume { loadError = "Diese Fundstelle ist in dieser Fassung nicht vorhanden."; return .missingSection }
            textSelection.clear()
            selectedID = entry.id; versionID = doc.version; document = doc
            let shown = found ?? doc.sections.first
            sectionID = shown?.id ?? ""; jump(to: paragraph)
            pdfURL = nil; viewPDF = false; pdfTarget = nil
            follow(shown, from: field)
            return .opened
        } catch {
            Diagnostics.failure("law.load", error)
            guard requestID == request else { return .superseded }
            loadError = error.localizedDescription
            return .failed
        }
    }
    /// Another place chosen by hand: „Zurück zu § …“ is no longer offered,
    /// and „Zurück zur Notiz“ follows its own rule again (`citationNavigated`).
    func endCrossTrail() {
        if !crossNavigating, !crossBack.isEmpty { crossBack = [] }
    }
    /// Scrolls the text to an Absatz of the shown section (again, if it is the
    /// same) and highlights it; nil just ends a pending target.
    func jump(to paragraph: String?) {
        jumpParagraph = paragraph; restoreOffset = nil
        if paragraph != nil { jumpSerial += 1 }
    }
    /// Puts the text back at an earlier offset (way back), once the section shows.
    func restore(offset: CGFloat) {
        jumpParagraph = nil; restoreOffset = offset; jumpSerial += 1
    }
    func search(_ value: String, allowFullText: Bool = false, bareReference: Bool = true, from field: LawLookupField) async {
        if let target = LawQuickTarget.parse(value, entries: laws.entries), let entry = laws.entries.first(where: { $0.id == target.lawID }) {
            await open(entry, target: target.reference.key, paragraph: target.reference.paragraph, from: field)
        } else if bareReference, let ref = LawReference.parse(value), let entry {
            if let doc = document, let s = doc.sections.first(where: { $0.keys.contains(ref.key) }) {
                showSection(s, from: field)
                jump(to: ref.paragraph)
            } else { await open(entry, version: document?.version, target: ref.key, paragraph: ref.paragraph, from: field) }
        } else if allowFullText, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let doc = document else { loadError = "Bitte zuerst ein Gesetz wählen."; return }
            let term = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            // Every section with the words, for the hit stepper; the first one
            // opens. Off the main thread over text folded once per version.
            let generation = LawFullTextSearch.begin()
            let positions = await LawFullTextSearch.sections(in: doc, lawID: selectedID, containing: term)
            // A newer search, another law or version meanwhile: this result is dropped.
            guard LawFullTextSearch.isCurrent(generation), document?.version == doc.version, document?.id == doc.id else { return }
            let found = positions.compactMap { doc.sections.indices.contains($0) ? doc.sections[$0] : nil }
            if field == .query { hits = found.map(\.id); hitTerm = value }
            if let first = found.first {
                showSection(first, from: field)
            } else { loadError = "„\(value)“ wurde in \(entry?.abbr ?? "diesem Dokument") nicht gefunden." }
        }
    }
    /// Return in the search field: a new term searches, the same term goes to the next hit.
    func submitQuery() async {
        if !hits.isEmpty, query == hitTerm { stepHit(1); return }
        await search(query, allowFullText: true, from: .query)
    }
    /// Previous/next section among the hits, wrapping around; from a section
    /// outside the hits the nearest one in that direction.
    func stepHit(_ delta: Int) {
        guard !hits.isEmpty, let sections = document?.sections else { return }
        endCrossTrail()
        let next: Int
        if let i = hits.firstIndex(of: sectionID) {
            next = (i + delta % hits.count + hits.count) % hits.count
        } else {
            let order = Dictionary(sections.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
            let here = order[sectionID] ?? -1
            let positions = hits.map { order[$0] ?? -1 }
            next = delta > 0 ? (positions.firstIndex { $0 > here } ?? 0) : (positions.lastIndex { $0 < here } ?? hits.count - 1)
        }
        guard let target = sections.first(where: { $0.id == hits[next] }) else { return }
        showSection(target, from: .query)
    }
    func togglePDF() async {
        guard let entry, let doc = document else { return }
        // A jump target belongs to the text view it was meant for: the text
        // view made anew after the PDF must not replay it.
        jumpParagraph = nil; restoreOffset = nil
        if viewPDF { viewPDF = false; pdfTarget = pdfPage; return }
        guard section?.pdf != nil || pdfTarget != nil else { loadError = LawReaderView.noPDFPosition; return }
        let id = requestID
        do { let url = try await laws.pdf(entry, version: doc.version); guard requestID == id else { return }; textSelection.clear(); pdfURL = url; viewPDF = true; loadError = "" }
        catch { loadError = error.localizedDescription }
    }
}

/// Full-text search of the law reader: section texts lowercased once per law
/// version (the last few kept), searched in a detached task, so Return in the
/// search field no longer folds megabytes of law text on the main thread.
/// Same match as before: label, title, text and notes joined by spaces.
enum LawFullTextSearch {
    @MainActor private static var generation = 0
    @MainActor static func begin() -> Int { generation &+= 1; return generation }
    @MainActor static func isCurrent(_ value: Int) -> Bool { value == generation }

    private actor Folded {
        private var entries: [(key: String, sections: [String])] = []
        func sections(_ key: String, build: @Sendable () -> [String]) -> [String] {
            if let hit = entries.first(where: { $0.key == key }) { return hit.sections }
            let folded = build()
            entries.append((key, folded))
            if entries.count > 3 { entries.removeFirst() }
            return folded
        }
    }
    private static let folded = Folded()

    /// Positions of the sections (in document order) whose joined, lowercased text contains `term`.
    static func sections(in doc: LawDocument, lawID: String, containing term: String) async -> [Int] {
        let key = "\(lawID)|\(doc.id)|\(doc.version)|\(doc.sections.count)"
        return await Task.detached(priority: .userInitiated) {
            let sections = await folded.sections(key) {
                doc.sections.map { "\($0.label) \($0.title) \($0.text) \($0.notes)".lowercased() }
            }
            return sections.indices.filter { sections[$0].contains(term) }
        }.value
    }
}
