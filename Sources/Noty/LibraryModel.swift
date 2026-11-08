import SwiftUI
import PDFKit
import NotebookCore

struct OpenNotebook: Identifiable {
    let id: UUID
    let directory: URL
    let title: String
    let isRestored: Bool
    var preferredPageID: UUID?
    var searchBounds: PageRect?
    /// A search hit over a page change, in flow offsets.
    var searchFlowRange: NSRange?
    /// Opened from a calendar event („Vergrößern“): the header button names
    /// the way back („Rechnungswesen · Di, 3. Nov.“) instead of the library.
    var returnTitle: String?
    /// Folder path in the library („Alle Unterlagen / Klasse 10“): tells
    /// notebooks with the same title apart in pickers and search hits.
    var path: String? = nil
}

@MainActor
final class LibraryModel: ObservableObject {
    let root: URL
    private let store: LibraryStore
    /// Long-lived so its listing cache skips unchanged restored copies on
    /// every refresh. Lists only; it never saves the main package.
    private let restoreCatalog: NotebookRepository
    @Published var snapshot = LibrarySnapshot()
    @Published var ready = false
    @Published var busy = false
    @Published var error: String?
    @Published var warning: String?
    @Published var opened: OpenNotebook?
    @Published var restoredCopies: [RestoredNotebook] = []
    @Published var backupStatus = "Noch kein Bibliotheksbackup exportiert"
    @Published private(set) var lastLibraryExport: Date?
    @Published var trashStatus: String?
    /// `busy` is held by background work (refresh after closing a notebook,
    /// automatic backup). The library stays visually unchanged meanwhile;
    /// user actions wait for it via `settle()` instead of being dropped.
    @Published private(set) var backgroundBusy = false
    /// Bumped for a notebook after its editor closed so only its preview is
    /// re-rendered in place (the old image stays until the new one is ready).
    @Published private(set) var artworkRevision: [UUID: Int] = [:]
    /// Sidebar folders the user expanded; persisted per area until collapsed.
    @Published var expandedFolders: Set<UUID> {
        didSet { if expandedFolders != oldValue { UserDefaults.standard.set(expandedFolders.map(\.uuidString).sorted(), forKey: expandedKey) } }
    }
    private let expandedKey: String
    /// Display order of pinned entries (stable IDs), per area. The pin itself
    /// is the index's `favorite` flag; pins missing here follow in index order.
    @Published var pinOrder: [UUID] {
        didSet { if pinOrder != oldValue { UserDefaults.standard.set(pinOrder.map(\.uuidString), forKey: pinOrderKey) } }
    }
    private let pinOrderKey: String
    private var lastEditedID: UUID?

    private let libraryBackupKey: String
    /// Last notebook open in this area; kept when the app is backgrounded/killed,
    /// cleared when the user closes the notebook.
    private let lastOpenedKey: String
    /// Only the first library loaded in this process (always the main library
    /// at launch) may reopen a notebook; switching areas later never does.
    private static var launchReopenPending = true

    init(root: URL = URL.documentsDirectory.appendingPathComponent("Noty", isDirectory: true)) {
        self.root = root
        store = LibraryStore(root: root)
        restoreCatalog = NotebookRepository(directory: root)
        // Container-independent keys; the former absolute-path key is migrated once.
        libraryBackupKey = StableDefaults.key("libraryBackup", root: root, legacyPrefix: "noty.libraryBackup.", pick: StableDefaults.newestDate)
        lastOpenedKey = StableSettingsKey.key("lastOpened", scope: StableDefaults.scope(root))
        expandedKey = StableSettingsKey.key("libraryExpanded", scope: StableDefaults.scope(root))
        expandedFolders = Set((UserDefaults.standard.stringArray(forKey: expandedKey) ?? []).compactMap(UUID.init(uuidString:)))
        pinOrderKey = StableSettingsKey.key("libraryPinOrder", scope: StableDefaults.scope(root))
        pinOrder = (UserDefaults.standard.stringArray(forKey: pinOrderKey) ?? []).compactMap(UUID.init(uuidString:))
        if let date = UserDefaults.standard.object(forKey: libraryBackupKey) as? Date {
            lastLibraryExport = date
            backupStatus = "Letztes Bibliotheksbackup: \(NotyText.statusDate(date))"
        }
        let reopen = Self.launchReopenPending
        Self.launchReopenPending = false
        Task {
            await refresh()
            if reopen { await reopenLastNotebook() }
        }
        // Failed `.noty` imports keep their stage for a day (BACKUPS.md).
        Task { [restoreCatalog] in await restoreCatalog.removeStaleStages() }
    }

    /// Set by the open editor workspace: commits every pane (editors pause only
    /// for this flush) so a following archive contains all acknowledged input.
    var editorCommit: (() async -> BackupCommit)?
    /// An archive is being written from committed packages; the library stays
    /// usable, only permanent deletion waits for it.
    private(set) var archiveRunning = false
    private var preparedExport: URL?
    private var preparedExportWarning: String?

    /// Why an automatic backup should wait a moment instead of starting now.
    var backupBlocker: String? {
        if !ready { return "Bibliothek wird geladen" }
        if busy && !backgroundBusy { return "Bibliotheksvorgang läuft" }
        if archiveRunning { return "Ein Backup läuft bereits" }
        return nil
    }

    /// Streams the committed library into a new verified temporary archive, one
    /// notebook at a time and off the UI actor, including the Apple-framework
    /// checks. With an open editor the caller committed it first (`editorCommit`);
    /// editing continues meanwhile, later commits are simply not included.
    /// A notebook with a damaged newest revision goes in with the state its
    /// editor would open (`olderStates`), so it never blocks the whole backup.
    func buildArchive(editorsCommitted: Bool = false) async throws -> PreparedLibraryArchive {
        guard ready, opened == nil || editorsCommitted, !archiveRunning else {
            throw BackupPostponed(reason: backupBlocker ?? "Heft geöffnet")
        }
        archiveRunning = true; defer { archiveRunning = false }
        // Process-wide: closing or opening editors skip their asset GC meanwhile.
        let activity = BackupActivity.shared.begin(); defer { activity.end() }
        let plan = try await store.backupPlan()
        let url = try BackupScratch.newFile()
        let task = Task.detached(priority: .utility) { () throws -> PreparedLibraryArchive in
            var olderStates: [String] = []
            let summary = try LibraryArchive.write(plan, to: url, validate: BackupValidation.validate,
                                                   olderState: { olderStates.append($0.title) })
            var archive = PreparedLibraryArchive(url: url, summary: summary, olderStates: olderStates)
            archive.calendarWarning = Self.calendarWarning(plan.calendar)
            return archive
        }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    /// What the calendar part of a backup could not carry as it is (never silent).
    nonisolated static func calendarWarning(_ capture: CalendarBackupCapture?) -> String? {
        guard let capture else { return nil }
        var parts: [String] = []
        if capture.olderState { parts.append("Kalender: älterer lesbarer Stand gesichert, neuere Revision beschädigt") }
        if capture.droppedLinks > 0 {
            parts.append("Kalender: \(NotyText.count(capture.droppedLinks, "Verknüpfung", "Verknüpfungen")) zu endgültig gelöschten Heften nicht gesichert")
        }
        if capture.sourceMissing { parts.append("Kalender: Offline-Stundenplan nicht lesbar, nicht gesichert") }
        return parts.isEmpty ? nil : parts.joined(separator: "; ")
    }

    /// Manual export from Settings: closed editors, visible progress, alert on error.
    func libraryBackup() async -> PreparedLibraryArchive? {
        guard ready, !busy, opened == nil else { return nil }
        busy = true; defer { busy = false }
        discardPreparedExport()
        backupStatus = "Bibliotheksbackup wird vorbereitet …"
        do {
            let archive = try await buildArchive()
            preparedExport = archive.url; preparedExportWarning = archive.warning
            backupStatus = archive.warning.map { "Bibliotheksbackup vorbereitet; \($0)" } ?? "Bibliotheksbackup vollständig vorbereitet"
            return archive
        } catch {
            backupStatus = "Bibliotheksbackup fehlgeschlagen"
            self.error = error.localizedDescription
            return nil
        }
    }

    func libraryBackupExported() {
        let date = Date()
        UserDefaults.standard.set(date, forKey: libraryBackupKey)
        lastLibraryExport = date
        backupStatus = "Bibliotheksbackup exportiert: \(NotyText.statusDate(date))"
        // Success with warning: shown in the library banner, not as an error.
        if let preparedExportWarning { warning = "Bibliotheksbackup exportiert; \(preparedExportWarning). Heft öffnen und prüfen." }
        discardPreparedExport()
    }

    private func discardPreparedExport() {
        if let preparedExport { BackupScratch.remove(preparedExport) }
        preparedExport = nil; preparedExportWarning = nil
    }

    func editorChoices() async -> [OpenNotebook] {
        // One snapshot and one folder map for the whole list: paths are looked
        // up in O(depth) and shared per folder, not searched per notebook.
        let value = snapshot
        var paths = FolderPaths(value)
        var choices: [OpenNotebook] = []
        for item in value.items where !item.isFolder && !value.isTrashed(item.id) {
            if let directory = try? await store.documentURL(id: item.id) {
                choices.append(OpenNotebook(id: item.id, directory: directory, title: item.title,
                    isRestored: item.source == .restored, path: paths.path(of: item)))
            }
        }
        return choices.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    /// `quiet`: background reload (e.g. after closing a notebook) that keeps
    /// the library visually unchanged; only real differences are published.
    func refresh(quiet: Bool = false) async {
        guard !busy else { return }
        busy = true; backgroundBusy = quiet
        defer { busy = false; backgroundBusy = false }
        do {
            let result = try await store.load()
            if snapshot != result.snapshot { snapshot = result.snapshot }
            if !ready { ready = true }
            // Forget expansion only for entries that no longer exist at all
            // (trashed folders may come back and keep their state).
            let known = Set(snapshot.items.map(\.id))
            if !expandedFolders.isSubset(of: known) { expandedFolders.formIntersection(known) }
            let pins = pinOrder.filter(known.contains)
            if pins != pinOrder { pinOrder = pins }
            var notices: [String] = []
            if result.recovered { notices.append("Bibliotheksindex aus vorherigem Stand geladen. Zuordnungen bitte prüfen.") }
            if result.unreadableDocuments > 0 {
                notices.append("\(result.unreadableDocuments) Heftverzeichnis(se) konnten nicht gelesen werden. Dateien bleiben erhalten.")
            }
            let notice = notices.isEmpty ? nil : notices.joined(separator: " ")
            if warning != notice { warning = notice }
            let catalog = try await restoreCatalog.restoredCopies()
            restoredCopies = catalog.notebooks.compactMap { copy -> RestoredNotebook? in
                guard let item = snapshot.items.first(where: { $0.id == copy.id }), !snapshot.isTrashed(copy.id) else { return nil }
                var result = copy; result.title = item.title; return result
            }
        } catch { self.error = error.localizedDescription }
    }

    /// Waits (bounded) for background work so a tap is not silently dropped.
    func settle() async {
        var waited = 0
        while busy && backgroundBusy && waited < 600 {
            try? await Task.sleep(for: .milliseconds(50)); waited += 1
        }
    }

    /// After the editor was closed: refresh in place without visible reload.
    func editorClosed() {
        if let id = lastEditedID { artworkRevision[id, default: 0] += 1 }
        lastEditedID = nil
        Task { await refresh(quiet: true) }
    }

    /// Foreground work blocks a second action; a tap is refused with a word
    /// instead of being dropped without a trace.
    private var accepting: Bool {
        guard ready, opened == nil else { return false }
        guard busy else { return true }
        error = "Bitte warten, bis der laufende Vorgang abgeschlossen ist."
        return false
    }

    /// Before a new store takes over this root (area switch): nothing of this
    /// store may still be writing, there is only ever one writer per root.
    func waitUntilIdle() async {
        while busy { try? await Task.sleep(for: .milliseconds(100)) }
    }

    /// `quiet`: no progress and no disabled library for a change without wait.
    private func change(quiet: Bool = false, _ action: () async throws -> LibrarySnapshot) async {
        await settle()
        guard accepting else { return }
        busy = true; backgroundBusy = quiet
        defer { busy = false; backgroundBusy = false }
        do { snapshot = try await action() }
        catch { self.error = error.localizedDescription }
    }

    /// Read-only snapshot of the last committed revision with its image
    /// originals (PDF export from the library).
    func committedNotebook(_ id: UUID) async throws -> (Notebook, NotebookAssets) {
        let package = try await store.previewPackage(id: id)
        return (package.document, package.assets)
    }

    private final class Tile {
        let stamp: String, appearance: NotebookAppearance?, image: UIImage?
        init(stamp: String, appearance: NotebookAppearance?, image: UIImage?) { self.stamp = stamp; self.appearance = appearance; self.image = image }
    }
    /// Tile previews per committed revision: an unchanged notebook is not decoded again.
    private let tiles: NSCache<NSUUID, Tile> = {
        let cache = NSCache<NSUUID, Tile>(); cache.totalCostLimit = 24 * 1024 * 1024; return cache
    }()

    /// At most two packages in memory at a time.
    private let previewGate = PreviewGate()

    func artwork(for id: UUID) async throws -> (NotebookAppearance?, UIImage?) {
        let url = try await store.documentURL(id: id)
        // Read before the document: a newer commit in between only re-renders later.
        let stamp = await Task.detached(priority: .utility) { NotebookRevisionStamp.read(directory: url) }.value
        if let stamp, let tile = tiles.object(forKey: id as NSUUID), tile.stamp == stamp { return (tile.appearance, tile.image) }
        // Whole packages are decoded outside the store actor: otherwise a
        // scrolled grid queues „Öffnen“ or „Umbenennen“ behind every preview.
        await previewGate.enter()
        let package: (document: Notebook, assets: NotebookAssets)
        do {
            try Task.checkCancellation()
            package = try await Task.detached(priority: .utility) { try LibraryStore.previewPackage(directory: url) }.value
            await previewGate.leave()
        } catch { await previewGate.leave(); throw error }
        let (document, assets) = package
        try Task.checkCancellation()
        // The document's own kind decides; an index rewritten by an older build lost the hint.
        if let item = snapshot.items.first(where: { $0.id == id }), item.isTextDocument != document.isTextDocument,
           let repaired = try? await store.setKind(id, kind: document.documentKind) {
            snapshot = repaired
        }
        let result: (NotebookAppearance?, UIImage?)
        if document.appearance?.coverEnabled == true { result = (document.appearance, nil) }
        else {
            guard let page = document.pages.first else { throw StorageError.invalidDocument }
            // The source PDF is parsed off the main actor (CGPDF), never with PDFKit here.
            let source: PageThumbnailCache.Source
            if let reference = page.pdfReference {
                source = document.pdfSources?.first(where: { $0.id == reference.sourceID }).map { .data($0.data, reference.pageIndex) } ?? .none
            } else { source = document.pdf.map { .data($0, 0) } ?? .none }
            result = (nil, try await PageThumbnailCache.render(page, source: source, assets: assets))
        }
        if let stamp {
            let pixels = result.1.map { Int($0.size.width * $0.size.height * $0.scale * $0.scale * 4) } ?? 1
            tiles.setObject(Tile(stamp: stamp, appearance: result.0, image: result.1), forKey: id as NSUUID, cost: pixels)
        }
        return result
    }
    func createFolder(_ title: String, parent: UUID?) async {
        await change { try await store.createFolder(title: title, parentID: parent) }
    }
    func createNotebook(_ title: String, appearance: NotebookAppearance = NotebookAppearance(), parent: UUID?) async -> Bool {
        await settle()
        guard accepting else { return false }
        busy = true; defer { busy = false }
        do {
            let notebook = try Notebook.blank(title: try LibraryStore.validTitle(title), appearance: appearance)
            snapshot = try await store.createDocument(notebook, parentID: parent)
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
    func createTextDocument(_ title: String, landscape: Bool, paper: PaperStyle, color: PaperColor = .white, parent: UUID?) async -> Bool {
        await settle()
        guard accepting else { return false }
        busy = true; defer { busy = false }
        do {
            let document = try Notebook.textDocument(title: try LibraryStore.validTitle(title), landscape: landscape, paper: paper, color: color)
            snapshot = try await store.createDocument(document, parentID: parent)
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
    func rename(_ id: UUID, title: String) async { await change { try await store.rename(id, title: title) } }
    func move(_ id: UUID, to parent: UUID?) async { await change { try await store.move(id, to: parent) } }
    /// Drag & drop: into `parent`, directly before sibling `before` (nil = at the end).
    func place(_ id: UUID, in parent: UUID?, before: UUID?) async {
        await change { try await store.place(id, in: parent, before: before) }
    }
    func trash(_ id: UUID) async { await change { try await store.trash(id) } }
    func restore(_ id: UUID) async {
        let item = snapshot.items.first(where: { $0.id == id })
        let folderTrashed = item?.parentID.map(snapshot.isTrashed) ?? false
        await change { try await store.restore(id) }
        // The store puts it at the top level, where it would not be looked for.
        if folderTrashed, let item, snapshot.items.contains(where: { $0.id == id && $0.deletedAt == nil }) {
            TopAlert.show("Wiederhergestellt", "„\(item.title)“ liegt jetzt in „Alle Unterlagen“, weil sein Ordner noch im Papierkorb liegt.")
        }
    }
    /// Independent copy of a notebook (new document identity) behind the original.
    func duplicate(_ item: NotebookCore.LibraryItem) async {
        guard !item.isFolder else { return }
        let suffix = " Kopie"
        let title = String(item.title.prefix(120 - suffix.count)) + suffix
        await change { try await store.duplicateDocument(item.id, title: title).snapshot }
    }
    /// Items placed in the trash themselves (descendants of a trashed folder are
    /// listed through their folder), newest first.
    var trashedItems: [NotebookCore.LibraryItem] {
        snapshot.items.filter { $0.deletedAt != nil }.sorted { ($0.deletedAt ?? .distantPast) > ($1.deletedAt ?? .distantPast) }
    }
    /// Number of index entries (including folder contents) that a purge of `item` would remove.
    func purgeCount(_ item: NotebookCore.LibraryItem) -> Int {
        snapshot.items.filter { candidate in
            var current: NotebookCore.LibraryItem? = candidate
            var visited = Set<UUID>()
            while let value = current, visited.insert(value.id).inserted {
                if value.id == item.id { return true }
                current = value.parentID.flatMap { parent in snapshot.items.first { $0.id == parent } }
            }
            return false
        }.count
    }
    /// Permanent deletion is only offered with all editors closed; the store
    /// refuses anything that is not already in the trash.
    func purge(_ ids: [UUID]) async { await purging { try await store.purge(ids: ids) } }
    func emptyTrash() async { await purging { try await store.emptyTrash() } }
    private func purging(_ action: () async throws -> LibraryPurgeResult) async {
        await settle()
        guard ready, !busy, opened == nil else { return }
        // A running backup reads these packages; deleting them would abort it.
        guard !archiveRunning else { error = "Bitte warten, bis das laufende Backup abgeschlossen ist."; return }
        busy = true
        defer { busy = false }
        do {
            let result = try await action()
            snapshot = result.snapshot
            restoredCopies.removeAll { result.purgedIDs.contains($0.id) }
            var parts = [result.purgedIDs.count == 1 ? "1 Eintrag endgültig gelöscht." : "\(result.purgedIDs.count) Einträge endgültig gelöscht."]
            if !result.retainedIDs.isEmpty {
                parts.append("Das ursprüngliche Heft liegt direkt im App-Ordner und bleibt im Papierkorb.")
            }
            if result.leftoverDirectories > 0 {
                parts.append("\(result.leftoverDirectories) Ordner konnten nicht vom Speicher entfernt werden; ihre Dateien bleiben erhalten und erscheinen nach dem Neuladen eventuell wieder in der Bibliothek.")
            }
            trashStatus = parts.joined(separator: " ")
        } catch { self.error = "Endgültiges Löschen fehlgeschlagen: \(error.localizedDescription)" }
    }
    // Quiet: a foreground change disables every entry for a moment, which made the library flash.
    func favorite(_ item: NotebookCore.LibraryItem) async { await change(quiet: true) { try await store.setFavorite(item.id, value: !item.favorite) } }
    /// Pinned entries (active only) in their display order.
    var pinnedItems: [NotebookCore.LibraryItem] {
        LibraryPinOrder.arrange(snapshot.items.filter { $0.favorite && !snapshot.isTrashed($0.id) }, order: pinOrder)
    }
    /// Drag & drop between pinned tiles: reorders pins, or pins an entry
    /// dragged in from elsewhere directly at that position.
    func placePin(_ id: UUID, at target: LibraryDropTarget) async {
        let current = pinnedItems.map(\.id)
        guard let order = LibraryPinOrder.placing(id, at: target, in: current) else { return }
        if !current.contains(id) {
            guard snapshot.items.contains(where: { $0.id == id }), !snapshot.isTrashed(id) else { return }
            await change { try await store.setFavorite(id, value: true) }
            guard snapshot.items.first(where: { $0.id == id })?.favorite == true else { return }
        }
        pinOrder = order
    }
    func reorder(_ ids: [UUID], parent: UUID?) async { await change { try await store.reorder(ids, parentID: parent) } }

    func open(_ item: NotebookCore.LibraryItem, pageID: UUID? = nil, searchBounds: PageRect? = nil, flowRange: NSRange? = nil,
              returnTitle: String? = nil) async {
        // A second tap on the notebook being opened is no second request.
        guard opening != item.id else { return }
        await settle()
        guard accepting, !item.isFolder else { return }
        opening = item.id
        // The calendar's note beside an event commits and lets go of its
        // notebook first (it may still file a new note, which needs the
        // library): one writer per package, and none behind the editor.
        if let releaseCalendarNote { await releaseCalendarNote() }
        guard accepting else { opening = nil; return }
        busy = true
        defer { busy = false; opening = nil }
        do {
            let url = try await store.documentURL(id: item.id)
            // Another writer (an append of a shared file) holds the package.
            guard !PackageWriteLock.shared.isHeld(url) else { error = "Dieses Heft wird gerade ergänzt. Bitte gleich noch einmal öffnen."; return }
            snapshot = try await store.markOpened(item.id)
            opened = OpenNotebook(id: item.id, directory: url, title: item.title,
                                  isRestored: item.source == .restored, preferredPageID: pageID, searchBounds: searchBounds, searchFlowRange: flowRange,
                                  returnTitle: returnTitle)
            lastEditedID = item.id
            UserDefaults.standard.set(item.id.uuidString, forKey: lastOpenedKey)
        } catch { self.error = error.localizedDescription }
    }

    private var opening: UUID?

    /// Called after the user closed the notebook normally (not on backgrounding).
    func notebookClosedByUser() { UserDefaults.standard.removeObject(forKey: lastOpenedKey) }

    /// Launch only: reopen the notebook that was open when the app was last used.
    /// Missing, trashed or unreadable documents are skipped silently and forgotten;
    /// the editor then restores its remembered page itself.
    private func reopenLastNotebook() async {
        guard let raw = UserDefaults.standard.string(forKey: lastOpenedKey) else { return }
        // Settings › Allgemein › „Zuletzt geöffnetes Heft wieder öffnen“ (default on).
        guard UserDefaults.standard.object(forKey: AppSettingsKey.reopenLastNotebook) as? Bool ?? true else { return }
        guard ready, opened == nil, !busy else { return }
        guard let id = UUID(uuidString: raw), let item = snapshot.items.first(where: { $0.id == id }),
              !item.isFolder, !snapshot.isTrashed(id) else { notebookClosedByUser(); return }
        busy = true
        defer { busy = false }
        do {
            let url = try await store.documentURL(id: id)
            snapshot = try await store.markOpened(id)
            guard opened == nil else { return }
            opened = OpenNotebook(id: id, directory: url, title: item.title, isRestored: item.source == .restored)
            lastEditedID = id
        } catch { notebookClosedByUser() }
    }

    func importPDF(_ url: URL, parent: UUID?, writingArea: PageMargins? = nil) async {
        await settle()
        guard accepting else { return }
        busy = true
        let access = url.startAccessingSecurityScopedResource()
        defer {
            if access { url.stopAccessingSecurityScopedResource() }
            busy = false
        }
        do {
            // Reading and parsing up to 500 pages stays off the UI actor.
            let document = try await withImportTimeLimit {
                try await Task.detached(priority: .userInitiated) {
                    try Self.importedNotebook(url, writingArea: writingArea)
                }.value
            }
            snapshot = try await store.createDocument(document, parentID: parent)
        } catch { self.error = "PDF-Import fehlgeschlagen: \(error.localizedDescription)" }
    }

    enum ImportCollision: Sendable { case replace, keepBoth }
    struct ImportedNotebook { let id: UUID; let title: String; let replaced: Bool }
    /// The last import ended because the user cancelled the collision question.
    private(set) var importDeclined = false

    /// Imports a `.noty`/`.notybackup` file as a normal notebook (exact title
    /// or „Titel (n)“, new identity, not a restored copy) through the staged,
    /// independently validated restore path. If the file's notebook already
    /// exists in this area: `collision` decides, nil asks („Vorhandenes
    /// ersetzen“ moves its current state to the trash; „Beide behalten“).
    /// nil on failure (`error` set) or when declined (`importDeclined`).
    @discardableResult
    func importBackup(_ url: URL, parent: UUID?, collision: ImportCollision? = nil, title: String? = nil) async -> ImportedNotebook? {
        importDeclined = false
        await settle()
        guard accepting else { return nil }
        busy = true
        let access = url.startAccessingSecurityScopedResource()
        defer {
            if access { url.stopAccessingSecurityScopedResource() }
            busy = false
        }
        let repository = NotebookRepository(directory: root)
        do {
            let prepared = try await repository.prepareRestore(from: url)
            try EditorModelValidation.validate(prepared.document, assets: prepared.assets)
            snapshot = try await store.load().snapshot
            var replacing: UUID?
            if let existing = snapshot.activeNotebook(prepared.sourceDocumentID) {
                var choice = collision
                if choice == nil {
                    choice = await TopAlert.choose("Heft schon vorhanden",
                        "„\(prepared.document.title)“ liegt bereits als „\(existing.title)“ in der Bibliothek. „Vorhandenes ersetzen“ legt dessen aktuellen Stand vorher in den Papierkorb.",
                        actions: [("Vorhandenes ersetzen", .destructive, ImportCollision.replace), ("Beide behalten", .default, .keepBoth)])
                }
                guard let choice else {
                    await repository.discardRestore(prepared)
                    importDeclined = true
                    return nil
                }
                if choice == .replace {
                    // One writer per package: the calendar's note beside an event lets
                    // go of it first (outside `busy`: it may still file a note). Anything
                    // else still writing it refuses the replacement, so its newest state
                    // never lands in the trash unseen.
                    busy = false
                    if let releaseCalendarNote { await releaseCalendarNote() }
                    busy = true
                    let package = try await store.documentURL(id: existing.id)
                    guard opened?.id != existing.id, let claim = await PackageWriteLock.shared.claim(package, waitingUpTo: 3) else {
                        await repository.discardRestore(prepared)
                        throw ReplaceBusy()
                    }
                    claim.release()
                    replacing = existing.id
                }
            }
            let result = try await NotebookImport.commit(prepared, repository: repository, library: store,
                                                         parentID: parent, replacing: replacing, title: title)
            snapshot = result.snapshot
            if let replacing, let pin = pinOrder.firstIndex(of: replacing) { pinOrder[pin] = result.id }
            // Event notes and the Lernfeld follow the restored state (same pages, new identity).
            if let replacing, let calendarNotebookReplaced { await calendarNotebookReplaced(replacing, result.id) }
            return ImportedNotebook(id: result.id, title: result.title, replaced: replacing != nil)
        } catch {
            // A failed validation or commit keeps its stage for analysis for a
            // day (BACKUPS.md); `removeStaleStages` at launch clears it.
            self.error = "Import fehlgeschlagen: \(error.localizedDescription)"
            return nil
        }
    }

    /// Index and package locations for the iCloud-Ablage (`NotebookVault.run`),
    /// captured on the library actor; the notebooks are read later, read-only.
    /// Without the calendar: the Ablage holds notebooks only, and an unreadable
    /// or newer calendar package must not stop it.
    func vaultPlan() async throws -> LibraryBackupPlan { try await store.backupPlan(includeCalendar: false) }

    /// Today's index and the canonical size/CRC of every active notebook's
    /// committed state, read off the UI actor exactly as a backup would archive
    /// it; compared with a backup's contents (BACKUP-RESTORE-PLAN Phase 1).
    /// Throws when a notebook of today's library is not readable.
    func backupComparison() async throws -> (snapshot: LibrarySnapshot, fingerprints: [UUID: LibraryArchiveFileInfo]) {
        // Notebooks only: the calendar is not compared and must not block „Hefte zurückholen“.
        let plan = try await store.backupPlan(includeCalendar: false)
        let fingerprints = await Task.detached(priority: .userInitiated) { plan.currentFingerprints() }.value
        return (plan.snapshot, fingerprints)
    }

    /// `<Titel>.noty` of the last committed revision for the share sheet,
    /// written and re-read off the UI actor (same archive as the editor's
    /// backup; the library title is the file's title). A notebook whose newest
    /// revision is unreadable is refused instead of sharing an older state.
    func shareFile(for item: NotebookCore.LibraryItem) async -> URL? {
        guard !item.isFolder else { return nil }
        do {
            let package = try await store.sharePackage(id: item.id), assets = package.assets
            var document = package.document
            document.title = item.title
            let url = try BackupScratch.newShareFile(title: item.title)
            let snapshot = document
            do {
                try await Task.detached(priority: .userInitiated) {
                    // Reads the package's originals: no asset GC meanwhile.
                    let activity = BackupActivity.shared.begin(); defer { activity.end() }
                    _ = try BackupArchive.write(snapshot, assets: assets, to: url)
                }.value
            } catch { BackupScratch.removeShare(url); throw error }
            return url
        } catch {
            self.error = "Teilen nicht möglich: \(error.localizedDescription)"
            return nil
        }
    }

    private nonisolated static func importedNotebook(_ url: URL, writingArea: PageMargins?) throws -> Notebook {
        let data = try readPDF(url)
        let (_, geometries) = try PDFImportCheck.pages(of: data)
        return try importedNotebook(data: data, geometries: geometries,
                                    title: NotebookTitles.sanitized(url.deletingPathExtension().lastPathComponent), writingArea: writingArea)
    }

    /// A new notebook of a checked PDF (`PDFImportCheck`); also the shared-file path.
    nonisolated static func importedNotebook(data: Data, geometries: [PDFPageGeometry], title: String,
                                             writingArea: PageMargins?) throws -> Notebook {
        var document = Notebook()
        document.title = title
        document.pdf = data
        document.pages = geometries.map { geometry in var page = Page(); page.geometry = geometry; return page }
        if let writingArea, !document.pages.isEmpty {
            var assignments: [UUID: PageMargins] = [:]
            for page in document.pages {
                assignments[page.id] = try writingArea.scaled(from: .init(width: 1, height: 1), to: page.geometry?.displaySize ?? .a4)
            }
            try document.setMargins(assignments)
        }
        // Originals above 20 MB get schema 10 at once, so Build 46 refuses the
        // whole notebook instead of failing later edits.
        if data.count > PDFSource.legacyMaximumBytes { document = try document.preparedForPageEditing() }
        return document
    }

    // MARK: Shared files (`IncomingFiling`)

    /// The open editor workspace (set by `EditorWorkspaceView`): an open
    /// notebook takes a shared file through its own editor model.
    weak var workspace: EditorWorkspace?

    /// Unlike the library's own actions, filing is allowed above an open
    /// notebook: it writes the index and new or closed packages only, never a
    /// package an editor holds. It waits briefly for running library work.
    private func filingAccess() async throws {
        await settle()
        var waited = 0
        while busy && waited < 100 { try? await Task.sleep(for: .milliseconds(50)); waited += 1 }
        guard ready, !busy else { throw IncomingFilingError.libraryBusy }
    }

    /// A new notebook from the shared file in `parent`; the title is made
    /// unique among the active notebooks like every import.
    /// Throws only before the commit (the index write of `createDocument`).
    func fileIncomingNotebook(_ pdf: IncomingPDF, title: String, parent: UUID?, writingArea: PageMargins?) async throws -> (item: NotebookCore.LibraryItem, pageIDs: [UUID]) {
        try await filingAccess()
        busy = true; defer { busy = false }
        if let parent { guard snapshot.items.contains(where: { $0.id == parent && $0.isFolder }), !snapshot.isTrashed(parent) else { throw LibraryError.unavailable } }
        let name = NotebookTitles.unique(try LibraryStore.validTitle(title), taken: snapshot.activeNotebookTitles())
        let document = try await Task.detached(priority: .userInitiated) {
            try Self.importedNotebook(data: pdf.data, geometries: pdf.geometries, title: name, writingArea: writingArea)
        }.value
        snapshot = try await store.createDocument(document, parentID: parent)
        let item = snapshot.items.first(where: { $0.id == document.id })
            ?? NotebookCore.LibraryItem(id: document.id, title: name, parentID: parent, source: .library)
        return (item, document.pages.map(\.id))
    }

    /// Appends the shared file to a notebook no view has open, through the
    /// library actor (one complete new revision, `LibraryStore.appendIncomingPDF`).
    /// The package's write claim (`PackageWriteLock`) is taken there, so any
    /// editor holding it (also a restored copy opened full screen, which is
    /// neither `opened` nor in the workspace) refuses the append, and an
    /// editor opened meanwhile waits for it. Throws only when nothing was
    /// committed; `verified == false` means committed but not confirmed.
    func appendIncoming(_ pdf: IncomingPDF, to id: UUID, writingArea: PageMargins?) async throws -> IncomingAppendResult {
        guard opened?.id != id, workspace?.holds(id) != true else { throw IncomingFilingError.editorBusy }
        try await filingAccess()
        guard opened?.id != id, workspace?.holds(id) != true else { throw IncomingFilingError.editorBusy }
        busy = true
        defer { busy = false }
        let result = try await store.appendIncomingPDF(to: id, data: pdf.data, geometries: pdf.geometries,
                                                       placement: .end, writingArea: writingArea)
        artworkRevision[id, default: 0] += 1
        return result
    }

    func createIncomingFolder(_ title: String, parent: UUID?) async throws -> UUID {
        try await filingAccess()
        busy = true; defer { busy = false }
        snapshot = try await store.createFolder(title: title, parentID: parent)
        guard let folder = snapshot.items.last, folder.isFolder else { throw LibraryError.unavailable }
        return folder.id
    }

    // MARK: Calendar notes (Kalender B2, docs/CALENDAR-PLAN.md §4)

    /// Set by the calendar of this area: commits and closes its note editor
    /// beside an event before the library opens any notebook.
    var releaseCalendarNote: (() async -> Void)?
    /// Set by the calendar of this area: a notebook it refers to was replaced
    /// by an earlier state (old identity, new identity).
    var calendarNotebookReplaced: ((UUID, UUID) async -> Void)?

    /// „Ersetzen“ while the notebook is still being written.
    struct ReplaceBusy: LocalizedError {
        var errorDescription: String? {
            "Dieses Heft wird gerade noch gespeichert oder ist geöffnet (zum Beispiel als Kalendernotiz). Bitte gleich noch einmal versuchen."
        }
    }

    /// Package of a new library notebook that is not in the index yet.
    func newDocumentDirectory(_ id: UUID) -> URL {
        root.appendingPathComponent("Library/Documents/\(id.uuidString)", isDirectory: true)
    }

    /// Rule 8, second step: the completely committed package of a new event
    /// note joins the library in the folder „Kalendernotizen“. The folder is
    /// found by its stored identity only; a missing or trashed one is created
    /// anew (never a same-named folder of the user). Returns the folder used.
    /// Allowed above an open notebook like filing; touches only the index.
    func adoptCalendarNote(_ id: UUID, title: String, folder: UUID?) async throws -> UUID {
        try await filingAccess()
        busy = true; defer { busy = false }
        var parent = CalendarNotesFolder.usable(folder, in: snapshot)
        if parent == nil {
            snapshot = try await store.createFolder(title: CalendarNotesFolder.title, parentID: nil)
            guard let created = snapshot.items.last, created.isFolder, created.title == CalendarNotesFolder.title else { throw LibraryError.unavailable }
            parent = created.id
        }
        // An earlier attempt already filed it (or a library load found the package).
        if let existing = snapshot.items.first(where: { $0.id == id }), existing.parentID == parent, !snapshot.isTrashed(id) { return parent! }
        let name = NotebookTitles.unique(title, taken: snapshot.activeNotebookTitles(excluding: id))
        snapshot = try await store.adoptImported(id, title: name, parentID: parent, replacing: nil)
        return parent!
    }

    /// Lernfelder (docs/LERNFELDER.md): a new Lernfeld notebook joins the
    /// library at the top level (the user may move it; it is found by
    /// identity). Like `adoptCalendarNote`, allowed above an open notebook.
    func adoptStudyNotebook(_ id: UUID, title: String) async throws {
        try await filingAccess()
        busy = true; defer { busy = false }
        if snapshot.items.contains(where: { $0.id == id }), !snapshot.isTrashed(id) { return }
        let name = NotebookTitles.unique(title, taken: snapshot.activeNotebookTitles(excluding: id))
        snapshot = try await store.adoptImported(id, title: name, parentID: nil, replacing: nil)
    }

    /// Active notebooks of the notes folder (for linking one again).
    func calendarNotebooks(in folder: UUID?) -> [NotebookCore.LibraryItem] {
        guard let folder = CalendarNotesFolder.usable(folder, in: snapshot) else { return [] }
        return snapshot.children(of: folder).filter { !$0.isFolder }
    }

    /// The editor's description of a library notebook (second view, „Öffnen“).
    func openDocument(_ id: UUID) async -> OpenNotebook? {
        guard let item = snapshot.items.first(where: { $0.id == id }), !item.isFolder,
              let url = try? await store.documentURL(id: id) else { return nil }
        return OpenNotebook(id: id, directory: url, title: item.title, isRestored: item.source == .restored)
    }

    /// The PDF behind `url`; a picture becomes one (`ImagePagePDF`).
    nonisolated static func readPDF(_ url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var data = Data()
        while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
            guard data.count + chunk.count <= PDFSource.maximumBytes else {
                throw NSError(domain: "noty", code: 1, userInfo: [NSLocalizedDescriptionKey: "PDFs und Bilder dürfen hier höchstens 100 MB groß sein."])
            }
            data.append(chunk)
        }
        guard !ImagePagePDF.isPDF(data), ImageFileFormat.detect(data) != nil else { return data }
        return try ImagePagePDF.pdf(from: data)
    }
}

struct LibraryNotebookView: View {
    @StateObject private var workspace: EditorWorkspace
    @ObservedObject var library: LibraryModel
    init(document: OpenNotebook, root: URL, library: LibraryModel) {
        self.library = library
        _workspace = StateObject(wrappedValue: EditorWorkspace(document: document, root: root))
    }
    var body: some View { EditorWorkspaceView(workspace: workspace, library: library) }
}

/// Limits how many notebook packages are decoded for previews at once.
private actor PreviewGate {
    private var running = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []
    func enter() async {
        if running < 2 { running += 1; return }
        await withCheckedContinuation { waiting.append($0) }
    }
    func leave() {
        if waiting.isEmpty { running -= 1 } else { waiting.removeFirst().resume() }
    }
}

/// „Alle Unterlagen / Klasse 10 / Mathe“ for many items of one snapshot:
/// folders indexed once by ID, each folder's path built once.
struct FolderPaths {
    private let folders: [UUID: NotebookCore.LibraryItem]
    private var cache: [UUID: String] = [:]

    init(_ snapshot: LibrarySnapshot) {
        folders = Dictionary(snapshot.items.filter(\.isFolder).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// The folders above `item`.
    mutating func path(of item: NotebookCore.LibraryItem) -> String {
        guard let parent = item.parentID else { return Self.root }
        return path(ofFolder: parent, visiting: [])
    }

    private mutating func path(ofFolder id: UUID, visiting: Set<UUID>) -> String {
        if let known = cache[id] { return known }
        guard let folder = folders[id], !visiting.contains(id) else { return Self.root }
        let above = folder.parentID.map { path(ofFolder: $0, visiting: visiting.union([id])) } ?? Self.root
        let result = above + " / " + folder.title
        cache[id] = result
        return result
    }

    private static let root = "Alle Unterlagen"
}
