import SwiftUI
import UniformTypeIdentifiers

struct NotyAccountSettingsPage: View {
    @EnvironmentObject private var laws: LawLibraryModel
    @State private var email = ""
    @State private var password = ""
    @State private var code = ""
    @State private var registering = false
    @State private var recovery = false
    @State private var recoverySent = false
    @State private var message = ""
    var body: some View {
        Form {
            if let user = laws.user, !laws.sessionExpired {
                Section("Noty-Konto") {
                    LabeledContent("Angemeldet", value: user.email ?? user.name)
                    Text("Dasselbe Konto gilt für noty und law.xclipsen.de. Deine Notizbücher werden nicht hochgeladen.").font(.caption).foregroundStyle(.secondary)
                    if user.emailVerified != true {
                        if user.email == nil {
                            TextField("E-Mail ergänzen", text: $email).keyboardType(.emailAddress).textContentType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled()
                            SecureField("Aktuelles Passwort", text: $password).textContentType(.password)
                            Button("E-Mail hinzufügen und bestätigen") {
                                Task { if await laws.accountAction("/api/email", email: email, password: password) { password = ""; message = "Bestätigungscode wurde verschickt." } }
                            }
                        }
                        verification
                        Button("Bestätigungscode erneut senden") {
                            Task { if await laws.accountAction("/api/email/resend") { message = "Bestätigungscode wurde verschickt." } }
                        }
                    }
                    Button("Abmelden", role: .destructive) { Task { await laws.logout() } }
                    Text("Markierungen bleiben nach dem Abmelden auf diesem iPad sichtbar. Noch nicht übertragene Änderungen bleiben gespeichert.").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Section(recovery ? "Passwort zurücksetzen" : registering ? "Noty-Konto erstellen" : "Bei noty anmelden") {
                    TextField(recovery ? "E-Mail" : registering ? "Benutzername" : "Benutzername oder E-Mail", text: $email)
                        .keyboardType(recovery ? .emailAddress : .default).textContentType(.username).textInputAutocapitalization(.never).autocorrectionDisabled()
                    if !recovery || recoverySent {
                        SecureField(recovery ? "Neues Passwort (mindestens 12 Zeichen)" : "Passwort", text: $password)
                            .textContentType(registering || recovery ? .newPassword : .password)
                    }
                    if recoverySent { TextField("Code aus der E-Mail", text: $code).textInputAutocapitalization(.never).autocorrectionDisabled() }
                    Button(recovery ? (recoverySent ? "Neues Passwort speichern" : "Anmeldehilfe senden") : (registering ? "Konto erstellen" : "Anmelden")) {
                        Task {
                            if recovery {
                                if recoverySent {
                                    if await laws.accountAction("/api/password/reset", password: password, code: code) { password = ""; code = ""; recovery = false; recoverySent = false; message = "Passwort geändert. Bitte anmelden." }
                                } else if await laws.accountAction("/api/password/request", email: email) { recoverySent = true; message = "Falls ein bestätigtes Konto existiert, erhältst du eine E-Mail." }
                            } else { await laws.login(email: email, password: password, registering: registering); password = "" }
                        }
                    }.disabled(email.isEmpty || ((!recovery || recoverySent) && password.isEmpty))
                    Button(recovery ? "Zur Anmeldung" : registering ? "Ich habe schon ein Konto" : "Konto erstellen") { recovery = false; registering.toggle(); password = "" }
                    if !registering && !recovery { Button("Passwort vergessen?") { recovery = true; password = "" } }
                    Text(registering
                        ? "Ein Konto braucht nur einen Benutzernamen (2–32 Buchstaben, Zahlen oder . _ -) und ein Passwort mit mindestens 12 Zeichen. Es wird keine E-Mail verschickt. Ohne E-Mail-Adresse lässt sich ein vergessenes Passwort nicht zurücksetzen."
                        : "Lesen, Suchen und Markieren funktionieren ohne Konto; Markierungen bleiben dann nur auf diesem iPad. Mit Konto werden Lesezeichen und Markierungen mit law.xclipsen.de und anderen Geräten abgeglichen.").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let error = laws.error { Section { Text(error).foregroundStyle(.orange); Button("Hinweis schließen") { laws.error = nil } } }
            if !message.isEmpty { Section { Text(message).foregroundStyle(.secondary) } }
            if laws.accountBusy { ProgressView() }
            Section {
                NavigationLink("Gesetzessammlung & Synchronisierung") { LawSettingsPage() }
            }
        }.navigationTitle("Konto").disabled(laws.accountBusy)
    }
    private var verification: some View {
        Group {
            Text("E-Mail noch nicht bestätigt. Den einmaligen Code aus der E-Mail hier eingeben.").font(.caption)
            TextField("Bestätigungscode", text: $code).textInputAutocapitalization(.never).autocorrectionDisabled()
            Button("E-Mail bestätigen") {
                Task { if await laws.accountAction("/api/email/verify", code: code) { code = ""; message = "E-Mail bestätigt." } }
            }.disabled(code.isEmpty)
        }
    }
}

struct LawSettingsPage: View {
    @EnvironmentObject private var laws: LawLibraryModel
    @AppStorage(LawLibraryModel.enabledKey) private var enabled = false
    @AppStorage(LawLibraryModel.syncKey) private var sync = true
    @AppStorage(LawLibraryModel.updatesKey) private var updates = true
    @State private var exported: URL?
    @State private var restoring = false
    var body: some View {
        Form {
            Section {
                Toggle("Gesetzessammlung aktivieren", isOn: $enabled)
                Toggle("Lesezeichen und Markierungen synchronisieren", isOn: $sync)
                Toggle("Neue Gesetzesfassungen automatisch laden", isOn: $updates)
            } footer: {
                Text("Der Kontoabgleich und öffentliche Gesetzesupdates sind unabhängig. Ohne Konto bleiben deine Markierungen lokal. Nach einem vollständigen Erstdownload sind die Texte offline verfügbar; PDFs kannst du einzeln laden.")
            }
            if let error = laws.error { Section { Text(error).foregroundStyle(.orange); Button("Hinweis schließen") { laws.error = nil } } }
            if enabled {
                Section("Offlinebestand") {
                    LabeledContent("Dokumente", value: "\(laws.entries.count)")
                    LabeledContent("Speicher", value: ByteCountFormatter.string(fromByteCount: laws.byteCount, countStyle: .file))
                    if !laws.progress.isEmpty { Text(laws.progress).font(.caption) }
                    if laws.downloading { ProgressView() }
                    Button("Gesetzesbestand jetzt laden / aktualisieren") { Task { await laws.updateLaws() } }.disabled(laws.downloading)
                    NavigationLink("Gesetzessammlung öffnen") { LawReaderView() }
                }
                Section("Persönliche Daten") {
                    Text(laws.syncStatus).font(.caption)
                    Button("Jetzt synchronisieren") { Task { await laws.synchronize() } }.disabled(laws.syncing || !sync || laws.user == nil)
                    Button("Markierungen und Lesezeichen sichern …") {
                        Task { do { exported = try await laws.exportPersonal() } catch { laws.error = error.localizedDescription } }
                    }
                    if let exported { ShareLink("Sicherungsdatei teilen", item: exported) }
                    Button("Markierungen aus Sicherung ergänzen …") { restoring = true }
                    Text("Diese Sicherung enthält persönliche Gesetzesdaten, keine Anmeldeschlüssel. Sie ergänzt Notizbuchbackups und bleibt von Gesetzesdownloads getrennt.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }.navigationTitle("Gesetzessammlung")
            .task { await laws.start() }
            .onChange(of: enabled) { _, _ in Task { await laws.settingsChanged() } }
            .onChange(of: sync) { _, _ in Task { await laws.settingsChanged(); await laws.synchronize() } }
            .onChange(of: updates) { _, _ in Task { await laws.settingsChanged() } }
            .fileImporter(isPresented: $restoring, allowedContentTypes: [.json]) { result in
                switch result { case .success(let url): Task { await laws.restorePersonal(url) }; case .failure(let error): laws.error = error.localizedDescription }
            }
    }
}

struct LawPanelView<Drag: Gesture>: View {
    @EnvironmentObject private var laws: LawLibraryModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Moves the window live; the workspace decides side, dock and stash on release.
    var drag: Drag
    /// What Apple Pencil does in the reader, and how the reader changes it.
    var pen = LawPenMode()
    var onPenChange: ((LawPenMode) -> Void)? = nil
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Menu {
                    Button(laws.docked ? "Über Notizbüchern schweben" : "Neben Notizbuch andocken", systemImage: laws.docked ? "rectangle.on.rectangle" : "rectangle.split.2x1") { laws.docked.toggle() }
                    Button(laws.panelOnLeft ? "Nach rechts" : "Nach links") { laws.panelOnLeft.toggle() }
                    Button("An den Rand schieben", systemImage: laws.panelOnLeft ? "arrow.left.to.line" : "arrow.right.to.line") {
                        withAnimation(NotyMotion.panel(reduceMotion)) { laws.stashed = true }
                    }
                } label: { Image(systemName: "rectangle.split.2x1").frame(width: 44, height: 36) }.accessibilityLabel("Gesetzesfenster anordnen")
                Spacer()
                Capsule().fill(.secondary).frame(width: 44, height: 5).frame(width: 80, height: 36)
                    .accessibilityLabel("Gesetzesfenster verschieben")
                Spacer()
                Button { laws.panelOpen = false } label: { Image(systemName: "xmark").frame(width: 44, height: 36) }.accessibilityLabel("Gesetzesfenster schließen")
            }.background(.ultraThinMaterial)
                // The whole bar is the grip, not only the small capsule.
                .contentShape(Rectangle())
                .gesture(drag)
            LawReaderView(pen: pen, onPenChange: onPenChange)
        }.clipShape(RoundedRectangle(cornerRadius: laws.docked ? 0 : 16))
            .overlay(RoundedRectangle(cornerRadius: laws.docked ? 0 : 16).strokeBorder(.secondary.opacity(0.25)))
            .shadow(color: .black.opacity(laws.docked ? 0 : 0.3), radius: 16)
    }
}
