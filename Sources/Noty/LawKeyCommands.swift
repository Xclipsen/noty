import SwiftUI
import UIKit
import PDFKit
import Combine
import NotebookCore

// Tastenkürzel der Gesetzessammlung für eine normale Hardwaretastatur
// (docs/KEYBOARD.md, „Gesetzessammlung“; Tabelle: Core `LawShortcuts`).
//
// - Menü „Gesetze“ (`NotyCommands`): ⇧⌘L, ⌥⌘L, ⌘L und die Anordnung, im
//   geöffneten Heft, solange die Sammlung eingeschaltet ist.
// - Gesetzfokus (`LawKeyboard.focused`): ⌘L, ⇧⌘L, `Space l`, ein Tipp ins
//   Fenster oder eine Auswahl im Gesetzestext setzen ihn; Berührung der
//   Heftseite, Schließen und Parken nehmen ihn zurück. Dann gelten die
//   ⌘-Kürzel der Zeilen `route == .menu` im Menü „Gesetze“ (wirken aus jedem
//   Teil des Fensters) und die Zeilen `route == .keyCommand` als UIKeyCommand
//   mit `discoverabilityTitle` am Tastenempfänger `LawKeyHostView`, der dafür
//   First Responder wird. Mit eingeschaltetem Helix (nur Textdokumente) gehen
//   Tasten ohne ⌘ an die Helix-Tabelle `GESETZE`, ⌘-Kürzel gelten weiter.

/// What the law reader does on a shortcut; registered by `LawReaderView.startKeys()`.
@MainActor
struct LawReaderKeyActions {
    var run: (LawShortcuts.Action) -> Void
    /// Text selection or chosen mark: only then 1–5 and ⌫ are offered.
    var selectionActive: () -> Bool
    /// The reader gives its Helix keys back.
    var leave: () -> Void
}

@MainActor
final class LawKeyboard: ObservableObject {
    static let shared = LawKeyboard()
    /// „Gesetzfokus“: shortcuts act on the law window.
    @Published private(set) var focused = false
    /// The window is open and not at its edge.
    @Published private(set) var windowShown = false
    @Published private(set) var windowStashed = false
    /// An editor with the collection switched on is there (`LawKeyAnchor`).
    @Published private(set) var available = false
    /// A text field of the window is being typed into: Esc comes from `LawKeyAnchor`.
    @Published private(set) var fieldEditing = false

    /// Colour 1–5 of the reader's palette (`LawMarkColor.palette`, as in the
    /// mark bar and the edit menu). The last colour (⇧⌘H, `mm`) is the mark
    /// controller's `lastColor`.
    static func hex(_ number: Int) -> String? {
        guard LawMarkColor.palette.indices.contains(number - 1) else { return nil }
        return LawMarkColor.palette[number - 1].hex
    }

    private weak var laws: LawLibraryModel?
    private weak var panel: LawPanelModel?
    private weak var host: LawKeyHostView?
    private var reader: LawReaderKeyActions?
    /// ⌘L or ⌘F before the reader took the keys: true clears the field.
    private var pendingSearch: Bool?
    private var watchingPanel: AnyCancellable?
    private var watchingMarks: AnyCancellable?
    private var watching: [AnyCancellable] = []

    private init() {
        let center = NotificationCenter.default
        center.publisher(for: UITextField.textDidBeginEditingNotification)
            .sink { [weak self] note in self?.fieldBegan(note.object as? UITextField) }
            .store(in: &watching)
        center.publisher(for: UITextField.textDidEndEditingNotification)
            .sink { [weak self] _ in self?.fieldEnded() }
            .store(in: &watching)
    }

    // MARK: Registration

    /// The active pane's anchor: the window model and the key responder.
    func attach(laws: LawLibraryModel, panel: LawPanelModel, host: LawKeyHostView, enabled: Bool) {
        self.laws = laws
        self.host = host
        if self.panel !== panel {
            self.panel = panel
            // objectWillChange comes before the change: read afterwards.
            watchingPanel = panel.objectWillChange.receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.panelChanged() }
        }
        if available != enabled { available = enabled }
        panelChanged()
    }
    func detach(host: LawKeyHostView) {
        guard self.host === host else { return }
        blur()
        self.host = nil
        if available { available = false }
    }
    func attach(reader: LawReaderKeyActions, marks: LawMarkController) {
        self.reader = reader
        // A selection in the law text means the window is being worked on.
        watchingMarks = marks.$selectionActive.removeDuplicates()
            .sink { [weak self] active in if active { self?.markFocused() } }
    }
    func detachReader() { reader = nil; watchingMarks = nil }

    /// Live state of the window; `windowShown`/`windowStashed` follow it for the menu.
    private var isShown: Bool { panel?.isVisible ?? false }
    private var isStashed: Bool { panel?.phase == .parked }
    private func panelChanged() {
        let shown = isShown, stashed = isStashed
        if windowShown != shown { windowShown = shown }
        if windowStashed != stashed { windowStashed = stashed }
        if !shown { blur() }
    }

    // MARK: Focus

    /// Sets the focus and lets the reader take the keys (`laws.keyFocus`).
    private func focus(claiming: Bool) {
        if !focused { focused = true }
        // The reader registers itself, enters Helix and focuses a pending search.
        laws?.keyFocus += 1
        if claiming { claimSoon() }
    }
    /// `Space l` from the page: opens the window (or brings it out) with the
    /// keys. A reader that exists takes them at once (`laws.keyFocus`); one
    /// created by this opening picks the set focus up when it appears
    /// (`LawReaderView.onAppear`), however long that takes. False without
    /// an editor anchor (the caller then only opens the window).
    @discardableResult
    func openWithKeys() -> Bool {
        guard available, let panel else { return false }
        panel.open()
        focus(claiming: true)
        return true
    }
    /// From the reader (`Space l`, a selection): focus without asking it again.
    func markFocused() {
        guard isShown, available else { return }
        if !focused { focused = true }
    }
    /// A tap into the window (`LawPanelView` applies `.lawKeyFocusArea()` to all of it).
    func windowTouched() {
        guard isShown, available else { return }
        if reader == nil || !focused { focus(claiming: true) } else { claimSoon() }
    }
    /// Touch or Pencil on the page, a page text began: the keys go back.
    func pageTouched() { blur() }
    func blur() {
        guard focused else { return }
        focused = false
        pendingSearch = nil
        if fieldEditing { fieldEditing = false }
        if host?.isFirstResponder == true { host?.resignFirstResponder() }
        reader?.leave()
        KeyboardRouter.shared.reclaim()
    }
    /// What the reader should do when it takes the keys: nil, or focus its
    /// quick search (true: emptied first).
    func takePendingSearch() -> Bool? {
        defer { pendingSearch = nil }
        return pendingSearch
    }

    func claimSoon() { DispatchQueue.main.async { [weak self] in _ = self?.claimKeys() } }
    /// The key responder of the window takes the keys, unless a field of the
    /// window or the law text has them. True while the focus is set
    /// (`KeyboardRouter.claimResponder` then leaves the page alone).
    @discardableResult
    func claimKeys() -> Bool {
        // Under a sheet or without a keyboard the usual claim of the router goes on.
        guard focused, let host, host.window != nil, KeyboardRouter.shared.hasKeyboard, !covered else { return false }
        // A text open in the Helix mode keeps its responder: its keys reach
        // `GESETZE` through the router as before, the text stays in NOR.
        if KeyboardRouter.shared.isEnabled, KeyboardRouter.shared.editing { return true }
        if let current = UIResponder.currentFirstResponder, current !== host,
           current is UIKeyInput, !(current is any KeyboardTextTarget) { return true }
        if !host.isFirstResponder { host.becomeFirstResponder() }
        return true
    }
    /// A sheet, popover or alert stands over the editor: its keys are its own.
    var covered: Bool {
        guard let host, let window = host.window, var top = window.rootViewController else { return true }
        while let next = top.presentedViewController, !next.isBeingDismissed { top = next }
        var controller = host.controller
        while let current = controller {
            if current === top { return false }
            controller = current.parent
        }
        return true
    }

    private func fieldBegan(_ field: UITextField?) {
        // In the editor only the law window and the palette have text fields.
        guard let field, let host, isShown, available, field.window === host.window,
              !KeyboardRouter.shared.paletteVisible, !covered else { return }
        if !focused || reader == nil { focus(claiming: false) }
        if !fieldEditing { fieldEditing = true }
    }
    private func fieldEnded() {
        guard fieldEditing else { return }
        fieldEditing = false
        claimSoon()
    }

    // MARK: Window

    // `LawPanelModel` animates every change itself (`NotyMotion.panel`).
    /// Opens a closed window or brings a parked one out.
    func openWindow() { panel?.open() }
    /// Closes the window for real (✕, Esc, `Space l`), not to the edge.
    func closeWindow() {
        guard let panel else { return }
        blur()
        panel.close()
    }
    func parkWindow() {
        guard let panel else { return }
        blur()
        panel.park()
    }
    func unparkWindow() { panel?.unpark() }

    // MARK: Actions

    func perform(_ action: LawShortcuts.Action) {
        // Esc closes a law citation card first, only while one is shown.
        if case .escape = action, LawCitationPreviewModel.shared.consumeEscape(by: .keyCommand) { return }
        guard available, panel != nil else { return }
        Self.note(action)
        switch action {
        case .toggleWindow:
            // Visible → closed, parked or closed → visible with the keys.
            let wasShown = isShown
            if wasShown { blur() }
            panel?.toggle()
            if !wasShown { focus(claiming: true) }
        case .parkWindow:
            // Visible → parked, parked or closed → visible with the keys.
            let wasShown = isShown
            if wasShown { blur() }
            panel?.togglePark()
            if !wasShown { focus(claiming: true) }
        case .lookup:
            // Under a sheet the window would open behind it.
            guard !covered else { return }
            openWindow()
            pendingSearch = true
            focus(claiming: false)
        case .dock(let edge):
            panel?.dock(edge)
        case .float:
            panel?.float()
        case .find:
            guard focused, !covered else { return }
            if let reader { reader.run(.find) } else { pendingSearch = false; focus(claiming: false) }
        default:
            guard focused, !covered, let reader else { return }
            reader.run(action)
        }
    }

    // MARK: Key commands

    /// The UIKeyCommands of the focus for the window's responder; empty
    /// without focus or under a sheet, so the key stays with whoever else has it.
    func keyCommands() -> [UIKeyCommand] {
        guard focused, available, !covered else { return [] }
        let helix = KeyboardRouter.shared.isEnabled
        let selection = reader?.selectionActive() ?? false
        return Self.commands.filter { command in
            guard let id = command.propertyList as? String, let row = LawShortcuts.shortcut(id: id), let combo = row.combo else { return false }
            // With Helix the keys without ⌘ belong to the table `GESETZE`.
            if helix, !combo.usesCommand { return false }
            return !row.requiresSelection || selection
        }
    }
    /// The same commands serve the law text and PDF while they are first
    /// responder (a touch selection): `LawKeyTextView`, `LawKeyPDFView`.
    private static let commands: [UIKeyCommand] = LawShortcuts.all.compactMap { row in
        guard row.route == .keyCommand, let combo = row.combo else { return nil }
        let command = UIKeyCommand(title: row.title, action: #selector(UIResponder.noty_lawKey(_:)), input: combo.keyInput,
                                   modifierFlags: combo.keyFlags, propertyList: row.id)
        command.discoverabilityTitle = row.title
        // Arrows, space and ⌫ would otherwise scroll or edit whatever holds them.
        command.wantsPriorityOverSystemBehavior = true
        if row.hidden { command.attributes = .hidden }
        return command
    }
}

extension UIResponder {
    /// Every responder takes it: the command only exists where the law window
    /// offers it (`LawKeyboard.keyCommands`).
    @objc func noty_lawKey(_ command: UIKeyCommand) {
        guard let id = command.propertyList as? String, let row = LawShortcuts.shortcut(id: id) else { return }
        LawKeyboard.shared.perform(row.action)
    }
}

extension LawShortcuts.Combo {
    var keyInput: String {
        switch key {
        case .character(let value): value
        case .escape: UIKeyCommand.inputEscape
        case .enter: "\r"
        case .space: " "
        case .delete: "\u{8}"
        case .tab: "\t"
        case .up: UIKeyCommand.inputUpArrow
        case .down: UIKeyCommand.inputDownArrow
        case .left: UIKeyCommand.inputLeftArrow
        case .right: UIKeyCommand.inputRightArrow
        }
    }
    var keyFlags: UIKeyModifierFlags {
        var flags = UIKeyModifierFlags()
        if modifiers.contains(.command) { flags.insert(.command) }
        if modifiers.contains(.shift) { flags.insert(.shift) }
        if modifiers.contains(.option) { flags.insert(.alternate) }
        if modifiers.contains(.control) { flags.insert(.control) }
        return flags
    }
    /// For the app menu (`NotyCommands`).
    var shortcut: KeyboardShortcut {
        let equivalent: KeyEquivalent = switch key {
        case .character(let value): KeyEquivalent(Character(value))
        case .escape: .escape
        case .enter: .return
        case .space: .space
        case .delete: .delete
        case .tab: .tab
        case .up: .upArrow
        case .down: .downArrow
        case .left: .leftArrow
        case .right: .rightArrow
        }
        var flags = EventModifiers()
        if modifiers.contains(.command) { flags.insert(.command) }
        if modifiers.contains(.shift) { flags.insert(.shift) }
        if modifiers.contains(.option) { flags.insert(.option) }
        if modifiers.contains(.control) { flags.insert(.control) }
        return KeyboardShortcut(equivalent, modifiers: flags)
    }
}

extension LawShortcuts {
    /// The menu shortcut of a row, nil if it has none.
    static func keyboardShortcut(_ id: String) -> KeyboardShortcut? { shortcut(id: id)?.combo?.shortcut }
}

/// The responder of the law window's keys: no content, first responder while
/// the focus is set and no field of the window types. Keys of the Helix mode
/// pass on to `KeyboardRouter` like everywhere else.
final class LawKeyHostView: UIView {
    override var canBecomeFirstResponder: Bool { LawKeyboard.shared.focused }
    override var keyCommands: [UIKeyCommand]? { (super.keyCommands ?? []) + LawKeyboard.shared.keyCommands() }
    var controller: UIViewController? {
        var responder: UIResponder? = next
        while let current = responder {
            if let controller = current as? UIViewController { return controller }
            responder = current.next
        }
        return nil
    }
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if !KeyboardRouter.shared.handle(presses) { super.pressesBegan(presses, with: event) }
    }
    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if !KeyboardRouter.shared.pressEnded(presses) { super.pressesEnded(presses, with: event) }
    }
    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if !KeyboardRouter.shared.pressEnded(presses) { super.pressesCancelled(presses, with: event) }
    }
}

/// The law text view: while it is first responder (a touch selection) the
/// law window's shortcuts stay available (`LawKeyboard`), and with the Helix
/// mode its keys (`GESETZE`) reach `KeyboardRouter` like from `LawKeyHostView`.
final class LawKeyTextView: UITextView {
    override var keyCommands: [UIKeyCommand]? { (super.keyCommands ?? []) + LawKeyboard.shared.keyCommands() }
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if !KeyboardRouter.shared.handle(presses) { super.pressesBegan(presses, with: event) }
    }
    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if !KeyboardRouter.shared.pressEnded(presses) { super.pressesEnded(presses, with: event) }
    }
    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if !KeyboardRouter.shared.pressEnded(presses) { super.pressesCancelled(presses, with: event) }
    }
}

/// The law PDF: like `LawKeyTextView` while it holds a text selection.
final class LawKeyPDFView: PDFView {
    override var keyCommands: [UIKeyCommand]? { (super.keyCommands ?? []) + LawKeyboard.shared.keyCommands() }
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if !KeyboardRouter.shared.handle(presses) { super.pressesBegan(presses, with: event) }
    }
    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if !KeyboardRouter.shared.pressEnded(presses) { super.pressesEnded(presses, with: event) }
    }
    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if !KeyboardRouter.shared.pressEnded(presses) { super.pressesCancelled(presses, with: event) }
    }
}

/// In the editor (`ContentView`): connects the window model and the key
/// responder of the active pane; Esc for a field of the law window.
struct LawKeyAnchor: View {
    let active: Bool
    @EnvironmentObject private var laws: LawLibraryModel
    @EnvironmentObject private var panel: LawPanelModel
    @AppStorage(LawLibraryModel.enabledKey) private var enabled = false
    @ObservedObject private var keyboard = LawKeyboard.shared
    @State private var host: LawKeyHostView?
    var body: some View {
        ZStack {
            HostReader(host: $host)
            // A field takes Esc to nothing by itself: one level back, like everywhere in the window.
            if keyboard.focused && keyboard.fieldEditing {
                Button("") { keyboard.perform(.escape) }
                    .keyboardShortcut(.cancelAction).opacity(0).accessibilityHidden(true)
            }
        }
        .frame(width: 0, height: 0)
        .onChange(of: "\(active)|\(enabled)|\(host.map { ObjectIdentifier($0).hashValue } ?? 0)", initial: true) { _, _ in connect() }
        .onDisappear { if let host { keyboard.detach(host: host) } }
    }
    private func connect() {
        guard let host else { return }
        if active { keyboard.attach(laws: laws, panel: panel, host: host, enabled: enabled) } else { keyboard.detach(host: host) }
    }
    /// Hands out the UIKit view once it exists. Stays interactive: a view
    /// without interaction ignores keys; it has no size to be touched.
    private struct HostReader: UIViewRepresentable {
        @Binding var host: LawKeyHostView?
        func makeUIView(context: Context) -> LawKeyHostView {
            let view = LawKeyHostView()
            DispatchQueue.main.async { host = view }
            return view
        }
        func updateUIView(_ view: LawKeyHostView, context: Context) {}
    }
}

extension View {
    /// A tap anywhere in the law window gives it the keys (`LawKeyboard`);
    /// applied by `LawPanelView` to the whole window (bar and reader).
    func lawKeyFocusArea() -> some View {
        simultaneousGesture(TapGesture().onEnded { LawKeyboard.shared.windowTouched() })
    }
}

extension LawKeyboard {
    /// The law keys in the diagnosis history (docs/DIAGNOSE.md): fixed names only.
    fileprivate static func note(_ action: LawShortcuts.Action) {
        switch action {
        case .toggleWindow: Diagnostics.note("key.law.toggle")
        case .parkWindow: Diagnostics.note("key.law.park")
        case .lookup: Diagnostics.note("key.law.lookup")
        case .find: Diagnostics.note("key.law.find")
        case .escape: Diagnostics.note("key.law.escape")
        case .dock, .float: Diagnostics.note("key.law.place")
        default: Diagnostics.note("key.law.other")
        }
    }
}
