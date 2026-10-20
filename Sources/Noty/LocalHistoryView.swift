import SwiftUI
import NotebookCore

struct LocalHistoryView: View {
    @ObservedObject var model: EditorModel
    var onSelect: (UUID) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var entries: [LocalRevision] = []
    @State private var loading = true
    @State private var unreadableCount = 0
    @State private var error: String?
    @State private var selectedID: UUID?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Heft: \(model.notebook.title)").font(.headline)
                    Text("Geöffnete Seite: \(model.pageIndex + 1)")
                    if !model.page.searchableText.isEmpty {
                        Text("Aktueller Text: \(String(model.page.searchableText.prefix(120)))")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(3)
                    }
                }
                Section {
                    ForEach(entries) { revision in
                        Button { selectedID = revision.id } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(revision.isLatest ? "Zuletzt gespeichert" : "Älterer Stand").font(.headline)
                                if selectedID == revision.id { Label("Ausgewählt", systemImage: "checkmark.circle.fill") }
                                Text(revision.title).foregroundStyle(.primary)
                                if let date = revision.savedAt {
                                    Text("\(date.formatted(.dateTime.day().month().year().hour().minute().second())) · \(date.formatted(.relative(presentation: .named)))")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Text("\(revision.pageCount) Seite(n) · als Kopie öffnen")
                                    .font(.caption).foregroundStyle(.secondary)
                            }.padding(.vertical, 4)
                        }.disabled(loading)
                    }
                } footer: {
                    Text("Aufbewahrt werden die drei jüngsten Stände und bis zu fünf ältere Zwischenstände im Abstand von mindestens 10 Minuten (zusammen höchstens 300 MB). Ein älterer Stand enthält spätere Änderungen noch nicht. Er öffnet sich als neue Kopie; das hier genannte Heft bleibt erhalten. Lokale Stände ersetzen kein externes Backup.")
                }
                if unreadableCount > 0 {
                    Text("\(unreadableCount) Stand/Stände nicht lesbar. Dateien bleiben erhalten.")
                }
                if let error { Text(error).foregroundStyle(.red) }
                if !loading && entries.isEmpty && error == nil {
                    Text("Noch keine vollständigen lokalen Stände vorhanden.")
                }
            }
            .overlay { if loading { ProgressView("Stände werden geprüft …") } }
            .safeAreaInset(edge: .bottom) {
                Button("Ausgewählten Stand als neue Kopie öffnen") {
                    if let id = selectedID { onSelect(id) }
                }
                .buttonStyle(.borderedProminent).disabled(selectedID == nil || loading)
                .padding().frame(maxWidth: .infinity).background(.bar)
            }
            .navigationTitle("Lokale Wiederherstellung")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Schließen") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Neu laden") { Task { await load() } }.disabled(loading)
                }
            }
            .task { await load() }
        }
    }

    private func load() async {
        loading = true
        error = nil
        defer { loading = false }
        do {
            let history = try await model.localHistory()
            entries = history.revisions
            if !entries.contains(where: { $0.id == selectedID }) { selectedID = nil }
            unreadableCount = history.unreadableCount
        } catch { self.error = error.localizedDescription }
    }
}
