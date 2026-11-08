import SwiftUI
import NotebookCore

/// „Mitteilungen“ as a sheet of the calendar (menu „…“ › „Mitteilungen …“
/// and the gear of the bell); the same form as Einstellungen › Kalender ›
/// Mitteilungen.
struct CalendarNotificationSettingsSheet: View {
    @ObservedObject var model: CalendarModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            CalendarNotificationSettingsForm(model: model) {
                // „Untis-Zugang prüfen“: the WebUntis sheet follows once this one
                // is gone (the calendar view opens it when nothing else is
                // presented; the wish is dated).
                dismiss()
                Task {
                    try? await Task.sleep(for: .milliseconds(700))
                    model.requestConnectionSheet()
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() } } }
        }
        .preferredColorScheme(.dark)
    }
}

/// Mitteilungen (08.11.2026; one word for the function, the page and its
/// switches – the banners of iPadOS are Mitteilungen too; „Erinnerung“ only
/// for the lead time before a date): the permission state (asked only when
/// switched on or on „Einschalten“), one switch per kind (Stundenplan-
/// änderungen, „Auch bei geschlossener App“, Schultag-Kachel,
/// Morgen-Überblick, Erinnerung vor eigenen Terminen and vor dem
/// Unterricht) and the quiet hours, each with its explanation in the row.
/// Everything is a device preference (`CalendarNotificationPreferences`,
/// not in backups) except the lesson reminder, which belongs to the area's
/// calendar package. The planned count lives on the developer page.
struct CalendarNotificationSettingsForm: View {
    @ObservedObject var model: CalendarModel
    /// „Untis-Zugang prüfen“ of the push section: show the WebUntis form.
    let reconnect: () -> Void
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
        Form {
            permissionSection
            Section {
                settingToggle("Stundenplanänderungen",
                              detail: model.connection == nil
                                ? "Erst mit verbundenem WebUntis: Ausfall, Vertretung, Raumwechsel und verlegte Stunden."
                                : "Ausfall, Vertretung, Raumwechsel und verlegte Stunden, sobald noty sie beim Abrufen erkennt – auch im Hintergrund, wenn iPadOS es zulässt. Was WebUntis für deine Schule wirklich meldet, ist noch nicht bestätigt.",
                              isOn: toggle(\.changes))
                    .disabled(model.connection == nil)
            } header: { Text("Stundenplan") }
            CalendarPushSection(model: model, reconnect: reconnect)
            CalendarSchoolDaySection(model: model)
            Section {
                settingToggle("Morgen-Überblick", detail: overviewDetail, isOn: toggle(\.overview))
                if settings.overview {
                    DatePicker("Uhrzeit", selection: clock(\.overviewMinute), displayedComponents: .hourAndMinute)
                }
            }
            Section {
                settingToggle("Vor eigenen Terminen",
                              detail: "Für Termine mit Uhrzeit ohne eigene Erinnerung; eine Erinnerung im Termin hat Vorrang. Ganztägige Termine nur mit eigener Erinnerung, Termine aus Apple Kalender und Outlook erinnert der Systemkalender.",
                              isOn: toggle(\.eventReminders))
                if settings.eventReminders {
                    Picker("Vorlaufzeit", selection: minutes(\.eventMinutes)) {
                        ForEach(CalendarNotificationSettings.eventPresets, id: \.self) { Text(CalendarReminder.text($0)).tag($0) }
                    }
                    .keyOption(.choice(minutes(\.eventMinutes), CalendarNotificationSettings.eventPresets))
                }
                Picker(selection: lessonBinding) {
                    Text("Keine Erinnerung").tag(0)
                    ForEach(CalendarReminder.lessonPresets, id: \.self) { Text("\($0) Minuten vorher").tag($0) }
                } label: {
                    SettingLabel("Vor dem Unterricht",
                                 detail: "Je Bereich gespeichert, mit dem Kalender auch im Bibliotheksbackup. Ausgefallene Stunden erinnern nie.")
                }
                .keyOption(.choice(lessonBinding, [0] + CalendarReminder.lessonPresets))
                .disabled(!model.canWrite)
            } header: { Text("Erinnerung") }
            Section {
                settingToggle("Ruhezeiten",
                              detail: settings.quietHours
                                ? "Von \(text(settings.quietStart)) bis \(text(settings.quietEnd)) keine Mitteilungen zu Änderungen und Unterricht; Änderungen stehen dann nur in der Glocke. Erinnerungen an eigene Termine kommen trotzdem."
                                : "Mitteilungen kommen zu jeder Uhrzeit.",
                              isOn: toggle(\.quietHours))
                if settings.quietHours {
                    DatePicker("Von", selection: clock(\.quietStart), displayedComponents: .hourAndMinute)
                    DatePicker("Bis", selection: clock(\.quietEnd), displayedComponents: .hourAndMinute)
                }
            }
        }
        .navigationTitle("Mitteilungen")
        .environment(\.locale, Locale(identifier: "de_DE"))
        .task { await model.refreshReminderPermission(); model.rescheduleReminders() }
    }

    private var overviewDetail: String {
        guard settings.overview else { return "An Tagen mit Unterricht oder Terminen eine Mitteilung am Morgen." }
        var result = "An Tagen mit Unterricht oder Terminen: erste Stunde mit Raum, Änderungen des Tages, fällige Hausaufgaben und deine Termine, Stand der letzten Aktualisierung."
        if settings.isQuiet(model.calendar.date(bySettingHour: settings.overviewMinute / 60, minute: settings.overviewMinute % 60, second: 0, of: Date()) ?? Date(), calendar: model.calendar) {
            result += " Die Uhrzeit liegt in den Ruhezeiten: Der Überblick kommt um \(text(settings.quietEnd))."
        }
        return result
    }

    @ViewBuilder private var permissionSection: some View {
        Section {
            switch model.reminderPermission {
            case .denied:
                Label("Mitteilungen für noty sind in den iPad-Einstellungen ausgeschaltet. Bis du sie dort erlaubst, erscheint alles nur in der Glocke.",
                      systemImage: "bell.slash").foregroundStyle(.orange)
                Button("iPad-Einstellungen öffnen") {
                    if let url = URL(string: UIApplication.openNotificationSettingsURLString) { openURL(url) }
                }
                .keyOption(.action { if let url = URL(string: UIApplication.openNotificationSettingsURLString) { openURL(url) } })
            case .notDetermined:
                Label("noty hat noch nicht um Erlaubnis gefragt. Bis dahin erscheint alles nur in der Glocke.", systemImage: "bell")
                Button { Task { await model.enableNotifications() } } label: {
                    Label("Mitteilungen einschalten", systemImage: "bell.badge")
                }
                .keyOption(.action { Task { await model.enableNotifications() } })
            case .allowed:
                Label("Auf diesem iPad erlaubt", systemImage: "bell.badge")
            }
            if let error = model.reminderError { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
        } footer: {
            Text("Diese Einstellungen gelten für dieses iPad und kommen nicht ins Backup, außer der Erinnerung vor dem Unterricht. Mitteilungen kommen nur vom geöffneten Bereich; ob noty dafür im Hintergrund abrufen darf, entscheidet iPadOS. Der Verlauf der Glocke bleibt auf diesem iPad.")
        }
    }
}
