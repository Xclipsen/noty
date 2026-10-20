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
            backupStatus = "Letzter Bibliotheksexport: \(date.formatted(date: .abbreviated, time: .shortened))"
        }
        let reopen = Self.launchReopenPending
        Self.launchReopenPending = false
        Task {
            await refresh()
            if reopen { await reopenLastNotebook() }
        }
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
            throw BackupPostponed(reason: backupBlocker ?? "Notizbuch geöffnet")
        }
        archiveRunning = true; defer { archiveRunning = false }
        let plan = try await store.backupPlan()
        let url = try BackupScratch.newFile()
        let task = Task.detached(priority: .utility) { () throws -> PreparedLibraryArchive in
            var olderStates: [String] = []
            let summary = try LibraryArchive.write(plan, to: url, validate: BackupValidation.validate,
                                                   olderState: { olderStates.append($0.title) })
            return PreparedLibraryArchive(url: url, summary: summary, olderStates: olderStates)
        }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
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
        backupStatus = "Bibliotheksdatei exportiert: \(date.formatted(date: .omitted, time: .shortened))"
        // Success with warning: shown in the library banner, not as an error.
        if let preparedExportWarning { warning = "Bibliotheksdatei exportiert; \(preparedExportWarning). Notizbuch öffnen und prüfen." }
        discardPreparedExport()
    }

    private func discardPreparedExport() {
        if let preparedExport { BackupScratch.remove(preparedExport) }
        preparedExport = nil; preparedExportWarning = nil
    }

    func editorChoices() async -> [OpenNotebook] {
        var choices: [OpenNotebook] = []
        for item in snapshot.items where !item.isFolder && !snapshot.isTrashed(item.id) {
            if let directory = try? await store.documentURL(id: item.id) {
                choices.append(OpenNotebook(id: item.id, directory: directory, title: item.title,
                    isRestored: item.source == .restored))
            }
        }
        return choices
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

    private func change(_ action: () async throws -> LibrarySnapshot) async {
        await settle()
        guard ready, !busy, opened == nil else { return }
        busy = true
        defer { busy = false }
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

    func artwork(for id: UUID) async throws -> (NotebookAppearance?, UIImage?) {
        let url = try await store.documentURL(id: id)
        // Read before the document: a newer commit in between only re-renders later.
        let stamp = await Task.detached(priority: .utility) { NotebookRevisionStamp.read(directory: url) }.value
        if let stamp, let tile = tiles.object(forKey: id as NSUUID), tile.stamp == stamp { return (tile.appearance, tile.image) }
        let (document, assets) = try await store.previewPackage(id: id)
        try Task.checkCancellation()
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
        guard ready, !busy, opened == nil else { return false }
        busy = true; defer { busy = false }
        do {
            let notebook = try Notebook.blank(title: title, appearance: appearance)
            snapshot = try await store.createDocument(notebook, parentID: parent)
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
    func restore(_ id: UUID) async { await change { try await store.restore(id) } }
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
                parts.append("Das ursprüngliche Notizbuch liegt direkt im App-Ordner und bleibt im Papierkorb.")
            }
            if result.leftoverDirectories > 0 {
                parts.append("\(result.leftoverDirectories) Ordner konnten nicht vom Speicher entfernt werden; ihre Dateien bleiben erhalten und erscheinen nach dem Neuladen eventuell wieder in der Bibliothek.")
            }
            trashStatus = parts.joined(separator: " ")
        } catch { self.error = "Endgültiges Löschen fehlgeschlagen: \(error.localizedDescription)" }
    }
    func favorite(_ item: NotebookCore.LibraryItem) async { await change { try await store.setFavorite(item.id, value: !item.favorite) } }
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

    func open(_ item: NotebookCore.LibraryItem, pageID: UUID? = nil, searchBounds: PageRect? = nil) async {
        await settle()
        guard ready, !busy, opened == nil, !item.isFolder else { return }
        busy = true
        defer { busy = false }
        do {
            let url = try await store.documentURL(id: item.id)
            snapshot = try await store.markOpened(item.id)
            opened = OpenNotebook(id: item.id, directory: url, title: item.title,
                                  isRestored: item.source == .restored, preferredPageID: pageID, searchBounds: searchBounds)
            lastEditedID = item.id
            UserDefaults.standard.set(item.id.uuidString, forKey: lastOpenedKey)
        } catch { self.error = error.localizedDescription }
    }

    /// Called after the user closed the notebook normally (not on backgrounding).
    func notebookClosedByUser() { UserDefaults.standard.removeObject(forKey: lastOpenedKey) }

    /// Launch only: reopen the notebook that was open when the app was last used.
    /// Missing, trashed or unreadable documents are skipped silently and forgotten;
    /// the editor then restores its remembered page itself.
    private func reopenLastNotebook() async {
        guard let raw = UserDefaults.standard.string(forKey: lastOpenedKey) else { return }
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
        guard ready, !busy, opened == nil else { return }
        busy = true
        let access = url.startAccessingSecurityScopedResource()
        defer {
            if access { url.stopAccessingSecurityScopedResource() }
            busy = false
        }
        do {
            let data = try await Task.detached { try Self.readPDF(url) }.value
            guard let pdf = PDFDocument(data: data), !pdf.isLocked, (1...500).contains(pdf.pageCount) else {
                throw StorageError.invalidDocument
            }
            var document = Notebook()
            document.title = String(url.deletingPathExtension().lastPathComponent.prefix(120))
            document.pdf = data
            document.pages = try (0..<pdf.pageCount).map { index in
                guard let source = pdf.page(at: index)?.pageRef else { throw StorageError.invalidDocument }
                var page = Page(); page.geometry = try PDFPageGeometry(source); return page
            }
            if let writingArea {
                for page in document.pages {
                    let margins = try writingArea.scaled(from: .init(width: 1, height: 1), to: page.geometry?.displaySize ?? .a4)
                    try document.setMargins(margins, pageIDs: [page.id])
                }
            }
            // Originals above 20 MB get schema 10 at once, so Build 46 refuses the
            // whole notebook instead of failing later edits.
            if data.count > PDFSource.legacyMaximumBytes { document = try document.preparedForPageEditing() }
            snapshot = try await store.createDocument(document, parentID: parent)
        } catch { self.error = "PDF-Import fehlgeschlagen: \(error.localizedDescription)" }
    }

    /// Restores a notebook backup as a new separate copy; nil on failure (alert shown).
    @discardableResult
    func importBackup(_ url: URL, parent: UUID?) async -> RestoredNotebook? {
        await settle()
        guard ready, !busy, opened == nil else { return nil }
        busy = true
        let access = url.startAccessingSecurityScopedResource()
        defer {
            if access { url.stopAccessingSecurityScopedResource() }
            busy = false
        }
        do {
            // Use the existing staged, independently validated restore path.
            let repository = NotebookRepository(directory: root)
            let prepared = try await repository.prepareRestore(from: url)
            try EditorModelValidation.validate(prepared.document, assets: prepared.assets)
            let restored = try await repository.commitRestore(prepared)
            snapshot = try await store.load().snapshot
            if let parent { snapshot = try await store.move(restored.id, to: parent) }
            return restored
        } catch { self.error = "Wiederherstellung fehlgeschlagen: \(error.localizedDescription)"; return nil }
    }

    nonisolated static func readPDF(_ url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var data = Data()
        while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
            guard data.count + chunk.count <= PDFSource.maximumBytes else {
                throw NSError(domain: "noty", code: 1, userInfo: [NSLocalizedDescriptionKey: "PDFs dürfen höchstens 100 MB groß sein."])
            }
            data.append(chunk)
        }
        return data
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
