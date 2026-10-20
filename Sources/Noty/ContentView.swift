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
    var isPaneActive: () -> Bool = { true }
    var onActivatePane: (() -> Void)?
    var onCloseWorkspace: (() -> Void)?
    var onSecondView: (() -> Void)?
    @State private var selectedPageID: UUID?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var toolbox: ToolbarSettingsModel
    @Environment(\.editorSettings) private var editorSettings
    @Environment(\.searchIndexArea) private var searchIndexArea
    @State private var showingSettings = false
    @State private var editingDefaults = false
    @State private var addingPage = false
    @State private var exporting = false
    @State private var exportFile: ExportFile?
    @State private var exportType: UTType = .json
    @StateObject private var pdfExport = PDFExportJob()
    @State private var tool: EditorTool = .pen
    @State private var lastInkTool: EditorTool = .pen
    @State private var pencilPalette: PencilPalettePresentation?
    @State private var pencilSqueeze = PencilSqueezeTracker()
    /// Undo/redo changed another page: select it, scrolling only if it is not visible.
    @State private var revealRequest: PageRevealRequest?
    @State private var textInsertRequest = 0
    @State private var textFocus: TextFlowFocus?
    @State private var writingDraft = Page()
    @State private var fitRequest = 0
    @State private var showingHistory = false
    @State private var selectedLocalRevision: UUID?
    @AppStorage(AppSettingsKey.sidebarVisible) private var showingPages = true
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
    @State private var searchHighlight: PageRect?
    @State private var searchHighlightPageID: UUID?
    @State private var searchHighlightToken = 0
    @State private var pageEntry = false
    @State private var pageEntryText = ""
    @State private var recentNote: String?
    @State private var recentNoteToken = 0
    private var ruler: Bool {
        get { toolbox.preferences.ruler ?? false }
        nonmutating set { toolbox.preferences.ruler = newValue }
    }
    private var shapeOptions: ShapeToolOptions {
        get { ShapeToolOptions(kind: toolbox.preferences.shapeKind ?? .line, pattern: toolbox.preferences.shapePattern ?? .solid, filled: toolbox.preferences.shapeFilled ?? false) }
        nonmutating set { toolbox.preferences.shapeKind = newValue.kind; toolbox.preferences.shapePattern = newValue.pattern; toolbox.preferences.shapeFilled = newValue.filled }
    }
    @State private var selectionFilter = SelectionFilter()
    @State private var lassoMode = LassoMode.freeform
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
        NavigationStack {
            workspaceSurface.ignoresSafeArea(.keyboard, edges: .bottom).overlay {
                if !isPaneActive() {
                    Color.clear.contentShape(Rectangle()).onTapGesture { onActivatePane?(); model.pageIndex = currentPageIndex }
                        .accessibilityLabel("Diese Ansicht aktivieren").accessibilityAddTraits(.isButton)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            // Full-screen writing surface: no iPadOS status bar, home indicator auto-hides.
            .statusBarHidden(true)
            .persistentSystemOverlays(.hidden)
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
                          contentType: exportType, defaultFilename: "noty-\(exportType == .pdf ? "export" : "backup")-\(Date().formatted(.iso8601).replacingOccurrences(of: ":", with: "-"))") { result in
                switch result {
                case .success:
                    if exportType == .pdf { model.fileStatus = "PDF-Datei exportiert" }
                    else { model.backupExported() }
                case .failure(let error):
                    if exportType == .notyBackup { model.backupStatus = "Backup-Export nicht abgeschlossen" }
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
                }
            }
            .sheet(isPresented: $customizingTools) { ToolbarCustomizationView(settings: toolbox) }
            .sheet(isPresented: $showingSettings) { editorSettings?.make() }
            .sheet(isPresented: $editingDefaults) {
                NotebookDefaultsView(current: model.notebook.pageDefaults) { paper, color, scope in
                    guard model.setPageDefaults(paper: paper, color: color, convertEmptyPages: scope),
                          scope == .wholeNotebook else { return }
                    // The whole notebook now has this paper colour: a neutral pen
                    // or marker of the old contrast colour would write invisibly
                    // (white on white). Same direction-aware rule as the ink.
                    if let pen = PaperInkInversion.converted(toolbox.preferences.penColor, to: color) {
                        toolbox.preferences.penColor = pen
                    }
                    if let marker = PaperInkInversion.converted(toolbox.preferences.markerColor, to: color) {
                        toolbox.preferences.markerColor = marker
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
            .alert("Hinweis", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
                if model.saveFailed && model.writable {
                    Button("Erneut speichern") { model.save() }
                }
                Button("OK") { model.error = nil }
            } message: { Text(model.error ?? "") }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active { model.save(); toolbox.save() }
            }
            .onChange(of: toolbox.preferences) { _, _ in toolbox.save() }
            .onChange(of: model.fileStatus) { _, note in showRecentNote(note) }
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
            .onChange(of: tool) { _, value in if value != .text { textFocus = nil }; if value.isInk { lastInkTool = value } }
            .onChange(of: model.notebook.id) { _, _ in selectedPageID = model.page.id; searchHighlightPageID = model.page.id }
            .onAppear {
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
        .preference(key: EditorCommandsPreference.self, value: editorCommands)
    }

    /// App menu / ⌘ shortcuts of this pane while it is the active one.
    private var editorCommands: EditorCommandActions? {
        guard isPaneActive(), notebookLoaded else { return nil }
        let onDraft = currentPage.id == writingDraft.id
        // A second presentation over an open sheet would never appear.
        let presenting = contentSearch || showingSettings || editingDefaults || addingPage || customizingTools || showingHistory || model.openedRestore != nil
            || marginsPage != nil || exporting || importingImage || choosingPhoto || pageEntry
        return EditorCommandActions(owner: ObjectIdentifier(model), canEdit: canEdit && !presenting,
            canExportPage: model.writable && !onDraft, exporting: pdfExport.running,
            hasPrevious: onDraft || currentPageIndex > 0, hasNext: !onDraft && currentPageIndex < model.notebook.pages.count - 1,
            search: { if canEdit { contentSearch = true } }, save: { model.save() },
            exportNotebook: { startPDFExport(pageOnly: false) }, exportPage: { startPDFExport(pageOnly: true) },
            previousPage: { stepPage(-1) }, nextPage: { stepPage(1) })
    }

    private func markNotebookShown() {
        // Logged once per open (EditorOpenTrace de-duplicates events).
        EditorOpenTrace.mark("model loaded", "pages=\(model.notebook.pages.count)")
        fadeSearchHighlightLater()
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
        if let onCloseWorkspace { onCloseWorkspace(); return }
        Task { if await model.flushBeforeClosing() { _ = await toolbox.flush(); dismiss() } }
    }

    /// The durable editor is always child zero. The sidebar only changes its
    /// available viewport, which the UIKit zoom view already handles on rotation.
    private var workspaceSurface: some View {
        GeometryReader { geometry in
            let compact = geometry.size.width < 760
            let width = min(320, max(0, geometry.size.width - (compact ? 32 : 360)))
            ZStack(alignment: .trailing) {
                editorSurface.padding(.trailing, showingPages && !compact ? width : 0)
                if showingPages && compact {
                    Color.black.opacity(0.35).contentShape(Rectangle())
                        .onTapGesture { showingPages = false }
                        .transition(.opacity)
                        .accessibilityLabel("Seitenleiste schließen")
                        .accessibilityAddTraits(.isButton)
                }
                if showingPages {
                    Group {
                        if notebookLoaded {
                            PageSidebarView(model: model, selectedPageID: $selectedPageID, onBack: closeEditor, onCollapse: { showingPages = false },
                                onSelect: { if compact { showingPages = false } },
                                onMargins: { id in marginsPage = MarginPage(id: id) })
                        } else {
                            // Same width and tone while loading: no placeholder thumbnail, no layout jump.
                            Color(white: 0.065).ignoresSafeArea().accessibilityHidden(true)
                        }
                    }
                    .frame(width: width)
                    .transition(reduceMotion ? .opacity : .move(edge: .trailing).combined(with: .opacity))
                }
            }
            .animation(NotyMotion.panel(reduceMotion), value: showingPages)
        }
    }

    private var canEdit: Bool { model.writable && !model.busy && !model.mutationsPaused && isPaneActive() }

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
                    topObstruction: layout.topInset + (toolbarOptions && tool != .text && toolbox.preferences.effectiveDock == .top ? 60 : 0),
                    // A freely placed palette covers part of the page: the caret is kept clear of it.
                    obstructions: toolbox.preferences.effectiveDock == .floating ? [layout.frame.cgRect.offsetBy(dx: -layout.leftInset, dy: 0)] : [],
                    configuration: pageConfiguration, onSelect: { id in
                        HangProbe.hit("ContentView.onSelect")
                        guard canEdit else { return }; selectedPageID = id
                    }, onTransfer: transferContents(generation: model.pageContentGeneration),
                    onError: { model.error = $0 }, revealRequest: revealRequest,
                    laser: tool == .laser ? toolbox.preferences.laserStyle : nil)
                    .ignoresSafeArea(.container, edges: .bottom)
                    .padding(.bottom, layout.bottomInset + (toolbarOptions && tool != .text && toolbox.preferences.effectiveDock == .bottom ? 60 : 0))
                    .padding(.leading, layout.leftInset)
                    .padding(.trailing, layout.rightInset)
                }
                editorHeader(layout: layout)
                    .frame(height: 60)
                ToolbarPaletteHost(layout: layout, preferences: $toolbox.preferences, more: $toolbarMore,
                    secondView: onSecondView != nil, enabled: canEdit && toolbox.writable,
                    showingOptions: toolbarOptions && tool != .text, optionsWidth: optionsWidths[tool] ?? EditorToolOptions.preferredWidth(for: tool)) { axis in
                    palette(axis: axis)
                } options: {
                    EditorToolOptions(tool: $tool, preferences: $toolbox.preferences, showing: $toolbarOptions,
                        shapeOptions: Binding(get: { shapeOptions }, set: { shapeOptions = $0 }), selectionFilter: $selectionFilter, lassoMode: $lassoMode,
                        recognizeShapes: Binding(get: { recognizeShapes }, set: { recognizeShapes = $0 }),
                        onInsertText: { textInsertRequest += 1 },
                        onPhoto: { imageTarget = currentPage.id; choosingPhoto = true },
                        onImageFile: { imageTarget = currentPage.id; importingImage = true },
                        onPasteImage: { if currentPage.id == writingDraft.id { guard model.materializeDraft(draftPage) else { return } }; model.pasteImage(pageID: currentPage.id) },
                        onContentWidth: { width in if optionsWidths[tool] != width { optionsWidths[tool] = width } })
                }
                if notebookLoaded, canEdit, let pencilPalette {
                    PencilToolPalette(presentation: pencilPalette, tool: $tool, preferences: $toolbox.preferences, inkTool: lastInkTool,
                        canUndo: model.canUndo, canRedo: model.canRedo, onUndo: { performUndo(redo: $0) },
                        onSelect: selectFromPencilPalette, onDismiss: { dismissPencilPalette(pencilPalette.id) })
                        .id(pencilPalette.id).transition(.opacity.animation(.easeOut(duration: 0.1)))
                        .onDisappear { dismissPencilPalette(pencilPalette.id) }
                }
            }
            .ignoresSafeArea(.keyboard, edges: .bottom)
            .background(Color(uiColor: NotebookViewport.backdrop).ignoresSafeArea())
            .animation(NotyMotion.palette(reduceMotion), value: toolbox.preferences.dock)
            .overlay(alignment: .bottomTrailing) {
                if notebookLoaded {
                    pageNavigator.padding(.trailing, layout.rightInset + 14).padding(.bottom, layout.bottomInset + 16)
                }
            }
            .overlay(alignment: .bottom) {
                PDFExportProgressBadge(job: pdfExport).padding(.bottom, layout.bottomInset + 12)
                    .animation(NotyMotion.highlight(reduceMotion), value: pdfExport.progress == nil)
            }
            .overlay(alignment: .bottomLeading) {
                // Animation scoped to the pill: autosave updates elsewhere stay unanimated.
                ZStack(alignment: .bottomLeading) {
                    if notebookLoaded || !model.busy, let note = statusNote {
                        statusPill(note).padding(.leading, layout.leftInset + 12).padding(.bottom, layout.bottomInset + 12)
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
    @ViewBuilder private func statusPill(_ note: String) -> some View {
        let label = HStack(spacing: 6) {
            if model.saveFailed { Image(systemName: "exclamationmark.triangle.fill") }
            Text(note).lineLimit(2)
            if model.saveFailed && model.writable { Text("Erneut versuchen").fontWeight(.semibold) }
        }
        .font(.caption).foregroundStyle(model.saveFailed ? Color.orange : .secondary)
        .padding(.horizontal, 12).padding(.vertical, 7).background(.ultraThinMaterial, in: Capsule())
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
        recentNote = note; recentNoteToken += 1
        let token = recentNoteToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { if recentNoteToken == token { recentNote = nil } }
    }
    private func toolbarLayout(_ size: CGSize) -> ToolbarLayout {
        let count = ToolbarLayout.itemCount(more: toolbarMore, preferences: toolbox.preferences, secondView: onSecondView != nil)
        return ToolbarLayout(viewport: PageSize(width: size.width, height: size.height), dock: toolbox.preferences.effectiveDock,
            floatingAxis: toolbox.preferences.floatingAxis ?? .horizontal, items: count,
            headerItems: ToolbarLayout.itemCount(more: false, preferences: toolbox.preferences, secondView: onSecondView != nil),
            floatingX: toolbox.preferences.floatingX, floatingY: toolbox.preferences.floatingY)
    }
    private func palette(axis: ToolbarAxis) -> some View {
        EditorToolbar(tool: $tool, preferences: $toolbox.preferences,
            onFit: { fitRequest += 1 }, onCustomize: { customizingTools = true },
            onSearch: { contentSearch = true }, onSecondView: onSecondView,
            ruler: Binding(get: { ruler }, set: { ruler = $0 }),
            more: $toolbarMore, settings: $toolbarOptions, axis: axis)
    }

    private func editorHeader(layout: ToolbarLayout) -> some View {
        ZStack(alignment: .topLeading) {
            // Arrow and title form one button: tapping the name also leaves the notebook.
            Button(action: closeEditor) {
                HStack(spacing: 0) {
                    Image(systemName: "arrow.left").frame(width: 44, height: 44)
                    if layout.headerLeadingFrame.width >= 100, notebookLoaded {
                        Text(model.notebook.title).font(.subheadline.weight(.semibold)).lineLimit(1).truncationMode(.tail)
                            .padding(.trailing, 14)
                    }
                }.contentShape(Rectangle())
            }.accessibilityLabel("Zurück zu den Notizbüchern").accessibilityValue(notebookLoaded ? model.notebook.title : "")
                .padding(.horizontal, 4).frame(height: 44).notyGlass()
                .frame(maxWidth: max(52, layout.headerLeadingFrame.width), alignment: .leading)
                .frame(width: max(52, layout.headerLeadingFrame.width), height: 44, alignment: .leading)
                .offset(x: layout.headerLeadingFrame.x, y: layout.headerLeadingFrame.y)
            HStack(spacing: 0) {
                // Notebook-wide: the most recent change on any page, in order.
                Button { performUndo(redo: false) } label: {
                    NotyActionGlyph(kind: .undo).frame(width: 24, height: 24).frame(width: 44, height: 44).contentShape(Rectangle())
                        .opacity(model.canUndo ? 1 : 0.35)
                }.accessibilityLabel("Rückgängig").disabled(!model.canUndo)
                if layout.headerActionCount >= 4 {
                    Button { performUndo(redo: true) } label: {
                        NotyActionGlyph(kind: .redo).frame(width: 24, height: 24).frame(width: 44, height: 44).contentShape(Rectangle())
                            .opacity(model.canRedo ? 1 : 0.35)
                    }.accessibilityLabel("Wiederholen").disabled(!model.canRedo)
                }
                if layout.headerActionCount >= 5 {
                    Button { writingScroll.toggle() } label: {
                        Image(systemName: "arrow.left.and.right.square").frame(width: 44, height: 44)
                            .background(RoundedRectangle(cornerRadius: 10).fill(writingScroll ? Color.cyan.opacity(0.28) : .clear))
                            .contentShape(Rectangle())
                    }.accessibilityLabel("Schreibscrollen")
                        .accessibilityValue(writingScroll ? "Ein" : "Aus")
                        .accessibilityHint("Seitlich bis zur Blattmitte scrollen, um bequemer am Rand zu schreiben.")
                }
                optionsMenu(layout: layout)
                if !layout.compactHeader {
                    Menu { pageInsertionActions } label: {
                        Image(systemName: "doc.badge.plus").frame(width: 44, height: 44).contentShape(Rectangle())
                    }.accessibilityLabel("Neue Seite")
                }
                Button { showingPages.toggle() } label: {
                    Image(systemName: "sidebar.right").frame(width: 44, height: 44).contentShape(Rectangle())
                }.accessibilityLabel("Seitenübersicht rechts")
            }.padding(.horizontal, 4).frame(width: layout.headerActionsFrame.width, height: 44)
                .notyGlass().disabled(!canEdit)
                .offset(x: layout.headerActionsFrame.x, y: layout.headerActionsFrame.y)
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .buttonStyle(NotyToolStyle())
    }
    @ViewBuilder private var pageInsertionActions: some View {
        Button("Standardseite hinzufügen", systemImage: "doc.badge.plus") {
            let defaults = model.notebook.pageDefaults
            model.insertPaper(defaults.paper, color: defaults.color, relativeTo: anchorPageID)
        }
        Button("Papier oder PDF auswählen …", systemImage: "doc.on.doc") { addingPage = true }
    }

    private var pageNavigator: some View {
        VStack(spacing: 3) {
            Button { stepPage(-1) } label: { Image(systemName: "chevron.up").frame(width: 48, height: 44).contentShape(Rectangle()) }
                .disabled(currentPageIndex == 0 && currentPage.id != writingDraft.id)
                .foregroundStyle(currentPageIndex == 0 && currentPage.id != writingDraft.id ? Color.gray.opacity(0.5) : .white)
                .accessibilityLabel("Vorherige Seite")
            pageNumberButton
            Button { stepPage(1) } label: { Image(systemName: "chevron.down").frame(width: 48, height: 44).contentShape(Rectangle()) }
                .disabled(currentPage.id == writingDraft.id || currentPageIndex >= model.notebook.pages.count - 1)
                .foregroundStyle(currentPage.id == writingDraft.id || currentPageIndex >= model.notebook.pages.count - 1 ? Color.gray.opacity(0.5) : .white)
                .accessibilityLabel("Nächste Seite")
        }.padding(4).notyGlass().buttonStyle(NotyToolStyle()).disabled(!canEdit)
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
                Text(onDraft ? "+" : "\(currentPageIndex + 1)").font(.caption.weight(.semibold))
                Rectangle().fill(.secondary).frame(width: 16, height: 1)
                Text("\(count)").font(.caption)
            }.frame(width: 48, height: 40).contentShape(Rectangle())
        }
        .foregroundStyle(.white)
        .keyboardShortcut("g", modifiers: .command)
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
                Button("Im Notizbuch suchen", systemImage: "magnifyingglass") { contentSearch = true }
                if layout.compactHeader {
                    Menu("Seite hinzufügen", systemImage: "doc.badge.plus") { pageInsertionActions }
                }
                Menu("Teilen und exportieren", systemImage: "square.and.arrow.up") {
                    Section("PDF") {
                        Button("Diese Seite", systemImage: "doc") { startPDFExport(pageOnly: true) }
                            .disabled(!model.writable || currentPage.id == writingDraft.id || pdfExport.running)
                        Button("Ganzes Notizbuch", systemImage: "book.closed") { startPDFExport(pageOnly: false) }
                            .disabled(!model.writable || pdfExport.running)
                    }
                    Section(model.backupStatus) {
                        Button("Vollständiges Backup …", systemImage: "archivebox") { exportBackup() }
                            .disabled(!model.writable)
                    }
                }
            }
            Section {
                Menu("Ansicht", systemImage: "eye") {
                    Toggle("Schreibscrollen bis zur Blattmitte", systemImage: "arrow.left.and.right.square", isOn: $writingScroll)
                    Toggle("Blättern statt Scrollen", systemImage: "book.pages", isOn: Binding(get: { toolbox.preferences.paging ?? false }, set: { toolbox.preferences.paging = $0 }))
                    Toggle("PDFs einheitlich anzeigen", systemImage: "rectangle.split.3x1", isOn: Binding(get: { toolbox.preferences.normalizePageWidths ?? false }, set: { toolbox.preferences.normalizePageWidths = $0 }))
                        .accessibilityHint("Gleiche Arbeitsblattbreite mit Schreibraum daneben. Ändert nur die Anzeige.")
                }
                Button("Diese Seite anpassen …", systemImage: "arrow.up.left.and.down.right.and.arrow.up.right.and.down.left") {
                    marginsPage = MarginPage(id: currentPage.id)
                }.disabled(!canEdit || !model.notebook.pages.contains(where: { $0.id == currentPage.id })
                           || (model.sourcePage(for: currentPage) == nil && !currentPage.writingSpaceExtendsPaper))
                Button("Papier für neue Seiten …", systemImage: "doc.richtext") { editingDefaults = true }
                    .disabled(!canEdit)
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
            if let data = await model.backupData() {
                exportFile = ExportFile(backupData: data)
                exportType = .notyBackup
                exporting = true
            }
        }
    }
    /// Page by page with a progress badge; the snapshot is fixed at the start.
    private func startPDFExport(pageOnly: Bool) {
        guard canEdit, !pdfExport.running, !(pageOnly && currentPage.id == writingDraft.id) else { return }
        pdfExport.start(model.notebook, pageIDs: pageOnly ? [currentPage.id] : nil, sourcePage: { model.sourcePage(for: $0) }) { result in
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
        guard canEdit, let outcome = model.undo(redo: redo) else { return }
        if tool == .text, var focus = outcome.focus, model.notebook.pages.contains(where: { $0.id == focus.pageID }) {
            focus.requestID = UUID(); textFocus = focus
        }
        guard outcome.pageID != selectedPageID, model.notebook.pages.contains(where: { $0.id == outcome.pageID }) else { return }
        revealRequest = PageRevealRequest(pageID: outcome.pageID)
        selectedPageID = outcome.pageID
    }
    /// Pencil double tap / double squeeze: eraser ↔ the ink tool used before
    /// (pen, pencil or marker), honouring the eraser preference. From the laser
    /// pointer it returns straight to that ink tool.
    private func togglePencilEraser() {
        guard canEdit else { return }
        pencilPalette = nil
        if tool == .strokeEraser || tool == .precisionEraser || tool == .laser { tool = lastInkTool }
        else {
            if tool.isInk { lastInkTool = tool }
            tool = toolbox.preferences.eraserPrecision == true ? .precisionEraser : .strokeEraser
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
        case .toggle: togglePencilEraser()
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
        return PageEditor(sourcePage: sourcePage, layout: layout, pageID: page.id,
            drawing: page.drawing, textBoxes: page.effectiveTextBoxes, images: page.images ?? [], shapes: page.shapes ?? [],
            searchHighlight: searchHighlightPageID == page.id ? searchHighlight : nil, paper: page.paper ?? (sourcePage == nil ? .legacyTest : .blank),
            paperColor: page.paperColor ?? .white, margins: page.margins,
            tool: tool, color: tool == .marker
                ? UIColor(preferences.markerColor.color).withAlphaComponent(preferences.markerStrokeColor.alpha)
                : UIColor(preferences.inkColor(for: tool).color),
            width: preferences.inkWidth(for: tool) * page.inkWidthScale,
            enabled: canEdit, autoPen: preferences.automaticInk(for: tool),
            fingerDrawing: preferences.fingerDrawing, ruler: ruler, shapeOptions: shapeOptions, selectionFilter: selectionFilter, lassoMode: lassoMode,
            recognizeShapes: recognizeShapes, markerStraight: preferences.markerStraight ?? false, markerTip: preferences.effectiveMarkerTip, scribbleErase: preferences.scribbleErase ?? true,
            onPencilAction: { togglePencilEraser() },
            onPencilSqueeze: { handlePencilSqueeze($0) },
            onInteraction: { id, active in
                model.setInteraction(id, active: active)
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
                if let focus { textFocus = focus; selectedPageID = focus.pageID }
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
                guard isPaneActive(), model.pageContentGeneration == generation else { return }
                if page.id == writingDraft.id, !model.notebook.pages.contains(where: { $0.id == page.id }) {
                    guard let drawing = try? PKDrawing(data: data), !drawing.strokes.isEmpty else { return }
                    guard model.materializeDraft(draftPage) else { return }
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
                    .contentTransition(.numericText())
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
        .animation(.snappy(duration: 0.15), value: text)
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
                .fill(prominent ? Color.accentColor : Color.primary.opacity(configuration.isPressed ? 0.22 : 0.1)))
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
                Text("Notizbuch konnte nicht geöffnet werden").font(.callout).foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.regular).tint(Color(white: 0.6))
                    .opacity(visible ? 1 : 0)
                    .accessibilityLabel("Notizbuch wird geöffnet")
            }
        }
        .allowsHitTesting(false)
        .onAppear { withAnimation(.easeIn(duration: 0.2).delay(0.3)) { visible = true } }
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
