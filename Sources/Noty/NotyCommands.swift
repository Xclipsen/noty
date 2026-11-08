import SwiftUI
import NotebookCore

/// Library actions for the app menu and ⌘ shortcuts; published only while no
/// notebook is open.
struct LibraryCommandActions {
    var newNotebook: (() -> Void)?
    var search: (() -> Void)?
    var newTextDocument: (() -> Void)?
    /// Shown calendar: ⌘N creates an event instead of a notebook.
    var newEvent: (() -> Void)?
    /// ⇧⌘K: Hefte ⇄ Kalender; nil while the switch must wait (event window, form).
    var toggleCalendar: (() -> Void)?
    var showsCalendar = false
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

private struct LibraryCommandsKey: FocusedValueKey { typealias Value = LibraryCommandActions }
private struct EditorCommandsKey: FocusedValueKey { typealias Value = EditorCommandActions }

extension FocusedValues {
    var libraryCommands: LibraryCommandActions? {
        get { self[LibraryCommandsKey.self] }
        set { self[LibraryCommandsKey.self] = newValue }
    }
    var editorCommands: EditorCommandActions? {
        get { self[EditorCommandsKey.self] }
        set { self[EditorCommandsKey.self] = newValue }
    }
}

private struct EditorCommandPublisher: ViewModifier {
    @State private var actions: EditorCommandActions?
    func body(content: Content) -> some View {
        content
            .onPreferenceChange(EditorCommandsPreference.self) { actions = $0 }
            .onChange(of: actions, initial: true) { _, value in KeyboardRouter.shared.setEditor(value) }
            .onDisappear { KeyboardRouter.shared.setEditor(nil) }
            .focusedSceneValue(\.editorCommands, actions)
    }
}

extension View {
    /// Root of a presented editor workspace: one scene-wide publisher.
    func publishesEditorCommands() -> some View { modifier(EditorCommandPublisher()) }
}

/// App menu (iPadOS menu bar / ⌘ overview). Undo/redo deliberately stay with the
/// system Edit menu and the responder chain, so typing keeps UITextView's undo;
/// with the law window focused its responder takes ⌘Z for the marks (`LawKeyboard`).
struct NotyCommands: Commands {
    @FocusedValue(\.libraryCommands) private var library
    @FocusedValue(\.editorCommands) private var editor
    @ObservedObject private var laws = LawKeyboard.shared
    @ObservedObject private var reader = LawReaderMenuState.shared
    /// Settings › Gesetzessammlung: without it there is no menu „Gesetze“.
    @AppStorage(LawLibraryModel.enabledKey) private var lawCollection = false
    /// The law collection is on and a notebook is open.
    private var lawsOn: Bool { laws.available && editor != nil }
    /// The law window has the keys: some notebook shortcuts are its own then
    /// (`LawShortcuts.displaces`).
    private var lawFocus: Bool { lawsOn && laws.focused }
    /// The window is on screen: its entries work from the menu, their
    /// shortcuts only with the focus.
    private var lawVisible: Bool { lawsOn && laws.windowShown }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button(library?.newEvent == nil ? "Neues Heft …" : "Neuer Termin …") {
                if let newEvent = library?.newEvent { newEvent() } else { library?.newNotebook?() }
            }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(editor != nil || (library?.newNotebook == nil && library?.newEvent == nil))
            Button("Neues Textdokument") { library?.newTextDocument?() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(editor != nil || library?.newTextDocument == nil)
        }
        CommandGroup(before: .sidebar) {
            Button(library?.showsCalendar == true ? "Hefte zeigen" : "Kalender zeigen") { library?.toggleCalendar?() }
                // Only with the library in front: in a notebook ⇧⌘K stays free.
                .keyboardShortcut(editor == nil && library?.toggleCalendar != nil ? KeyboardShortcut("k", modifiers: [.command, .shift]) : nil)
                .disabled(editor != nil || library?.toggleCalendar == nil)
        }
        CommandMenu("Heft") {
            Button(lawFocus ? "Im Gesetz suchen" : editor == nil ? "In allen Heften suchen" : editor?.isTextDocument == true ? "Im Dokument suchen" : "Im Heft suchen") {
                if lawFocus { laws.perform(.find) } else if let editor { editor.search() } else { library?.search?() }
            }
            .keyboardShortcut("f", modifiers: .command)
            .disabled(!lawFocus && (editor.map { !$0.canEdit } ?? (library?.search == nil)))
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
        Button("Fundstelle suchen …") { laws.perform(.lookup) }
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
