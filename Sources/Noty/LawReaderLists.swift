import SwiftUI
import NotebookCore

extension LawReaderView {
    var lawList: some View {
        NavigationStack {
            List(laws.entries) { entry in
                Button("\(entry.abbr) · \(entry.name)") { pick(entry) }.keyOption(.action { pick(entry) })
            }.navigationTitle("Gesetz wählen")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fertig") { showLaws = false } } }
        }
    }
    private func pick(_ entry: LawEntry) {
        showLaws = false
        Task { await choose(entry) }
    }
    func toggleBookmark() {
        if let existing = bookmarkItem { Task { await laws.remove(existing) }; return }
        guard let doc = document, let section else { return }
        var payload = basePayload(doc)
        payload["sectionId"] = .string(section.id); payload["view"] = .string(viewPDF ? "pdf" : "text")
        if viewPDF { payload["page"] = .number(Double(pdfPage)) }
        payload["label"] = .string(viewPDF ? "\(doc.abbr) · PDF-Seite \(pdfPage)" : "\(doc.abbr) · \(section.label) \(section.title)")
        Task { await laws.save(kind: "bookmark", payload: payload) }
    }
    var contents: some View {
        NavigationStack {
            List(document?.sections ?? []) { s in
                let open = { textSelection.clear(); pdfTarget = nil; sectionID = s.id; jumpParagraph = nil; follow(s); showContents = false }
                Button(action: open) {
                    VStack(alignment: .leading) { Text(s.label).font(.headline); Text(s.title).font(.caption) }
                }.keyOption(.action(open))
            }.navigationTitle("Inhaltsverzeichnis")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fertig") { showContents = false } } }
        }
    }
    /// Lesezeichen und Markierungen: `LawMarkListView.swift` (Paket A2).
    var bookmarks: some View { markList }
}
