import SwiftUI
import NotebookCore

/// „Lernfeld-Heft wählen“ (Einstellungen › Kalender › Lernfelder,
/// docs/LERNFELDER.md): an existing notebook of the library becomes the
/// notebook of a Lernfeld. Nothing is written into it until the next lesson
/// note; that section then goes to its end.
struct CalendarFieldNotebookPicker: View {
    let field: CalendarStudyField
    @ObservedObject var model: CalendarModel
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    private var candidates: [NotebookCore.LibraryItem] {
        model.fieldNotebookCandidates(for: field).filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        NavigationStack {
            List(candidates) { item in
                Button {
                    Task { await model.setFieldNotebook(item, for: field.id) }
                    dismiss()
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "book.closed").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title).lineLimit(2).truncationMode(.middle)
                            Text(path(of: item)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
            .overlay {
                if candidates.isEmpty {
                    if search.isEmpty {
                        ContentUnavailableView("Kein Heft frei", systemImage: "book.closed",
                                               description: Text("Lege zuerst ein Heft in der Bibliothek an oder importiere eines. Textdokumente, Kalendernotizen und Hefte anderer Lernfelder oder Fächer stehen nicht zur Wahl."))
                    } else { ContentUnavailableView.search(text: search) }
                }
            }
            .searchable(text: $search, prompt: "Heft suchen")
            .navigationTitle("Heft für \(field.shortName)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } } }
            .safeAreaInset(edge: .bottom) {
                Text(footer)
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .padding(.horizontal).padding(.vertical, 10).frame(maxWidth: .infinity).background(.bar)
            }
        }
        .keyboardSheet()
    }

    private var footer: String {
        let sections = model.fieldSectionCount(field)
        let base = "Ab der nächsten Mitschrift bekommt jede Stunde von \(field.shortName) in diesem Heft eine neue Seite mit Überschrift, hinter den vorhandenen Seiten. Das Heft selbst wird jetzt nicht verändert."
        guard sections > 0 else { return base }
        return base + " Die \(sections == 1 ? "eine bisherige Mitschrift bleibt" : "\(sections) bisherigen Mitschriften bleiben") im alten Heft und an ihren Stunden."
    }

    /// „Oberste Ebene“ or the folder titles from the top.
    private func path(of item: NotebookCore.LibraryItem) -> String {
        guard let snapshot = model.library?.snapshot else { return "" }
        var titles: [String] = [], parent = item.parentID, hops = 0
        while let id = parent, hops < 32, let folder = snapshot.items.first(where: { $0.id == id && $0.isFolder }) {
            titles.insert(folder.title, at: 0); parent = folder.parentID; hops += 1
        }
        return titles.isEmpty ? "Oberste Ebene" : titles.joined(separator: " › ")
    }
}
