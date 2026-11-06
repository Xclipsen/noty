import SwiftUI
import NotebookCore

/// „Apple Kalender und Outlook“ (Stufe C) inside the connection sheet:
/// connect consciously (asks iPadOS for full calendar access once), show or
/// hide single calendars, choose the preselected target of new events,
/// read anew, switch off. Outlook appears when the Microsoft 365/Exchange
/// account is added under iPad-Einstellungen › Apps › Kalender › Accounts.
struct CalendarSystemSection: View {
    @ObservedObject var model: CalendarModel
    @State private var working = false
    @State private var failure: String?

    var body: some View {
        Section {
            if !model.systemEnabled {
                Button {
                    run { await model.connectSystemCalendars() }
                } label: {
                    Label("Apple Kalender und Outlook verbinden …", systemImage: "calendar.badge.plus")
                }
            } else if let problem = model.systemAccess.problem {
                Label(problem, systemImage: "lock").foregroundStyle(.orange)
                Button("iPad-Einstellungen öffnen") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
                Button("Ausschalten", role: .destructive) { run { await model.disconnectSystemCalendars() } }
            } else {
                if let status = model.systemStatusText { Label(status, systemImage: model.systemReading ? "arrow.triangle.2.circlepath" : "checkmark.circle") }
                ForEach(groups, id: \.0) { account, calendars in
                    DisclosureGroup(account.isEmpty ? "Weitere" : account) {
                        ForEach(calendars) { item in
                            Toggle(isOn: Binding(get: { !model.hiddenSystemCalendars.contains(item.id) },
                                                 set: { shown in Task { await model.setSystemCalendar(item.id, shown: shown) } })) {
                                HStack(spacing: 8) {
                                    Circle().fill(color(item.colorHex)).frame(width: 10, height: 10)
                                    Text(item.title)
                                    if !item.writable { Image(systemName: "lock").font(.caption).foregroundStyle(.secondary).accessibilityLabel("schreibgeschützt") }
                                }
                            }
                        }
                    }
                }
                Picker("Neue Termine in", selection: Binding(get: { model.systemDefaultTarget },
                                                            set: { target in Task { await model.setDefaultWriteTarget(target) } })) {
                    Text("Persönlich (noty)").tag(CalendarWriteTarget.local)
                    ForEach(model.writableSystemCalendars) { Text($0.displayName).tag(CalendarWriteTarget.system(calendarID: $0.id)) }
                }
                Button("Jetzt neu einlesen") { model.reloadSystemCalendars() }.disabled(model.systemReading)
                Button("Ausschalten", role: .destructive) { run { await model.disconnectSystemCalendars() } }
            }
            if let failure { Label(failure, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
        } header: {
            Text("Apple Kalender und Outlook")
        } footer: {
            Text("noty liest die Kalender dieses iPads – auch Outlook bzw. Microsoft 365, wenn das Konto unter iPad-Einstellungen › Apps › Kalender › Accounts hinzugefügt ist. Termine, die du in noty einem dieser Kalender zuordnest, trägt iPadOS dort ein; den Abgleich mit dem Konto übernimmt das iPad. Notizen bleiben in noty. „Ausschalten“ entfernt keine Termine und keine Notizen.")
        }
        .disabled(working)
    }

    private var groups: [(String, [CalendarSystemCalendar])] {
        Dictionary(grouping: model.systemCalendars, by: \.account).map { ($0.key, $0.value) }.sorted { $0.0 < $1.0 }
    }

    private func color(_ hex: String) -> Color {
        guard let c = CalendarColorHex.components(hex) else { return .gray }
        return Color(red: c.red, green: c.green, blue: c.blue)
    }

    private func run(_ action: @escaping () async -> String?) {
        working = true
        failure = nil
        Task {
            failure = await action()
            working = false
        }
    }
}

/// Homework from WebUntis (offline timetable) with the local „erledigt“
/// mark. Presentable by the calendar views; the mark is never sent to WebUntis.
struct CalendarHomeworkList: View {
    @ObservedObject var model: CalendarModel
    @State private var showsDone = false

    var body: some View {
        let items = model.homework.filter { showsDone || !$0.done }
        List {
            if model.homework.isEmpty {
                Text(model.connection == nil ? "Hausaufgaben kommen aus WebUntis. Bitte zuerst WebUntis verbinden."
                     : "Im geladenen Zeitraum liefert WebUntis keine Hausaufgaben.")
                    .foregroundStyle(.secondary)
            }
            ForEach(items) { item in
                Button {
                    Task { await model.setHomeworkDone(item.id, done: !item.done) }
                } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: item.done ? "checkmark.circle.fill" : "circle").foregroundStyle(item.done ? .green : .secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.homework.subject ?? "Hausaufgabe").font(.subheadline.weight(.semibold))
                            Text(item.homework.text.isEmpty ? "ohne Text" : item.homework.text).strikethrough(item.done)
                            if let remark = item.homework.remark { Text(remark).font(.footnote).foregroundStyle(.secondary) }
                            Text("fällig " + CalendarText.longDate(item.homework.due.start(in: model.calendar), calendar: model.calendar)
                                 + (item.homework.completedInSource ? " · in WebUntis als erledigt markiert" : ""))
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityValue(item.done ? "erledigt" : "offen")
            }
        }
        .toolbar { Toggle("Erledigte zeigen", isOn: $showsDone) }
    }
}
