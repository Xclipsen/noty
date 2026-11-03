import SwiftUI
import NotebookCore

extension LawReaderView {
    /// The one place to choose a law: plain list, the open law marked and in view.
    var lawList: some View {
        let term = lawFilter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let shown = term.isEmpty ? laws.entries : laws.entries.filter { entry in
            ([entry.abbr, entry.name] + (entry.aliases ?? [])).contains { $0.lowercased().contains(term) }
        }
        return NavigationStack {
            ScrollViewReader { proxy in
                List(shown) { entry in
                    let current = entry.id == selectedID
                    Button { pick(entry) } label: {
                        listRow(entry.abbr, detail: entry.name, current: current)
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(current ? Color.notyAccent.opacity(0.14) : Color.clear)
                    .accessibilityAddTraits(current ? .isSelected : [])
                    .id(entry.id)
                    .keyOption(.action { pick(entry) })
                }
                .listStyle(.plain)
                .overlay {
                    if laws.entries.isEmpty {
                        ContentUnavailableView("Noch keine Gesetze geladen", systemImage: "books.vertical",
                                               description: Text("Unter Einstellungen › Gesetzessammlung den Offlinebestand laden."))
                    } else if shown.isEmpty {
                        ContentUnavailableView.search(text: lawFilter)
                    }
                }
                .onAppear { DispatchQueue.main.async { proxy.scrollTo(selectedID, anchor: .center) } }
            }
            .searchable(text: $lawFilter, placement: .navigationBarDrawer(displayMode: .always), prompt: "Abkürzung oder Name")
            .navigationTitle("Gesetz wählen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fertig") { showLaws = false } } }
        }
        .onDisappear { lawFilter = "" }
    }
    private func pick(_ entry: LawEntry) {
        showLaws = false
        Task { await choose(entry) }
    }
    /// Row of the law list and the contents: name in bold, detail below, the
    /// current entry in the accent colour with a check mark.
    private func listRow(_ title: String, detail: String, current: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline).foregroundStyle(current ? Color.notyAccent : .primary)
                if !detail.isEmpty { Text(detail).font(.subheadline).foregroundStyle(.secondary).lineLimit(2) }
            }
            Spacer(minLength: 0)
            if current { Image(systemName: "checkmark").font(.body.weight(.semibold)).foregroundStyle(Color.notyAccent).accessibilityHidden(true) }
        }
        .padding(.vertical, 3).frame(minHeight: 44).contentShape(Rectangle())
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
    /// Contents of the open version: searchable, the shown section marked and in view.
    var contents: some View {
        let all = document?.sections ?? []
        let term = contentsFilter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let shown = term.isEmpty ? all : all.filter { s in
            s.label.lowercased().contains(term) || s.title.lowercased().contains(term) || s.keys.contains { $0.lowercased() == term }
        }
        return NavigationStack {
            ScrollViewReader { proxy in
                List(shown) { s in
                    let current = s.id == sectionID
                    let open = { showSection(s); showContents = false }
                    Button(action: open) { listRow(s.label, detail: s.title, current: current) }
                        .buttonStyle(.plain)
                        .listRowBackground(current ? Color.notyAccent.opacity(0.14) : Color.clear)
                        .accessibilityAddTraits(current ? .isSelected : [])
                        .id(s.id)
                        .keyOption(.action(open))
                }
                .listStyle(.plain)
                .overlay {
                    if document == nil {
                        ContentUnavailableView("Kein Gesetz geöffnet", systemImage: "list.bullet.indent", description: Text("Zuerst ein Gesetz wählen."))
                    } else if shown.isEmpty {
                        ContentUnavailableView.search(text: contentsFilter)
                    }
                }
                .onAppear { DispatchQueue.main.async { proxy.scrollTo(sectionID, anchor: .center) } }
            }
            .searchable(text: $contentsFilter, placement: .navigationBarDrawer(displayMode: .always), prompt: "Vorschrift oder Stichwort")
            .navigationTitle(document.map { "Inhalt · \($0.abbr)" } ?? "Inhaltsverzeichnis")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fertig") { showContents = false } } }
        }
        .onDisappear { contentsFilter = "" }
    }
    /// Lesezeichen und Markierungen: `LawMarkListView.swift` (Paket A2).
    var bookmarks: some View { markList }
}
