import SwiftUI
import UIKit
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

    static let lastColorKey = "noty.laws.lastMarkColor"
    /// `#RRGGBB` of the last colour chosen with 1–5 (⇧⌘H, `mm`); nil: the pen's.
    var lastColor: String? { UserDefaults.standard.string(forKey: Self.lastColorKey) }
    func remember(color: String) { UserDefaults.standard.set(color, forKey: Self.lastColorKey) }
    /// Colour 1–5 of the reader's palette.
    // LAW-MERGE: LawPenMode.presets (Markieren); hier nur gelesen.
    static func hex(_ number: Int) -> String? {
        guard LawPenMode.presets.indices.contains(number - 1) else { return nil }
        return LawPenMode(kind: .marker, color: LawPenMode.presets[number - 1].color).hex
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
    private var isShown: Bool { panel.map { $0.isOpen && !$0.stashed } ?? false }
    private var isStashed: Bool { panel.map { $0.isOpen && $0.stashed } ?? false }
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
    /// From the reader (`Space l`, a selection): focus without asking it again.
    func markFocused() {
        guard isShown, available else { return }
        if !focused { focused = true }
    }
    /// A tap into the window. LAW-MERGE: LawPanelView wendet `.lawKeyFocusArea()` auf das ganze Fenster an.
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

    private func animate(_ change: () -> Void) {
        withAnimation(NotyMotion.panel(UIAccessibility.isReduceMotionEnabled)) { change() }
    }
    func openWindow() {
        guard let panel else { return }
        // LAW-MERGE: panel.open() (öffnet und holt vom Rand)
        animate { panel.isOpen = true; panel.stashed = false }
    }
    func closeWindow() {
        guard let panel else { return }
        blur()
        // LAW-MERGE: panel.close()
        animate { panel.isOpen = false }
    }
    func parkWindow() {
        guard let panel else { return }
        blur()
        // LAW-MERGE: panel.park()
        animate { panel.stashed = true }
    }
    func unparkWindow() {
        guard let panel else { return }
        // LAW-MERGE: panel.unpark()
        animate { panel.stashed = false }
    }

    // MARK: Actions

    func perform(_ action: LawShortcuts.Action) {
        guard available, panel != nil else { return }
        switch action {
        case .toggleWindow:
            // LAW-MERGE: panel.toggle() (sichtbar → schließen, sonst öffnen)
            if isShown { closeWindow() } else { openWindow(); focus(claiming: true) }
        case .parkWindow:
            if isShown { parkWindow() }
            else if isStashed { unparkWindow(); focus(claiming: true) }
            else { openWindow(); focus(claiming: true) }
        case .lookup:
            openWindow()
            pendingSearch = true
            focus(claiming: false)
        case .dock(let edge):
            guard let panel else { return }
            // LAW-MERGE: panel.dock(edge)
            animate { panel.edge = edge; panel.docked = true; panel.isOpen = true; panel.stashed = false }
        case .float:
            guard let panel else { return }
            // LAW-MERGE: panel.float()
            animate { panel.docked = false }
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
    /// The same commands for the law text and PDF while they are first
    /// responder (a touch selection). LAW-MERGE: LawTextView/LawPDFView
    /// `override var keyCommands { (super.keyCommands ?? []) + LawKeyboard.shared.keyCommands() }`.
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
    /// A tap anywhere in the law window gives it the keys (`LawKeyboard`).
    /// LAW-MERGE: LawPanelView `.lawKeyFocusArea()` am Fensterinhalt (Kopf und Leser).
    func lawKeyFocusArea() -> some View {
        simultaneousGesture(TapGesture().onEnded { LawKeyboard.shared.windowTouched() })
    }
}
