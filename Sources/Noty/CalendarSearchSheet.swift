import SwiftUI
import NotebookCore

/// Search over the shown entries (own events, loaded timetable, system
/// calendars, or the samples); never silently limited.
struct CalendarSearchSheet: View {
    @ObservedObject var model: CalendarModel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    /// The search field takes the focus when the sheet opens.
    @State private var searchActive = false
    private static let shownLimit = 200

    var body: some View {
        NavigationStack {
            let results = model.search(query)
            List {
                ForEach(results.prefix(Self.shownLimit)) { event in
                    Button {
                        model.show(event)
                        dismiss()
                    } label: { CalendarListRow(event: event, model: model, showsDate: true) }
                    .accessibilityLabel(CalendarText.longDate(event.start, calendar: model.calendar) + ", "
                                        + model.accessibilityText(event, notes: model.hasNotes(event)))
                }
                if results.count > Self.shownLimit {
                    Text("\(results.count - Self.shownLimit) weitere Treffer – Suche genauer eingeben.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .overlay {
                if query.trimmingCharacters(in: .whitespaces).isEmpty {
                    ContentUnavailableView("Termine suchen", systemImage: "magnifyingglass",
                                           description: Text(model.showsSamples ? "Titel, Raum, Lehrkraft oder Beschreibung (Beispieldaten des angezeigten Jahres)."
                                                             : "Titel, Ort, Raum oder Beschreibung: eigene Termine (Serien im angezeigten Jahr) und geladener Stundenplan."))
                } else if results.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
            }
            .searchable(text: $query, isPresented: $searchActive, placement: .navigationBarDrawer(displayMode: .always), prompt: "Termine suchen")
            .task {
                // A sheet ignores a focus request before it is on screen.
                try? await Task.sleep(for: .milliseconds(150))
                searchActive = true
            }
            .navigationTitle("Suche")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Fertig") { dismiss() } } }
        }
        .preferredColorScheme(.dark)
    }
}
