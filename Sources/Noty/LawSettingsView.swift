import SwiftUI
import NotebookCore
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
    @State private var confirmUnlink = false
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        Form {
            if let user = laws.user, !laws.sessionExpired {
                Section("Noty-Konto") {
                    LabeledContent("Angemeldet", value: user.email ?? user.name)
                    Text("Dasselbe Konto gilt für noty und law.xclipsen.de. Hefte und Textdokumente werden nicht hochgeladen.").font(.caption).foregroundStyle(.secondary)
                    if LawLibraryModel.mailDelivery, user.emailVerified != true {
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
                    apple(user)
                    Button("Abmelden", role: .destructive) { Task { await laws.logout() } }
                    Text("Markierungen bleiben nach dem Abmelden auf diesem iPad sichtbar. Noch nicht übertragene Änderungen bleiben gespeichert.").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                if laws.sessionExpired, let user = laws.user {
                    Section("Anmeldung abgelaufen") {
                        Text("Die Anmeldung als „\(user.email ?? user.name)“ gilt nicht mehr. Bitte erneut anmelden; noch nicht übertragene Markierungen bleiben auf diesem iPad.").font(.caption)
                        Button("Abmelden", role: .destructive) { Task { await laws.logout() } }
                    }
                }
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
                            message = ""
                            if recovery {
                                if recoverySent {
                                    if await laws.accountAction("/api/password/reset", password: password, code: code) { password = ""; code = ""; recovery = false; recoverySent = false; message = "Passwort geändert. Bitte anmelden." }
                                } else if await laws.accountAction("/api/password/request", email: email) { recoverySent = true; message = "Falls ein bestätigtes Konto existiert, wird eine E-Mail verschickt." }
                            } else if await laws.login(email: email, password: password, registering: registering) { password = "" }
                        }
                    }.disabled(email.isEmpty || ((!recovery || recoverySent) && password.isEmpty))
                    if !recovery {
                        AppleSignInButton(type: registering ? .signUp : .signIn) {
                            Task {
                                message = ""
                                let result = await laws.appleLogin()
                                guard result.signedIn else { return }
                                password = ""; registering = false
                                if result.created { message = "Neues noty-Konto „\(laws.user?.name ?? "")“ mit Apple erstellt." }
                            }
                        }.id(colorScheme).frame(height: 44).frame(maxWidth: 375)
                            .accessibilityLabel(registering ? "Mit Apple registrieren" : "Mit Apple anmelden")
                    }
                    Button(recovery ? "Zur Anmeldung" : registering ? "Ich habe schon ein Konto" : "Konto erstellen") { recovery = false; registering.toggle(); password = "" }
                    if !registering && !recovery {
                        if LawLibraryModel.mailDelivery { Button("Passwort vergessen?") { recovery = true; password = "" } }
                        else { Text("Zurücksetzen eines vergessenen Passworts ist noch nicht möglich, weil noty derzeit keine E-Mails verschickt.").font(.caption).foregroundStyle(.secondary) }
                    }
                    Text(registering
                        ? "Ein Konto braucht nur einen Benutzernamen (2–32 Buchstaben, Zahlen oder . _ -) und ein Passwort mit mindestens 12 Zeichen. Es wird keine E-Mail verschickt. Ohne E-Mail-Adresse lässt sich ein vergessenes Passwort nicht zurücksetzen."
                        : "Lesen, Suchen und Markieren funktionieren ohne Konto; Markierungen bleiben dann nur auf diesem iPad. Mit Konto werden Lesezeichen und Markierungen mit law.xclipsen.de und anderen Geräten abgeglichen.").font(.caption).foregroundStyle(.secondary)
                    if !recovery {
                        Text("„Mit Apple anmelden“ öffnet das noty-Konto, das mit dieser Apple-ID verknüpft ist, sonst entsteht ein neues – nach einer abgelaufenen Anmeldung nicht, und wenn noch Markierungen eines anderen Kontos auf diesem iPad warten, fragt noty vorher. Ein bestehendes Konto zuerst mit Passwort anmelden und dann Apple verknüpfen. noty speichert von Apple keine E-Mail-Adresse.").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if let error = laws.error { Section { Text(error).foregroundStyle(.orange); Button("Hinweis schließen") { laws.error = nil } } }
            if !message.isEmpty { Section { Text(message).foregroundStyle(.secondary) } }
            if laws.accountBusy { ProgressView() }
            Section {
                NavigationLink("Gesetzessammlung & Synchronisierung") { LawSettingsPage() }
            }
        }.navigationTitle("Konto").disabled(laws.accountBusy)
            .task { if laws.user != nil, laws.user?.apple == nil { await laws.refreshAccount() } }
            .confirmationDialog("Apple trennen?", isPresented: $confirmUnlink, titleVisibility: .visible) {
                Button("Apple trennen", role: .destructive) {
                    Task { message = ""; if await laws.appleUnlink() { message = "Apple ist nicht mehr mit diesem Konto verknüpft." } }
                }
            } message: { Text("Danach ist die Anmeldung nur noch mit Benutzername und Passwort möglich.") }
            .keyboardSheet()
            .onChange(of: laws.error) { _, error in if error != nil { message = "" } }
            .onAppear { laws.inlineErrorPages += 1 }
            .onDisappear { laws.inlineErrorPages -= 1 }
    }
    @ViewBuilder private func apple(_ user: NotyAccountUser) -> some View {
        if user.apple == true {
            LabeledContent("Mit Apple anmelden", value: "verknüpft")
            Button("Apple trennen", role: .destructive) { confirmUnlink = true }
        } else {
            Button("Apple verknüpfen") {
                Task { message = ""; if await laws.appleLink() { message = "Apple ist jetzt mit diesem Konto verknüpft." } }
            }
        }
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
                keyToggle("Gesetzessammlung aktivieren", isOn: $enabled)
                keyToggle("Lesezeichen und Markierungen synchronisieren", isOn: $sync)
                keyToggle("Neue Gesetzesfassungen automatisch laden", isOn: $updates)
            } footer: {
                Text("Der Kontoabgleich und öffentliche Gesetzesupdates sind unabhängig. Ohne Konto bleiben Markierungen lokal. Nach einem vollständigen Erstdownload sind die Texte offline verfügbar; PDFs lassen sich einzeln laden.")
            }
            if let error = laws.error { Section { Text(error).foregroundStyle(.orange); Button("Hinweis schließen") { laws.error = nil } } }
            if enabled {
                Section("Offlinebestand") {
                    LabeledContent("Dokumente", value: "\(laws.entries.count)")
                    LabeledContent("Speicher", value: ByteCountFormatter.string(fromByteCount: laws.byteCount, countStyle: .file))
                    if !laws.progress.isEmpty { Text(laws.progress).font(.caption) }
                    if laws.downloading { ProgressView() }
                    Button("Gesetzesbestand jetzt laden / aktualisieren") { Task { await laws.updateLaws() } }.keyOption(.action { Task { await laws.updateLaws() } }).disabled(laws.downloading)
                    NavigationLink("Gesetzessammlung öffnen") { LawReaderView() }
                }
                Section("Persönliche Daten") {
                    Text(laws.syncStatus).font(.caption)
                    Button("Jetzt synchronisieren") { Task { await laws.synchronize() } }.keyOption(.action { Task { await laws.synchronize() } }).disabled(laws.syncing || !sync || laws.user == nil || laws.sessionExpired)
                    Button("Markierungen und Lesezeichen sichern …") {
                        Task { do { exported = try await laws.exportPersonal() } catch { laws.error = error.localizedDescription } }
                    }
                    if let exported { ShareLink("Sicherungsdatei teilen …", item: exported) }
                    Button("Markierungen aus Sicherung ergänzen …") { restoring = true }
                    Text("Diese Sicherung enthält persönliche Gesetzesdaten, keine Anmeldeschlüssel. Sie ergänzt Heft- und Bibliotheksbackups und bleibt von Gesetzesdownloads getrennt.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }.navigationTitle("Gesetzessammlung")
            .keyboardSheet()
            .task { await laws.start() }
            .onAppear { laws.inlineErrorPages += 1 }
            .onDisappear { laws.inlineErrorPages -= 1 }
            .onChange(of: enabled) { _, _ in Task { await laws.settingsChanged() } }
            .onChange(of: sync) { _, _ in Task { await laws.settingsChanged(); await laws.synchronize() } }
            .onChange(of: updates) { _, _ in Task { await laws.settingsChanged() } }
            .fileImporter(isPresented: $restoring, allowedContentTypes: [.json]) { result in
                switch result { case .success(let url): Task { await laws.restorePersonal(url) }; case .failure(let error): laws.error = error.localizedDescription }
            }
    }
}
