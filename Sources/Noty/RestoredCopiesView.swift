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
                        Button("Heft öffnen") { onSelect(copy) }
                        ForEach(copy.textPages) { preview in
                            Button {
                                var selected = copy
                                selected.preferredPageID = preview.id
                                onSelect(selected)
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Seite \(preview.pageNumber) öffnen").font(.subheadline.bold())
                                    Text(preview.text).foregroundStyle(.primary).lineLimit(3)
                                }
                            }
                        }
                    } header: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(copy.title)
                            if let date = copy.modifiedAt {
                                Text(date, format: .dateTime.day().month().year().hour().minute().second())
                            }
                        }
                    }
                }
            }
            .searchable(text: $search, prompt: "Name oder Vorschautext")
            .navigationTitle("Wiederhergestellte Kopien")
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button("Schließen") { dismiss() } } }
        }
    }
}
