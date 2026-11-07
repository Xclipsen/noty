import SwiftUI
import NotebookCore

/// Library actions for the app menu and ⌘ shortcuts; published only while no
/// notebook is open.
struct LibraryCommandActions {
    var newNotebook: (() -> Void)?
    var search: (() -> Void)?
    var newTextDocument: (() -> Void)?
    /// What the menu shows (the closures act on the library's own state).
    var availability: [Bool] { [newNotebook != nil, search != nil, newTextDocument != nil] }
}

/// Actions of the active editor pane. Equality ignores the closures: they act on
/// the pane's persistent state and model; the flags drive the menu's state.
struct EditorCommandActions: Equatable {
    let owner: ObjectIdentifier
    /// Two panes can show one notebook (same owner, other page and closures).
    let pane: UUID
    var canEdit: Bool
    var canExportPage: Bool
    var exporting: Bool
    var hasPrevious: Bool
    var hasNext: Bool
    var isTextDocument = false
    let search: () -> Void
    let save: () -> Void
    let exportNotebook: () -> Void
    let exportPage: () -> Void
    let previousPage: () -> Void
    let nextPage: () -> Void
    let close: () -> Void
    /// Everything the keyboard mode (`KeyboardRouter`) asks of this pane.
    let keys: EditorKeyActions

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.owner == rhs.owner && lhs.pane == rhs.pane && lhs.canEdit == rhs.canEdit && lhs.canExportPage == rhs.canExportPage
            && lhs.exporting == rhs.exporting && lhs.hasPrevious == rhs.hasPrevious && lhs.hasNext == rhs.hasNext
            && lhs.isTextDocument == rhs.isTextDocument
    }
}

/// Both panes report upwards; only the active pane's value is non-nil, so the
/// scene publishes exactly one editor (never an ambiguous pair).
struct EditorCommandsPreference: PreferenceKey {
    static var defaultValue: EditorCommandActions? { nil }
    static func reduce(value: inout EditorCommandActions?, nextValue: () -> EditorCommandActions?) {
        if value == nil { value = nextValue() }
    }
}

/// The actions behind the app menu and its ⌘ shortcuts, one scene
/// (`UIApplicationSupportsMultipleScenes` is false). Not `@FocusedValue`: the
/// editor lives in a `fullScreenCover` and mostly a UIKit view (page, text,
/// law window) holds the keys, so SwiftUI's focused values reached the menu
/// unreliably and ⌘F, ⌘L (and the other editor entries) stayed disabled.
/// `KeyboardRouter` runs ⌘F and ⌘L from here too when a press reaches one of
/// the app's responders instead of the menu; `latch` keeps it to one run.
@MainActor
final class AppCommandCenter: ObservableObject {
    static let shared = AppCommandCenter()
    enum Command: String { case search, lawLookup }

    @Published private(set) var editor: EditorCommandActions?
    @Published private(set) var library: LibraryCommandActions?
    private var editorOwner: UUID?
    private var libraryOwner: UUID?
    private var latch = KeyDeliveryLatch()
    private init() {}

    func setEditor(_ actions: EditorCommandActions?, owner: UUID) {
        // A late nil of a cover that went must not clear the new one.
        if actions == nil, let editorOwner, editorOwner != owner { return }
        editorOwner = actions == nil ? nil : owner
        if editor != actions { editor = actions }
    }
    /// A cover that went: only its own value (a new one may be there already).
    func clearEditor(owner: UUID) {
        guard editorOwner == owner else { return }
        editorOwner = nil
        if editor != nil { editor = nil }
    }
    /// Like the editor: a library replaced on an area switch (`.id(root.path)`)
    /// leaves late, its `onDisappear` must not clear the new one's actions.
    func setLibrary(_ actions: LibraryCommandActions?, owner: UUID) {
        if actions == nil, let libraryOwner, libraryOwner != owner { return }
        libraryOwner = actions == nil ? nil : owner
        library = actions
    }
    func clearLibrary(owner: UUID) {
        guard libraryOwner == owner else { return }
        libraryOwner = nil
        library = nil
    }

    /// The law collection is on, a notebook is open and free: no sheet,
    /// popover or alert of the editor over it.
    var lawsOn: Bool {
        let keyboard = LawKeyboard.shared
        return keyboard.available && editor?.canEdit == true && !keyboard.covered
    }
    /// The law window has the keys (`LawShortcuts.displaces`).
    var lawFocus: Bool { lawsOn && LawKeyboard.shared.focused }
    /// The palette, an input line or a key panel (question, input, colour,
    /// dialog) has the keys: ⌘F and ⌘L would open something behind it. The
    /// Helix panels of the law window and the sidebar are no such layer.
    private var keyPanelOpen: Bool {
        let router = KeyboardRouter.shared
        if router.paletteVisible || router.textPrompt != nil { return true }
        guard let panel = router.activePanel else { return false }
        return panel.context != .law && panel.context != .sidebar
    }

    /// Same rules as the menu's enabled state.
    func isAvailable(_ command: Command) -> Bool {
        guard !keyPanelOpen else { return false }
        switch command {
        case .search: return lawFocus || (editor.map(\.canEdit) ?? (library?.search != nil))
        case .lawLookup: return lawsOn
        }
    }
    /// Runs the command once per key press, whichever way it came (menu:
    /// `.keyCommand`, `KeyboardRouter`: `.press`). False: not available, or
    /// the other way ran it a moment ago.
    @discardableResult
    func perform(_ command: Command, by route: KeyDeliveryLatch.Route) -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        guard isAvailable(command), latch.allows(command.rawValue, by: route, now: now) else { return false }
        latch.used(command.rawValue, by: route, now: now)
        switch command {
        case .search:
            if lawFocus { LawKeyboard.shared.perform(.find) } else if let editor { editor.search() } else { library?.search?() }
        case .lawLookup:
            LawKeyboard.shared.perform(.lookup)
        }
        return true
    }
}

private struct EditorCommandPublisher: ViewModifier {
    @State private var actions: EditorCommandActions?
    @State private var owner = UUID()
    func body(content: Content) -> some View {
        content
            .onPreferenceChange(EditorCommandsPreference.self) { actions = $0 }
            .onChange(of: actions, initial: true) { _, value in
                KeyboardRouter.shared.setEditor(value)
                AppCommandCenter.shared.setEditor(value, owner: owner)
            }
            .onDisappear {
                KeyboardRouter.shared.setEditor(nil)
                AppCommandCenter.shared.clearEditor(owner: owner)
            }
    }
}

private struct LibraryCommandPublisher: ViewModifier {
    let actions: LibraryCommandActions?
    @State private var owner = UUID()
    func body(content: Content) -> some View {
        content
            .onChange(of: actions?.availability, initial: true) { _, _ in AppCommandCenter.shared.setLibrary(actions, owner: owner) }
            .onDisappear { AppCommandCenter.shared.clearLibrary(owner: owner) }
    }
}

extension View {
    /// Root of a presented editor workspace: one scene-wide publisher.
    func publishesEditorCommands() -> some View { modifier(EditorCommandPublisher()) }
    /// The library's menu actions; nil while a notebook or a sheet is open.
    func publishesLibraryCommands(_ actions: LibraryCommandActions?) -> some View { modifier(LibraryCommandPublisher(actions: actions)) }
}

/// App menu (iPadOS menu bar / ⌘ overview). Undo/redo deliberately stay with the
/// system Edit menu and the responder chain, so typing keeps UITextView's undo;
/// with the law window focused its responder takes ⌘Z for the marks (`LawKeyboard`).
struct NotyCommands: Commands {
    @ObservedObject private var center = AppCommandCenter.shared
    @ObservedObject private var laws = LawKeyboard.shared
    @ObservedObject private var reader = LawReaderMenuState.shared
    /// Settings › Gesetzessammlung: without it there is no menu „Gesetze“.
    @AppStorage(LawLibraryModel.enabledKey) private var lawCollection = false
    private var library: LibraryCommandActions? { center.library }
    private var editor: EditorCommandActions? { center.editor }
    /// The law collection is on and a notebook is open.
    private var lawsOn: Bool { center.lawsOn }
    /// The law window has the keys: some notebook shortcuts are its own then
    /// (`LawShortcuts.displaces`).
    private var lawFocus: Bool { center.lawFocus }
    /// The window is on screen: its entries work from the menu, their
    /// shortcuts only with the focus.
    private var lawVisible: Bool { lawsOn && laws.windowShown }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Neues Heft …") { library?.newNotebook?() }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(editor != nil || library?.newNotebook == nil)
            Button("Neues Textdokument") { library?.newTextDocument?() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(editor != nil || library?.newTextDocument == nil)
        }
        CommandMenu("Heft") {
            Button(lawFocus ? "Im Gesetz suchen" : editor == nil ? "In allen Heften suchen" : editor?.isTextDocument == true ? "Im Dokument suchen" : "Im Heft suchen") {
                center.perform(.search, by: .keyCommand)
            }
            .keyboardShortcut("f", modifiers: .command)
            .disabled(!center.isAvailable(.search))
            Button("Jetzt speichern") { editor?.save() }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(editor == nil)
            Divider()
            Button("Als PDF exportieren …") { editor?.exportNotebook() }
                .keyboardShortcut("e", modifiers: .command)
                .disabled(editor.map { !$0.canEdit || $0.exporting } ?? true)
            Button("Diese Seite als PDF exportieren …") { editor?.exportPage() }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(editor.map { !$0.canEdit || $0.exporting || !$0.canExportPage } ?? true)
            Divider()
            Button("Vorherige Seite") { editor?.previousPage() }
                // With the law window focused: start of the section (menu „Gesetze“).
                .keyboardShortcut(lawFocus ? nil : KeyboardShortcut(.upArrow, modifiers: .command))
                .disabled(!(editor.map { $0.canEdit && $0.hasPrevious } ?? false))
            Button("Nächste Seite") { editor?.nextPage() }
                .keyboardShortcut(lawFocus ? nil : KeyboardShortcut(.downArrow, modifiers: .command))
                .disabled(!(editor.map { $0.canEdit && $0.hasNext } ?? false))
            Divider()
            Button("Schließen") { editor?.close() }
                .keyboardShortcut("w", modifiers: .command)
                .disabled(editor.map { !$0.canEdit } ?? true)
            Button("Befehlspalette") { KeyboardRouter.shared.togglePalette() }
                .keyboardShortcut("p", modifiers: [.command, .shift])
            Button("Tastenübersicht") { KeyboardRouter.shared.toggleHelp() }
                .keyboardShortcut("/", modifiers: .command)
        }
        if lawCollection {
            CommandMenu("Gesetze") { lawMenu }
        }
    }

    /// Menu „Gesetze“: the window always, the rest while the window is on
    /// screen (Core `LawShortcuts`, docs/KEYBOARD.md). Without the focus those
    /// entries carry no shortcut, so the keys stay with the notebook; choosing
    /// one in the menu gives the window the focus first.
    @ViewBuilder private var lawMenu: some View {
        Button(laws.windowShown ? "Gesetzessammlung schließen" : "Gesetzessammlung öffnen") { laws.perform(.toggleWindow) }
            .keyboardShortcut(LawShortcuts.keyboardShortcut("window.toggle"))
            .disabled(!lawsOn)
        // Closed: nothing to push to the edge (⇧⌘L opens).
        Button(laws.windowStashed ? "Vom Rand holen" : "An den Rand schieben") { laws.perform(.parkWindow) }
            .keyboardShortcut(LawShortcuts.keyboardShortcut("window.park"))
            .disabled(!lawsOn || !(laws.windowShown || laws.windowStashed))
        Button("Fundstelle suchen …") { center.perform(.lawLookup, by: .keyCommand) }
            .keyboardShortcut(LawShortcuts.keyboardShortcut("window.lookup"))
            .disabled(!lawsOn)
        Menu("Anordnen") {
            ForEach(LawShortcuts.shortcuts(in: .notebook).filter { $0.combo == nil }, id: \.id) { row in
                Button(row.title) { laws.perform(row.action) }
            }
        }.disabled(!lawsOn)
        Divider()
        // ⌘F stays in „Heft“ with the title „Im Gesetz suchen“.
        ForEach(LawShortcuts.all.filter { $0.context == .focus && $0.route == .menu && $0.id != "focus.find" }, id: \.id) { row in
            Button(menuTitle(row)) { performFocused(row.action) }
                .keyboardShortcut(lawFocus ? row.combo?.shortcut : nil)
                .disabled(!lawVisible)
        }
    }

    /// Titles that say what the entry does now.
    private func menuTitle(_ row: LawShortcuts.Shortcut) -> String {
        switch row.id {
        case "focus.bookmark": reader.bookmarked ? "Lesezeichen entfernen" : "Lesezeichen setzen"
        case "focus.view": reader.showsPDF ? "Lesetext zeigen" : "PDF zeigen"
        default: row.title
        }
    }

    /// From the menu without the focus: the window takes it (as after a tap
    /// into it), then the action runs once its reader has the keys.
    private func performFocused(_ action: LawShortcuts.Action) {
        if laws.focused { laws.perform(action); return }
        let keyboard = LawKeyboard.shared
        keyboard.windowTouched()
        DispatchQueue.main.async { keyboard.perform(action) }
    }
}
