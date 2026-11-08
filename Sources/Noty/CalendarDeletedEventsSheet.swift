import SwiftUI
import NotebookCore

/// Kalender B3, menu „…“ › „Gelöschte Termine …“: deleted own events and
/// single deleted occurrences of series, newest first. „Wiederherstellen“
/// brings the event back with its identity (its notes appear again);
/// „Endgültig entfernen“ removes only the entry, never a note.
struct CalendarDeletedEventsSheet: View {
    @ObservedObject var model: CalendarModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.calendarLocalChange) private var localChange
    @State private var failure: String?
    @State private var confirmingEmpty = false

    var body: some View {
        NavigationStack {
            List {
                if let failure {
                    Section { Label(failure, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                }
                Section {
                    ForEach(model.deletedEvents) { entry in row(entry) }
                    if model.deletedEvents.isEmpty { Text("Keine gelöschten Termine.").foregroundStyle(.secondary) }
                } footer: {
                    Text("Gelöschte eigene Termine bleiben hier, bis du sie endgültig entfernst, und sind im Bibliotheksbackup enthalten. Notizen zu Terminen liegen weiter in „Kalendernotizen“ und werden nie mitgelöscht.")
                }
                if !model.deletedEvents.isEmpty {
                    Section {
                        Button("Alle endgültig entfernen …", systemImage: "trash.slash", role: .destructive) { confirmingEmpty = true }
                            .disabled(!model.canWrite)
                    }
                }
            }
            .navigationTitle("Gelöschte Termine")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() } } }
            .confirmationDialog("Alle gelöschten Termine endgültig entfernen?", isPresented: $confirmingEmpty, titleVisibility: .visible) {
                Button("\(NotyText.count(model.deletedEvents.count, "Eintrag", "Einträge")) endgültig entfernen", role: .destructive) {
                    Task { await model.purgeDeleted(Set(model.deletedEvents.map(\.id))) }
                }
                Button("Abbrechen", role: .cancel) {}
            } message: {
                Text("Die Termine lassen sich danach nicht mehr wiederherstellen. Notizen in „Kalendernotizen“ bleiben erhalten.")
            }
        }
        .environment(\.locale, Locale(identifier: "de_DE"))
        .preferredColorScheme(.dark)
    }

    private func row(_ entry: CalendarDeletedEvent) -> some View {
        HStack(spacing: CalendarSpace.m) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.event.title).lineLimit(1)
                Text(subtitle(entry)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            Button("Wiederherstellen") {
                localChange?.mark(); Task { failure = await model.restoreDeleted(entry.id) }
            }
            .buttonStyle(.borderless)
            .disabled(!model.canWrite)
        }
        .frame(minHeight: 44)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button("Endgültig entfernen", systemImage: "trash", role: .destructive) {
                Task { await model.purgeDeleted([entry.id]) }
            }
        }
        .contextMenu {
            Button("Wiederherstellen", systemImage: "arrow.uturn.backward") { localChange?.mark(); Task { failure = await model.restoreDeleted(entry.id) } }
            Button("Endgültig entfernen", systemImage: "trash", role: .destructive) { Task { await model.purgeDeleted([entry.id]) } }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: "Wiederherstellen") { localChange?.mark(); Task { failure = await model.restoreDeleted(entry.id) } }
    }

    private func subtitle(_ entry: CalendarDeletedEvent) -> String {
        let calendar = model.calendar
        let deleted = "gelöscht am \(CalendarText.numericDate(entry.deletedAt, calendar: calendar))"
        if let date = entry.occurrence {
            return "Ein Termin der Serie am \(CalendarText.numericDate(date.start(in: calendar), calendar: calendar)) · \(deleted)"
        }
        let interval = entry.event.timing.interval(in: calendar)
        var when = CalendarText.numericDate(interval.start, calendar: calendar)
        if !entry.event.timing.isAllDay { when += " " + CalendarText.clock(interval.start, calendar: calendar) }
        if let rule = entry.event.recurrence { when += " · " + rule.text }
        return when + " · " + deleted
    }
}
