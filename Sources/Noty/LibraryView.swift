import SwiftUI
import UniformTypeIdentifiers
import NotebookCore

/// Shown location; notebooks open the editor instead. The calendar is not a
/// location but a mode beside the whole library (`showsCalendar`): returning
/// shows the folder that was open before (docs/CALENDAR-PLAN.md, „Umschalter
/// Bibliothek/Kalender“).
private enum LibraryLocation: Hashable {
    case root, folder(UUID), recent
}

/// Files-like library: sidebar with pinned entries and the persisted
/// folder/notebook tree, the selected folder's contents on the right.
struct LibraryView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The window's size class (inside the split view the sidebar column may
    /// report compact although the window is wide).
    @Environment(\.horizontalSizeClass) private var sizeClass
    @ObservedObject var model: LibraryModel
    @ObservedObject var workspaces: WorkspaceAppModel
    @EnvironmentObject private var externalBackup: ExternalBackupModel
    @EnvironmentObject private var toolbox: ToolbarSettingsModel
    @AppStorage(AppSettingsKey.homeLayout) private var layout = LibraryLayout.grid
    @AppStorage(AppSettingsKey.librarySort) private var sort = LibrarySort.manual
    @State private var location: LibraryLocation = .root
    @State private var search = ""
    /// Documents travel with the presentation; a separate `@State` list read
    /// only inside `sheet(isPresented:)` was stale (empty) on the first open.
    @State private var contentSearch: NotebookChoiceList?
    @State private var searchHit: ContentSearchHit?
    @State private var importingPDF = false
    @State private var importingBackup = false
    @State private var showingName = false
    @State private var creatingNotebook = false
    @State private var creatingTextDocument = false
    @State private var libraryEditMode: EditMode = .inactive
    @State private var name = ""
    /// Keyboard mode: the item `hjkl` stands on.
    @State private var keyboardFocus: UUID?
    @State private var nameAction = NameAction.folder
    @State private var moving: NotebookCore.LibraryItem?
    @State private var trashing: NotebookCore.LibraryItem?
    @State private var showingCopies = false
    @State private var selectedCopy: RestoredNotebook?
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    /// Hefte ⇄ Kalender (switch at the top left, ⇧⌘K). The calendar hides the
    /// library sidebar; leaving it restores the visibility from before.
    @State private var showsCalendar = false
    @State private var visibilityBeforeCalendar: NavigationSplitViewVisibility?
    @Namespace private var modeSwitchSpace
    /// Width of the whole split view; with `detailWidth` it tells whether the
    /// library sidebar stands beside the content (`sidebarBeside`).
    @State private var splitWidth: CGFloat = 0
    /// Split width at which the sidebar stood beside the content when the
    /// calendar was shown (nil: it did not).
    @State private var besideBeforeCalendar: CGFloat?
    /// Hefte ← Kalender with the sidebar coming back beside (same window
    /// width as before): the switch moves into it with the switching
    /// transaction instead of a frame later, when the width is measured.
    /// Ends with that measurement, at the latest after 0.6 s.
    @State private var sidebarReturning = false
    /// Shown by tap: the calendar counts as visible (WebUntis/EventKit refresh,
    /// waiting notification) only after the glide, so no result rebuilds it mid-way.
    @State private var calendarRevealDelay: TimeInterval = 0
    /// „Hefte | Kalender“ in the sidebar's bar beside the system button: the
    /// words from 260 pt sidebar width, with symbols from 330 pt, below only
    /// the symbols (Dynamic Type scales both with the words).
    @ScaledMetric(relativeTo: .subheadline) private var switchTitlesWidth: CGFloat = 260
    @ScaledMetric(relativeTo: .subheadline) private var switchFullWidth: CGFloat = 330
    @State private var showingAreas = false
    @State private var selectedArea: TestWorkspace?
    @State private var switchingArea = false
    @State private var settingsRequest: SettingsRequest?
    /// Hint or verified result of the toolbar backup; its failures arrive in `externalBackup.error`.
    /// Current drag & drop preview (insertion line or highlighted folder).
    @State private var dropMark: DropMark?
    /// Entry dragged from this library (for hiding invalid targets while hovering).
    @State private var dragging: UUID?
    @State private var frames = DropFrames()
    @State private var sidebarSize = CGSize(width: 280, height: 600)
    @State private var detailSize = CGSize(width: 600, height: 600)
    /// Width of the detail column (both sides): the calendar sidebar button.
    @State private var detailWidth: CGFloat = 0
    @StateObject private var pdfExport = PDFExportJob()
    /// Calendar of this area, owned by the host (per area): switching to the calendar and back keeps both.
    @ObservedObject var calendar: CalendarModel
    @State private var exportedPDF: ExportFile?
    @State private var exportingPDF = false
    @State private var exportedPDFName = "noty-export"

    private enum NameAction { case folder, rename(UUID) }
    private var parentID: UUID? { if case .folder(let id) = location { return id }; return nil }
    /// Background work (refresh after closing a notebook, automatic backup)
    /// keeps the library interactive and visually unchanged.
    private var editable: Bool {
        model.ready && model.opened == nil && !workspaces.busy && (!model.busy || model.backgroundBusy)
    }
    /// Menu shortcuts pause while a sheet/dialog is shown: a second presentation would not appear.
    private var presenting: Bool {
        creatingNotebook || creatingTextDocument || settingsRequest != nil || contentSearch != nil || moving != nil || showingAreas || showingCopies
            || showingName || trashing != nil || importingPDF || importingBackup || exportingPDF
    }
    private var normalFolder: Bool { location == .root || parentID != nil }
    /// Manual drag order is only meaningful for the unsorted contents of one folder.
    private var canReorder: Bool { normalFolder && search.isEmpty && sort == .manual }
    private var errorShown: Binding<Bool> {
        Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })
    }
    private var backupMessage: String? { externalBackup.error }
    /// New items land in the open folder or „Alle Unterlagen“; „Zuletzt
    /// verwendet“ or a running search would hide them.
    private func showNewItem() {
        search = ""
        if location == .recent { location = .root }
        if showsCalendar { setCalendar(false, animated: false) }
    }
    private var activeCopies: [RestoredNotebook] {
        model.restoredCopies.compactMap { copy -> RestoredNotebook? in
            guard let item = model.snapshot.items.first(where: { $0.id == copy.id }), !model.snapshot.isTrashed(copy.id) else { return nil }
            var result = copy; result.title = item.title; return result
        }
    }
    private var title: String {
        switch location {
        case .root: "Alle Unterlagen"
        case .folder(let id): model.snapshot.items.first { $0.id == id }?.title ?? "Ordner"
        case .recent: "Zuletzt verwendet"
        }
    }
    private var rows: [NotebookCore.LibraryItem] {
        let value = model.snapshot
        let candidates: [NotebookCore.LibraryItem]
        if !search.isEmpty {
            // Global name search; content search (PDF/typed text) has its own sheet.
            candidates = value.items.filter { !value.isTrashed($0.id) }
        } else {
            switch location {
            case .root, .folder: candidates = value.children(of: parentID)
            case .recent:
                return value.items.filter { !$0.isFolder && $0.lastOpened != nil && !value.isTrashed($0.id) }
                    .sorted { ($0.lastOpened ?? .distantPast) > ($1.lastOpened ?? .distantPast) }
            }
        }
        return sort.apply(candidates.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) })
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
        } detail: {
            detail
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { splitWidth = $0 }
        .animation(NotyMotion.panel(reduceMotion), value: libraryEditMode)
        .environment(\.editMode, $libraryEditMode)
        .background(KeyboardHost().frame(width: 0, height: 0).accessibilityHidden(true))
        .overlay { KeyboardOverlay(scope: .library) }
        .onChange(of: model.opened == nil && !presenting, initial: true) { _, free in
            KeyboardRouter.shared.setLibrary(free ? LibraryKeyActions(run: { runKey($0, count: $1 ?? 1) }, commands: { keyCommands }) : nil)
        }
        .sheet(isPresented: $creatingNotebook) {
            NotebookCreationView(defaultAppearance: toolbox.preferences.defaultAppearance) { title, appearance in
                let created = await model.createNotebook(title, appearance: appearance, parent: parentID)
                if created { showNewItem() }
                return created
            }.alert("Bibliothek", isPresented: errorShown) {
                Button("OK") { model.error = nil }
            } message: { Text(model.error ?? "") }
        }
        .sheet(isPresented: $creatingTextDocument) {
            TextDocumentCreationView(defaultAppearance: toolbox.preferences.defaultAppearance) { title, landscape, paper, color in
                let created = await model.createTextDocument(title, landscape: landscape, paper: paper, color: color, parent: parentID)
                if created { showNewItem() }
                return created
            }.alert("Bibliothek", isPresented: errorShown) {
                Button("OK") { model.error = nil }
            } message: { Text(model.error ?? "") }
        }
        .fullScreenCover(item: $settingsRequest, onDismiss: switchAreaIfRequested) { request in
            SettingsView(library: model, toolbox: toolbox, externalBackup: externalBackup, workspaces: workspaces,
                         calendar: calendar, initialPage: request.page) { area in
                selectedArea = area; switchingArea = true; settingsRequest = nil
            }
        }
        .sheet(item: $contentSearch, onDismiss: {
            if let hit = searchHit, let item = model.snapshot.items.first(where: { $0.id == hit.documentID }) {
                searchHit = nil; Task { await model.open(item, pageID: hit.pageID, searchBounds: hit.bounds, flowRange: hit.flowRange) }
            }
        }) { search in
            ContentSearchView(documents: search.documents, area: StableDefaults.scope(model.root), retain: search.retain) { searchHit = $0 }
        }
        // Closing a notebook updates the library in place (no visible reload).
        .fullScreenCover(item: $model.opened, onDismiss: {
            model.editorClosed()
            if KeyboardRouter.shared.searchAllAfterClosing { KeyboardRouter.shared.searchAllAfterClosing = false; searchAllNotebooks() }
        }) { document in
            LibraryNotebookView(document: document, root: model.root, library: model).id(document.id)
                .environment(\.searchIndexArea, StableDefaults.scope(model.root))
                .publishesEditorCommands()
                .overlay { KeyboardOverlay(scope: .editor) }
                .environment(\.editorSettings, EditorSettingsPresenter { [model, toolbox, externalBackup, workspaces, calendar] in
                    AnyView(SettingsView(library: model, toolbox: toolbox, externalBackup: externalBackup, workspaces: workspaces,
                                         calendar: calendar))
                })
        }
        .sheet(item: $moving) { item in
            MoveDestinationView(item: item, snapshot: model.snapshot) { destination in
                moving = nil
                Task { await model.move(item.id, to: destination) }
            }
        }
        .sheet(isPresented: $showingAreas, onDismiss: switchAreaIfRequested) {
            WorkspacePickerView(model: workspaces) { area in
                selectedArea = area; switchingArea = true; showingAreas = false
            }
        }
        .sheet(isPresented: $showingCopies, onDismiss: {
            if let copy = selectedCopy, let item = model.snapshot.items.first(where: { $0.id == copy.id }) {
                selectedCopy = nil
                Task { await model.open(item, pageID: copy.preferredPageID) }
            }
        }) {
            RestoredCopiesView(copies: activeCopies) { copy in
                selectedCopy = copy; showingCopies = false
            }
        }
        .alert(nameTitle, isPresented: $showingName) {
            TextField("Name", text: $name)
            Button("Abbrechen", role: .cancel) { }
            // Same rule as the store (1…120 characters): a pasted overlong name must not be lost after saving.
            Button("Speichern") { submitName() }.disabled((try? LibraryStore.validTitle(name)) == nil)
                .keyboardShortcut(.defaultAction)
        } message: {
            // The reason a greyed-out „Speichern“ has (ZWJ emoji, soft hyphen, length).
            if let problem = NotyText.titleProblem(name) { Text(problem) }
        }
        .confirmationDialog("In den Papierkorb verschieben?", isPresented: Binding(
            get: { trashing != nil }, set: { if !$0 { trashing = nil } }), titleVisibility: .visible) {
            if let item = trashing {
                // Fixed verb: a long title in the button label would truncate the action away.
                Button("In den Papierkorb", role: .destructive) {
                    Task { await model.trash(item.id) }
                    trashing = nil
                }
            }
        } message: {
            Text(trashing.map { "\(NotyText.quoted($0.title)) wird in den Papierkorb verschoben. " } ?? "") + Text(Self.trashNote)
        }
        .sheet(isPresented: $importingPDF) {
            PDFImportSheet(defaults: toolbox.preferences.defaultAppearance, onImport: { url, margins in
                let access = url.startAccessingSecurityScopedResource()
                Task {
                    await model.importPDF(url, parent: parentID, writingArea: margins)
                    showNewItem()
                    if access { url.stopAccessingSecurityScopedResource() }
                }
            }, onError: { model.error = $0 })
        }
        .fileImporter(isPresented: $importingBackup, allowedContentTypes: [.noty, .notyBackup, .json, .data]) { result in
            switch result {
            case .success(let url): Task { if await model.importBackup(url, parent: parentID) != nil { showNewItem() } }
            case .failure(let error): model.error = error.localizedDescription
            }
        }
        // The creation sheets show errors over themselves, this one would wait behind them.
        .alert("Bibliothek", isPresented: Binding(get: { model.error != nil && settingsRequest == nil && !creatingNotebook && !creatingTextDocument }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }.keyboardShortcut(.defaultAction)
        } message: { Text(model.error ?? "") }
        // Settings and the area sheet show these errors themselves.
        .alert("Bereiche", isPresented: Binding(get: { workspaces.error != nil && settingsRequest == nil && !showingAreas }, set: { if !$0 { workspaces.error = nil } })) {
            Button("OK") { workspaces.error = nil }.keyboardShortcut(.defaultAction)
        } message: { Text(workspaces.error ?? "") }
        // Settings shows backup errors itself, also over the editor; this one reports the toolbar backup.
        .alert("Backup", isPresented: Binding(get: { backupMessage != nil && !presenting && model.opened == nil }, set: { if !$0 { externalBackup.error = nil } })) {
            Button("OK") { externalBackup.error = nil }.keyboardShortcut(.defaultAction)
        } message: { Text(backupMessage ?? "") }
        .onChange(of: location) { _, value in
            search = ""; libraryEditMode = .inactive
            if case .folder(let id) = value { reveal(id) }
        }
        // Search or another sort removes the „Fertig“ button with `canReorder`:
        // editing must not stay on without a way out.
        .onChange(of: canReorder) { _, reorder in if !reorder { libraryEditMode = .inactive } }
        // A tapped calendar notification or bell entry shows the calendar (not over an open notebook).
        .onChange(of: calendar.openRequest) { _, _ in if model.opened == nil { setCalendar(true, animated: false) } }
        // The calendar asks WebUntis and keeps its note only while it is the
        // shown side: set here from the switch itself (the calendar view's own
        // appear/disappear came late after a quick back and forth). Shown by
        // tap it counts only after the glide (`calendarRevealDelay`, task below).
        .onChange(of: showsCalendar) { _, shown in if !shown || calendarRevealDelay == 0 { calendar.visible = shown } }
        .task(id: showsCalendar && calendarRevealDelay > 0) {
            guard showsCalendar, calendarRevealDelay > 0 else { return }
            try? await Task.sleep(for: .seconds(calendarRevealDelay))
            if !Task.isCancelled && showsCalendar { calendar.visible = true }
        }
        .onAppear { calendar.visible = showsCalendar }
        .onDisappear { calendar.visible = false }
        // The prediction of `sidebarReturning` ends with the measured width,
        // or – when the sidebar did not come back beside – after 0.6 s.
        .onChange(of: detailWidth) { _, _ in if sidebarReturning { sidebarReturning = false } }
        .task(id: sidebarReturning) {
            guard sidebarReturning else { return }
            try? await Task.sleep(for: .seconds(0.6))
            if !Task.isCancelled { sidebarReturning = false }
        }
        // No sheet changes with these alerts: the keys have to come back by themselves.
        .onChange(of: model.error == nil && workspaces.error == nil && backupMessage == nil) { _, _ in KeyboardRouter.shared.reclaim() }
        .onChange(of: model.snapshot) { _, _ in leaveUnavailableFolder() }
        .publishesLibraryCommands(model.opened == nil && !presenting ? LibraryCommandActions(
            newNotebook: editable ? { creatingNotebook = true } : nil,
            search: editable ? { searchAllNotebooks() } : nil,
            newTextDocument: editable ? { creatingTextDocument = true } : nil,
            newEvent: showsCalendar ? { calendar.requestNewEvent() } : nil,
            toggleCalendar: canSwitchMode ? { setCalendar(!showsCalendar, animated: false) } : nil,
            showsCalendar: showsCalendar) : nil)
    }

    // MARK: Hefte ⇄ Kalender

    /// The event window and the event form are modal over the calendar: its
    /// note commits only when the window closes (`selection = nil`), so the
    /// calendar does not go away beneath them; neither under its own sheets,
    /// popovers and dialogs (`presentingOverlays`, set by `CalendarView`).
    private var canSwitchMode: Bool {
        !showsCalendar || (calendar.selectedEvent == nil && calendar.draft == nil && calendar.enlargedDraft == nil
                           && calendar.pendingSeriesChange == nil && !calendar.presentingOverlays)
    }

    /// Calendar keys only while nothing of the library is presented above it
    /// (a notebook, sheets, dialogs, alerts) and nothing of its own.
    private var calendarKeysActive: Bool {
        model.opened == nil && !presenting && model.error == nil && workspaces.error == nil && backupMessage == nil
            && !calendar.presentingOverlays
    }

    /// Tapping (switch, sidebar): ONE motion (`NotyMotion.modeSwitch`,
    /// 0.45 s without overshoot, user request 08.11.2026) – the content
    /// cross-fades with a 20-pt shift (`NotyMotion.modeTransition`) while the
    /// library sidebar collapses (or comes back), the switch changes its bar
    /// and its marker slides. ⇧⌘K, the command palette and a notification:
    /// at once. Reduce Motion: the column changes at once, the content only
    /// cross-fades (0.2 s).
    /// When the column moves by tap, it follows one frame later
    /// (`columnLag`): the system sidebar button must already be gone (→
    /// Kalender) or back in the detail bar (→ Hefte) when the split view
    /// starts its column animation. In the same update the detail bar kept
    /// the removed button's place for the whole glide (Build 142, landscape:
    /// calendar sidebar button and switch ≈ 55 pt too far right until the
    /// sidebar was gone, then a jump to the edge).
    private func setCalendar(_ shown: Bool, animated: Bool) {
        guard shown != showsCalendar, shown || canSwitchMode else { return }
        // Never force the sidebar open (portrait would cover the content):
        // a hidden one stays hidden, otherwise the system places it as it
        // does by itself.
        let target: NavigationSplitViewVisibility = shown || visibilityBeforeCalendar == .detailOnly ? .detailOnly : .automatic
        let returning = !shown && target != .detailOnly && besideBeforeCalendar == splitWidth
        let prepare = {
            if shown {
                search = ""; libraryEditMode = .inactive; keyboardFocus = nil
                visibilityBeforeCalendar = columnVisibility
                besideBeforeCalendar = switchInSidebar ? splitWidth : nil
                sidebarReturning = false
            }
        }
        let column = {
            columnVisibility = target
            if !shown {
                sidebarReturning = returning
                visibilityBeforeCalendar = nil
                besideBeforeCalendar = nil
            }
        }
        calendarRevealDelay = animated ? NotyMotion.modeSwitchDuration(reduceMotion) : 0
        if !animated {
            NotyMotion.instant { prepare(); column(); showsCalendar = shown }
        } else if reduceMotion {
            NotyMotion.instant { prepare(); column() }
            withAnimation(NotyMotion.modeSwitch(true)) { showsCalendar = shown }
        } else if columnVisibility == target {
            withAnimation(NotyMotion.modeSwitch(false)) { prepare(); column(); showsCalendar = shown }
        } else {
            // Content, switch and system button first, the column a frame later
            // in the same motion (both transactions `modeSwitch`).
            withAnimation(NotyMotion.modeSwitch(false)) { prepare(); showsCalendar = shown }
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.columnLag) {
                guard showsCalendar == shown else { return }
                withAnimation(NotyMotion.modeSwitch(false)) { column() }
            }
        }
    }

    /// One frame at 60 Hz (two at 120 Hz): by then the bars of the first
    /// transaction are laid out and committed.
    private static let columnLag: TimeInterval = 1.0 / 60

    /// The library sidebar stands beside the content: measured, the detail
    /// column is clearly narrower than the split view. Laid over the content
    /// (portrait, swiped in) it does not count – the detail keeps its width,
    /// and `columnVisibility` is no reliable report of that overlay (a wrong
    /// guess would put the only switch into a hidden sidebar).
    private var sidebarBeside: Bool { splitWidth - detailWidth >= 200 }

    /// Where „Hefte | Kalender“ is: in the sidebar's bar (right of the system
    /// sidebar button, user request 08.11.2026) while the sidebar stands
    /// beside the content, otherwise top left in the detail column (in the
    /// calendar after the calendar sidebar button). Always exactly one.
    /// Never in the calendar: → Kalender leaves the sidebar's bar with the
    /// content, a frame before the column (`setCalendar`), so it does not
    /// stay there without the system button beside it.
    private var switchInSidebar: Bool {
        !showsCalendar && columnVisibility != .detailOnly && (sidebarBeside || sidebarReturning)
    }

    /// Words, symbols or both, chosen by the sidebar's width and used in both
    /// bars, so the switch looks alike wherever it is; the detail bar never
    /// goes below the words (it has room for them).
    private func switchLabels(inSidebar: Bool) -> LibraryModeSwitch.Labels {
        // Narrow window (Split View): symbols only, the bar keeps its other items.
        if sizeClass == .compact { return .symbols }
        if sidebarSize.width >= switchFullWidth { return .full }
        return inSidebar && sidebarSize.width < switchTitlesWidth ? .symbols : .titles
    }

    /// Segmented „Hefte | Kalender“ (`switchInSidebar`). Moving between the
    /// bars it cross-fades; the marker slides between the segments.
    private func modeSwitch(_ labels: LibraryModeSwitch.Labels) -> some View {
        LibraryModeSwitch(showsCalendar: showsCalendar, labels: labels, namespace: modeSwitchSpace, reduceMotion: reduceMotion) {
            setCalendar($0, animated: true)
        }
        .disabled(!canSwitchMode || model.opened != nil)
    }

    /// Calendar sidebar on/off: the button slides it (`NotyMotion.panel`;
    /// Reduce Motion: it fades, the layout changes at once); ⌃⌘S in the
    /// calendar changes it without motion. Off while the event window is open.
    private var calendarSidebarButton: some View {
        Button {
            withAnimation(NotyMotion.panel(reduceMotion)) { calendar.sidebarWanted.toggle() }
        } label: {
            Label(calendar.sidebarWanted ? "Kalenderleiste ausblenden" : "Kalenderleiste einblenden", systemImage: "sidebar.squares.left")
        }
        .help("Kalenderleiste (⌃⌘S)")
        .disabled(calendar.selectedEvent != nil || model.opened != nil)
    }

    // MARK: Keyboard mode (docs/KEYBOARD.md)
    /// Items per row of the grid (`gridColumns`); the lists have one.
    private var keyboardColumns: Int {
        layout == .list ? 1 : max(1, Int((detailSize.width - 56 + 32) / (140 + 32)))
    }
    private func runKey(_ action: HelixAction, count: Int) {
        // The calendar covers the collection: no item may be acted on unseen.
        let items = showsCalendar ? [] : rows
        let index = items.firstIndex { $0.id == keyboardFocus }
        func focus(_ target: Int) { if !items.isEmpty { keyboardFocus = items[min(max(0, target), items.count - 1)].id } }
        let item = index.map { items[$0] }
        switch action {
        // Nothing focused yet: every direction starts at the first item.
        case .focusItem(let dx, let dy): focus(index.map { $0 + (dx + dy * keyboardColumns) * count } ?? 0)
        case .focusFirstItem: focus(0)
        case .focusLastItem: focus(items.count - 1)
        case .parentFolder: if !showsCalendar { leaveLevel() }
        case .search, .searchAll: searchAllNotebooks()
        case .newNotebook: creatingNotebook = true
        case .newTextDocument: creatingTextDocument = true
        case .newFolder: askName(.folder, title: "Neuer Ordner")
        default: break
        }
        guard editable, let item else { return }
        switch action {
        case .openItem: activate(item)
        case .renameItem: askName(.rename(item.id), title: "Umbenennen", value: item.title)
        case .trashItem:
            KeyboardRouter.shared.ask("\(NotyText.quoted(item.title)) in den Papierkorb?", message: Self.trashNote, confirm: "In den Papierkorb") {
                Task { await model.trash(item.id) }
            }
        case .pinItem: Task { await model.favorite(item) }
        case .moveItem: moving = item
        case .duplicateItem: if !item.isFolder { Task { await model.duplicate(item) } }
        case .export(.pdf): if !item.isFolder { exportPDF(item) }
        case .export(.markdown): if !item.isFolder { shareText(item, as: .markdown) }
        case .export(.plainText): if !item.isFolder { shareText(item, as: .plainText) }
        case .export(.noty): if !item.isFolder { shareNoty(item) }
        case .export(.word): if !item.isFolder { shareText(item, as: .word) }
        case .export(.rtf): if !item.isFolder { shareText(item, as: .rtf) }
        default: break
        }
    }
    private static let trashNote = "Wiederherstellen ist unter Einstellungen › Papierkorb möglich. Enthaltene Unterlagen eines Ordners werden ebenfalls ausgeblendet."
    /// The name by key: the input line, the responder stays (the alert is for touch).
    private func askName(_ action: NameAction, title: String, value: String = "") {
        KeyboardRouter.shared.askText(title, value: value) { text in
            nameAction = action; name = text
            submitName()
        }
    }
    /// What only the menus offer; the palette adds every key binding by name.
    private var keyCommands: [PaletteCommand] {
        [PaletteCommand(title: showsCalendar ? "Hefte zeigen" : "Kalender zeigen") { setCalendar(!showsCalendar, animated: false) },
         PaletteCommand(title: "PDF oder Bild importieren") { importingPDF = true },
         PaletteCommand(title: "Backup importieren") { importingBackup = true },
         PaletteCommand(title: "Wiederhergestellte Kopien") { showingCopies = true },
         PaletteCommand(title: "Einstellungen") { settingsRequest = SettingsRequest() }]
            + (DeveloperAccess.showsAreas(workspaces) ? [PaletteCommand(title: "Bereiche") { showingAreas = true }] : [])
    }

    // MARK: Sidebar

    /// Plain scrolling column instead of a selectable `List`: there the
    /// collection view owns long-press/drag of its cells and the per-row drop
    /// delegates did not fire on the device (Build 44). One delegate for the
    /// whole column resolves the finger position against measured frames.
    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                sidebarLink("Alle Unterlagen", systemImage: "tray.full", target: .root,
                            dropInto: dropMark == DropMark(zone: .root, target: .into(nil)))
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(LibrarySpace.sidebar)) } action: { frames.root = $0 }
                sidebarLink("Zuletzt verwendet", systemImage: "clock", target: .recent, dropInto: false)
                // Second way in besides the switch (the sidebar goes away with it).
                // Swiped in over the calendar, the entry puts the sidebar away again.
                sidebarButton("Kalender", systemImage: "calendar", selected: showsCalendar, dropInto: false) {
                    if showsCalendar {
                        withAnimation(NotyMotion.panel(reduceMotion)) { columnVisibility = .detailOnly }
                    } else {
                        setCalendar(true, animated: true)
                    }
                }
                let pins = model.pinnedItems
                if !pins.isEmpty {
                    sidebarHeader("Angeheftet")
                    LazyVGrid(columns: pinnedColumns, alignment: .leading, spacing: 8) {
                        ForEach(pins) { pinnedTile($0) }
                    }
                }
                sidebarHeader("Bibliothek")
                ForEach(treeEntries) { treeRow($0) }
            }
            .padding(.horizontal, 12).padding(.bottom, 16)
            .frame(maxWidth: .infinity, minHeight: sidebarSize.height, alignment: .topLeading)
            .overlay(alignment: .topLeading) { insertionLine(sidebarLine) }
            .coordinateSpace(name: LibrarySpace.sidebar)
            .onDrop(of: [.text], delegate: LibraryDropDelegate(zones: [.root, .pinned, .tree], mark: $dropMark,
                                                               resolve: { sidebarDrop(at: $0) }, perform: { performDrop($0, id: $1) }))
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { sidebarSize = $0 }
        .background(Color(uiColor: .secondarySystemBackground))
        .navigationTitle("noty")
        .toolbar { sidebarToolbar }
        // In the calendar the library sidebar is away on purpose: no system
        // toggle beside the switch (the switch brings it back). Changes with
        // `showsCalendar`, a frame before the column (`setCalendar`).
        .toolbar(removing: showsCalendar ? .sidebarToggle : nil)
        .navigationSplitViewColumnWidth(min: 220, ideal: 280, max: 380)
        .safeAreaInset(edge: .bottom) { sidebarFooter }
    }

    /// The switch while the sidebar stands beside the content
    /// (`switchInSidebar`); otherwise `leadingToolbar` of the detail has it.
    @ToolbarContentBuilder private var sidebarToolbar: some ToolbarContent {
        if switchInSidebar {
            ToolbarItem(placement: .topBarLeading) { modeSwitch(switchLabels(inSidebar: true)) }
        }
    }

    private func sidebarLink(_ title: String, systemImage: String, target: LibraryLocation, dropInto: Bool) -> some View {
        sidebarButton(title, systemImage: systemImage, selected: !showsCalendar && location == target, dropInto: dropInto) {
            location = target
            setCalendar(false, animated: true)
        }
    }

    private func sidebarButton(_ title: String, systemImage: String, selected: Bool, dropInto: Bool,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label {
                Text(title).foregroundStyle(.primary)
            } icon: {
                Image(systemName: systemImage).foregroundStyle(.tint)
            }
            .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
            .padding(.horizontal, 10).padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background { sidebarBackground(selected: selected, dropInto: dropInto) }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func sidebarHeader(_ title: String) -> some View {
        Text(title).font(.headline).foregroundStyle(.secondary)
            .padding(.horizontal, 10).padding(.top, 18).padding(.bottom, 4)
            .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder private func sidebarBackground(selected: Bool, dropInto: Bool) -> some View {
        if dropInto { dropHighlight }
        else if selected { RoundedRectangle(cornerRadius: 10).fill(.tint.opacity(0.18)) }
    }

    /// Two pinned tiles side by side whenever the sidebar is wide enough.
    private var pinnedColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 8, alignment: .top), count: sidebarSize.width >= 230 ? 2 : 1)
    }

    private func pinnedTile(_ item: NotebookCore.LibraryItem) -> some View {
        let selected = location == .folder(item.id)
        return Button { activate(item) } label: {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: item.librarySymbol(filled: true))
                    .font(.title3).foregroundStyle(.tint)
                Text(item.title).font(.subheadline.weight(.medium)).foregroundStyle(.primary)
                    .lineLimit(2).truncationMode(.middle).multilineTextAlignment(.leading)
                    // Full title for the pointer; VoiceOver keeps label + hint of the tile.
                    .pointerHelp(item.title)
            }
            .frame(maxWidth: .infinity, minHeight: 58, alignment: .topLeading)
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 12)
                .fill(selected ? AnyShapeStyle(.tint.opacity(0.18)) : AnyShapeStyle(Color(uiColor: .tertiarySystemFill))))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(NotyPressStyle())
        .overlay { if dropMark == DropMark(zone: .pinned, target: .into(item.id)) { dropHighlight } }
        .accessibilityLabel(accessibilityName(item))
        .accessibilityHint(item.isFolder ? "Öffnet den Ordner" : item.isTextDocument ? "Öffnet das Textdokument" : "Öffnet das Heft")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(LibrarySpace.sidebar)) } action: { frames.pinned[item.id] = $0 }
        .onDrag { dragProvider(item.id) }
        .contextMenu { itemActions(item, showsEnclosing: true) }
    }

    /// Visible rows of the folder/notebook tree. Expansion is stored per area
    /// and only changes when the user opens or closes a folder (or a folder is revealed).
    private var treeEntries: [TreeEntry] {
        let value = model.snapshot
        let expanded = model.expandedFolders
        var result: [TreeEntry] = []
        func walk(_ parent: UUID?, depth: Int) {
            for item in sort.apply(value.children(of: parent)) {
                let hasChildren = item.isFolder && !value.children(of: item.id).isEmpty
                let open = hasChildren && expanded.contains(item.id)
                result.append(TreeEntry(item: item, depth: depth, hasChildren: hasChildren, expanded: open))
                if open && depth < 64 { walk(item.id, depth: depth + 1) }
            }
        }
        walk(nil, depth: 0)
        return result
    }

    private func toggleExpansion(_ id: UUID) {
        if model.expandedFolders.contains(id) { _ = model.expandedFolders.remove(id) } else { _ = model.expandedFolders.insert(id) }
    }

    private func treeRow(_ entry: TreeEntry) -> some View {
        let item = entry.item
        let selected = location == .folder(item.id)
        return HStack(spacing: 0) {
            if entry.hasChildren {
                Button {
                    withAnimation(NotyMotion.panel(reduceMotion)) { toggleExpansion(item.id) }
                } label: {
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                        .rotationEffect(.degrees(entry.expanded ? 90 : 0))
                        .frame(width: LibrarySpace.chevron, height: 32).contentShape(Rectangle())
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .accessibilityLabel(entry.expanded ? "\(item.title) zuklappen" : "\(item.title) aufklappen")
            } else {
                Color.clear.frame(width: LibrarySpace.chevron, height: 1)
            }
            Button { activate(item) } label: {
                Label {
                    // Middle truncation: near-duplicates („Scan … 14-32-11“, „… Kopie“) differ at the end.
                    Text(item.title).lineLimit(1).truncationMode(.middle).foregroundStyle(.primary)
                        .pointerHelp(item.title)
                } icon: {
                    Image(systemName: item.librarySymbol(filled: false))
                        .foregroundStyle(item.isFolder ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                }
                .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(accessibilityName(item))
            .accessibilityHint(item.isFolder ? "Öffnet den Ordner" : item.isTextDocument ? "Öffnet das Textdokument" : "Öffnet das Heft")
            .accessibilityAddTraits(selected ? .isSelected : [])
        }
        // Capped like the text outline: deep folder chains must leave room for the title.
        .padding(.leading, CGFloat(min(entry.depth, LibrarySpace.maxIndentDepth)) * LibrarySpace.indent)
        .padding(.horizontal, LibrarySpace.rowInset).padding(.vertical, 2)
        .background { sidebarBackground(selected: selected, dropInto: dropMark == DropMark(zone: .tree, target: .into(item.id))) }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(LibrarySpace.sidebar)) } action: { frames.tree[item.id] = $0 }
        .onDrag { dragProvider(item.id) }
        .contextMenu { itemActions(item, showsEnclosing: false) }
    }

    // MARK: Drag & drop

    private var dropHighlight: some View {
        RoundedRectangle(cornerRadius: 10).fill(.tint.opacity(0.25))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.tint, lineWidth: 2))
            .allowsHitTesting(false)
    }

    private func dragProvider(_ id: UUID) -> NSItemProvider {
        dragging = id
        return NSItemProvider(object: id.uuidString as NSString)
    }

    private func dropFrame(_ item: NotebookCore.LibraryItem, _ rect: CGRect, opensBelow: Bool = false) -> LibraryDropFrame {
        LibraryDropFrame(id: item.id, minX: rect.minX, minY: rect.minY, maxX: rect.maxX, maxY: rect.maxY,
                         isFolder: item.isFolder, opensBelow: opensBelow)
    }

    private func isBetween(_ target: LibraryDropTarget) -> Bool {
        switch target {
        case .before, .after: true
        case .into, .intoStart: false
        }
    }

    /// Hides targets that would be rejected or change nothing for the entry
    /// being dragged in this app (a folder into itself, its own position).
    private func validated(_ mark: DropMark) -> DropMark? {
        guard let id = dragging else { return mark }
        if mark.zone == .pinned && isBetween(mark.target) {
            let current = model.pinnedItems.map(\.id)
            guard model.snapshot.items.contains(where: { $0.id == id }), !model.snapshot.isTrashed(id),
                  let order = LibraryPinOrder.placing(id, at: mark.target, in: current), order != current else { return nil }
            return mark
        }
        return model.snapshot.placement(of: id, at: mark.target) == nil ? nil : mark
    }

    /// Sidebar: „Alle Unterlagen“ = top level; pinned tiles = pin order (or
    /// into a pinned folder); tree rows = position or into a folder.
    private func sidebarDrop(at point: CGPoint) -> DropMark? {
        guard editable else { return nil }
        if frames.root.contains(point) { return validated(DropMark(zone: .root, target: .into(nil))) }
        var pinBounds: CGRect?
        var pinTiles: [LibraryDropFrame] = []
        for item in model.pinnedItems {
            guard let rect = frames.pinned[item.id] else { continue }
            pinBounds = pinBounds?.union(rect) ?? rect
            pinTiles.append(dropFrame(item, rect))
        }
        if let pinBounds, pinBounds.insetBy(dx: -6, dy: -6).contains(point) {
            return LibraryDropLayout.gridTarget(x: point.x, y: point.y, tiles: pinTiles, positional: true)
                .flatMap { validated(DropMark(zone: .pinned, target: $0)) }
        }
        let entries = treeEntries
        let rows = entries.compactMap { entry in frames.tree[entry.id].map { dropFrame(entry.item, $0, opensBelow: entry.expanded) } }
        guard let first = rows.first, let last = rows.last, point.y >= first.minY - 8 else { return nil }
        let positional = sort == .manual
        // Empty space below the tree: end of the top level.
        if point.y > last.maxY + 12 {
            guard positional, let top = entries.last(where: { $0.depth == 0 }) else { return nil }
            return validated(DropMark(zone: .tree, target: .after(top.id)))
        }
        return LibraryDropLayout.listTarget(y: point.y, rows: rows, positional: positional)
            .flatMap { validated(DropMark(zone: .tree, target: $0)) }
    }

    private var sidebarLine: LineSpec? {
        guard let mark = dropMark else { return nil }
        switch (mark.zone, mark.target) {
        case (.pinned, .before(let id)):
            return frames.pinned[id].map { LineSpec(vertical: true, x: $0.minX - 4, y: $0.minY, length: $0.height) }
        case (.pinned, .after(let id)):
            return frames.pinned[id].map { LineSpec(vertical: true, x: $0.maxX + 4, y: $0.minY, length: $0.height) }
        case (.tree, .before(let id)): return treeLine(id, below: false)
        case (.tree, .after(let id)): return treeLine(id, below: true)
        case (.tree, .intoStart(let id)): return treeLine(id, below: true, nested: true)
        default: return nil
        }
    }

    /// Insertion line indented to the depth the entry would get.
    private func treeLine(_ id: UUID, below: Bool, nested: Bool = false) -> LineSpec? {
        let entries = treeEntries
        guard let index = entries.firstIndex(where: { $0.id == id }), let frame = frames.tree[id] else { return nil }
        var y = below ? frame.maxY + 1 : frame.minY - 1
        if below && !nested {
            // Behind an expanded folder means behind its whole visible subtree.
            var end = index
            while end + 1 < entries.count && entries[end + 1].depth > entries[index].depth { end += 1 }
            if let rect = frames.tree[entries[end].id] { y = rect.maxY + 1 }
        }
        let depth = CGFloat(entries[index].depth + (nested ? 1 : 0))
        let x = frame.minX + LibrarySpace.rowInset + depth * LibrarySpace.indent + LibrarySpace.chevron
        return LineSpec(vertical: false, x: x, y: y, length: max(24, frame.maxX - x))
    }

    /// Main area: insertion line between tiles/rows (manual order), folder
    /// highlight for dropping into it, otherwise into the shown folder.
    private func detailDrop(at point: CGPoint) -> DropMark? {
        guard editable else { return nil }
        let measured = layout == .list ? frames.list : frames.grid
        let tiles = rows.compactMap { item in measured[item.id].map { dropFrame(item, $0) } }
        let target = layout == .list
            ? LibraryDropLayout.listTarget(y: point.y, rows: tiles, positional: canReorder)
            : LibraryDropLayout.gridTarget(x: point.x, y: point.y, tiles: tiles, positional: canReorder)
        if let target, let mark = validated(DropMark(zone: .detail, target: target)) { return mark }
        guard normalFolder, search.isEmpty else { return nil }
        return validated(DropMark(zone: .detail, target: .into(parentID)))
    }

    private var detailLine: LineSpec? {
        guard let mark = dropMark, mark.zone == .detail else { return nil }
        switch mark.target {
        case .before(let id), .after(let id):
            let after = mark.target == .after(id)
            if layout == .list {
                guard let rect = frames.list[id] else { return nil }
                return LineSpec(vertical: false, x: rect.minX + 20, y: after ? rect.maxY : rect.minY, length: max(24, rect.width - 40))
            }
            guard let rect = frames.grid[id] else { return nil }
            return LineSpec(vertical: true, x: after ? rect.maxX + 16 : rect.minX - 16, y: rect.minY, length: rect.height)
        case .into, .intoStart: return nil
        }
    }

    @ViewBuilder private func insertionLine(_ spec: LineSpec?) -> some View {
        if let spec {
            InsertionLine(vertical: spec.vertical)
                .frame(width: spec.vertical ? 7 : spec.length, height: spec.vertical ? spec.length : 7)
                .offset(x: spec.x - 3.5, y: spec.y - 3.5)
        }
    }

    private func performDrop(_ mark: DropMark, id: UUID) {
        dragging = nil
        guard editable else { return }
        if mark.zone == .pinned && isBetween(mark.target) {
            Task { await model.placePin(id, at: mark.target) }
            return
        }
        // Same placement rules as the store: one commit for folder + position.
        guard let placement = model.snapshot.placement(of: id, at: mark.target) else { return }
        Task { await model.place(id, in: placement.parentID, before: placement.beforeID) }
    }

    private var sidebarFooter: some View {
        HStack {
            // Bereiche are a test tool: hidden in the normal noty unless one exists.
            if DeveloperAccess.showsAreas(workspaces) {
                Button { showingAreas = true } label: {
                    Label(workspaces.title, systemImage: workspaces.kind.symbol).lineLimit(1)
                }
                .disabled(model.busy && !model.backgroundBusy || workspaces.busy)
                .accessibilityLabel("Bereich \(workspaces.title)").accessibilityHint("Bereich wechseln")
            }
            Spacer()
            let count = model.trashedItems.count
            if count > 0 {
                Button { settingsRequest = SettingsRequest(page: .trash) } label: {
                    Label("\(count)", systemImage: "trash").monospacedDigit()
                }
                .accessibilityLabel("Papierkorb, \(count) \(count == 1 ? "Eintrag" : "Einträge")")
                .accessibilityHint("Öffnet den Papierkorb in den Einstellungen")
            }
        }
        .font(.subheadline).buttonStyle(.plain).foregroundStyle(workspaces.kind == nil ? Color.secondary : Color.orange)
        .padding(.horizontal, 20).padding(.vertical, 12)
        .background(.bar)
    }

    // MARK: Detail

    /// The calendar brings its own toolbar; search, editing and drops belong
    /// to the collection only. Export, warnings and (sidebar hidden or laid
    /// over) the Hefte/Kalender switch stay for both. Both sides are in one
    /// `ZStack` so the switch can show the leaving and the coming side
    /// together (`NotyMotion.modeTransition`); the calendar's model is the
    /// host's, nothing of its state goes with the view.
    private var detail: some View {
        ZStack {
            if showsCalendar {
                CalendarView(model: calendar, keysActive: calendarKeysActive, covered: model.opened != nil)
                    .transition(NotyMotion.modeTransition(leading: false, reduced: reduceMotion))
            } else {
                collection
                    .navigationTitle(title)
                    .searchable(text: $search, prompt: "Name suchen")
                    .toolbar { libraryToolbar }
                    .transition(NotyMotion.modeTransition(leading: true, reduced: reduceMotion))
            }
        }
            .toolbar { leadingToolbar }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { detailWidth = $0 }
            .safeAreaInset(edge: .top, spacing: 0) {
                if let warning = model.warning {
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .font(.caption).padding().frame(maxWidth: .infinity, alignment: .leading)
                        .background(.orange.opacity(0.12))
                }
            }
            .overlay(alignment: .bottom) {
                PDFExportProgressBadge(job: pdfExport).padding(12)
            }
            .fileExporter(isPresented: $exportingPDF, document: exportedPDF, contentType: .pdf, defaultFilename: exportedPDFName) { result in
                switch result {
                case .success: AccessibilityNotification.Announcement("PDF gesichert").post()
                case .failure(let error): model.error = error.localizedDescription
                }
                exportedPDF = nil
            }
            .overlay(alignment: .bottom) {
                // Only user-started operations show progress; background work stays invisible.
                if model.ready && model.busy && !model.backgroundBusy {
                    ProgressView("Bibliothek wird bearbeitet …").font(.footnote)
                        .padding(.horizontal, 14).padding(.vertical, 10).background(.regularMaterial, in: Capsule()).padding(12)
                }
            }
    }

    /// Leading items of both sides, in this order: (Kalender, wide enough)
    /// the calendar sidebar button, the switch (unless it is in the sidebar's
    /// bar, `switchInSidebar`), then (Hefte, inside a folder) the way up. One
    /// declaration for both sides keeps the switch the same item while the
    /// content changes beneath it.
    @ToolbarContentBuilder private var leadingToolbar: some ToolbarContent {
        // Left of the switch (user request 08.11.2026; before, the calendar's
        // own toolbar put it right of it). Only where the sidebar has room
        // (from 864 pt calendar width: landscape, not portrait) – measured
        // here (`detailWidth`), so the button is there with the first frame
        // of the calendar instead of after the calendar has measured itself.
        if showsCalendar && detailWidth >= CalendarSidebar.minimumTotalWidth {
            ToolbarItem(placement: .topBarLeading) { calendarSidebarButton }
        }
        if !switchInSidebar {
            ToolbarItem(placement: .topBarLeading) { modeSwitch(switchLabels(inSidebar: false)) }
        }
        if !showsCalendar, case .folder(let id) = location, search.isEmpty {
            ToolbarItem(placement: .topBarLeading) {
                Button { goUp(from: id) } label: {
                    // A long parent name (up to 120 characters) must not crowd the trailing items out of the bar.
                    let name = parentTitle(of: id)
                    Label(name.count > 24 ? String(name.prefix(23)) + "…" : name, systemImage: "chevron.backward")
                        .labelStyle(.titleAndIcon).lineLimit(1)
                }
                .accessibilityLabel("Zurück zu \(parentTitle(of: id))")
            }
        }
    }

    /// Trailing top bar of the library (leading: `leadingToolbar`). Every control is its own item with an
    /// explicit placement, declared in display order (leading to trailing):
    /// backup hint (only when needed) · Inhalte suchen · Darstellung ·
    /// Bearbeiten (only when reordering is possible) · Neu · Backup jetzt
    /// speichern (development builds only) · Einstellungen.
    /// Optional items are added or left out as whole items: no permanently
    /// present item with sometimes empty content (the leading slot used to be
    /// one), no group whose membership changes while navigating.
    @ToolbarContentBuilder private var libraryToolbar: some ToolbarContent {
        if BackupStatusBadge.needsAttention(externalBackup) {
            ToolbarItem(placement: .topBarTrailing) {
                BackupStatusBadge(externalBackup: externalBackup, library: model) { settingsRequest = SettingsRequest(page: .backup) }
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button { searchAllNotebooks() } label: {
                Label("In allen Heften suchen", systemImage: "magnifyingglass")
            }.disabled(!editable)
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Picker("Darstellung", selection: $layout) {
                    ForEach(LibraryLayout.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
                }
                Picker("Sortierung", selection: $sort) {
                    ForEach(LibrarySort.allCases) { Text($0.title).tag($0) }
                }
                Divider()
                Button("Neu laden", systemImage: "arrow.clockwise") { Task { await model.refresh() } }.disabled(model.busy)
            } label: { Label("Darstellung und Sortierung", systemImage: layout == .grid ? "square.grid.2x2" : "list.bullet") }
        }
        if canReorder {
            ToolbarItem(placement: .topBarTrailing) { EditButton().disabled(!editable) }
        }
        ToolbarItem(placement: .topBarTrailing) {
            // One primary entry point for creating and importing.
            Menu {
                Section {
                    Button("Neues Heft …", systemImage: "book.closed") { creatingNotebook = true }
                    Button("Neues Textdokument …", systemImage: "doc.text") { creatingTextDocument = true }
                    Button("Neuer Ordner …", systemImage: "folder.badge.plus") { prompt(.folder) }
                }
                Section {
                    Button("PDF oder Bild importieren …", systemImage: "doc.badge.plus") { importingPDF = true }
                    Button(".noty importieren …", systemImage: "arrow.down.doc") { importingBackup = true }
                    if !activeCopies.isEmpty {
                        Button("Wiederhergestellte Kopien …", systemImage: "clock.arrow.circlepath") { showingCopies = true }
                    }
                }
            } label: { Label("Neu", systemImage: "plus") }
            .disabled(!editable)
            .accessibilityLabel("Neu oder importieren")
        }
        ToolbarItem(placement: Self.settingsPlacement) {
            Button { settingsRequest = SettingsRequest() } label: { Label("Einstellungen", systemImage: "gearshape") }
        }
    }

    /// iPadOS 27 lays the top bar out by available space: when the detail column
    /// is crowded (sidebar, back button with the parent's name, title, search
    /// field) the system moves `.topBarTrailing` items, the last-declared first,
    /// so the gear ended up away from the trailing edge. A pinned trailing item
    /// stays at the trailing edge (it only gives way while a search is active).
    private static var settingsPlacement: ToolbarItemPlacement {
        if #available(iOS 27.0, *) { return .topBarPinnedTrailing }
        return .topBarTrailing
    }

    /// Same exporter as the editor, from the last committed revision.
    private func exportPDF(_ item: NotebookCore.LibraryItem) {
        guard !item.isFolder, !pdfExport.running else { return }
        Task {
            do {
                let committed = try await model.committedNotebook(item.id)
                var notebook = committed.0
                let assets = committed.1
                // The library title: a renamed notebook takes it over only when opened.
                notebook.title = item.title
                exportedPDFName = PDFExporter.fileName(for: notebook.title)
                // Same pages as from the editor: a text document without empty trailing pages.
                pdfExport.start(notebook, pageIDs: PDFExporter.wholeDocumentPages(notebook), assets: assets) { result in
                    switch result {
                    case .success(let data): exportedPDF = ExportFile(pdfData: data); exportingPDF = true
                    case .failure(let error): if !(error is CancellationError) { model.error = error.localizedDescription }
                    }
                }
            } catch { model.error = error.localizedDescription }
        }
    }

    /// `<Titel>.noty` of the last committed revision in the share sheet.
    private func shareNoty(_ item: NotebookCore.LibraryItem) {
        Task { if let url = await model.shareFile(for: item) { NotyShare.present(url) } }
    }

    /// Notebook or text document as `<Titel>.txt`/`.md`/`.rtf`/`.docx` of the last committed
    /// revision, the same export as in the editor (`TextDocumentExport`).
    private func shareText(_ item: NotebookCore.LibraryItem, as format: TextDocumentExport.Format) {
        Task {
            do {
                let (notebook, _) = try await model.committedNotebook(item.id)
                let data = TextDocumentExport.data(notebook, as: format)
                guard !data.isEmpty else { model.error = "Hier gibt es noch keinen Text zum Teilen."; return }
                let url = try BackupScratch.newShareFile(title: notebook.title, fileExtension: format.fileExtension)
                try data.write(to: url, options: .atomic)
                NotyShare.present(url)
            } catch { model.error = "Teilen nicht möglich: \(error.localizedDescription)" }
        }
    }

    private func searchAllNotebooks() {
        guard editable else { return }
        let retain = Set(model.snapshot.items.filter { !$0.isFolder }.map(\.id))
        Task { contentSearch = NotebookChoiceList(documents: await model.editorChoices(), retain: retain) }
    }

    private func switchAreaIfRequested() {
        guard switchingArea else { return }
        let area = selectedArea
        selectedArea = nil; switchingArea = false
        Task {
            if toolbox.writable {
                guard await toolbox.flush() else { model.error = toolbox.status; calendar.selectionChanged(); return }
            }
            // The calendar's note beside an event commits and lets go first.
            // The switch disposes this area's calendar model: a note or a
            // calendar change that exists only in memory is never dropped
            // silently, only after the explicit choice to discard it.
            if let unsaved = await calendar.prepareAreaSwitch() {
                guard await TopAlert.ask("Kalender nicht gespeichert",
                                         unsaved + "\n\nBeim Wechseln des Bereichs gehen diese Änderungen verloren. Ohne Wechsel versucht noty es weiter.",
                                         confirm: "Verwerfen und wechseln") else {
                    // Staying: the note beside the selected event opens again.
                    calendar.selectionChanged()
                    return
                }
                calendar.discardUnsavedForAreaSwitch()
            }
            // The new area's store must not start beside a running import.
            await model.waitUntilIdle()
            await workspaces.select(area)
        }
    }

    @ViewBuilder private var collection: some View {
        Group {
            if libraryEditMode.isEditing {
                List {
                    ForEach(rows) { item in documentRow(item) }
                        .onMove { offsets, target in
                            var order = rows.map(\.id)
                            order.move(fromOffsets: offsets, toOffset: target)
                            Task { await model.reorder(order, parent: parentID) }
                        }
                        .moveDisabled(!canReorder || !editable)
                }
            } else {
                ScrollViewReader { proxy in
                ScrollView {
                    Group {
                        if layout == .list {
                            LazyVStack(spacing: 0) {
                                ForEach(rows) { item in listRow(item) }
                            }.padding(.vertical, 8)
                        } else {
                            LazyVGrid(columns: gridColumns, alignment: .leading, spacing: 32) {
                                ForEach(rows) { item in documentCard(item) }
                            }.padding(28)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: detailSize.height, alignment: .top)
                    .background {
                        // Dropping anywhere else moves into the shown folder.
                        if let mark = dropMark, mark.zone == .detail, mark.target == .into(parentID) {
                            Rectangle().fill(.tint.opacity(0.06)).allowsHitTesting(false)
                        }
                    }
                    .overlay(alignment: .topLeading) { insertionLine(detailLine) }
                    .coordinateSpace(name: LibrarySpace.detail)
                    .onDrop(of: [.text], delegate: LibraryDropDelegate(zones: [.detail], mark: $dropMark,
                                                                       resolve: { detailDrop(at: $0) }, perform: { performDrop($0, id: $1) }))
                }
                .onGeometryChange(for: CGSize.self) { $0.size } action: { detailSize = $0 }
                .onChange(of: keyboardFocus) { _, id in if let id { proxy.scrollTo(id) } }
                }
            }
        }
        .overlay {
            if !model.ready { if model.busy { ProgressView("Bibliothek wird geladen …") } }
            else if rows.isEmpty { emptyState }
        }
    }

    private func listRow(_ item: NotebookCore.LibraryItem) -> some View {
        documentRow(item)
            .padding(.horizontal, 20).padding(.vertical, 6)
            .background {
                if dropMark == DropMark(zone: .detail, target: .into(item.id)) { dropHighlight.padding(.horizontal, 8) }
            }
            .overlay(alignment: .bottom) { Divider().padding(.leading, 66) }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(LibrarySpace.detail)) } action: { frames.list[item.id] = $0 }
            .onDrag { dragProvider(item.id) }
    }

    /// Top alignment plus fixed-height captions: covers of one row line up
    /// whether a title has one or two lines and whether a subtitle exists.
    private var gridColumns: [GridItem] { [GridItem(.adaptive(minimum: 140, maximum: 200), spacing: 32, alignment: .top)] }

    @ViewBuilder private var emptyState: some View {
        if !search.isEmpty {
            ContentUnavailableView.search(text: search)
        } else {
            switch location {
            case .recent:
                ContentUnavailableView("Noch nichts geöffnet", systemImage: "clock")
            case .folder:
                ContentUnavailableView {
                    Label("Ordner ist leer", systemImage: "folder")
                } actions: { createButtons }
            case .root:
                ContentUnavailableView {
                    Label("Noch keine Unterlagen", systemImage: "books.vertical")
                } actions: { createButtons }
            }
        }
    }

    @ViewBuilder private var createButtons: some View {
        // Same order and labels as the „+“ menu: Heft, Textdokument, Ordner.
        Button("Neues Heft …", systemImage: "book.closed") { creatingNotebook = true }.disabled(!editable)
        Button("Neues Textdokument …", systemImage: "doc.text") { creatingTextDocument = true }.disabled(!editable)
        Button("Neuer Ordner …", systemImage: "folder.badge.plus") { prompt(.folder) }.disabled(!editable)
    }

    private func accessibilityName(_ item: NotebookCore.LibraryItem) -> String {
        var parts = ["\(item.libraryKindName) \(item.title)"]
        if item.favorite { parts.append("angeheftet") }
        if item.source == .restored { parts.append("wiederhergestellte Kopie") }
        if let date = item.lastOpened, !item.isFolder { parts.append("zuletzt geöffnet \(NotyText.listDate(date))") }
        return parts.joined(separator: ", ")
    }

    private func activate(_ item: NotebookCore.LibraryItem) {
        // A folder chosen in the (swiped-in) sidebar leaves the calendar; a
        // location change of its own (a trashed folder falling back) does not.
        if item.isFolder { location = .folder(item.id); setCalendar(false, animated: true) }
        else { Task { await model.open(item) } }
    }

    private func rowDetails(_ item: NotebookCore.LibraryItem) -> String {
        var parts: [String] = []
        if item.source == .restored { parts.append("Wiederhergestellte Kopie") }
        if item.source == .legacyMain { parts.append("Ursprüngliches Heft") }
        // While searching, `subtitle` is the path: its own line in the row.
        if search.isEmpty, let detail = subtitle(item) { parts.append(detail) }
        return parts.joined(separator: " · ")
    }

    private func subtitle(_ item: NotebookCore.LibraryItem) -> String? {
        if !search.isEmpty { return path(of: item) }
        if item.isFolder {
            let count = model.snapshot.children(of: item.id).count
            return NotyText.count(count, "Objekt", "Objekte")
        }
        guard let date = item.lastOpened else { return nil }
        return NotyText.listDate(date)
    }

    private var keyboardFocusRing: some View {
        RoundedRectangle(cornerRadius: 10).strokeBorder(.tint, lineWidth: 2).allowsHitTesting(false)
    }

    private func documentCard(_ item: NotebookCore.LibraryItem) -> some View {
        VStack(spacing: 8) {
            Button { activate(item) } label: {
                Group {
                    if item.isFolder {
                        Image(systemName: "folder.fill").font(.system(size: 76)).foregroundStyle(.tint)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else { LibraryNotebookArtwork(item: item, model: model) }
                }.aspectRatio(0.72, contentMode: .fit)
            }.buttonStyle(NotyPressStyle()).disabled(!editable)
                .accessibilityLabel(accessibilityName(item))
                .accessibilityHint(item.isFolder ? "Öffnet den Ordner" : item.isTextDocument ? "Öffnet das Textdokument" : "Öffnet das Heft")
            VStack(spacing: 2) {
                HStack(spacing: 4) {
                    if item.favorite { Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.secondary) }
                    Text(item.title).font(.subheadline.weight(.medium)).lineLimit(2, reservesSpace: true)
                        .truncationMode(.middle).multilineTextAlignment(.center)
                }
                // Always present (blank when empty), the search path cut at the head: the nearest folder matters most.
                Text(subtitle(item) ?? " ").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    .truncationMode(search.isEmpty ? .tail : .head)
            }
            .frame(maxWidth: .infinity)
            .help(item.title)
            .accessibilityHidden(true)
        }
        .background {
            if dropMark == DropMark(zone: .detail, target: .into(item.id)) { dropHighlight.padding(-8) }
        }
        .overlay { if keyboardFocus == item.id { keyboardFocusRing.padding(-6) } }
        .id(item.id)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(LibrarySpace.detail)) } action: { frames.grid[item.id] = $0 }
        .onDrag { dragProvider(item.id) }
        .contextMenu { itemActions(item, showsEnclosing: location == .recent || !search.isEmpty) }
    }

    private func documentRow(_ item: NotebookCore.LibraryItem) -> some View {
        Button { activate(item) } label: {
            HStack(spacing: 14) {
                Image(systemName: item.isFolder ? "folder.fill" : item.librarySymbol(filled: false))
                    .font(.title2).foregroundStyle(item.isFolder ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary)).frame(width: 32)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title).foregroundStyle(.primary).lineLimit(2).truncationMode(.middle)
                    // One string: separate texts in an HStack each wrapped into ragged mini-columns.
                    let details = rowDetails(item)
                    if !details.isEmpty {
                        Text(details).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    // Search: the path on its own line, cut at the head (the nearest
                    // folder matters most) without cutting „Wiederhergestellte Kopie“.
                    if !search.isEmpty {
                        Text(path(of: item)).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                    }
                }
                Spacer()
                if item.favorite { Image(systemName: "pin.fill").font(.caption).foregroundStyle(.secondary) }
                if item.isFolder { Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary) }
            }.padding(.vertical, 4).contentShape(Rectangle())
        }.buttonStyle(NotyPressStyle()).disabled(!editable)
        .overlay { if keyboardFocus == item.id { keyboardFocusRing.padding(-3) } }
        .id(item.id)
            .accessibilityLabel(accessibilityName(item))
            .accessibilityHint(item.isFolder ? "Öffnet den Ordner" : item.isTextDocument ? "Öffnet das Textdokument" : "Öffnet das Heft")
            .contextMenu { itemActions(item, showsEnclosing: location == .recent || !search.isEmpty) }
    }

    @ViewBuilder private func itemActions(_ item: NotebookCore.LibraryItem, showsEnclosing: Bool) -> some View {
        if model.snapshot.isTrashed(item.id) {
            Button("Wiederherstellen", systemImage: "arrow.uturn.backward") { Task { await model.restore(item.id) } }
        } else {
            Button(item.favorite ? "Nicht mehr anheften" : "Anheften", systemImage: item.favorite ? "pin.slash" : "pin") {
                Task { await model.favorite(item) }
            }
            Button("Umbenennen …", systemImage: "pencil") { prompt(.rename(item.id), value: item.title) }
            Button("Verschieben …", systemImage: "folder") { moving = item }
            if !item.isFolder {
                Button("Duplizieren", systemImage: "plus.square.on.square") { Task { await model.duplicate(item) } }
                // Rare export variants in one submenu, as in the editor (polish audit F15).
                Menu("Teilen und exportieren", systemImage: "square.and.arrow.up") {
                    Button("Als PDF exportieren …", systemImage: "doc.richtext") { exportPDF(item) }.disabled(pdfExport.running)
                    Button("Als .noty teilen …", systemImage: "shippingbox") { shareNoty(item) }
                    Section("Nur Text") {
                        Button("Als Markdown teilen (.md) …") { shareText(item, as: .markdown) }
                        Button("Als Text teilen (.txt) …") { shareText(item, as: .plainText) }
                        Button("Als Word teilen (.docx) …") { shareText(item, as: .word) }
                        Button("Als RTF teilen (.rtf) …") { shareText(item, as: .rtf) }
                    }
                }
            }
            if showsEnclosing {
                Button("Im Ordner zeigen", systemImage: "arrow.up.forward.square") {
                    location = item.parentID.map(LibraryLocation.folder) ?? .root
                }
            }
            Divider()
            Button("In den Papierkorb …", systemImage: "trash", role: .destructive) { trashing = item }
        }
    }

    /// Expands the ancestors of a folder shown on the right; never collapses anything.
    private func reveal(_ id: UUID) {
        var parent = model.snapshot.items.first { $0.id == id }?.parentID
        var visited = Set<UUID>()
        while let value = parent, visited.insert(value).inserted {
            if !model.expandedFolders.contains(value) { model.expandedFolders.insert(value) }
            parent = model.snapshot.items.first { $0.id == value }?.parentID
        }
    }
    /// A shown folder that was trashed/removed falls back to its nearest active ancestor.
    private func leaveUnavailableFolder() {
        guard case .folder(let id) = location else { return }
        var current: UUID? = id
        var visited = Set<UUID>()
        while let value = current, visited.insert(value).inserted {
            guard let item = model.snapshot.items.first(where: { $0.id == value }) else { current = nil; break }
            if !model.snapshot.isTrashed(value) { break }
            current = item.parentID
        }
        if current != id { location = current.map(LibraryLocation.folder) ?? .root }
    }
    private func path(of item: NotebookCore.LibraryItem) -> String { libraryPath(item, in: model.snapshot) }
    private func parentTitle(of id: UUID) -> String {
        guard let parent = model.snapshot.items.first(where: { $0.id == id })?.parentID else { return "Alle Unterlagen" }
        return model.snapshot.items.first { $0.id == parent }?.title ?? "Alle Unterlagen"
    }
    /// `-` in the library: a name search first, then „Zuletzt verwendet“ or the folder.
    private func leaveLevel() {
        if !search.isEmpty { search = "" }
        else if case .folder(let id) = location { goUp(from: id) }
        else if location == .recent { location = .root }
    }
    private func goUp(from id: UUID) {
        let parent = model.snapshot.items.first { $0.id == id }?.parentID
        location = parent.map(LibraryLocation.folder) ?? .root
    }
    private var nameTitle: String {
        switch nameAction {
        case .folder: "Neuer Ordner"
        case .rename: "Umbenennen"
        }
    }
    private func prompt(_ action: NameAction, value: String = "") {
        nameAction = action; name = value; showingName = true
    }
    private func submitName() {
        let value = name
        let action = nameAction
        let parent = parentID
        Task {
            switch action {
            case .folder:
                await model.createFolder(value, parent: parent)
                showNewItem()
            case .rename(let id): await model.rename(id, title: value)
            }
        }
    }
}

private enum LibrarySpace {
    static let sidebar = "librarySidebar"
    static let detail = "libraryDetail"
    /// Tree geometry shared by rows and insertion lines.
    static let indent: CGFloat = 16
    /// Deeper levels keep this indentation (a 220-pt sidebar at depth 10 left no room for the title).
    static let maxIndentDepth = 6
    static let chevron: CGFloat = 22
    static let rowInset: CGFloat = 6
}

private struct TreeEntry: Identifiable {
    let item: NotebookCore.LibraryItem
    let depth: Int
    let hasChildren: Bool
    let expanded: Bool
    var id: UUID { item.id }
}

private enum DropZone: Hashable { case root, pinned, tree, detail }

/// Current drag & drop preview: insertion line or highlighted folder.
private struct DropMark: Equatable {
    let zone: DropZone
    let target: LibraryDropTarget
}

private struct LineSpec: Equatable {
    var vertical: Bool
    var x: CGFloat, y: CGFloat, length: CGFloat
}

/// Measured row/tile frames (drop coordinate spaces) for resolving drops.
/// Deliberately not observed: layout updates must not re-render the library.
private final class DropFrames {
    var root: CGRect = .null
    var pinned: [UUID: CGRect] = [:]
    var tree: [UUID: CGRect] = [:]
    var grid: [UUID: CGRect] = [:]
    var list: [UUID: CGRect] = [:]
}

private struct InsertionLine: View {
    let vertical: Bool
    var body: some View {
        let stack = vertical ? AnyLayout(VStackLayout(spacing: 0)) : AnyLayout(HStackLayout(spacing: 0))
        stack {
            Circle().stroke(.tint, lineWidth: 2).frame(width: 7, height: 7)
            Rectangle().fill(.tint).frame(width: vertical ? 2 : nil, height: vertical ? nil : 2)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// One delegate per column: the drop position is resolved against all
/// measured frames, so the preview follows the finger exactly.
private struct LibraryDropDelegate: DropDelegate {
    let zones: Set<DropZone>
    @Binding var mark: DropMark?
    let resolve: (CGPoint) -> DropMark?
    let perform: (DropMark, UUID) -> Void

    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [.text]) }
    func dropEntered(info: DropInfo) { _ = dropUpdated(info: info) }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        let next = resolve(info.location)
        if let next {
            if mark != next { mark = next }
        } else if let current = mark, zones.contains(current.zone) {
            mark = nil
        }
        return DropProposal(operation: next == nil ? .forbidden : .move)
    }
    func dropExited(info: DropInfo) { if let current = mark, zones.contains(current.zone) { mark = nil } }
    func performDrop(info: DropInfo) -> Bool {
        let target = resolve(info.location)
        mark = nil
        guard let target, let provider = info.itemProviders(for: [.text]).first else { return false }
        let perform = perform
        Task { @MainActor in
            let text: String? = await withCheckedContinuation { continuation in
                _ = provider.loadTransferable(type: String.self) { continuation.resume(returning: try? $0.get()) }
            }
            if let text, let dragged = UUID(uuidString: text.trimmingCharacters(in: .whitespacesAndNewlines)) { perform(target, dragged) }
        }
        return true
    }
}

private func libraryPath(_ item: NotebookCore.LibraryItem, in value: LibrarySnapshot) -> String {
    var components: [String] = []
    var parent = item.parentID
    var visited = Set<UUID>()
    while let id = parent, visited.insert(id).inserted, let folder = value.items.first(where: { $0.id == id }) {
        components.insert(folder.title, at: 0); parent = folder.parentID
    }
    return (["Alle Unterlagen"] + components).joined(separator: " / ")
}

private struct MoveDestinationView: View {
    let item: NotebookCore.LibraryItem
    let snapshot: LibrarySnapshot
    let onSelect: (UUID?) -> Void
    @Environment(\.dismiss) private var dismiss
    private var folders: [NotebookCore.LibraryItem] {
        snapshot.items.filter { folder in
            guard folder.isFolder, !snapshot.isTrashed(folder.id) else { return false }
            var parent: UUID? = folder.id
            while let id = parent {
                if id == item.id { return false }
                parent = snapshot.items.first { $0.id == id }?.parentID
            }
            return true
        }
    }
    var body: some View {
        NavigationStack {
            List {
                // The name wraps here; in the title a long name cut off „verschieben“.
                Section {
                    Button("Alle Unterlagen") { onSelect(nil) }.disabled(item.parentID == nil).keyOption(.action { onSelect(nil) })
                    ForEach(folders) { folder in
                        Button { onSelect(folder.id) } label: {
                            VStack(alignment: .leading) {
                                Label(folder.title, systemImage: "folder").lineLimit(2).truncationMode(.middle)
                                Text(libraryPath(folder, in: snapshot)).font(.caption).foregroundStyle(.secondary)
                                    .lineLimit(1).truncationMode(.head)
                            }
                        }.disabled(folder.id == item.parentID).keyOption(.action { onSelect(folder.id) })
                    }
                } header: {
                    Text("\(NotyText.quoted(item.title)) verschieben nach …").lineLimit(3).textCase(nil)
                }
            }
            .navigationTitle("Verschieben")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } } }
        }
        .keyboardSheet()
    }
}

private struct LibraryNotebookArtwork: View {
    let item: NotebookCore.LibraryItem
    @ObservedObject var model: LibraryModel
    @State private var appearance: NotebookAppearance?
    @State private var image: UIImage?
    @State private var failed = false
    var body: some View {
        ZStack {
            if let appearance { NotebookCoverPreview(appearance: appearance) }
            else if let image { Image(uiImage: image).resizable().scaledToFit() }
            else if failed { Image(systemName: "doc.questionmark").font(.largeTitle).foregroundStyle(.secondary) }
            else { ProgressView() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        // Only a change of this notebook (reopened/closed) reloads its preview;
        // the previous image stays visible until the new one is ready.
        .task(id: "\(item.id)-\(item.lastOpened?.timeIntervalSince1970 ?? 0)-\(model.artworkRevision[item.id] ?? 0)") {
            do {
                let result = try await model.artwork(for: item.id)
                try Task.checkCancellation()
                appearance = result.0; image = result.1; failed = false
            } catch is CancellationError { }
            catch { failed = true }
        }
    }
}

/// One presentation of the content search, carrying the documents it searches.
private struct NotebookChoiceList: Identifiable {
    let id = UUID()
    let documents: [OpenNotebook]
    /// Every notebook of the area, trashed ones included: their index survives.
    let retain: Set<UUID>
}

/// „Hefte | Kalender“ at the top left (sidebar bar or detail bar): two
/// segments with a marker that slides to the chosen side with the switching
/// transaction (Reduce Motion: it only cross-fades). VoiceOver and Full
/// Keyboard Access see a segmented picker.
private struct LibraryModeSwitch: View {
    /// Words with symbols, words only (sidebar of the usual 280 pt) or symbols only.
    enum Labels { case full, titles, symbols }
    let showsCalendar: Bool
    let labels: Labels
    let namespace: Namespace.ID
    let reduceMotion: Bool
    let select: (Bool) -> Void
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        HStack(spacing: 2) {
            segment("Hefte", systemImage: "books.vertical", calendar: false)
            segment("Kalender", systemImage: "calendar", calendar: true)
        }
        .padding(3)
        .background(Capsule().fill(Color(uiColor: .tertiarySystemFill)))
        .opacity(enabled ? 1 : 0.5)
        .help("Hefte oder Kalender (⇧⌘K)")
        .accessibilityRepresentation {
            Picker("Ansicht", selection: Binding(get: { showsCalendar }, set: { select($0) })) {
                Text("Hefte").tag(false)
                Text("Kalender").tag(true)
            }
            .pickerStyle(.segmented)
        }
    }

    private func segment(_ title: String, systemImage: String, calendar: Bool) -> some View {
        let selected = showsCalendar == calendar
        return Button { select(calendar) } label: {
            Group {
                switch labels {
                case .symbols: Image(systemName: systemImage)
                case .titles: Text(title)
                case .full: Label(title, systemImage: systemImage).labelStyle(.titleAndIcon)
                }
            }
            .font(.subheadline.weight(selected ? .semibold : .regular))
            .foregroundStyle(selected ? Color.primary : Color.secondary)
            .padding(.horizontal, 12)
            .frame(minWidth: 40, minHeight: 32)
            .background { if selected { marker } }
            // The capsule stays 32 pt high; it takes touches 44 pt high.
            .contentShape(NotyHitShape())
        }
        .buttonStyle(NotyPressStyle())
        .accessibilityLabel(title)
    }

    @ViewBuilder private var marker: some View {
        let shape = Capsule().fill(Color(uiColor: .systemBackground)).shadow(color: .black.opacity(0.14), radius: 2, y: 1)
        if reduceMotion { shape.transition(.opacity) }
        else { shape.matchedGeometryEffect(id: "libraryModeMarker", in: namespace) }
    }
}
