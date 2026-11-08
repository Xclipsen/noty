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
    /// Input diagnosis (`InputProbe`): on by default in noty dev only.
    static let inputProbe = "noty.diagnostics.inputProbe"
    /// „Textwerkzeug fixieren“ (lock in the text tool's options).
    static let textToolLocked = "noty.text.toolLocked"
    /// Weiches Einrasten beim Verschieben (default on).
    static let snapping = "noty.editor.snapping"
    /// New text fields start in the automatic colour (default on); off: the last used one.
    static let automaticTextColor = "noty.text.automaticColor"
    /// New text fields on lined/grid paper stand on its lines (default on).
    static let alignTextToLines = "noty.text.alignToLines"
    /// „=“ calculates in the text (default on).
    static let calculator = "noty.editor.calculator"
    /// „-> “ becomes „→ “ while typing (`TextArrowReplacement`, default on).
    static let arrows = "noty.editor.arrows"
    /// Helix keys (docs/KEYBOARD.md): experimental, text documents only, off
    /// unless switched on. A new key: the former `noty.keyboard.mode` meant
    /// the whole app and was on by default.
    static let helixTextDocuments = "noty.keyboard.helixTextDocuments"
    /// Automatic pairs while typing in the keyboard mode: off unless switched on.
    static let autoPairs = "noty.keyboard.autoPairs"
    /// One line after every tap on what it reached (`TapDiagnostics`): off unless switched on.
    static let tapDiagnostics = "noty.debug.tapDiagnostics"
    /// Text editor 2 in text documents (docs/TEXT-EDITOR-2.md): off unless switched on.
    static let textEditor2 = "noty.text.editor2"
    /// Lasso: what it selects (`SelectionFilter.bits`) and freeform/rectangle.
    static let lassoFilter = "noty.lasso.filter"
    static let lassoMode = "noty.lasso.mode"
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
    case general, account, laws, editor, tools, paper, backup, trash, about, diagnostics
    var id: String { rawValue }
    var title: String {
        switch self {
        case .general: "Allgemein"
        case .account: "Konto"
        case .laws: "Gesetzessammlung"
        case .editor: "Editor"
        case .tools: "Stift & Werkzeuge"
        case .paper: "Papier für neue Hefte"
        case .backup: "Backup"
        case .trash: "Papierkorb"
        case .about: "Über noty"
        case .diagnostics: "Diagnose"
        }
    }
    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .account: "person.crop.circle"
        case .laws: "books.vertical"
        case .editor: "rectangle.and.pencil.and.ellipsis"
        case .tools: "pencil.tip.crop.circle"
        case .paper: "squareshape.split.3x3"
        case .backup: "externaldrive"
        case .trash: "trash"
        case .about: "info.circle"
        case .diagnostics: "stethoscope"
        }
    }
    /// True when the page edits data stored per area (Bereich).
    var perArea: Bool { [.tools, .paper, .backup, .trash].contains(self) }
    /// Rows of the settings root, grouped.
    static let rootSections: [[SettingsPage]] = [[.general, .account, .laws, .editor, .tools, .paper], [.backup, .trash], [.about, .diagnostics]]
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
                            Text("Bereich \(NotyText.quoted(workspaces.title))")
                            Text(workspaces.kind == nil ? "Standardbereich" : workspaces.kind == .mirror ? "Spiegel einer anderen noty-App, wird beim nächsten Abgleich ersetzt" : "Getrennter Test-/Restore-Bereich").font(.caption).foregroundStyle(.secondary)
                        }
                    } icon: { Image(systemName: workspaces.kind.symbol) }
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
            .keyboardSheet()
        }
        .environmentObject(toolbox)
        .environmentObject(externalBackup)
        // Outside the editor nothing else persists toolbar.json changes.
        .onChange(of: toolbox.preferences) { _, _ in toolbox.save() }
        .interactiveDismissDisabled(library.busy || externalBackup.busy)
        .alert("Bibliothek", isPresented: Binding(get: { library.error != nil }, set: { if !$0 { library.error = nil } })) {
            Button("OK") { library.error = nil }
        } message: { Text(library.error ?? "") }
        .alert("Bereiche", isPresented: Binding(get: { workspaces.error != nil }, set: { if !$0 { workspaces.error = nil } })) {
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
        .keyOption(.action { path.append(page) })
    }

    @ViewBuilder private func destination(_ page: SettingsPage) -> some View {
        switch page {
        case .general: GeneralSettingsPage()
        case .account: NotyAccountSettingsPage()
        case .laws: LawSettingsPage()
        case .editor: EditorSettingsPage(toolbox: toolbox, area: workspaces.title)
        case .tools: ToolSettingsPage(toolbox: toolbox, area: workspaces.title)
        case .paper: PaperSettingsPage(toolbox: toolbox, area: workspaces.title)
        case .backup: BackupSettingsPage(library: library, toolbox: toolbox, externalBackup: externalBackup,
                                         workspaces: workspaces, onSelectArea: onSelectArea)
        case .trash: TrashSettingsPage(library: library, area: workspaces.title)
        case .about: AboutSettingsPage(toolbox: toolbox, workspaces: workspaces)
        case .diagnostics: DiagnosticsSettingsPage()
        }
    }
}

private func areaFooter(_ area: String) -> some View {
    Text("Gilt für Bereich \(NotyText.quoted(area)) und wird mit dessen Werkzeugeinstellungen gespeichert.")
}

private struct GeneralSettingsPage: View {
    @AppStorage(AppSettingsKey.homeLayout) private var layout = LibraryLayout.grid
    @AppStorage(AppSettingsKey.librarySort) private var sort = LibrarySort.manual
    var body: some View {
        Form {
            Section("Bibliothek") {
                Picker("Darstellung", selection: $layout) {
                    ForEach(LibraryLayout.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
                }.keyOption(.choice($layout, LibraryLayout.allCases))
                Picker("Sortierung", selection: $sort) {
                    ForEach(LibrarySort.allCases) { Text($0.title).tag($0) }
                }.keyOption(.choice($sort, LibrarySort.allCases))
            }
        }
        .navigationTitle("Allgemein")
        .keyboardSheet()
    }
}

private struct EditorSettingsPage: View {
    @ObservedObject var toolbox: ToolbarSettingsModel
    let area: String
    @AppStorage(AppSettingsKey.writingScroll) private var writingScroll = false
    @AppStorage(AppSettingsKey.sidebarVisible) private var sidebarVisible = true
    @AppStorage(AppSettingsKey.typewriter) private var typewriter = false
    @AppStorage(AppSettingsKey.snapping) private var snapping = true
    @AppStorage(AppSettingsKey.calculator) private var calculator = true
    @AppStorage(AppSettingsKey.arrows) private var arrows = true
    @AppStorage(AppSettingsKey.automaticTextColor) private var automaticTextColor = true
    @AppStorage(AppSettingsKey.alignTextToLines) private var alignTextToLines = true
    @AppStorage(AppSettingsKey.helixTextDocuments) private var helix = false
    @AppStorage(AppSettingsKey.autoPairs) private var autoPairs = false
    var body: some View {
        Form {
            Section {
                keyToggle("Schreibscrollen bis zur Bildschirmmitte", isOn: $writingScroll)
                keyToggle("Seitenleiste beim Öffnen zeigen", isOn: $sidebarVisible)
                keyToggle("Schreibmaschinen-Modus beim Tippen", isOn: $typewriter)
                keyToggle("Neue Textfelder in automatischer Farbe", isOn: $automaticTextColor)
                    .accessibilityHint("Schwarz oder Weiß passend zum Papier. Aus: Neue Felder übernehmen die zuletzt benutzte Farbe.")
                keyToggle("Neue Textfelder an Linien ausrichten", isOn: $alignTextToLines)
                    .accessibilityHint("Auf liniertem oder kariertem Papier stehen die Zeilen neuer Textfelder auf den Linien. Bestehende Felder bleiben unverändert; jedes Feld lässt sich in der Formatleiste umschalten.")
                keyToggle("Rechnen mit „=“", isOn: $calculator)
                    .accessibilityHint("2+3= wird zu 2+3=5, 2 + 3 = zu 2 + 3 = 5. Von oben nach unten: Zahlen untereinander, dann = allein in einer neuen Zeile.")
                keyToggle("Pfeile beim Tippen (-> wird →)", isOn: $arrows)
                    .accessibilityHint("Mit dem folgenden Leerzeichen: -> wird →, => wird ⇒, <- wird ←, <-> wird ↔, nur am Zeilenanfang oder nach einem Leerzeichen. ⌫ direkt danach stellt das Getippte wieder her.")
                keyToggle("Einrasten", isOn: $snapping)
                    .accessibilityHint("Textfelder, Bilder, Formen und Auswahlen rasten beim langsamen Verschieben an Kanten, Mitten, Linien und Seitenrändern ein.")
                keyToggle("Helix-Tastatur in Textdokumenten (experimentell)", isOn: $helix)
                    .accessibilityHint("Steuert Textdokumente mit einer Hardware-Tastatur: Erst auswählen, dann handeln. i schreibt, Esc geht eine Ebene zurück, die Leertaste öffnet das Menü, Leertaste und h zeigen alle Tasten. Hefte und Bibliothek bleiben unverändert.")
                Toggle("Klammern automatisch schließen", isOn: $autoPairs)
                    .disabled(!helix)
                    .accessibilityHint("Mit der Helix-Tastatur schließt die Eingabe runde, eckige und geschweifte Klammern und Anführungszeichen selbst, außer direkt neben einem Wort.")
            } header: { Text("Alle Bereiche") } footer: {
                Text("Die Helix-Tastatur ist experimentell und wirkt nur in Textdokumenten mit einer Hardware-Tastatur. Die Seitenleiste merkt sich auch das letzte Ein- oder Ausblenden im Editor. Der Schreibmaschinen-Modus hält die Schreibzeile beim Tippen im oberen Drittel, auch mit schwebender oder externer Tastatur. Einrasten wirkt nur bei langsamer Bewegung; ein zweiter Finger auf dem Bildschirm unterdrückt es beim Ziehen. „An Linien ausrichten“ wirkt nur auf liniertem oder kariertem Papier und in Schreibplatz mit Linien; bestehende Felder bleiben, wie sie sind.")
            }
            Section {
                keyToggle("Blättern statt vertikal scrollen", isOn: Binding(get: { toolbox.preferences.paging ?? false }, set: { toolbox.preferences.paging = $0 }))
                keyToggle("PDFs einheitlich anzeigen", isOn: Binding(get: { toolbox.preferences.normalizePageWidths ?? false }, set: { toolbox.preferences.normalizePageWidths = $0 }))
                    .accessibilityHint("Gleiche Arbeitsblattbreite mit Schreibraum daneben. Ändert nur die Anzeige.")
                keyToggle("Auch mit dem Finger zeichnen", isOn: $toolbox.preferences.fingerDrawing)
            } header: { Text("Bereich \(NotyText.quoted(area))") } footer: {
                Text("„PDFs einheitlich anzeigen“ ändert nur die Anzeige; PDF-Originale und Export bleiben unverändert. Beim Fingerzeichnen mit zwei Fingern navigieren.")
            }
            .disabled(!toolbox.writable)
            if !toolbox.status.isEmpty { Section { Text(toolbox.status).font(.caption) } }
        }
        .navigationTitle("Editor")
        .keyboardSheet()
    }
}

private struct ToolSettingsPage: View {
    @ObservedObject var toolbox: ToolbarSettingsModel
    let area: String
    /// A link has no action a key could run.
    @State private var customizing = false
    private var hoverPreviewState: String {
        if #available(iOS 17.5, *) { return UIPencilInteraction.prefersHoverToolPreview ? "System: ein" : "System: aus" }
        return "Systemeinstellung"
    }
    var body: some View {
        Form {
            Section {
                keyToggle("Autostift für neue Striche", isOn: Binding(get: { toolbox.preferences.autoPen ?? false }, set: { toolbox.preferences.setAutomaticInk($0, for: .pen) }))
                keyToggle("Stift/Bleistift: Formen nach Halten erkennen", isOn: Binding(get: { toolbox.preferences.recognizeShapes ?? true }, set: { toolbox.preferences.recognizeShapes = $0 }))
                keyToggle("Textmarker: Linie nach Halten begradigen", isOn: Binding(get: { toolbox.preferences.markerHoldStraighten ?? true }, set: { toolbox.preferences.markerHoldStraighten = $0 }))
                let tip = Binding(get: { toolbox.preferences.effectiveMarkerTip }, set: { toolbox.preferences.markerTip = $0 })
                Picker("Textmarkerspitze", selection: tip) {
                    Text("Rund").tag(MarkerTip.round); Text("Keil").tag(MarkerTip.chisel)
                }.keyOption(.choice(tip, [.round, .chisel]))
                keyToggle("Textmarker immer gerade (rastet bei 0°/90°, 45°, 30° ein)", isOn: Binding(get: { toolbox.preferences.markerStraight ?? false }, set: { toolbox.preferences.markerStraight = $0 }))
                let precise = Binding(get: { toolbox.preferences.eraserPrecision ?? false }, set: { toolbox.preferences.eraserPrecision = $0 })
                Picker("Radierer-Standard", selection: precise) {
                    Text("Ganzer Strich").tag(false); Text("Präzise").tag(true)
                }.keyOption(.toggle(precise))
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
                let dock = Binding(get: { toolbox.preferences.effectiveDock }, set: { toolbox.preferences.dock = $0 })
                Picker("Leistenposition", selection: dock) {
                    Text("Oben").tag(ToolbarDock.top)
                    Text("Unten").tag(ToolbarDock.bottom)
                    Text("Links").tag(ToolbarDock.left)
                    Text("Rechts").tag(ToolbarDock.right)
                    if toolbox.preferences.dockOnly == false { Text("Schwebend").tag(ToolbarDock.floating) }
                }.keyOption(.choice(dock, toolbox.preferences.dockOnly == false ? [.top, .bottom, .left, .right, .floating] : [.top, .bottom, .left, .right]))
                NavigationLink("Werkzeugleiste anpassen") { ToolbarCustomizationList(settings: toolbox).keyboardSheet() }
                    .keyOption(.action { customizing = true })
            } header: { Text("Werkzeugleiste") } footer: { areaFooter(area) }
            if !toolbox.status.isEmpty { Section { Text(toolbox.status).font(.caption) } }
        }
        .disabled(!toolbox.writable)
        .navigationTitle("Stift & Werkzeuge")
        .navigationDestination(isPresented: $customizing) { ToolbarCustomizationList(settings: toolbox).keyboardSheet() }
        .keyboardSheet()
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
                        keyToggle("Umschlag", isOn: appearance.coverEnabled)
                        Text("Startwerte für neue Hefte und Textdokumente. Beim Anlegen weiterhin änderbar; bestehende bleiben unverändert.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                NotebookAppearanceEditor(appearance: appearance, paperHeading: "Papier").padding(.vertical, 6)
            } footer: { areaFooter(area) }
            Section {
                Button("Auf noty-Standard zurücksetzen") { toolbox.preferences.defaultAppearance = nil }
                    .disabled(toolbox.preferences.defaultAppearance == nil)
                    .keyOption(.action { toolbox.preferences.defaultAppearance = nil })
            }
        }
        .disabled(!toolbox.writable)
        .navigationTitle("Papier für neue Hefte")
        .keyboardSheet()
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
    @State private var showingForm = false
    @State private var showingAreas = false
    @State private var restoredArea = false
    /// Status of the automatic backup when its last busy phase began (announcements).
    @State private var statusBeforeBackupWork: String?
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
        return policy.lastSuccess.map(NotyText.statusDate) ?? NotyText.never
    }
    var body: some View {
        Form {
            Section("Automatisches Backup") {
                if policy.target == .disabled {
                    Button("Backup-Ordner wählen …", systemImage: "folder.badge.plus") { pick(.backupFolder) }
                        .disabled(externalBackup.busy).keyOption(.action { pick(.backupFolder) })
                } else {
                    LabeledContent(policy.target == .webDAV ? "WebDAV" : "Backup-Ordner", value: targetName)
                    LabeledContent("Letztes Backup", value: lastBackup)
                    Button("Jetzt sichern", systemImage: "arrow.clockwise") {
                        Task { await externalBackup.attempt(library: library, toolbox: toolbox, manual: true) }
                    }.disabled(externalBackup.busy || !library.ready)
                        .keyOption(.action { Task { await externalBackup.attempt(library: library, toolbox: toolbox, manual: true) } })
                    if policy.target == .folder {
                        Button(health == .folderUnreachable ? "Backup-Ordner neu wählen …" : "Backup-Ordner ändern …", systemImage: "folder") { pick(.backupFolder) }
                            .disabled(externalBackup.busy).keyOption(.action { pick(.backupFolder) })
                    }
                }
                NavigationLink("Weitere Optionen") { backupForm }.keyOption(.action { showingForm = true })
            }
            Section {
                LabeledContent("Letzter Export", value: library.lastLibraryExport.map(NotyText.statusDate) ?? NotyText.never)
                Button("Exportieren …", systemImage: "square.and.arrow.up", action: exportLibrary).disabled(!libraryIdle)
                    .keyOption(.action(exportLibrary))
                Button("Als neuen Bereich wiederherstellen …", systemImage: "arrow.down.doc") { pick(.libraryArchive) }
                    .disabled(!libraryIdle).keyOption(.action { pick(.libraryArchive) })
            } header: { Text("Bibliotheksbackup") } footer: {
                Text("Enthält alle Hefte, Ordner, Papierkorb und Einstellungen dieses Bereichs sowie den Kalender (eigene und gelöschte Termine, Terminnotiz-Verknüpfungen, Fachfarben, Offline-Stundenplan). WebUntis-Zugangsdaten sind nie enthalten. Ein einzelnes Heftbackup enthält keinen Kalender.")
            }
            AppSyncSection(library: library, toolbox: toolbox, workspaces: workspaces)
            Section {
                NavigationLink {
                    WorkspacePickerList(model: workspaces, onSelect: onSelectArea).keyboardSheet()
                } label: {
                    LabeledContent("Bereiche", value: workspaces.title)
                }
                .disabled(library.busy && !library.backgroundBusy)
                .keyOption(.action { showingAreas = true })
            } footer: {
                if library.opened != nil { Text("Export und Wiederherstellen erst nach dem Schließen des Hefts.") }
            }
        }
        .navigationTitle("Backup")
        .navigationDestination(isPresented: $showingForm) { backupForm }
        .navigationDestination(isPresented: $showingAreas) { WorkspacePickerList(model: workspaces, onSelect: onSelectArea).keyboardSheet() }
        .keyboardSheet()
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
        .overlay { if library.busy || workspaces.busy || externalBackup.busy { ProgressView(activityTitle).padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) } }
        // Results of backup work for VoiceOver (polish audit F10); steps ending in „…“ stay silent.
        .onChange(of: library.backupStatus) { _, note in
            if !note.hasSuffix("…") { AccessibilityNotification.Announcement(note).post() }
        }
        // Only a new result: retrieving an archive leaves the status as it was,
        // so an unchanged (or still running „…“) status stays silent.
        .onChange(of: externalBackup.busy) { _, busy in
            if busy { statusBeforeBackupWork = externalBackup.status; return }
            let status = externalBackup.status
            if status != statusBeforeBackupWork, !status.hasSuffix("…") { AccessibilityNotification.Announcement(status).post() }
            statusBeforeBackupWork = nil
        }
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
                    library.backupStatus = "Bibliothek als neuen Bereich wiederhergestellt · Einstellungen › Backup › Bereiche"
                    restoredArea = true
                }
            }
            case .failure(let error): library.error = error.localizedDescription
            }
        }
        .fileExporter(isPresented: $exporting, document: file, contentType: .notyLibrary,
                      defaultFilename: NotyText.libraryFileName()) { result in
            switch result {
            case .success: library.libraryBackupExported()
            case .failure(let error):
                library.backupStatus = "Bibliotheksbackup-Export nicht abgeschlossen"
                library.error = error.localizedDescription
            }
        }
        .alert("Backup", isPresented: Binding(get: { externalBackup.error != nil && !formVisible }, set: { if !$0 { externalBackup.error = nil } })) {
            Button("OK") { externalBackup.error = nil }
        } message: { Text(externalBackup.error ?? "") }
        .alert("Als neuen Bereich wiederhergestellt", isPresented: $restoredArea) {
            Button("OK", role: .cancel) { }
        } message: { Text(NotyText.restoredAreaMessage) }
    }

    private func pick(_ purpose: ImportPurpose) { importPurpose = purpose; importing = true }
    /// Words for the spinner: what is running (polish audit F8, labels only).
    private var activityTitle: String {
        if externalBackup.busy {
            // The external backup reports its steps; retrieving keeps the last note.
            return externalBackup.status.hasSuffix("…") ? externalBackup.status : "Backup wird geladen und geprüft …"
        }
        if workspaces.busy { return "Bereich wird übernommen …" }
        return "Bibliotheksbackup wird erstellt …"
    }
    private func exportLibrary() {
        Task {
            guard await toolbox.flush() else { library.error = toolbox.status; return }
            if let archive = await library.libraryBackup() { file = LibraryArchiveFile(url: archive.url); exporting = true }
        }
    }
    private var backupForm: some View {
        ExternalBackupForm(model: externalBackup, library: library, workspaces: workspaces)
            .onAppear { formVisible = true }.onDisappear { formVisible = false }
            .keyboardSheet()
    }

    /// A few short lines only: status, last backup, target.
    private var info: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(health.shortTitle, systemImage: health.isSetUp ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.headline).foregroundStyle(health.isSetUp ? Color.green : Color.orange)
            LabeledContent("Letztes Backup", value: policy.lastSuccess.map(NotyText.statusDate) ?? NotyText.never)
            LabeledContent(policy.target == .webDAV ? "WebDAV" : "Backup-Ordner", value: targetName)
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
                Section { Label("Bei geöffnetem Heft kann der Papierkorb nicht bearbeitet werden.", systemImage: "info.circle").font(.callout) }
            }
            if let status = library.trashStatus {
                Section { Text(status).font(.callout) }
            }
            Section {
                ForEach(items) { item in row(item).keyOption(.action { ask(item) }) }
            } footer: {
                Text("Einträge im Papierkorb bleiben vollständig gespeichert und sind in Bibliotheksbackups enthalten. noty leert den Papierkorb nie automatisch. Ordner stellen ihren Inhalt mit wieder her.")
            }
            if !items.isEmpty {
                Section {
                    Button("Papierkorb leeren …", systemImage: "trash.slash", role: .destructive) { confirmingEmpty = true }
                        .disabled(!editable)
                        .keyOption(.action {
                            KeyboardRouter.shared.ask("Papierkorb leeren?", message: "Alle Einträge im Papierkorb einschließlich enthaltener Ordnerinhalte werden vom iPad entfernt. Das kann nicht rückgängig gemacht werden.",
                                                      confirm: "\(NotyText.count(items.count, "Eintrag", "Einträge")) endgültig löschen", safe: true) { Task { await library.emptyTrash() } }
                        })
                }
            }
        }
        .overlay {
            if items.isEmpty {
                ContentUnavailableView("Papierkorb ist leer", systemImage: "trash",
                                       description: Text("Gelöschte Hefte, Textdokumente und Ordner erscheinen hier, bis sie wiederhergestellt oder endgültig gelöscht werden."))
            } else if library.busy { ProgressView("Papierkorb wird bearbeitet …") }
        }
        .navigationTitle("Papierkorb · \(NotyText.isolated(area))")
        .navigationBarTitleDisplayMode(.inline)
        .keyboardSheet()
        .confirmationDialog("Endgültig löschen?", isPresented: Binding(get: { purging != nil }, set: { if !$0 { purging = nil } }),
                            titleVisibility: .visible, presenting: purging) { item in
            // Fixed verb: a long title in the button would truncate the action away; the name is in the message.
            Button("Endgültig löschen", role: .destructive) {
                purging = nil
                Task { await library.purge([item.id]) }
            }
            Button("Abbrechen", role: .cancel) { purging = nil }
        } message: { item in
            Text(purgeMessage(item))
        }
        .confirmationDialog("Papierkorb leeren?", isPresented: $confirmingEmpty, titleVisibility: .visible) {
            Button("\(NotyText.count(items.count, "Eintrag", "Einträge")) endgültig löschen", role: .destructive) { Task { await library.emptyTrash() } }
            Button("Abbrechen", role: .cancel) { }
        } message: {
            Text("Alle Einträge im Papierkorb einschließlich enthaltener Ordnerinhalte werden vom iPad entfernt. Das kann nicht rückgängig gemacht werden. Ältere Backups enthalten diese Einträge weiterhin.")
        }
        .onDisappear { library.trashStatus = nil }
    }

    /// Enter on a row: what its menu offers, the final step with its own question.
    private func ask(_ item: NotebookCore.LibraryItem) {
        guard editable else { return }
        var options = [KeyQuestion.Option(title: "Wiederherstellen") { Task { await library.restore(item.id) } }]
        if item.source != .legacyMain {
            options.append(KeyQuestion.Option(title: "Endgültig löschen …", destructive: true) {
                KeyboardRouter.shared.ask("Endgültig löschen?", message: purgeMessage(item), confirm: "Endgültig löschen", safe: true) {
                    Task { await library.purge([item.id]) }
                }
            })
        }
        options.append(KeyQuestion.Option(title: "Abbrechen"))
        KeyboardRouter.shared.present(KeyQuestion(title: item.title, message: "", options: options, chosen: options[0].id))
    }
    private func row(_ item: NotebookCore.LibraryItem) -> some View {
        HStack(spacing: 14) {
            Image(systemName: item.librarySymbol(filled: false)).font(.title3).foregroundStyle(.secondary).frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title).lineLimit(2).truncationMode(.middle)
                // One string: separate texts each wrapped into ragged mini-columns.
                Text(details(item)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
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
                Button("Endgültig löschen …", systemImage: "trash.slash", role: .destructive) { purging = item }.disabled(!editable)
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

    private func details(_ item: NotebookCore.LibraryItem) -> String {
        var parts: [String] = []
        if let date = item.deletedAt { parts.append("Gelöscht \(NotyText.listDate(date))") }
        let count = library.purgeCount(item) - 1
        if item.isFolder, count > 0 { parts.append(NotyText.count(count, "enthaltener Eintrag", "enthaltene Einträge")) }
        if item.source == .legacyMain { parts.append("Ursprüngliches Heft") }
        return parts.joined(separator: " · ")
    }

    private func purgeMessage(_ item: NotebookCore.LibraryItem) -> String {
        let contained = library.purgeCount(item) - 1
        let content = !item.isFolder || contained <= 0 ? ""
            : contained == 1 ? " einschließlich 1 enthaltenen Eintrags" : " einschließlich \(contained) enthaltener Einträge"
        return "\(NotyText.quoted(item.title))\(content) wird vom iPad entfernt. Das kann nicht rückgängig gemacht werden. Ältere Backups enthalten den Eintrag weiterhin."
    }
}

private struct AboutSettingsPage: View {
    @ObservedObject var toolbox: ToolbarSettingsModel
    @ObservedObject var workspaces: WorkspaceAppModel
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
                Text("Alle Unterlagen liegen lokal im App-Container und sind über die Dateien-App sichtbar. Dort bitte nichts umbenennen oder verschieben. Hefte und Textdokumente verlassen das iPad nur über ein selbst eingerichtetes Backup, einen Export oder Teilen. Das freiwillige noty-Konto gleicht nur Lesezeichen und Markierungen der Gesetzessammlung mit law.xclipsen.de ab; Gesetzestexte werden von dort geladen.")
            }
            SigningRenewalSection()
        }
        .navigationTitle("Über noty")
        .keyboardSheet()
    }
}

/// Own page: a freeze of „Über noty“ must not take the tools to find it with it.
private struct DiagnosticsSettingsPage: View {
    @AppStorage(AppSettingsKey.hangProbe) private var hangProbe = false
    @AppStorage(AppSettingsKey.inputProbe) private var inputProbe = InputProbe.defaultEnabled
    @AppStorage(AppSettingsKey.tapDiagnostics) private var tapDiagnostics = false
    @AppStorage(AppSettingsKey.textEditor2) private var textEditor2 = false
    var body: some View {
        Form {
            Section {
                keyToggle("Hänger-Diagnose", isOn: $hangProbe)
                keyToggle("Eingabe-Diagnose", isOn: $inputProbe)
                keyToggle("Tipp-Diagnose", isOn: $tapDiagnostics)
                    .onChange(of: tapDiagnostics) { _, _ in TapDiagnostics.shared.refresh() }
                keyToggle("Neuer Texteditor (Test)", isOn: $textEditor2)
            } footer: {
                Text("Tipp-Diagnose: zeigt nach jedem Tipp, was er getroffen hat und welche Felder dort liegen, nur Größen, keine Inhalte. Hänger-Diagnose: schreibt bei längeren Hängern nur Codeadressen und Zähler ins Systemprotokoll und nach Dateien › Auf meinem iPad › noty › Diagnose › haenger.txt, keine Inhalte. Eingabe-Diagnose: meldet Berührungen ohne Wirkung und lange Eingabesperren nach Dateien › Auf meinem iPad › noty › Diagnose › eingabe.txt, nur Klassennamen und Zustände, keine Inhalte. Beide wirken nach einem Neustart der App. Neuer Texteditor: ein Text über alle Seiten eines Textdokuments, im Blättermodus aus; noch ohne Formatleiste. Wirkt beim nächsten Öffnen eines Dokuments.")
            }
        }
        .navigationTitle("Diagnose")
        .keyboardSheet()
    }
}
