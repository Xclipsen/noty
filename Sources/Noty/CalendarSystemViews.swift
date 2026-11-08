import SwiftUI
import NotebookCore

/// „Apple Kalender und Outlook“ as a sheet of the calendar (menu „…“,
/// „Verwalten …“ in the status popover); the same form as Einstellungen ›
/// Kalender › Apple Kalender und Outlook.
struct CalendarSystemSheet: View {
    @ObservedObject var model: CalendarModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            CalendarSystemForm(model: model)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() } } }
        }
        .preferredColorScheme(.dark)
    }
}

struct CalendarSystemForm: View {
    @ObservedObject var model: CalendarModel
    var body: some View {
        Form { CalendarSystemSection(model: model) }
            .navigationTitle("Apple Kalender und Outlook")
    }
}

/// „Apple Kalender und Outlook“ (Stufe C), one section of `CalendarSystemForm`:
/// connect consciously (asks iPadOS for full calendar access once), show or
/// hide single calendars, choose the preselected target of new events,
/// read anew, switch off. Outlook appears when the Microsoft 365/Exchange
/// account is added under iPad-Einstellungen › Apps › Kalender › Accounts.
struct CalendarSystemSection: View {
    @ObservedObject var model: CalendarModel
    @State private var working = false
    @State private var failure: String?
    /// Accounts whose calendars are unfolded (also by keys: Enter on the account).
    @State private var expanded: Set<String> = []

    var body: some View {
        Section {
            if !model.systemEnabled {
                Button { connect() } label: {
                    Label("Apple Kalender und Outlook verbinden …", systemImage: "calendar.badge.plus")
                }
                .keyOption(.action { connect() })
            } else if let problem = model.systemAccess.problem {
                Label(problem, systemImage: "lock").foregroundStyle(.orange)
                Button("iPad-Einstellungen öffnen") { openSettings() }
                    .keyOption(.action { openSettings() })
                Button("Ausschalten", role: .destructive) { disconnect() }
                    .keyOption(.action { disconnect() })
            } else {
                if let status = model.systemStatusText { Label(status, systemImage: model.systemReading ? "arrow.triangle.2.circlepath" : "checkmark.circle") }
                ForEach(groups, id: \.0) { account, calendars in
                    let unfolded = Binding(get: { expanded.contains(account) },
                                           set: { open in if open { expanded.insert(account) } else { expanded.remove(account) } })
                    DisclosureGroup(account.isEmpty ? "Weitere" : account, isExpanded: unfolded) {
                        ForEach(calendars) { item in
                            let shown = Binding(get: { !model.hiddenSystemCalendars.contains(item.id) },
                                                set: { shown in Task { await model.setSystemCalendar(item.id, shown: shown) } })
                            Toggle(isOn: shown) {
                                HStack(spacing: 8) {
                                    Circle().fill(color(item.colorHex)).frame(width: 10, height: 10)
                                    Text(item.title)
                                    if !item.writable { Image(systemName: "lock").font(.caption).foregroundStyle(.secondary).accessibilityLabel("schreibgeschützt") }
                                }
                            }
                            .keyOption(.toggle(shown))
                        }
                    }
                    .keyOption(.action { unfolded.wrappedValue.toggle() })
                }
                let target = Binding(get: { model.systemDefaultTarget },
                                     set: { target in Task { await model.setDefaultWriteTarget(target) } })
                Picker(selection: target) {
                    Text("Persönlich (noty)").tag(CalendarWriteTarget.local)
                    ForEach(model.writableSystemCalendars) { Text($0.displayName).tag(CalendarWriteTarget.system(calendarID: $0.id)) }
                } label: {
                    SettingLabel("Neue Termine in", detail: "Vorauswahl im Formular; jeder Termin lässt sich dort umstellen.")
                }
                .keyOption(.choice(target, [CalendarWriteTarget.local] + model.writableSystemCalendars.map { .system(calendarID: $0.id) }))
                Button("Jetzt neu einlesen") { model.reloadSystemCalendars() }
                    .keyOption(.action { model.reloadSystemCalendars() })
                    .disabled(model.systemReading)
                Button("Ausschalten", role: .destructive) { disconnect() }
                    .keyOption(.action { disconnect() })
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

    private func connect() { run { await model.connectSystemCalendars() } }
    private func disconnect() { run { await model.disconnectSystemCalendars() } }
    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
    }

    private func run(_ action: @escaping () async -> String?) {
        guard !working else { return }
        working = true
        failure = nil
        Task {
            failure = await action()
            working = false
        }
    }
}
