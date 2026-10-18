import SwiftUI
import UniformTypeIdentifiers
import UserNotifications
import NotebookCore

struct ExternalBackupView: View {
    @ObservedObject var model: ExternalBackupModel
    @ObservedObject var library: LibraryModel
    @ObservedObject var workspaces: WorkspaceAppModel
    @EnvironmentObject private var toolbox: ToolbarSettingsModel
    @Environment(\.dismiss) private var dismiss
    @State private var folderPicker = false
    @State private var endpoint = ""
    @State private var username = ""
    @State private var password = ""
    @State private var exporting = false
    @State private var file: ExportFile?
    @State private var reminderStatus = ""
    @State private var restored = false
    var body: some View {
        NavigationStack {
            Form {
                Section("Aktives Ziel · diese Bibliothek") {
                    Text(targetTitle)
                    Text(model.status).font(.subheadline)
                    if let date = model.policy.lastSuccess { Text("Letzter geprüfter Stand: \(date.formatted())").font(.caption) }
                    Text("Vollständig editierbare, unverschlüsselte Sicherungen. Ein täglicher Versuch während aktiver Nutzung; bei Fehlern erneuter Versuch nach 15 Minuten. Es ist immer nur ein Ziel aktiv.")
                        .font(.caption).foregroundStyle(.secondary)
                    Stepper("\(model.policy.keep) automatische Stände behalten", value: Binding(get: { model.policy.keep }, set: { model.setRetention($0) }), in: 3...30)
                    Button("Jetzt vollständig sichern") { Task { await model.attempt(library: library, toolbox: toolbox, manual: true) } }
                        .disabled(model.policy.target == .disabled || !library.ready)
                    Button("Automatisches Backup ausschalten") { model.disable() }
                }
                Section("iCloud Drive / Dateien-Ordner") {
                    Button("Backupordner wählen") { folderPicker = true }
                    Text("In der Dateien-Auswahl einen Ordner in iCloud Drive wählen. Nach dem Schreiben prüft noty die lokale Zieldatei; der Cloud-Upload wird von iPadOS ausgeführt und hier nicht als abgeschlossen bestätigt.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("WebDAV") {
                    TextField("HTTPS-Adresse des vorhandenen Ordners", text: $endpoint).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    TextField("Benutzername", text: $username).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("Passwort / App-Passwort", text: $password)
                    Button("WebDAV als aktives Ziel speichern") {
                        model.useWebDAV(endpoint: endpoint, username: username, password: password); password = ""
                    }
                    Text("Zugangsdaten liegen im Geräte-Schlüsselbund. Der Ordner muss bereits existieren. Alte Sicherungen bleiben beim Zielwechsel erhalten.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Ältere vollständige Stände") {
                    Button("Liste vom Ziel neu laden") { Task { do { try await model.reloadHistory() } catch { model.error = "Liste konnte nicht geladen werden. Backupziel prüfen." } } }
                    ForEach(model.history, id: \.self) { name in
                        VStack(alignment: .leading) {
                            Text(Date(timeIntervalSince1970: model.policy.timestamp(name) ?? 0), format: .dateTime.day().month().year().hour().minute().second())
                            HStack {
                                Button("Als neuen Bereich wiederherstellen") { Task {
                                    guard let bytes = await model.retrieve(name) else { return }
                                    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".notylibrary")
                                    defer { try? FileManager.default.removeItem(at: url) }
                                    do {
                                        try bytes.write(to: url, options: .atomic)
                                        restored = await workspaces.restoreLibrary(url)
                                        if !restored { model.error = workspaces.error ?? "Wiederherstellung fehlgeschlagen." }
                                    } catch { model.error = "Wiederherstellung konnte nicht vorbereitet werden." }
                                } }
                                Button("Datei exportieren") { Task {
                                    if let bytes = await model.retrieve(name) { file = ExportFile(libraryData: bytes); exporting = true }
                                } }
                            }.font(.caption)
                        }.padding(.vertical, 4)
                    }
                    if model.history.isEmpty { Text("Noch keine Stände vom aktiven Ziel geladen.").foregroundStyle(.secondary) }
                }
                Section("Signierung erneuern") {
                    if let expiration = SigningReminder.expiration {
                        Text("Installiertes Profil gültig bis \(expiration.formatted()).")
                        Button("Erinnerung einen Tag vorher aktivieren") { Task { reminderStatus = await SigningReminder.enable() } }
                    } else { Text("Profilablauf nicht lesbar. Die kostenlose Signierung weiterhin wöchentlich am PC erneuern.") }
                    if !reminderStatus.isEmpty { Text(reminderStatus).font(.caption) }
                    Text("Am PC als Update mit derselben App-ID installieren. App vorher schließen und Gerät entsperren. Vor jedem Update vollständigen Datenabzug sichern; App nicht löschen.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .disabled(model.busy || workspaces.busy)
            .overlay { if model.busy { ProgressView("Sicherung wird geprüft …").padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) } }
            .navigationTitle("Externe Backups")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Schließen") { dismiss() }.disabled(model.busy) } }
            .onAppear { endpoint = model.policy.endpoint; username = model.username }
            .fileImporter(isPresented: $folderPicker, allowedContentTypes: [.folder]) { result in
                switch result { case .success(let url): model.useFolder(url); case .failure: model.error = "Kein Backupordner gewählt." }
            }
            .fileExporter(isPresented: $exporting, document: file, contentType: .notyLibrary, defaultFilename: "noty-gepruefte-bibliothek") { result in
                if case .failure = result { model.error = "Dateiexport nicht abgeschlossen." }
            }
            .alert("Externes Backup", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
                Button("OK") { model.error = nil }
            } message: { Text(model.error ?? "") }
            .alert("Als neuen Bereich wiederhergestellt", isPresented: $restored) {
                Button("OK", role: .cancel) { }
            } message: { Text("Der neue Bereich ist unter Bereiche verfügbar. Die aktuelle Bibliothek bleibt erhalten.") }
            .interactiveDismissDisabled(model.busy)
        }
    }
    private var targetTitle: String {
        switch model.policy.target { case .disabled: "Ausgeschaltet"; case .folder: "Dateien-Ordner / iCloud Drive"; case .webDAV: "WebDAV" }
    }
}

private enum SigningReminder {
    static var expiration: Date? {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let bytes = try? Data(contentsOf: url),
              let start = bytes.range(of: Data("<?xml".utf8)), let end = bytes.range(of: Data("</plist>".utf8)), start.lowerBound < end.upperBound,
              let plist = try? PropertyListSerialization.propertyList(from: bytes[start.lowerBound..<end.upperBound], options: [], format: nil) as? [String: Any] else { return nil }
        return plist["ExpirationDate"] as? Date
    }
    static func enable() async -> String {
        guard let expiration else { return "Profilablauf nicht lesbar." }
        do {
            let center = UNUserNotificationCenter.current()
            guard try await center.requestAuthorization(options: [.alert, .sound]) else { return "Mitteilungen nicht erlaubt. Bitte wöchentlich selbst erinnern." }
            let content = UNMutableNotificationContent()
            content.title = "noty-Signierung erneuern"; content.body = "Am PC mit derselben App-ID aktualisieren und vorher die App-Daten sichern. App nicht löschen."; content.sound = .default
            let date = max(Date().addingTimeInterval(60), expiration.addingTimeInterval(-24 * 3600))
            let trigger = UNCalendarNotificationTrigger(dateMatching: Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date), repeats: false)
            try await center.add(UNNotificationRequest(identifier: "noty.signing-renewal", content: content, trigger: trigger))
            return "Erinnerung für \(date.formatted()) aktiviert. Nach jedem Signierungsupdate hier neu setzen."
        } catch { return "Erinnerung konnte nicht gespeichert werden." }
    }
}
