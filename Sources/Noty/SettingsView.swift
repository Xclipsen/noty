import SwiftUI
import NotebookCore

/// App-wide keys (UserDefaults/@AppStorage). Per-area settings live in the
/// area's `toolbar.json` (ToolbarPreferences) and in area-keyed backup policies.
enum AppSettingsKey {
    static let homeLayout = "noty.home.layout"
    static let librarySort = "noty.library.sort"
    static let writingScroll = "noty.editor.writingScroll"
    static let typewriter = "noty.editor.typewriter"
    static let sidebarVisible = "noty.sidebar.visible"
    static let hangProbe = "noty.diagnostics.hangProbe"
}

enum LibraryLayout: String, CaseIterable, Identifiable {
    case grid, list
    var id: String { rawValue }
    var title: String { self == .grid ? "Raster" : "Liste" }
    var symbol: String { self == .grid ? "square.grid.2x2" : "list.bullet" }
}

enum LibrarySort: String, CaseIterable, Identifiable {
    case manual, name, recent
    var id: String { rawValue }
    var title: String {
        switch self { case .manual: "Eigene Reihenfolge"; case .name: "Name"; case .recent: "Zuletzt geöffnet" }
    }
    /// Folders stay in front; only the display order changes, never the index.
    func apply(_ items: [NotebookCore.LibraryItem]) -> [NotebookCore.LibraryItem] {
        switch self {
        case .manual: return items
        case .name:
            return items.sorted {
                if $0.isFolder != $1.isFolder { return $0.isFolder }
                return $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
        case .recent:
            let folders = items.filter(\.isFolder)
            let documents = items.filter { !$0.isFolder }.enumerated().sorted { lhs, rhs in
                let (a, b) = (lhs.element.lastOpened, rhs.element.lastOpened)
                if a != b { return (a ?? .distantPast) > (b ?? .distantPast) }
                return lhs.offset < rhs.offset
            }.map(\.element)
            return folders + documents
        }
    }
}

enum SettingsPage: String, CaseIterable, Identifiable, Hashable {
    case general, editor, tools, paper, backup, trash, about, diagnostics
    var id: String { rawValue }
    var title: String {
        switch self {
        case .general: "Allgemein"
        case .editor: "Editor"
        case .tools: "Stift & Werkzeuge"
        case .paper: "Papier-Standards"
        case .backup: "Backup & Daten"
        case .trash: "Papierkorb"
        case .about: "Über noty"
        case .diagnostics: "Diagnose"
        }
    }
    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .editor: "doc.richtext"
        case .tools: "pencil.tip.crop.circle"
        case .paper: "doc.plaintext"
        case .backup: "externaldrive"
        case .trash: "trash"
        case .about: "info.circle"
        case .diagnostics: "stethoscope"
        }
    }
    /// True when the page edits data stored per area (Bereich).
    var perArea: Bool { [.tools, .paper, .backup, .trash].contains(self) }
    /// Rows of the settings root, grouped. `.diagnostics` has no own row; it
    /// opens „Über noty“, which contains the Diagnose section.
    static let rootSections: [[SettingsPage]] = [[.general, .editor, .tools, .paper], [.backup, .trash], [.about]]
}

struct SettingsRequest: Identifiable {
    let id = UUID()
    var page: SettingsPage?
}

/// Lets the editor present the same per-area settings without knowing the
/// library's models; nil outside the library (no settings entry then).
struct EditorSettingsPresenter {
    let make: @MainActor () -> AnyView
}
private struct EditorSettingsKey: EnvironmentKey { static let defaultValue: EditorSettingsPresenter? = nil }
extension EnvironmentValues {
    var editorSettings: EditorSettingsPresenter? {
        get { self[EditorSettingsKey.self] }
        set { self[EditorSettingsKey.self] = newValue }
    }
}

/// Central settings. Presented from the library toolbar; the editor can present
/// it with the same per-area models. `onSelectArea` is nil where switching areas
/// is not possible (e.g. with an open notebook).
struct SettingsView: View {
    @ObservedObject var library: LibraryModel
    @ObservedObject var toolbox: ToolbarSettingsModel
    @ObservedObject var externalBackup: ExternalBackupModel
    @ObservedObject var workspaces: WorkspaceAppModel
    var onSelectArea: ((TestWorkspace?) -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var path: [SettingsPage]

    init(library: LibraryModel, toolbox: ToolbarSettingsModel, externalBackup: ExternalBackupModel,
         workspaces: WorkspaceAppModel, initialPage: SettingsPage? = nil, onSelectArea: ((TestWorkspace?) -> Void)? = nil) {
        self.library = library; self.toolbox = toolbox; self.externalBackup = externalBackup
        self.workspaces = workspaces; self.onSelectArea = onSelectArea
        _path = State(initialValue: initialPage.map { [$0] } ?? [])
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Bereich „\(workspaces.title)“")
                            Text(workspaces.kind == nil ? "Standardbereich" : "Getrennter Test-/Restore-Bereich").font(.caption).foregroundStyle(.secondary)
                        }
                    } icon: { Image(systemName: workspaces.kind == nil ? "books.vertical" : "flask") }
                } footer: {
                    Text("Mit „Bereich“ markierte Einstellungen gelten nur für diesen Bereich und sind in seinem Bibliotheksbackup enthalten. Die übrigen gelten für die ganze App auf diesem iPad.")
                }
                ForEach(SettingsPage.rootSections, id: \.self) { pages in
                    Section {
                        ForEach(pages) { page in pageRow(page) }
                    }
                }
            }
            .navigationTitle("Einstellungen")
            .navigationDestination(for: SettingsPage.self) { page in destination(page) }
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() } } }
        }
        .environmentObject(toolbox)
        .environmentObject(externalBackup)
        // Outside the editor nothing else persists toolbar.json changes.
        .onChange(of: toolbox.preferences) { _, _ in toolbox.save() }
        .interactiveDismissDisabled(library.busy || externalBackup.busy)
        .alert("Bibliothek", isPresented: Binding(get: { library.error != nil }, set: { if !$0 { library.error = nil } })) {
            Button("OK") { library.error = nil }
        } message: { Text(library.error ?? "") }
        .alert("Test- und Restore-Bereiche", isPresented: Binding(get: { workspaces.error != nil }, set: { if !$0 { workspaces.error = nil } })) {
            Button("OK") { workspaces.error = nil }
        } message: { Text(workspaces.error ?? "") }
        .preferredColorScheme(.dark)
    }

    private func pageRow(_ page: SettingsPage) -> some View {
        NavigationLink(value: page) {
            HStack {
                Label(page.title, systemImage: page.symbol)
                Spacer()
                if page == .trash, !library.trashedItems.isEmpty {
                    Text("\(library.trashedItems.count)").foregroundStyle(.secondary).monospacedDigit()
                }
                if page.perArea { Text("Bereich").font(.caption2).foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 2).background(Capsule().fill(.secondary.opacity(0.15))) }
            }
        }
        .accessibilityHint(page.perArea ? "Gilt nur für den aktuellen Bereich" : "Gilt für die ganze App")
    }

    @ViewBuilder private func destination(_ page: SettingsPage) -> some View {
        switch page {
        case .general: GeneralSettingsPage()
        case .editor: EditorSettingsPage(toolbox: toolbox, area: workspaces.title)
        case .tools: ToolSettingsPage(toolbox: toolbox, area: workspaces.title)
        case .paper: PaperSettingsPage(toolbox: toolbox, area: workspaces.title)
        case .backup: BackupSettingsPage(library: library, toolbox: toolbox, externalBackup: externalBackup,
                                         workspaces: workspaces, onSelectArea: onSelectArea)
        case .trash: TrashSettingsPage(library: library, area: workspaces.title)
        case .about, .diagnostics: AboutSettingsPage(toolbox: toolbox, workspaces: workspaces)
        }
    }
}

private func areaFooter(_ area: String) -> some View {
    Text("Gilt für Bereich „\(area)“ und wird mit dessen Werkzeugeinstellungen gespeichert.")
}

private struct GeneralSettingsPage: View {
    @AppStorage(AppSettingsKey.homeLayout) private var layout = LibraryLayout.grid
    @AppStorage(AppSettingsKey.librarySort) private var sort = LibrarySort.manual
    var body: some View {
        Form {
            Section("Bibliothek") {
                Picker("Darstellung", selection: $layout) {
                    ForEach(LibraryLayout.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
                }
                Picker("Sortierung", selection: $sort) {
                    ForEach(LibrarySort.allCases) { Text($0.title).tag($0) }
                }
            }
        }
        .navigationTitle("Allgemein")
    }
}

private struct EditorSettingsPage: View {
    @ObservedObject var toolbox: ToolbarSettingsModel
    let area: String
    @AppStorage(AppSettingsKey.writingScroll) private var writingScroll = false
    @AppStorage(AppSettingsKey.sidebarVisible) private var sidebarVisible = true
    @AppStorage(AppSettingsKey.typewriter) private var typewriter = false
    var body: some View {
        Form {
            Section {
                Toggle("Schreibscrollen bis zur Bildschirmmitte", isOn: $writingScroll)
                Toggle("Seitenleiste beim Öffnen zeigen", isOn: $sidebarVisible)
                Toggle("Schreibmaschinen-Modus beim Tippen", isOn: $typewriter)
            } header: { Text("Alle Bereiche") } footer: {
                Text("Die Seitenleiste merkt sich auch das letzte Ein- oder Ausblenden im Editor. Der Schreibmaschinen-Modus hält die Schreibzeile beim Tippen im oberen Drittel, auch mit schwebender oder externer Tastatur.")
            }
            Section {
                Toggle("Blättern statt vertikal scrollen", isOn: Binding(get: { toolbox.preferences.paging ?? false }, set: { toolbox.preferences.paging = $0 }))
                Toggle("PDFs einheitlich anzeigen", isOn: Binding(get: { toolbox.preferences.normalizePageWidths ?? false }, set: { toolbox.preferences.normalizePageWidths = $0 }))
                    .accessibilityHint("Gleiche Arbeitsblattbreite mit Schreibraum daneben. Ändert nur die Anzeige.")
                Toggle("Auch mit dem Finger zeichnen", isOn: $toolbox.preferences.fingerDrawing)
            } header: { Text("Bereich „\(area)“") } footer: {
                Text("„PDFs einheitlich anzeigen“ ändert nur die Anzeige; PDF-Originale und Export bleiben unverändert. Beim Fingerzeichnen mit zwei Fingern navigieren.")
            }
            .disabled(!toolbox.writable)
            if !toolbox.status.isEmpty { Section { Text(toolbox.status).font(.caption) } }
        }
        .navigationTitle("Editor")
    }
}

private struct ToolSettingsPage: View {
    @ObservedObject var toolbox: ToolbarSettingsModel
    let area: String
    private var hoverPreviewState: String {
        if #available(iOS 17.5, *) { return UIPencilInteraction.prefersHoverToolPreview ? "System: ein" : "System: aus" }
        return "Systemeinstellung"
    }
    var body: some View {
        Form {
            Section {
                Toggle("Autostift für neue Striche", isOn: Binding(get: { toolbox.preferences.autoPen ?? false }, set: { toolbox.preferences.setAutomaticInk($0, for: .pen) }))
                Toggle("Form- und Linienerkennung nach Halten", isOn: Binding(get: { toolbox.preferences.recognizeShapes ?? true }, set: { toolbox.preferences.recognizeShapes = $0 }))
                Picker("Markerspitze", selection: Binding(get: { toolbox.preferences.effectiveMarkerTip }, set: { toolbox.preferences.markerTip = $0 })) {
                    Text("Rund").tag(MarkerTip.round); Text("Keil").tag(MarkerTip.chisel)
                }
                Toggle("Marker immer gerade (rastet bei 0°/90°, 45°, 30° ein)", isOn: Binding(get: { toolbox.preferences.markerStraight ?? false }, set: { toolbox.preferences.markerStraight = $0 }))
                Picker("Radierer-Standard", selection: Binding(get: { toolbox.preferences.eraserPrecision ?? false }, set: { toolbox.preferences.eraserPrecision = $0 })) {
                    Text("Ganzer Strich").tag(false); Text("Präzise").tag(true)
                }
            } header: { Text("Stift, Marker, Radierer") } footer: {
                Text("Autostift wählt für neue Striche eine zur Seitenhelligkeit passende Farbe. Runde Markerspitze: gleichmäßig breit und durchscheinend; Keil: klassischer Marker. Vorhandene Striche bleiben unverändert.")
            }
            // PencilKit offers no per-view switch for its hover tool preview; the
            // system setting is read-only (`prefersHoverToolPreview`). The stored
            // `pencilPreview` field stays in the toolbar format for compatibility.
            Section {
                LabeledContent("Pencil-Hover-Vorschau", value: hoverPreviewState)
            } footer: {
                Text("Die Werkzeugvorschau beim Schweben folgt der Systemeinstellung unter Einstellungen › Apple Pencil. iPadOS bietet Apps keine Möglichkeit, sie nur in noty abzuschalten.")
            }
            Section {
                Picker("Leistenposition", selection: Binding(get: { toolbox.preferences.effectiveDock }, set: { toolbox.preferences.dock = $0 })) {
                    Text("Oben").tag(ToolbarDock.top)
                    Text("Unten").tag(ToolbarDock.bottom)
                    Text("Links").tag(ToolbarDock.left)
                    Text("Rechts").tag(ToolbarDock.right)
                    if toolbox.preferences.dockOnly == false { Text("Schwebend").tag(ToolbarDock.floating) }
                }
                NavigationLink("Werkzeugleiste anpassen") { ToolbarCustomizationList(settings: toolbox) }
            } header: { Text("Werkzeugleiste") } footer: { areaFooter(area) }
            if !toolbox.status.isEmpty { Section { Text(toolbox.status).font(.caption) } }
        }
        .disabled(!toolbox.writable)
        .navigationTitle("Stift & Werkzeuge")
    }
}

private struct PaperSettingsPage: View {
    @ObservedObject var toolbox: ToolbarSettingsModel
    let area: String
    private var appearance: Binding<NotebookAppearance> {
        Binding(get: { toolbox.preferences.defaultAppearance ?? NotebookAppearance() },
                set: { toolbox.preferences.defaultAppearance = $0 })
    }
    var body: some View {
        Form {
            Section {
                HStack(alignment: .top, spacing: 20) {
                    NotebookCoverPreview(appearance: appearance.wrappedValue).aspectRatio(0.71, contentMode: .fit).frame(maxWidth: 110)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("Umschlag", isOn: appearance.coverEnabled)
                        Text("Startwerte für neue Notizbücher. Beim Anlegen weiterhin änderbar; bestehende Notizbücher bleiben unverändert.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                NotebookAppearanceEditor(appearance: appearance, paperHeading: "Papier").padding(.vertical, 6)
            } footer: { areaFooter(area) }
            Section {
                Button("Auf noty-Standard zurücksetzen") { toolbox.preferences.defaultAppearance = nil }
                    .disabled(toolbox.preferences.defaultAppearance == nil)
            }
        }
        .disabled(!toolbox.writable)
        .navigationTitle("Papier-Standards")
    }
}

/// Deliberately short: status at the top right, a few rows, explanations in
/// the info popover. The complete form stays one level deeper.
private struct BackupSettingsPage: View {
    @ObservedObject var library: LibraryModel
    @ObservedObject var toolbox: ToolbarSettingsModel
    @ObservedObject var externalBackup: ExternalBackupModel
    @ObservedObject var workspaces: WorkspaceAppModel
    let onSelectArea: ((TestWorkspace?) -> Void)?
    @State private var exporting = false
    /// One importer for both purposes: two `.fileImporter`s on one view conflict in SwiftUI.
    private enum ImportPurpose { case backupFolder, libraryArchive }
    @State private var importing = false
    @State private var importPurpose = ImportPurpose.libraryArchive
    @State private var showingInfo = false
    @State private var restoredArea = false
    /// The pushed form shows backup errors itself; avoid a second alert.
    @State private var formVisible = false
    @State private var file: LibraryArchiveFile?
    private var libraryIdle: Bool { library.ready && !library.busy && !workspaces.busy && library.opened == nil }
    private var health: BackupHealth { BackupHealth(externalBackup) }
    private var policy: ExternalBackupPolicy { externalBackup.policy }
    private var targetName: String {
        switch policy.target {
        case .disabled: "Keins"
        case .folder: policy.folderName ?? "Dateien-Ordner"
        case .webDAV: URL(string: policy.endpoint)?.host() ?? "WebDAV"
        }
    }
    private var lastBackup: String {
        if externalBackup.busy { return "Läuft …" }
        return policy.lastSuccess.map { $0.formatted(.relative(presentation: .named)) } ?? "Noch keins"
    }
    var body: some View {
        Form {
            Section("Externes Backup") {
                if policy.target == .disabled {
                    Button("Backup-Ordner wählen", systemImage: "folder.badge.plus") { pick(.backupFolder) }
                        .disabled(externalBackup.busy)
                } else {
                    LabeledContent(policy.target == .webDAV ? "WebDAV" : "Ordner", value: targetName)
                    LabeledContent("Letztes Backup", value: lastBackup)
                    Button("Jetzt sichern", systemImage: "arrow.clockwise") {
                        Task { await externalBackup.attempt(library: library, toolbox: toolbox, manual: true) }
                    }.disabled(externalBackup.busy || !library.ready)
                    if policy.target == .folder {
                        Button(health == .folderUnreachable ? "Ordner neu wählen" : "Ordner ändern", systemImage: "folder") { pick(.backupFolder) }
                            .disabled(externalBackup.busy)
                    }
                }
                NavigationLink("Weitere Optionen") {
                    ExternalBackupForm(model: externalBackup, library: library, workspaces: workspaces)
                        .onAppear { formVisible = true }.onDisappear { formVisible = false }
                }
            }
            Section("Bibliotheksdatei") {
                LabeledContent("Letzter Export", value: library.lastLibraryExport.map { $0.formatted(.relative(presentation: .named)) } ?? "Nie")
                Button("Exportieren …", systemImage: "square.and.arrow.up") {
                    Task {
                        guard await toolbox.flush() else { library.error = toolbox.status; return }
                        if let archive = await library.libraryBackup() { file = LibraryArchiveFile(url: archive.url); exporting = true }
                    }
                }.disabled(!libraryIdle)
                Button("Als neuen Bereich wiederherstellen …", systemImage: "arrow.down.doc") { pick(.libraryArchive) }
                    .disabled(!libraryIdle)
            }
            Section {
                NavigationLink {
                    WorkspacePickerList(model: workspaces, onSelect: onSelectArea)
                } label: {
                    LabeledContent("Bereich", value: workspaces.title)
                }
            } footer: {
                if library.opened != nil { Text("Export und Wiederherstellen erst nach dem Schließen des Notizbuchs.") }
            }
        }
        .navigationTitle("Backup & Daten")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showingInfo = true } label: {
                    HStack(spacing: 6) {
                        Text(health.shortTitle).font(.subheadline.weight(.semibold))
                        Image(systemName: "info.circle")
                    }
                    .foregroundStyle(health.isSetUp ? Color.green : Color.orange)
                }
                .accessibilityLabel("Backup-Status: \(health.shortTitle)")
                .accessibilityHint("Zeigt Details zum Backup")
                .popover(isPresented: $showingInfo) { info }
            }
        }
        .overlay { if library.busy || workspaces.busy || externalBackup.busy { ProgressView().padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) } }
        .onAppear { externalBackup.checkFolder() }
        .fileImporter(isPresented: $importing,
                      allowedContentTypes: importPurpose == .backupFolder ? [.folder] : [.notyLibrary, .data]) { result in
            if importPurpose == .backupFolder {
                if case .success(let url) = result { externalBackup.useFolder(url) }
                return
            }
            switch result {
            case .success(let url): Task {
                if await workspaces.restoreLibrary(url) {
                    library.backupStatus = "Bibliothek als neuen Bereich wiederhergestellt · unter Bereiche öffnen"
                    restoredArea = true
                }
            }
            case .failure(let error): library.error = error.localizedDescription
            }
        }
        .fileExporter(isPresented: $exporting, document: file, contentType: .notyLibrary,
                      defaultFilename: "noty-bibliothek-\(Date().formatted(.iso8601).replacingOccurrences(of: ":", with: "-"))") { result in
            switch result {
            case .success: library.libraryBackupExported()
            case .failure(let error):
                library.backupStatus = "Bibliotheksbackup-Export nicht abgeschlossen"
                library.error = error.localizedDescription
            }
        }
        .alert("Externes Backup", isPresented: Binding(get: { externalBackup.error != nil && !formVisible }, set: { if !$0 { externalBackup.error = nil } })) {
            Button("OK") { externalBackup.error = nil }
        } message: { Text(externalBackup.error ?? "") }
        .alert("Als neuen Bereich wiederhergestellt", isPresented: $restoredArea) {
            Button("OK", role: .cancel) { }
        } message: { Text("Unter „Bereich“ verfügbar. Die aktuelle Bibliothek bleibt erhalten.") }
    }

    private func pick(_ purpose: ImportPurpose) { importPurpose = purpose; importing = true }

    /// A few short lines only: status, last backup, target.
    private var info: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(health.shortTitle, systemImage: health.isSetUp ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.headline).foregroundStyle(health.isSetUp ? Color.green : Color.orange)
            LabeledContent("Letztes Backup", value: policy.lastSuccess.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "Noch keins")
            LabeledContent(policy.target == .webDAV ? "WebDAV" : "Ordner", value: targetName)
            if !health.isSetUp, policy.target != .disabled {
                Text(externalBackup.status).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .font(.subheadline)
        .padding(18)
        .frame(width: 300)
        .presentationCompactAdaptation(.popover)
    }
}

private struct TrashSettingsPage: View {
    @ObservedObject var library: LibraryModel
    let area: String
    @State private var purging: NotebookCore.LibraryItem?
    @State private var confirmingEmpty = false
    private var editable: Bool { library.ready && !library.busy && library.opened == nil }
    private var items: [NotebookCore.LibraryItem] { library.trashedItems }
    var body: some View {
        List {
            if library.opened != nil {
                Section { Label("Bei geöffnetem Notizbuch kann der Papierkorb nicht bearbeitet werden.", systemImage: "info.circle").font(.callout) }
            }
            if let status = library.trashStatus {
                Section { Text(status).font(.callout) }
            }
            Section {
                ForEach(items) { item in row(item) }
            } footer: {
                Text("Einträge im Papierkorb bleiben vollständig gespeichert und sind in Bibliotheksbackups enthalten. noty leert den Papierkorb nie automatisch. Ordner stellen ihren Inhalt mit wieder her.")
            }
            if !items.isEmpty {
                Section {
                    Button("Papierkorb leeren …", systemImage: "trash.slash", role: .destructive) { confirmingEmpty = true }
                        .disabled(!editable)
                }
            }
        }
        .overlay {
            if items.isEmpty {
                ContentUnavailableView("Papierkorb ist leer", systemImage: "trash",
                                       description: Text("Gelöschte Notizbücher und Ordner erscheinen hier, bis du sie wiederherstellst oder endgültig löschst."))
            } else if library.busy { ProgressView() }
        }
        .navigationTitle("Papierkorb · \(area)")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Endgültig löschen?", isPresented: Binding(get: { purging != nil }, set: { if !$0 { purging = nil } }),
                            titleVisibility: .visible, presenting: purging) { item in
            Button("„\(item.title)“ endgültig löschen", role: .destructive) {
                purging = nil
                Task { await library.purge([item.id]) }
            }
            Button("Abbrechen", role: .cancel) { purging = nil }
        } message: { item in
            Text(purgeMessage(item))
        }
        .confirmationDialog("Papierkorb leeren?", isPresented: $confirmingEmpty, titleVisibility: .visible) {
            Button("Alle \(items.count) Einträge endgültig löschen", role: .destructive) { Task { await library.emptyTrash() } }
            Button("Abbrechen", role: .cancel) { }
        } message: {
            Text("Alle Einträge im Papierkorb einschließlich enthaltener Ordnerinhalte werden vom iPad entfernt. Das kann nicht rückgängig gemacht werden. Ältere Backups enthalten diese Einträge weiterhin.")
        }
        .onDisappear { library.trashStatus = nil }
    }

    private func row(_ item: NotebookCore.LibraryItem) -> some View {
        HStack(spacing: 14) {
            Image(systemName: item.isFolder ? "folder" : "book.closed").font(.title3).foregroundStyle(.secondary).frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                HStack(spacing: 6) {
                    if let date = item.deletedAt { Text("Gelöscht \(date.formatted(date: .abbreviated, time: .shortened))") }
                    let count = library.purgeCount(item) - 1
                    if item.isFolder { Text(count == 1 ? "· 1 enthaltener Eintrag" : "· \(count) enthaltene Einträge") }
                    if item.source == .legacyMain { Text("· Ursprüngliches Notizbuch") }
                }.font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Menu {
                Button("Wiederherstellen", systemImage: "arrow.uturn.backward") { Task { await library.restore(item.id) } }
                if item.source != .legacyMain {
                    Button("Endgültig löschen …", systemImage: "trash.slash", role: .destructive) { purging = item }
                }
            } label: { Image(systemName: "ellipsis.circle").font(.title3).frame(width: 44, height: 44) }
                .accessibilityLabel("Aktionen für \(item.title)")
                .disabled(!editable)
        }
        .swipeActions(edge: .trailing) {
            if item.source != .legacyMain {
                Button("Endgültig löschen", systemImage: "trash.slash", role: .destructive) { purging = item }.disabled(!editable)
            }
            Button("Wiederherstellen", systemImage: "arrow.uturn.backward") { Task { await library.restore(item.id) } }
                .tint(.blue).disabled(!editable)
        }
        .contextMenu {
            Button("Wiederherstellen", systemImage: "arrow.uturn.backward") { Task { await library.restore(item.id) } }.disabled(!editable)
            if item.source != .legacyMain {
                Button("Endgültig löschen …", systemImage: "trash.slash", role: .destructive) { purging = item }.disabled(!editable)
            }
        }
    }

    private func purgeMessage(_ item: NotebookCore.LibraryItem) -> String {
        let contained = library.purgeCount(item) - 1
        let content = item.isFolder && contained > 0 ? " einschließlich \(contained) enthaltener Einträge" : ""
        return "„\(item.title)“\(content) wird vom iPad entfernt. Das kann nicht rückgängig gemacht werden. Ältere Backups enthalten den Eintrag weiterhin."
    }
}

private struct AboutSettingsPage: View {
    @ObservedObject var toolbox: ToolbarSettingsModel
    @ObservedObject var workspaces: WorkspaceAppModel
    @AppStorage(AppSettingsKey.hangProbe) private var hangProbe = false
    private func info(_ key: String) -> String { Bundle.main.object(forInfoDictionaryKey: key) as? String ?? "–" }
    var body: some View {
        Form {
            Section("noty") {
                LabeledContent("Version", value: info("CFBundleShortVersionString"))
                LabeledContent("Build", value: info("CFBundleVersion"))
                LabeledContent("Werkzeugformat", value: "\(toolbox.preferences.formatVersion)")
                LabeledContent("Bibliotheksindex", value: "Format 1")
            }
            Section {
                LabeledContent("Meine Bibliothek", value: "Auf meinem iPad › noty › Noty")
                LabeledContent("Test-/Restore-Bereiche", value: "Auf meinem iPad › noty › NotyWorkspaces")
                LabeledContent("Aktueller Bereich", value: workspaces.title)
            } header: { Text("Datenablage") } footer: {
                Text("Alle Unterlagen liegen lokal im App-Container und sind über die Dateien-App sichtbar. Dort bitte nichts umbenennen oder verschieben. noty hat kein Konto und keinen eigenen Server; Daten verlassen das iPad nur über ein selbst eingerichtetes Backup oder einen Export.")
            }
            SigningRenewalSection()
            Section {
                Toggle("Hänger-Diagnose", isOn: $hangProbe)
            } header: { Text("Diagnose") } footer: {
                Text("Protokolliert bei längeren Hängern nur Codeadressen und Zähler im Systemprotokoll, keine Inhalte. Wirkt nach einem Neustart der App.")
            }
        }
        .navigationTitle("Über noty")
    }
}
