import SwiftUI
import NotebookCore

// Push-Dienst (docs/PUSH.md): the consent before anything is uploaded and
// the section „Auch bei geschlossener App“ of „Mitteilungen“. Its details
// (device id, last contact, server state) are on the developer page
// (`CalendarDeveloperSection`).

extension View {
    /// The consent (text and version `CalendarPush.consentVersion`) before
    /// the first upload. „Zustimmen“ registers; „Nicht jetzt“ keeps
    /// everything local and is not asked again (the switch in
    /// „Mitteilungen“ asks once more).
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

    /// The consent remembered after connecting WebUntis when the form was
    /// already gone (`model.pushOfferPending`): offered by the first place
    /// that is on screen and free (`ready`) – Einstellungen › Kalender or the
    /// calendar –, once, and only while it still applies (`shouldOffer`).
    func calendarPushOffer(model: CalendarModel, ready: Bool = true) -> some View {
        modifier(CalendarPushOfferPresenter(model: model, ready: ready))
    }
}

private struct CalendarPushOfferPresenter: ViewModifier {
    @ObservedObject var model: CalendarModel
    let ready: Bool
    @State private var onScreen = false
    /// `ready` as last seen (read again after the short wait in `claim`).
    @State private var free = false
    @State private var offering = false

    func body(content: Content) -> some View {
        content
            .onAppear { onScreen = true; free = ready; claim(waiting: true) }
            .onDisappear { onScreen = false }
            .onChange(of: ready) { _, now in free = now; if now { claim(waiting: true) } }
            .onChange(of: model.pushOfferPending) { _, pending in if pending { claim(waiting: false) } }
            .calendarPushConsent(isPresented: $offering, model: model)
    }

    /// `waiting`: a cover or sheet may still be on its way out (an alert
    /// would not appear beneath it).
    private func claim(waiting: Bool) {
        guard model.pushOfferPending, onScreen, free, !offering else { return }
        if waiting {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(650))
                claim(waiting: false)
            }
            return
        }
        model.pushOfferPending = false
        if CalendarPushClient.shared.shouldOffer(for: model) { offering = true }
    }
}

/// „Auch bei geschlossener App“: on/off (off deletes everything on the
/// server) with its explanation and what the user has to know or do now.
/// Shown only in noty calendar.
struct CalendarPushSection: View {
    @ObservedObject var model: CalendarModel
    @ObservedObject private var push = CalendarPushClient.shared
    /// „Untis-Zugang prüfen“: show the WebUntis form (the sheet closes first).
    let reconnect: () -> Void
    @State private var asking = false

    var body: some View {
        if push.availability != .otherChannel {
            Section {
                switch push.availability {
                case .available:
                    settingToggle("Auch bei geschlossener App",
                                  detail: "Der noty-Server prüft deinen Stundenplan stündlich (werktags 5–21 Uhr, am Wochenende seltener) und meldet Änderungen über Apple, auch wenn noty geschlossen ist. Dafür liegt deine WebUntis-Freigabe verschlüsselt auf dem Server; „Aus“ oder „Trennen“ löscht dort alles.",
                                  isOn: Binding(get: { push.isOn(for: model) }, set: { switchTo($0) }))
                        .disabled(model.connection == nil || push.working)
                    status
                case .unavailable(let reason):
                    SettingLabel("Auch bei geschlossener App", detail: "Nicht verfügbar. \(reason)")
                        .foregroundStyle(.secondary)
                case .otherChannel:
                    EmptyView()
                }
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
        // The server asked for a pause (429 with Retry-After) that has not passed yet.
        let pause = push.blockedUntil.flatMap { $0 > Date() ? $0 : nil }
        if push.working {
            Label("Mitteilungsdienst wird abgeglichen …", systemImage: "arrow.triangle.2.circlepath")
        } else if state.pendingDelete {
            line("Abmeldung steht noch aus: Die Daten auf dem Server sind noch nicht gelöscht. noty wiederholt das beim nächsten Start."
                 + (pause.map { " " + CalendarPushClient.pauseText($0) } ?? ""),
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
                line("Wartet auf die WebUntis-Zugangsdaten dieses iPads.", "key", .orange)
                Button { reconnect() } label: { Label("WebUntis neu verbinden …", systemImage: "qrcode") }
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
                if let pause {
                    // 429: only a pause for the app's requests; the server keeps polling and notifying.
                    line("Aktiv · " + CalendarPushClient.pauseText(pause) + " Mitteilungen kommen trotzdem weiter.", "hourglass", .secondary)
                } else if let error = state.lastError {
                    line("Server nicht erreichbar: \(error) Bis dahin meldet noty Änderungen selbst.", "exclamationmark.triangle", .orange)
                    retryButton("Erneut versuchen")
                } else if state.serverError != nil {
                    // Registered, but the server's own WebUntis fetch fails (details: developer page).
                    line("Der Server meldet ein Problem beim Abrufen des Stundenplans. Bis es behoben ist, kommen Änderungen womöglich nur, wenn noty selbst aktualisiert.",
                         "exclamationmark.triangle", .orange)
                    retryButton("Erneut versuchen")
                } else {
                    // Last contact and the server's own fetch problems: developer page.
                    line("Aktiv – Änderungen meldet der Server; noty trägt eigene Funde nur in die Glocke ein.", "checkmark.circle", .green)
                }
            }
        }
    }

    /// Times like „zuletzt abgeglichen 07:12“ with equal-width digits.
    private func line(_ text: String, _ symbol: String, _ tint: Color) -> some View {
        Label(text, systemImage: symbol).monospacedDigit().foregroundStyle(tint).fixedSize(horizontal: false, vertical: true)
    }

    private func retryButton(_ title: String) -> some View {
        Button { Task { await push.retry(model) } } label: { Label(title, systemImage: "arrow.clockwise") }
            .disabled(push.working)
    }
}
