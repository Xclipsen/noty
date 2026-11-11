import SwiftUI
import NotebookCore

// BACKUP-RESTORE-PLAN Phase 2: one place „Wiederherstellen“ in the settings.
// A notebook's timeline lists its local states, the automatic backups that
// hold a state of it (from the local summaries, Phase 3) and its versions in
// the iCloud-Ablage; each comes back into the normal library as a copy
// (default) or in place of today's state, which goes to the trash first.
// Everything takes the checked `.noty` import path; no Bereich, no
// „Wiederhergestellte Kopien“.

/// Requests from places that cannot present the restore views themselves:
/// the editor („Älteren Stand wiederherstellen …“ closes the notebook, then
/// the library shows its timeline) and a `.notylibrary` opened from Files.
/// The library shows them only while it is free (no notebook open, nothing
/// presented above it), so a request never gets stuck behind Settings or the
/// area list. Settings and the area list present their own views locally.
@MainActor
final class RestoreRouter: ObservableObject {
    static let shared = RestoreRouter()
    struct Timeline: Identifiable, Equatable { let id: UUID }
    struct Archive: Identifiable { let id = UUID(); let url: URL; let title: String; var selectAll = false }
    /// Presented by the library; set only while it is free.
    @Published var timeline: Timeline?
    @Published var archive: Archive?
    private var pendingTimeline: (id: UUID, at: Date)?
    private var pendingArchive: Archive?
    private var showing: Task<Void, Never>?
    /// Kept up to date by the library.
    var libraryFree = false { didSet { if libraryFree != oldValue { schedule() } } }
    private init() {}

    /// The editor closes its notebook right after this; the timeline appears
    /// once the library is free again. A request that waited longer than a
    /// minute (closing failed, the user went elsewhere) is dropped.
    func requestTimeline(_ id: UUID) {
        pendingTimeline = (id, Date())
        schedule()
    }

    /// A checked copy of a library backup file; the router owns it until the
    /// contents view takes it. Shown now or when the library is free again.
    /// False (file removed) while another one is shown or waiting.
    func show(_ request: Archive) -> Bool {
        guard archive == nil, pendingArchive == nil else { BackupScratch.remove(request.url); return false }
        pendingArchive = request
        schedule()
        return true
    }

    /// Waits for the library to be free (e.g. the editor's cover has finished
    /// closing), so the sheet is never presented during another presentation.
    private func schedule() {
        guard libraryFree, pendingTimeline != nil || pendingArchive != nil else { return }
        showing?.cancel()
        showing = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled, let self, self.libraryFree, self.timeline == nil, self.archive == nil else { return }
            if let pending = self.pendingTimeline {
                self.pendingTimeline = nil
                if Date().timeIntervalSince(pending.at) < 60 { self.timeline = Timeline(id: pending.id); return }
            }
            if let pending = self.pendingArchive { self.pendingArchive = nil; self.archive = pending }
        }
    }
}

/// Settings › Wiederherstellen.
struct RestoreSettingsPage: View {
    @ObservedObject var library: LibraryModel
    @ObservedObject var externalBackup: ExternalBackupModel
    @ObservedObject var workspaces: WorkspaceAppModel
    @ObservedObject private var vault = NotebookVaultModel.shared
    @State private var picking = false
    @State private var showingBackups = false
    @State private var showingVault = false
    @State private var adopting = Set<UUID>()
    @State private var report: String?
    /// A library backup file chosen here: shown above Settings, not by the library.
    @State private var openedFile: RestoreRouter.Archive?

    private var activeCopies: [RestoredNotebook] {
        library.restoredCopies.compactMap { copy -> RestoredNotebook? in
            guard let item = library.snapshot.items.first(where: { $0.id == copy.id }), !library.snapshot.isTrashed(copy.id) else { return nil }
            var result = copy; result.title = item.title; return result
        }
    }

    var body: some View {
        Form {
            if library.opened != nil {
                Section { Label("Zum Zurückholen bitte zuerst das geöffnete Heft schließen.", systemImage: "info.circle").font(.callout) }
            }
            Section {
                NavigationLink { NotebookPickerView(library: library, externalBackup: externalBackup) } label: {
                    SettingLabel("Ein Heft auf einen früheren Stand bringen", detail: "Lokale Stände, automatische Backups und die iCloud-Ablage dieses Hefts in einer Zeitleiste.")
                }
            } header: { Text("Ein Heft") } footer: {
                Text("Auch aus einem geöffneten Heft: „…“ › „Älteren Stand wiederherstellen …“. Gelöscht? Zuerst im Papierkorb nachsehen.")
            }
            Section {
                NavigationLink { OlderBackupsView(model: externalBackup, library: library, workspaces: workspaces) } label: {
                    SettingLabel("Automatische Backups", detail: externalBackup.policy.target == .disabled
                                 ? "Kein automatisches Backup eingerichtet."
                                 : "Inhalt ansehen, einzelne Hefte oder die ganze Bibliothek zurückholen.")
                }
                .disabled(externalBackup.policy.target == .disabled)
                .keyOption(.action { showingBackups = true })
                if vault.enabled {
                    NavigationLink { VaultBrowserView(vault: vault, library: library) } label: {
                        SettingLabel("iCloud-Ablage", detail: "Die Stände jedes Hefts in iCloud.")
                    }
                    .keyOption(.action { showingVault = true })
                }
                Button("Bibliotheksbackup-Datei öffnen …", systemImage: "arrow.down.doc") { picking = true }
                    .disabled(library.opened != nil || library.busy)
            } header: { Text("Ganze Bibliothek") } footer: {
                Text("Ein Backup zeigt, was sich seitdem geändert hat. Zurückgeholt wird in deine Bibliothek: als Kopie, an Stelle des heutigen Stands (der in den Papierkorb kommt) oder für alles auf einmal mit „Ganze Bibliothek auf diesen Stand bringen“.")
            }
            Section {
                NavigationLink { TrashSettingsPage(library: library, workspaces: workspaces) } label: {
                    SettingLabel("Papierkorb", detail: "Gelöschte Hefte und Ordner zurücklegen.")
                }
            }
            if !activeCopies.isEmpty {
                Section {
                    ForEach(activeCopies) { copy in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(copy.title).lineLimit(2).truncationMode(.middle)
                                if let date = copy.modifiedAt { Text(NotyText.listDate(date)).font(.caption).foregroundStyle(.secondary) }
                            }
                            Spacer()
                            Button("In Bibliothek übernehmen") { Task { await adopt(copy) } }
                                .disabled(adopting.contains(copy.id) || library.opened != nil)
                        }
                    }
                } header: { Text("Wiederhergestellte Kopien (alt)") } footer: {
                    Text("Ältere Versionen von noty legten wiederhergestellte Stände getrennt ab. „In Bibliothek übernehmen“ macht daraus ein normales Heft; die alte Kopie kommt in den Papierkorb.")
                }
            }
        }
        .navigationTitle("Wiederherstellen")
        .navigationDestination(isPresented: $showingBackups) { OlderBackupsView(model: externalBackup, library: library, workspaces: workspaces) }
        .navigationDestination(isPresented: $showingVault) { VaultBrowserView(vault: vault, library: library) }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.notyLibrary]) { result in
            guard case .success(let url) = result else { return }
            Task { if let copy = await RestoreArchives.copyLibraryFile(url) { openedFile = RestoreRouter.Archive(url: copy, title: "Bibliotheksbackup") } }
        }
        .sheet(item: $openedFile) { request in
            BackupContentsView(source: .file(request.url, title: request.title), library: library,
                               openAsArea: DeveloperAccess.visible ? { url in await workspaces.restoreLibrary(url) } : nil)
        }
        .alert("Wiederherstellen", isPresented: Binding(get: { report != nil }, set: { if !$0 { report = nil } })) {
            Button("OK") { report = nil }
        } message: { Text(report ?? "") }
        .keyboardSheet()
    }

    /// An old restored copy becomes an ordinary notebook (same checked import).
    private func adopt(_ copy: RestoredNotebook) async {
        guard let item = library.snapshot.items.first(where: { $0.id == copy.id }) else { return }
        adopting.insert(copy.id); defer { adopting.remove(copy.id) }
        guard let file = await library.shareFile(for: item) else { report = library.error; library.error = nil; return }
        defer { BackupScratch.removeShare(file) }
        if let imported = await library.importBackup(file, parent: nil, collision: .keepBoth, title: item.title) {
            await library.trash(copy.id)
            report = "„\(imported.title)“ liegt jetzt in der Bibliothek. Die alte Kopie ist im Papierkorb."
        } else {
            report = (library.error ?? "Die Bibliothek ist gerade beschäftigt.") + " Es wurde nichts verändert."
            library.error = nil
        }
    }
}

/// Opening a library backup file: its contents (BackupContentsView), never a
/// new Bereich in the normal noty; the test apps may also open it as one.
@MainActor
enum RestoreArchives {
    /// A bounded copy in the scratch folder (the contents view owns it), or nil
    /// after telling the user.
    static func copyLibraryFile(_ url: URL) async -> URL? {
        let copy: URL
        do {
            copy = try BackupScratch.newFile("notylibrary")
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            try await Task.detached(priority: .userInitiated) {
                try CoordinatedBackupFiles().reading(url, metadataOnly: false) { source in
                    _ = try BoundedFile.copy(from: source, to: copy, limit: LibraryArchive.maximumBytes)
                }
            }.value
        } catch {
            TopAlert.show("Datei nicht lesbar", "Die Datei konnte nicht in noty kopiert werden. Es wurde nichts verändert.")
            return nil
        }
        return copy
    }
}

/// Choose the notebook whose timeline to show.
struct NotebookPickerView: View {
    @ObservedObject var library: LibraryModel
    @ObservedObject var externalBackup: ExternalBackupModel
    @State private var search = ""

    private var notebooks: [NotebookCore.LibraryItem] {
        library.snapshot.items
            .filter { !$0.isFolder && !library.snapshot.isTrashed($0.id) && $0.source != .restored }
            .filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    var body: some View {
        List(notebooks) { item in
            NavigationLink {
                NotebookTimelineView(notebookID: item.id, library: library, externalBackup: externalBackup)
            } label: {
                Label(item.title, systemImage: item.isTextDocument ? "doc.text" : "book.closed").lineLimit(2)
            }
        }
        .overlay { if notebooks.isEmpty { ContentUnavailableView.search(text: search) } }
        .searchable(text: $search, prompt: "Heft suchen")
        .navigationTitle("Heft wählen")
    }
}

/// All earlier states of one notebook, newest first.
struct NotebookTimelineView: View {
    let notebookID: UUID
    @ObservedObject var library: LibraryModel
    @ObservedObject var externalBackup: ExternalBackupModel
    /// „Öffnen“ after restoring: the presenter closes this view first, then
    /// opens the notebook. Nil (Settings): no „Öffnen“.
    var onOpen: ((UUID) -> Void)?
    @ObservedObject private var vault = NotebookVaultModel.shared
    @State private var states: [TimelineState] = []
    @State private var loading = true
    @State private var notes: [String] = []
    @State private var working: String?
    @State private var replacing: TimelineState?
    @State private var report: Report?
    struct Report: Identifiable { let id = UUID(); let title: String; let message: String; var open: UUID? }

    struct TimelineState: Identifiable {
        enum Source { case local(UUID), backup(String), vault(VaultVersion) }
        let id: String
        let source: Source
        let date: Date
        let pageCount: Int?
        let title: String
        /// „auf diesem iPad“, „iCloud Drive“, …
        let place: String
        var extra: String?
        var symbol: String {
            switch source { case .local: "ipad"; case .backup: "archivebox"; case .vault: "icloud" }
        }
    }

    private var item: NotebookCore.LibraryItem? {
        library.snapshot.items.first { $0.id == notebookID && !$0.isFolder }
    }

    var body: some View {
        List {
            if let item {
                Section {
                    Label(item.title, systemImage: item.isTextDocument ? "doc.text" : "book.closed").font(.headline)
                    if library.snapshot.isTrashed(item.id) {
                        Text("Dieses Heft liegt im Papierkorb. Zurückgeholte Stände kommen als neues Heft in die Bibliothek.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(notes, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                }
            }
            Section {
                ForEach(states) { state in row(state) }
                if !loading && states.isEmpty {
                    Text("Keine früheren Stände gefunden.").foregroundStyle(.secondary)
                }
            } header: { Text("Frühere Stände") } footer: {
                Text("„Als Kopie“ legt den Stand neben das heutige Heft („Titel (Stand …)“). „Ersetzen“ legt den heutigen Stand vorher in den Papierkorb. Automatische Backups zeigt die Liste nur, wenn dieses iPad sie geschrieben hat; jeder Stand erscheint einmal.")
            }
        }
        .navigationTitle("Frühere Stände")
        .overlay {
            if loading { ProgressView("Stände werden gesucht …") }
            else if let working { ProgressView(working).padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) }
        }
        .disabled(working != nil)
        .task { await load() }
        .refreshable { await load() }
        .confirmationDialog("Heutigen Stand ersetzen?", isPresented: Binding(get: { replacing != nil }, set: { if !$0 { replacing = nil } }),
                            titleVisibility: .visible, presenting: replacing) { state in
            Button("Ersetzen", role: .destructive) { Task { await restore(state, replace: true) } }
        } message: { state in
            Text("Der heutige Stand kommt in den Papierkorb, der Stand vom \(NotyText.listDate(state.date)) nimmt seinen Platz ein.")
        }
        .alert(item: $report) { report in
            if let id = report.open, let onOpen, library.snapshot.activeNotebook(id) != nil {
                return Alert(title: Text(report.title), message: Text(report.message),
                             primaryButton: .default(Text("Öffnen")) { onOpen(id) },
                             secondaryButton: .cancel(Text("OK")))
            }
            return Alert(title: Text(report.title), message: Text(report.message), dismissButton: .default(Text("OK")))
        }
    }

    private func row(_ state: TimelineState) -> some View {
        let exists = library.snapshot.activeNotebook(notebookID) != nil
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: state.symbol).foregroundStyle(.tint).frame(width: 22).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(NotyText.listDate(state.date, seconds: false))
                    Text(([state.place] + [state.pageCount.map { NotyText.count($0, "Seite", "Seiten") }, state.extra].compactMap { $0 })
                        .joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary)
                    if let current = item?.title, state.title != current {
                        Text("damals „\(state.title)“").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            HStack {
                Button(exists ? "Als Kopie zurückholen" : "Zurückholen") { Task { await restore(state, replace: false) } }
                    .buttonStyle(.borderedProminent)
                if exists {
                    Button("Ersetzen …", role: .destructive) { replacing = state }.buttonStyle(.bordered)
                }
            }
            .font(.callout).controlSize(.small)
            .disabled(library.opened != nil)
        }
        .padding(.vertical, 4)
    }

    // MARK: Loading

    private func load() async {
        loading = true; defer { loading = false }
        var found: [TimelineState] = [], notes: [String] = []
        // Local states of the (closed) package, read-only.
        if let document = await library.openDocument(notebookID) {
            if library.opened?.id == notebookID {
                notes.append("Das Heft ist gerade geöffnet; lokale Stände zeigt die Liste nach dem Schließen.")
            } else {
                let package = document.directory
                let read = Task.detached(priority: .userInitiated) { try LocalStates.history(package: package) }
                if let history = try? await read.value {
                    for revision in history.revisions where !revision.isLatest {
                        guard let date = revision.savedAt else { continue }
                        found.append(TimelineState(id: "local-\(revision.id)", source: .local(revision.id), date: date,
                                                   pageCount: revision.pageCount, title: revision.title, place: "auf diesem iPad"))
                    }
                    if history.unreadableCount > 0 { notes.append("\(NotyText.count(history.unreadableCount, "lokaler Stand ist", "lokale Stände sind")) nicht lesbar.") }
                }
            }
        }
        // Automatic backups this iPad wrote (summaries), each state once; only
        // those still at the target (listed afresh; while a backup runs, the
        // list it keeps). Unlisted: all, with a note.
        let place = externalBackup.policy.target == .webDAV ? "WebDAV-Backup" : "Backup im Ordner"
        var listed: Set<String>?
        if externalBackup.policy.target != .disabled {
            var reachable = externalBackup.busy
            if !reachable { reachable = (try? await externalBackup.reloadHistory()) != nil }
            if reachable { listed = Set(externalBackup.history) }
        }
        let held = externalBackup.summaries.states(of: notebookID)
        if listed == nil, !held.isEmpty {
            notes.append("Die automatischen Backups waren nicht erreichbar; manche Einträge gibt es dort vielleicht nicht mehr.")
        }
        for (summary, same) in held where listed?.contains(summary.file) ?? true {
            guard let entry = summary.notebook(notebookID) else { continue }
            found.append(TimelineState(id: "backup-\(summary.file)", source: .backup(summary.file), date: summary.createdAt,
                                       pageCount: nil, title: entry.title, place: place,
                                       extra: same > 1 ? "gleich in \(same) Backups" : nil))
        }
        // The iCloud-Ablage.
        if vault.enabled, let root = await vault.resolve() {
            let id = notebookID
            if let result = try? await Task.detached(priority: .userInitiated, operation: {
                try NotebookVault.heads(root: root, coordination: CoordinatedBackupFiles())
            }).value {
                for head in result.heads {
                    guard let notebook = head.notebooks.first(where: { $0.id == id }) else { continue }
                    for version in notebook.versions {
                        found.append(TimelineState(id: "vault-\(version.file)", source: .vault(version), date: version.savedAt,
                                                   pageCount: version.pageCount, title: notebook.title, place: "iCloud-Ablage",
                                                   extra: result.heads.count > 1 ? head.deviceName : nil))
                    }
                }
            }
        }
        states = found.sorted { $0.date > $1.date }
        self.notes = notes
    }

    // MARK: Restoring

    private func restore(_ state: TimelineState, replace: Bool) async {
        guard library.opened == nil else {
            report = Report(title: "Heft geöffnet", message: "Bitte zuerst das geöffnete Heft schließen. Es wurde nichts verändert.")
            return
        }
        let current = library.snapshot
        let today = current.activeNotebook(notebookID)
        let baseTitle = today?.title ?? state.title
        let title = today != nil && !replace
            ? LibraryBackupBrowser.copyTitle(baseTitle, savedAt: state.date, withTime: { if case .backup = state.source { return false }; return true }())
            : baseTitle
        working = "Stand wird geladen und geprüft …"
        defer { working = nil }
        let folder: URL
        do { folder = try BackupScratch.newFolder() }
        catch { report = Report(title: "Nicht möglich", message: "Kein Platz für die Zwischendateien. Es wurde nichts verändert."); return }
        defer { BackupScratch.removeFolder(folder) }
        let file: URL
        do {
            switch state.source {
            case .local(let revision):
                guard let document = await library.openDocument(notebookID) else { throw LibraryError.unavailable }
                let package = document.directory, target = folder.appendingPathComponent("stand.notybackup")
                try await Task.detached(priority: .userInitiated) {
                    try LocalStates.export(package: package, revision: revision, title: title, to: target)
                }.value
                file = target
            case .backup(let name):
                guard let archive = await externalBackup.retrieve(name) else {
                    throw externalBackup.error.map { RestoreFailure($0) } ?? RestoreFailure("Das Backup konnte nicht geladen werden.")
                }
                externalBackup.error = nil
                defer { BackupScratch.remove(archive.url) }
                let id = notebookID, url = archive.url
                let files = try await Task.detached(priority: .userInitiated) {
                    try LibraryBackupBrowser.extract(archive: url, titles: [id: title], into: folder)
                }.value
                guard let extracted = files[id] else { throw LibraryArchiveError.invalid }
                file = extracted
            case .vault(let version):
                guard let root = await vault.resolve() else { throw RestoreFailure(vault.statusText) }
                let id = notebookID, target = folder.appendingPathComponent("ablage.notybackup")
                try await Task.detached(priority: .userInitiated) {
                    try NotebookVault.copyVersion(root: root, notebook: id, version: version, to: target, coordination: CoordinatedBackupFiles())
                }.value
                file = target
            }
        } catch {
            report = Report(title: "Stand nicht lesbar",
                            message: ((error as? LocalizedError)?.errorDescription ?? error.localizedDescription) + " Es wurde nichts verändert.")
            return
        }
        working = "Wird in die Bibliothek übernommen …"
        let parent = today?.parentID.flatMap { id in current.items.contains { $0.id == id && $0.isFolder } && !current.isTrashed(id) ? id : nil }
        let collision: LibraryModel.ImportCollision? = today == nil ? nil : (replace ? .replace : .keepBoth)
        // Always the title chosen here: an iCloud version or a backup may carry an older one.
        if let imported = await library.importBackup(file, parent: parent, collision: collision, title: title) {
            report = Report(title: replace ? "Stand ersetzt" : "Zurückgeholt",
                            message: "„\(imported.title)“ liegt jetzt in der Bibliothek." + (imported.replaced ? " Der bisherige Stand liegt im Papierkorb." : ""),
                            open: imported.id)
            await load()
        } else {
            let reason = library.error ?? "Die Bibliothek ist gerade beschäftigt."
            library.error = nil
            report = Report(title: "Nicht zurückgeholt", message: reason + " Es wurde nichts verändert.")
        }
    }
}

struct RestoreFailure: LocalizedError {
    let text: String
    init(_ text: String) { self.text = text }
    var errorDescription: String? { text }
}

extension LibraryModel {
    /// The folder at `path` (titles from the top), created where missing;
    /// an existing active folder of the same title at that level is reused.
    /// Nil (top level) when a folder cannot be created.
    func folderPath(_ path: [String]) async -> UUID? {
        var parent: UUID?
        for title in path {
            let siblings = snapshot.items.filter { $0.isFolder && $0.parentID == parent && !snapshot.isTrashed($0.id) }
            if let existing = siblings.first(where: { $0.title == title }) { parent = existing.id; continue }
            let before = Set(snapshot.items.map(\.id))
            await createFolder(title, parent: parent)
            guard let created = snapshot.items.first(where: { $0.isFolder && !before.contains($0.id) && $0.title == title }) else { return parent }
            parent = created.id
        }
        return parent
    }
}
