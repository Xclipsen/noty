import SwiftUI
import UIKit
import OSLog
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
    var run: (HelixAction, Int?) -> Void
    var commands: () -> [PaletteCommand]
    var direct: (KeyPalette.Direct) -> Void
}

/// What it asks of the library (`LibraryView`).
struct LibraryKeyActions {
    var run: (HelixAction, Int?) -> Void
    var commands: () -> [PaletteCommand]
}

/// The input line of `/`, `?` and `s`. Display only: its keys keep coming
/// through the router, because the text view has to stay first responder.
/// Selection, caret reveal and format bar then work as during every other
/// command; focus moving to a field would end the text for all of them.
struct TextPrompt: Equatable {
    enum Kind: Equatable { case search(backward: Bool), select }
    let kind: Kind
    var query = ""
    var noMatch = false
    var symbol: String {
        switch kind {
        case .search(let backward): backward ? "?" : "/"
        case .select: "s"
        }
    }
}

/// The keyboard mode (docs/KEYBOARD.md). Responders hand their hardware key
/// presses here (`pressesBegan`); what a key means is decided by `HelixParser`
/// in Core, text commands by `TextEngine`. ⌘ shortcuts stay with the menus and
/// key commands. Without a hardware keyboard nothing here ever runs.
@MainActor
final class KeyboardRouter: ObservableObject {
    enum Scope { case library, editor }
    static let shared = KeyboardRouter()

    @Published private(set) var scope = Scope.library
    @Published private(set) var label = "NOR"
    /// SEITE or BIBLIOTHEK; in a text the mode says enough.
    @Published private(set) var contextLabel = "BIBLIOTHEK"
    @Published private(set) var pending = ""
    /// The open menu node, for the which-key popup.
    @Published private(set) var menu: HelixMenu?
    @Published private(set) var textPrompt: TextPrompt?
    /// A short message of a command (`Kein Treffer`).
    @Published private(set) var notice: String?
    /// Selections of the engine: the app shows only the primary one, so the
    /// mode indicator has to say that `d` will take more than that.
    @Published private(set) var selectionCount = 1
    /// The mode indicator only appears once a hardware key was pressed.
    @Published private(set) var keyboardSeen = false
    @Published var helpVisible = false
    @Published var paletteVisible = false {
        didSet {
            if paletteVisible, !oldValue { holdText() }
            // The palette's text field took the focus: keys must find a responder again.
            guard oldValue, !paletteVisible else { return }
            returnToHeldText()
            reclaim()
        }
    }

    /// Text, selections, register and mode of the current text. Nothing but a
    /// text in NOR or SEL reads it; INS only remembers where typing began.
    var engine = TextEngine(mode: .insert)
    var mode: TextEngine.Mode { engine.mode }
    private(set) var editing = false
    private var parser = HelixParser()
    private var editorActions: EditorKeyActions?
    private var libraryActions: LibraryKeyActions?
    weak var viewport: NotebookViewport?
    weak var host: KeyboardHostView?
    /// The next text view to begin editing continues the current mode (a
    /// motion or edit moved the caret to another page). A focus request that
    /// never arrives must not hold the mode, so this runs out.
    var handoff: Bool {
        get { handoffTime.map { CACurrentMediaTime() - $0 < 1.5 } ?? false }
        set { handoffTime = newValue ? CACurrentMediaTime() : nil }
    }
    private var handoffTime: TimeInterval?
    /// The app sets the selection itself: nothing new to take over from the view.
    var showingSelection = false
    /// Where the caret stands while INS follows typing behind `i`, `a`, `o` …
    /// Another place at Esc means a tap or an arrow key moved it.
    var insertRun: Int?
    private(set) var typedSinceInsert = false
    /// What the register last put on the system pasteboard.
    private var pasteboardCopy: String?
    /// The state before the input line opened, for Esc.
    private var promptStart: TextEngine?
    /// The text the palette's field took the focus from.
    private weak var heldEditor: PageTextView?
    private var heldTries = 0
    private var noticeTask: Task<Void, Never>?
    /// `Space f` in the editor: the search over all notebooks lives in the
    /// library, it opens as soon as the editor cover is gone.
    var searchAllAfterClosing = false

    private var gate = KeyPressGate()
    private var repeatKey: Int?
    private var repeatTask: Task<Void, Never>?
    private var reclaimTask: Task<Void, Never>?
    /// Settings › Diagnose only (`idevicesyslog | grep noty.keys`); `notice`, as the syslog relay drops `info`.
    private static let log = Logger(subsystem: "de.la.noty", category: "keyboard")
    private var outcome = ""
    private var loggedResponder = ""

    var isEnabled: Bool { UserDefaults.standard.object(forKey: AppSettingsKey.keyboardMode) as? Bool ?? true }
    var allowsTyping: Bool { !isEnabled || mode == .insert }

    // MARK: State from the views

    func setEditor(_ commands: EditorCommandActions?) {
        scope = commands == nil ? .library : .editor
        // A sheet closed: the keys need a responder in the editor again.
        if editorActions == nil, commands?.canEdit == true { reclaim() }
        editorActions = commands?.canEdit == true ? commands?.keys : nil
        if commands == nil {
            editing = false; heldEditor = nil
            endTextState()
            reclaim()
        } else if editorActions == nil { cancelPrompt() }
        refreshLabel()
    }
    func setLibrary(_ actions: LibraryKeyActions?) {
        libraryActions = actions
        if actions != nil { reclaim() }
    }
    /// Keys only arrive at the first responder. Whatever held it (a closing
    /// sheet, the editor under its cover animation) lets go some time later and
    /// nothing reports that moment, so the claim is repeated for a while.
    func reclaim() {
        reclaimTask?.cancel()
        reclaimTask = Task { @MainActor [weak self] in
            for delay in [0, 150, 350, 500, 1000] {
                try? await Task.sleep(for: .milliseconds(delay))
                guard let self, !Task.isCancelled else { return }
                self.claimResponder()
            }
        }
    }
    private func claimResponder() {
        switch scope {
        case .library: if libraryActions != nil { host?.claim() }
        case .editor:
            if heldEditor != nil { returnToHeldText() }
            else if editorActions != nil { viewport?.activeSheet?.claimUndoResponder() }
        }
        guard HangProbe.isInstalled, Self.responderName != loggedResponder else { return }
        loggedResponder = Self.responderName
        Self.log.notice("[noty.keys] claim scope=\(self.scope == .library ? "library" : "editor", privacy: .public) responder=\(Self.responderName, privacy: .public)")
    }
    func textBegan() {
        editing = true
        // `applyTextFocus` ends a hand-off, once the selection is in place.
        if !handoff { setMode(.insert); insertRun = nil; typedSinceInsert = false }
        refreshLabel()
    }
    func textEnded() {
        DispatchQueue.main.async { [self] in
            guard !(UIResponder.currentFirstResponder is PageTextView), heldEditor == nil else { return }
            editing = false; TextFlowSelection.shared.set(nil)
            endTextState()
            refreshLabel()
        }
    }
    /// No text any more: the register stays, everything else goes.
    private func endTextState() {
        parser.reset(); pending = ""; menu = nil
        textPrompt = nil; promptStart = nil
        engine.sync(text: "", selection: NSRange(location: 0, length: 0), mode: .insert)
    }
    func setMode(_ mode: TextEngine.Mode, editor: PageTextView? = nil) {
        engine.sync(text: engine.string, selection: engine.selectedRange, mode: mode)
        if mode == .insert { parser.reset(); pending = ""; menu = nil }
        modeChanged(editor: editor)
    }
    /// After a command: the wide caret, the indicator and the start of an INS run.
    func modeChanged(editor: PageTextView? = nil) {
        (editor ?? (UIResponder.currentFirstResponder as? PageTextView))?.normalCaret = isEnabled && mode != .insert
        refreshLabel()
    }
    /// A tap in the text writes, also out of NOR and SEL.
    func tappedText(_ editor: PageTextView) {
        cancelPrompt()
        setMode(.insert, editor: editor)
        insertRun = nil; typedSinceInsert = false
    }
    /// INS was entered by a command: typing follows from here.
    func insertBegan(at caret: Int) { insertRun = caret; typedSinceInsert = false }
    func typed(caret: Int) {
        typedSinceInsert = true
        if insertRun != nil { insertRun = caret }
    }
    /// Undo or a replaced selection changed the text: selection offsets are stale.
    func textChangedElsewhere() {
        TextFlowSelection.shared.set(nil)
        if mode == .select { setMode(.normal) }
    }
    private func refreshLabel() {
        let name: String = switch mode {
        case .insert: "INS"; case .normal: "NOR"; case .select: "SEL"
        }
        let value = scope == .editor && editing ? name : "NOR"
        let place = scope == .library ? "BIBLIOTHEK" : editing ? "" : "SEITE"
        let count = scope == .editor && editing && mode != .insert ? engine.selections.count : 1
        if label != value { label = value }
        if contextLabel != place { contextLabel = place }
        if selectionCount != count { selectionCount = count }
    }

    // MARK: Register and messages

    /// `y`, `d`, `c`: the system pasteboard takes the register.
    func exportRegister() {
        guard let value = engine.register?.joined else { return }
        pasteboardCopy = value
        UIPasteboard.general.string = value
    }
    /// Before pasting: something copied elsewhere since then wins. A string
    /// ending in a line break counts as whole lines, as in the register.
    func adoptPasteboard() {
        guard let value = UIPasteboard.general.string, !value.isEmpty, value != pasteboardCopy else { return }
        engine.register = TextEngine.Register(value)
        pasteboardCopy = value
    }
    func show(_ value: TextEngine.Notice) {
        notice = switch value {
        case .wrapped: "Suche von vorn"
        case .noMatch: "Kein Treffer"
        case .pairNotFound: "Kein Paar gefunden"
        }
        noticeTask?.cancel()
        noticeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, !Task.isCancelled else { return }
            self.notice = nil
        }
    }

    // MARK: Palette over a text

    /// The palette's field ends the text's editing: its state stays here, so
    /// that a text command of the palette still finds it.
    private func holdText() {
        guard editing, let editor = UIResponder.currentFirstResponder as? PageTextView else { return }
        if mode != .insert { editor.historyOwner?.keyboardSync(editor) }
        heldEditor = editor; heldTries = 0
    }
    private func returnToHeldText() {
        guard !paletteVisible, let editor = heldEditor else { return }
        guard editor.window != nil, editor.isEditable, editor.historyOwner != nil else {
            // An empty free field disappeared with the focus.
            heldEditor = nil; textEnded(); return
        }
        handoff = true
        editor.beginEditingOnPurpose()
        handoff = false
        guard editor.isFirstResponder else {
            // `claimResponder` tries again, as often as it claims.
            heldTries += 1
            if heldTries > 5 { heldEditor = nil; textEnded() }
            return
        }
        heldEditor = nil
        if mode != .insert { editor.historyOwner?.keyboardShowSelection(editor) }
        modeChanged(editor: editor)
    }

    // MARK: Input line

    private func openPrompt(_ kind: TextPrompt.Kind, editor: PageTextView?) {
        guard let editor, editor.historyOwner?.keyboardSync(editor) == true else { return }
        promptStart = engine
        textPrompt = TextPrompt(kind: kind)
    }
    /// Live: every change searches from the state before the prompt opened.
    private func promptChanged(_ query: String, editor: PageTextView?) {
        guard var prompt = textPrompt, let start = promptStart else { return }
        prompt.query = query
        engine = start
        if !query.isEmpty {
            let outcome: TextEngine.Outcome
            switch prompt.kind {
            case .search(let backward): outcome = engine.search(query, backward: backward)
            case .select: outcome = engine.selectMatches(query)
            }
            prompt.noMatch = outcome.notice == .noMatch
        } else { prompt.noMatch = false }
        textPrompt = prompt
        showSelection(in: editor)
    }
    private func closePrompt(restoring: Bool, editor: PageTextView?) {
        guard let prompt = textPrompt else { return }
        if restoring, let promptStart { engine = promptStart }
        textPrompt = nil; promptStart = nil
        if restoring { showSelection(in: editor) }
        else if prompt.noMatch { show(.noMatch) }
    }
    func cancelPrompt() { closePrompt(restoring: true, editor: nil) }
    private func showSelection(in editor: PageTextView?) {
        guard let editor = editor ?? UIResponder.currentFirstResponder as? PageTextView else { return }
        editor.historyOwner?.keyboardShowSelection(editor)
        modeChanged(editor: editor)
    }
    /// ⌘V while the input line is open.
    func pasteIntoPrompt(_ text: String, editor: PageTextView) {
        guard let prompt = textPrompt else { return }
        promptChanged(prompt.query + text.replacingOccurrences(of: "\n", with: " "), editor: editor)
    }
    private func promptKey(_ token: String, editor: PageTextView?) {
        guard let prompt = textPrompt else { return }
        switch token {
        case "<Esc>": closePrompt(restoring: true, editor: editor)
        case "<CR>": closePrompt(restoring: false, editor: editor)
        case "<BS>": if !prompt.query.isEmpty { promptChanged(String(prompt.query.dropLast()), editor: editor) }
        case "<Space>", "<S-Space>": promptChanged(prompt.query + " ", editor: editor)
        default:
            // A control key or a named key is no text.
            guard token.count == 1 else { return }
            promptChanged(prompt.query + token, editor: editor)
        }
    }

    // MARK: Keys

    private var context: HelixContext? {
        if scope == .library { return libraryActions == nil ? nil : .library }
        guard editorActions != nil else { return nil }
        guard editing else { return .page }
        return mode == .insert ? nil : .text
    }
    /// Where overview and palette start: also while typing.
    var shownContext: HelixContext { context ?? (scope == .library ? .library : editing ? .text : .page) }

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
        // Everything else with ⌥ stays what it types: `[ ] { } | ~ @` on German layouts.
        if flags.contains(.alternate), key.charactersIgnoringModifiers == ";" || (shift && key.charactersIgnoringModifiers == ",") { return "<A-;>" }
        let characters = key.characters
        return characters.count == 1 ? characters : nil
    }

    /// True when a press was used (not passed on, no text is typed). One event
    /// can carry several presses (⇧ and a letter in one report of the keyboard).
    func handle(_ presses: Set<UIPress>, text: PageTextView? = nil) -> Bool {
        guard isEnabled else { return false }
        var used = false
        for press in presses.sorted(by: { $0.timestamp < $1.timestamp }) {
            guard let key = press.key else { continue }
            if handle(key, time: press.timestamp, text: text) { used = true }
        }
        return used
    }
    private func handle(_ key: UIKey, time: TimeInterval, text: PageTextView?) -> Bool {
        let code = key.keyCode.rawValue, token = Self.token(for: key), tracing = HangProbe.isInstalled
        let before = context, typing = (editing && mode == .insert) || textPrompt != nil
        outcome = ""
        // The responder chain walked on with an unused press: nothing new happened.
        let fresh = gate.began(key: code, time: time)
        let used = fresh && evaluate(key, token: token, code: code, text: text)
        if tracing {
            // Typing stays out of the log; named keys carry no content.
            let shown = token.map { typing && !$0.hasPrefix("<") ? "(typing)" : $0 } ?? "(none)"
            Self.log.notice("[noty.keys] token=\(shown, privacy: .public) time=\(time, privacy: .public) context=\(before?.rawValue ?? "none", privacy: .public) scope=\(self.scope == .library ? "library" : "editor", privacy: .public) editing=\(self.editing, privacy: .public) \(fresh ? "" : "second-delivery ", privacy: .public)used=\(used, privacy: .public) \(self.outcome, privacy: .public) responder=\(Self.responderName, privacy: .public)")
        }
        return used
    }
    private static var responderName: String { UIResponder.currentFirstResponder.map { String(describing: type(of: $0)) } ?? "none" }

    private func evaluate(_ key: UIKey, token: String?, code: Int, text: PageTextView?) -> Bool {
        guard let token else {
            // A dead key (`^` on German layouts) must not start typing in normal mode.
            let arrows: [UIKeyboardHIDUsage] = [.keyboardLeftArrow, .keyboardRightArrow, .keyboardUpArrow, .keyboardDownArrow]
            guard !key.modifierFlags.contains(.command), !arrows.contains(key.keyCode), let context, context == .text else { return false }
            gate.swallow(key: code)
            return true
        }
        if !keyboardSeen { keyboardSeen = true }
        cancelRepeat()
        if helpVisible { helpVisible = false; gate.swallow(key: code); return true }
        if paletteVisible { return false }
        if textPrompt != nil {
            promptKey(token, editor: text)
            gate.swallow(key: code)
            return true
        }
        if mode == .insert, editing, token == "<Esc>", let text { _ = escape(in: text); gate.swallow(key: code); return true }
        guard feed(token, key: code, text: text) else { return false }
        gate.swallow(key: code)
        return true
    }
    /// A key command that the system would otherwise take (Tab).
    func handle(token: String) { _ = feed(token, key: nil, text: nil) }

    private func feed(_ token: String, key: Int?, text: PageTextView?) -> Bool {
        guard let context else { return false }
        let editor = editing ? (text ?? UIResponder.currentFirstResponder as? PageTextView) : nil
        if token == "<Esc>", parser.isIdle, let editor {
            if !escape(in: editor) { editor.finishByEscape() }
            return true
        }
        let result = parser.feed(token, context: context)
        if HangProbe.isInstalled { outcome = "\(result)" }
        switch result {
        case .pending(let node):
            pending = parser.display; menu = node
            return true
        case .cancelled:
            pending = ""; menu = nil
            return true
        case .unbound:
            pending = ""; menu = nil
            // In a text no stray letter may be typed; arrows with ⇧ and the like stay native.
            return context == .text
        case .action(let action, let count, let repeats):
            pending = ""; menu = nil
            perform(action, count: count, context: context, text: editor)
            // A page or tool change can take the responder away with its sheet.
            if context == .page { reclaim() }
            if repeats, let key {
                repeatKey = key
                repeatTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(320))
                    // A lost key-up ends by itself; every other key cancels at once.
                    for _ in 0..<160 where !Task.isCancelled {
                        guard let self, self.repeatKey == key else { return }
                        self.perform(action, count: nil, context: context, text: self.editing ? UIResponder.currentFirstResponder as? PageTextView : nil)
                        try? await Task.sleep(for: .milliseconds(45))
                    }
                }
            }
            return true
        }
    }
    private func cancelRepeat() { repeatTask?.cancel(); repeatTask = nil; repeatKey = nil }

    /// True when the end of this press belongs to a handled one.
    func pressEnded(_ presses: Set<UIPress>) -> Bool {
        var handled = false
        for press in presses {
            guard let code = press.key?.keyCode.rawValue else { cancelRepeat(); continue }
            if code == repeatKey { cancelRepeat() }
            if gate.ended(key: code) { handled = true }
        }
        return handled
    }

    /// Esc in a text, one level at a time; false: the caller leaves the text.
    func escape(in editor: PageTextView) -> Bool {
        guard isEnabled, scope == .editor else { return false }
        if textPrompt != nil { closePrompt(restoring: true, editor: editor); return true }
        // First Esc only drops a started sequence (`g`, `3`).
        if !parser.isIdle { parser.reset(); pending = ""; menu = nil; return true }
        return editor.historyOwner?.keyboardEscape(editor) ?? false
    }

    private func perform(_ action: HelixAction, count: Int?, context: HelixContext, text: PageTextView?) {
        switch action {
        case .help: helpVisible = true; return
        case .palette: paletteVisible = true; return
        case .searchPrompt(let backward): openPrompt(.search(backward: backward), editor: text); return
        case .selectPrompt: openPrompt(.select, editor: text); return
        case .text(let command):
            if let text { text.historyOwner?.keyboardRun(command, count: count, editor: text) }
            return
        default: break
        }
        if context == .library { libraryActions?.run(action, count); return }
        if let text, action == .undo || action == .redo {
            text.historyOwner?.keyboardUndo(redo: action == .redo, editor: text)
            return
        }
        let times = count ?? 1
        let sheet = viewport?.activeSheet
        switch action {
        case .scroll(let x, let y):
            if sheet?.objectLayer.keyboardNudge(dx: Double(x * times), dy: Double(y * times)) != true { viewport?.keyboardScroll(x: x * times, y: y * times) }
        case .scrollScreen(let fraction): viewport?.keyboardScreen(fraction * Double(times))
        case .zoom(let steps): viewport?.keyboardZoom(steps * times)
        case .write: if sheet?.objectLayer.keyboardEditSelected() != true { sheet?.keyboardWrite() }
        case .nextObject(let step): sheet?.keyboardCycleObject(step * times)
        case .deleteObject: sheet?.objectLayer.keyboardDelete()
        case .copyObject: sheet?.objectLayer.keyboardCopy()
        case .duplicateObject: sheet?.objectLayer.keyboardDuplicate()
        case .pasteObject: sheet?.pasteFromClipboard()
        case .selectAll: sheet?.keyboardSelectAll()
        case .escape: sheet?.objectLayer.keyboardClearSelection()
        default: editorActions?.run(action, count)
        }
    }

    // MARK: Palette and help

    func togglePalette() { paletteVisible.toggle() }
    /// Every key binding of the current context by name, then what only the menus offer.
    func paletteCommands() -> [PaletteCommand] {
        let context = shownContext
        let keys = HelixKeymap.commands(in: context).compactMap { row in
            row.action.map { action in
                PaletteCommand(title: row.title, keys: row.label) { [weak self] in self?.runFromPalette(action, context: context) }
            }
        }
        let extra = scope == .library ? libraryActions?.commands() : editorActions?.commands()
        return (extra ?? []) + keys
    }
    private func runFromPalette(_ action: HelixAction, context: HelixContext) {
        let text = editing ? UIResponder.currentFirstResponder as? PageTextView : nil
        // The commands of a text start in NOR, wherever ⇧⌘P came from.
        if context == .text, mode == .insert, let text { _ = escape(in: text) }
        perform(action, count: nil, context: context, text: text)
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
        KeyboardRouter.shared.reclaim()
        guard !observing else { return }
        observing = true
        // At launch the window is not key yet; a finished text gives the focus back.
        for name in [UITextField.textDidEndEditingNotification, UITextView.textDidEndEditingNotification,
                     UIWindow.didBecomeKeyNotification, UIApplication.didBecomeActiveNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(focusChanged), name: name, object: nil)
        }
    }
    @objc private func focusChanged() { KeyboardRouter.shared.reclaim() }
    /// Takes the keys unless text is being typed; the sheets and the editor
    /// cover above the library have to be gone first.
    func claim() {
        guard let window, !isFirstResponder, KeyboardRouter.shared.isEnabled, KeyboardRouter.shared.scope == .library,
              window.rootViewController?.presentedViewController == nil,
              !(UIResponder.currentFirstResponder is UIKeyInput) else { return }
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
    // Stays interactive: a view without interaction ignores keys (`UIView.h`); it has no size to be touched.
    func makeUIView(context: Context) -> KeyboardHostView { KeyboardHostView() }
    func updateUIView(_ view: KeyboardHostView, context: Context) {}
}
