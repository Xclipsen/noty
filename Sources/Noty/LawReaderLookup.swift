import SwiftUI
import NotebookCore

/// Last read section per law and the last law, so reopening a law, a notebook
/// or the app continues there instead of at the beginning. Display state only.
enum LawReadingPosition {
    static let sectionsKey = "noty.laws.readingSections"
    static let lastKey = "noty.laws.lastLaw"
    static func section(_ law: String) -> String? {
        (UserDefaults.standard.dictionary(forKey: sectionsKey) as? [String: String])?[law]
    }
    static var lastLaw: String? { UserDefaults.standard.string(forKey: lastKey) }
    static func remember(law: String, section: String) {
        var all = UserDefaults.standard.dictionary(forKey: sectionsKey) as? [String: String] ?? [:]
        guard all[law] != section || lastLaw != law else { return }
        all[law] = section
        UserDefaults.standard.set(all, forKey: sectionsKey)
        UserDefaults.standard.set(law, forKey: lastKey)
    }
}

/// Which input started a lookup; that field keeps what was typed there.
enum LawLookupField { case query, number }

extension LawReaderView {
    /// Opens the law and section the reader showed last (or the first law).
    func openInitial() async {
        guard selectedID.isEmpty, !loading,
              let entry = laws.entries.first(where: { $0.id == LawReadingPosition.lastLaw }) ?? laws.entries.first else { return }
        await open(entry, target: LawReadingPosition.section(entry.id), resume: true)
    }
    /// Picking the current law keeps the reading position; another law continues
    /// at its last read section instead of jumping to the beginning.
    func choose(_ entry: LawEntry) async {
        guard entry.id != selectedID else { return }
        await open(entry, target: LawReadingPosition.section(entry.id), resume: true)
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
                textSelection.clear()
                pdfTarget = nil; sectionID = s.id; jumpParagraph = ref.paragraph; loadError = ""
                follow(s, from: field)
            } else { await open(entry, version: document?.version, target: ref.key, paragraph: ref.paragraph, from: field) }
        } else if allowFullText, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let doc = document else { loadError = "Bitte zuerst ein Gesetz wählen."; return }
            let term = value.lowercased()
            if let found = doc.sections.first(where: { ("\($0.label) \($0.title) \($0.text) \($0.notes)").lowercased().contains(term) }) {
                textSelection.clear()
                sectionID = found.id; jumpParagraph = nil; loadError = ""
                follow(found, from: field)
            } else { loadError = "„\(value)“ wurde in \(entry?.abbr ?? "diesem Dokument") nicht gefunden." }
        }
    }
    func togglePDF() async {
        guard let entry, let doc = document else { return }
        if viewPDF { viewPDF = false; pdfTarget = pdfPage; return }
        guard section?.pdf != nil || pdfTarget != nil else { loadError = "Keine eindeutig zugeordnete PDF-Fundstelle; der Lesetext bleibt geöffnet."; return }
        let id = requestID
        do { let url = try await laws.pdf(entry, version: doc.version); guard requestID == id else { return }; textSelection.clear(); pdfURL = url; viewPDF = true; loadError = "" }
        catch { loadError = error.localizedDescription }
    }
}
