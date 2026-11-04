import SwiftUI
import NotebookCore

/// Kalender B3, menu „…“ › „Erinnerungen …“: the general lesson reminder
/// (off by default; cancelled lessons never), the permission state with a
/// hint to the iPad settings, and how far ahead reminders are planned
/// (iPadOS keeps only about 64 pending notifications per app).
struct CalendarReminderSettingsSheet: View {
    @ObservedObject var model: CalendarModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    private var lessonBinding: Binding<Int> {
        Binding(get: { model.lessonReminderMinutes ?? 0 },
                set: { value in Task { await model.setLessonReminder(value == 0 ? nil : value) } })
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Unterricht", selection: lessonBinding) {
                        Text("Keine Erinnerung").tag(0)
                        ForEach(CalendarReminder.lessonPresets, id: \.self) { Text("\($0) Minuten vorher").tag($0) }
                    }
                    .disabled(!model.canWrite)
                } footer: {
                    Text("Für WebUntis-Stunden aus dem Offline-Stundenplan dieses Bereichs; ausgefallene Stunden erhalten keine Erinnerung. Erinnerungen für eigene Termine stellst du im Termin ein.")
                }
                Section {
                    switch model.reminderPermission {
                    case .denied:
                        Label("Mitteilungen für noty sind ausgeschaltet. Erinnerungen erscheinen erst, wenn sie in den iPad-Einstellungen › Mitteilungen › noty erlaubt sind.",
                              systemImage: "bell.slash").foregroundStyle(.orange)
                        Button("iPad-Einstellungen öffnen") {
                            if let url = URL(string: UIApplication.openNotificationSettingsURLString) { openURL(url) }
                        }
                    case .notDetermined:
                        Label("noty fragt nach der Erlaubnis für Mitteilungen, sobald du eine Erinnerung einschaltest.", systemImage: "bell")
                    case .allowed:
                        Label("Mitteilungen erlaubt", systemImage: "bell.badge")
                    }
                    if let until = model.remindersPlannedUntil {
                        Label(model.plannedReminderCount == 0
                              ? "Keine anstehenden Erinnerungen bis \(CalendarText.numericDate(until, calendar: model.calendar))"
                              : "\(NotyText.count(model.plannedReminderCount, "Erinnerung", "Erinnerungen")) geplant bis \(CalendarText.numericDate(until, calendar: model.calendar)) \(CalendarText.clock(until, calendar: model.calendar))",
                              systemImage: "calendar.badge.clock")
                    } else {
                        Label("Keine Erinnerung eingeschaltet", systemImage: "bell.slash")
                    }
                    if let error = model.reminderError { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                } footer: {
                    Text("iPadOS hält nur eine begrenzte Zahl geplanter Mitteilungen bereit. noty plant deshalb die nächsten (höchstens 50) und plant beim Öffnen der App, nach jeder Aktualisierung des Stundenplans und nach jeder Änderung neu. Nur der aktuell geöffnete Bereich erinnert.")
                }
            }
            .navigationTitle("Erinnerungen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() } } }
            .task { await model.refreshReminderPermission(); model.rescheduleReminders() }
        }
        .environment(\.locale, Locale(identifier: "de_DE"))
        .preferredColorScheme(.dark)
    }
}

/// Kalender B3, menu „…“ › „Gelöschte Termine …“: deleted own events and
/// single deleted occurrences of series, newest first. „Wiederherstellen“
/// brings the event back with its identity (its notes appear again);
/// „Endgültig entfernen“ removes only the entry, never a note.
struct CalendarDeletedEventsSheet: View {
    @ObservedObject var model: CalendarModel
    @Environment(\.dismiss) private var dismiss
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
                Task { failure = await model.restoreDeleted(entry.id) }
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
            Button("Wiederherstellen", systemImage: "arrow.uturn.backward") { Task { failure = await model.restoreDeleted(entry.id) } }
            Button("Endgültig entfernen", systemImage: "trash", role: .destructive) { Task { await model.purgeDeleted([entry.id]) } }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: "Wiederherstellen") { Task { failure = await model.restoreDeleted(entry.id) } }
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
