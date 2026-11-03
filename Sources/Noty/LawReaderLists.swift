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
    var bookmarks: some View {
        NavigationStack {
            List(laws.items.filter { !$0.deleted }) { item in
                HStack {
                    let go = {
                        guard let id = item.payload["lawId"]?.string, let entry = laws.entries.first(where: { $0.id == id }) else { return }
                        var target = item.payload["sectionId"]?.string
                        if case let .object(a) = item.payload["anchor"] { target = a["sectionId"]?.string }
                        let version = item.payload["versionId"]?.string
                        showBookmarks = false
                        Task {
                            await open(entry, version: version, target: target)
                            if item.payload["view"]?.string == "pdf", let page = item.payload["page"]?.int, let doc = document, doc.id == entry.id, doc.version == version {
                                let request = requestID
                                do { let url = try await laws.pdf(entry, version: doc.version); guard requestID == request else { return }; pdfURL = url; pdfTarget = page; viewPDF = true }
                                catch { loadError = error.localizedDescription }
                            }
                        }
                    }
                    Button(action: go) {
                        VStack(alignment: .leading) {
                            Text(item.payload["label"]?.string ?? "Markierung · \(item.payload["lawId"]?.string?.uppercased() ?? "")")
                            if case let .object(a) = item.payload["anchor"], let quote = a["quote"]?.string { Text(quote).font(.caption).lineLimit(2).foregroundStyle(.secondary) }
                            if item.dirty { Text("Lokal gespeichert").font(.caption2).foregroundStyle(.secondary) }
                        }
                    }.keyOption(.action(go))
                    Spacer()
                    Button(role: .destructive) { Task { await laws.remove(item) } } label: { Image(systemName: "trash") }.accessibilityLabel("Eintrag löschen")
                }
            }.navigationTitle("Lesezeichen & Markierungen")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fertig") { showBookmarks = false } } }
        }
    }
}
