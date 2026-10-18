import SwiftUI
import NotebookCore

private enum LibraryLocation: Hashable {
    case root, folder(UUID), favorites, recent, trash
}

private struct FolderBranch: Identifiable {
    let item: NotebookCore.LibraryItem
    var children: [FolderBranch]?
    var id: UUID { item.id }
}

struct LibraryView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var model: LibraryModel
    @ObservedObject var workspaces: WorkspaceAppModel
    @EnvironmentObject private var externalBackup: ExternalBackupModel
    @State private var showingExternalBackup = false
    @EnvironmentObject private var toolbox: ToolbarSettingsModel
    @State private var location: LibraryLocation = .root
    @State private var search = ""
    @State private var contentSearch = false
    @State private var searchDocuments: [OpenNotebook] = []
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
    @State private var importingLibrary = false
    @State private var exportingLibrary = false
    @State private var libraryFile: ExportFile?

    private enum NameAction { case folder, notebook, rename(UUID) }
    private var parentID: UUID? { if case .folder(let id) = location { return id }; return nil }
    private var editable: Bool { model.ready && !model.busy && !workspaces.busy && model.opened == nil }
    private var normalFolder: Bool { location == .root || parentID != nil }
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
        case .favorites: "Favoriten"
        case .recent: "Zuletzt verwendet"
        case .trash: "Papierkorb"
        }
    }
    private var rows: [NotebookCore.LibraryItem] {
        let value = model.snapshot
        let candidates: [NotebookCore.LibraryItem]
        if location == .trash {
            candidates = value.items.filter { $0.deletedAt != nil }
        } else if !search.isEmpty {
            // Global name search; this is not yet the planned OCR/content search.
            candidates = value.items.filter { !value.isTrashed($0.id) }
        } else {
            switch location {
            case .root, .folder: candidates = value.children(of: parentID)
            case .favorites: candidates = value.items.filter { $0.favorite && !value.isTrashed($0.id) }
            case .recent:
                candidates = value.items.filter { !$0.isFolder && $0.lastOpened != nil && !value.isTrashed($0.id) }
                    .sorted { ($0.lastOpened ?? .distantPast) > ($1.lastOpened ?? .distantPast) }
            case .trash: candidates = []
            }
        }
        return candidates.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            List {
                Section {
                    sidebarButton("Alle Unterlagen", icon: "tray.full", destination: .root)
                        .dropDestination(for: String.self) { ids, _ in acceptDrop(ids, parent: nil) }
                    sidebarButton("Favoriten", icon: "star", destination: .favorites)
                    sidebarButton("Zuletzt verwendet", icon: "clock", destination: .recent)
                    sidebarButton("Papierkorb", icon: "trash", destination: .trash)
                }
                Section("Ordner") {
                    OutlineGroup(branches(parent: nil), children: \.children) { branch in
                        sidebarButton(branch.item.title, icon: "folder", destination: .folder(branch.id))
                            .draggable(branch.id.uuidString)
                            .dropDestination(for: String.self) { ids, _ in acceptDrop(ids, parent: branch.id) }
                            .contextMenu { itemActions(branch.item) }
                    }
                }
            }
            .navigationTitle("noty")
            .navigationSplitViewColumnWidth(min: 220, ideal: 270, max: 380)
        } detail: {
            VStack(spacing: 0) {
                HStack {
                    Label(workspaces.title, systemImage: workspaces.kind == nil ? "books.vertical" : "flask")
                    if workspaces.kind != nil { Text("· Getrennter Bereich").foregroundStyle(.secondary) }
                    Spacer()
                }.font(.subheadline).padding(.horizontal).padding(.top, 8)
                Text(externalBackup.status).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal)
                Text(model.backupStatus).font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal).padding(.vertical, 4)
                if let warning = model.warning {
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .font(.caption).padding().frame(maxWidth: .infinity, alignment: .leading)
                        .background(.orange.opacity(0.12))
                }
                if location == .trash {
                    Text("Einträge bleiben gespeichert. Ordner stellen ihre enthaltenen Unterlagen mit wieder her.")
                        .font(.caption).foregroundStyle(.secondary).padding()
                } else if !search.isEmpty {
                    Text("Namenssuche in allen aktiven Ordnern und Heften")
                        .font(.caption).foregroundStyle(.secondary).padding(.top)
                } else if let parent = parentID {
                    Button { goUp(from: parent) } label: {
                        Label("Übergeordneter Ordner", systemImage: "arrow.up")
                    }.padding(.top)
                }
                Group {
                    if libraryEditMode.isEditing {
                        List {
                            ForEach(rows) { item in
                                documentRow(item)
                            }
                            .onMove { offsets, target in
                                var order = rows.map(\.id)
                                order.move(fromOffsets: offsets, toOffset: target)
                                Task { await model.reorder(order, parent: parentID) }
                            }
                            .moveDisabled(!normalFolder || !search.isEmpty || !editable)
                        }
                    } else {
                        ScrollView {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 155, maximum: 220), spacing: 32)], alignment: .leading, spacing: 32) {
                                ForEach(rows) { item in documentCard(item) }
                            }.padding(28)
                        }
                    }
                }
                .overlay {
                    if !model.ready && model.busy { ProgressView("Bibliothek wird geladen …") }
                    else if rows.isEmpty {
                        ContentUnavailableView(search.isEmpty ? "Keine Unterlagen" : "Keine Namen gefunden",
                            systemImage: search.isEmpty ? "folder" : "magnifyingglass",
                            description: Text(location == .trash ? "Der Papierkorb ist leer." : "Über + ein Heft oder einen Ordner anlegen oder eine PDF importieren."))
                    }
                }
                if model.busy { ProgressView().padding(8) }
            }
            .navigationTitle(title)
            .searchable(text: $search, prompt: "Ordner- oder Heftname")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { Task { searchDocuments = await model.editorChoices(); contentSearch = true } } label: { Label("Inhalte suchen", systemImage: "doc.text.magnifyingglass") }.disabled(!editable)
                    Button { showingAreas = true } label: { Label("Bereiche", systemImage: "square.stack.3d.up") }
                        .disabled(model.busy || workspaces.busy)
                    Menu {
                        Button("Externe Backups und Signierung") { showingExternalBackup = true }
                        Button("Bibliotheksbackup exportieren") {
                            Task {
                                guard await toolbox.flush() else { model.error = toolbox.status; return }
                                if let data = await model.libraryBackup() {
                                    libraryFile = ExportFile(libraryData: data)
                                    exportingLibrary = true
                                }
                            }
                        }
                        Button("Bibliotheksbackup als neuen Bereich wiederherstellen") { importingLibrary = true }
                    } label: { Label("Sicherung", systemImage: "archivebox") }.disabled(!editable)
                    if normalFolder && search.isEmpty { EditButton().disabled(!editable) }
                    Menu {
                        Button("Neuer Ordner", systemImage: "folder.badge.plus") { prompt(.folder) }
                        Button("Neues Notizbuch", systemImage: "square.and.pencil") { creatingNotebook = true }
                        Button("PDF als neues Heft importieren", systemImage: "doc.badge.plus") { importingPDF = true }
                        Button("Heft-Backup als Kopie importieren", systemImage: "arrow.down.doc") { importingBackup = true }
                        if !activeCopies.isEmpty {
                            Button("Kopien mit Textvorschau finden", systemImage: "doc.text.magnifyingglass") { showingCopies = true }
                        }
                    } label: { Label("Neu", systemImage: "plus") }
                    .disabled(!editable || location == .trash)
                    Button { Task { await model.refresh() } } label: { Label("Neu laden", systemImage: "arrow.clockwise") }
                        .disabled(model.busy)
                }
            }
        }
        .animation(NotyMotion.panel(reduceMotion), value: libraryEditMode)
        .animation(NotyMotion.highlight(reduceMotion), value: location)
        .environment(\.editMode, $libraryEditMode)
        .sheet(isPresented: $creatingNotebook) {
            NotebookCreationView { title, appearance in await model.createNotebook(title, appearance: appearance, parent: parentID) }
        }
        .sheet(isPresented: $showingExternalBackup) { ExternalBackupView(model: externalBackup, library: model, workspaces: workspaces) }
        .sheet(isPresented: $contentSearch, onDismiss: {
            if let hit = searchHit, let item = model.snapshot.items.first(where: { $0.id == hit.documentID }) {
                searchHit = nil; Task { await model.open(item, pageID: hit.pageID, searchBounds: hit.bounds) }
            }
        }) { ContentSearchView(documents: searchDocuments) { searchHit = $0 } }
        .fullScreenCover(item: $model.opened, onDismiss: { Task { await model.refresh() } }) { document in
            LibraryNotebookView(document: document, root: model.root, library: model).id(document.id)
        }
        .sheet(item: $moving) { item in
            MoveDestinationView(item: item, snapshot: model.snapshot) { destination in
                moving = nil
                Task { await model.move(item.id, to: destination) }
            }
        }
        .sheet(isPresented: $showingAreas, onDismiss: {
            if switchingArea {
                let area = selectedArea
                selectedArea = nil; switchingArea = false
                Task {
                    if toolbox.writable {
                        guard await toolbox.flush() else { model.error = toolbox.status; return }
                    }
                    await workspaces.select(area)
                }
            }
        }) {
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
                Button("\(item.title) in den Papierkorb", role: .destructive) {
                    Task { await model.trash(item.id) }
                    if location == .folder(item.id) { location = .root }
                    trashing = nil
                }
            }
        } message: { Text("Du kannst den Eintrag später wiederherstellen. Enthaltene Unterlagen eines Ordners werden ebenfalls ausgeblendet.") }
        .sheet(isPresented: $importingPDF) {
            PDFImportSheet(onImport: { url, margins in
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
        .fileImporter(isPresented: $importingLibrary, allowedContentTypes: [.notyLibrary, .data]) { result in
            switch result {
            case .success(let url): Task {
                if await workspaces.restoreLibrary(url) {
                    model.backupStatus = "Bibliothek als neuen Bereich wiederhergestellt · über Bereiche öffnen"
                }
            }
            case .failure(let error): model.error = error.localizedDescription
            }
        }
        .fileExporter(isPresented: $exportingLibrary, document: libraryFile, contentType: .notyLibrary,
                      defaultFilename: "noty-bibliothek-\(Date().formatted(.iso8601).replacingOccurrences(of: ":", with: "-"))") { result in
            switch result {
            case .success: model.libraryBackupExported()
            case .failure(let error):
                model.backupStatus = "Bibliotheksbackup-Export nicht abgeschlossen"
                model.error = error.localizedDescription
            }
        }
        .alert("Bibliothek", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
        .alert("Test- und Restore-Bereiche", isPresented: Binding(get: { workspaces.error != nil }, set: { if !$0 { workspaces.error = nil } })) {
            Button("OK") { workspaces.error = nil }
        } message: { Text(workspaces.error ?? "") }
        .onChange(of: location) { _, _ in search = "" }
    }

    private func sidebarButton(_ name: String, icon: String, destination: LibraryLocation) -> some View {
        Button { location = destination } label: {
            Label(name, systemImage: icon).foregroundStyle(location == destination ? Color.accentColor : Color.primary)
                .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    private func documentCard(_ item: NotebookCore.LibraryItem) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                if item.isFolder { location = .folder(item.id) }
                else { Task { await model.open(item) } }
            } label: {
                Group {
                    if item.isFolder {
                        RoundedRectangle(cornerRadius: 12).fill(Color.accentColor.opacity(0.12))
                            .overlay(Image(systemName: "folder.fill").font(.system(size: 56)).foregroundStyle(Color.accentColor))
                    } else { LibraryNotebookArtwork(item: item, model: model, cache: artworkCache) }
                }.aspectRatio(0.72, contentMode: .fit)
            }.buttonStyle(NotyPressStyle()).disabled(!editable || location == .trash)
            HStack(alignment: .top, spacing: 4) {
                Text(item.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                Spacer(minLength: 0)
                if item.favorite { Image(systemName: "star.fill").font(.caption).foregroundStyle(.yellow) }
                Menu { itemActions(item) } label: { Image(systemName: "chevron.down").font(.caption).frame(width: 28, height: 28) }.disabled(!editable)
            }
            if let date = item.lastOpened { Text(date, style: .date).font(.caption).foregroundStyle(.secondary) }
        }
        .draggable(item.id.uuidString)
        .dropDestination(for: String.self) { ids, _ in item.isFolder && acceptDrop(ids, parent: item.id) }
        .contextMenu { itemActions(item) }
    }

    private func documentRow(_ item: NotebookCore.LibraryItem) -> some View {
        HStack {
            Button {
                if location == .trash { return }
                if item.isFolder { location = .folder(item.id) }
                else { Task { await model.open(item) } }
            } label: {
                HStack(spacing: 14) {
                    Image(systemName: item.isFolder ? "folder.fill" : "book.closed")
                        .font(.title2).foregroundStyle(item.isFolder ? Color.accentColor : .secondary)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.title).foregroundStyle(.primary)
                        HStack {
                            if item.source == .restored { Text("Wiederhergestellte Kopie") }
                            if item.source == .legacyMain { Text("Ursprüngliches Heft") }
                            if !search.isEmpty { Text(path(of: item)) }
                            if location == .recent, let date = item.lastOpened { Text(date, style: .relative) }
                            if location == .trash, let date = item.deletedAt { Text(date, style: .date) }
                        }.font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if item.favorite { Image(systemName: "star.fill").foregroundStyle(.yellow) }
                    if item.isFolder { Image(systemName: "chevron.right").font(.caption) }
                }.padding(.vertical, 6).contentShape(Rectangle())
            }.buttonStyle(NotyPressStyle()).disabled(!editable || location == .trash)
            Menu { itemActions(item) } label: { Image(systemName: "ellipsis.circle").padding(6) }
                .disabled(!editable)
        }
        .draggable(item.id.uuidString)
        .dropDestination(for: String.self) { ids, _ in
            guard item.isFolder else { return false }
            return acceptDrop(ids, parent: item.id)
        }
        .contextMenu { itemActions(item) }
    }

    @ViewBuilder private func itemActions(_ item: NotebookCore.LibraryItem) -> some View {
        if model.snapshot.isTrashed(item.id) {
            Button("Wiederherstellen", systemImage: "arrow.uturn.backward") { Task { await model.restore(item.id) } }
        } else {
            Button("Umbenennen", systemImage: "pencil") { prompt(.rename(item.id), value: item.title) }
            Button("Verschieben", systemImage: "folder") { moving = item }
            Button(item.favorite ? "Aus Favoriten entfernen" : "Zu Favoriten", systemImage: item.favorite ? "star.slash" : "star") {
                Task { await model.favorite(item) }
            }
            Button("In den Papierkorb", systemImage: "trash", role: .destructive) { trashing = item }
        }
    }

    private func branches(parent: UUID?) -> [FolderBranch] {
        model.snapshot.children(of: parent).filter(\.isFolder).map { item in
            let children = branches(parent: item.id)
            return FolderBranch(item: item, children: children.isEmpty ? nil : children)
        }
    }
    private func acceptDrop(_ ids: [String], parent: UUID?) -> Bool {
        guard editable, location != .trash, ids.count == 1, let id = UUID(uuidString: ids[0]),
              model.snapshot.items.contains(where: { $0.id == id }), !model.snapshot.isTrashed(id) else { return false }
        Task { await model.move(id, to: parent) }
        return true
    }
    private func path(of item: NotebookCore.LibraryItem) -> String { libraryPath(item, in: model.snapshot) }
    private func goUp(from id: UUID) {
        let parent = model.snapshot.items.first { $0.id == id }?.parentID
        location = parent.map(LibraryLocation.folder) ?? .root
    }
    private var nameTitle: String {
        switch nameAction {
        case .folder: "Neuer Ordner"
        case .notebook: "Neues Heft"
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
            case .notebook: _ = await model.createNotebook(value, parent: parent)
            case .rename(let id): await model.rename(id, title: value)
            }
        }
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
        .task(id: "\(item.id)-\(item.lastOpened?.timeIntervalSince1970 ?? 0)") {
            do {
                let result = try await model.artwork(for: item.id, cache: cache)
                try Task.checkCancellation()
                appearance = result.0; image = result.1; failed = false
            } catch is CancellationError { }
            catch { failed = true }
        }
    }
}
