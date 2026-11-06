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
                    Text("Nach dem Abmelden erscheinen nur Markierungen, die ohne Konto angelegt wurden. Lesezeichen und Markierungen dieses Kontos bleiben auf diesem iPad, auch noch nicht gesendete, und sind nach der nächsten Anmeldung wieder da.").font(.caption).foregroundStyle(.secondary)
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
                NavigationLink("Gesetzessammlung und Abgleich") { LawSettingsPage() }
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
    @AppStorage(LawLibraryModel.citationLinksKey) private var citationLinks = true
    @State private var exported: URL?
    @State private var restoring = false
    var body: some View {
        Form {
            Section {
                symbolToggle("Gesetzessammlung aktivieren", systemImage: "books.vertical", isOn: $enabled)
                symbolToggle("Lesezeichen und Markierungen abgleichen", systemImage: "arrow.triangle.2.circlepath", isOn: $sync)
                symbolToggle("Neue Gesetzesfassungen automatisch laden", systemImage: "arrow.down.circle", isOn: $updates)
            } footer: {
                Text("Der Abgleich mit dem Konto und neue Gesetzesfassungen sind unabhängig voneinander. Ohne Konto bleiben Markierungen auf diesem iPad. Nach dem ersten vollständigen Laden sind die Texte offline da; PDFs lassen sich einzeln laden.")
            }
            if enabled {
                Section {
                    symbolToggle("Gesetzesverweise im Heft verlinken", systemImage: "link", isOn: $citationLinks)
                } footer: {
                    Text("Verweise wie „§ 35a EStG“ auf Heftseiten werden dezent unterstrichen. Mit Apple Pencil oder Trackpad darüber halten oder mit dem Finger antippen zeigt eine Vorschau; Tippen auf die Vorschau öffnet die Vorschrift in der Gesetzessammlung. Im Heft wird dabei nichts gespeichert.")
                }
            }
            if let error = laws.error {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    Button("Hinweis schließen", systemImage: "xmark") { laws.error = nil }
                }
            }
            if enabled {
                Section("Offlinebestand") {
                    LabeledContent { Text("\(laws.entries.count)") } label: { Label("Dokumente", systemImage: "doc.text") }
                    LabeledContent { Text(ByteCountFormatter.string(fromByteCount: laws.byteCount, countStyle: .file)) } label: { Label("Speicher", systemImage: "internaldrive") }
                    if laws.downloading || !laws.progress.isEmpty {
                        LabeledContent {
                            if laws.downloading { ProgressView() }
                        } label: {
                            Label(laws.progress.isEmpty ? "Wird geladen …" : laws.progress, systemImage: "arrow.down.circle")
                        }
                    }
                    Button("Gesetzesbestand jetzt laden / aktualisieren", systemImage: "arrow.clockwise") { Task { await laws.updateLaws() } }.keyOption(.action { Task { await laws.updateLaws() } }).disabled(laws.downloading)
                    NavigationLink { LawReaderView() } label: { Label("Gesetzessammlung öffnen", systemImage: "book") }
                }
                Section("Persönliche Daten") {
                    LabeledContent { Text(laws.syncStatus).multilineTextAlignment(.trailing) } label: { Label("Abgleich", systemImage: "checkmark.icloud") }
                    Button("Jetzt abgleichen", systemImage: "arrow.triangle.2.circlepath") { Task { await laws.synchronize() } }.keyOption(.action { Task { await laws.synchronize() } }).disabled(laws.syncing || !sync || laws.user == nil || laws.sessionExpired)
                    Button("Markierungen und Lesezeichen sichern …", systemImage: "archivebox") {
                        Task { do { exported = try await laws.exportPersonal() } catch { laws.error = error.localizedDescription } }
                    }
                    if let exported { ShareLink(item: exported) { Label("Sicherungsdatei teilen …", systemImage: "square.and.arrow.up") } }
                    Button("Markierungen aus Sicherung ergänzen …", systemImage: "square.and.arrow.down") { restoring = true }
                    Text("Diese Sicherung enthält persönliche Gesetzesdaten, keine Anmeldeschlüssel. Sie ergänzt Heft- und Bibliotheksbackups und bleibt von Gesetzesdownloads getrennt.").font(.caption).foregroundStyle(.secondary)
                    if laws.hiddenItemCount > 0 {
                        LabeledContent { Text("\(laws.hiddenItemCount)") } label: { Label("Einträge anderer Konten", systemImage: "person.2") }
                        Text("Diese Einträge gehören zu einem anderen Konto oder wurden ohne Konto angelegt. Sie bleiben auf diesem iPad und erscheinen wieder, sobald ihr Konto angemeldet ist – ohne Konto angelegte nach dem Abmelden. Bis dahin werden sie nicht gesendet.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let notice = laws.personalNotice {
                    Section {
                        Label(notice, systemImage: "doc.on.doc")
                        Button("Hinweis schließen", systemImage: "xmark") { laws.personalNotice = nil }
                    } header: { Text("Reparatur") }
                }
                if !laws.rejectedItems.isEmpty { rejected }
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
    /// Entries the server refused for good (B9): send again, or keep them
    /// only on this iPad (visible here, never sent).
    private var rejected: some View {
        Section {
            ForEach(laws.rejectedItems, id: \.key) { item in
                VStack(alignment: .leading, spacing: 4) {
                    Text(rejectedTitle(item)).font(.subheadline)
                    if let rejection = item.rejection {
                        Text(rejection.message).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .swipeActions {
                    Button("Nur lokal") { Task { await laws.keepLocal([item]) } }.tint(.gray)
                    Button("Erneut") { Task { await laws.retryRejected([item]) } }.tint(.accentColor)
                }
            }
            Button("Erneut versuchen", systemImage: "arrow.clockwise") { Task { await laws.retryRejected() } }
                .keyOption(.action { Task { await laws.retryRejected() } })
                .disabled(laws.syncing || laws.user == nil || laws.sessionExpired)
            Button("Nur lokal behalten", systemImage: "ipad") { Task { await laws.keepLocal(laws.rejectedItems) } }
                .keyOption(.action { Task { await laws.keepLocal(laws.rejectedItems) } })
        } header: {
            Label("Vom Server abgelehnt", systemImage: "exclamationmark.triangle")
        } footer: {
            Text("„Nur lokal behalten“: Die Einträge bleiben auf diesem iPad sichtbar und werden nicht mehr gesendet. Einzelne Einträge per Wischen.")
        }
    }
    private func rejectedTitle(_ item: LawPersonalItem) -> String {
        let law = item.payload["lawId"]?.string.flatMap { id in laws.entries.first { $0.id == id }?.abbr } ?? item.payload["lawId"]?.string ?? "Gesetz"
        let what = item.kind == "bookmark" ? "Lesezeichen" : "Markierung"
        return "\(what) · \(law)"
    }
    /// `keyToggle` with a symbol, like the other settings pages.
    private func symbolToggle(_ title: String, systemImage: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) { Label(title, systemImage: systemImage) }.keyOption(.toggle(isOn))
    }
}
