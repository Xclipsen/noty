import SwiftUI
import UniformTypeIdentifiers
import NotebookCore

/// Shown location; notebooks open the editor instead.
private enum LibraryLocation: Hashable {
    case root, folder(UUID), recent
}

/// Files-like library: sidebar with pinned entries and the persisted
/// folder/notebook tree, the selected folder's contents on the right.
struct LibraryView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
    @StateObject private var artworkCache = PageThumbnailCache()
    @State private var creatingNotebook = false
    @State private var libraryEditMode: EditMode = .inactive
    @State private var name = ""
    @State private var nameAction = NameAction.folder
    @State private var moving: NotebookCore.LibraryItem?
    @State private var trashing: NotebookCore.LibraryItem?
    @State private var showingCopies = false
    @State private var selectedCopy: RestoredNotebook?
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var showingAreas = false
    @State private var selectedArea: TestWorkspace?
    @State private var switchingArea = false
    @State private var settingsRequest: SettingsRequest?
    /// Current drag & drop preview (insertion line or highlighted folder).
    @State private var dropMark: DropMark?
    /// Entry dragged from this library (for hiding invalid targets while hovering).
    @State private var dragging: UUID?
    @State private var frames = DropFrames()
    @State private var sidebarSize = CGSize(width: 280, height: 600)
    @State private var detailSize = CGSize(width: 600, height: 600)
    @StateObject private var pdfExport = PDFExportJob()
    @State private var exportedPDF: ExportFile?
    @State private var exportingPDF = false
    @State private var exportedPDFName = "noty-export"

    private enum NameAction { case folder, notebook, rename(UUID) }
    private var parentID: UUID? { if case .folder(let id) = location { return id }; return nil }
    /// Background work (refresh after closing a notebook, automatic backup)
    /// keeps the library interactive and visually unchanged.
    private var editable: Bool {
        model.ready && model.opened == nil && !workspaces.busy && (!model.busy || model.backgroundBusy)
    }
    /// Menu shortcuts pause while a sheet/dialog is shown: a second presentation would not appear.
    private var presenting: Bool {
        creatingNotebook || settingsRequest != nil || contentSearch != nil || moving != nil || showingAreas || showingCopies
            || showingName || trashing != nil || importingPDF || importingBackup || exportingPDF
    }
    private var normalFolder: Bool { location == .root || parentID != nil }
    /// Manual drag order is only meaningful for the unsorted contents of one folder.
    private var canReorder: Bool { normalFolder && search.isEmpty && sort == .manual }
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
        .animation(NotyMotion.panel(reduceMotion), value: libraryEditMode)
        .animation(NotyMotion.highlight(reduceMotion), value: location)
        .environment(\.editMode, $libraryEditMode)
        .sheet(isPresented: $creatingNotebook) {
            NotebookCreationView(defaultAppearance: toolbox.preferences.defaultAppearance) { title, appearance in
                await model.createNotebook(title, appearance: appearance, parent: parentID)
            }
        }
        .sheet(item: $settingsRequest, onDismiss: switchAreaIfRequested) { request in
            SettingsView(library: model, toolbox: toolbox, externalBackup: externalBackup, workspaces: workspaces,
                         initialPage: request.page) { area in
                selectedArea = area; switchingArea = true; settingsRequest = nil
            }
        }
        .sheet(item: $contentSearch, onDismiss: {
            if let hit = searchHit, let item = model.snapshot.items.first(where: { $0.id == hit.documentID }) {
                searchHit = nil; Task { await model.open(item, pageID: hit.pageID, searchBounds: hit.bounds) }
            }
        }) { search in
            ContentSearchView(documents: search.documents, area: StableDefaults.scope(model.root), retain: search.retain) { searchHit = $0 }
        }
        // Closing a notebook updates the library in place (no visible reload).
        .fullScreenCover(item: $model.opened, onDismiss: { model.editorClosed() }) { document in
            LibraryNotebookView(document: document, root: model.root, library: model).id(document.id)
                .environment(\.searchIndexArea, StableDefaults.scope(model.root))
                .publishesEditorCommands()
                .environment(\.editorSettings, EditorSettingsPresenter { [model, toolbox, externalBackup, workspaces] in
                    AnyView(SettingsView(library: model, toolbox: toolbox, externalBackup: externalBackup, workspaces: workspaces))
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
            Button("Speichern") { submitName() }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .confirmationDialog("In den Papierkorb verschieben?", isPresented: Binding(
            get: { trashing != nil }, set: { if !$0 { trashing = nil } }), titleVisibility: .visible) {
            if let item = trashing {
                Button("„\(item.title)“ in den Papierkorb", role: .destructive) {
                    Task { await model.trash(item.id) }
                    trashing = nil
                }
            }
        } message: { Text("Wiederherstellen ist unter Einstellungen › Papierkorb möglich. Enthaltene Unterlagen eines Ordners werden ebenfalls ausgeblendet.") }
        .sheet(isPresented: $importingPDF) {
            PDFImportSheet(defaults: toolbox.preferences.defaultAppearance, onImport: { url, margins in
                let access = url.startAccessingSecurityScopedResource()
                Task {
                    await model.importPDF(url, parent: parentID, writingArea: margins)
                    if access { url.stopAccessingSecurityScopedResource() }
                }
            }, onError: { model.error = $0 })
        }
        .fileImporter(isPresented: $importingBackup, allowedContentTypes: [.notyBackup, .json, .data]) { result in
            switch result {
            case .success(let url): Task { await model.importBackup(url, parent: parentID) }
            case .failure(let error): model.error = error.localizedDescription
            }
        }
        .alert("Bibliothek", isPresented: Binding(get: { model.error != nil && settingsRequest == nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
        .alert("Test- und Restore-Bereiche", isPresented: Binding(get: { workspaces.error != nil && settingsRequest == nil }, set: { if !$0 { workspaces.error = nil } })) {
            Button("OK") { workspaces.error = nil }
        } message: { Text(workspaces.error ?? "") }
        .onChange(of: location) { _, value in
            search = ""; libraryEditMode = .inactive
            if case .folder(let id) = value { reveal(id) }
        }
        .onChange(of: model.snapshot) { _, _ in leaveUnavailableFolder() }
        .focusedSceneValue(\.libraryCommands, model.opened == nil && !presenting ? LibraryCommandActions(
            newNotebook: editable ? { creatingNotebook = true } : nil,
            search: editable ? { searchAllNotebooks() } : nil) : nil)
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
        .navigationSplitViewColumnWidth(min: 220, ideal: 280, max: 380)
        .safeAreaInset(edge: .bottom) { sidebarFooter }
    }

    private func sidebarLink(_ title: String, systemImage: String, target: LibraryLocation, dropInto: Bool) -> some View {
        let selected = location == target
        return Button { location = target } label: {
            Label {
                Text(title).foregroundStyle(.primary)
            } icon: {
                Image(systemName: systemImage).foregroundStyle(Color.accentColor)
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
        else if selected { RoundedRectangle(cornerRadius: 10).fill(Color.accentColor.opacity(0.18)) }
    }

    /// Two pinned tiles side by side whenever the sidebar is wide enough.
    private var pinnedColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 8, alignment: .top), count: sidebarSize.width >= 230 ? 2 : 1)
    }

    private func pinnedTile(_ item: NotebookCore.LibraryItem) -> some View {
        let selected = location == .folder(item.id)
        return Button { activate(item) } label: {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: item.isFolder ? "folder.fill" : "book.closed.fill")
                    .font(.title3).foregroundStyle(Color.accentColor)
                Text(item.title).font(.subheadline.weight(.medium)).foregroundStyle(.primary)
                    .lineLimit(2).multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, minHeight: 58, alignment: .topLeading)
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 12)
                .fill(selected ? Color.accentColor.opacity(0.18) : Color(uiColor: .tertiarySystemFill)))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(NotyPressStyle())
        .overlay { if dropMark == DropMark(zone: .pinned, target: .into(item.id)) { dropHighlight } }
        .accessibilityLabel(accessibilityName(item))
        .accessibilityHint(item.isFolder ? "Zeigt den Ordner" : "Öffnet das Notizbuch")
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
                    Text(item.title).lineLimit(1).foregroundStyle(.primary)
                } icon: {
                    Image(systemName: item.isFolder ? "folder" : "book.closed")
                        .foregroundStyle(item.isFolder ? Color.accentColor : Color.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(accessibilityName(item))
            .accessibilityHint(item.isFolder ? "Zeigt den Ordner" : "Öffnet das Notizbuch")
            .accessibilityAddTraits(selected ? .isSelected : [])
        }
        .padding(.leading, CGFloat(entry.depth) * LibrarySpace.indent)
        .padding(.horizontal, LibrarySpace.rowInset).padding(.vertical, 2)
        .background { sidebarBackground(selected: selected, dropInto: dropMark == DropMark(zone: .tree, target: .into(item.id))) }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(LibrarySpace.sidebar)) } action: { frames.tree[item.id] = $0 }
        .onDrag { dragProvider(item.id) }
        .contextMenu { itemActions(item, showsEnclosing: false) }
    }

    // MARK: Drag & drop

    private var dropHighlight: some View {
        RoundedRectangle(cornerRadius: 10).fill(Color.accentColor.opacity(0.25))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accentColor, lineWidth: 2))
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
            Button { showingAreas = true } label: {
                Label(workspaces.title, systemImage: workspaces.kind == nil ? "books.vertical" : "flask").lineLimit(1)
            }
            .disabled(model.busy && !model.backgroundBusy || workspaces.busy)
            .accessibilityLabel("Bereich \(workspaces.title)").accessibilityHint("Bereich wechseln")
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

    private var detail: some View {
        collection
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
                if case .failure(let error) = result { model.error = error.localizedDescription }
                exportedPDF = nil
            }
            .overlay(alignment: .bottom) {
                // Only user-started operations show progress; background work stays invisible.
                if model.ready && model.busy && !model.backgroundBusy {
                    ProgressView().padding(10).background(.regularMaterial, in: Capsule()).padding(12)
                }
            }
            .navigationTitle(title)
            .searchable(text: $search, prompt: "Ordner- oder Notizbuchname")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if case .folder(let id) = location, search.isEmpty {
                        Button { goUp(from: id) } label: {
                            Label(parentTitle(of: id), systemImage: "chevron.backward").labelStyle(.titleAndIcon)
                        }
                        .accessibilityLabel("Zurück zu \(parentTitle(of: id))")
                    }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if BackupStatusBadge.needsAttention(externalBackup) {
                        BackupStatusBadge(externalBackup: externalBackup, library: model) { settingsRequest = SettingsRequest(page: .backup) }
                    }
                    Button { searchAllNotebooks() } label: {
                        Label("Inhalte suchen", systemImage: "doc.text.magnifyingglass")
                    }.disabled(!editable)
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
                    if canReorder { EditButton().disabled(!editable) }
                    Button { prompt(.folder) } label: { Label("Neuer Ordner", systemImage: "folder.badge.plus") }
                        .disabled(!editable)
                    Button { creatingNotebook = true } label: { Label("Neues Notizbuch", systemImage: "square.and.pencil") }
                        .disabled(!editable)
                    Menu {
                        Button("Arbeitsblatt/PDF importieren", systemImage: "doc.badge.plus") { importingPDF = true }
                        Button("Notizbuch-Backup als Kopie importieren", systemImage: "arrow.down.doc") { importingBackup = true }
                        if !activeCopies.isEmpty {
                            Button("Kopien mit Textvorschau finden", systemImage: "doc.text.magnifyingglass") { showingCopies = true }
                        }
                    } label: { Label("Importieren", systemImage: "square.and.arrow.down") }
                    .disabled(!editable)
                    Button { settingsRequest = SettingsRequest() } label: { Label("Einstellungen", systemImage: "gearshape") }
                }
            }
    }

    /// Same exporter as the editor, from the last committed revision.
    private func exportPDF(_ item: NotebookCore.LibraryItem) {
        guard !item.isFolder, !pdfExport.running else { return }
        Task {
            do {
                let notebook = try await model.committedNotebook(item.id)
                exportedPDFName = item.title
                pdfExport.start(notebook) { result in
                    switch result {
                    case .success(let data): exportedPDF = ExportFile(pdfData: data); exportingPDF = true
                    case .failure(let error): if !(error is CancellationError) { model.error = error.localizedDescription }
                    }
                }
            } catch { model.error = error.localizedDescription }
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
                guard await toolbox.flush() else { model.error = toolbox.status; return }
            }
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
                            Color.accentColor.opacity(0.06).allowsHitTesting(false)
                        }
                    }
                    .overlay(alignment: .topLeading) { insertionLine(detailLine) }
                    .coordinateSpace(name: LibrarySpace.detail)
                    .onDrop(of: [.text], delegate: LibraryDropDelegate(zones: [.detail], mark: $dropMark,
                                                                       resolve: { detailDrop(at: $0) }, perform: { performDrop($0, id: $1) }))
                }
                .onGeometryChange(for: CGSize.self) { $0.size } action: { detailSize = $0 }
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

    private var gridColumns: [GridItem] { [GridItem(.adaptive(minimum: 140, maximum: 200), spacing: 32)] }

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
        Button("Neuer Ordner", systemImage: "folder.badge.plus") { prompt(.folder) }.disabled(!editable)
        Button("Neues Notizbuch", systemImage: "square.and.pencil") { creatingNotebook = true }.disabled(!editable)
    }

    private func accessibilityName(_ item: NotebookCore.LibraryItem) -> String {
        var parts = [item.isFolder ? "Ordner \(item.title)" : "Notizbuch \(item.title)"]
        if item.favorite { parts.append("angeheftet") }
        if item.source == .restored { parts.append("wiederhergestellte Kopie") }
        if let date = item.lastOpened, !item.isFolder { parts.append("zuletzt geöffnet \(date.formatted(date: .abbreviated, time: .omitted))") }
        return parts.joined(separator: ", ")
    }

    private func activate(_ item: NotebookCore.LibraryItem) {
        if item.isFolder { location = .folder(item.id) }
        else { Task { await model.open(item) } }
    }

    private func subtitle(_ item: NotebookCore.LibraryItem) -> String? {
        if !search.isEmpty { return path(of: item) }
        if item.isFolder {
            let count = model.snapshot.children(of: item.id).count
            return count == 1 ? "1 Objekt" : "\(count) Objekte"
        }
        guard let date = item.lastOpened else { return nil }
        return location == .recent ? date.formatted(.relative(presentation: .named)) : date.formatted(date: .abbreviated, time: .omitted)
    }

    private func documentCard(_ item: NotebookCore.LibraryItem) -> some View {
        VStack(spacing: 8) {
            Button { activate(item) } label: {
                Group {
                    if item.isFolder {
                        Image(systemName: "folder.fill").font(.system(size: 76)).foregroundStyle(Color.accentColor)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else { LibraryNotebookArtwork(item: item, model: model, cache: artworkCache) }
                }.aspectRatio(0.72, contentMode: .fit)
            }.buttonStyle(NotyPressStyle()).disabled(!editable)
                .accessibilityLabel(accessibilityName(item))
                .accessibilityHint(item.isFolder ? "Öffnet den Ordner" : "Öffnet das Notizbuch")
            VStack(spacing: 2) {
                HStack(spacing: 4) {
                    if item.favorite { Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.secondary) }
                    Text(item.title).font(.subheadline.weight(.medium)).lineLimit(2).multilineTextAlignment(.center)
                }
                if let detail = subtitle(item) { Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            .frame(maxWidth: .infinity)
            .accessibilityHidden(true)
        }
        .background {
            if dropMark == DropMark(zone: .detail, target: .into(item.id)) { dropHighlight.padding(-8) }
        }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(LibrarySpace.detail)) } action: { frames.grid[item.id] = $0 }
        .onDrag { dragProvider(item.id) }
        .contextMenu { itemActions(item, showsEnclosing: location == .recent || !search.isEmpty) }
    }

    private func documentRow(_ item: NotebookCore.LibraryItem) -> some View {
        Button { activate(item) } label: {
            HStack(spacing: 14) {
                Image(systemName: item.isFolder ? "folder.fill" : "book.closed")
                    .font(.title2).foregroundStyle(item.isFolder ? Color.accentColor : .secondary).frame(width: 32)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title).foregroundStyle(.primary)
                    HStack {
                        if item.source == .restored { Text("Wiederhergestellte Kopie") }
                        if item.source == .legacyMain { Text("Ursprüngliches Notizbuch") }
                        if let detail = subtitle(item) { Text(detail) }
                    }.font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if item.favorite { Image(systemName: "pin.fill").font(.caption).foregroundStyle(.secondary) }
                if item.isFolder { Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary) }
            }.padding(.vertical, 4).contentShape(Rectangle())
        }.buttonStyle(NotyPressStyle()).disabled(!editable)
            .accessibilityLabel(accessibilityName(item))
            .accessibilityHint(item.isFolder ? "Öffnet den Ordner" : "Öffnet das Notizbuch")
            .contextMenu { itemActions(item, showsEnclosing: location == .recent || !search.isEmpty) }
    }

    @ViewBuilder private func itemActions(_ item: NotebookCore.LibraryItem, showsEnclosing: Bool) -> some View {
        if model.snapshot.isTrashed(item.id) {
            Button("Wiederherstellen", systemImage: "arrow.uturn.backward") { Task { await model.restore(item.id) } }
        } else {
            Button(item.favorite ? "Nicht mehr anheften" : "Anheften", systemImage: item.favorite ? "pin.slash" : "pin") {
                Task { await model.favorite(item) }
            }
            Button("Umbenennen", systemImage: "pencil") { prompt(.rename(item.id), value: item.title) }
            Button("Verschieben", systemImage: "folder") { moving = item }
            if !item.isFolder {
                Button("Duplizieren", systemImage: "plus.square.on.square") { Task { await model.duplicate(item) } }
                Button("Als PDF exportieren", systemImage: "doc.richtext") { exportPDF(item) }.disabled(pdfExport.running)
            }
            if showsEnclosing {
                Button("Im Ordner zeigen", systemImage: "arrow.up.forward.square") {
                    location = item.parentID.map(LibraryLocation.folder) ?? .root
                }
            }
            Divider()
            Button("In den Papierkorb", systemImage: "trash", role: .destructive) { trashing = item }
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
    private func goUp(from id: UUID) {
        let parent = model.snapshot.items.first { $0.id == id }?.parentID
        location = parent.map(LibraryLocation.folder) ?? .root
    }
    private var nameTitle: String {
        switch nameAction {
        case .folder: "Neuer Ordner"
        case .notebook: "Neues Notizbuch"
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
            case .folder: await model.createFolder(value, parent: parent)
            case .notebook: _ = await model.createNotebook(value, appearance: toolbox.preferences.defaultAppearance ?? NotebookAppearance(), parent: parent)
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
            Circle().stroke(Color.accentColor, lineWidth: 2).frame(width: 7, height: 7)
            Rectangle().fill(Color.accentColor).frame(width: vertical ? 2 : nil, height: vertical ? nil : 2)
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
                Button("Alle Unterlagen") { onSelect(nil) }
                ForEach(folders) { folder in
                    Button { onSelect(folder.id) } label: {
                        VStack(alignment: .leading) {
                            Label(folder.title, systemImage: "folder")
                            Text(libraryPath(folder, in: snapshot)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("\(item.title) verschieben")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } } }
        }
    }
}

private struct LibraryNotebookArtwork: View {
    let item: NotebookCore.LibraryItem
    @ObservedObject var model: LibraryModel
    @ObservedObject var cache: PageThumbnailCache
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
                let result = try await model.artwork(for: item.id, cache: cache)
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
