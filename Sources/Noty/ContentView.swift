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
    @State private var addingPage = false
    @State private var addingPDF = false
    @State private var pendingPDFAnchor: UUID?
    @State private var pendingPDFBefore = false
    @State private var importing = false
    @State private var importingBackup = false
    @State private var confirmingImport = false
    @State private var exporting = false
    @State private var exportFile: ExportFile?
    @State private var exportType: UTType = .json
    @State private var tool: EditorTool = .pen
    @State private var undoRequest = 0
    @State private var redoRequest = 0
    @State private var textInsertRequest = 0
    @State private var textFocus: TextFlowFocus?
    @State private var writingDraft = Page()
    @State private var fitRequest = 0
    @State private var showingHistory = false
    @State private var selectedLocalRevision: UUID?
    @State private var showingCopies = false
    @State private var selectedCopy: RestoredNotebook?
    @AppStorage("noty.sidebar.visible") private var showingPages = true
    @State private var customizingTools = false
    @State private var toolbarMore = false
    @State private var toolbarOptions = false
    @State private var marginsPage: MarginPage?
    @State private var importingImage = false
    @State private var choosingPhoto = false
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var imageTarget: UUID?
    @State private var contentSearch = false
    @State private var searchHighlight: PageRect?
    @State private var searchHighlightPageID: UUID?
    private var ruler: Bool {
        get { toolbox.preferences.ruler ?? false }
        nonmutating set { toolbox.preferences.ruler = newValue }
    }
    private var shapeOptions: ShapeToolOptions {
        get { ShapeToolOptions(kind: toolbox.preferences.shapeKind ?? .line, pattern: toolbox.preferences.shapePattern ?? .solid, filled: toolbox.preferences.shapeFilled ?? false) }
        nonmutating set { toolbox.preferences.shapeKind = newValue.kind; toolbox.preferences.shapePattern = newValue.pattern; toolbox.preferences.shapeFilled = newValue.filled }
    }
    @State private var selectionFilter = SelectionFilter()
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
            .sheet(isPresented: $addingPage, onDismiss: { if pendingPDFAnchor != nil { addingPDF = true } }) {
                AddPageSheet(position: .after, enabled: canEdit, defaults: model.notebook.appearance,
                    onPaper: { style, color, geometry, position in
                        let anchor = position == .end ? model.notebook.pages.last!.id : currentPage.id
                        model.insertPaper(style, color: color, relativeTo: anchor, before: position == .before, geometry: geometry)
                        addingPage = false
                    }, onPDF: { position in
                        pendingPDFAnchor = position == .end ? model.notebook.pages.last!.id : currentPage.id
                        pendingPDFBefore = position == .before; addingPage = false
                    })
            }
            .sheet(isPresented: $addingPDF, onDismiss: { pendingPDFAnchor = nil }) {
                PDFImportSheet(onImport: { url, margins in
                    if let anchor = pendingPDFAnchor { model.insertPDF(url, relativeTo: anchor, before: pendingPDFBefore, writingArea: margins) }
                }, onError: { model.error = $0 })
            }
            .confirmationDialog("Das aktuelle Testheft wird vor dem Import lokal archiviert. Für ein unabhängiges Backup vorher exportieren.",
                                isPresented: $confirmingImport, titleVisibility: .visible) {
                Button("Datei auswählen") { importing = true }
            }
            .fileImporter(isPresented: $importing,
                          allowedContentTypes: importingBackup ? [.notyBackup, .json, .data] : [.pdf]) { result in
                switch result {
                case .success(let url): model.importFile(url, backup: importingBackup)
                case .failure(let error): model.error = error.localizedDescription
                }
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
                if target == writingDraft.id { guard model.materializeDraft(draftPage) else { return } }
                model.insertPhoto(item, pageID: target)
                selectedPhoto = nil
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
            .fullScreenCover(item: $model.openedRestore, onDismiss: {
                Task { await model.refreshRestoredCopies() }
            }) { restored in
                RestoredNotebookView(restored: restored).id(restored.id)
            }
            .sheet(isPresented: $showingCopies, onDismiss: {
                if let copy = selectedCopy {
                    selectedCopy = nil
                    model.openedRestore = copy
                }
            }) {
                RestoredCopiesView(copies: model.restoredCopies) { copy in
                    selectedCopy = copy
                    showingCopies = false
                }
            }
            .sheet(isPresented: $contentSearch) {
                ContentSearchView(documents: [OpenNotebook(id: model.notebook.id, directory: model.storageRoot, title: model.notebook.title, isRestored: false)], current: model.notebook) { hit in
                    selectedPageID = hit.pageID; searchHighlight = hit.bounds; searchHighlightPageID = hit.pageID; fitRequest += 1
                }
            }
            .sheet(isPresented: $customizingTools) { ToolbarCustomizationView(settings: toolbox) }
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
            .onChange(of: model.pageIndex) { _, index in
                if isPaneActive(), model.notebook.pages.indices.contains(index) { selectedPageID = model.notebook.pages[index].id }
            }
            .onChange(of: model.notebook.pages.map(\.id)) { _, ids in
                if ids.contains(writingDraft.id) { writingDraft = Page() }
                if let selectedPageID, let index = ids.firstIndex(of: selectedPageID), isPaneActive() { model.pageIndex = index }
            }
            .onChange(of: selectedPageID) { _, _ in if isPaneActive() { model.pageIndex = currentPageIndex } }
            .onChange(of: model.pageContentGeneration) { _, _ in textFocus = nil; writingDraft = Page() }
            .onChange(of: tool) { _, value in if value != .text { textFocus = nil } }
            .onChange(of: model.notebook.id) { _, _ in selectedPageID = model.page.id; searchHighlightPageID = model.page.id }
            .onAppear { selectedPageID = model.page.id; searchHighlight = initialSearchBounds; searchHighlightPageID = model.page.id }
            // Managed editors flush before dismissal. A late onDisappear save
            // could otherwise race a new editor for the same package.
            .onDisappear { if !isLibraryDocument && !isRestoredCopy { model.save() } }
            .interactiveDismissDisabled(isLibraryDocument || isRestoredCopy)
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
                    PageSidebarView(model: model, selectedPageID: $selectedPageID, onBack: closeEditor, onCollapse: { showingPages = false },
                        onSelect: { if compact { showingPages = false } },
                        onMargins: { id in marginsPage = MarginPage(id: id) })
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
            let layout = toolbarLayout(geometry.size)
            ZStack(alignment: .topLeading) {
                NotebookEditor(pages: editorPages, selectedPageID: selectedPageID ?? currentPage.id,
                    paging: toolbox.preferences.paging ?? false, normalizeWidths: toolbox.preferences.normalizePageWidths ?? false,
                    fitRequest: fitRequest, textInsertRequest: textInsertRequest, textFocus: textFocus,
                    enabled: canEdit, fingerDrawing: toolbox.preferences.fingerDrawing,
                    configuration: pageConfiguration, onSelect: { id in
                        guard canEdit else { return }; selectedPageID = id
                    })
                    .padding(.top, layout.topInset + (toolbarOptions && tool != .text && toolbox.preferences.effectiveDock == .top ? 60 : 0))
                    .padding(.bottom, layout.bottomInset + (toolbarOptions && tool != .text && toolbox.preferences.effectiveDock == .bottom ? 60 : 0))
                    .padding(.leading, layout.leftInset)
                    .padding(.trailing, layout.rightInset)
                editorHeader(layout: layout)
                    .frame(height: 60)
                ToolbarPaletteHost(layout: layout, preferences: $toolbox.preferences, more: $toolbarMore,
                    secondView: onSecondView != nil, enabled: canEdit && toolbox.writable,
                    showingOptions: toolbarOptions && tool != .text, optionsWidth: EditorToolOptions.preferredWidth(for: tool)) { axis in
                    palette(axis: axis)
                } options: {
                    EditorToolOptions(tool: $tool, preferences: $toolbox.preferences, showing: $toolbarOptions,
                        shapeOptions: Binding(get: { shapeOptions }, set: { shapeOptions = $0 }), selectionFilter: $selectionFilter,
                        recognizeShapes: Binding(get: { recognizeShapes }, set: { recognizeShapes = $0 }),
                        onInsertText: { textInsertRequest += 1 },
                        onPhoto: { imageTarget = currentPage.id; choosingPhoto = true },
                        onImageFile: { imageTarget = currentPage.id; importingImage = true },
                        onPasteImage: { if currentPage.id == writingDraft.id { guard model.materializeDraft(draftPage) else { return } }; model.pasteImage(pageID: currentPage.id) })
                }
            }
            .ignoresSafeArea(.keyboard, edges: .bottom)
            .animation(NotyMotion.palette(reduceMotion), value: toolbox.preferences.dock)
            .overlay(alignment: .bottomTrailing) {
                pageNavigator.padding(.trailing, layout.rightInset + 14).padding(.bottom, layout.bottomInset + 16)
            }
            .overlay(alignment: .bottomLeading) {
                Text(model.status).font(.caption2).foregroundStyle(model.saveFailed ? Color.orange : .secondary)
                    .padding(.horizontal, 10).padding(.vertical, 5).background(.ultraThinMaterial, in: Capsule())
                    .padding(.leading, layout.leftInset + 12).padding(.bottom, layout.bottomInset + 12)
                    .accessibilityIdentifier("saveStatus").allowsHitTesting(false)
            }
        }
    }
    private func toolbarLayout(_ size: CGSize) -> ToolbarLayout {
        let count = ToolbarLayout.itemCount(more: toolbarMore, presets: toolbox.preferences.presets.count, secondView: onSecondView != nil)
        return ToolbarLayout(viewport: PageSize(width: size.width, height: size.height), dock: toolbox.preferences.effectiveDock,
            floatingAxis: toolbox.preferences.floatingAxis ?? .horizontal, items: count,
            headerItems: ToolbarLayout.itemCount(more: false, presets: toolbox.preferences.presets.count, secondView: onSecondView != nil),
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
            HStack(spacing: 4) {
                Button(action: closeEditor) {
                    Image(systemName: "arrow.left").frame(width: 44, height: 44).contentShape(Rectangle())
                }.accessibilityLabel("Zurück zu den Notizbüchern")
                Text(model.notebook.title).font(.subheadline.weight(.semibold)).lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.frame(width: layout.headerLeadingFrame.width, height: 44)
                .offset(x: layout.headerLeadingFrame.x, y: layout.headerLeadingFrame.y)
            HStack(spacing: 0) {
                Button { undoRequest += 1 } label: {
                    Image(systemName: "arrow.uturn.backward").frame(width: 44, height: 44).contentShape(Rectangle())
                }.accessibilityLabel("Rückgängig")
                if layout.headerActionCount >= 4 {
                    Button { redoRequest += 1 } label: {
                        Image(systemName: "arrow.uturn.forward").frame(width: 44, height: 44).contentShape(Rectangle())
                    }.accessibilityLabel("Wiederholen")
                }
                fileMenu
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
            let defaults = model.notebook.appearance ?? NotebookAppearance()
            model.insertPaper(defaults.paper, color: defaults.color, relativeTo: currentPage.id)
        }
        Button("Papier oder PDF auswählen", systemImage: "plus") { addingPage = true }
    }

    private var pageNavigator: some View {
        VStack(spacing: 3) {
            Button { if currentPage.id == writingDraft.id { selectedPageID = model.notebook.pages.last?.id } else { currentPageIndex -= 1 } } label: { Image(systemName: "chevron.up").frame(width: 48, height: 44).contentShape(Rectangle()) }
                .disabled(currentPageIndex == 0 && currentPage.id != writingDraft.id).accessibilityLabel("Vorherige Seite")
            Text(currentPage.id == writingDraft.id ? "+" : "\(currentPageIndex + 1)").font(.caption.weight(.semibold))
            Rectangle().fill(.secondary).frame(width: 16, height: 1)
            Text("\(model.notebook.pages.count)").font(.caption)
            Button {
                if currentPageIndex == model.notebook.pages.count - 1, model.notebook.pages.count < 500 { selectedPageID = writingDraft.id }
                else { currentPageIndex += 1 }
            } label: { Image(systemName: "chevron.down").frame(width: 48, height: 44).contentShape(Rectangle()) }
                .disabled(currentPage.id == writingDraft.id || (model.notebook.pages.count == 500 && currentPageIndex == 499)).accessibilityLabel("Nächste Seite oder neue Schreibseite")
        }.padding(4).notyGlass().buttonStyle(NotyToolStyle()).disabled(!canEdit)
    }
    private var fileMenu: some View {
        Menu {
            Text(model.status)
            if model.saveFailed { Button("Erneut speichern") { model.save() } }
            Text(model.backupStatus)
            if let status = model.fileStatus { Text(status) }
            if !toolbox.status.isEmpty { Text(toolbox.status) }
            Divider()
            Button("Rückgängig", systemImage: "arrow.uturn.backward") { undoRequest += 1 }
            Button("Wiederholen", systemImage: "arrow.uturn.forward") { redoRequest += 1 }
            Menu("Seite hinzufügen", systemImage: "doc.badge.plus") { pageInsertionActions }
            Divider()
            Toggle("Blättern statt vertikal scrollen", isOn: Binding(get: { toolbox.preferences.paging ?? false }, set: { toolbox.preferences.paging = $0 }))
            Toggle("PDFs einheitlich anzeigen", isOn: Binding(get: { toolbox.preferences.normalizePageWidths ?? false }, set: { toolbox.preferences.normalizePageWidths = $0 }))
                .accessibilityHint("Gleiche Arbeitsblattbreite mit Schreibraum daneben. Ändert nur die Anzeige.")

                        Button("Im Heft suchen") { contentSearch = true }.keyboardShortcut("f", modifiers: .command)
                        Button("Jetzt speichern") { model.save() }.keyboardShortcut("s", modifiers: .command)
                        Button("Lokale Wiederherstellungspunkte") { showingHistory = true }
                            .disabled(!model.writable)
                        if !isRestoredCopy && !isLibraryDocument {
                            Button("PDF importieren") { importingBackup = false; confirmingImport = true }
                                .disabled(!model.writable)
                        }
                        if !isRestoredCopy && !isLibraryDocument {
                            Button("Backup als Kopie wiederherstellen") { importingBackup = true; importing = true }
                            if !model.restoredCopies.isEmpty {
                                Button("Wiederhergestellte Kopien") { showingCopies = true }
                            }
                        }
                        Button("Vollständiges Heft-Backup exportieren") {
                            Task {
                                if let data = await model.backupData() {
                                    exportFile = ExportFile(backupData: data)
                                    exportType = .notyBackup
                                    exporting = true
                                }
                            }
                        }
                        .disabled(!model.writable)
                        Button("Aktuelle Seite als PDF exportieren") {
                            do {
                                exportFile = ExportFile(pdfData: try PDFExporter.render(model.notebook, pageIDs: [currentPage.id]))
                                exportType = .pdf; exporting = true
                            } catch { model.error = error.localizedDescription }
                        }.disabled(!model.writable)
                        Button("Ganzes Heft als PDF exportieren") {
                            do {
                                exportFile = ExportFile(pdfData: try PDFExporter.render(model.notebook))
                                exportType = .pdf
                                exporting = true
                            } catch { model.error = error.localizedDescription }
                        }
                        .disabled(!model.writable)

        } label: { Image(systemName: "ellipsis.circle").frame(width: 44, height: 44).contentShape(Rectangle()) }.accessibilityLabel("Optionen und Export")
    }
    private func pageConfiguration(_ page: Page) -> PageEditor {
        let sourcePage = model.sourcePage(for: page)
        let layout = (try? PageLayout(page: page, source: sourcePage?.pageRef)) ?? model.pageLayout
        let generation = model.pageContentGeneration
        let preferences = toolbox.preferences
        return PageEditor(sourcePage: sourcePage, layout: layout, pageID: page.id,
            drawing: page.drawing, textBoxes: page.effectiveTextBoxes, images: page.images ?? [], shapes: page.shapes ?? [],
            searchHighlight: searchHighlightPageID == page.id ? searchHighlight : nil, paper: page.paper ?? .legacyTest,
            paperColor: page.paperColor ?? .white, margins: page.margins,
            tool: tool, color: UIColor((tool == .marker ? preferences.markerColor : preferences.penColor).color),
            width: tool == .marker ? preferences.markerWidth : tool == .precisionEraser ? preferences.eraserWidth : preferences.penWidth,
            enabled: canEdit, autoPen: preferences.autoPen ?? false, pencilPreview: preferences.pencilPreview ?? true,
            fingerDrawing: preferences.fingerDrawing, ruler: ruler, shapeOptions: shapeOptions, selectionFilter: selectionFilter,
            recognizeShapes: recognizeShapes,
            onPencilAction: { if canEdit { tool = tool == .strokeEraser ? .pen : .strokeEraser } },
            onInteraction: { id, active in
                model.setInteraction(id, active: active)
            },
            undoRequest: undoRequest, redoRequest: redoRequest, fitRequest: fitRequest, contentGeneration: generation,
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
                if let focus = model.undoFlowText(redo: redo) { textFocus = focus; selectedPageID = focus.pageID }
            },
            onFlowBackspace: { box in
                guard isPaneActive(), model.pageContentGeneration == generation else { return }
                if let focus = model.backspaceFlowText(pageID: page.id, box: box) { textFocus = focus; selectedPageID = focus.pageID }
            },
            readTextBoxes: { model.notebook.pages.first(where: { $0.id == page.id })?.effectiveTextBoxes ?? (page.id == writingDraft.id ? writingDraft.effectiveTextBoxes : []) },
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
            })
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
