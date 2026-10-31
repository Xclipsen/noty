import SwiftUI
import UIKit
import NotebookCore

/// One entry of the command palette.
struct PaletteCommand: Identifiable {
    let id = UUID()
    let title: String
    var keys: String? = nil
    let run: () -> Void
}

/// What the keyboard mode asks of an open editor pane (`ContentView`).
struct EditorKeyActions {
    var run: (KeyAction, Int, Bool) -> Void
    var commands: () -> [PaletteCommand]
    var direct: (KeyPalette.Direct) -> Void
}

/// What it asks of the library (`LibraryView`).
struct LibraryKeyActions {
    var run: (KeyAction, Int) -> Void
    var commands: () -> [PaletteCommand]
}

/// The keyboard mode (docs/KEYBOARD.md). Responders hand their hardware key
/// presses here (`pressesBegan`); what a key means is decided by
/// `KeySequenceParser` in Core. ⌘ shortcuts stay with the menus and key
/// commands. Without a hardware keyboard nothing here ever runs.
@MainActor
final class KeyboardRouter: ObservableObject {
    enum TextMode: Equatable { case insert, normal, visual(line: Bool) }
    enum Scope { case library, editor }
    static let shared = KeyboardRouter()

    @Published private(set) var scope = Scope.library
    @Published private(set) var label = "BIBLIOTHEK"
    @Published private(set) var pending = ""
    /// The mode indicator only appears once a hardware key was pressed.
    @Published private(set) var keyboardSeen = false
    @Published var helpVisible = false
    @Published var paletteVisible = false {
        didSet {
            // The palette's text field took the focus: keys must find a responder again.
            guard oldValue, !paletteVisible else { return }
            DispatchQueue.main.async { [weak self] in self?.viewport?.activeSheet?.claimUndoResponder(); self?.host?.claim() }
        }
    }

    private(set) var textMode = TextMode.insert
    private(set) var editing = false
    private var parser = KeySequenceParser()
    private var editorActions: EditorKeyActions?
    private var libraryActions: LibraryKeyActions?
    weak var viewport: NotebookViewport?
    weak var host: KeyboardHostView?
    /// The next text view to begin editing continues the current mode (a
    /// motion or edit moved the caret to another page).
    var handoff = false
    /// Visual mode, in offsets of the whole text.
    var visualAnchor = 0
    var visualCaret = 0
    /// `y`/`d` keep whether whole lines were taken; the text is on the system pasteboard.
    var register = ""
    var registerLinewise = false

    private weak var lastPress: UIPress?
    private weak var repeatPress: UIPress?
    private var repeatTask: Task<Void, Never>?
    private var swallowed = Set<ObjectIdentifier>()

    var isEnabled: Bool { UserDefaults.standard.object(forKey: AppSettingsKey.keyboardMode) as? Bool ?? true }
    var isVisual: Bool { if case .visual = textMode { return true }; return false }
    var isLinewiseVisual: Bool { textMode == .visual(line: true) }
    var allowsTyping: Bool { !isEnabled || textMode == .insert }

    // MARK: State from the views

    func setEditor(_ commands: EditorCommandActions?) {
        scope = commands == nil ? .library : .editor
        // A sheet closed: the keys need a responder in the editor again.
        if editorActions == nil, commands?.canEdit == true {
            DispatchQueue.main.async { [weak self] in self?.viewport?.activeSheet?.claimUndoResponder() }
        }
        editorActions = commands?.canEdit == true ? commands?.keys : nil
        if commands == nil {
            editing = false; textMode = .insert
            DispatchQueue.main.async { [weak self] in self?.host?.claim() }
        }
        refreshLabel()
    }
    func setLibrary(_ actions: LibraryKeyActions?) {
        libraryActions = actions
        if actions != nil { DispatchQueue.main.async { [weak self] in self?.host?.claim() } }
    }
    func textBegan() {
        editing = true
        if handoff { handoff = false } else { setTextMode(.insert) }
        refreshLabel()
    }
    func textEnded() {
        DispatchQueue.main.async { [self] in
            guard !(UIResponder.currentFirstResponder is PageTextView) else { return }
            editing = false; TextFlowSelection.shared.set(nil)
            parser.reset(); pending = ""; textMode = .insert
            refreshLabel()
        }
    }
    func setTextMode(_ mode: TextMode, editor: PageTextView? = nil) {
        textMode = mode
        (editor ?? (UIResponder.currentFirstResponder as? PageTextView))?.normalCaret = isEnabled && mode != .insert
        refreshLabel()
    }
    /// Undo or a replaced selection changed the text: selection offsets are stale.
    func textChangedElsewhere() {
        TextFlowSelection.shared.set(nil)
        if isVisual { setTextMode(.normal) }
    }
    private func refreshLabel() {
        let text: String = switch textMode {
        case .insert: "SCHREIBEN"; case .normal: "NORMAL"; case .visual(line: false): "MARKIEREN"; case .visual(line: true): "ZEILEN"
        }
        let value = scope == .library ? "BIBLIOTHEK" : editing ? text : "SEITE"
        if label != value { label = value }
    }

    // MARK: Keys

    private var context: KeyContext? {
        if scope == .library { return libraryActions == nil ? nil : .library }
        guard editorActions != nil else { return nil }
        guard editing else { return .page }
        switch textMode { case .insert: return nil; case .normal: return .text; case .visual: return .visual }
    }

    /// The token of a key press; nil for ⌘ shortcuts and keys without meaning here.
    private static func token(for key: UIKey) -> String? {
        let flags = key.modifierFlags
        guard !flags.contains(.command) else { return nil }
        let shift = flags.contains(.shift)
        switch key.keyCode {
        case .keyboardEscape: return "<Esc>"
        case .keyboardReturnOrEnter, .keypadEnter: return "<CR>"
        case .keyboardTab: return shift ? "<S-Tab>" : "<Tab>"
        case .keyboardSpacebar: return shift ? "<S-Space>" : "<Space>"
        case .keyboardDeleteOrBackspace: return "<BS>"
        case .keyboardLeftArrow: return shift ? nil : "<Left>"
        case .keyboardRightArrow: return shift ? nil : "<Right>"
        case .keyboardUpArrow: return shift ? nil : "<Up>"
        case .keyboardDownArrow: return shift ? nil : "<Down>"
        default: break
        }
        if flags.contains(.control) {
            let letter = key.charactersIgnoringModifiers.lowercased()
            // ⌃[ and ⌃C: Esc on keyboards without that key.
            if letter == "[" || letter == "c" { return "<Esc>" }
            return letter.count == 1 ? "^" + letter : nil
        }
        let characters = key.characters
        return characters.count == 1 ? characters : nil
    }

    /// True when the press was used (not passed on, no text is typed).
    func handle(_ presses: Set<UIPress>, text: PageTextView? = nil) -> Bool {
        guard isEnabled, presses.count == 1, let press = presses.first, press !== lastPress, let key = press.key else { return false }
        lastPress = press
        guard let token = Self.token(for: key) else {
            // A dead key (`^` on German layouts) must not start typing in normal mode.
            let arrows: [UIKeyboardHIDUsage] = [.keyboardLeftArrow, .keyboardRightArrow, .keyboardUpArrow, .keyboardDownArrow]
            guard !key.modifierFlags.contains(.command), !arrows.contains(key.keyCode), let context, context == .text || context == .visual else { return false }
            swallow(press)
            return true
        }
        if !keyboardSeen { keyboardSeen = true }
        cancelRepeat()
        if helpVisible { helpVisible = false; swallow(press); return true }
        if paletteVisible { return false }
        if textMode == .insert, editing, token == "<Esc>", let text { _ = escape(in: text); swallow(press); return true }
        guard feed(token, press: press, text: text) else { return false }
        swallow(press)
        return true
    }
    /// A key command that the system would otherwise take (Tab).
    func handle(token: String) { _ = feed(token, press: nil, text: nil) }
    private func swallow(_ press: UIPress) { swallowed.insert(ObjectIdentifier(press)) }

    private func feed(_ token: String, press: UIPress?, text: PageTextView?) -> Bool {
        guard let context else { return false }
        let editor = editing ? (text ?? UIResponder.currentFirstResponder as? PageTextView) : nil
        if token == "<Esc>", parser.isIdle, let editor {
            if !escape(in: editor) { editor.finishByEscape() }
            return true
        }
        switch parser.feed(token, context: context) {
        case .pending:
            pending = parser.display
            return true
        case .unbound:
            pending = ""
            // In a text no stray letter may be typed; arrows with ⇧ and the like stay native.
            return context == .text || context == .visual
        case .action(let action, let count, let explicit, let repeats):
            pending = ""
            perform(action, count: count, explicit: explicit, context: context, text: editor)
            if repeats, let press {
                repeatPress = press
                repeatTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(320))
                    // A lost key-up ends by itself; every other key cancels at once.
                    for _ in 0..<160 where !Task.isCancelled {
                        guard let self, self.repeatPress === press else { return }
                        self.perform(action, count: 1, explicit: false, context: context, text: self.editing ? UIResponder.currentFirstResponder as? PageTextView : nil)
                        try? await Task.sleep(for: .milliseconds(45))
                    }
                }
            }
            return true
        }
    }
    private func cancelRepeat() { repeatTask?.cancel(); repeatTask = nil; repeatPress = nil }

    /// True when the end of this press belongs to a handled one.
    func pressEnded(_ presses: Set<UIPress>) -> Bool {
        var handled = false
        for press in presses {
            if press === repeatPress { cancelRepeat() }
            if swallowed.remove(ObjectIdentifier(press)) != nil { handled = true }
        }
        return handled
    }

    /// Esc in a text: typing → normal → (false) the caller leaves the text.
    func escape(in editor: PageTextView) -> Bool {
        guard isEnabled, scope == .editor else { return false }
        // First Esc only drops a started sequence (`d`, `3`).
        if !parser.isIdle { parser.reset(); pending = ""; return true }
        switch textMode {
        case .insert:
            TextFlowSelection.shared.set(nil)
            setTextMode(.normal, editor: editor)
            editor.historyOwner?.keyboardStepBackAfterTyping(editor)
            return true
        case .visual:
            TextFlowSelection.shared.set(nil)
            editor.historyOwner?.keyboardEndVisual(editor)
            setTextMode(.normal, editor: editor)
            return true
        case .normal:
            return false
        }
    }

    private func perform(_ action: KeyAction, count: Int, explicit: Bool, context: KeyContext, text: PageTextView?) {
        switch action {
        case .help: helpVisible = true; return
        case .palette: paletteVisible = true; return
        default: break
        }
        if context == .library { libraryActions?.run(action, count); return }
        if let text, let layer = text.historyOwner, layer.keyboardPerform(action, count: count, explicit: explicit, editor: text) { return }
        let sheet = viewport?.activeSheet
        switch action {
        case .scroll(let x, let y):
            if sheet?.objectLayer.keyboardNudge(dx: Double(x * count), dy: Double(y * count)) != true { viewport?.keyboardScroll(x: x * count, y: y * count) }
        case .scrollScreen(let fraction): viewport?.keyboardScreen(fraction * Double(count))
        case .zoom(let steps): viewport?.keyboardZoom(steps * count)
        case .write(let entry): sheet?.keyboardWrite(entry)
        case .nextObject(let step): sheet?.keyboardCycleObject(step * count)
        case .editObject: sheet?.objectLayer.keyboardEditSelected()
        case .deleteObject: sheet?.objectLayer.keyboardDelete()
        case .copyObject: sheet?.objectLayer.keyboardCopy()
        case .cutObject: sheet?.objectLayer.keyboardCut()
        case .duplicateObject: sheet?.objectLayer.keyboardDuplicate()
        case .pasteObject: sheet?.pasteFromClipboard()
        case .selectAll: sheet?.keyboardSelectAll()
        case .cancel: sheet?.objectLayer.keyboardClearSelection()
        default: editorActions?.run(action, count, explicit)
        }
    }

    // MARK: Palette and help

    func togglePalette() { paletteVisible.toggle() }
    /// Every key binding of the current context by name, then what only the menus offer.
    func paletteCommands() -> [PaletteCommand] {
        let context = self.context ?? (scope == .library ? .library : .page)
        var seen = Set<String>(), result: [PaletteCommand] = []
        for row in KeyMap.bindings where row.contexts.contains(context) && row.action != .palette && row.action != .cancel {
            guard seen.insert(row.title).inserted else { continue }
            result.append(PaletteCommand(title: row.title, keys: row.keys.replacingOccurrences(of: " ", with: "")) { [weak self] in
                self?.perform(row.action, count: 1, explicit: false, context: context,
                              text: self?.editing == true ? UIResponder.currentFirstResponder as? PageTextView : nil)
            })
        }
        let extra = scope == .library ? libraryActions?.commands() : editorActions?.commands()
        return (extra ?? []) + result
    }
    func runDirect(_ command: KeyPalette.Direct) { editorActions?.direct(command) }
}

/// Key presses where no editor view holds the focus (library): a view
/// without content that stays first responder while nothing else is.
final class KeyboardHostView: UIView {
    override var canBecomeFirstResponder: Bool { true }
    private var observing = false
    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else { return }
        KeyboardRouter.shared.host = self
        claim()
        guard !observing else { return }
        observing = true
        for name in [UITextField.textDidEndEditingNotification, UITextView.textDidEndEditingNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(textEnded), name: name, object: nil)
        }
    }
    @objc private func textEnded() { DispatchQueue.main.async { [weak self] in self?.claim() } }
    func claim() {
        guard window != nil, KeyboardRouter.shared.isEnabled, KeyboardRouter.shared.scope == .library, UIResponder.currentFirstResponder == nil else { return }
        becomeFirstResponder()
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

struct KeyboardHost: UIViewRepresentable {
    func makeUIView(context: Context) -> KeyboardHostView {
        let view = KeyboardHostView(); view.isUserInteractionEnabled = false; return view
    }
    func updateUIView(_ view: KeyboardHostView, context: Context) {}
}
