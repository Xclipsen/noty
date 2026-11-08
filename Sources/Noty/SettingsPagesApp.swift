import SwiftUI
import NotebookCore

// Settings: Allgemein, Darstellung, Über noty, Datenschutz, Entwickler.

struct GeneralSettingsPage: View {
    @AppStorage(AppSettingsKey.homeLayout) private var layout = LibraryLayout.grid
    @AppStorage(AppSettingsKey.librarySort) private var sort = LibrarySort.manual
    @AppStorage(AppSettingsKey.reopenLastNotebook) private var reopen = true
    @State private var confirmingReset = false
    @State private var resetDone = false
    var body: some View {
        Form {
            Section {
                Picker("Darstellung", selection: $layout) {
                    ForEach(LibraryLayout.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
                }.keyOption(.choice($layout, LibraryLayout.allCases))
                Picker("Sortierung", selection: $sort) {
                    ForEach(LibrarySort.allCases) { Text($0.title).tag($0) }
                }.keyOption(.choice($sort, LibrarySort.allCases))
            } header: { Text("Bibliothek") } footer: {
                Text("Auch über das Menü oben in der Bibliothek änderbar. Die Sortierung ändert nur die Anzeige, nie deine eigene Reihenfolge.")
            }
            Section("Beim Start") {
                settingToggle("Zuletzt geöffnetes Heft wieder öffnen",
                              detail: "noty startet mit dem Heft oder Textdokument, das beim letzten Mal offen war. Aus: noty startet immer in der Bibliothek.",
                              isOn: $reopen)
            }
            Section {
                Button("Einstellungen zurücksetzen …", role: .destructive) { confirmingReset = true }
                    .keyOption(.action { confirmingReset = true })
            } footer: {
                Text(resetDone ? "Zurückgesetzt." : "Setzt Bibliothek, Darstellung, Ansicht und Text auf die Standardwerte. Stift-, Werkzeug- und Papiereinstellungen, Backups, Konto und alle Hefte bleiben unverändert.")
            }
        }
        .navigationTitle(SettingsPage.general.title)
        .keyboardSheet()
        .confirmationDialog("Einstellungen zurücksetzen?", isPresented: $confirmingReset, titleVisibility: .visible) {
            Button("Zurücksetzen", role: .destructive) {
                AppSettingsKey.resettable.forEach { UserDefaults.standard.removeObject(forKey: $0) }
                resetDone = true
            }
        } message: {
            Text("Bibliothek, Darstellung, Ansicht und Text bekommen wieder die Standardwerte. Deine Hefte und Werkzeuge bleiben unverändert.")
        }
    }
}

struct AppearanceSettingsPage: View {
    @AppStorage(AppSettingsKey.accent) private var accent = AccentChoice.blue
    var body: some View {
        Form {
            Section {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: 12)], spacing: 18) {
                    ForEach(AccentChoice.allCases) { choice in swatch(choice) }
                }
                .padding(.vertical, 10)
                .keyOption(.choice($accent, AccentChoice.allCases))
            } header: { Text("Akzentfarbe") } footer: {
                Text("Färbt Schalter, Auswahl, Ordner und Hervorhebungen in Bibliothek und Einstellungen. Stifte, Papier und die Werkzeugleiste im Heft bleiben unverändert.")
            }
            Section("Vorschau") {
                HStack(spacing: 14) {
                    Image(systemName: "folder.fill").font(.title).foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Mathe")
                        Text("12 Hefte").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "checkmark").foregroundStyle(.tint)
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.tint.opacity(0.18)))
                Toggle("Schalter", isOn: .constant(true)).allowsHitTesting(false)
                Button("Schaltfläche") { }.allowsHitTesting(false)
            }
            .accessibilityHidden(true)
            Section {
                LabeledContent("Erscheinungsbild", value: "Dunkel")
            } footer: {
                Text("noty ist auf eine dunkle Oberfläche abgestimmt, damit das Papier im Mittelpunkt steht. Die Papierfarbe stellst du je Heft unter „Papier“ ein.")
            }
        }
        .navigationTitle(SettingsPage.appearance.title)
        .keyboardSheet()
    }

    private func swatch(_ choice: AccentChoice) -> some View {
        let chosen = accent == choice
        return Button { accent = choice } label: {
            VStack(spacing: 7) {
                ZStack {
                    Circle().fill(choice.color.gradient).frame(width: 46, height: 46)
                    if chosen {
                        Circle().strokeBorder(Color.white.opacity(0.9), lineWidth: 3).frame(width: 46, height: 46)
                        Image(systemName: "checkmark").font(.headline.weight(.bold)).foregroundStyle(.white)
                    }
                }
                .shadow(color: choice.color.opacity(chosen ? 0.55 : 0), radius: 8)
                Text(choice.title).font(.caption).foregroundStyle(chosen ? .primary : .secondary)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(choice.title)
        .accessibilityAddTraits(chosen ? .isSelected : [])
        .sensoryFeedback(.selection, trigger: chosen)
    }
}

struct AboutSettingsPage: View {
    @ObservedObject var workspaces: WorkspaceAppModel
    @AppStorage(AppSettingsKey.developerMode) private var developerMode = false
    @State private var taps = 0
    @State private var copied = false
    private func info(_ key: String) -> String { Bundle.main.object(forInfoDictionaryKey: key) as? String ?? "–" }
    private var versionLine: String { "\(AppSyncModel.shared.channel?.appName ?? "noty") \(info("CFBundleShortVersionString")) (Build \(info("CFBundleVersion")))" }
    var body: some View {
        Form {
            Section {
                SettingsHeaderCard()
                LabeledContent("Version", value: info("CFBundleShortVersionString"))
                Button { tappedBuild() } label: {
                    LabeledContent("Build") {
                        Text(copied ? "Kopiert" : info("CFBundleVersion")).monospacedDigit()
                    }
                }
                .buttonStyle(.plain)
                .accessibilityHint("Kopiert Version und Build")
                .sensoryFeedback(.success, trigger: copied)
                .keyOption(.action { tappedBuild() })
                if let channel = AppSyncModel.shared.channel, channel != .stable {
                    LabeledContent("App", value: channel.appName)
                }
            } footer: {
                Text(developerMode && !DeveloperAccess.isTestApp ? "Entwickleroptionen sind eingeschaltet." : "Tippen auf den Build kopiert Version und Build, etwa für eine Fehlermeldung.")
            }
            Section {
                LabeledContent("Hefte und Textdokumente", value: "Dateien › Auf meinem iPad › noty")
            } header: { Text("Datenablage") } footer: {
                Text("Alles liegt lokal auf diesem iPad und ist über die Dateien-App sichtbar. Dort bitte nichts umbenennen oder verschieben.")
            }
            SigningRenewalSection()
            Section {
                Text("Gesetzestexte und Lesezeichen-Abgleich der Gesetzessammlung kommen von law.xclipsen.de. noty verwendet keine Bibliotheken von Drittanbietern.")
                    .font(.footnote).foregroundStyle(.secondary)
            } header: { Text("Hinweise") }
        }
        .navigationTitle(SettingsPage.about.title)
        .keyboardSheet()
    }

    private func tappedBuild() {
        UIPasteboard.general.string = versionLine
        copied = true
        Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
        guard !DeveloperAccess.isTestApp, !developerMode else { return }
        taps += 1
        if taps >= 7 { developerMode = true; taps = 0 }
    }
}

struct PrivacySettingsPage: View {
    @ObservedObject private var vault = NotebookVaultModel.shared
    var body: some View {
        Form {
            Section {
                Label {
                    Text("Hefte, Textdokumente und Einstellungen liegen auf diesem iPad. noty enthält keine Werbung, keine Nutzungsanalyse und kein Tracking.")
                } icon: { Image(systemName: "lock.shield.fill").foregroundStyle(.green) }
            }
            Section {
                flow("externaldrive.fill", "Automatisches Backup",
                     "Nur wenn du ein Ziel einrichtest: Bibliotheksbackups gehen in den gewählten Ordner (etwa iCloud Drive) oder auf deinen WebDAV-Server. WebDAV-Zugangsdaten liegen nur im Schlüsselbund dieses iPads.")
                if vault.available {
                    flow("icloud.fill", "iCloud-Ablage",
                         "Nur wenn eingeschaltet: einzelne Hefte im iCloud-Ordner dieser App in deinem iCloud-Konto.")
                }
                flow("books.vertical.fill", "Gesetzessammlung und noty-Konto",
                     "Gesetzestexte werden von law.xclipsen.de geladen. Mit Konto werden E-Mail-Adresse, Lesezeichen und Markierungen dorthin abgeglichen, auf Wunsch mit „Mit Apple anmelden“. Hefte werden nie übertragen.")
                flow("square.and.arrow.up.fill", "Teilen und Export",
                     "Nur auf deinen Befehl: PDF, .noty-Dateien und Bibliotheksbackups gehen an die App oder Person, die du wählst.")
                flow("arrow.triangle.2.circlepath", "Zwischen noty-Apps",
                     "Die normale noty legt eine Kopie der Bibliothek in einen gemeinsamen Ordner auf diesem iPad, den nur noty dev, noty AI und noty calendar lesen. Dabei verlässt nichts das iPad.")
                if DeveloperAccess.visible {
                    flow("stethoscope", "Diagnose",
                         "Eingeschaltete Diagnosen schreiben nur Codeadressen, Klassennamen und Zähler nach Dateien › noty › Diagnose, nie Inhalte. Sie bleiben auf dem iPad.")
                }
            } header: { Text("Wann Daten das iPad verlassen") }
        }
        .navigationTitle(SettingsPage.privacy.title)
        .keyboardSheet()
    }

    private func flow(_ symbol: String, _ title: String, _ detail: String) -> some View {
        Label {
            SettingLabel(title, detail: detail)
        } icon: { Image(systemName: symbol).foregroundStyle(.tint) }
        .accessibilityElement(children: .combine)
    }
}

/// Test and developer tools: in noty dev, noty AI and noty calendar always,
/// in the normal noty only after unlocking (seven taps on the build).
struct DeveloperSettingsPage: View {
    @ObservedObject var library: LibraryModel
    @ObservedObject var toolbox: ToolbarSettingsModel
    @ObservedObject var workspaces: WorkspaceAppModel
    let onSelectArea: ((TestWorkspace?) -> Void)?
    @AppStorage(AppSettingsKey.hangProbe) private var hangProbe = false
    @AppStorage(AppSettingsKey.inputProbe) private var inputProbe = InputProbe.defaultEnabled
    @AppStorage(AppSettingsKey.tapDiagnostics) private var tapDiagnostics = false
    @AppStorage(AppSettingsKey.textEditor2) private var textEditor2 = false
    @AppStorage(AppSettingsKey.developerMode) private var developerMode = false
    @State private var showingAreas = false
    var body: some View {
        Form {
            Section {
                NavigationLink {
                    WorkspacePickerList(model: workspaces, onSelect: onSelectArea).keyboardSheet()
                } label: {
                    LabeledContent("Bereiche", value: workspaces.title)
                }
                .disabled(library.busy && !library.backgroundBusy)
                .keyOption(.action { showingAreas = true })
            } header: { Text("Bereiche") } footer: {
                Text("Getrennte Test- und Restore-Bereiche mit eigenen Heften und Einstellungen. Für die finale Version nicht vorgesehen.")
            }
            AppSyncSection(library: library, toolbox: toolbox, workspaces: workspaces)
            Section {
                settingToggle("Hänger-Diagnose", detail: "Schreibt bei längeren Hängern Codeadressen und Zähler nach Dateien › noty › Diagnose › haenger.txt. Wirkt nach einem Neustart der App.", isOn: $hangProbe)
                settingToggle("Eingabe-Diagnose", detail: "Meldet Berührungen ohne Wirkung und lange Eingabesperren nach Diagnose › eingabe.txt, nur Klassennamen und Zustände. Wirkt nach einem Neustart der App.", isOn: $inputProbe)
                settingToggle("Tipp-Diagnose", detail: "Zeigt nach jedem Tipp, was er getroffen hat und welche Felder dort liegen, nur Größen, keine Inhalte.", isOn: $tapDiagnostics)
                    .onChange(of: tapDiagnostics) { _, _ in TapDiagnostics.shared.refresh() }
            } header: { Text("Diagnose") }
            Section("Experimente") {
                settingToggle("Neuer Texteditor", detail: "Ein Text über alle Seiten eines Textdokuments, im Blättermodus aus, noch ohne Formatleiste. Wirkt beim nächsten Öffnen eines Dokuments.", badge: "Test", isOn: $textEditor2)
            }
            Section("Interna") {
                LabeledContent("Werkzeugformat", value: "\(toolbox.preferences.formatVersion)")
                LabeledContent("Bibliotheksindex", value: "Format \(library.snapshot.formatVersion)")
                LabeledContent("Test-/Restore-Bereiche", value: "noty › NotyWorkspaces")
                LabeledContent("App", value: AppSyncModel.shared.channel?.appName ?? "nicht zugeordnet")
            }
            if !DeveloperAccess.isTestApp {
                Section {
                    Button("Entwickleroptionen ausblenden") { developerMode = false }
                        .keyOption(.action { developerMode = false })
                }
            }
        }
        .navigationTitle(SettingsPage.developer.title)
        .navigationDestination(isPresented: $showingAreas) { WorkspacePickerList(model: workspaces, onSelect: onSelectArea).keyboardSheet() }
        .keyboardSheet()
    }
}
