import SwiftUI
import NotebookCore

struct RestoredCopiesView: View {
    let copies: [RestoredNotebook]
    var onSelect: (RestoredNotebook) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    private var filtered: [RestoredNotebook] {
        copies.filter { copy in
            search.isEmpty || copy.title.localizedCaseInsensitiveContains(search)
                || copy.textPages.contains { $0.text.localizedCaseInsensitiveContains(search) }
        }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(filtered) { copy in
                    Section {
                        Button("Öffnen") { onSelect(copy) }.keyOption(.action { onSelect(copy) })
                        ForEach(copy.textPages) { preview in
                            let open = {
                                var selected = copy
                                selected.preferredPageID = preview.id
                                onSelect(selected)
                            }
                            Button(action: open) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Seite \(preview.pageNumber) öffnen").font(.subheadline.bold())
                                    Text(preview.text).foregroundStyle(.primary).lineLimit(3)
                                }
                            }.keyOption(.action(open))
                        }
                    } header: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(copy.title).lineLimit(2).truncationMode(.middle).textCase(nil).help(copy.title)
                            if let date = copy.modifiedAt {
                                Text(date, format: .dateTime.day().month().year().hour().minute().second()).monospacedDigit()
                            }
                        }
                    }
                }
            }
            .overlay {
                if filtered.isEmpty {
                    if search.isEmpty {
                        ContentUnavailableView("Keine wiederhergestellten Kopien", systemImage: "clock.arrow.circlepath",
                            description: Text("Aus einem Backup wiederhergestellte Hefte erscheinen hier."))
                    } else { ContentUnavailableView.search(text: search) }
                }
            }
            .searchable(text: $search, prompt: "Name oder Vorschautext")
            .navigationTitle("Wiederhergestellte Kopien")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() } } }
        }
        .keyboardSheet()
    }
}
