import SwiftUI
import PDFKit
import PencilKit
import UniformTypeIdentifiers
import NotebookCore

@MainActor
final class EditorModel: ObservableObject {
    @Published var notebook = Notebook()
    @Published var pageIndex = 0
    @Published var status = "Noch nicht gespeichert"
    @Published var error: String?
    @Published var writable = false
    @Published var busy = true
    @Published var saveFailed = false
    @Published var backupStatus = "Noch kein Backup exportiert"
    @Published var fileStatus: String?
    @Published var restoredCopies: [RestoredNotebook] = []
    @Published var openedRestore: RestoredNotebook?
    @Published private(set) var copiedPage: CopiedPage?
    @Published private(set) var cutPageID: UUID?
    @Published private(set) var pdfOutline: [NotebookOutlineItem] = []
    @Published private(set) var pageContentGeneration = 0
    let storageRoot: URL
    @Published private(set) var mutationsPaused = false
    private var activeInteractions = Set<UUID>()
    private var mutationWaiters: [CheckedContinuation<Void, Never>] = []
    var inputInProgress: Bool { !activeInteractions.isEmpty }
    func setInteraction(_ id: UUID, active: Bool) {
        if active { activeInteractions.insert(id) } else { activeInteractions.remove(id) }
    }
    func pauseMutations() { mutationsPaused = true }
    func resumeMutations() {
        mutationsPaused = false
        let waiters = mutationWaiters; mutationWaiters = []
        for waiter in waiters { waiter.resume() }
    }
    func awaitMutationAccess() async {
        if mutationsPaused { await withCheckedContinuation { mutationWaiters.append($0) } }
    }
    private let store: NotebookRepository
    private let backupDateKey: String
    private let preferredPageID: UUID?
    private let pageKeyPrefix: String
    private let legacyPageKeysAllowed: Bool
    private var pendingSave: Task<Void, Never>?
    private var revision = 0
    private var sources: NotebookPDFCatalog?

    init(storageRoot root: URL = URL.documentsDirectory.appendingPathComponent("Noty", isDirectory: true),
         restoreDirectory: URL? = nil, preferredPageID: UUID? = nil, libraryTitle: String? = nil) {
        storageRoot = root
        store = NotebookRepository(directory: root, restoreDirectory: restoreDirectory)
        backupDateKey = "noty.backupExport.\(root.path)"
        pageKeyPrefix = "noty.page.\(root.path)."
        let mainPath = URL.documentsDirectory.appendingPathComponent("Noty", isDirectory: true).path
        legacyPageKeysAllowed = root.path == mainPath || root.path.hasPrefix(mainPath + "/")
        self.preferredPageID = preferredPageID
        let legacyDate = legacyPageKeysAllowed ? UserDefaults.standard.object(forKey: "noty.backupExport.\(root.lastPathComponent)") as? Date : nil
        if let date = UserDefaults.standard.object(forKey: backupDateKey) as? Date ?? legacyDate {
            backupStatus = "Letzter Datei-Export: \(date.formatted(date: .abbreviated, time: .shortened))"
        }
        Task {
            defer { busy = false }
            do {
                var (loaded, recovered) = try await store.load()
                try validate(loaded)
                // Keep legacy page geometry nil: existing ink is never rescaled.
                loaded.schemaVersion = max(2, loaded.schemaVersion)
                // Library names are authoritative; synchronize only while this
                // editor exclusively owns the document, never from the index actor.
                if let libraryTitle { loaded.title = libraryTitle }
                sources = try NotebookPDFCatalog(loaded)
                pdfOutline = sources?.outline ?? []
                notebook = loaded
                let legacyPage = legacyPageKeysAllowed ? UserDefaults.standard.string(forKey: "noty.page.\(loaded.id.uuidString)") : nil
                let remembered = (UserDefaults.standard.string(forKey: pageKeyPrefix + loaded.id.uuidString) ?? legacyPage).flatMap(UUID.init(uuidString:))
                if let id = self.preferredPageID ?? remembered,
                   let index = loaded.pages.firstIndex(where: { $0.id == id }) { pageIndex = index }
                writable = true
                status = recovered ? "Aus Wiederherstellungskopie geladen" : "Bereit"
                // Also commit the prototype-to-revision migration without
                // requiring the user to change an otherwise unchanged note.
                save()
            } catch {
                status = "Lesefehler – Originaldateien geschützt"
                self.error = "Gespeicherte Daten sind nicht lesbar. Originaldateien bleiben erhalten. Ein exportiertes Backup kann über Dateien wiederhergestellt werden. \(error.localizedDescription)"
            }
            await refreshRestoredCopies()
        }
    }

    func validate(_ document: Notebook) throws {
        try EditorModelValidation.validate(document)
    }

    var page: Page { notebook.pages[pageIndex] }
    var sourcePage: PDFPage? { sourcePage(for: page) }
    func sourcePage(for page: Page) -> PDFPage? { sources?.sourcePage(for: page) }
    var pageLayout: PageLayout {
        // validate() guarantees the imported geometry before activating the editor.
        (try? PageLayout(page: page, source: sourcePage?.pageRef))
            ?? PageLayout(source: .testPaper, legacyA4: true)
    }

    func updateTextBoxes(_ boxes: [TextBox], pageID: UUID) {
        guard writable, !mutationsPaused, let index = notebook.pages.firstIndex(where: { $0.id == pageID }) else { return }
        guard notebook.pages[index].effectiveTextBoxes != boxes else { return }
        do {
            var candidate = notebook
            try candidate.replaceTextBoxes(boxes, pageID: pageID)
            if candidate.schemaVersion != notebook.schemaVersion {
                let catalogue = try NotebookPDFCatalog(candidate, reusing: sources)
                sources = catalogue; pdfOutline = catalogue.outline
            }
            notebook = candidate
            scheduleSave()
        } catch { self.error = "Textänderung konnte nicht übernommen werden: \(error.localizedDescription)" }
    }

    // Text-flow history is atomic across pages. Expected full snapshots prevent
    // an old text undo from overwriting later ink/image/restore edits.
    private struct FlowHistoryEntry {
        var before: Notebook
        var after: Notebook
        var beforeFocus: TextFlowFocus
        var afterFocus: TextFlowFocus
    }
    private var flowUndo: [FlowHistoryEntry] = []
    private var flowRedo: [FlowHistoryEntry] = []

    func updateFlowText(pageID: UUID, previous: TextBox, replacement: TextBox,
                        selection: NSRange, trailingDraft: Page? = nil) -> TextFlowFocus? {
        guard writable, !busy, !mutationsPaused else { return nil }
        let before = notebook
        do {
            let (candidate, focus) = try notebook.reflowText(pageID: pageID, previous: previous,
                replacement: replacement, selection: selection, trailingDraft: trailingDraft, capacity: TextFlowEditing.capacity)
            let beforeFocus = TextFlowFocus(pageID: pageID, boxID: previous.id,
                selection: NSRange(location: min(selection.location, (previous.text as NSString).length), length: 0), typingStyle: previous.style)
            try installFlow(candidate)
            if candidate != before {
                flowUndo.append(FlowHistoryEntry(before: before, after: candidate, beforeFocus: beforeFocus, afterFocus: focus))
                if flowUndo.count > 50 { flowUndo.removeFirst() }; flowRedo.removeAll()
            }
            return focus
        } catch {
            self.error = "Textfluss: \(error.localizedDescription)"
            // Keep an overflowing edit on its original page rather than losing
            // typed/pasted text when the page limit or glyph capacity is reached.
            if let index = notebook.pages.firstIndex(where: { $0.id == pageID }),
               notebook.pages[index].effectiveTextBoxes.contains(previous) {
                var boxes = notebook.pages[index].effectiveTextBoxes
                if let i = boxes.firstIndex(where: { $0.id == previous.id }) { boxes[i] = replacement }
                updateTextBoxes(boxes, pageID: pageID)
                if notebook != before {
                    let focus = TextFlowFocus(pageID: pageID, boxID: replacement.id, selection: selection, typingStyle: replacement.style)
                    flowUndo.append(FlowHistoryEntry(before: before, after: notebook, beforeFocus: focus, afterFocus: focus))
                    if flowUndo.count > 50 { flowUndo.removeFirst() }; flowRedo.removeAll()
                    return focus
                }
            }
            return nil
        }
    }
    func undoFlowText(redo: Bool) -> TextFlowFocus? {
        guard writable, !busy, !mutationsPaused,
              let entry = redo ? flowRedo.last : flowUndo.last else { return nil }
        guard notebook == (redo ? entry.before : entry.after) else {
            flowUndo.removeAll(); flowRedo.removeAll()
            error = "Der Heftinhalt wurde außerhalb des Textflusses geändert. Alte Text-Undo-Schritte wurden zum Schutz dieser Änderungen verworfen."
            return nil
        }
        do {
            try installFlow(redo ? entry.after : entry.before)
            if redo { flowRedo.removeLast(); flowUndo.append(entry) }
            else { flowUndo.removeLast(); flowRedo.append(entry) }
            return redo ? entry.afterFocus : entry.beforeFocus
        } catch { self.error = error.localizedDescription; return nil }
    }
    func backspaceFlowText(pageID: UUID, box: TextBox) -> TextFlowFocus? {
        guard let index = notebook.pages.firstIndex(where: { $0.id == pageID }), let flow = box.flowID,
              let previousIndex = notebook.pages.indices.last(where: { $0 < index && notebook.pages[$0].effectiveTextBoxes.contains(where: { $0.flowID == flow }) }),
              let previous = notebook.pages[previousIndex].effectiveTextBoxes.first(where: { $0.flowID == flow }) else { return nil }
        var replacement = previous
        let text = previous.text as NSString
        if text.length > 0 {
            let last = text.rangeOfComposedCharacterSequence(at: text.length - 1)
            guard let part = try? previous.fragment(NSRange(location: 0, length: last.location)) else { return nil }
            replacement = part
        }
        return updateFlowText(pageID: notebook.pages[previousIndex].id, previous: previous,
            replacement: replacement, selection: NSRange(location: (replacement.text as NSString).length, length: 0))
    }
    private func installFlow(_ candidate: Notebook) throws {
        try candidate.validate()
        if candidate.schemaVersion != notebook.schemaVersion || candidate.pages.map(\.id) != notebook.pages.map(\.id)
            || candidate.pdfSources != notebook.pdfSources || candidate.pdf != notebook.pdf {
            let catalogue = try NotebookPDFCatalog(candidate, reusing: sources)
            sources = catalogue; pdfOutline = catalogue.outline
        }
        notebook = candidate
        if pageIndex >= notebook.pages.count { pageIndex = notebook.pages.count - 1 }
        scheduleSave()
    }

    @discardableResult
    func materializeDraft(_ draft: Page) -> Bool {
        guard writable, !mutationsPaused, !busy else { return false }
        do {
            var candidate = notebook; try candidate.materializeWritingDraft(draft)
            if candidate != notebook { try installFlow(candidate) }
            return true
        } catch { self.error = error.localizedDescription; return false }
    }

    func updateDrawing(_ data: Data, pageID: UUID) {
        guard writable, !mutationsPaused, let index = notebook.pages.firstIndex(where: { $0.id == pageID }) else { return }
        notebook.pages[index].drawing = data
        scheduleSave()
    }

    func updateImages(_ images: [ImageObject], pageID: UUID) {
        guard writable, !mutationsPaused, let index = notebook.pages.firstIndex(where: { $0.id == pageID }),
              (notebook.pages[index].images ?? []) != images else { return }
        do {
            var candidate = notebook
            try candidate.replaceImages(images, pageID: pageID)
            if candidate.schemaVersion != notebook.schemaVersion {
                let catalogue = try NotebookPDFCatalog(candidate, reusing: sources)
                sources = catalogue; pdfOutline = catalogue.outline
            }
            notebook = candidate; scheduleSave()
        } catch { self.error = "Bildänderung konnte nicht übernommen werden. Höchstens 50 Bilder pro Seite und 40 MB Bildoriginale pro Heft. \(error.localizedDescription)" }
    }

    @discardableResult
    func updateContent(_ content: PageContent, basedOn previous: PageContent, pageID: UUID) -> Bool {
        guard writable, !mutationsPaused, !busy, let index = notebook.pages.firstIndex(where: { $0.id == pageID }),
              PageContent(page: notebook.pages[index]) == previous else {
            error = "Die Seite wurde inzwischen in einer anderen Ansicht geändert. Bitte die Auswahl erneut setzen."
            return false
        }
        do {
            var candidate = notebook; try candidate.replaceContent(content, pageID: pageID)
            if candidate.schemaVersion != notebook.schemaVersion {
                let catalogue = try NotebookPDFCatalog(candidate, reusing: sources)
                sources = catalogue; pdfOutline = catalogue.outline
            }
            notebook = candidate; scheduleSave(); return true
        } catch { self.error = "Objektänderung nicht übernommen: \(error.localizedDescription)"; return false }
    }

    private func scheduleSave() { save(delayed: true) }

    func selectPage(_ id: UUID) {
        guard writable, !mutationsPaused, !busy, let index = notebook.pages.firstIndex(where: { $0.id == id }) else { return }
        pageIndex = index
    }

    /// A complete value change is installed only after validation. The existing
    /// actor owns its save and keeps failures visible with the candidate in memory.
    @discardableResult
    private func editPages(resetEditor: Bool = false, _ action: (inout Notebook) throws -> UUID?) -> Bool {
        guard writable, !mutationsPaused, !busy else { return false }
        let selected = page.id
        let oldIndex = pageIndex
        do {
            var candidate = notebook
            let requested = try action(&candidate)
            let catalogue = try NotebookPDFCatalog(candidate, reusing: sources)
            let index = candidate.pages.firstIndex(where: { $0.id == (requested ?? selected) })
                ?? min(oldIndex, candidate.pages.count - 1)
            sources = catalogue
            pdfOutline = catalogue.outline
            if resetEditor { pageContentGeneration += 1 }
            notebook = candidate
            pageIndex = index
            save(); return true
        } catch { self.error = error.localizedDescription; return false }
    }

    func insertPaper(_ style: PaperStyle, color: PaperColor = .white, relativeTo anchor: UUID, before: Bool = false, geometry: PDFPageGeometry? = nil) {
        editPages { document in
            guard let index = document.pages.firstIndex(where: { $0.id == anchor }) else { throw PageOperationError.missingPage }
            return try document.insertPaper(style, color: color, at: index + (before ? 0 : 1), geometry: geometry)
        }
    }

    func duplicatePage(_ id: UUID) { editPages { try $0.duplicatePage(id) } }
    func copyPage(_ id: UUID, cut: Bool = false) {
        guard writable, !mutationsPaused, !busy else { return }
        do { copiedPage = try notebook.copyPage(id); cutPageID = cut ? id : nil }
        catch { self.error = error.localizedDescription }
    }
    func pastePage(after anchor: UUID) {
        guard let payload = copiedPage else { return }
        let cutID = cutPageID
        let success = editPages { document in
            if let cutID { try document.movePage(cutID, after: anchor); return cutID }
            return try document.pastePage(payload, after: anchor)
        }
        if cutID != nil, success { copiedPage = nil; cutPageID = nil }
    }
    func clearPage(_ id: UUID) { editPages(resetEditor: true) { try $0.clearPage(id); return id } }
    func movePage(_ id: UUID, to index: Int) { editPages { try $0.movePage(id, to: index); return nil } }
    func reorderPages(_ ids: [UUID]) { editPages { try $0.reorderPages(ids); return nil } }
    func trashPage(_ id: UUID) { editPages { try $0.trashPage(id); return nil } }
    func restorePage(_ id: UUID) { editPages(resetEditor: true) { try $0.restorePage(id) } }
    func toggleBookmark(_ id: UUID) { editPages { try $0.toggleBookmark(id); return nil } }

    func installMarginSnapshot(_ candidate: Notebook) throws {
        guard writable, !mutationsPaused, !busy else { throw PageOperationError.missingPage }
        let selected = page.id
        let catalogue = try NotebookPDFCatalog(candidate, reusing: sources)
        let index = candidate.pages.firstIndex { $0.id == selected } ?? min(pageIndex, candidate.pages.count - 1)
        sources = catalogue
        pdfOutline = catalogue.outline
        notebook = candidate
        pageIndex = index
        save()
    }

    func insertPDF(_ url: URL, relativeTo anchor: UUID, before: Bool = false, writingArea: PageMargins? = nil) {
        if mutationsPaused {
            let access = url.startAccessingSecurityScopedResource()
            Task {
                await awaitMutationAccess()
                insertPDF(url, relativeTo: anchor, before: before, writingArea: writingArea)
                if access { url.stopAccessingSecurityScopedResource() }
            }
            return
        }
        guard writable, !mutationsPaused, !busy else { return }
        busy = true
        let access = url.startAccessingSecurityScopedResource()
        Task {
            defer { if access { url.stopAccessingSecurityScopedResource() }; busy = false }
            do {
                let data = try await Task.detached { try LibraryModel.readPDF(url) }.value
                guard let pdf = PDFDocument(data: data), !pdf.isLocked, (1...500).contains(pdf.pageCount) else {
                    throw StorageError.invalidDocument
                }
                let geometries = try (0..<pdf.pageCount).map { index in
                    guard let page = pdf.page(at: index)?.pageRef else { throw StorageError.invalidDocument }
                    return try PDFPageGeometry(page)
                }
                guard let index = notebook.pages.firstIndex(where: { $0.id == anchor }) else { throw PageOperationError.missingPage }
                var candidate = notebook
                let ids = try candidate.insertPDF(data, geometries: geometries, at: index + (before ? 0 : 1))
                if let writingArea {
                    for id in ids {
                        guard let page = candidate.pages.first(where: { $0.id == id }) else { throw PageOperationError.missingPage }
                        let margins = try writingArea.scaled(from: .init(width: 1, height: 1), to: page.geometry?.displaySize ?? .a4)
                        try candidate.setMargins(margins, pageIDs: [id])
                    }
                }
                let catalogue = try NotebookPDFCatalog(candidate, reusing: sources)
                sources = catalogue
                pdfOutline = catalogue.outline
                notebook = candidate
                if let first = ids.first, let position = candidate.pages.firstIndex(where: { $0.id == first }) { pageIndex = position }
                save()
            } catch { self.error = "PDF-Einfügen fehlgeschlagen: \(error.localizedDescription)" }
        }
    }

    /// Closing must finish its last commit before another editor can be opened.
    /// On failure the editor stays open with its unsaved in-memory snapshot.
    func flushBeforeClosing() async -> Bool {
        guard !busy else { return false }
        guard writable else { return true }
        busy = true
        defer { busy = false }
        save()
        while true {
            let closingRevision = revision
            await pendingSave?.value
            if closingRevision == revision {
                if saveFailed { return false }
                writable = false
                return true
            }
        }
    }

    func waitForSave() async -> Bool {
        while true {
            let expected = revision
            await pendingSave?.value
            if expected == revision { return !saveFailed }
        }
    }

    func save(delayed: Bool = false) {
        guard writable else { return }
        UserDefaults.standard.set(page.id.uuidString, forKey: pageKeyPrefix + notebook.id.uuidString)
        pendingSave?.cancel()
        revision += 1
        let snapshot = notebook
        let savingRevision = revision
        status = "Änderungen werden gespeichert …"
        saveFailed = false
        // Give iOS time to complete a flush when moving to the background.
        let background = delayed ? UIBackgroundTaskIdentifier.invalid : UIApplication.shared.beginBackgroundTask(withName: "noty-save")
        pendingSave = Task {
            defer {
                if background != .invalid { UIApplication.shared.endBackgroundTask(background) }
            }
            do {
                if delayed { try await Task.sleep(for: .milliseconds(250)) }
                try Task.checkCancellation()
                try await store.save(snapshot, revision: savingRevision)
                if savingRevision == revision { status = "Lokal gespeichert" }
            } catch is CancellationError {
                // A newer complete snapshot supersedes this one.
            } catch {
                if savingRevision == revision {
                    status = "Speichern fehlgeschlagen – Änderungen nur im Speicher"
                    saveFailed = true
                    self.error = error.localizedDescription
                }
            }
        }
    }

    func importFile(_ url: URL, backup: Bool) {
        guard !busy else { return }
        if backup {
            restoreBackupAsCopy(url)
            return
        }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey])
            guard (values.fileSize ?? 0) <= 20_000_000 else { throw StorageError.invalidDocument }
            let data = try Data(contentsOf: url)
            guard let pdf = PDFDocument(data: data), !pdf.isLocked,
                  (1...500).contains(pdf.pageCount) else { throw StorageError.invalidDocument }
            var candidate = Notebook()
            candidate.title = url.deletingPathExtension().lastPathComponent
            candidate.pdf = data
            candidate.pages = try (0..<pdf.pageCount).map { index in
                guard let source = pdf.page(at: index)?.pageRef else { throw StorageError.invalidDocument }
                var page = Page()
                page.geometry = try PDFPageGeometry(source)
                return page
            }
            try validate(candidate)
            pendingSave?.cancel()
            revision += 1
            let replacementRevision = revision
            let previous = writable ? notebook : nil
            writable = false
            busy = true
            Task {
                defer { busy = false }
                do {
                    try await store.replace(candidate, preserving: previous, revision: replacementRevision)
                    pageIndex = 0
                    sources = try NotebookPDFCatalog(candidate)
                    pdfOutline = sources?.outline ?? []
                    notebook = candidate
                    writable = true
                    status = "Importiert und lokal gespeichert"
                    saveFailed = false
                } catch {
                    writable = previous != nil
                    self.error = "Import fehlgeschlagen: \(error.localizedDescription)"
                }
            }
        } catch { self.error = "Import fehlgeschlagen: \(error.localizedDescription)" }
    }

    func backupData() async -> Data? {
        guard writable, !mutationsPaused, !busy else { return nil }
        busy = true
        let snapshot = notebook
        backupStatus = "Backup wird vorbereitet …"
        defer { busy = false }
        do {
            let data = try await store.backup(snapshot)
            backupStatus = "Backup geprüft · Speicherort wählen"
            return data
        } catch {
            backupStatus = "Backup konnte nicht erstellt werden"
            self.error = error.localizedDescription
            return nil
        }
    }

    func backupExported() {
        let date = Date()
        UserDefaults.standard.set(date, forKey: backupDateKey)
        backupStatus = "Backup-Datei exportiert: \(date.formatted(date: .omitted, time: .shortened))"
    }

    func refreshRestoredCopies() async {
        do {
            let catalog = try await store.restoredCopies()
            restoredCopies = catalog.notebooks
            if catalog.unreadableCount > 0 {
                fileStatus = "\(catalog.unreadableCount) Wiederherstellungskopie(n) nicht lesbar · Dateien bleiben erhalten"
            }
        } catch { fileStatus = "Wiederherstellungskopien konnten nicht aufgelistet werden" }
    }

    func localHistory() async throws -> LocalHistory {
        try await store.localHistory()
    }

    func openLocalRevisionAsCopy(_ id: UUID) {
        guard !busy else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                let prepared = try await store.prepareLocalRecovery(id: id)
                try await openPreparedRestore(prepared, message: "Lokalen Stand als separate Kopie geöffnet")
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func openPreparedRestore(_ prepared: PreparedRestore, message: String) async throws {
        try validate(prepared.document)
        var restored = try await store.commitRestore(prepared)
        restored.preferredPageID = page.id
        await refreshRestoredCopies()
        backupStatus = message
        openedRestore = restored
    }

    private func restoreBackupAsCopy(_ url: URL) {
        busy = true
        let access = url.startAccessingSecurityScopedResource()
        Task {
            defer {
                if access { url.stopAccessingSecurityScopedResource() }
                busy = false
            }
            do {
                let prepared = try await store.prepareRestore(from: url)
                // Foundation tests cannot validate these Apple-framework layers.
                let message = prepared.isLegacyJSON
                    ? "Altes JSON ohne Prüfsumme als separate Kopie wiederhergestellt"
                    : "Backup geprüft und als separate Kopie wiederhergestellt"
                try await openPreparedRestore(prepared, message: message)
            } catch {
                backupStatus = "Wiederherstellung fehlgeschlagen · aktuelles Heft erhalten"
                self.error = error.localizedDescription
            }
        }
    }
}

@MainActor
enum EditorModelValidation {
    static func validate(_ document: Notebook) throws {
        _ = try NotebookPDFCatalog(document)
        for page in document.pages + (document.deletedPages ?? []).map(\.page) where !page.drawing.isEmpty {
            _ = try PKDrawing(data: page.drawing)
        }
        for page in document.pages + (document.deletedPages ?? []).map(\.page) {
            for image in page.images ?? [] { try ImageRendering.validate(image) }
        }
    }
}

extension UTType {
    static let notyBackup = UTType(exportedAs: "de.la.noty.backup", conformingTo: .data)
    static let notyLibrary = UTType(exportedAs: "de.la.noty.library", conformingTo: .data)
}

struct ExportFile: FileDocument {
    static var readableContentTypes: [UTType] { [.notyBackup, .notyLibrary, .json, .pdf] }
    var data: Data
    init(backupData: Data) { data = backupData }
    init(pdfData: Data) { data = pdfData }
    init(libraryData: Data) { data = libraryData }
    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
        if configuration.contentType == .notyLibrary { _ = try LibraryArchive.decode(data) }
        else if configuration.contentType != .pdf { _ = try BackupArchive.decode(data) }
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
