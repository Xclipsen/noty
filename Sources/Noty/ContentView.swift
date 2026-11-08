import SwiftUI
import UniformTypeIdentifiers
import PhotosUI
import _PhotosUI_SwiftUI
import PencilKit
import NotebookCore

struct ContentView: View {
    @ObservedObject var model: EditorModel
    var isRestoredCopy = false
    var isLibraryDocument = false
    var initialSearchBounds: PageRect? = nil
    /// A search hit over a page change: marked in the flow once the document stands.
    var initialFlowRange: NSRange? = nil
    var isPaneActive: () -> Bool = { true }
    /// Without the short lock while saving: only another pane being in front covers this one.
    var isPaneSelected: () -> Bool = { true }
    var onActivatePane: (() -> Void)?
    var onCloseWorkspace: (() -> Void)?
    var onSecondView: (() -> Void)?
    /// Switches the law window: closed → open, parked → brought out, visible → closed.
    var onLaws: (() -> Void)?
    /// Current state of the law window, read when the palette lists its commands.
    var lawsPhase: (() -> LawPanelState.Phase)?
    /// `Space l`: shows the law window and hands it the keys.
    var onLawKeys: (() -> Void)?
    /// Reports the selected tool, e.g. so Pencil highlights in the law reader.
    var onToolChange: ((EditorTool) -> Void)?
    /// Embedded beside a calendar event (Kalender B2): no own navigation
    /// stack, the app's bars stay, the page overview starts closed and does
    /// not change the app-wide setting.
    var embedded = false
    /// Replaces „Zur Bibliothek“ + title of the header button, e.g. the way
    /// back to a calendar event or „Vergrößern“ beside it.
    var closeTitle: String? = nil
    var closeSymbol = "arrow.left"
    @State private var selectedPageID: UUID?
    /// Pages of this view and the chrome above them in its surface
    /// (activation layer of an inactive view).
    @State private var paneWakeArea = PaneWakeArea.Area()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var toolbox: ToolbarSettingsModel
    /// Law window focus: ⌘G then means its next hit (docs/KEYBOARD.md).
    @ObservedObject private var lawKeys = LawKeyboard.shared
    @Environment(\.editorSettings) private var editorSettings
    @Environment(\.searchIndexArea) private var searchIndexArea
    @State private var showingSettings = false
    @State private var editingDefaults = false
    @State private var addingPage = false
    @State private var exporting = false
    @State private var exportFile: ExportFile?
    @State private var exportType: UTType = .json
    @StateObject private var pdfExport = PDFExportJob()
    @State private var currentTool: EditorTool = .pen
    /// Every tool change (bar, options, keys, Pencil palette) first settles a
    /// held stroke (`settleHeldStrokes`): its recognised shape reaches the
    /// model, as before undo or a Pencil double tap, instead of being dropped
    /// for the freehand stroke. Only from actions, never inside a view update.
    private var tool: EditorTool {
        get { currentTool }
        nonmutating set {
            if newValue != currentTool { WorksheetView.settleHeldStrokes() }
            currentTool = newValue
        }
    }
    private var toolBinding: Binding<EditorTool> { Binding(get: { currentTool }, set: { tool = $0 }) }
    @State private var lastInkTool: EditorTool = .pen
    /// The tool before the text tool: leaving a field returns there unless the text tool is fixed.
    @State private var toolBeforeText: EditorTool?
    /// The tool before the eraser: Pencil double tap/squeeze returns there (any tool).
    @State private var toolBeforeEraser: EditorTool?
    /// The tool used before the current one (system setting „Vorheriges Werkzeug“).
    @State private var previousTool: EditorTool?
    @AppStorage(AppSettingsKey.textToolLocked) private var textToolLocked = false
    @State private var pencilPalette: PencilPalettePresentation?
    @State private var pencilSqueeze = PencilSqueezeTracker()
    /// Undo/redo changed another page: select it, scrolling only if it is not visible.
    @State private var revealRequest: PageRevealRequest?
    @State private var textInsertRequest = 0
    @State private var textFocus: TextFlowFocus?
    @State private var writingDraft = Page()
    @State private var fitRequest = 0
    @State private var sidebarKeys: SidebarKeyRequest?
    @State private var paneID = UUID()
    @State private var showingHistory = false
    @State private var selectedLocalRevision: UUID?
    @AppStorage(AppSettingsKey.sidebarVisible) private var showingPages = true
    @State private var embeddedPages = false
    /// The page overview: app-wide setting, or local while embedded.
    private var pagesShown: Bool {
        get { embedded ? embeddedPages : showingPages }
        nonmutating set { if embedded { embeddedPages = newValue } else { showingPages = newValue } }
    }
    @AppStorage(AppSettingsKey.writingScroll) private var writingScroll = false
    @State private var customizingTools = false
    @State private var toolbarMore = false
    @State private var toolbarOptions = false
    @State private var optionsWidths: [EditorTool: Double] = [:]
    @State private var marginsPage: MarginPage?
    @State private var importingImage = false
    @State private var choosingPhoto = false
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var imageTarget: UUID?
    @State private var contentSearch = false
    /// The editor's first appearance only: closing a cover above it (a restored
    /// copy) appears it again, which must not reset the page or search jump.
    @State private var appeared = false
    @State private var searchHighlight: PageRect?
    @State private var searchHighlightPageID: UUID?
    @State private var searchHighlightToken = 0
    @State private var pageEntry = false
    @State private var pageEntryText = ""
    @State private var recentNote: String?
    @State private var recentNoteToken = 0
    /// VoiceOver heard the current save failure series already.
    @State private var saveFailureAnnounced = false
    private var ruler: Bool {
        get { toolbox.preferences.ruler ?? false }
        nonmutating set { toolbox.preferences.ruler = newValue }
    }
    private var shapeOptions: ShapeToolOptions {
        get { ShapeToolOptions(preferences: toolbox.preferences) }
        nonmutating set { newValue.store(in: &toolbox.preferences) }
    }
    /// Lasso filter and freeform/rectangle stay as last chosen (app-wide,
    /// UserDefaults like the other editor settings; `toolbar.json` unchanged).
    @AppStorage(AppSettingsKey.lassoFilter) private var lassoFilterBits = SelectionFilter().bits
    @AppStorage(AppSettingsKey.lassoMode) private var lassoModeRaw = LassoMode.freeform.rawValue
    private var selectionFilter: SelectionFilter {
        get { SelectionFilter(bits: lassoFilterBits) }
        nonmutating set { lassoFilterBits = newValue.bits }
    }
    private var lassoMode: LassoMode {
        get { LassoMode(rawValue: lassoModeRaw) ?? .freeform }
        nonmutating set { lassoModeRaw = newValue.rawValue }
    }
    private var recognizeShapes: Bool {
        get { toolbox.preferences.recognizeShapes ?? true }
        nonmutating set { toolbox.preferences.recognizeShapes = newValue }
    }
    private struct MarginPage: Identifiable { let id: UUID }
    private var draftPage: Page {
        var page = model.notebook.writingDraft(id: writingDraft.id)
        page.textBoxes = writingDraft.textBoxes; page.drawing = writingDraft.drawing
        return page
    }
    private var editorPages: [Page] {
        model.notebook.pages + (model.notebook.pages.count < 500 && !model.notebook.pages.contains(where: { $0.id == writingDraft.id }) ? [draftPage] : [])
    }
    private var currentPage: Page {
        if selectedPageID == writingDraft.id, !model.notebook.pages.contains(where: { $0.id == writingDraft.id }) { return draftPage }
        return model.notebook.pages[currentPageIndex]
    }
    /// Insert/anchor target: the trailing unsaved draft maps to the last real page.
    private var anchorPageID: UUID {
        currentPage.id == writingDraft.id ? (model.notebook.pages.last?.id ?? currentPage.id) : currentPage.id
    }
    /// Before the stored document is installed the model holds a placeholder,
    /// which must never be shown or get a native sheet. The latch lives in the
    /// model: this view's state may outlive a model (second pane replaced).
    private var notebookLoaded: Bool { model.documentLoaded }
    private var currentPageIndex: Int {
        get { model.notebook.pages.firstIndex { $0.id == selectedPageID } ?? min(model.pageIndex, model.notebook.pages.count - 1) }
        nonmutating set {
            let index = min(max(0, newValue), model.notebook.pages.count - 1)
            selectedPageID = model.notebook.pages[index].id
            if isPaneActive() { model.pageIndex = index }
        }
    }

    var body: some View {
        Group {
            if embedded {
                // Inside the calendar: its own navigation bar and status bar stay.
                editorBody
            } else {
                NavigationStack {
                    editorBody
                        .toolbar(.hidden, for: .navigationBar)
                        // Full-screen writing surface: no iPadOS status bar, home indicator auto-hides.
                        .statusBarHidden(true)
                        .persistentSystemOverlays(.hidden)
                }
            }
        }
        .preference(key: EditorCommandsPreference.self, value: editorCommands)
        // Shortcuts of the law window: model, key responder, Esc in its fields.
        .background { if !isRestoredCopy { LawKeyAnchor(active: isPaneActive()) } }
    }

    @ViewBuilder private var editorBody: some View {
        workspaceSurface.onPreferenceChange(PaneWakeArea.self) { paneWakeArea = $0 }
            .ignoresSafeArea(.keyboard, edges: .bottom).overlay {
            // Only an inactive view gets this layer; the active one keeps
            // nothing above its toolbar and pages (Build 111 regression).
            if !isPaneSelected() {
                // With an ink tool the pages stay open below: the first Pencil
                // stroke draws and activates this view, a finger tap there
                // activates it through the viewport (DEVICE-FEEDBACK-20 §4).
                // Bar, options, page buttons and sidebar above them stay
                // covered: a tap there activates instead of hitting locked chrome.
                let hole = pencilWakes ? paneWakeArea.pages : nil, shields = paneWakeArea.shields
                GeometryReader { proxy in
                    // The layer's own origin in the surface space (safe area, window mode).
                    Color.clear.contentShape(PaneWakeArea.Hole(hole: hole, shields: shields,
                                                               origin: proxy.frame(in: .named(PaneWakeArea.space)).origin))
                        .onTapGesture { activatePane() }
                        .accessibilityLabel("Diese Ansicht aktivieren").accessibilityAddTraits(.isButton)
                }
            }
        }
        // Around surface and layer, so both measure in the same space.
        .coordinateSpace(name: PaneWakeArea.space)
        .sheet(isPresented: $addingPage) {
            AddPageSheet(position: .after, enabled: canEdit, defaults: model.notebook.appearance,
                onPaper: { style, color, geometry, position in
                    let anchor = position == .end ? model.notebook.pages.last!.id : anchorPageID
                    model.insertPaper(style, color: color, relativeTo: anchor, before: position == .before, geometry: geometry)
                    addingPage = false
                }, onPDF: { url, margins, position in
                    let anchor = position == .end ? model.notebook.pages.last!.id : anchorPageID
                    model.insertPDF(url, relativeTo: anchor, before: position == .before, writingArea: margins)
                    addingPage = false
                }, onError: { model.error = $0 })
        }
        .fileImporter(isPresented: $importingImage, allowedContentTypes: [.image]) { result in
            switch result {
            case .success(let url): if let imageTarget { if imageTarget == writingDraft.id { guard model.materializeDraft(draftPage) else { return } }; model.insertImageFile(url, pageID: imageTarget) }
            case .failure(let error): model.error = error.localizedDescription
            }
        }
        .photosPicker(isPresented: $choosingPhoto, selection: $selectedPhoto, matching: .images, preferredItemEncoding: .current)
        .onChange(of: selectedPhoto) { _, item in
            guard let item, let target = imageTarget else { return }
            // Always clear, otherwise the same photo can't be picked again after a failure.
            defer { selectedPhoto = nil }
            if target == writingDraft.id { guard model.materializeDraft(draftPage) else { return } }
            model.insertPhoto(item, pageID: target)
        }
        .fileExporter(isPresented: $exporting, document: exportFile,
                      contentType: exportType, defaultFilename: exportType == .pdf ? PDFExporter.fileName(for: model.notebook.title)
                        : NotyFile.fileStem(for: model.notebook.title)) { result in
            // The system wrote its copy: the scratch archive is no longer needed.
            if let scratch = exportFile?.fileURL { BackupScratch.remove(scratch) }
            switch result {
            case .success:
                if exportType == .pdf { model.fileStatus = "Als PDF exportiert" }
                else { model.backupExported() }
            case .failure(let error):
                if exportType == .noty { model.backupStatus = "In Dateien sichern nicht abgeschlossen" }
                model.error = error.localizedDescription
            }
        }
        .fullScreenCover(item: $model.openedRestore) { restored in
            RestoredNotebookView(restored: restored).id(restored.id)
        }
        .sheet(isPresented: $contentSearch) {
            ContentSearchView(documents: [OpenNotebook(id: model.notebook.id, directory: model.storageRoot, title: model.notebook.title, isRestored: false)],
                              current: model.notebook, currentSources: { model.sourcePage(for: $0) },
                              area: searchIndexArea ?? StableDefaults.scope(model.storageRoot)) { hit in
                selectedPageID = hit.pageID; searchHighlight = hit.bounds; searchHighlightPageID = hit.pageID; fitRequest += 1
                fadeSearchHighlightLater()
                if let range = hit.flowRange { selectFlowLater(range) }
            }
        }
        .sheet(isPresented: $customizingTools) { ToolbarCustomizationView(settings: toolbox) }
        .fullScreenCover(isPresented: $showingSettings) { editorSettings?.make() }
        .sheet(isPresented: $editingDefaults) {
            if isTextDocument {
                TextDocumentPaperView(current: model.notebook.pageDefaults) { paper, color in
                    if model.setDocumentPaper(paper: paper, color: color, trailingDraft: draftPage) { toolsFollowPaper(color) }
                }
            } else {
                NotebookDefaultsView(current: model.notebook.pageDefaults) { paper, color, scope in
                    guard model.setPageDefaults(paper: paper, color: color, convertEmptyPages: scope),
                          scope == .wholeNotebook else { return }
                    toolsFollowPaper(color)
                }
            }
        }
        .sheet(item: $marginsPage) { selection in PageMarginsView(model: model, pageID: selection.id) }
        .sheet(isPresented: $showingHistory, onDismiss: {
            if let id = selectedLocalRevision {
                selectedLocalRevision = nil
                model.openLocalRevisionAsCopy(id)
            }
        }) {
            LocalHistoryView(model: model) { id in
                selectedLocalRevision = id
                showingHistory = false
            }
        }
        .alert(isTextDocument ? "Textdokument" : "Heft", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            if model.saveFailed && model.writable {
                Button("Erneut speichern") { model.save() }
            }
            Button("OK") { model.error = nil }.keyboardShortcut(.defaultAction)
        } message: { Text(model.error ?? "") }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { WorksheetView.settleHeldStrokes(); model.save(); toolbox.save() }
        }
        .onChange(of: toolbox.preferences) { _, _ in toolbox.save() }
        .onChange(of: model.fileStatus) { _, note in showRecentNote(note) }
        // Once per failure series and only in the active pane: automatic retries
        // and later saves flip `saveFailed` again; a successful save ends the series.
        .onChange(of: model.saveFailed) { _, failed in
            guard failed, !saveFailureAnnounced, isPaneActive() else { return }
            saveFailureAnnounced = true
            AccessibilityNotification.Announcement("Speichern fehlgeschlagen").post()
        }
        .onChange(of: model.status) { _, status in
            if status == "Lokal gespeichert" { saveFailureAnnounced = false }
        }
        .onChange(of: model.backupStatus) { _, note in showRecentNote(note) }
        .onChange(of: model.pageIndex) { _, index in
            if isPaneActive(), model.notebook.pages.indices.contains(index) { selectedPageID = model.notebook.pages[index].id }
        }
        .onChange(of: model.notebook.pages.map(\.id)) { old, ids in
            if ids.contains(writingDraft.id) { writingDraft = Page() }
            if let selectedPageID, let index = ids.firstIndex(of: selectedPageID) {
                if isPaneActive() { model.pageIndex = index }
            }
            // The selected page was deleted (here or in the other pane): focus the
            // page before it, or the one after it if it was the first page. The
            // viewport jumps there because the selection was not reported by it.
            else if let selectedPageID, selectedPageID != writingDraft.id, !ids.isEmpty {
                self.selectedPageID = PageRemovalFocus.focus(removed: selectedPageID, before: old, after: ids)
                    ?? ids[min(max(0, model.pageIndex), ids.count - 1)]
            }
        }
        .onChange(of: selectedPageID) { _, _ in if isPaneActive() { model.pageIndex = currentPageIndex } }
        .onChange(of: model.pageContentGeneration) { _, _ in textFocus = nil; writingDraft = Page() }
        .onChange(of: model.mutationsPaused || model.busy) { _, blocked in if !blocked { adoptHeldDraftDrawing() } }
        .onChange(of: tool) { old, value in
            if value != .text { textFocus = nil }; if value.isInk { lastInkTool = value }
            if value == .text, old != .text { toolBeforeText = old }
            // Every way into the eraser (bar, palette, Pencil) counts, not only the toggle.
            if value.isEraser, !old.isEraser { toolBeforeEraser = old }
            previousTool = old
        }
        .onChange(of: tool, initial: true) { _, value in onToolChange?(value) }
        .onChange(of: model.notebook.id) { _, _ in selectedPageID = model.page.id; searchHighlightPageID = model.page.id }
        .onAppear {
            guard !appeared else { return }
            appeared = true
            selectedPageID = model.page.id; searchHighlight = initialSearchBounds; searchHighlightPageID = model.page.id
            EditorOpenTrace.begin()
            if model.documentLoaded { markNotebookShown() }
        }
        .onChange(of: model.documentLoaded) { _, loaded in if loaded { markNotebookShown() } }
        .onChange(of: canEdit) { _, editable in if !editable { pageEntry = false } }
        // Managed editors flush before dismissal; no late onDisappear save
        // may race a new editor for the same package.
        .interactiveDismissDisabled(isLibraryDocument || isRestoredCopy)
    }

    /// The whole document now has this paper colour: a neutral pen, marker or
    /// pencil of the old contrast colour would write invisibly (white on
    /// white). Same direction-aware rule as the ink (`followPaper`).
    private func toolsFollowPaper(_ color: PaperColor) { toolbox.preferences.followPaper(color) }

    /// Ink the draft page held while it could not become a page (see `onDrawing`).
    private func adoptHeldDraftDrawing() {
        let data = writingDraft.drawing
        guard !data.isEmpty, model.writable, !model.notebook.pages.contains(where: { $0.id == writingDraft.id }) else { return }
        var draft = draftPage; draft.drawing = Data()
        guard model.materializeDraft(draft) else { return }
        model.updateDrawing(data, pageID: draft.id)
    }

    /// App menu / ⌘ shortcuts of this pane while it is the active one.
    private var editorCommands: EditorCommandActions? {
        guard isPaneActive(), notebookLoaded else { return nil }
        let onDraft = currentPage.id == writingDraft.id
        // A second presentation over an open sheet would never appear.
        let presenting = contentSearch || showingSettings || editingDefaults || addingPage || customizingTools || showingHistory || model.openedRestore != nil
            || marginsPage != nil || exporting || importingImage || choosingPhoto || pageEntry || model.error != nil
        return EditorCommandActions(owner: ObjectIdentifier(model), pane: paneID, canEdit: canEdit && !presenting,
            canExportPage: model.writable && !onDraft, exporting: pdfExport.running,
            hasPrevious: onDraft || currentPageIndex > 0, hasNext: !onDraft && currentPageIndex < model.notebook.pages.count - 1, isTextDocument: isTextDocument,
            search: { if canEdit { contentSearch = true } }, save: { model.save() },
            exportNotebook: { startPDFExport(pageOnly: false) }, exportPage: { startPDFExport(pageOnly: true) },
            previousPage: { stepPage(-1) }, nextPage: { stepPage(1) }, close: { closeEditor() },
            keys: EditorKeyActions(run: { runKey($0, count: $1) }, commands: { keyCommands }, direct: { runDirect($0) }))
    }

    // MARK: Keyboard mode (docs/KEYBOARD.md)
    /// `count` is nil unless typed: on `gg`, `ge` and `G` it names a page.
    private func runKey(_ action: HelixAction, count: Int?) {
        guard canEdit else { return }
        let pages = model.notebook.pages
        func go(to number: Int) { selectedPageID = pages[min(max(1, number), pages.count) - 1].id }
        switch action {
        case .tool(let value): tool = value; toolbarOptions = false
        case .page(let delta): for _ in 0..<(count ?? 1) { stepPage(delta) }
        case .firstPage: go(to: count ?? 1)
        case .lastPage: go(to: count ?? pages.count)
        case .gotoPage: if let count { go(to: count) } else { openPageEntry() }
        case .fit: fitRequest += 1
        case .sidebar: NotyMotion.instant { pagesShown = true }; sidebarKeys = SidebarKeyRequest(target: .pages)
        case .outline: NotyMotion.instant { pagesShown = true }; sidebarKeys = SidebarKeyRequest(target: .outline)
        case .bookmarks: NotyMotion.instant { pagesShown = true }; sidebarKeys = SidebarKeyRequest(target: .bookmarks)
        case .laws:
            if let onLawKeys { onLawKeys() } else { KeyboardRouter.shared.show(note: "Gesetzessammlung ist ausgeschaltet") }
        case .colors: openKeyColors()
        case .close: closeEditor()
        case .bookmark: if pages.contains(where: { $0.id == currentPage.id }) { model.toggleBookmark(currentPage.id) }
        case .search: contentSearch = true
        case .searchAll:
            // The other documents can only open from the library.
            if isLibraryDocument { KeyboardRouter.shared.searchAllAfterClosing = true; closeEditor() } else { contentSearch = true }
        case .export(.pdf): startPDFExport(pageOnly: false)
        case .export(.pagePDF): startPDFExport(pageOnly: true)
        case .export(.markdown): shareText(.markdown)
        case .export(.plainText): shareText(.plainText)
        case .export(.noty): shareNoty()
        case .export(.word): shareText(.word)
        case .export(.rtf): shareText(.rtf)
        case .undo: performUndo(redo: false)
        case .redo: performUndo(redo: true)
        default: break
        }
    }
    /// `Space c`: in a text its colours and marker, otherwise what the tool has.
    private func openKeyColors() {
        let router = KeyboardRouter.shared
        if router.editing {
            let rows = (UIResponder.currentFirstResponder as? any KeyboardTextTarget)?.keyboardColorRows() ?? []
            if rows.isEmpty { router.show(note: "Hier gibt es keine Textfarben") } else { router.openChoices("Text", rows: rows) }
            return
        }
        let current = tool
        var rows: [KeyChoiceRow] = []
        if [.pen, .pencil, .marker, .shape].contains(current) {
            let inks = ShapeFillStyleSection.palette.map { ink, name in
                KeyChoiceItem(title: name, color: ink.color) { toolbox.preferences.setInkColor(ink, for: current) }
            }
            rows += KeyChoiceRow.rows("Farbe", inks, width: 6)
        }
        if current == .laser {
            let colors = LaserPointerView.colors.map { item in KeyChoiceItem(title: item.name, color: item.color.color) { toolbox.preferences.laserColor = item.color } }
            rows.append(KeyChoiceRow(title: "Farbe", items: colors))
        }
        if let range = ToolbarPreferences.widthRange(for: current) {
            let stops = KeyChoice.widths(in: range).map { width in KeyChoiceItem(title: width.formatted()) { toolbox.preferences.setInkWidth(width, for: current) } }
            rows.append(KeyChoiceRow(title: "Strichstärke", items: stops))
        } else if current == .precisionEraser {
            let stops = KeyChoice.widths(in: 4...60).map { width in KeyChoiceItem(title: width.formatted()) { toolbox.preferences.eraserWidth = width } }
            rows.append(KeyChoiceRow(title: "Radiererbreite", items: stops))
        }
        if current == .shape {
            let patterns = StrokePattern.allCases.map { pattern in KeyChoiceItem(title: pattern.title) { shapeOptions.pattern = pattern } }
            rows.append(KeyChoiceRow(title: "Linienart", items: patterns))
        }
        if rows.isEmpty { router.show(note: "Dieses Werkzeug hat keine Farbe") } else { router.openChoices(current.title, rows: rows) }
    }
    private func runDirect(_ command: KeyPalette.Direct) {
        switch command {
        case .save: model.save()
        case .close: closeEditor()
        case .page(let number): runKey(.gotoPage, count: number)
        }
    }
    /// What only the menus offer; the palette adds every key binding by name.
    private var keyCommands: [PaletteCommand] {
        var items = [PaletteCommand(title: "Vollständiges Backup") { exportBackup() },
                     PaletteCommand(title: "Lokale Wiederherstellungspunkte") { showingHistory = true },
                     PaletteCommand(title: "Speichern", keys: ":w") { model.save() },
                     PaletteCommand(title: "Blättern statt Scrollen umschalten") { toolbox.preferences.paging = !(toolbox.preferences.paging ?? false) },
                     PaletteCommand(title: "Schreibmaschinen-Modus umschalten") { TextObjectLayer.typewriterEnabled.toggle() },
                     PaletteCommand(title: "Lineal umschalten") { ruler.toggle() },
                     PaletteCommand(title: "Textwerkzeug fixieren umschalten") { textToolLocked.toggle() },
                     PaletteCommand(title: "Werkzeugleiste anpassen") { customizingTools = true }]
        if KeyboardRouter.shared.isEnabled {
            items.append(PaletteCommand(title: "Helix-Tastatur ausschalten") { KeyboardRouter.shared.switchOff() })
        }
        if isTextDocument {
            items.append(PaletteCommand(title: "Papier ändern") { editingDefaults = true })
        } else {
            let page = currentPage
            items += [PaletteCommand(title: "Seite hinzufügen") { let defaults = model.notebook.pageDefaults; model.insertPaper(defaults.paper, color: defaults.color, relativeTo: anchorPageID) },
                      PaletteCommand(title: "Seite duplizieren") { model.duplicatePage(page.id) },
                      PaletteCommand(title: "Seite leeren") { model.clearPage(page.id) },
                      PaletteCommand(title: "Seite in den Papierkorb") { model.trashPage(page.id) },
                      PaletteCommand(title: "Seite anpassen") { marginsPage = MarginPage(id: page.id) },
                      PaletteCommand(title: "Papier für neue Seiten") { editingDefaults = true }]
        }
        if let onLaws { items.append(PaletteCommand(title: lawPanelPaletteTitle(lawsPhase?() ?? .closed), run: onLaws)) }
        if editorSettings != nil { items.append(PaletteCommand(title: "Einstellungen") { showingSettings = true }) }
        return items
    }
    private var flowActions: TextFlowActions? {
        guard model.notebook.isTextDocument else { return nil }
        func show(_ focus: TextFlowFocus?) {
            guard var focus else { return }
            focus.requestID = UUID(); textFocus = focus; selectedPageID = focus.pageID
        }
        return TextFlowActions(content: { model.notebook.textFlowContent },
            offset: { model.notebook.textFlowOffset(boxID: $0, location: $1) },
            parts: { model.notebook.textFlowParts(of: $0) },
            paragraph: { model.notebook.textFlowParagraph(of: $0) },
            edit: { edits, caret in show(model.editFlow(edits, caret: caret, trailingDraft: draftPage)) },
            restyle: { range, change in
                guard model.restyleFlow(range: range, trailingDraft: draftPage, change: change) != nil else { return }
                // Sizes may have moved text over pages: the same range, new parts.
                if TextFlowSelection.shared.range != nil { TextFlowSelection.shared.set(range, parts: model.notebook.textFlowParts(of: range)) }
            },
            moveCaret: { range in
                guard let place = model.notebook.textFlowPlace(at: range.location), let content = model.notebook.textFlowContent else {
                    KeyboardRouter.shared.handoff = false
                    return
                }
                let length = (content.text as NSString).length
                show(TextFlowFocus(pageID: place.pageID, boxID: place.boxID, selection: NSRange(location: place.location, length: range.length),
                                   typingStyle: length == 0 ? content.style : content.style(at: min(range.location, length - 1))))
            },
            segments: {
                let pages = Dictionary(model.notebook.pages.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                return model.notebook.textFlowSegments.compactMap { segment in pages[segment.pageID].map { ($0, segment.box) } }
            },
            change: { change, capacity in model.changeFlow(change, capacity: capacity, trailingDraft: draftPage) },
            settle: { id, selection in
                // Undone meanwhile: a new step would take away the redo.
                guard !model.canRedo, let focus = model.settleFlow(boxID: id, selection: selection, trailingDraft: draftPage),
                      selection != nil else { return }
                // As typing into the next page, the other way round.
                if focus.pageID != currentPage.id { KeyboardRouter.shared.handoff = true }
                show(focus)
            })
    }

    /// After the search sheet: its field holds the focus until it is gone.
    private func selectFlowLater(_ range: NSRange) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { selectFlow(range) }
    }
    /// A search hit over a page change: marked on both pages (`TextFlowSelection`,
    /// the surface of text editor 2 takes the whole range), the caret at its start.
    private func selectFlow(_ range: NSRange) {
        guard canEdit, let content = model.notebook.textFlowContent, NSMaxRange(range) <= (content.text as NSString).length,
              let place = model.notebook.textFlowPlace(at: range.location) else { return }
        if tool != .text { tool = .text; toolbarOptions = false }
        let router = KeyboardRouter.shared
        router.handoff = true
        TextFlowSelection.shared.set(range, parts: model.notebook.textFlowParts(of: range))
        if let page = model.notebook.pages.first(where: { $0.id == place.pageID }),
           let box = page.effectiveTextBoxes.first(where: { $0.id == place.boxID }), let part = model.notebook.textFlowParts(of: range)[box.id] {
            searchHighlight = box.markerBounds(part, on: page); searchHighlightPageID = page.id
            fadeSearchHighlightLater()
        }
        var focus = TextFlowFocus(pageID: place.pageID, boxID: place.boxID, selection: NSRange(location: place.location, length: range.length),
                                  typingStyle: content.style(at: range.location))
        focus.requestID = UUID(); textFocus = focus; selectedPageID = focus.pageID
    }

    private func markNotebookShown() {
        // Logged once per open (EditorOpenTrace de-duplicates events).
        EditorOpenTrace.mark("model loaded", "pages=\(model.notebook.pages.count)")
        fadeSearchHighlightLater()
        if let initialFlowRange { selectFlowLater(initialFlowRange) }
    }

    /// Gliederung of a text document: the heading's page comes into view,
    /// the heading is marked briefly like a jump to an open task, and the
    /// caret goes behind it (text tool, `TextFlowFocus`). Read-only: only
    /// page and marker.
    private func jumpToOutline(_ entry: TextOutlineEntry) {
        guard let page = model.notebook.pages.first(where: { $0.id == entry.pageID }),
              let box = page.effectiveTextBoxes.first(where: { $0.id == entry.boxID }) else { return }
        searchHighlight = entry.markerBounds(box: box, page: page); searchHighlightPageID = page.id
        fadeSearchHighlightLater()
        selectedPageID = page.id
        guard canEdit else { return }
        if tool != .text { tool = .text; toolbarOptions = false }
        var focus = entry.focus; focus.requestID = UUID(); textFocus = focus
    }

    /// The jump marker of a search hit/open task stays 3 s (plus the closing
    /// sheet animation), then fades; a newer jump restarts the time.
    private func fadeSearchHighlightLater() {
        guard searchHighlight != nil else { return }
        searchHighlightToken += 1
        let token = searchHighlightToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.4) {
            if searchHighlightToken == token { searchHighlight = nil }
        }
    }

    private func closeEditor() {
        WorksheetView.settleHeldStrokes() // a held stroke right before closing is saved
        if let onCloseWorkspace { onCloseWorkspace(); return }
        Task {
            if await model.flushBeforeClosing() { _ = await toolbox.flush(); dismiss(); return }
            if let reason = model.saveBlocked, await TopAlert.ask(EditorWorkspace.blockedTitle, EditorWorkspace.blockedMessage(reason), confirm: EditorWorkspace.blockedConfirm) {
                model.abandonUnsavedChanges(); _ = await toolbox.flush(); dismiss(); return
            }
            // Stays open: `Space f` must not fire at some later close.
            KeyboardRouter.shared.searchAllAfterClosing = false
        }
    }

    /// The durable editor is always child zero. The sidebar only changes its
    /// available viewport, which the UIKit zoom view already handles on rotation.
    private var workspaceSurface: some View {
        GeometryReader { geometry in
            let compact = geometry.size.width < 760
            let width = min(320, max(0, geometry.size.width - (compact ? 32 : 360)))
            ZStack(alignment: .trailing) {
                editorSurface.padding(.trailing, pagesShown && !compact ? width : 0)
                if pagesShown && compact {
                    Color.black.opacity(0.35).contentShape(Rectangle())
                        .paneWakeShield()
                        .onTapGesture { pagesShown = false }
                        .transition(reduceMotion ? .opacity.animation(NotyMotion.fade) : .opacity)
                        .accessibilityLabel("Seitenleiste schließen")
                        .accessibilityAddTraits(.isButton)
                }
                if pagesShown {
                    Group {
                        if notebookLoaded {
                            PageSidebarView(model: model, selectedPageID: $selectedPageID, onBack: closeEditor, onCollapse: { pagesShown = false },
                                onSelect: { if compact { pagesShown = false } },
                                onMargins: { id in marginsPage = MarginPage(id: id) },
                                onOutline: { jumpToOutline($0) }, keyRequest: $sidebarKeys)
                        } else {
                            // Same width and tone while loading: no placeholder thumbnail, no layout jump.
                            Color(white: 0.065).ignoresSafeArea().accessibilityHidden(true)
                        }
                    }
                    .frame(width: width)
                    .paneWakeShield()
                    // Reduce Motion: only the sidebar fades; the layout (editor padding) stays instant.
                    .transition(reduceMotion ? .opacity.animation(NotyMotion.fade) : .move(edge: .trailing).combined(with: .opacity))
                }
            }
            .animation(NotyMotion.panel(reduceMotion), value: pagesShown)
        }
    }

    private var canEdit: Bool { model.writable && !model.busy && !model.mutationsPaused && isPaneActive() }
    /// Inactive view (two views) whose ink tool takes the Pencil directly:
    /// the first stroke draws and activates it, no extra tap.
    private var pencilWakes: Bool {
        !isPaneSelected() && onActivatePane != nil && notebookLoaded && tool.isInk && model.writable && !model.busy && !model.mutationsPaused
    }
    private func activatePane() { onActivatePane?(); model.pageIndex = currentPageIndex }
    /// Text document (TEXT-REBUILD-62 §4): no manual pages, taps go into the flow.
    private var isTextDocument: Bool { model.notebook.isTextDocument }

    // Palette chrome uses viewport points. The native notebook remains child zero.
    private var editorSurface: some View {
        GeometryReader { geometry in
            let _ = HangProbe.hit("ContentView.editorSurface")
            let layout = toolbarLayout(geometry.size)
            ZStack(alignment: .topLeading) {
                if !notebookLoaded {
                    // Never build sheets for the model's placeholder notebook.
                    NotebookLoadingView(failed: !model.busy)
                        .padding(.leading, layout.leftInset).padding(.trailing, layout.rightInset)
                        .padding(.top, layout.topInset).padding(.bottom, layout.bottomInset)
                } else {
                let pages = editorPages
                // Right after loading, selectedPageID may still name the placeholder
                // page until onChange runs; never let the viewport build a sheet for
                // a stale or wrong page in that frame.
                NotebookEditor(pages: pages, selectedPageID: selectedPageID.flatMap { id in pages.contains { $0.id == id } ? id : nil } ?? currentPage.id,
                    paging: toolbox.preferences.paging ?? false, normalizeWidths: toolbox.preferences.normalizePageWidths ?? false,
                    fitRequest: fitRequest, textInsertRequest: textInsertRequest, textFocus: textFocus,
                    enabled: canEdit, fingerDrawing: toolbox.preferences.fingerDrawing, writingScroll: writingScroll,
                    // No separate header strip: pages use the full height and
                    // merely start below the floating header/palette.
                    topObstruction: layout.topInset,
                    // A freely placed palette and open tool options cover part of the page: the caret is kept clear of them.
                    obstructions: (toolbox.preferences.effectiveDock == .floating ? [layout.frame.cgRect.offsetBy(dx: -layout.leftInset, dy: 0)] : [])
                        + (optionsBar(layout).map { [$0] } ?? []),
                    configuration: pageConfiguration, onSelect: { id in
                        HangProbe.hit("ContentView.onSelect")
                        guard canEdit else { return }; selectedPageID = id
                    }, onTransfer: transferContents(generation: model.pageContentGeneration),
                    onError: { model.error = $0 }, revealRequest: revealRequest,
                    laser: tool == .laser ? toolbox.preferences.laserStyle : nil,
                    optionsAvoidance: optionsBar(layout).flatMap { bar in
                        ToolbarAvoidanceEdge(dock: toolbox.preferences.effectiveDock).map { ToolbarOptionsAvoidance(edge: $0, bar: bar) }
                    }, onActivate: pencilWakes ? { activatePane() } : nil)
                    .background { GeometryReader { proxy in
                        Color.clear.preference(key: PaneWakeArea.self, value: PaneWakeArea.Area(pages: PaneWakeArea.pages(proxy.frame(in: .named(PaneWakeArea.space)), top: layout.topInset)))
                    } }
                    .ignoresSafeArea(.container, edges: .bottom)
                    .padding(.bottom, layout.bottomInset)
                    .padding(.leading, layout.leftInset)
                    .padding(.trailing, layout.rightInset)
                }
                editorHeader(layout: layout)
                    .frame(height: 60)
                ToolbarPaletteHost(layout: layout, preferences: $toolbox.preferences, more: $toolbarMore,
                    secondView: onSecondView != nil, enabled: canEdit && toolbox.usable,
                    showingOptions: toolbarOptions, optionsWidth: optionsWidths[tool] ?? EditorToolOptions.preferredWidth(for: tool)) { axis in
                    palette(axis: axis)
                } options: {
                    EditorToolOptions(tool: toolBinding, preferences: $toolbox.preferences, showing: $toolbarOptions,
                        shapeOptions: Binding(get: { shapeOptions }, set: { shapeOptions = $0 }), selectionFilter: Binding(get: { selectionFilter }, set: { selectionFilter = $0 }),
                        lassoMode: Binding(get: { lassoMode }, set: { lassoMode = $0 }),
                        recognizeShapes: Binding(get: { recognizeShapes }, set: { recognizeShapes = $0 }),
                        textToolLocked: $textToolLocked,
                        onInsertText: { textInsertRequest += 1 },
                        onPhoto: { imageTarget = currentPage.id; choosingPhoto = true },
                        onImageFile: { imageTarget = currentPage.id; importingImage = true },
                        onPasteImage: { if currentPage.id == writingDraft.id { guard model.materializeDraft(draftPage) else { return } }; model.pasteImage(pageID: currentPage.id, near: nil) },
                        onContentWidth: { width in if optionsWidths[tool] != width { optionsWidths[tool] = width } })
                }
                if notebookLoaded, canEdit, let pencilPalette {
                    PencilToolPalette(presentation: pencilPalette, tool: toolBinding, preferences: $toolbox.preferences, inkTool: lastInkTool,
                        canUndo: model.canUndo, canRedo: model.canRedo, onUndo: { performUndo(redo: $0) },
                        onSelect: selectFromPencilPalette, onDismiss: { dismissPencilPalette(pencilPalette.id) })
                        .id(pencilPalette.id).transition(.opacity.animation(.easeOut(duration: 0.1)))
                        .onDisappear { dismissPencilPalette(pencilPalette.id) }
                }
                // Toolbar and attached options over the pages (floating or
                // beside a dock), in the surface space: shields of the
                // activation layer of an inactive view.
                let origin = geometry.frame(in: .named(PaneWakeArea.space)).origin
                let chrome = [layout.frame.cgRect] + (toolbarOptions
                    ? [layout.optionsFrame(preferredWidth: optionsWidths[tool] ?? EditorToolOptions.preferredWidth(for: tool)).cgRect] : [])
                Color.clear.allowsHitTesting(false).accessibilityHidden(true)
                    .preference(key: PaneWakeArea.self, value: PaneWakeArea.Area(shields: chrome.map { $0.offsetBy(dx: origin.x, dy: origin.y) }))
            }
            .ignoresSafeArea(.keyboard, edges: .bottom)
            .background(Color(uiColor: NotebookViewport.backdrop).ignoresSafeArea())
            .animation(NotyMotion.palette(reduceMotion), value: toolbox.preferences.dock)
            .overlay(alignment: .bottomTrailing) {
                if notebookLoaded {
                    pageNavigator.paneWakeShield().padding(.trailing, layout.rightInset + 14).padding(.bottom, layout.bottomInset + 16)
                }
            }
            .overlay(alignment: .bottom) {
                // Narrow panes: keep clear of the page navigator (trailing). While
                // the status pill shows (any width, it may grow almost to the pane
                // width), sit above its measured height: „Abbrechen“ and
                // „Erneut versuchen“ both stay reachable.
                let narrow = geometry.size.width - layout.leftInset - layout.rightInset < 560
                PDFExportProgressBadge(job: pdfExport)
                    .padding(.leading, narrow ? layout.leftInset + 12 : 0)
                    .padding(.trailing, narrow ? layout.rightInset + Self.navigatorClearance : 0)
                    .padding(.bottom, layout.bottomInset + 12 + (statusNote != nil && statusPillHeight > 0 ? statusPillHeight + 8 : 0))
                    .animation(NotyMotion.highlight(reduceMotion), value: pdfExport.progress == nil)
            }
            .overlay(alignment: .bottomLeading) {
                // Animation scoped to the pill: autosave updates elsewhere stay unanimated.
                ZStack(alignment: .bottomLeading) {
                    if notebookLoaded || !model.busy, let note = statusNote {
                        // Never under the page navigator: its retry target stays reachable.
                        statusPill(note, maxWidth: max(160, geometry.size.width - layout.leftInset - layout.rightInset - 12 - Self.navigatorClearance))
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { statusPillHeight = $0 }
                            .padding(.leading, layout.leftInset + 12).padding(.bottom, layout.bottomInset + 12)
                            .transition(.opacity)
                    }
                }.animation(NotyMotion.highlight(reduceMotion), value: statusNote)
            }
        }
    }
    /// Routine save states live in the options menu. The corner only shows what
    /// needs attention (failure, recovery) or just happened (export, defaults).
    private var statusNote: String? {
        if model.saveFailed { return model.status }
        if let recentNote { return recentNote }
        return Self.routineStatuses.contains(model.status) ? nil : model.status
    }
    private static let routineStatuses: Set<String> = ["Noch nicht gespeichert", "Bereit", "Änderungen werden gespeichert …", "Lokal gespeichert", "Importiert und lokal gespeichert"]
    /// Room the bottom-trailing page navigator takes (56 wide, 14 from the
    /// edge) plus a gap: bottom overlays on narrow panes stay clear of it.
    private static let navigatorClearance: CGFloat = 14 + 56 + 10
    /// Measured height of the status pill: the PDF badge sits above it.
    @State private var statusPillHeight: CGFloat = 0
    @ViewBuilder private func statusPill(_ note: String, maxWidth: CGFloat) -> some View {
        let label = NotyWidthCap(maximum: maxWidth) {
            HStack(spacing: 6) {
                if model.saveFailed { Image(systemName: "exclamationmark.triangle.fill") }
                Text(note).lineLimit(2)
                if model.saveFailed && model.writable {
                    Text("Erneut versuchen").fontWeight(.semibold).lineLimit(1).fixedSize().layoutPriority(1)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
        }
        // Same glass as the rest of the editor chrome, bright text: readable on
        // white and on dark paper (polish audit F9).
        .font(.caption).foregroundStyle(model.saveFailed ? Color.orange : .white.opacity(0.88))
        .notyGlass(in: Capsule())
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .environment(\.colorScheme, .dark)
        .accessibilityIdentifier("saveStatus")
        if model.saveFailed && model.writable {
            Button { model.save() } label: { label }.buttonStyle(NotyPressStyle())
        } else {
            label.allowsHitTesting(false)
        }
    }
    /// File/backup feedback stays a few seconds, then the corner is clear again.
    private func showRecentNote(_ note: String?) {
        guard let note, !note.isEmpty else { return }
        // VoiceOver hears what the corner shows (polish audit F10).
        if isPaneActive() { AccessibilityNotification.Announcement(note).post() }
        recentNote = note; recentNoteToken += 1
        let token = recentNoteToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { if recentNoteToken == token { recentNote = nil } }
    }
    /// Open attached tool options in viewport points (the notebook viewport
    /// starts at the top edge and after the left toolbar inset).
    private func optionsBar(_ layout: ToolbarLayout) -> CGRect? {
        guard toolbarOptions, notebookLoaded else { return nil }
        return layout.optionsFrame(preferredWidth: optionsWidths[tool] ?? EditorToolOptions.preferredWidth(for: tool))
            .cgRect.offsetBy(dx: -layout.leftInset, dy: 0)
    }
    private func toolbarLayout(_ size: CGSize) -> ToolbarLayout {
        let count = ToolbarLayout.itemCount(more: toolbarMore, preferences: toolbox.preferences, secondView: onSecondView != nil)
        return ToolbarLayout(viewport: PageSize(width: size.width, height: size.height), dock: toolbox.preferences.effectiveDock,
            floatingAxis: toolbox.preferences.floatingAxis ?? .horizontal, items: count,
            headerItems: ToolbarLayout.itemCount(more: false, preferences: toolbox.preferences, secondView: onSecondView != nil),
            floatingX: toolbox.preferences.floatingX, floatingY: toolbox.preferences.floatingY)
    }
    private func palette(axis: ToolbarAxis) -> some View {
        EditorToolbar(tool: toolBinding, preferences: $toolbox.preferences,
            onFit: { fitRequest += 1 }, onCustomize: { customizingTools = true },
            onSearch: { contentSearch = true }, onSecondView: onSecondView,
            ruler: Binding(get: { ruler }, set: { ruler = $0 }),
            more: $toolbarMore, settings: $toolbarOptions, axis: axis, activeInk: lastInkTool,
            searchTitle: isTextDocument ? "Im Dokument suchen" : "Im Heft suchen")
    }

    private func editorHeader(layout: ToolbarLayout) -> some View {
        ZStack(alignment: .topLeading) {
            // Arrow and title form one button: tapping the name also leaves the notebook.
            Button(action: closeEditor) {
                HStack(spacing: 0) {
                    Image(systemName: closeSymbol).frame(width: 44, height: 44)
                    if layout.headerLeadingFrame.width >= 100, notebookLoaded || closeTitle != nil {
                        Text(closeTitle ?? model.notebook.title).font(.subheadline.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                            .padding(.trailing, 14)
                    }
                }.contentShape(Rectangle())
            }.accessibilityLabel(closeTitle ?? "Zur Bibliothek").accessibilityValue(notebookLoaded ? model.notebook.title : "")
                .notyTooltip(closeTitle == nil ? "Zur Bibliothek (⌘W)" : "Zurück (⌘W)", hint: false)
                .padding(.horizontal, 4).frame(height: 44).notyGlass()
                .frame(maxWidth: max(52, layout.headerLeadingFrame.width), alignment: .leading)
                .frame(width: max(52, layout.headerLeadingFrame.width), height: 44, alignment: .leading)
                .offset(x: layout.headerLeadingFrame.x, y: layout.headerLeadingFrame.y)
            HStack(spacing: 0) {
                // Notebook-wide: the most recent change on any page, in order.
                Button { performUndo(redo: false) } label: {
                    NotyActionGlyph(kind: .undo).frame(width: 24, height: 24).frame(width: 44, height: 44).contentShape(Rectangle())
                        .opacity(model.canUndo ? 1 : NotyChrome.disabledOpacity)
                }.accessibilityLabel("Rückgängig").notyTooltip("Rückgängig (⌘Z)", hint: false).disabled(!model.canUndo)
                if layout.headerActionCount >= 4 {
                    Button { performUndo(redo: true) } label: {
                        NotyActionGlyph(kind: .redo).frame(width: 24, height: 24).frame(width: 44, height: 44).contentShape(Rectangle())
                            .opacity(model.canRedo ? 1 : NotyChrome.disabledOpacity)
                    }.accessibilityLabel("Wiederholen").notyTooltip("Wiederholen (⇧⌘Z)", hint: false).disabled(!model.canRedo)
                }
                if layout.headerActionCount >= 5 {
                    Button { writingScroll.toggle() } label: {
                        // On: the symbol itself is filled and tinted, no box behind it.
                        Image(systemName: writingScroll ? "arrow.left.and.right.square.fill" : "arrow.left.and.right.square")
                            .foregroundStyle(writingScroll ? Color.notyAccent : Color.white)
                            .scaleEffect(writingScroll ? 1.12 : 1)
                            .frame(width: 44, height: 44).contentShape(Rectangle())
                    }.accessibilityLabel("Schreibscrollen")
                        .notyTooltip("Schreibscrollen – Blattrand zur Mitte holen", hint: false)
                        .accessibilityValue(writingScroll ? "Ein" : "Aus")
                        .accessibilityHint("Seitlich scrollen, bis der Blattrand die Bildschirmmitte erreicht, um bequemer am Rand zu schreiben.")
                }
                optionsMenu(layout: layout).notyTooltip("Optionen – Teilen, Export, Seite", hint: false)
                // Text documents get their pages from the text only.
                if !layout.compactHeader, !isTextDocument {
                    Menu { pageInsertionActions } label: {
                        Image(systemName: "doc.badge.plus").frame(width: 44, height: 44).contentShape(Rectangle())
                    }.accessibilityLabel("Neue Seite").notyTooltip("Seite hinzufügen", hint: false)
                }
                Button { pagesShown.toggle() } label: {
                    Image(systemName: "sidebar.right").frame(width: 44, height: 44).contentShape(Rectangle())
                }.accessibilityLabel("Seitenübersicht rechts").notyTooltip("Seitenleiste ein/aus", hint: false)
            }.padding(.horizontal, 4).frame(width: layout.headerActionsFrame.width, height: 44)
                .notyGlass().disabled(!canEdit)
                .offset(x: layout.headerActionsFrame.x, y: layout.headerActionsFrame.y)
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .buttonStyle(NotyToolStyle())
            // Fixed 44-pt chrome over the canvas: capped like system bars.
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            .environment(\.notyTooltipAxis, .horizontal)
            .notyTooltipHost()
    }
    @ViewBuilder private var pageInsertionActions: some View {
        Button("Standardseite hinzufügen", systemImage: "doc.badge.plus") {
            let defaults = model.notebook.pageDefaults
            model.insertPaper(defaults.paper, color: defaults.color, relativeTo: anchorPageID)
        }
        Button("Papier, PDF oder Bild wählen …", systemImage: "doc.on.doc") { addingPage = true }
    }

    private var pageNavigator: some View {
        VStack(spacing: 3) {
            Button { stepPage(-1) } label: { Image(systemName: "chevron.up").frame(width: 48, height: 44).contentShape(Rectangle()) }
                .disabled(currentPageIndex == 0 && currentPage.id != writingDraft.id)
                .foregroundStyle(.white.opacity(currentPageIndex == 0 && currentPage.id != writingDraft.id ? NotyChrome.disabledOpacity : 1))
                .accessibilityLabel("Vorherige Seite").notyTooltip("Vorherige Seite (⌘↑)", hint: false).accessibilityShowsLargeContentViewer()
            pageNumberButton
            Button { stepPage(1) } label: { Image(systemName: "chevron.down").frame(width: 48, height: 44).contentShape(Rectangle()) }
                .disabled(currentPage.id == writingDraft.id || currentPageIndex >= model.notebook.pages.count - 1)
                .foregroundStyle(.white.opacity(currentPage.id == writingDraft.id || currentPageIndex >= model.notebook.pages.count - 1 ? NotyChrome.disabledOpacity : 1))
                .accessibilityLabel("Nächste Seite").notyTooltip("Nächste Seite (⌘↓)", hint: false).accessibilityShowsLargeContentViewer()
        }.padding(4).notyGlass().buttonStyle(NotyToolStyle()).disabled(!canEdit)
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            // Names open to the left, towards the page.
            .environment(\.notyTooltipAxis, .vertical)
            .notyTooltipHost()
    }
    /// Chevrons and ⌘↑/⌘↓: from the trailing draft page "up" returns to the last real page.
    private func stepPage(_ delta: Int) {
        guard canEdit else { return }
        if currentPage.id == writingDraft.id {
            if delta < 0 { selectedPageID = model.notebook.pages.last?.id }
        } else { currentPageIndex += delta }
    }
    /// Number block of the navigator: tap (or ⌘G) opens "Gehe zu Seite".
    private var pageNumberButton: some View {
        let count = model.notebook.pages.count
        let onDraft = currentPage.id == writingDraft.id
        return Button { openPageEntry() } label: {
            VStack(spacing: 3) {
                Text(onDraft ? "+" : "\(currentPageIndex + 1)").font(.caption.weight(.semibold).monospacedDigit())
                    .lineLimit(1).minimumScaleFactor(0.7)
                Rectangle().fill(.secondary).frame(width: 16, height: 1)
                Text("\(count)").font(.caption.monospacedDigit()).lineLimit(1).minimumScaleFactor(0.7)
            }.frame(width: 48, height: 40).contentShape(Rectangle())
        }
        .foregroundStyle(.white)
        .notyTooltip("Gehe zu Seite (⌘G)", hint: false)
        // With the law window focused ⌘G is its next hit (menu „Gesetze“).
        .keyboardShortcut(lawKeys.focused ? nil : KeyboardShortcut("g", modifiers: .command))
        .accessibilityLabel(onDraft ? "Neue Seite nach Seite \(count), zum Springen tippen" : "Seite \(currentPageIndex + 1) von \(count), zum Springen tippen")
        .popover(isPresented: $pageEntry, arrowEdge: .trailing) { pageEntryPanel(count: count) }
    }
    private func openPageEntry() {
        guard canEdit else { return }
        pageEntryText = ""; pageEntry = true
    }
    /// Compact in-app number pad: no system keyboard. Digits that would leave
    /// 1…N are disabled, so only existing pages can be submitted.
    private func pageEntryPanel(count: Int) -> some View {
        PageJumpPad(text: $pageEntryText, count: count, current: currentPageIndex + 1,
                    onGo: jumpToEnteredPage, onCancel: { pageEntry = false })
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            .presentationCompactAdaptation(.popover)
    }
    private func jumpToEnteredPage() {
        let count = model.notebook.pages.count
        guard canEdit else { pageEntry = false; return }
        guard let number = Int(pageEntryText), (1...count).contains(number) else { return }
        pageEntry = false
        // Same selection path as the chevrons and the sidebar: the viewport
        // treats a selection it did not report as a jump (scroll and paging).
        currentPageIndex = number - 1
    }
    /// Options („…“): a status line plus a few grouped entries. Rare tools sit in
    /// submenus; undo/redo and adding pages only appear when the header has no room.
    private func optionsMenu(layout: ToolbarLayout) -> some View {
        Menu {
            Section(model.status) {
                if model.saveFailed {
                    Button("Erneut speichern", systemImage: "arrow.clockwise") { model.save() }
                }
                if !toolbox.status.isEmpty { Text(toolbox.status) }
            }
            if layout.headerActionCount < 4 {
                Button("Wiederholen", systemImage: "arrow.uturn.forward") { performUndo(redo: true) }.disabled(!model.canRedo)
            }
            Section {
                // ⌘F/⌘S live in the app menu (NotyCommands): shortcuts inside a closed Menu do not register.
                Button(isTextDocument ? "Im Dokument suchen" : "Im Heft suchen", systemImage: "magnifyingglass") { contentSearch = true }
                if layout.compactHeader, !isTextDocument {
                    Menu("Seite hinzufügen", systemImage: "doc.badge.plus") { pageInsertionActions }
                }
                Menu("Teilen und exportieren", systemImage: "square.and.arrow.up") {
                    Section("PDF") {
                        Button("Als PDF exportieren …", systemImage: "doc.richtext") { startPDFExport(pageOnly: false) }
                            .disabled(!model.writable || pdfExport.running)
                        Button("Diese Seite als PDF exportieren …", systemImage: "doc") { startPDFExport(pageOnly: true) }
                            .disabled(!model.writable || currentPage.id == writingDraft.id || pdfExport.running)
                    }
                    // One symbol per meaning: the text formats go without (polish audit F15).
                    Section("Nur Text") {
                        Button("Als Markdown teilen (.md) …") { shareText(.markdown) }
                            .disabled(!model.writable)
                        Button("Als Text teilen (.txt) …") { shareText(.plainText) }
                            .disabled(!model.writable)
                        Button("Als Word teilen (.docx) …") { shareText(.word) }
                            .disabled(!model.writable)
                        Button("Als RTF teilen (.rtf) …") { shareText(.rtf) }
                            .disabled(!model.writable)
                    }
                    Section(model.backupStatus) {
                        Button("Als .noty teilen …", systemImage: "shippingbox") { shareNoty() }
                            .disabled(!model.writable)
                        // Same checked archive as „Als .noty teilen“, but saved via
                        // the file dialog and counted as backup (status, date).
                        Button("In Dateien sichern …", systemImage: "archivebox") { exportBackup() }
                            .disabled(!model.writable)
                    }
                }
            }
            Section {
                if let onLaws { LawPanelMenuToggle(action: onLaws) }
                Menu("Ansicht", systemImage: "eye") {
                    Toggle("Schreibscrollen bis zur Bildschirmmitte", systemImage: "arrow.left.and.right.square", isOn: $writingScroll)
                    Toggle("Blättern statt Scrollen", systemImage: "book.pages", isOn: Binding(get: { toolbox.preferences.paging ?? false }, set: { toolbox.preferences.paging = $0 }))
                    Toggle("PDFs einheitlich anzeigen", systemImage: "rectangle.split.3x1", isOn: Binding(get: { toolbox.preferences.normalizePageWidths ?? false }, set: { toolbox.preferences.normalizePageWidths = $0 }))
                        .accessibilityHint("Gleiche Arbeitsblattbreite mit Schreibraum daneben. Ändert nur die Anzeige.")
                }
                if !isTextDocument {
                    Button("Seite anpassen …", systemImage: "arrow.up.left.and.down.right.and.arrow.up.right.and.down.left") {
                        marginsPage = MarginPage(id: currentPage.id)
                    }.disabled(!canEdit || !model.notebook.pages.contains(where: { $0.id == currentPage.id })
                               || (model.sourcePage(for: currentPage) == nil && !currentPage.writingSpaceExtendsPaper))
                    Button("Papier für neue Seiten …", systemImage: "squareshape.split.3x3") { editingDefaults = true }
                        .disabled(!canEdit)
                } else {
                    Button("Seitenumbruch einfügen", systemImage: "arrow.down.to.line.compact") { insertPageBreak() }
                        .disabled(!canEdit)
                    Button("Papier ändern …", systemImage: "squareshape.split.3x3") { editingDefaults = true }
                        .disabled(!canEdit)
                }
                Button("Lokale Wiederherstellungspunkte …", systemImage: "clock.arrow.circlepath") { showingHistory = true }
                    .disabled(!model.writable)
            }
            if editorSettings != nil {
                Section {
                    Button("Einstellungen …", systemImage: "gearshape") { showingSettings = true }
                }
            }
        } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44).contentShape(Rectangle()) }
            .accessibilityLabel("Optionen")
    }
    private func exportBackup() {
        Task {
            if let url = await model.backupFile() {
                if let previous = exportFile?.fileURL { BackupScratch.remove(previous) }
                exportFile = ExportFile(backupFile: url)
                exportType = .noty
                exporting = true
            }
        }
    }
    /// At the caret; without one behind the text.
    private func insertPageBreak() {
        if let text = UIResponder.currentFirstResponder as? any KeyboardTextTarget { text.insertPageBreak(); return }
        guard let length = model.notebook.textFlowContent.map({ ($0.text as NSString).length }) else { return }
        if tool != .text { tool = .text; toolbarOptions = false }
        flowActions?.edit([TextListEditing.Edit(range: NSRange(location: length, length: 0), replacement: TextLines.pageBreakText)], nil)
    }
    /// The text of this notebook or document (`TextDocumentExport`) in the
    /// share sheet, named `<Titel>.txt`/`.md`/`.rtf`/`.docx`; removed after
    /// sharing. Without any text nothing is shared.
    private func shareText(_ format: TextDocumentExport.Format) {
        let data = TextDocumentExport.data(model.notebook, as: format)
        guard !data.isEmpty else { model.error = "Hier gibt es noch keinen Text zum Teilen."; return }
        do {
            let url = try BackupScratch.newShareFile(title: model.notebook.title, fileExtension: format.fileExtension)
            try data.write(to: url, options: .atomic)
            NotyShare.present(url)
            if format == .word || format == .rtf, TextDocumentExport.leavesOutContent(of: model.notebook, drawingIsEmpty: EditorModel.drawingIsEmpty) {
                model.fileStatus = "Nur Text: Handschrift, Bilder und Formen stehen im PDF-Export"
            }
        } catch { model.error = "Teilen nicht möglich: \(error.localizedDescription)" }
    }
    /// The checked `<Titel>.noty` of the current state in the share sheet.
    private func shareNoty() {
        Task { if let url = await model.backupFile(sharing: true) { NotyShare.present(url) } }
    }
    /// Page by page with a progress badge; the snapshot is fixed at the start.
    private func startPDFExport(pageOnly: Bool) {
        guard canEdit, !pdfExport.running, !(pageOnly && currentPage.id == writingDraft.id) else { return }
        // A text document leaves out trailing pages without content (the reserve page is never part of it).
        pdfExport.start(model.notebook, pageIDs: pageOnly ? [currentPage.id] : PDFExporter.wholeDocumentPages(model.notebook), sourcePage: { model.sourcePage(for: $0) },
                        assets: model.imageAssets) { result in
            switch result {
            case .success(let data): exportFile = ExportFile(pdfData: data); exportType = .pdf; exporting = true
            case .failure(let error):
                if error is CancellationError { model.fileStatus = "PDF-Export abgebrochen" } else { model.error = error.localizedDescription }
            }
        }
    }
    /// Notebook-wide undo/redo: reverts the most recent change on any page in
    /// order (by stable page ID) and brings that page into view.
    private func performUndo(redo: Bool) {
        // A held line/shape still waiting for PencilKit is the newest step.
        WorksheetView.settleHeldStrokes()
        guard canEdit else {
            // Never a silent no-op: an import or backup holds the notebook for the moment.
            if isPaneActive(), model.writable { showRecentNote("\(redo ? "Wiederholen" : "Rückgängig") geht erst nach dem laufenden Vorgang.") }
            return
        }
        guard let outcome = model.undo(redo: redo) else { return }
        KeyboardRouter.shared.textChangedElsewhere()
        // Undoing the first content on the former writing draft removed that
        // page again: the (new) writing draft takes its place, without a jump.
        if outcome.pageID == selectedPageID, !model.notebook.pages.contains(where: { $0.id == outcome.pageID }) {
            selectedPageID = writingDraft.id; revealRequest = PageRevealRequest(pageID: writingDraft.id)
            return
        }
        if tool == .text, var focus = outcome.focus, model.notebook.pages.contains(where: { $0.id == focus.pageID }) {
            focus.requestID = UUID(); textFocus = focus
            // Only now: an undo without a focus must not hold the mode.
            KeyboardRouter.shared.undoRequestedFocus()
        }
        guard outcome.pageID != selectedPageID, model.notebook.pages.contains(where: { $0.id == outcome.pageID }) else { return }
        revealRequest = PageRevealRequest(pageID: outcome.pageID)
        selectedPageID = outcome.pageID
    }
    /// Pencil double tap / double squeeze („Radierer“): eraser ↔ exactly the
    /// tool used before it, whatever it was (laser, lasso, shapes …),
    /// honouring the eraser preference.
    private func togglePencilEraser() {
        guard canEdit else { return }
        pencilPalette = nil
        if tool.isEraser {
            tool = toolBeforeEraser.flatMap { $0.isEraser ? nil : $0 } ?? lastInkTool
        } else {
            tool = toolbox.preferences.eraserPrecision == true ? .precisionEraser : .strokeEraser
        }
    }
    /// System setting „Vorheriges Werkzeug“: back to the tool used before the
    /// current one (a second time returns again); without one like the eraser toggle.
    private func switchToPreviousTool() {
        guard canEdit else { return }
        pencilPalette = nil
        guard let previous = previousTool, previous != tool else { togglePencilEraser(); return }
        tool = previous
    }
    private func pencilToolSwitch(_ action: PencilToolSwitch) {
        switch action {
        case .eraser: togglePencilEraser()
        case .previous: switchToPreviousTool()
        }
    }
    /// Apple Pencil Pro: one squeeze opens the tool palette at the Pencil; a
    /// quick second squeeze toggles the eraser instead (palette never shown).
    private func handlePencilSqueeze(_ event: PencilSqueezeEvent) {
        guard canEdit, notebookLoaded else { return }
        switch pencilSqueeze.handle(event.phase, at: event.time, showing: pencilPalette != nil, preference: event.preference) {
        case .none: break
        case .schedule(let token):
            // Shown after a short delay (most double squeezes cancel it first);
            // a later second squeeze still closes it and toggles (tracker).
            let presentation = PencilPalettePresentation(location: event.location, leftHanded: event.leftHanded)
            DispatchQueue.main.asyncAfter(deadline: .now() + PencilSqueezeTracker.showDelay) {
                guard pencilSqueeze.fire(token), canEdit, notebookLoaded, pencilPalette == nil else { return }
                pencilPalette = presentation
            }
        case .dismiss: withAnimation(NotyMotion.highlight(reduceMotion)) { pencilPalette = nil }
        case .toggle:
            if #available(iOS 17.5, *), UIPencilInteraction.preferredSqueezeAction == .switchPrevious { switchToPreviousTool() }
            else { togglePencilEraser() }
        }
    }
    /// Same selection path as the toolbar buttons.
    private func selectFromPencilPalette(_ item: EditorTool) {
        let choice = EditorToolbar.choice(item, preferences: toolbox.preferences)
        tool = choice.tool; toolbarOptions = choice.options
    }
    private func dismissPencilPalette(_ id: UUID) {
        guard pencilPalette?.id == id else { return }
        withAnimation(NotyMotion.highlight(reduceMotion)) { pencilPalette = nil }
    }

    /// Cross-page selection moves: all pages or none (one notebook-wide undo step).
    /// Dropping onto the trailing draft page materializes it first.
    private func transferContents(generation: Int) -> ([PageContentReplacement]) -> Bool {
        { changes in
            guard isPaneActive(), model.pageContentGeneration == generation else { return false }
            for change in changes where change.pageID == writingDraft.id && !model.notebook.pages.contains(where: { $0.id == change.pageID }) {
                guard PageContent(page: draftPage) == change.expected, model.materializeDraft(draftPage) else { return false }
            }
            return model.replaceContents(changes)
        }
    }

    private func pageConfiguration(_ page: Page) -> PageEditor {
        HangProbe.hit("ContentView.pageConfiguration")
        let sourcePage = model.sourcePage(for: page)
        let layout = (try? PageLayout(page: page, source: sourcePage?.pageRef)) ?? model.pageLayout
        let generation = model.pageContentGeneration
        let preferences = toolbox.preferences
        return PageEditor(sourcePage: sourcePage, layout: layout, pageID: page.id, page: page,
            drawing: page.drawing, textBoxes: page.effectiveTextBoxes, images: page.images ?? [], shapes: page.shapes ?? [],
            searchHighlight: searchHighlightPageID == page.id ? searchHighlight : nil, paper: page.paper ?? (sourcePage == nil ? .legacyTest : .blank),
            paperColor: page.paperColor ?? .white, margins: page.margins, writingRegionTops: page.writingRegionTops,
            tool: tool, color: tool == .marker
                ? UIColor(preferences.markerColor.color).withAlphaComponent(preferences.markerStrokeColor.alpha)
                : UIColor(preferences.inkColor(for: tool).color),
            width: preferences.inkWidth(for: tool) * page.inkWidthScale,
            enabled: canEdit, autoPen: preferences.automaticInk(for: tool),
            fingerDrawing: preferences.fingerDrawing, ruler: ruler, shapeOptions: shapeOptions, selectionFilter: selectionFilter, lassoMode: lassoMode,
            recognizeShapes: tool == .marker ? preferences.markerHoldStraighten ?? true : recognizeShapes, markerStraight: preferences.markerStraight ?? false, markerTip: preferences.effectiveMarkerTip, scribbleErase: preferences.scribbleErase ?? true,
            onPencilAction: { pencilToolSwitch($0) },
            onPencilSqueeze: { handlePencilSqueeze($0) },
            onPencilWake: pencilWakes ? { activatePane() } : nil,
            onInteraction: { id, active in
                model.setInteraction(id, active: active)
                if active { KeyboardRouter.shared.pageTouched(); LawKeyboard.shared.pageTouched() }
            },
            onUndo: { redo in performUndo(redo: redo) },
            undoState: UndoAvailability(undo: model.canUndo, redo: model.canRedo),
            onInkSession: { model.beginInkSession(pageID: page.id) },
            fitRequest: fitRequest, contentGeneration: generation,
            textInsertRequest: textInsertRequest,
            onFlowEdit: { previous, replacement, selection in
                guard isPaneActive(), model.pageContentGeneration == generation else { return nil }
                if page.id == writingDraft.id, !model.notebook.pages.contains(where: { $0.id == page.id }) {
                    var draft = draftPage; draft.textBoxes = (writingDraft.textBoxes ?? []).map { $0.id == previous.id ? previous : $0 }
                    if draft.textBoxes?.contains(where: { $0.id == previous.id }) != true { draft.textBoxes = (draft.textBoxes ?? []) + [previous] }
                    guard model.materializeDraft(draft) else { return nil }
                }
                let focus = model.updateFlowText(pageID: page.id, previous: previous, replacement: replacement,
                    selection: selection, trailingDraft: draftPage)
                if let focus {
                    // The caret leaves this page: the old view ends before the new one begins.
                    if focus.pageID != page.id { KeyboardRouter.shared.handoff = true }
                    textFocus = focus; selectedPageID = focus.pageID
                }
                return focus
            },
            onFlowUndo: { redo in
                guard isPaneActive(), model.pageContentGeneration == generation else { return }
                performUndo(redo: redo)
            },
            onFlowBackspace: { box in
                guard isPaneActive(), model.pageContentGeneration == generation else { return }
                if let focus = model.backspaceFlowText(pageID: page.id, box: box) { textFocus = focus; selectedPageID = focus.pageID }
            },
            onUndoBoundary: { if isPaneActive(), model.pageContentGeneration == generation { model.separateUndoStep() } },
            readTextBoxes: { model.notebook.pages.first(where: { $0.id == page.id })?.effectiveTextBoxes ?? (page.id == writingDraft.id ? writingDraft.effectiveTextBoxes : []) },
            readFlowText: { flow in model.notebook.pages.flatMap { $0.effectiveTextBoxes.filter { $0.flowID == flow }.map(\.text) }.joined() },
            onDrawing: { data in
                // Not `isPaneActive`: a late stroke behind a closing phase still counts.
                guard isPaneSelected(), model.pageContentGeneration == generation else { return }
                if page.id == writingDraft.id, !model.notebook.pages.contains(where: { $0.id == page.id }) {
                    guard let drawing = try? PKDrawing(data: data), !drawing.strokes.isEmpty else { return }
                    // Late stroke behind a backup pause or a busy model: kept on
                    // the draft (its sheet keeps showing it) and adopted when
                    // editing resumes, like `heldDrawings` of existing pages.
                    guard model.materializeDraft(draftPage) else { writingDraft.drawing = data; return }
                }
                model.updateDrawing(data, pageID: page.id)
            },
            onTextBoxes: { boxes in
                guard isPaneActive(), model.pageContentGeneration == generation else { return }
                if page.id == writingDraft.id, !model.notebook.pages.contains(where: { $0.id == page.id }) {
                    writingDraft.textBoxes = boxes
                    guard boxes.contains(where: { !$0.text.isEmpty }) else { return }
                    guard model.materializeDraft(draftPage) else { return }
                }
                model.updateTextBoxes(boxes, pageID: page.id)
            },
            onImages: { if isPaneActive(), model.pageContentGeneration == generation { model.updateImages($0, pageID: page.id) } },
            onError: { model.error = $0 },
            onContent: { next, before in
                guard isPaneActive(), model.pageContentGeneration == generation else { return false }
                if page.id == writingDraft.id, !model.notebook.pages.contains(where: { $0.id == page.id }) {
                    guard model.materializeDraft(draftPage) else { return false }
                }
                return model.updateContent(next, basedOn: before, pageID: page.id)
            },
            onEraseShapes: { next, before in
                // Only existing pages carry shapes; the draft page has none.
                guard isPaneActive(), model.pageContentGeneration == generation else { return false }
                return model.updateContent(next, basedOn: before, pageID: page.id, inkGesture: true)
            },
            onPasteImage: { place, finished in
                guard isPaneActive(), model.pageContentGeneration == generation, canEdit else { finished(false); return }
                if page.id == writingDraft.id, !model.notebook.pages.contains(where: { $0.id == page.id }) {
                    guard model.materializeDraft(draftPage) else { finished(false); return }
                }
                model.pasteImage(pageID: page.id, near: place, finished: finished)
            },
            onTextFieldRequested: {
                // Double-tap menu „Textfeld hinzufügen“ or a second tap on a selected
                // field: the sheet opens the field once the text tool is set.
                guard canEdit else { return }
                tool = .text; toolbarOptions = false
            },
            textToolLocked: textToolLocked,
            flowDocument: model.notebook.isTextDocument,
            onFlowEnd: {
                // Below the text, on a page after it or on the reserve page: caret behind the last character.
                guard isPaneActive(), model.pageContentGeneration == generation, canEdit,
                      var focus = model.textFlowEnd() else { return }
                KeyboardRouter.shared.writingRequested()
                if tool != .text { tool = .text; toolbarOptions = false }
                focus.requestID = UUID(); textFocus = focus; selectedPageID = focus.pageID
            },
            onSelectWholeFlow: {
                // ⌘A with a pen or between fields: the caret first (on this page), then the selection.
                guard isPaneActive(), model.pageContentGeneration == generation, canEdit else { return }
                let here = model.notebook.textFlowSegments.first { $0.pageID == currentPage.id }
                guard var focus = here.map({ TextFlowFocus(pageID: $0.pageID, boxID: $0.box.id, selection: NSRange(location: ($0.box.text as NSString).length, length: 0), typingStyle: $0.box.style) }) ?? model.textFlowEnd() else { return }
                TextFlowSelection.shared.selectAllWhenFocused = true
                if tool != .text { tool = .text; toolbarOptions = false }
                focus.requestID = UUID(); textFocus = focus; selectedPageID = focus.pageID
            },
            flowActions: flowActions,
            onTextEditingFinished: {
                // Leaving a field returns to the tool before the text tool (Textneubau).
                guard isPaneActive(), tool == .text, !textToolLocked else { return }
                tool = toolBeforeText.flatMap { $0 == .text ? nil : $0 } ?? lastInkTool
            })
    }

}

/// "Gehe zu Seite" as a floating number pad (digits, delete, Los). Hardware
/// keyboards type digits, Backspace deletes, Return jumps and Escape closes
/// through key equivalents, so no text field and no system keyboard is needed.
private struct PageJumpPad: View {
    @Binding var text: String
    let count: Int
    let current: Int
    let onGo: () -> Void
    let onCancel: () -> Void

    private var number: Int? { Int(text) }
    private var valid: Bool { number.map { (1...count).contains($0) } ?? false }
    /// A digit is offered only if the result can still be a page of this notebook.
    private func accepts(_ digit: Int) -> Bool {
        if text.isEmpty && digit == 0 { return false }
        guard text.count < 4, let next = Int(text + String(digit)) else { return false }
        return next <= count
    }
    private func type(_ digit: Int) { if accepts(digit) { text += String(digit) } }

    var body: some View {
        VStack(spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(text.isEmpty ? "\(current)" : text)
                    .font(.system(size: 34, weight: .semibold).monospacedDigit())
                    .foregroundStyle(text.isEmpty ? Color.secondary : Color.primary)
                Text("von \(count)").font(.callout).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(text.isEmpty ? "Seitenzahl eingeben, aktuell Seite \(current) von \(count)" : "Seite \(text) von \(count)")
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(58), spacing: 8), count: 3), spacing: 8) {
                ForEach(1..<10) { digit in key(digit) }
                Button { if !text.isEmpty { text.removeLast() } } label: {
                    Image(systemName: "delete.left").frame(width: 58, height: 46)
                }
                .buttonStyle(PageJumpKeyStyle())
                .keyboardShortcut(.delete, modifiers: [])
                .disabled(text.isEmpty)
                .accessibilityLabel("Löschen")
                key(0)
                Button(action: onGo) {
                    Text("Los").font(.headline).frame(width: 58, height: 46)
                }
                .buttonStyle(PageJumpKeyStyle(prominent: true))
                .keyboardShortcut(.defaultAction)
                .disabled(!valid)
                .accessibilityHint(valid ? "Springt zu Seite \(text)." : "Erst eine Seitenzahl von 1 bis \(count) eingeben.")
            }
        }
        .padding(14)
        // Escape on a hardware keyboard; tapping outside closes the popover too.
        .background {
            Button("Abbrechen", action: onCancel).keyboardShortcut(.cancelAction)
                .opacity(0).allowsHitTesting(false).accessibilityHidden(true)
        }
        .frame(width: 218)
        // The navigator styles its label white; the popover uses system colours.
        .foregroundStyle(.primary)
    }

    private func key(_ digit: Int) -> some View {
        Button { type(digit) } label: {
            Text("\(digit)").font(.title2.monospacedDigit()).frame(width: 58, height: 46)
        }
        .buttonStyle(PageJumpKeyStyle())
        .keyboardShortcut(KeyEquivalent(Character("\(digit)")), modifiers: [])
        .disabled(!accepts(digit))
    }
}

private struct PageJumpKeyStyle: ButtonStyle {
    var prominent = false
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(prominent ? Color.white : Color.primary)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(prominent ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.primary.opacity(configuration.isPressed ? 0.22 : 0.1))))
            .opacity(isEnabled ? (configuration.isPressed && prominent ? 0.8 : 1) : 0.35)
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// Shown instead of the notebook until the stored document is installed.
/// The indicator fades in late, so quick opens show only the dark background.
private struct NotebookLoadingView: View {
    var failed: Bool
    @State private var visible = false
    var body: some View {
        ZStack {
            Color.clear
            if failed {
                Text("Öffnen fehlgeschlagen").font(.callout).foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.regular).tint(Color(white: 0.6))
                    .opacity(visible ? 1 : 0)
                    .accessibilityLabel("Wird geöffnet")
            }
        }
        .allowsHitTesting(false)
        .onAppear { withAnimation(.easeOut(duration: 0.2).delay(0.3)) { visible = true } }
    }
}

private struct RestoredNotebookView: View {
    @StateObject private var model: EditorModel
    init(restored: RestoredNotebook) {
        _model = StateObject(wrappedValue: EditorModel(storageRoot: restored.directory,
                                                     restoreDirectory: restored.collectionDirectory,
                                                     preferredPageID: restored.preferredPageID))
    }
    var body: some View { ContentView(model: model, isRestoredCopy: true) }
}

/// Pages of the inactive view in its activation layer: the layer leaves them
/// open (even-odd hole) when they take the Pencil directly. Below the
/// header/palette strip (`top`), which keeps its activation tap. A plain
/// rect in the surface's coordinate space, read through `onPreferenceChange`,
/// so the layer itself is evaluated with the body (its pane state current).
private struct PaneWakeArea: PreferenceKey {
    /// `pages`: the open hole; `shields`: chrome above the pages (toolbar,
    /// options, page buttons, sidebar) that stays under the layer.
    struct Area: Equatable { var pages: CGRect? = nil; var shields: [CGRect] = [] }
    static let space = "noty.paneWake"
    static var defaultValue: Area { Area() }
    static func reduce(value: inout Area, nextValue: () -> Area) {
        let next = nextValue(); value.pages = value.pages ?? next.pages; value.shields += next.shields
    }
    static func pages(_ frame: CGRect, top: CGFloat) -> CGRect {
        CGRect(x: frame.minX, y: frame.minY + top, width: frame.width, height: max(0, frame.height - top))
    }
    /// Non-zero winding: the layer and the shields clockwise, the hole
    /// against it, so overlapping shields stay covered (even-odd would open
    /// their overlap). Rects come in the surface space, `origin` is the
    /// layer's own position there.
    struct Hole: Shape {
        var hole: CGRect?
        var shields: [CGRect] = []
        var origin: CGPoint = .zero
        func path(in rect: CGRect) -> Path {
            var path = Path()
            func add(_ area: CGRect, reversed: Bool) {
                let corners = [CGPoint(x: area.minX, y: area.minY), CGPoint(x: area.maxX, y: area.minY),
                               CGPoint(x: area.maxX, y: area.maxY), CGPoint(x: area.minX, y: area.maxY)]
                path.addLines(reversed ? corners.reversed() : corners); path.closeSubpath()
            }
            add(rect, reversed: false)
            guard let hole = hole?.offsetBy(dx: -origin.x, dy: -origin.y), hole.width > 0, hole.height > 0 else { return path }
            add(hole, reversed: true)
            for shield in shields {
                let local = shield.offsetBy(dx: -origin.x, dy: -origin.y).intersection(hole)
                if !local.isNull, local.width > 0, local.height > 0 { add(local, reversed: false) }
            }
            return path
        }
    }
}
private extension View {
    /// Chrome above the pages of a view: its activation layer keeps it covered
    /// while it is inactive (`PaneWakeArea`).
    func paneWakeShield() -> some View {
        background { GeometryReader { proxy in
            Color.clear.preference(key: PaneWakeArea.self, value: PaneWakeArea.Area(shields: [proxy.frame(in: .named(PaneWakeArea.space))]))
        } }
    }
}
