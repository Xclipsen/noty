import SwiftUI
import NotebookCore

/// Einstellungen › Kalender (docs/SETTINGS.md, „Kalender“): view, shown
/// calendars, connections, subject colours and Mitteilungen of the open
/// area's calendar. The model is the area's own (`WorkspaceLibraryHost`,
/// handed through `SettingsView`): no second model, no second writer. The
/// sub-pages are the views of the calendar's sheets, which stay as
/// shortcuts (menu „…“, bell, status popover).
struct CalendarSettingsPage: View {
    @ObservedObject var model: CalendarModel
    @ObservedObject var workspaces: WorkspaceAppModel
    /// A search hit's sub-page (`SettingsSearchItem.subpage`): opened once, then cleared.
    @Binding var open: SettingsSubpage?
    /// Links have no action a key could run: these open the same pages.
    @State private var showingColors = false
    @State private var showingWebUntis = false
    @State private var showingSystem = false
    @State private var showingNotifications = false
    @State private var showingStudy = false
    @State private var showingMaterials = false
    @ObservedObject private var materials = MaterialLibrary.shared
    /// „Untis-Zugang prüfen“ inside the Mitteilungen page.
    @State private var webUntisFromNotifications = false

    var body: some View {
        Form {
            if let error = model.storageError {
                Section { Label(error, systemImage: "lock.trianglebadge.exclamationmark").foregroundStyle(.orange) }
            }
            if model.showsSamples {
                Section {
                    Label("Der Kalender zeigt gerade Beispieldaten; Fachfarben sind solange gesperrt.", systemImage: "theatermasks")
                    Button("Beispieldaten ausblenden") { model.showsSamples = false }
                        .keyOption(.action { model.showsSamples = false })
                }
            }
            Section {
                Picker(selection: $model.weekDays) {
                    Text("Montag – Freitag").tag(5)
                    Text("Ganze Woche").tag(7)
                } label: {
                    SettingLabel("Wochentage", detail: "Was die Woche im Kalender zeigt.")
                }
                .keyOption(.choice($model.weekDays, [5, 7]))
                NavigationLink { colorsPage } label: {
                    SettingLabel("Fachfarben", detail: "Eine feste Farbe je Fach aus dem Stundenplan; eigene Termine bleiben grün.")
                }
                // Inside `.disabled`: the key option is off as well while the row is.
                .keyOption(.action { showingColors = true })
                .disabled(model.showsSamples || !model.canWrite)
            } header: { Text("Ansicht") } footer: { AreaScopeFooter(workspaces: workspaces) }
            Section {
                ForEach(model.listedSources) { source in
                    settingToggle(source.title, detail: detail(source), isOn: Binding(
                        get: { !model.hiddenSources.contains(source) },
                        set: { shown in if shown { model.hiddenSources.remove(source) } else { model.hiddenSources.insert(source) } }))
                }
            } header: { Text("Sichtbare Kalender") } footer: {
                AreaScopeFooter(workspaces: workspaces,
                                text: "Ausgeblendete Termine bleiben gespeichert; ihre Erinnerungen und Mitteilungen kommen weiter, und eine angetippte Mitteilung blendet ihren Kalender wieder ein. Auch in der Kalenderleiste und im Menü „…“ umschaltbar.")
            }
            Section {
                NavigationLink { webUntisPage } label: {
                    SettingLabel("WebUntis", detail: webUntisStatus)
                }
                .keyOption(.action { showingWebUntis = true })
                NavigationLink { systemPage } label: {
                    SettingLabel("Apple Kalender und Outlook", detail: systemStatus)
                }
                .keyOption(.action { showingSystem = true })
            } header: { Text("Verbindungen") } footer: { AreaScopeFooter(workspaces: workspaces) }
            Section {
                NavigationLink { CalendarStudySettingsPage(model: model) } label: {
                    SettingLabel("Lernfelder", detail: studySummary)
                }
                .keyOption(.action { showingStudy = true })
                NavigationLink { MaterialSettingsPage() } label: {
                    SettingLabel("Materialien", detail: materials.packages.isEmpty ? "Kein Materialpaket"
                                 : materials.packages.map(\.catalog.title).joined(separator: ", "))
                }
                .keyOption(.action { showingMaterials = true })
            } header: { Text("Schule") } footer: {
                Text("Stunden eines Lernfelds werden zu Abschnitten mit Überschrift im Heft des Lernfelds; Skripte, Videos und Paragrafen der Materialien lassen sich am Thema der Stunde festhalten.")
            }
            Section {
                NavigationLink { notificationsPage } label: {
                    SettingLabel("Mitteilungen", detail: notificationSummary)
                }
                .keyOption(.action { showingNotifications = true })
            } footer: {
                Text("Stundenplanänderungen, Morgen-Überblick, Erinnerungen und Ruhezeiten. Auch über die Glocke im Kalender erreichbar.")
            }
        }
        .navigationTitle(SettingsPage.calendar.title)
        .navigationDestination(isPresented: $showingColors) { colorsPage }
        .navigationDestination(isPresented: $showingWebUntis) { webUntisPage }
        .navigationDestination(isPresented: $showingSystem) { systemPage }
        .navigationDestination(isPresented: $showingNotifications) { notificationsPage }
        .navigationDestination(isPresented: $showingStudy) { CalendarStudySettingsPage(model: model) }
        .navigationDestination(isPresented: $showingMaterials) { MaterialSettingsPage() }
        .keyboardSheet()
        .task { await model.refreshReminderPermission() }
        // The push consent after connecting, if the WebUntis page was already left.
        .calendarPushOffer(model: model)
        .onAppear { openRequested(waiting: true) }
        .onChange(of: open) { _, _ in openRequested(waiting: false) }
    }

    /// Opens the sub-page a search hit asked for (after the page is in place).
    private func openRequested(waiting: Bool) {
        guard let page = open else { return }
        if waiting {
            Task { @MainActor in openRequested(waiting: false) }
            return
        }
        open = nil
        guard !model.connectionBusy else { return }
        showingColors = false; showingWebUntis = false; showingSystem = false; showingNotifications = false
        switch page {
        case .calendarColors: if !model.showsSamples && model.canWrite { showingColors = true }
        case .calendarWebUntis: showingWebUntis = true
        case .calendarSystem: showingSystem = true
        case .calendarNotifications: showingNotifications = true
        }
    }

    private var studySummary: String {
        let fields = model.studyFields.count, rules = model.state.studyRules.count, subjects = model.subjectNotebooks.count
        if fields == 0, subjects == 0 { return "Fächer des Stundenplans Lernfeldern oder eigenen Heften zuordnen" }
        var text = "\(fields) Lernfelder · \(rules) Zuordnungen"
        if subjects > 0 { text += " · \(NotyText.count(subjects, "Fach-Heft", "Fach-Hefte"))" }
        return text
    }

    // MARK: Sub-pages (the calendar's sheets without their frame)

    private var colorsPage: some View { CalendarColorsList(model: model).keyboardSheet() }
    private var webUntisPage: some View { CalendarWebUntisPage(model: model) }
    private var systemPage: some View { CalendarSystemForm(model: model).keyboardSheet() }
    private var notificationsPage: some View {
        CalendarNotificationSettingsForm(model: model) { webUntisFromNotifications = true }
            .navigationDestination(isPresented: $webUntisFromNotifications) { webUntisPage }
            .keyboardSheet()
    }

    // MARK: Texts

    private func detail(_ source: CalendarSource) -> String {
        switch source {
        case .timetable: "Unterricht aus WebUntis."
        case .personal: "Deine Termine in noty."
        case .holidays: "Schulferien und gesetzliche Feiertage in NRW."
        case .system: "Termine der eingeblendeten Kalender dieses iPads."
        }
    }

    private var webUntisStatus: String {
        guard let connection = model.connection else {
            return "Nicht verbunden. Stundenplan, Ferien und Hausaufgaben über die Untis-Mobile-Freigabe."
        }
        if model.credentialsMissing { return "\(connection.label) · auf diesem iPad neu verbinden" }
        if model.syncing { return "\(connection.label) · wird aktualisiert …" }
        if model.syncError != nil { return "\(connection.label) · Aktualisierung fehlgeschlagen" }
        return "\(connection.label) · " + (model.lastSuccess.map { model.standText($0) } ?? "noch nicht geladen")
    }

    private var systemStatus: String {
        guard model.systemEnabled else { return "Aus. Liest und schreibt die Kalender dieses iPads, auch Microsoft 365." }
        if let problem = model.systemAccess.problem { return problem }
        if let error = model.systemError { return error }
        if model.hiddenSources.contains(.system) { return "Verbunden · unter „Sichtbare Kalender“ ausgeblendet" }
        let shown = model.systemCalendars.filter { !model.hiddenSystemCalendars.contains($0.id) }.count
        return "Verbunden · " + NotyText.count(shown, "Kalender eingeblendet", "Kalender eingeblendet")
    }

    private var notificationSummary: String {
        switch model.reminderPermission {
        case .denied: return "In den iPad-Einstellungen ausgeschaltet; alles erscheint nur in der Glocke."
        case .notDetermined: return "Noch nicht eingeschaltet; alles erscheint nur in der Glocke."
        case .allowed: break
        }
        let settings = model.notificationSettings
        var parts: [String] = []
        if settings.changes && model.connection != nil { parts.append("Stundenplanänderungen") }
        if settings.overview { parts.append(String(format: "Morgen-Überblick um %02d:%02d", settings.overviewMinute / 60, settings.overviewMinute % 60)) }
        if settings.eventReminders { parts.append("Erinnerung " + CalendarReminder.text(settings.eventMinutes)) }
        if let lesson = model.lessonReminderMinutes { parts.append("Unterricht \(lesson) Minuten vorher") }
        return parts.isEmpty ? "Alle aus." : parts.joined(separator: ", ")
    }
}

/// Einstellungen › Kalender › WebUntis: the form, which is not left while it
/// connects (`model.connectionBusy`): the back button is hidden (that also
/// stops the swipe back) and Esc does nothing meanwhile.
private struct CalendarWebUntisPage: View {
    @ObservedObject var model: CalendarModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        CalendarWebUntisForm(model: model)
            .keyboardSheet(onCancel: { if !model.connectionBusy { dismiss() } })
    }
}

/// Einstellungen › Entwickler: the calendar's test and diagnosis tools,
/// moved out of the calendar (only where `DeveloperAccess.visible`):
/// „Beispieldaten anzeigen“, the planned count, the test tile and the
/// push diagnosis.
struct CalendarDeveloperSection: View {
    @ObservedObject var model: CalendarModel
    @ObservedObject private var center = CalendarSchoolDayCenter.shared
    @ObservedObject private var push = CalendarPushClient.shared
    /// Short id of the push registration (keychain, read on appear).
    @State private var deviceID: String?

    var body: some View {
        Section {
            settingToggle("Beispieldaten anzeigen",
                          detail: "Der Kalender zeigt nur frei erfundene Termine, „+“ ist gesperrt, nichts wird gespeichert. Für Vorführung und Designprüfung; die Marke neben dem Titel blendet sie wieder aus.",
                          isOn: $model.showsSamples)
            LabeledContent {
                Text(planText).monospacedDigit().multilineTextAlignment(.trailing)
            } label: {
                SettingLabel("Geplante Mitteilungen",
                             detail: "iPadOS hält nur etwa 64 je App: noty plant die Morgen-Überblicke der nächsten Tage, dann die nächsten Erinnerungen, zusammen höchstens 50, und plant beim Öffnen, nach jeder Aktualisierung und jeder Änderung neu.")
            }
            if let error = model.reminderError { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
        } header: { Text("Kalender") }
        if center.supported {
            Section {
                Button { center.startDemo() } label: { Label("Test-Kachel starten", systemImage: "play.rectangle") }
                    .disabled(!center.systemAllowed)
                    .keyOption(.action { center.startDemo() })
                if center.demoRunning {
                    Button { center.demoChange() } label: { Label("Änderung simulieren", systemImage: "bell.badge") }
                        .keyOption(.action { center.demoChange() })
                    Button(role: .destructive) { center.endDemo() } label: { Label("Test-Kachel beenden", systemImage: "stop.circle") }
                        .keyOption(.action { center.endDemo() })
                }
                LabeledContent("Echte Kachel", value: center.running ?? "läuft nicht")
                if let error = center.lastError { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
            } header: { Text("Schultag-Kachel") } footer: {
                Text("Die Test-Kachel zeigt Beispielstunden um die aktuelle Uhrzeit, unabhängig vom Stundenplan; „Änderung simulieren“ weckt den Bildschirm wie eine echte Änderung. Nichts wird gespeichert.")
            }
        }
        if push.availability != .otherChannel {
            Section {
                LabeledContent("Dienst", value: availabilityText)
                LabeledContent("Geräte-ID", value: deviceID ?? "keine")
                LabeledContent("Gewünscht", value: wantedText)
                LabeledContent("Registriert", value: push.state.registered ? "ja" : "nein")
                LabeledContent("Status", value: push.state.serverState ?? "–")
                LabeledContent("Verbindung", value: connectionText)
                LabeledContent("Letzter Kontakt", value: push.state.lastContact.map(NotyText.statusDate) ?? NotyText.never)
                if let problem = push.state.serverError { LabeledContent("Letzter Abruf des Servers", value: problem) }
                if let error = push.state.lastError { LabeledContent("Letzter Fehler", value: error) }
                if push.state.pendingDelete { LabeledContent("Abmeldung", value: "steht noch aus") }
                Button { Task { await push.sync(model, force: true) } } label: { Label("Jetzt abgleichen", systemImage: "arrow.triangle.2.circlepath") }
                    .disabled(push.working || !push.isOn(for: model))
                    .keyOption(.action { Task { await push.sync(model, force: true) } })
            } header: { Text("Push-Dienst") } footer: {
                Text("Geräte-ID gekürzt; das Geheimnis bleibt im Schlüsselbund. Server: \(CalendarPush.baseURL?.host() ?? "–").")
            }
            .task(id: push.state) { deviceID = Self.shortDeviceID() }
        }
    }

    private static func shortDeviceID() -> String? {
        let read = CalendarPushKeychain.read()
        if read.locked { return "Schlüsselbund gesperrt" }
        return read.credentials.map { String($0.deviceID.prefix(8)) + "…" }
    }

    private var planText: String {
        let calendar = model.calendar
        if let until = model.remindersPlannedUntil {
            return model.plannedReminderCount == 0
                ? "keine bis \(CalendarText.numericDate(until, calendar: calendar))"
                : "\(model.plannedReminderCount) bis \(CalendarText.numericDate(until, calendar: calendar)) \(CalendarText.clock(until, calendar: calendar))"
        }
        return model.plannedReminderCount > 0 ? "\(model.plannedReminderCount)" : "keine"
    }

    private var availabilityText: String {
        switch push.availability {
        case .available(let environment): "verfügbar (\(environment))"
        case .unavailable(let reason): "nicht verfügbar: \(reason)"
        case .otherChannel: "nur in noty und noty calendar"
        }
    }

    private var wantedText: String {
        switch push.state.wanted {
        case nil: "noch nicht gefragt"
        case true?: "ja" + (push.state.consentDate.map { ", Einwilligung \(NotyText.statusDate($0))" } ?? "")
        case false?: "nein"
        }
    }

    private var connectionText: String {
        guard let id = push.state.connectionID else { return "–" }
        return id == model.connection?.id ? "dieser Bereich" : "andere Verbindung"
    }
}
