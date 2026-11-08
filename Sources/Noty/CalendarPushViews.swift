import SwiftUI
import NotebookCore

// Push-Dienst (docs/PUSH.md): the consent before anything is uploaded and
// the section „Auch bei geschlossener App“ of the sheet „Benachrichtigungen“.

extension View {
    /// The consent (text and version `CalendarPush.consentVersion`) before
    /// the first upload. „Zustimmen“ registers; „Nicht jetzt“ keeps
    /// everything local and is not asked again (the switch in
    /// „Benachrichtigungen“ asks once more).
    func calendarPushConsent(isPresented: Binding<Bool>, model: CalendarModel) -> some View {
        alert(CalendarPush.consentTitle, isPresented: isPresented) {
            Button("Zustimmen") { Task { await CalendarPushClient.shared.enable(for: model) } }
            Button("Nicht jetzt", role: .cancel) {
                if CalendarPushClient.shared.state.wanted == nil { CalendarPushClient.shared.decline() }
            }
        } message: {
            Text(CalendarPush.consentText)
        }
    }
}

/// „Auch bei geschlossener App“: on/off (off deletes everything on the
/// server), status and a short explanation. Shown only in noty calendar.
struct CalendarPushSection: View {
    @ObservedObject var model: CalendarModel
    @ObservedObject private var push = CalendarPushClient.shared
    /// The sheet should close to show the WebUntis sheet („Untis-Zugang prüfen“).
    let reconnect: () -> Void
    @State private var asking = false

    var body: some View {
        if push.availability != .otherChannel {
            Section {
                switch push.availability {
                case .available:
                    Toggle(isOn: Binding(get: { push.isOn(for: model) }, set: { switchTo($0) })) {
                        Label("Auch bei geschlossener App", systemImage: "antenna.radiowaves.left.and.right")
                    }
                    .disabled(model.connection == nil || push.working)
                    status
                case .unavailable(let reason):
                    Label("Auch bei geschlossener App: nicht verfügbar. \(reason)", systemImage: "antenna.radiowaves.left.and.right.slash")
                        .foregroundStyle(.secondary)
                case .otherChannel:
                    EmptyView()
                }
            } footer: {
                Text("Der noty-Server prüft deinen Stundenplan stündlich (werktags 5–21 Uhr, am Wochenende seltener) und meldet Änderungen über Apple – auch wenn noty geschlossen oder weggewischt ist. Dafür liegt deine WebUntis-Freigabe verschlüsselt auf dem Server. Solange das aktiv ist, trägt noty selbst gefundene Änderungen nur in die Glocke ein. Ausschalten oder „Trennen“ löscht alles auf dem Server.")
            }
            .calendarPushConsent(isPresented: $asking, model: model)
        }
    }

    private func switchTo(_ on: Bool) {
        if on {
            if push.hasConsent { Task { await push.enable(for: model) } } else { asking = true }
        } else {
            Task { await push.disable() }
        }
    }

    @ViewBuilder private var status: some View {
        let state = push.state
        if push.working {
            Label("Mitteilungsdienst wird abgeglichen …", systemImage: "arrow.triangle.2.circlepath")
        } else if state.pendingDelete {
            line("Abmeldung steht noch aus: Die Daten auf dem Server sind noch nicht gelöscht. noty wiederholt das beim nächsten Start.",
                 "exclamationmark.triangle", .orange)
            retryButton("Jetzt erneut versuchen")
        } else if state.wanted == true, let target = state.connectionID, target != model.connection?.id {
            line("Aktiv für die WebUntis-Verbindung eines anderen Bereichs. Einschalten verlegt es hierher.", "info.circle", .secondary)
        } else if !push.isOn(for: model) {
            line("Aus – Änderungen meldet noty nur, wenn es selbst aktualisiert (im Vordergrund oder wenn iPadOS Hintergrundzeit gibt).",
                 "moon.zzz", .secondary)
        } else if !model.notificationSettings.changes {
            line("Pausiert, weil „Stundenplanänderungen“ aus ist. Auf dem Server ist nichts mehr gespeichert.", "pause.circle", .secondary)
        } else if !state.registered {
            if let error = state.lastError {
                line("Nicht eingerichtet: \(error) Bis dahin meldet noty Änderungen selbst.", "exclamationmark.triangle", .orange)
                retryButton("Erneut versuchen")
            } else if model.reminderPermission != .allowed {
                line("Wartet auf die Erlaubnis für Mitteilungen.", "bell.slash", .orange)
            } else if model.credentialsMissing {
                line("Wartet auf die WebUntis-Zugangsdaten dieses iPads (oben neu verbinden).", "key", .orange)
            } else {
                line("Wird eingerichtet …", "hourglass", .secondary)
                retryButton("Erneut versuchen")
            }
        } else {
            switch state.serverState {
            case "authFailed":
                line("Pausiert: Untis-Zugang prüfen. Der Server wurde von WebUntis abgewiesen. Bis zum Neuverbinden meldet noty Änderungen selbst.",
                     "key", .orange)
                Button { reconnect() } label: { Label("WebUntis neu verbinden …", systemImage: "qrcode") }
                retryButton("Mit der vorhandenen Freigabe erneut versuchen")
            case "tokenInvalid":
                line("Pausiert: Mitteilungs-Token ungültig. noty meldet beim nächsten Start ein neues; bis dahin meldet noty Änderungen selbst.",
                     "exclamationmark.triangle", .orange)
                retryButton("Jetzt erneut versuchen")
            default:
                if let error = state.lastError {
                    line("Server nicht erreichbar: \(error) Bis dahin meldet noty Änderungen selbst.", "exclamationmark.triangle", .orange)
                    retryButton("Erneut versuchen")
                } else {
                    line("Aktiv" + (state.lastContact.map { " · zuletzt abgeglichen " + CalendarText.clock($0, calendar: model.calendar) } ?? ""),
                         "checkmark.circle", .green)
                    if let problem = state.serverError {
                        line("Letzter Abruf des Servers: \(problem)", "info.circle", .secondary)
                    }
                }
            }
        }
    }

    private func line(_ text: String, _ symbol: String, _ tint: Color) -> some View {
        Label(text, systemImage: symbol).foregroundStyle(tint).fixedSize(horizontal: false, vertical: true)
    }

    private func retryButton(_ title: String) -> some View {
        Button { Task { await push.retry(model) } } label: { Label(title, systemImage: "arrow.clockwise") }
            .disabled(push.working)
    }
}
