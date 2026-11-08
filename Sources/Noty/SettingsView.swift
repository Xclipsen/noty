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
    /// Reopen the notebook that was open when the app was last used (default on).
    static let reopenLastNotebook = "noty.app.reopenLastNotebook"
    /// `AccentChoice` of the whole app (default blue, the former system tint).
    static let accent = "noty.app.accent"
    /// Developer tools in the normal noty (unlocked in „Über noty“).
    static let developerMode = "noty.app.developerMode"
    /// What „Einstellungen zurücksetzen“ resets: app-wide preferences only;
    /// per-area values (toolbar.json), backups, accounts and data stay.
    static let resettable = [homeLayout, librarySort, writingScroll, typewriter, sidebarVisible, snapping, automaticTextColor,
                             alignTextToLines, calculator, arrows, helixTextDocuments, autoPairs, reopenLastNotebook, accent]
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


enum SettingsPage: String, CaseIterable, Identifiable, Hashable {
    case general, appearance, view, text, tools, paper, calendar, laws, account, backup, trash, about, privacy, developer
    var id: String { rawValue }
    var title: String {
        switch self {
        case .general: "Allgemein"
        case .appearance: "Darstellung"
        case .view: "Ansicht & Seiten"
        case .text: "Text & Tastatur"
        case .tools: "Stift & Werkzeuge"
        case .paper: "Papier für neue Hefte"
        case .calendar: "Kalender"
        case .laws: "Gesetzessammlung"
        case .account: "noty-Konto"
        case .backup: "Backup & Wiederherstellen"
        case .trash: "Papierkorb"
        case .about: "Über noty"
        case .privacy: "Datenschutz"
        case .developer: "Entwickler"
        }
    }
    var symbol: String {
        switch self {
        case .general: "gearshape.fill"
        case .appearance: "paintpalette.fill"
        case .view: "book.pages.fill"
        case .text: "character.cursor.ibeam"
        case .tools: "pencil.tip"
        case .paper: "squareshape.split.3x3"
        case .calendar: "calendar"
        case .laws: "books.vertical.fill"
        case .account: "person.crop.circle.fill"
        case .backup: "externaldrive.fill.badge.icloud"
        case .trash: "trash.fill"
        case .about: "info.circle.fill"
        case .privacy: "hand.raised.fill"
        case .developer: "hammer.fill"
        }
    }
    var tint: Color {
        switch self {
        case .general: Color(white: 0.55)
        case .appearance: Color(red: 0.93, green: 0.36, blue: 0.58)
        case .view: Color(red: 0.25, green: 0.52, blue: 0.98)
        case .text: Color(red: 0.98, green: 0.58, blue: 0.18)
        case .tools: Color(red: 0.16, green: 0.72, blue: 0.62)
        case .paper: Color(red: 0.80, green: 0.62, blue: 0.30)
        // Not red: the Gesetzessammlung beside it is.
        case .calendar: Color(red: 0.58, green: 0.40, blue: 0.92)
        case .laws: Color(red: 0.86, green: 0.30, blue: 0.27)
        case .account: Color(red: 0.36, green: 0.55, blue: 0.95)
        case .backup: Color(red: 0.20, green: 0.70, blue: 0.40)
        case .trash: Color(white: 0.48)
        case .about: Color(red: 0.45, green: 0.50, blue: 0.62)
        case .privacy: Color(red: 0.28, green: 0.45, blue: 0.86)
        case .developer: Color(red: 0.93, green: 0.48, blue: 0.16)
        }
    }
    struct Group: Identifiable { let id: Int; let title: String?; let pages: [SettingsPage] }
    /// Sidebar groups, T3-style: unnamed first and last group.
    @MainActor static func groups(developer: Bool) -> [Group] {
        [Group(id: 0, title: nil, pages: [.general, .appearance]),
         Group(id: 1, title: "Schreiben", pages: [.view, .text, .tools, .paper]),
         Group(id: 2, title: "Funktionen", pages: [.calendar, .laws, .account]),
         Group(id: 3, title: "Daten", pages: [.backup, .trash]),
         Group(id: 4, title: nil, pages: [.about, .privacy] + (developer ? [.developer] : []))]
    }
}

/// Central settings. Presented from the library toolbar; the editor can present
/// it with the same per-area models. `onSelectArea` is nil where switching areas
/// is not possible (e.g. with an open notebook). Wide: sidebar with groups,
/// search and the page beside it; narrow: a list that pushes the pages.
struct SettingsView: View {
    @ObservedObject var library: LibraryModel
    @ObservedObject var toolbox: ToolbarSettingsModel
    @ObservedObject var externalBackup: ExternalBackupModel
    @ObservedObject var workspaces: WorkspaceAppModel
    /// The calendar of the open area (owned by `WorkspaceLibraryHost`); its
    /// pages observe it themselves.
    let calendar: CalendarModel
    var onSelectArea: ((TestWorkspace?) -> Void)?
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var vault = NotebookVaultModel.shared
    @AppStorage(AppSettingsKey.developerMode) private var developerMode = false
    @AppStorage(AppSettingsKey.accent) private var accent = AccentChoice.blue
    @State private var selection: SettingsPage?
    @State private var path: [SettingsPage]
    @State private var query = ""
    /// The sub-page of the search hit just chosen (handed to its page, which clears it).
    @State private var subpage: SettingsSubpage?

    init(library: LibraryModel, toolbox: ToolbarSettingsModel, externalBackup: ExternalBackupModel,
         workspaces: WorkspaceAppModel, calendar: CalendarModel, initialPage: SettingsPage? = nil,
         onSelectArea: ((TestWorkspace?) -> Void)? = nil) {
        self.library = library; self.toolbox = toolbox; self.externalBackup = externalBackup
        self.workspaces = workspaces; self.calendar = calendar; self.onSelectArea = onSelectArea
        _selection = State(initialValue: initialPage ?? .general)
        _path = State(initialValue: initialPage.map { [$0] } ?? [])
    }

    private var developer: Bool { _ = developerMode; return DeveloperAccess.visible }

    var body: some View {
        GeometryReader { proxy in
            if proxy.size.width >= 680 { split } else { stack }
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
        .tint(accent.color)
        .preferredColorScheme(.dark)
    }

    // MARK: Layouts

    /// The sidebar keeps its page while a page must not be left
    /// (`CalendarModel.connectionBusy`: WebUntis connects).
    private var guardedSelection: Binding<SettingsPage?> {
        Binding(get: { selection }, set: { page in if !calendar.connectionBusy { selection = page } })
    }

    private var split: some View {
        HStack(spacing: 0) {
            List(selection: guardedSelection) {
                sidebarContent(pushes: false)
            }
            .listStyle(.sidebar)
            .frame(width: 300)
            .modifier(DisabledWhileConnecting(calendar: calendar))
            Divider().ignoresSafeArea()
            NavigationStack {
                destination(selection ?? .general)
                    .frame(maxWidth: 820)
                    .frame(maxWidth: .infinity)
                    .background(Color(uiColor: .systemGroupedBackground))
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() } } }
            }
            .id(selection)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .background { splitKeys }
        .onChange(of: developer) { _, visible in if !visible, selection == .developer { selection = .about } }
        // A narrower window shows the same page in the list layout.
        .onChange(of: selection) { _, page in path = page.map { [$0] } ?? [] }
    }

    /// The sidebar takes no keys of its own: ⌘↓/⌘↑ step through the pages,
    /// Esc closes Settings where the page itself does not take it.
    private var splitKeys: some View {
        Group {
            Button("") { step(1) }.keyboardShortcut(.downArrow, modifiers: .command)
            Button("") { step(-1) }.keyboardShortcut(.upArrow, modifiers: .command)
            KeyEscapeButton { if !calendar.connectionBusy { dismiss() } }
        }
        .frame(width: 0, height: 0).opacity(0).accessibilityHidden(true)
    }

    private func step(_ offset: Int) {
        guard !calendar.connectionBusy else { return }
        let pages = SettingsPage.groups(developer: developer).flatMap(\.pages)
        guard !pages.isEmpty else { return }
        let index = pages.firstIndex(of: selection ?? .general) ?? 0
        selection = pages[(index + offset + pages.count) % pages.count]
    }

    private var stack: some View {
        NavigationStack(path: $path) {
            List { sidebarContent(pushes: true) }
                .navigationTitle("Einstellungen")
                .navigationDestination(for: SettingsPage.self) { page in destination(page) }
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() } } }
                .keyboardSheet(onCancel: { if !calendar.connectionBusy { dismiss() } })
        }
        .onChange(of: path) { _, pages in if let page = pages.first { selection = page } }
    }

    // MARK: Sidebar

    @ViewBuilder private func sidebarContent(pushes: Bool) -> some View {
        Section {
            SettingsHeaderCard()
            if workspaces.areaID != nil {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Bereich \(NotyText.quoted(workspaces.title))")
                        Text(workspaces.kind == .mirror ? "Spiegel einer anderen noty-App" : "Getrennter Bereich mit eigenen Heften")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } icon: { Image(systemName: workspaces.kind.symbol).foregroundStyle(.orange) }
            }
            searchField
        }
        if query.trimmingCharacters(in: .whitespaces).isEmpty {
            ForEach(SettingsPage.groups(developer: developer)) { group in
                Section {
                    ForEach(group.pages) { page in pageRow(page, pushes: pushes) }
                } header: {
                    if let title = group.title { Text(title) }
                }
            }
        } else {
            let hits = SettingsSearchItem.index(developer: developer, vault: vault.available).filter { $0.matches(query) }
            Section("Treffer") {
                if hits.isEmpty {
                    Text("Keine Einstellung gefunden").foregroundStyle(.secondary)
                }
                ForEach(hits) { hit in
                    let label = HStack(spacing: 12) {
                        SettingsTile(symbol: hit.page.symbol, color: hit.page.tint, size: 26)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(hit.title)
                            Text(([hit.page.title] + [hit.section].compactMap { $0 }).joined(separator: " › "))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if pushes {
                        // A button, not a link: the hit may name a sub-page of its page.
                        Button { open(hit, pushes: true) } label: {
                            HStack {
                                label
                                Spacer(minLength: 4)
                                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .keyOption(.action { open(hit, pushes: true) })
                    } else {
                        Button { open(hit, pushes: false) } label: { label.contentShape(Rectangle()) }
                            .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    /// A search hit: its page and, where it has one, its sub-page. The list
    /// layout pushes the page (the search stays for the way back), the
    /// sidebar selects it.
    private func open(_ hit: SettingsSearchItem, pushes: Bool) {
        guard !calendar.connectionBusy else { return }
        subpage = hit.subpage
        if pushes { path.append(hit.page) } else { selection = hit.page; query = "" }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Einstellungen durchsuchen", text: $query)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .submitLabel(.search)
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain).accessibilityLabel("Suche löschen")
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder private func pageRow(_ page: SettingsPage, pushes: Bool) -> some View {
        let label = HStack(spacing: 12) {
            SettingsTile(symbol: page.symbol, color: page.tint)
            Text(page.title)
            Spacer(minLength: 4)
            trailing(page)
        }
        if pushes {
            NavigationLink(value: page) { label }.keyOption(.action { path.append(page) })
        } else {
            label.tag(page)
        }
    }

    @ViewBuilder private func trailing(_ page: SettingsPage) -> some View {
        switch page {
        case .trash where !library.trashedItems.isEmpty:
            Text("\(library.trashedItems.count)").foregroundStyle(.secondary).monospacedDigit()
        case .backup:
            let healthy = BackupHealth(externalBackup).isSetUp
            Circle().fill(healthy ? Color.green : Color.orange).frame(width: 8, height: 8)
                .accessibilityLabel(healthy ? "Backup eingerichtet" : "Backup prüfen")
        case .developer:
            if let channel = AppSyncModel.shared.channel, channel != .stable { SettingsBadge(channel.appName) }
        default: EmptyView()
        }
    }

    // MARK: Pages

    @ViewBuilder private func destination(_ page: SettingsPage) -> some View {
        switch page {
        case .general: GeneralSettingsPage()
        case .appearance: AppearanceSettingsPage()
        case .view: ViewSettingsPage(toolbox: toolbox, workspaces: workspaces)
        case .text: TextSettingsPage()
        case .tools: ToolSettingsPage(toolbox: toolbox, workspaces: workspaces)
        case .paper: PaperSettingsPage(toolbox: toolbox, workspaces: workspaces)
        case .calendar: CalendarSettingsPage(model: calendar, workspaces: workspaces, open: $subpage)
        case .laws: LawSettingsPage()
        case .account: NotyAccountSettingsPage()
        case .backup: BackupSettingsPage(library: library, toolbox: toolbox, externalBackup: externalBackup,
                                         workspaces: workspaces, onSelectArea: onSelectArea)
        case .trash: TrashSettingsPage(library: library, workspaces: workspaces)
        case .about: AboutSettingsPage(workspaces: workspaces)
        case .privacy: PrivacySettingsPage()
        case .developer: DeveloperSettingsPage(library: library, toolbox: toolbox, workspaces: workspaces, calendar: calendar,
                                               onSelectArea: onSelectArea)
        }
    }
}

/// Dims the settings sidebar while WebUntis connects (its selection is
/// guarded as well). Only this modifier observes the calendar, not the settings.
private struct DisabledWhileConnecting: ViewModifier {
    @ObservedObject var calendar: CalendarModel
    func body(content: Content) -> some View { content.disabled(calendar.connectionBusy) }
}

/// App icon, name, version and – in the test apps – which app this is.
struct SettingsHeaderCard: View {
    private static func info(_ key: String) -> String { Bundle.main.object(forInfoDictionaryKey: key) as? String ?? "–" }
    static let icon: UIImage? = {
        let info = Bundle.main.infoDictionary
        let icons = (info?["CFBundleIcons~ipad"] ?? info?["CFBundleIcons"]) as? [String: Any]
        let files = (icons?["CFBundlePrimaryIcon"] as? [String: Any])?["CFBundleIconFiles"] as? [String]
        return files?.reversed().lazy.compactMap { UIImage(named: $0) }.first
    }()
    var body: some View {
        HStack(spacing: 14) {
            if let icon = Self.icon {
                Image(uiImage: icon).resizable().frame(width: 52, height: 52)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .accessibilityHidden(true)
            } else {
                SettingsTile(symbol: "pencil.and.scribble", color: AccentChoice.current.color, size: 52)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(AppSyncModel.shared.channel?.appName ?? "noty").font(.title3.weight(.semibold))
                }
                Text("Version \(Self.info("CFBundleShortVersionString")) · Build \(Self.info("CFBundleVersion"))")
                    .font(.footnote).foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}
