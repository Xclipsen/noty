import SwiftUI
import NotebookCore

/// Which input started a lookup; that field keeps what was typed there.
enum LawLookupField { case query, number }

extension LawReaderView {
    /// Opens the law and section the reader showed last (or the first law).
    func openInitial() async {
        guard selectedID.isEmpty, !loading,
              let entry = laws.entries.first(where: { $0.id == laws.lastReadingSpot?.lawId }) ?? laws.entries.first else { return }
        await resume(entry)
    }
    /// Picking the current law keeps the reading position; another law continues
    /// at its last read spot instead of jumping to the beginning.
    func choose(_ entry: LawEntry) async {
        guard entry.id != selectedID else { return }
        await resume(entry)
    }
    /// Continues `entry` where it was read (B10): the remembered version if
    /// the catalogue still has it (otherwise the current one), the section,
    /// and text or PDF with its page. The scroll offset is not restored yet.
    /// `spot`: another remembered place of `entry` (the way back after a citation).
    func resume(_ entry: LawEntry, at place: LawReadingSpot? = nil) async {
        let spot = place ?? laws.readingSpot(law: entry.id)
        let version = spot?.versionId.flatMap { id in entry.versions.contains { $0.id == id } ? id : nil }
        await open(entry, version: version, target: spot?.sectionId, resume: true)
        // Only a PDF already on this iPad: reopening never starts a large download.
        guard spot?.view == .pdf, selectedID == entry.id, !viewPDF, let doc = document,
              await laws.pdfIsOffline(entry, version: doc.version), selectedID == entry.id else { return }
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
    func open(_ entry: LawEntry, version: String? = nil, target: String? = nil, paragraph: String? = nil, resume: Bool = false, from field: LawLookupField? = nil) async {
        let request = UUID(); requestID = request
        loading = true; loadError = ""
        defer { if requestID == request { loading = false } }
        do {
            let doc = try await laws.document(entry, version: version)
            guard !Task.isCancelled, requestID == request else { return }
            let found = target.flatMap { key in doc.sections.first { $0.id == key || $0.keys.contains(key) } }
            if target != nil && found == nil && !resume { loadError = "Diese Fundstelle ist in dieser Fassung nicht vorhanden."; return }
            textSelection.clear()
            selectedID = entry.id; versionID = doc.version; document = doc
            let shown = found ?? doc.sections.first
            sectionID = shown?.id ?? ""; jumpParagraph = paragraph
            pdfURL = nil; viewPDF = false; pdfTarget = nil
            follow(shown, from: field)
        } catch { if requestID == request { loadError = error.localizedDescription } }
    }
    func search(_ value: String, allowFullText: Bool = false, bareReference: Bool = true, from field: LawLookupField) async {
        if let target = LawQuickTarget.parse(value, entries: laws.entries), let entry = laws.entries.first(where: { $0.id == target.lawID }) {
            await open(entry, target: target.reference.key, paragraph: target.reference.paragraph, from: field)
        } else if bareReference, let ref = LawReference.parse(value), let entry {
            if let doc = document, let s = doc.sections.first(where: { $0.keys.contains(ref.key) }) {
                showSection(s, from: field)
                jumpParagraph = ref.paragraph
            } else { await open(entry, version: document?.version, target: ref.key, paragraph: ref.paragraph, from: field) }
        } else if allowFullText, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let doc = document else { loadError = "Bitte zuerst ein Gesetz wählen."; return }
            let term = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            // Every section with the words, for the hit stepper; the first one opens.
            let found = doc.sections.filter { "\($0.label) \($0.title) \($0.text) \($0.notes)".lowercased().contains(term) }
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
        if viewPDF { viewPDF = false; pdfTarget = pdfPage; return }
        guard section?.pdf != nil || pdfTarget != nil else { loadError = LawReaderView.noPDFPosition; return }
        let id = requestID
        do { let url = try await laws.pdf(entry, version: doc.version); guard requestID == id else { return }; textSelection.clear(); pdfURL = url; viewPDF = true; loadError = "" }
        catch { loadError = error.localizedDescription }
    }
}
