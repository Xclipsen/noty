import SwiftUI
import NotebookCore

/// Benachrichtigungen (08.11.2026; replaces the B3 „Erinnerungen …“ sheet),
/// menu „…“ › „Benachrichtigungen …“ and the gear of the bell: one switch
/// per kind (Stundenplanänderungen, Morgen-Überblick, Erinnerung vor
/// eigenen Terminen, Unterricht), the overview time, quiet hours, lead
/// time, the permission state (asked only when switched on or on
/// „Einschalten“) and how far ahead iPadOS has the notifications.
struct CalendarReminderSettingsSheet: View {
    @ObservedObject var model: CalendarModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    private var settings: CalendarNotificationSettings { model.notificationSettings }

    private var lessonBinding: Binding<Int> {
        Binding(get: { model.lessonReminderMinutes ?? 0 },
                set: { value in Task { await model.setLessonReminder(value == 0 ? nil : value) } })
    }

    private func toggle(_ path: WritableKeyPath<CalendarNotificationSettings, Bool>) -> Binding<Bool> {
        Binding(get: { model.notificationSettings[keyPath: path] },
                set: { value in model.updateNotificationSettings { $0[keyPath: path] = value } })
    }

    private func minutes(_ path: WritableKeyPath<CalendarNotificationSettings, Int>) -> Binding<Int> {
        Binding(get: { model.notificationSettings[keyPath: path] },
                set: { value in model.updateNotificationSettings { $0[keyPath: path] = value } })
    }

    /// A time of day (minutes after midnight) as a DatePicker value.
    private func clock(_ path: WritableKeyPath<CalendarNotificationSettings, Int>) -> Binding<Date> {
        let calendar = model.calendar
        return Binding(get: {
            let minute = model.notificationSettings[keyPath: path]
            return calendar.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: Date()) ?? Date()
        }, set: { date in
            let parts = calendar.dateComponents([.hour, .minute], from: date)
            let value = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
            model.updateNotificationSettings { $0[keyPath: path] = value }
        })
    }

    private func text(_ minute: Int) -> String { String(format: "%02d:%02d", minute / 60, minute % 60) }

    var body: some View {
        NavigationStack {
            Form {
                permissionSection
                Section {
                    Toggle(isOn: toggle(\.changes)) {
                        Label("Stundenplanänderungen", systemImage: "arrow.triangle.swap")
                    }
                    .disabled(model.connection == nil)
                } footer: {
                    Text(model.connection == nil
                         ? "Erst mit verbundenem WebUntis. Gemeldet werden Ausfall, Vertretung, Raumwechsel und verlegte Stunden, sobald noty sie beim Abrufen erkennt."
                         : "Ausfall, Vertretung, Raumwechsel und verlegte Stunden, sobald noty sie beim Abrufen erkennt – auch im Hintergrund, wenn iPadOS es zulässt. Verglichen werden nur Tage, die vorher und jetzt vollständig geladen wurden. Welche Änderungen WebUntis über den inoffiziellen Zugang wirklich meldet, ist für deine Schule noch nicht bestätigt.")
                }
                Section {
                    Toggle(isOn: toggle(\.overview)) {
                        Label("Morgen-Überblick", systemImage: "sun.horizon")
                    }
                    if settings.overview {
                        DatePicker("Uhrzeit", selection: clock(\.overviewMinute), displayedComponents: .hourAndMinute)
                    }
                } footer: {
                    Text(overviewFooter)
                }
                Section {
                    Toggle(isOn: toggle(\.eventReminders)) {
                        Label("Erinnerung vor eigenen Terminen", systemImage: "bell")
                    }
                    if settings.eventReminders {
                        Picker("Vorlaufzeit", selection: minutes(\.eventMinutes)) {
                            ForEach(CalendarNotificationSettings.eventPresets, id: \.self) { Text(CalendarReminder.text($0)).tag($0) }
                        }
                    }
                    Picker(selection: lessonBinding) {
                        Text("Keine Erinnerung").tag(0)
                        ForEach(CalendarReminder.lessonPresets, id: \.self) { Text("\($0) Minuten vorher").tag($0) }
                    } label: {
                        Label("Unterricht", systemImage: "graduationcap")
                    }
                    .disabled(!model.canWrite)
                } footer: {
                    Text("Eigene Termine mit Uhrzeit erinnern mit dieser Vorlaufzeit, wenn im Termin keine eigene Erinnerung eingestellt ist; eine Erinnerung im Termin hat Vorrang. Ganztägige Termine nur mit eigener Erinnerung. Termine aus Apple Kalender/Outlook erinnert der Systemkalender selbst. Unterricht ist standardmäßig ohne Erinnerung; ausgefallene Stunden erhalten nie eine.")
                }
                Section {
                    Toggle(isOn: toggle(\.quietHours)) {
                        Label("Ruhezeiten", systemImage: "moon")
                    }
                    if settings.quietHours {
                        DatePicker("Von", selection: clock(\.quietStart), displayedComponents: .hourAndMinute)
                        DatePicker("Bis", selection: clock(\.quietEnd), displayedComponents: .hourAndMinute)
                    }
                } footer: {
                    Text(settings.quietHours
                         ? "Von \(text(settings.quietStart)) bis \(text(settings.quietEnd)) keine Mitteilungen für Änderungen und Unterricht – Änderungen stehen dann nur in der Glocke. Erinnerungen an eigene Termine kommen trotzdem, weil du sie bewusst gesetzt hast."
                         : "Mitteilungen kommen zu jeder Uhrzeit.")
                }
                planSection
            }
            .navigationTitle("Benachrichtigungen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() } } }
            .task { await model.refreshReminderPermission(); model.rescheduleReminders() }
        }
        .environment(\.locale, Locale(identifier: "de_DE"))
        .preferredColorScheme(.dark)
    }

    private var overviewFooter: String {
        guard settings.overview else { return "An Schultagen eine Mitteilung mit erster Stunde und Raum, den Änderungen des Tages, fälligen Hausaufgaben und deinen Terminen." }
        var result = "An Tagen mit Unterricht oder Terminen: erste Stunde mit Raum, Änderungen des Tages, fällige Hausaufgaben (nur hier, keine eigene Mitteilung) und deine Termine. Am Wochenende, in den Ferien und an freien Tagen ohne Termine kommt keiner. Der Inhalt ist der Stand der letzten Aktualisierung."
        if settings.isQuiet(model.calendar.date(bySettingHour: settings.overviewMinute / 60, minute: settings.overviewMinute % 60, second: 0, of: Date()) ?? Date(), calendar: model.calendar) {
            result += " Die Uhrzeit liegt in den Ruhezeiten: der Überblick kommt um \(text(settings.quietEnd))."
        }
        return result
    }

    @ViewBuilder private var permissionSection: some View {
        Section {
            switch model.reminderPermission {
            case .denied:
                Label("Mitteilungen für noty sind ausgeschaltet. Benachrichtigungen erscheinen nur in der Glocke, bis sie in den iPad-Einstellungen › Mitteilungen › noty erlaubt sind.",
                      systemImage: "bell.slash").foregroundStyle(.orange)
                Button("iPad-Einstellungen öffnen") {
                    if let url = URL(string: UIApplication.openNotificationSettingsURLString) { openURL(url) }
                }
            case .notDetermined:
                Label("noty hat noch nicht um Erlaubnis für Mitteilungen gefragt. Bis dahin erscheinen Benachrichtigungen nur in der Glocke.",
                      systemImage: "bell")
                Button { Task { await model.enableNotifications() } } label: {
                    Label("Benachrichtigungen einschalten", systemImage: "bell.badge")
                }
            case .allowed:
                Label("Mitteilungen erlaubt", systemImage: "bell.badge")
            }
        }
    }

    @ViewBuilder private var planSection: some View {
        Section {
            if let until = model.remindersPlannedUntil {
                Label(model.plannedReminderCount == 0
                      ? "Nichts geplant bis \(CalendarText.numericDate(until, calendar: model.calendar))"
                      : "\(NotyText.count(model.plannedReminderCount, "Mitteilung", "Mitteilungen")) geplant bis \(CalendarText.numericDate(until, calendar: model.calendar)) \(CalendarText.clock(until, calendar: model.calendar))",
                      systemImage: "calendar.badge.clock")
            } else if model.plannedReminderCount > 0 {
                Label("\(NotyText.count(model.plannedReminderCount, "Mitteilung", "Mitteilungen")) geplant", systemImage: "calendar.badge.clock")
            } else {
                Label("Keine Mitteilung geplant", systemImage: "bell.slash")
            }
            if let error = model.reminderError { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
        } footer: {
            Text("iPadOS hält nur eine begrenzte Zahl geplanter Mitteilungen bereit. noty plant deshalb die Morgen-Überblicke der nächsten Tage und dann die nächsten Erinnerungen (zusammen höchstens 50) und plant beim Öffnen der App, nach jeder Aktualisierung des Stundenplans und nach jeder Änderung neu. Hintergrundaktualisierung ist nicht garantiert: iPadOS entscheidet, ob und wann noty im Hintergrund abrufen darf. Nur der geöffnete Bereich benachrichtigt. Der Verlauf der Glocke liegt nur auf diesem iPad und ist nicht im Backup.")
        }
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
