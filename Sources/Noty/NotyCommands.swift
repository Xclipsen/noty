import SwiftUI

/// Library actions for the app menu and ⌘ shortcuts; published only while no
/// notebook is open.
struct LibraryCommandActions {
    var newNotebook: (() -> Void)?
    var search: (() -> Void)?
    var newTextDocument: (() -> Void)?
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
/// system Edit menu and the responder chain, so typing keeps UITextView's undo.
struct NotyCommands: Commands {
    @FocusedValue(\.libraryCommands) private var library
    @FocusedValue(\.editorCommands) private var editor

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Neues Notizbuch") { library?.newNotebook?() }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(editor != nil || library?.newNotebook == nil)
            Button("Neues Textdokument") { library?.newTextDocument?() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(editor != nil || library?.newTextDocument == nil)
        }
        CommandMenu("Heft") {
            Button(editor == nil ? "In allen Heften suchen" : "Im Heft suchen") {
                if let editor { editor.search() } else { library?.search?() }
            }
            .keyboardShortcut("f", modifiers: .command)
            .disabled(editor.map { !$0.canEdit } ?? (library?.search == nil))
            Button("Jetzt speichern") { editor?.save() }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(editor == nil)
            Divider()
            Button("Heft als PDF exportieren") { editor?.exportNotebook() }
                .keyboardShortcut("e", modifiers: .command)
                .disabled(editor.map { !$0.canEdit || $0.exporting } ?? true)
            Button("Aktuelle Seite als PDF exportieren") { editor?.exportPage() }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(editor.map { !$0.canEdit || $0.exporting || !$0.canExportPage } ?? true)
            Divider()
            Button("Vorherige Seite") { editor?.previousPage() }
                .keyboardShortcut(.upArrow, modifiers: .command)
                .disabled(!(editor.map { $0.canEdit && $0.hasPrevious } ?? false))
            Button("Nächste Seite") { editor?.nextPage() }
                .keyboardShortcut(.downArrow, modifiers: .command)
                .disabled(!(editor.map { $0.canEdit && $0.hasNext } ?? false))
            Divider()
            Button("Schließen") { editor?.close() }
                .keyboardShortcut("w", modifiers: .command)
                .disabled(editor.map { !$0.canEdit } ?? true)
            Button("Befehlspalette") { KeyboardRouter.shared.togglePalette() }
                .keyboardShortcut("p", modifiers: [.command, .shift])
            Button("Tastenübersicht") { KeyboardRouter.shared.helpVisible.toggle() }
                .keyboardShortcut("/", modifiers: .command)
        }
    }
}
