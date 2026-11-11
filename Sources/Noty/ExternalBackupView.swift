import SwiftUI
import UniformTypeIdentifiers
import UserNotifications
import NotebookCore

/// Standalone sheet; the same form is pushed from Settings › Backup.
struct ExternalBackupView: View {
    @ObservedObject var model: ExternalBackupModel
    @ObservedObject var library: LibraryModel
    @ObservedObject var workspaces: WorkspaceAppModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ExternalBackupForm(model: model, library: library, workspaces: workspaces, showsSigning: true)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() }.disabled(model.busy) } }
                .interactiveDismissDisabled(model.busy)
        }
    }
}

struct ExternalBackupForm: View {
    @ObservedObject var model: ExternalBackupModel
    @ObservedObject var library: LibraryModel
    @ObservedObject var workspaces: WorkspaceAppModel
    var showsSigning = false
    @EnvironmentObject private var toolbox: ToolbarSettingsModel
    @State private var folderPicker = false
    @State private var endpoint = ""
    @State private var username = ""
    @State private var password = ""
    @State private var confirmingRemoval = false
    @State private var confirmingDisable = false
    var body: some View {
        Form {
            Section {
                // Long values (a 300-character reason, a long folder name) get their own lines:
                // as a LabeledContent value they squeezed the label until it wrapped letter by letter.
                LabeledContent {
                    Text(targetTitle).lineLimit(2).truncationMode(.middle).pointerHelp(targetTitle)
                } label: { Text("Ziel").fixedSize() }
                Text(model.status).font(.subheadline).foregroundStyle(model.folderUnreachable ? Color.orange : Color.secondary)
                LabeledContent("Letztes Backup", value: model.policy.lastSuccess.map(NotyText.statusDate) ?? NotyText.never)
                if let warning = model.policy.lastWarning, model.policy.lastOutcome == .succeeded {
                    Text("Hinweis: \(warning). Das Heft öffnen und prüfen; die beschädigten neueren Daten bleiben im Heftordner.")
                        .font(.caption).foregroundStyle(.orange)
                }
                if let attempt = model.policy.lastAttempt, model.policy.lastOutcome != .succeeded {
                    LabeledContent("Letzter Versuch", value: "\(NotyText.statusDate(attempt)) · \(outcomeTitle)")
                    if let reason = model.policy.lastFailureReason, !reason.isEmpty,
                       model.policy.lastOutcome == .failed || model.policy.lastOutcome == .unreachable {
                        Text(reason).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    if let next = model.policy.nextAttempt, next > Date() {
                        LabeledContent("Nächster automatischer Versuch", value: NotyText.statusDate(next))
                    }
                }
                Stepper("Die neuesten \(model.policy.keep) Backups behalten", value: Binding(get: { model.policy.keep }, set: { model.setRetention($0) }), in: 3...30)
                Button("Automatisches Backup ausschalten …", role: .destructive) { confirmingDisable = true }
                    .disabled(model.policy.target == .disabled)
            } header: {
                Text(workspaces.areaID == nil ? "Aktives Ziel" : "Aktives Ziel · Bereich \(NotyText.quoted(workspaces.title))").lineLimit(2).truncationMode(.middle)
            } footer: {
                Text("Einmal am Tag, solange noty benutzt wird. Nach Fehlern folgen weitere Versuche nach 15 Minuten, 1, 4 und 12 Stunden. Außer den neuesten bleibt gestaffelt je ein Backup der letzten 7 Tage, 4 Wochen und 6 Monate, damit sich auch ein vor Wochen gelöschtes Heft zurückholen lässt.")
            }
            Section("Backup-Ordner (Dateien, iCloud Drive)") {
                Button(model.policy.target == .folder ? "Anderen Backup-Ordner wählen …" : "Backup-Ordner wählen …") { folderPicker = true }
            }
            Section {
                TextField("HTTPS-Adresse des vorhandenen Ordners", text: $endpoint).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                TextField("Benutzername", text: $username).textInputAutocapitalization(.never).autocorrectionDisabled()
                SecureField(model.keepsStoredPassword(for: endpoint) ? "Gespeichert – leer lassen zum Beibehalten" : "Passwort / App-Passwort", text: $password)
                Button("WebDAV als aktives Ziel speichern") {
                    model.useWebDAV(endpoint: endpoint, username: username, password: password); password = ""
                }
                if model.hasStoredCredentials {
                    Button("Zugangsdaten entfernen …", role: .destructive) { confirmingRemoval = true }
                }
            } header: { Text("WebDAV") } footer: {
                Text("Zugangsdaten nur im Schlüsselbund dieses iPads, nie im Backup. Der Ordner muss bereits existieren. Ein leeres Passwortfeld behält das gespeicherte Passwort, solange die Adresse beim selben Server bleibt; für einen anderen Server bitte neu eingeben.")
            }
            if showsSigning { SigningRenewalSection() }
        }
        .disabled(model.busy || workspaces.busy)
        .overlay { if model.busy { ProgressView(model.status.hasSuffix("…") ? model.status : "Backup wird geladen und geprüft …").padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) } }
        .navigationTitle("Ziel und Aufbewahrung")
        .onAppear { endpoint = model.policy.endpoint; username = model.username; model.checkFolder() }
        .fileImporter(isPresented: $folderPicker, allowedContentTypes: [.folder]) { result in
            switch result { case .success(let url): model.useFolder(url); case .failure: model.error = "Kein Backup-Ordner gewählt." }
        }
        .confirmationDialog("WebDAV-Zugangsdaten entfernen?", isPresented: $confirmingRemoval, titleVisibility: .visible) {
            Button("Zugangsdaten entfernen", role: .destructive) { model.removeCredentials(); username = "" }
        } message: { Text("Benutzername und Passwort werden aus dem Schlüsselbund gelöscht. Automatische WebDAV-Backups schlagen fehl, bis neue Zugangsdaten gespeichert sind.") }
        .confirmationDialog("Automatisches Backup ausschalten?", isPresented: $confirmingDisable, titleVisibility: .visible) {
            Button("Ausschalten", role: .destructive) { model.disable() }
        } message: { Text("Es entstehen keine neuen automatischen Backups mehr. Vorhandene Backups im Backup-Ordner bzw. auf dem WebDAV-Ziel bleiben erhalten.") }
        .alert("Backup", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
    }
    private var targetTitle: String {
        switch model.policy.target {
        case .disabled: "Ausgeschaltet"
        case .folder: model.policy.folderName.map { "Dateien-Ordner \(NotyText.quoted($0))" } ?? "Dateien-Ordner / iCloud Drive"
        case .webDAV: "WebDAV"
        }
    }
    private var outcomeTitle: String {
        switch model.policy.lastOutcome {
        case .unreachable?: "nicht erreichbar"
        case .failed?: "fehlgeschlagen"
        case .succeeded?, nil: "ohne Ergebnis"
        }
    }
}

/// Free-signing renewal hint; shown in Settings › Über noty and the standalone backup sheet.
struct SigningRenewalSection: View {
    @State private var reminderStatus = ""
    @State private var enabled = SigningReminder.enabled
    var body: some View {
        Section("Signierung erneuern") {
            if let expiration = SigningReminder.expiration {
                LabeledContent("Signatur gültig bis", value: NotyText.statusDate(expiration))
                if expiration < Date() { Text("Abgelaufen – am PC neu signieren und als Update installieren.").foregroundStyle(.orange) }
                keyToggle("Erinnerung einen Tag vorher", isOn: Binding(get: { enabled }, set: { value in
                    enabled = value
                    Task { reminderStatus = value ? await SigningReminder.enable() : SigningReminder.disable(); enabled = SigningReminder.enabled }
                }))
            } else { Text("Profilablauf nicht lesbar. Die Signierung rechtzeitig am PC erneuern.") }
            if !reminderStatus.isEmpty { Text(reminderStatus).font(.caption) }
            Text("Am PC als Update mit derselben App-ID installieren. App vorher schließen und Gerät entsperren. Vor jedem Update vollständigen Datenabzug sichern; App nicht löschen.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// The expiry comes from the app's own embedded.mobileprovision, read once per
/// launch. With the reminder enabled, every launch replaces the one pending
/// notification (fixed identifier) for the profile that is installed now.
enum SigningReminder {
    static let identifier = "noty.signing-renewal"
    private static let enabledKey = "noty.v2.signingReminder"
    static let expiration: Date? = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision")
        .flatMap { try? BoundedFile.read($0, limit: 2_000_000) }.flatMap(SigningProfile.expirationDate)
    static var enabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    /// Launch: reschedule only if the user enabled the reminder; never asks for permission here.
    static func refresh() async {
        let center = UNUserNotificationCenter.current()
        // Build ≤ 46 set the reminder once without remembering it: adopt that choice.
        if !enabled, await center.pendingNotificationRequests().contains(where: { $0.identifier == identifier }) {
            UserDefaults.standard.set(true, forKey: enabledKey)
        }
        guard enabled, let expiration else { return }
        _ = await schedule(expiration, mayAsk: false)
    }
    static func enable() async -> String {
        guard let expiration else { return "Profilablauf nicht lesbar." }
        UserDefaults.standard.set(true, forKey: enabledKey)
        return await schedule(expiration, mayAsk: true)
    }
    static func disable() -> String {
        UserDefaults.standard.set(false, forKey: enabledKey)
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [identifier])
        return "Erinnerung ausgeschaltet."
    }
    private static func schedule(_ expiration: Date, mayAsk: Bool) async -> String {
        let center = UNUserNotificationCenter.current()
        guard let date = SigningProfile.reminderDate(expiration: expiration) else {
            center.removePendingNotificationRequests(withIdentifiers: [identifier])
            return "Profil bereits abgelaufen. Bitte am PC erneuern."
        }
        do {
            var status = await center.notificationSettings().authorizationStatus
            if status == .notDetermined, mayAsk {
                status = try await center.requestAuthorization(options: [.alert, .sound]) ? .authorized : .denied
            }
            guard status == .authorized || status == .provisional else {
                if mayAsk { UserDefaults.standard.set(false, forKey: enabledKey) }
                return "Mitteilungen nicht erlaubt. Bitte selbst an die Erneuerung denken."
            }
            let content = UNMutableNotificationContent()
            content.title = "noty-Signierung erneuern"; content.body = "Am PC mit derselben App-ID aktualisieren und vorher die App-Daten sichern. App nicht löschen."; content.sound = .default
            let trigger = UNCalendarNotificationTrigger(dateMatching: Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date), repeats: false)
            center.removePendingNotificationRequests(withIdentifiers: [identifier])
            try await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: trigger))
            return "Erinnerung für \(NotyText.statusDate(date)) gesetzt; nach jedem Signierungsupdate automatisch neu."
        } catch { return "Erinnerung konnte nicht gespeichert werden." }
    }
}
