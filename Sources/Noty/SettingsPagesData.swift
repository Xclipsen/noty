import SwiftUI
import NotebookCore

// Settings › Daten: Backup & Wiederherstellen, Papierkorb.

/// One page for everything that protects the notes: status at the top, the
/// daily automatic backup, the iCloud-Ablage, one „Wiederherstellen“
/// section and the manual library file. Details one level deeper.
struct BackupSettingsPage: View {
    @ObservedObject var library: LibraryModel
    @ObservedObject var toolbox: ToolbarSettingsModel
    @ObservedObject var externalBackup: ExternalBackupModel
    @ObservedObject var workspaces: WorkspaceAppModel
    let onSelectArea: ((TestWorkspace?) -> Void)?
    @ObservedObject private var vault = NotebookVaultModel.shared
    @State private var exporting = false
    /// One importer for both purposes: two `.fileImporter`s on one view conflict in SwiftUI.
    private enum ImportPurpose { case backupFolder, libraryArchive }
    @State private var importing = false
    @State private var importPurpose = ImportPurpose.libraryArchive
    @State private var showingForm = false
    @State private var showingHistory = false
    @State private var showingAreas = false
    @State private var restoredArea = false
    /// Status of the automatic backup when its last busy phase began (announcements).
    @State private var statusBeforeBackupWork: String?
    /// The pushed pages show backup errors themselves; avoid a second alert.
    @State private var formVisible = false
    @State private var file: LibraryArchiveFile?
    private var libraryIdle: Bool { library.ready && !library.busy && !workspaces.busy && library.opened == nil }
    private var health: BackupHealth { BackupHealth(externalBackup) }
    private var policy: ExternalBackupPolicy { externalBackup.policy }
    private var targetName: String {
        switch policy.target {
        case .disabled: "Keins"
        case .folder: policy.folderName ?? "Dateien-Ordner"
        case .webDAV: URL(string: policy.endpoint)?.host() ?? "WebDAV"
        }
    }
    private var lastBackup: String {
        if externalBackup.busy { return "Läuft …" }
        return policy.lastSuccess.map(NotyText.statusDate) ?? NotyText.never
    }
    var body: some View {
        Form {
            Section { statusCard }
            Section {
                if policy.target == .disabled {
                    Button("Backup-Ordner wählen …", systemImage: "folder.badge.plus") { pick(.backupFolder) }
                        .disabled(externalBackup.busy).keyOption(.action { pick(.backupFolder) })
                } else {
                    LabeledContent(policy.target == .webDAV ? "WebDAV" : "Backup-Ordner", value: targetName)
                    Button("Jetzt sichern", systemImage: "arrow.clockwise") {
                        Task { await externalBackup.attempt(library: library, toolbox: toolbox, manual: true) }
                    }.disabled(externalBackup.busy || !library.ready)
                        .keyOption(.action { Task { await externalBackup.attempt(library: library, toolbox: toolbox, manual: true) } })
                    if policy.target == .folder {
                        Button(health == .folderUnreachable ? "Backup-Ordner neu wählen …" : "Backup-Ordner ändern …", systemImage: "folder") { pick(.backupFolder) }
                            .disabled(externalBackup.busy).keyOption(.action { pick(.backupFolder) })
                    }
                }
                NavigationLink { backupForm } label: {
                    SettingLabel("Ziel und Aufbewahrung", detail: "WebDAV, Backup-Ordner, Anzahl der Stände, Fehlerdetails.")
                }
                .keyOption(.action { showingForm = true })
            } header: { Text("Automatisches Backup") } footer: {
                Text("Die ganze Bibliothek als eine geprüfte Datei, einmal am Tag. Am besten in einen Ordner in iCloud Drive oder auf einen WebDAV-Server.")
            }
            NotebookVaultSection(vault: vault, library: library, workspaces: workspaces)
            Section {
                LabeledContent("Letzter Export", value: library.lastLibraryExport.map(NotyText.statusDate) ?? NotyText.never)
                Button("Exportieren …", systemImage: "square.and.arrow.up", action: exportLibrary).disabled(!libraryIdle)
                    .keyOption(.action(exportLibrary))
            } header: { Text("Bibliotheksbackup als Datei") } footer: {
                Text("Alle Hefte, Ordner, der Papierkorb und die Werkzeugeinstellungen in einer Datei, etwa für ein anderes iPad. Dazu der Kalender: eigene und gelöschte Termine, Terminnotiz-Verknüpfungen, Fachfarben und der Offline-Stundenplan. WebUntis-Zugangsdaten sind nie enthalten; ein einzelnes Heftbackup enthält keinen Kalender.")
            }
            Section {
                NavigationLink { historyView } label: {
                    SettingLabel("Ältere automatische Backups", detail: "Inhalt ansehen und einzelne Hefte als Kopie zurückholen oder ersetzen.")
                }
                .disabled(policy.target == .disabled)
                .keyOption(.action { showingHistory = true })
                Button("Bibliotheksbackup-Datei öffnen …", systemImage: "arrow.down.doc") { pick(.libraryArchive) }
                    .disabled(!libraryIdle).keyOption(.action { pick(.libraryArchive) })
                if DeveloperAccess.showsAreas(workspaces) {
                    NavigationLink {
                        WorkspacePickerList(model: workspaces, onSelect: onSelectArea).keyboardSheet()
                    } label: { LabeledContent("Bereiche", value: workspaces.title) }
                    .disabled(library.busy && !library.backgroundBusy)
                    .keyOption(.action { showingAreas = true })
                }
            } header: { Text("Wiederherstellen") } footer: {
                Text("Eine Bibliotheksbackup-Datei öffnet sich als eigener Bereich neben deiner Bibliothek, erreichbar unten in der Seitenleiste der Bibliothek. Frühere Stände eines Hefts findest du im Heft unter „Lokale Wiederherstellungspunkte“. Gelöschte Hefte liegen zuerst im Papierkorb."
                     + (library.opened != nil ? " Export und Wiederherstellen erst nach dem Schließen des Hefts." : ""))
            }
        }
        .navigationTitle(SettingsPage.backup.title)
        .navigationDestination(isPresented: $showingForm) { backupForm }
        .navigationDestination(isPresented: $showingHistory) { historyView }
        .navigationDestination(isPresented: $showingAreas) { WorkspacePickerList(model: workspaces, onSelect: onSelectArea).keyboardSheet() }
        .keyboardSheet()
        .overlay { if library.busy || workspaces.busy || externalBackup.busy { ProgressView(activityTitle).padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) } }
        // Results of backup work for VoiceOver (polish audit F10); steps ending in „…“ stay silent.
        .onChange(of: library.backupStatus) { _, note in
            if !note.hasSuffix("…") { AccessibilityNotification.Announcement(note).post() }
        }
        // Only a new result: retrieving an archive leaves the status as it was,
        // so an unchanged (or still running „…“) status stays silent.
        .onChange(of: externalBackup.busy) { _, busy in
            if busy { statusBeforeBackupWork = externalBackup.status; return }
            let status = externalBackup.status
            if status != statusBeforeBackupWork, !status.hasSuffix("…") { AccessibilityNotification.Announcement(status).post() }
            statusBeforeBackupWork = nil
        }
        .onAppear { externalBackup.checkFolder() }
        .fileImporter(isPresented: $importing,
                      allowedContentTypes: importPurpose == .backupFolder ? [.folder] : [.notyLibrary, .data]) { result in
            if importPurpose == .backupFolder {
                if case .success(let url) = result { externalBackup.useFolder(url) }
                return
            }
            switch result {
            case .success(let url): Task {
                if await workspaces.restoreLibrary(url) {
                    library.backupStatus = "Bibliothek als neuen Bereich wiederhergestellt"
                    restoredArea = true
                }
            }
            case .failure(let error): library.error = error.localizedDescription
            }
        }
        .fileExporter(isPresented: $exporting, document: file, contentType: .notyLibrary,
                      defaultFilename: NotyText.libraryFileName()) { result in
            switch result {
            case .success: library.libraryBackupExported()
            case .failure(let error):
                library.backupStatus = "Bibliotheksbackup-Export nicht abgeschlossen"
                library.error = error.localizedDescription
            }
        }
        .alert("Backup", isPresented: Binding(get: { externalBackup.error != nil && !formVisible }, set: { if !$0 { externalBackup.error = nil } })) {
            Button("OK") { externalBackup.error = nil }
        } message: { Text(externalBackup.error ?? "") }
        .alert("Als neuen Bereich wiederhergestellt", isPresented: $restoredArea) {
            Button("OK", role: .cancel) { }
        } message: { Text(NotyText.restoredAreaMessage) }
    }

    /// Status first, T3-style: one card that says whether the notes are safe.
    private var statusCard: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: health.isSetUp ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                .font(.system(size: 30)).foregroundStyle(health.isSetUp ? Color.green : Color.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(health.shortTitle).font(.headline)
                Text("Letztes Backup: \(lastBackup)").font(.subheadline).foregroundStyle(.secondary)
                if !health.isSetUp, policy.target != .disabled {
                    Text(externalBackup.status).font(.footnote).foregroundStyle(.secondary).lineLimit(3)
                }
                if vault.available, vault.enabled { Text("iCloud-Ablage: \(vault.statusText)").font(.footnote).foregroundStyle(.secondary).lineLimit(2) }
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }

    private func pick(_ purpose: ImportPurpose) { importPurpose = purpose; importing = true }
    /// Words for the spinner: what is running (polish audit F8, labels only).
    private var activityTitle: String {
        if externalBackup.busy {
            // The external backup reports its steps; retrieving keeps the last note.
            return externalBackup.status.hasSuffix("…") ? externalBackup.status : "Backup wird geladen und geprüft …"
        }
        if workspaces.busy { return "Bereich wird übernommen …" }
        return "Bibliotheksbackup wird erstellt …"
    }
    private func exportLibrary() {
        Task {
            guard await toolbox.flush() else { library.error = toolbox.status; return }
            if let archive = await library.libraryBackup() { file = LibraryArchiveFile(url: archive.url); exporting = true }
        }
    }
    /// Both ways in (tap, keys) mark the page as showing its own backup errors.
    private var historyView: some View {
        OlderBackupsView(model: externalBackup, library: library, workspaces: workspaces)
            .onAppear { formVisible = true }.onDisappear { formVisible = false }
            .keyboardSheet()
    }
    private var backupForm: some View {
        ExternalBackupForm(model: externalBackup, library: library, workspaces: workspaces)
            .onAppear { formVisible = true }.onDisappear { formVisible = false }
            .keyboardSheet()
    }
}

/// The automatic backups on the active target, newest first. A backup opens
/// its contents (single notebooks back as a copy or in place of today's
/// state); the whole library or the file are one menu further.
struct OlderBackupsView: View {
    @ObservedObject var model: ExternalBackupModel
    @ObservedObject var library: LibraryModel
    @ObservedObject var workspaces: WorkspaceAppModel
    @State private var browsing: Browsed?
    @State private var exporting = false
    @State private var file: LibraryArchiveFile?
    @State private var restored = false
    @State private var loaded = false
    struct Browsed: Identifiable { let name: String; var id: String { name } }

    var body: some View {
        List {
            Section {
                ForEach(model.history, id: \.self) { name in row(name).keyOption(.action { browsing = Browsed(name: name) }) }
                if model.history.isEmpty {
                    Text(loaded ? "Am Ziel liegen noch keine automatischen Backups." : "Liste wird geladen …").foregroundStyle(.secondary)
                }
            } footer: {
                Text("Antippen zeigt, welche Hefte das Backup enthält und was sich seitdem geändert hat. Zurückgeholte Hefte kommen als Kopie in die Bibliothek; „Ersetzen“ legt den heutigen Stand vorher in den Papierkorb.")
            }
        }
        .navigationTitle("Ältere Backups")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Neu laden", systemImage: "arrow.clockwise") { Task { await reload() } }.disabled(model.busy)
            }
        }
        .disabled(model.busy || workspaces.busy)
        .overlay { if model.busy { ProgressView(model.status.hasSuffix("…") ? model.status : "Backup wird geladen und geprüft …").padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) } }
        .task { if !loaded { await reload() } }
        .refreshable { await reload() }
        .sheet(item: $browsing) { backup in BackupContentsView(name: backup.name, model: model, library: library) }
        .fileExporter(isPresented: $exporting, document: file, contentType: .notyLibrary, defaultFilename: NotyText.libraryFileName()) { result in
            if let url = file?.url { BackupScratch.remove(url) }
            file = nil
            if case .failure = result { model.error = "Export nicht abgeschlossen." }
        }
        .alert("Backup", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
        .alert("Als neuen Bereich wiederhergestellt", isPresented: $restored) {
            Button("OK", role: .cancel) { }
        } message: { Text(NotyText.restoredAreaMessage) }
    }

    private func reload() async {
        do { try await model.reloadHistory() } catch { model.error = "Liste konnte nicht geladen werden. Backup-Ziel prüfen." }
        loaded = true
    }

    private func row(_ name: String) -> some View {
        HStack(spacing: 12) {
            Button { browsing = Browsed(name: name) } label: {
                HStack(spacing: 12) {
                    Image(systemName: "archivebox").foregroundStyle(.tint).frame(width: 26).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(NotyText.listDate(Date(timeIntervalSince1970: model.policy.timestamp(name) ?? 0), seconds: true))
                        if model.placeholders.contains(name) {
                            Text("Nur in iCloud, wird beim Öffnen geladen").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Menu {
                Button("Inhalt ansehen …", systemImage: "list.bullet.rectangle") { browsing = Browsed(name: name) }
                Button("Ganze Bibliothek als eigenen Bereich öffnen …", systemImage: "square.stack") { Task {
                    guard let archive = await model.retrieve(name) else { return }
                    defer { BackupScratch.remove(archive.url) }
                    restored = await workspaces.restoreLibrary(archive.url)
                    if !restored { model.error = workspaces.error ?? "Wiederherstellung fehlgeschlagen."; workspaces.error = nil }
                } }
                Button("Datei exportieren …", systemImage: "square.and.arrow.up") { Task {
                    if let archive = await model.retrieve(name) { file = LibraryArchiveFile(url: archive.url); exporting = true }
                } }
            } label: { Image(systemName: "ellipsis.circle").font(.title3).frame(width: 44, height: 44) }
                .accessibilityLabel("Weitere Aktionen")
        }
    }
}

struct TrashSettingsPage: View {
    @ObservedObject var library: LibraryModel
    @ObservedObject var workspaces: WorkspaceAppModel
    @State private var purging: NotebookCore.LibraryItem?
    @State private var confirmingEmpty = false
    private var editable: Bool { library.ready && !library.busy && library.opened == nil }
    private var items: [NotebookCore.LibraryItem] { library.trashedItems }
    var body: some View {
        List {
            if library.opened != nil {
                Section { Label("Bei geöffnetem Heft kann der Papierkorb nicht bearbeitet werden.", systemImage: "info.circle").font(.callout) }
            }
            if let status = library.trashStatus {
                Section { Text(status).font(.callout) }
            }
            Section {
                ForEach(items) { item in row(item).keyOption(.action { ask(item) }) }
            } footer: {
                Text("Einträge im Papierkorb bleiben vollständig gespeichert und sind in Bibliotheksbackups enthalten. noty leert den Papierkorb nie automatisch. Ordner stellen ihren Inhalt mit wieder her.")
            }
            if !items.isEmpty {
                Section {
                    Button("Papierkorb leeren …", systemImage: "trash.slash", role: .destructive) { confirmingEmpty = true }
                        .disabled(!editable)
                        .keyOption(.action {
                            KeyboardRouter.shared.ask("Papierkorb leeren?", message: "Alle Einträge im Papierkorb einschließlich enthaltener Ordnerinhalte werden vom iPad entfernt. Das kann nicht rückgängig gemacht werden.",
                                                      confirm: "\(NotyText.count(items.count, "Eintrag", "Einträge")) endgültig löschen", safe: true) { Task { await library.emptyTrash() } }
                        })
                }
            }
        }
        .overlay {
            if items.isEmpty {
                ContentUnavailableView("Papierkorb ist leer", systemImage: "trash",
                                       description: Text("Gelöschte Hefte, Textdokumente und Ordner erscheinen hier, bis sie wiederhergestellt oder endgültig gelöscht werden."))
            } else if library.busy { ProgressView("Papierkorb wird bearbeitet …") }
        }
        .navigationTitle(workspaces.areaID == nil ? SettingsPage.trash.title : "Papierkorb · \(NotyText.isolated(workspaces.title))")
        .navigationBarTitleDisplayMode(.inline)
        .keyboardSheet()
        .confirmationDialog("Endgültig löschen?", isPresented: Binding(get: { purging != nil }, set: { if !$0 { purging = nil } }),
                            titleVisibility: .visible, presenting: purging) { item in
            // Fixed verb: a long title in the button would truncate the action away; the name is in the message.
            Button("Endgültig löschen", role: .destructive) {
                purging = nil
                Task { await library.purge([item.id]) }
            }
            Button("Abbrechen", role: .cancel) { purging = nil }
        } message: { item in
            Text(purgeMessage(item))
        }
        .confirmationDialog("Papierkorb leeren?", isPresented: $confirmingEmpty, titleVisibility: .visible) {
            Button("\(NotyText.count(items.count, "Eintrag", "Einträge")) endgültig löschen", role: .destructive) { Task { await library.emptyTrash() } }
            Button("Abbrechen", role: .cancel) { }
        } message: {
            Text("Alle Einträge im Papierkorb einschließlich enthaltener Ordnerinhalte werden vom iPad entfernt. Das kann nicht rückgängig gemacht werden. Ältere Backups enthalten diese Einträge weiterhin.")
        }
        .onDisappear { library.trashStatus = nil }
    }

    /// Enter on a row: what its menu offers, the final step with its own question.
    private func ask(_ item: NotebookCore.LibraryItem) {
        guard editable else { return }
        var options = [KeyQuestion.Option(title: "Wiederherstellen") { Task { await library.restore(item.id) } }]
        if item.source != .legacyMain {
            options.append(KeyQuestion.Option(title: "Endgültig löschen …", destructive: true) {
                KeyboardRouter.shared.ask("Endgültig löschen?", message: purgeMessage(item), confirm: "Endgültig löschen", safe: true) {
                    Task { await library.purge([item.id]) }
                }
            })
        }
        options.append(KeyQuestion.Option(title: "Abbrechen"))
        KeyboardRouter.shared.present(KeyQuestion(title: item.title, message: "", options: options, chosen: options[0].id))
    }
    private func row(_ item: NotebookCore.LibraryItem) -> some View {
        HStack(spacing: 14) {
            Image(systemName: item.librarySymbol(filled: false)).font(.title3).foregroundStyle(.secondary).frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title).lineLimit(2).truncationMode(.middle)
                // One string: separate texts each wrapped into ragged mini-columns.
                Text(details(item)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            Menu {
                Button("Wiederherstellen", systemImage: "arrow.uturn.backward") { Task { await library.restore(item.id) } }
                if item.source != .legacyMain {
                    Button("Endgültig löschen …", systemImage: "trash.slash", role: .destructive) { purging = item }
                }
            } label: { Image(systemName: "ellipsis.circle").font(.title3).frame(width: 44, height: 44) }
                .accessibilityLabel("Aktionen für \(item.title)")
                .disabled(!editable)
        }
        .swipeActions(edge: .trailing) {
            if item.source != .legacyMain {
                Button("Endgültig löschen …", systemImage: "trash.slash", role: .destructive) { purging = item }.disabled(!editable)
            }
            Button("Wiederherstellen", systemImage: "arrow.uturn.backward") { Task { await library.restore(item.id) } }
                .tint(.blue).disabled(!editable)
        }
        .contextMenu {
            Button("Wiederherstellen", systemImage: "arrow.uturn.backward") { Task { await library.restore(item.id) } }.disabled(!editable)
            if item.source != .legacyMain {
                Button("Endgültig löschen …", systemImage: "trash.slash", role: .destructive) { purging = item }.disabled(!editable)
            }
        }
    }

    private func details(_ item: NotebookCore.LibraryItem) -> String {
        var parts: [String] = []
        if let date = item.deletedAt { parts.append("Gelöscht \(NotyText.listDate(date))") }
        let count = library.purgeCount(item) - 1
        if item.isFolder, count > 0 { parts.append(NotyText.count(count, "enthaltener Eintrag", "enthaltene Einträge")) }
        if item.source == .legacyMain { parts.append("Ursprüngliches Heft") }
        return parts.joined(separator: " · ")
    }

    private func purgeMessage(_ item: NotebookCore.LibraryItem) -> String {
        let contained = library.purgeCount(item) - 1
        let content = !item.isFolder || contained <= 0 ? ""
            : contained == 1 ? " einschließlich 1 enthaltenen Eintrags" : " einschließlich \(contained) enthaltener Einträge"
        return "\(NotyText.quoted(item.title))\(content) wird vom iPad entfernt. Das kann nicht rückgängig gemacht werden. Ältere Backups enthalten den Eintrag weiterhin."
    }
}
