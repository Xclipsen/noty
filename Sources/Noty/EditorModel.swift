import SwiftUI
import PDFKit
import PencilKit
import UniformTypeIdentifiers
import NotebookCore

@MainActor
final class EditorModel: ObservableObject {
    /// Until the stored document is installed this is a neutral blank sheet,
    /// never the prototype test page; the editor does not show it anyway
    /// (`documentLoaded`), and it is never saved (`writable` is false).
    @Published var notebook = Notebook.blank(title: "")
    @Published var pageIndex = 0 { didSet { if pageIndex != oldValue { rememberPage() } } }
    @Published var status = "Noch nicht gespeichert"
    @Published var error: String?
    @Published var writable = false { didSet { if writable && !documentLoaded { documentLoaded = true } } }
    /// Latched once a real document was installed (first `writable`). Later
    /// read-only phases (import, closing) keep it, so views are not torn down.
    /// Owned by the model, not by a view: a view reused for another model can
    /// never mistake that model's placeholder for loaded content.
    @Published private(set) var documentLoaded = false
    @Published var busy = true
    @Published var saveFailed = false
    @Published var backupStatus = "Noch kein Backup exportiert"
    @Published var fileStatus: String?
    @Published var openedRestore: RestoredNotebook?
    @Published private(set) var copiedPage: CopiedPage?
    @Published private(set) var cutPageID: UUID?
    @Published private(set) var pdfOutline: [NotebookOutlineItem] = []
    @Published private(set) var pageContentGeneration = 0
    /// Notebook-wide, chronological undo/redo across all pages and layers.
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    private var history = NotebookUndoHistory()
    /// One counter per page; each PencilKit tool use (stroke, eraser gesture)
    /// becomes one undo step even when it reports several drawing changes.
    private var inkSessions: [UUID: Int] = [:]
    let storageRoot: URL
    /// Root of the library area this notebook belongs to: the restore
    /// collection is always `<area root>/Restores` (library notebooks and
    /// restored copies), the legacy main notebook lives in the area root.
    /// Local history copies get titles unique in this area.
    private let libraryRoot: URL
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
    /// Set while an older fallback state is open unchanged (see init).
    private var recoveredSnapshot: Notebook?
    private var retryTask: Task<Void, Never>?
    private var retryAttempt = 0
    /// Last non-retryable save error already shown; cleared by a successful save.
    private var lastPermanentFailure: String?
    /// The package's asset GC after opening (repository actor, before its
    /// first commit; skipped there once a commit happened).
    private var openingCleanup: Task<Void, Never>?

    init(storageRoot root: URL = URL.documentsDirectory.appendingPathComponent("Noty", isDirectory: true),
         restoreDirectory: URL? = nil, preferredPageID: UUID? = nil, libraryTitle: String? = nil) {
        storageRoot = root
        libraryRoot = restoreDirectory?.deletingLastPathComponent() ?? root
        store = NotebookRepository(directory: root, restoreDirectory: restoreDirectory)
        // Image layers, thumbnails and exports of this editor resolve its
        // originals (files and pending imports) through the registry.
        ImageAssetRegistry.shared.register(store.assets)
        // Container-independent keys (relative to Documents); the former
        // absolute-path keys stop matching when iOS moves the container on update.
        backupDateKey = StableDefaults.key("backupExport", root: root, legacyPrefix: "noty.backupExport.", pick: StableDefaults.newestDate)
        pageKeyPrefix = StableSettingsKey.key("page", scope: StableDefaults.scope(root)) + "."
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
                // Opening speed: decode every PencilKit drawing and image off the
                // UI actor; PDFKit parsing happens once (the catalogue below
                // validates the PDFs) instead of twice on the UI actor.
                let snapshot = loaded, assets = store.assets
                try await Task.detached(priority: .userInitiated) {
                    try EditorModelValidation.validateOnOpening(snapshot, assets: assets)
                }.value
                EditorOpenTrace.mark("document read", "pages=\(loaded.pages.count)")
                // Keep legacy page geometry nil: existing ink is never rescaled.
                loaded.schemaVersion = max(2, loaded.schemaVersion)
                // Library names are authoritative; synchronize only while this
                // editor exclusively owns the document, never from the index actor.
                if let libraryTitle { loaded.title = libraryTitle }
                sources = try NotebookPDFCatalog(loaded)
                pdfOutline = sources?.outline ?? []
                notebook = loaded
                let legacyPage = legacyPageKeysAllowed ? UserDefaults.standard.string(forKey: "noty.page.\(loaded.id.uuidString)") : nil
                let pageKey = StableDefaults.key("page", root: root, suffix: "." + loaded.id.uuidString, legacyPrefix: "noty.page.")
                let remembered = (UserDefaults.standard.string(forKey: pageKey) ?? legacyPage).flatMap(UUID.init(uuidString:))
                if let id = self.preferredPageID ?? remembered,
                   let index = loaded.pages.firstIndex(where: { $0.id == id }) { pageIndex = index }
                writable = true
                if recovered {
                    // An older fallback is committed only with the first real
                    // change: opening alone never replaces the newer manifest
                    // or moves the skipped newer revisions to Quarantine/.
                    recoveredSnapshot = loaded
                    status = "Älterer geprüfter Stand geladen – noch nicht gespeichert"
                    error = "Der neueste Speicherstand dieses Hefts ist beschädigt oder unvollständig. Geöffnet wurde der letzte vollständig geprüfte ältere Stand. Die neueren Daten werden nicht gelöscht: Mit der nächsten Änderung wird dieser Stand gespeichert, beschädigte neuere Revisionen bleiben im Ordner „Quarantine“ des Hefts erhalten."
                } else {
                    status = "Bereit"
                    // Also commit the prototype-to-revision migration without
                    // requiring the user to change an otherwise unchanged note.
                    save()
                }
                // Before any undo history can matter: the repository refuses
                // the opening run once this editor committed anything.
                openingCleanup = Task { [store] in
                    _ = try? await store.collectAssetGarbage(.opening, keeping: ImageAssetRegistry.shared.clipboardHashes)
                }
            } catch {
                status = "Lesefehler – Originaldateien geschützt"
                self.error = "Gespeicherte Daten sind nicht lesbar. Originaldateien bleiben erhalten. Ein exportiertes Backup kann über Dateien wiederhergestellt werden. \(error.localizedDescription)"
            }
        }
    }

    func validate(_ document: Notebook, assets: ImageAssetProviding? = nil) throws {
        try EditorModelValidation.validate(document, assets: assets)
    }

    /// This notebook's image originals: committed package files plus pending
    /// imports (staged here, written by the next commit before its revision).
    nonisolated var imageAssets: NotebookAssets { store.assets }

    /// Originals referenced by `images` that this notebook does not have yet
    /// (objects pasted from another notebook's selection) are staged here
    /// from the package that holds them, before the change is installed;
    /// otherwise every later commit would fail on a missing asset. Objects
    /// already in the notebook cost no file access.
    private func adoptImageAssets<S: Sequence>(_ images: S) throws where S.Element == ImageObject {
        let known = Set(notebook.allImages.map(\.asset.sha256))
        for reference in Set(images.map(\.asset)) where !known.contains(reference.sha256) && !imageAssets.isAvailable(reference) {
            guard let data = ImageAssetRegistry.shared.data(for: reference) else { throw ImageAssetError.missing(reference.sha256) }
            _ = try imageAssets.stage(data)
        }
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
        HangProbe.hit("Model.updateTextBoxes")
        guard writable, !mutationsPaused, let index = notebook.pages.firstIndex(where: { $0.id == pageID }) else { return }
        guard notebook.pages[index].effectiveTextBoxes != boxes else { return }
        do {
            let before = PageContent(page: notebook.pages[index])
            var candidate = notebook
            try candidate.replaceTextBoxes(boxes, pageID: pageID)
            if candidate.schemaVersion != notebook.schemaVersion {
                let catalogue = try NotebookPDFCatalog(candidate, reusing: sources)
                sources = catalogue; pdfOutline = catalogue.outline
            }
            notebook = candidate
            recordChange(.text, pageID: pageID, before: before,
                         coalescing: .init(key: "text-\(pageID.uuidString)", window: 1.5))
            scheduleSave()
        } catch { self.error = "Textänderung konnte nicht übernommen werden: \(error.localizedDescription)" }
    }

    // Text-flow edits are atomic across pages and part of the notebook-wide
    // history; expected states prevent an old text undo from overwriting later edits.
    private static let flowCoalescing = NotebookUndoHistory.Coalescing(key: "text-flow", window: 1.5)

    /// Automatic list conversion: its own undo step, apart from the typing.
    func separateUndoStep() { history.separateNextStep() }

    func updateFlowText(pageID: UUID, previous: TextBox, replacement: TextBox,
                        selection: NSRange, trailingDraft: Page? = nil) -> TextFlowFocus? {
        guard writable, !busy, !mutationsPaused else { return nil }
        let before = notebook
        do {
            let (candidate, focus) = try notebook.reflowText(pageID: pageID, previous: previous,
                replacement: replacement, selection: selection, trailingDraft: trailingDraft,
                drawingIsEmpty: Self.drawingIsEmpty,
                pageCapacity: { page, box in TextFlowEditing.capacity(box, page: page) })
            let beforeFocus = TextFlowFocus(pageID: pageID, boxID: previous.id,
                selection: NSRange(location: TextListEditing.caret(before: previous.text, after: replacement.text, selection: selection.location), length: 0),
                typingStyle: previous.style)
            try installFlow(candidate)
            history.record(.textFlow, before: before, after: candidate, beforeFocus: beforeFocus, afterFocus: focus,
                           coalescing: Self.flowCoalescing)
            publishHistory()
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
                    // updateTextBoxes already recorded this page change.
                    return TextFlowFocus(pageID: pageID, boxID: replacement.id, selection: selection, typingStyle: replacement.style)
                }
            }
            return nil
        }
    }
    /// No strokes (also ink whose strokes were all erased): such a page holds
    /// nothing in a text document and is neither kept after the text nor exported.
    nonisolated static func drawingIsEmpty(_ data: Data) -> Bool {
        data.isEmpty || ((try? PKDrawing(data: data))?.strokes.isEmpty ?? false)
    }

    /// Text documents: where a tap below the text, on a page after it or on
    /// the reserve page puts the caret (end of the flow). A document without
    /// flow (not written by this build) gets one on its first page first.
    func textFlowEnd() -> TextFlowFocus? {
        guard notebook.isTextDocument, writable, !busy, !mutationsPaused else { return nil }
        if let focus = notebook.textFlowEndFocus { return focus }
        do {
            guard let (candidate, focus) = try notebook.addingTextFlow() else { return nil }
            let before = notebook
            try installFlow(candidate)
            recordPageOperation(before: before, undoPageID: focus.pageID)
            return focus
        } catch { self.error = "Textfluss: \(error.localizedDescription)"; return nil }
    }

    /// Pages of a whole-document PDF: text documents without trailing empty pages.
    var exportedPageIDs: [UUID] { notebook.exportedPageIDs(drawingIsEmpty: Self.drawingIsEmpty) }

    /// Reverts (or re-applies) the most recent change on any page, in order.
    /// Steps whose page was deleted, replaced or changed elsewhere are dropped;
    /// they never overwrite newer content. Returns the page to reveal.
    func undo(redo: Bool) -> NotebookUndoHistory.Outcome? {
        guard writable, !busy, !mutationsPaused else { return nil }
        defer { publishHistory() }
        guard let outcome = redo ? history.redo(notebook) : history.undo(notebook) else { return nil }
        do {
            let previous = notebook
            let selected = page.id
            try installFlow(outcome.notebook)
            if outcome.kind == .pages {
                // Page operations reorder/insert pages: keep the open page by ID.
                if let index = notebook.pages.firstIndex(where: { $0.id == selected }) { pageIndex = index }
                // Content of existing pages changed (clear, restore, whole-notebook
                // restyle): reload every canvas like the original operation did, so
                // no late callback of an old canvas writes the other state back.
                let old = Dictionary(previous.pages.map { ($0.id, PageContent(page: $0)) }, uniquingKeysWith: { a, _ in a })
                if notebook.pages.contains(where: { page in old[page.id].map { $0 != PageContent(page: page) } ?? false }) {
                    pageContentGeneration += 1
                }
            }
            return outcome
        } catch {
            history.removeAll()
            self.error = "Rückgängig nicht möglich: \(error.localizedDescription)"
            return nil
        }
    }
    /// A PencilKit tool use began on this page (stroke or eraser gesture).
    func beginInkSession(pageID: UUID) { inkSessions[pageID, default: 0] += 1 }
    private func recordChange(_ kind: NotebookUndoHistory.Kind, pageID: UUID, before: PageContent,
                              coalescing: NotebookUndoHistory.Coalescing? = nil) {
        guard let page = notebook.pages.first(where: { $0.id == pageID }) else { return }
        history.record(kind, changes: [PageContentReplacement(pageID: pageID, expected: before, replacement: PageContent(page: page))],
                       coalescing: coalescing)
        publishHistory()
    }
    private func publishHistory() {
        if canUndo != history.canUndo { canUndo = history.canUndo }
        if canRedo != history.canRedo { canRedo = history.canRedo }
    }
    /// After edits outside the history: drop steps that no longer match so the
    /// buttons stay truthful.
    private func pruneHistory() { history.prune(notebook); publishHistory() }
    /// Page operations (paper defaults, add, delete, duplicate, move, PDF
    /// insertion, clear, restore, bookmark, margins) are one undo step each.
    /// A change that cannot be recorded safely (legacy notebook migrated by
    /// this very operation) only prunes, as before.
    private func recordPageOperation(before: Notebook, undoPageID: UUID) {
        let redoPageID = notebook.pages.indices.contains(pageIndex) ? notebook.pages[pageIndex].id : undoPageID
        if history.recordPages(before: before, after: notebook, undoPageID: undoPageID, redoPageID: redoPageID) {
            publishHistory()
        } else {
            pruneHistory()
        }
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
        HangProbe.hit("Model.updateDrawing")
        guard writable, !mutationsPaused, let index = notebook.pages.firstIndex(where: { $0.id == pageID }),
              notebook.pages[index].drawing != data else { return }
        let before = PageContent(page: notebook.pages[index])
        notebook.pages[index].drawing = data
        recordChange(.ink, pageID: pageID, before: before, coalescing: inkCoalescing(pageID))
        scheduleSave()
    }
    /// One undo step per PencilKit tool use on a page.
    private func inkCoalescing(_ pageID: UUID) -> NotebookUndoHistory.Coalescing {
        .init(key: "ink-\(pageID.uuidString)-\(inkSessions[pageID] ?? 0)", window: 120)
    }

    func updateImages(_ images: [ImageObject], pageID: UUID) {
        guard writable, !mutationsPaused, let index = notebook.pages.firstIndex(where: { $0.id == pageID }),
              (notebook.pages[index].images ?? []) != images else { return }
        do {
            let before = PageContent(page: notebook.pages[index])
            try adoptImageAssets(images)
            var candidate = notebook
            try candidate.replaceImages(images, pageID: pageID)
            if candidate.schemaVersion != notebook.schemaVersion {
                let catalogue = try NotebookPDFCatalog(candidate, reusing: sources)
                sources = catalogue; pdfOutline = catalogue.outline
            }
            notebook = candidate
            // An image drag publishes every frame; one gesture is one step.
            recordChange(.images, pageID: pageID, before: before,
                         coalescing: .init(key: "images-\(pageID.uuidString)", window: 0.8))
            scheduleSave()
        } catch { self.error = "Bildänderung konnte nicht übernommen werden. Höchstens 50 Bilder pro Seite und 500 MB Bildoriginale pro Heft. \(error.localizedDescription)" }
    }

    @discardableResult
    /// `inkGesture`: part of the current PencilKit tool use on this page
    /// (shapes removed by the precision eraser); recorded as ink with that
    /// gesture's coalescing key, so eraser ink and shapes undo together.
    func updateContent(_ content: PageContent, basedOn previous: PageContent, pageID: UUID, inkGesture: Bool = false) -> Bool {
        HangProbe.hit("Model.updateContent")
        guard writable, !mutationsPaused, !busy, let index = notebook.pages.firstIndex(where: { $0.id == pageID }),
              PageContent(page: notebook.pages[index]) == previous else {
            error = "Die Seite wurde inzwischen in einer anderen Ansicht geändert. Bitte die Auswahl erneut setzen."
            return false
        }
        do {
            try adoptImageAssets(content.images)
            var candidate = notebook; try candidate.replaceContent(content, pageID: pageID)
            if candidate.schemaVersion != notebook.schemaVersion {
                let catalogue = try NotebookPDFCatalog(candidate, reusing: sources)
                sources = catalogue; pdfOutline = catalogue.outline
            }
            notebook = candidate
            if inkGesture {
                recordChange(.ink, pageID: pageID, before: previous, coalescing: inkCoalescing(pageID))
            } else {
                recordChange(.objects, pageID: pageID, before: previous)
            }
            scheduleSave(); return true
        } catch { self.error = "Objektänderung nicht übernommen: \(error.localizedDescription)"; return false }
    }

    /// Atomic multi-page content change (selection moved to another page and
    /// its undo/redo). Every expected page state is checked; one validated
    /// candidate is installed and saved, or nothing changes.
    @discardableResult
    func replaceContents(_ changes: [PageContentReplacement]) -> Bool {
        HangProbe.hit("Model.replaceContents")
        guard writable, !mutationsPaused, !busy else { return false }
        do {
            try adoptImageAssets(changes.flatMap(\.replacement.images))
            var candidate = notebook; try candidate.replaceContents(changes)
            if candidate.schemaVersion != notebook.schemaVersion {
                let catalogue = try NotebookPDFCatalog(candidate, reusing: sources)
                sources = catalogue; pdfOutline = catalogue.outline
            }
            notebook = candidate
            // One step for both pages; undo reveals the source, redo the target.
            history.record(.transfer, changes: changes); publishHistory()
            scheduleSave(); return true
        } catch CrossPageTransferError.conflict {
            error = "Die Seiten wurden inzwischen geändert. Bitte die Auswahl erneut setzen."; return false
        } catch { self.error = "Verschieben nicht übernommen: \(error.localizedDescription)"; return false }
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
            let before = notebook
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
            recordPageOperation(before: before, undoPageID: selected)
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
        // A cut page deleted in the meantime can't be moved: paste its copy
        // instead and drop the stale cut marker rather than failing forever.
        let cutID = cutPageID.flatMap { id in notebook.pages.contains { $0.id == id } ? id : nil }
        if cutID == nil { cutPageID = nil }
        let success = editPages { document in
            if let cutID { try document.movePage(cutID, after: anchor); return cutID }
            return try document.pastePage(payload, after: anchor)
        }
        if cutID != nil, success { copiedPage = nil; cutPageID = nil }
    }
    func clearPage(_ id: UUID) { editPages(resetEditor: true) { try $0.clearPage(id); return id } }
    func movePage(_ id: UUID, to index: Int) { editPages { try $0.movePage(id, to: index); return nil } }
    func reorderPages(_ ids: [UUID]) { editPages { try $0.reorderPages(ids); return nil } }
    /// New standard pages (and the trailing draft) use this paper from now on.
    /// `.emptyPages` switches empty paper pages along; `.wholeNotebook` switches
    /// every paper page and the writing space beside PDFs, swapping neutral ink
    /// black↔white (rules in Core `PaperInkInversion`/`setPageDefaults`). One
    /// validated candidate, one save; the editor reloads every page so no
    /// stale canvas can write the old colours back. One notebook-wide undo
    /// step restores the exact previous pages, ink and default; the previous
    /// state also stays reachable through the local revision history.
    /// (Parameter label kept for the existing ContentView call site.)
    @discardableResult
    func setPageDefaults(paper: PaperStyle, color: PaperColor, convertEmptyPages scope: PageDefaultsScope) -> Bool {
        let empty: Set<UUID> = scope == .emptyPages ? Set(notebook.pages.filter { page in
            page.drawing.isEmpty || (try? PKDrawing(data: page.drawing))?.strokes.isEmpty == true
        }.map(\.id)) : []
        let drawingStep: Notebook.InkRecolor? = scope == .wholeNotebook ? inkRecolorStep : nil
        var changed = 0
        let action: (inout Notebook) throws -> UUID? = { document in
            changed = try document.setPageDefaults(paper: paper, color: color, scope: scope,
                                                   emptyPageIDs: empty, recolorDrawing: drawingStep)
            return nil
        }
        let converted = editPages(resetEditor: scope == .wholeNotebook, action)
        guard converted else { return false }
        let pages = "\(changed) Seite\(changed == 1 ? "" : "n")"
        switch scope {
        case .wholeNotebook: fileStatus = "Notizbuch auf \(color == .dark ? "Dunkel" : "Weiß") umgestellt: \(pages)"
        case .emptyPages: fileStatus = changed > 0 ? "Seitenstandard geändert, \(changed) leere Seite\(changed == 1 ? "" : "n") umgestellt" : "Seitenstandard geändert"
        case .newPagesOnly: fileStatus = "Seitenstandard geändert"
        }
        return true
    }
    /// Thin PencilKit step for paper colour flips: path, transform, mask, ink
    /// type and random seed stay; only the PKInk colour of strokes Core selects is replaced.
    var inkRecolorStep: Notebook.InkRecolor {
        { data, convert in
            let drawing = try PKDrawing(data: data)
            let light = UITraitCollection(userInterfaceStyle: .light)
            var changed = false
            let strokes = drawing.strokes.map { stroke -> PKStroke in
                var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                guard stroke.ink.color.resolvedColor(with: light).getRed(&r, green: &g, blue: &b, alpha: &a),
                      let next = convert(PageRect(stroke.renderBounds), InkColor(Double(r), Double(g), Double(b), Double(a)))
                else { return stroke }
                var result = stroke
                result.ink = PKInk(stroke.ink.inkType, color: UIColor(red: next.red, green: next.green, blue: next.blue, alpha: next.alpha))
                changed = true
                return result
            }
            return changed ? PKDrawing(strokes: strokes).dataRepresentation() : data
        }
    }
    /// Deleting the open page focuses the page before it (or after it, if it
    /// was the first page); other deletions keep the current page.
    func trashPage(_ id: UUID) {
        let open = page.id
        editPages { document in
            let old = document.pages.map(\.id)
            try document.trashPage(id)
            return open == id ? PageRemovalFocus.focus(removed: id, before: old, after: document.pages.map(\.id)) : nil
        }
    }
    func restorePage(_ id: UUID) { editPages(resetEditor: true) { try $0.restorePage(id) } }
    /// Permanent page-trash removal (also of unused PDF originals). One undo
    /// step while this notebook stays open, like every page operation.
    func deleteTrashedPage(_ id: UUID) { editPages { try $0.deleteTrashedPage(id); return nil } }
    func emptyPageTrash() { editPages { try $0.emptyPageTrash(); return nil } }
    func toggleBookmark(_ id: UUID) { editPages { try $0.toggleBookmark(id); return nil } }

    func installMarginSnapshot(_ candidate: Notebook, resetEditor: Bool = false) throws {
        guard writable, !mutationsPaused, !busy else { throw PageOperationError.missingPage }
        let selected = page.id
        let before = notebook
        let catalogue = try NotebookPDFCatalog(candidate, reusing: sources)
        let index = candidate.pages.firstIndex { $0.id == selected } ?? min(pageIndex, candidate.pages.count - 1)
        sources = catalogue
        pdfOutline = catalogue.outline
        if resetEditor { pageContentGeneration += 1 }
        notebook = candidate
        pageIndex = index
        recordPageOperation(before: before, undoPageID: selected)
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
                let previous = notebook
                let selected = page.id
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
                recordPageOperation(before: previous, undoPageID: selected)
                save()
            } catch { self.error = "PDF-Einfügen fehlgeschlagen: \(error.localizedDescription)" }
        }
    }

    /// Closing must finish its last commit before another editor can be opened.
    /// On failure the editor stays open with its unsaved in-memory snapshot.
    func flushBeforeClosing() async -> Bool {
        guard !busy else { error = "Bitte den laufenden Vorgang abwarten, dann erneut schließen."; return false }
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
                await collectAssetGarbageAfterClosing()
                return true
            }
        }
    }

    /// After the last successful commit, once the editor is no longer
    /// writable: the package's asset GC (skipped by the repository while a
    /// backup or restore runs, or if the state on disk differs). Awaited, so
    /// a notebook opened again never overlaps it. Originals on the in-app
    /// object clipboard are kept for pasting elsewhere.
    func collectAssetGarbageAfterClosing() async {
        guard !writable else { return }
        await openingCleanup?.value
        openingCleanup = nil
        _ = try? await store.collectAssetGarbage(.closing, current: notebook, keeping: ImageAssetRegistry.shared.clipboardHashes)
    }

    func waitForSave() async -> Bool {
        while true {
            let expected = revision
            await pendingSave?.value
            if expected == revision { return !saveFailed }
        }
    }

    /// Remembered per notebook so a relaunch reopens the last viewed page, also without edits.
    private func rememberPage() {
        guard writable, notebook.pages.indices.contains(pageIndex) else { return }
        UserDefaults.standard.set(page.id.uuidString, forKey: pageKeyPrefix + notebook.id.uuidString)
    }

    func save(delayed: Bool = false) {
        guard writable else { return }
        rememberPage()
        if let recoveredSnapshot {
            // Flushes (close, background, backup) keep the recovered notice and
            // the damaged newer files untouched until the user changes something.
            guard notebook != recoveredSnapshot else { return }
            self.recoveredSnapshot = nil
        }
        pendingSave?.cancel()
        retryTask?.cancel(); retryTask = nil
        revision += 1
        let snapshot = notebook
        let savingRevision = revision
        status = saveFailed ? "Neuer Speicherversuch …" : "Änderungen werden gespeichert …"
        saveFailed = false
        // Give iOS time to complete a flush when moving to the background.
        let background = delayed ? nil : BackgroundSaveTask()
        pendingSave = Task {
            defer { background?.end() }
            do {
                if delayed { try await Task.sleep(for: .milliseconds(250)) }
                try Task.checkCancellation()
                try await store.save(snapshot, revision: savingRevision)
                if savingRevision == revision { status = "Lokal gespeichert"; retryAttempt = 0; lastPermanentFailure = nil }
            } catch is CancellationError {
                // A newer complete snapshot supersedes this one.
            } catch {
                if savingRevision == revision { saveDidFail(error) }
            }
        }
    }

    /// Automatic retry while saving fails (SCOPE: retry on errors). Each attempt
    /// goes through save() and therefore commits the then CURRENT snapshot with
    /// a new revision number; the repository never lets an older one win.
    /// Errors a retry cannot fix (size limit, unknown or invalid format) wait
    /// for the user. A success, a newer save or closing cancels the retry.
    private func saveDidFail(_ failure: Error) {
        saveFailed = true
        let message = failure.localizedDescription
        guard Self.retryable(failure) else {
            status = "Speichern fehlgeschlagen – Änderungen nur im Speicher"
            // The same permanent error again (e.g. a later flush) keeps the
            // status but raises no new alert; a different error does.
            if message != lastPermanentFailure { error = message }
            lastPermanentFailure = message
            return
        }
        let delay = Self.retryDelays[min(retryAttempt, Self.retryDelays.count - 1)]
        // One alert per failure series; later attempts only update the status.
        if retryAttempt == 0 { error = message + " Noty versucht es automatisch erneut." }
        retryAttempt += 1
        status = "Speichern fehlgeschlagen – Änderungen nur im Speicher · neuer Versuch in \(delay) s"
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, self.saveFailed, self.writable else { return }
            self.save()
        }
    }
    private static let retryDelays = [2, 5, 15, 60]
    private static func retryable(_ error: Error) -> Bool {
        if error is StorageError { return false }
        guard let error = error as? RevisionError else { return true }
        switch error {
        case .snapshotTooLarge, .unsupportedFormat: return false
        default: return true
        }
    }

    /// A verified `.noty` file (`.notybackup` format 2, unchanged content) in
    /// the app's temporary backup directory (never inside a notebook package);
    /// the caller removes it after the export dialog (`BackupScratch.remove`)
    /// or the share sheet (`BackupScratch.removeShare`). `sharing`: named
    /// `<Titel>.noty` in its own scratch folder. The archive is written and
    /// re-read on the repository actor, never held in memory as a whole.
    func backupFile(sharing: Bool = false) async -> URL? {
        guard writable, !mutationsPaused, !busy else { return nil }
        busy = true
        let snapshot = notebook
        // Sharing is no backup confirmation: the backup status stays as it is.
        if !sharing { backupStatus = "Backup wird vorbereitet …" }
        defer { busy = false }
        do {
            let url = try sharing ? BackupScratch.newShareFile(title: snapshot.title) : BackupScratch.newFile(NotyFile.fileExtension)
            let discard = { sharing ? BackupScratch.removeShare(url) : BackupScratch.remove(url) }
            do { try await store.backup(snapshot, to: url) } catch { discard(); throw error }
            if !sharing { backupStatus = "Backup geprüft · Speicherort wählen" }
            return url
        } catch {
            if !sharing { backupStatus = "Backup konnte nicht erstellt werden" }
            self.error = error.localizedDescription
            return nil
        }
    }

    func backupExported() {
        let date = Date()
        UserDefaults.standard.set(date, forKey: backupDateKey)
        backupStatus = "Backup-Datei exportiert: \(date.formatted(date: .omitted, time: .shortened))"
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
        try validate(prepared.document, assets: prepared.assets)
        var restored = try await store.commitRestoreCopy(prepared, libraryRoot: libraryRoot)
        restored.preferredPageID = page.id
        backupStatus = message
        openedRestore = restored
    }
}

/// iOS background time for one save. Ended exactly once: when the save
/// finishes, or by the system's expiration handler if time runs out first
/// (the commit itself is not cancelled; it continues when the app runs again).
@MainActor
private final class BackgroundSaveTask {
    private var identifier = UIBackgroundTaskIdentifier.invalid
    init() {
        identifier = UIApplication.shared.beginBackgroundTask(withName: "noty-save") { [weak self] in self?.end() }
    }
    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}

@MainActor
enum EditorModelValidation {
    static func validate(_ document: Notebook, assets: ImageAssetProviding? = nil) throws {
        _ = try NotebookPDFCatalog(document)
        try validateContent(document, assets: assets)
    }
    /// PencilKit drawings and images of active and trashed pages. No UI or
    /// PDFKit objects: safe off the UI actor (the PDF part is the catalogue).
    /// Image originals come from `assets` (nil: the registry); each original
    /// (content address and pixel size) is decoded and verified once, also
    /// when duplicated pages share it.
    /// Opening: every PencilKit drawing, but image originals only by
    /// presence (pending bytes, or a file of the right size: `stat`). Their
    /// SHA-256 and ImageIO check follow when an image is first drawn
    /// (`ImageRendering.prepare`; a mismatch shows the existing "damaged"
    /// path), and in backup, restore and PDF export. Opening a notebook with
    /// 500 MB of originals therefore reads none of them.
    nonisolated static func validateOnOpening(_ document: Notebook, assets: NotebookAssets) throws {
        for page in document.pages + (document.deletedPages ?? []).map(\.page) where !page.drawing.isEmpty {
            _ = try PKDrawing(data: page.drawing)
        }
        for reference in document.externalImageAssets where !assets.isAvailable(reference) {
            throw ImageAssetError.missing(reference.sha256)
        }
    }

    nonisolated static func validateContent(_ document: Notebook, assets: ImageAssetProviding? = nil) throws {
        for page in document.pages + (document.deletedPages ?? []).map(\.page) where !page.drawing.isEmpty {
            _ = try PKDrawing(data: page.drawing)
        }
        let images = document.allImages
        guard !images.isEmpty else { return }
        let provider: ImageAssetProviding = assets ?? ImageAssetRegistry.shared
        var checked = Set<String>()
        for image in images where checked.insert("\(image.asset.sha256)-\(image.pixelWidth)x\(image.pixelHeight)").inserted {
            try ImageRendering.validate(image, assets: provider)
        }
    }
}

extension UTType {
    /// `.noty`: shared/exported notebook (content = `.notybackup` format 2).
    static let noty = UTType(exportedAs: "de.la.noty.document", conformingTo: .data)
    /// Former extension of the same format; stays importable.
    static let notyBackup = UTType(exportedAs: "de.la.noty.backup", conformingTo: .data)
    static let notyLibrary = UTType(exportedAs: "de.la.noty.library", conformingTo: .data)
}

/// Editor exports: a PDF in memory or a verified backup file. A backup is
/// handed to the system from its file (like `LibraryArchiveFile`), never
/// loaded into memory as a whole. Export only; reading goes through the
/// staged restore paths.
struct ExportFile: FileDocument {
    static var readableContentTypes: [UTType] { [.noty, .notyBackup, .notyLibrary, .json, .pdf] }
    private enum Content { case data(Data), file(URL) }
    private let content: Content
    init(pdfData: Data) { content = .data(pdfData) }
    init(backupFile url: URL) { content = .file(url) }
    init(configuration: ReadConfiguration) throws { throw CocoaError(.featureUnsupported) }
    /// The scratch file behind a backup export.
    var fileURL: URL? { if case .file(let url) = content { url } else { nil } }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        switch content {
        case .data(let data): FileWrapper(regularFileWithContents: data)
        case .file(let url): try FileWrapper(url: url, options: [])
        }
    }
}
