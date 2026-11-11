import SwiftUI
import UIKit
import OSLog
import GameController
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

/// The input line of `/`, `?`, `s` and `S`. Display only: its keys keep coming
/// through the router, because the text view has to stay first responder.
/// Selection, caret reveal and format bar then work as during every other
/// command; focus moving to a field would end the text for all of them.
struct TextPrompt: Equatable {
    enum Kind: Equatable { case search(backward: Bool), select, split }
    let kind: Kind
    var query = ""
    var noMatch = false
    var symbol: String {
        switch kind {
        case .search(let backward): backward ? "?" : "/"
        case .select: "s"
        case .split: "S"
        }
    }
    /// The same as a key of a macro.
    var action: HelixAction {
        switch kind {
        case .search(let backward): .searchPrompt(backward: backward)
        case .select: .selectPrompt
        case .split: .splitPrompt
        }
    }
}

/// The text the keyboard mode works on: a page's text view or the surface of
/// text editor 2 (docs/TEXT-EDITOR-2.md).
@MainActor
protocol KeyboardTextTarget: UIResponder {
    var normalCaret: Bool { get set }
    /// Can take the focus back after the palette (an empty field may be gone).
    var keepsTextFocus: Bool { get }
    /// Text and marker colours of the colour panel; empty where it has none.
    func keyboardColorRows() -> [KeyChoiceRow]
    func beginEditingOnPurpose()
    func finishByEscape()
    @discardableResult func keyboardSync() -> Bool
    func keyboardRun(_ command: TextEngine.Command, count: Int?)
    func keyboardEscape() -> Bool
    func keyboardShowSelection()
    func keyboardUndo(redo: Bool)
    func insertPageBreak()
    /// Ends a composition: its text stays (Esc).
    func unmarkText()
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
    /// `Q`: the register a macro is being recorded into.
    @Published private(set) var recordingRegister: String?
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
    /// Open parts with keys of their own, see `KeyPanel`.
    var panels = KeyPanelStack<KeyPanel>()
    /// Counts changes of `panels`: they are no published value themselves.
    @Published var panelRevision = 0
    @Published var question: KeyQuestion?
    @Published var choices: KeyChoices?
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
    private weak var heldEditor: (any KeyboardTextTarget)?
    private var heldTries = 0
    private var noticeTask: Task<Void, Never>?
    /// `Space f` in the editor: the search over all notebooks lives in the
    /// library, it opens as soon as the editor cover is gone.
    var searchAllAfterClosing = false

    private var gate = KeyPressGate()
    private var latch = KeyDeliveryLatch()
    private var repeatKey: Int?
    private var repeatTask: Task<Void, Never>?
    private var reclaimTask: Task<Void, Never>?
    /// Settings › Diagnose only (`idevicesyslog | grep noty.keys`); `notice`, as the syslog relay drops `info`.
    private static let log = Logger(subsystem: "de.la.noty", category: "keyboard")
    private var outcome = ""
    private var loggedResponder = ""

    /// The active pane shows a text document: the only place the keys work.
    @Published private(set) var inTextDocument = false
    var isEnabled: Bool { inTextDocument && UserDefaults.standard.bool(forKey: AppSettingsKey.helixTextDocuments) }
    var allowsTyping: Bool { !isEnabled || mode == .insert }
    /// INS closes pairs by itself (Settings › Editor).
    var pairsTyping: Bool { isEnabled && UserDefaults.standard.bool(forKey: AppSettingsKey.autoPairs) }
    /// Enter keeps the indent of the line; lists go first (`TextListEditing`).
    func indentedNewline(in text: String, range: NSRange) -> TextListEditing.Edit? {
        isEnabled ? TextTyping.newline(in: text, range: range) : nil
    }

    // MARK: State from the views

    func setEditor(_ commands: EditorCommandActions?) {
        let before = (scope, editorActions != nil)
        scope = commands == nil ? .library : .editor
        let document = commands?.isTextDocument == true
        if document != inTextDocument {
            // The other pane or the library knows no NOR: its text just takes typing.
            if inTextDocument { cancelPrompt(); setMode(.insert) }
            inTextDocument = document
        }
        // A sheet closed: the keys need a responder in the editor again.
        if editorActions == nil, commands?.canEdit == true { reclaim() }
        editorActions = commands?.canEdit == true ? commands?.keys : nil
        if commands == nil {
            editing = false; heldEditor = nil
            endTextState()
            dropQuestions()
            reclaim()
        } else if editorActions == nil { cancelPrompt() }
        // The keys of a started sequence lead nowhere there.
        if before != (scope, editorActions != nil) { dropSequence() }
        refreshLabel()
    }
    func setLibrary(_ actions: LibraryKeyActions?) {
        libraryActions = actions
        dropSequence()
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
        let sheet = sheetPanel
        // The law window has the keys (`LawKeyboard`): its responder, not the page.
        if sheet == nil, scope == .editor, heldEditor == nil, LawKeyboard.shared.claimKeys() { return }
        switch KeyFocusTarget.resolve(hasPanelHost: sheet != nil, inEditor: scope == .editor, heldText: heldEditor != nil,
                                      editorActive: editorActions != nil, libraryActive: libraryActions != nil) {
        case .panelHost: sheet?.host?.claim()
        case .heldText: returnToHeldText()
        case .page: viewport?.activeSheet?.claimUndoResponder()
        case .library: host?.claim()
        case .none: break
        }
        guard HangProbe.isInstalled, Self.responderName != loggedResponder else { return }
        loggedResponder = Self.responderName
        Self.log.notice("[noty.keys] claim scope=\(self.scope == .library ? "library" : "editor", privacy: .public) responder=\(Self.responderName, privacy: .public)")
    }
    func textBegan() {
        trace("textBegan")
        let entering = !editing
        editing = true
        // `applyTextFocus` ends a hand-off, once the selection is in place.
        if !handoff {
            dropPrompt()
            pageTouched()
            LawKeyboard.shared.pageTouched()
            setMode(.insert); insertRun = nil; typedSinceInsert = false
        } else if entering { insertRun = nil; typedSinceInsert = false }
        refreshLabel()
    }
    func textEnded() {
        DispatchQueue.main.async { [self] in
            guard !(UIResponder.currentFirstResponder is any KeyboardTextTarget), heldEditor == nil else {
                trace("textEnded kept")
                return
            }
            // A focus request is on its way to another page: it decides, or runs out.
            if handoff {
                trace("textEnded waits")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [self] in textEnded() }
                return
            }
            editing = false; TextFlowSelection.shared.set(nil)
            endTextState()
            refreshLabel()
            trace("textEnded")
            // Nothing else takes the keys when no text view let go of them.
            reclaim()
        }
    }
    /// Touch alone again: sheets and the search field behave as without a keyboard.
    /// NOR and SEL need a key to get out of, and the indicator is gone with the
    /// keyboard: the on-screen keyboard writes, as after a tap in the text.
    func keyboardDisconnected() {
        guard GCKeyboard.coalesced == nil else { return }
        keyboardSeen = false
        if isEnabled, mode != .insert { writingRequested() }
    }
    /// Diagnose: the states between two keys (`idevicesyslog | grep noty.keys`).
    func trace(_ event: String) {
        guard HangProbe.isInstalled else { return }
        Self.log.notice("[noty.keys] \(event, privacy: .public) mode=\(self.label, privacy: .public) editing=\(self.editing, privacy: .public) handoff=\(self.handoff, privacy: .public) responder=\(Self.responderName, privacy: .public)")
    }
    /// No text any more: the registers stay, everything else goes.
    private func endTextState() {
        dropSequence()
        dropPrompt()
        engine.textEnded()
        engine.sync(text: "", selection: NSRange(location: 0, length: 0), mode: .insert)
    }
    func setMode(_ mode: TextEngine.Mode, editor: (any KeyboardTextTarget)? = nil) {
        engine.sync(text: engine.string, selection: engine.selectedRange, mode: mode)
        if mode == .insert { dropSequence() }
        modeChanged(editor: editor)
    }
    func dropSequence() { parser.reset(); pending = ""; menu = nil }
    /// The input line goes, the selection stays what the user made of it.
    private func dropPrompt() { textPrompt = nil; promptStart = nil }
    /// After a command: the wide caret, the indicator and the start of an INS run.
    func modeChanged(editor: (any KeyboardTextTarget)? = nil) {
        (editor ?? (UIResponder.currentFirstResponder as? any KeyboardTextTarget))?.normalCaret = isEnabled && mode != .insert
        refreshLabel()
    }
    /// A tap in the text writes, also out of NOR and SEL.
    func tappedText(_ editor: any KeyboardTextTarget) {
        pageTouched()
        LawKeyboard.shared.pageTouched()
        dropPrompt()
        setMode(.insert, editor: editor)
        insertRun = nil; typedSinceInsert = false
    }
    /// A focus to write at (a tap below the text, `i` on the page): writes,
    /// also out of NOR. Every other focus keeps the mode (`applyTextFocus`).
    func writingRequested() {
        dropPrompt()
        setMode(.insert); insertRun = nil; typedSinceInsert = false
    }
    /// Undo asks for a focus: the mode stays, and from the page the text
    /// opens in NOR, so that the next letter is no text.
    func undoRequestedFocus() {
        handoff = true
        if !editing, isEnabled, keyboardSeen { setMode(.normal) }
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
    func refreshLabel() {
        let name: String = switch mode {
        case .insert: "INS"; case .normal: "NOR"; case .select: "SEL"
        }
        let value = activePanel.map { $0.typing ? "INS" : "NOR" } ?? (scope == .editor && editing ? name : "NOR")
        let place = activePanel?.label ?? (scope == .library ? "BIBLIOTHEK" : editing ? "" : "SEITE")
        // In INS only text editor 2 keeps several: it types at all of them.
        let count = scope == .editor && editing ? engine.selections.count : 1
        if label != value { label = value }
        if contextLabel != place { contextLabel = place }
        if selectionCount != count { selectionCount = count }
        if recordingRegister != engine.recordingRegister { recordingRegister = engine.recordingRegister }
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
        let note = switch value {
        case .wrapped: "Suche von vorn"
        case .noMatch: "Kein Treffer"
        case .pairNotFound: "Kein Paar gefunden"
        case .primaryOnly: "Nur Hauptauswahl"
        case .registerEmpty: "Register leer"
        case .macroStopped: "Makro abgebrochen"
        case .repeatStopped: "Wiederholung abgebrochen"
        case .notInMacro: "Nicht im Makro"
        }
        show(note: note)
    }
    func show(note: String) {
        notice = note
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
        guard editing, let editor = UIResponder.currentFirstResponder as? any KeyboardTextTarget else { return }
        if mode != .insert { editor.keyboardSync() }
        heldEditor = editor; heldTries = 0
    }
    private func returnToHeldText() {
        guard !paletteVisible, let editor = heldEditor else { return }
        guard editor.keepsTextFocus else {
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
        if mode != .insert { editor.keyboardShowSelection() }
        modeChanged(editor: editor)
    }

    // MARK: Input line

    private func openPrompt(_ kind: TextPrompt.Kind, editor: (any KeyboardTextTarget)?) {
        guard let editor, editor.keyboardSync() else { return }
        promptStart = engine
        textPrompt = TextPrompt(kind: kind)
    }
    /// Live: every change searches from the state before the prompt opened.
    private func promptChanged(_ query: String, editor: (any KeyboardTextTarget)?) {
        guard var prompt = textPrompt, let start = promptStart else { return }
        prompt.query = query
        engine = start
        if !query.isEmpty {
            let outcome: TextEngine.Outcome
            switch prompt.kind {
            case .search(let backward): outcome = engine.search(query, backward: backward)
            case .select: outcome = engine.selectMatches(query)
            case .split: outcome = engine.splitMatches(query)
            }
            prompt.noMatch = outcome.notice == .noMatch
        } else { prompt.noMatch = false }
        textPrompt = prompt
        showSelection(in: editor)
    }
    private func closePrompt(restoring: Bool, editor: (any KeyboardTextTarget)?) {
        guard let prompt = textPrompt else { return }
        if restoring, let promptStart { engine = promptStart }
        else if !prompt.query.isEmpty, let promptStart {
            engine.rememberJump(from: promptStart)
            engine.recordPrompt(prompt.action, query: prompt.query)
        }
        textPrompt = nil; promptStart = nil
        if restoring { showSelection(in: editor) }
        else if prompt.noMatch { show(.noMatch) }
    }
    func cancelPrompt() { closePrompt(restoring: true, editor: nil) }
    private func showSelection(in editor: (any KeyboardTextTarget)?) {
        guard let editor = editor ?? UIResponder.currentFirstResponder as? any KeyboardTextTarget else { return }
        editor.keyboardShowSelection()
        modeChanged(editor: editor)
    }
    /// ⌘V while the input line is open.
    func pasteIntoPrompt(_ text: String, editor: any KeyboardTextTarget) {
        guard let prompt = textPrompt else { return }
        promptChanged(prompt.query + text.replacingOccurrences(of: "\n", with: " "), editor: editor)
    }
    private func promptKey(_ token: String, editor: (any KeyboardTextTarget)?) {
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
        if let activePanel { return activePanel.context }
        if scope == .library { return libraryActions == nil ? nil : .library }
        guard editorActions != nil else { return nil }
        guard editing else { return .page }
        return mode == .insert ? nil : .text
    }
    /// Where overview and palette start: also while typing.
    var shownContext: HelixContext { context ?? (scope == .library ? .library : editing ? .text : .page) }

    /// The token of a key press; nil for ⌘ shortcuts and keys without meaning here.
    /// `commands`: ⌥ with a letter is a command there, otherwise it types.
    private static func token(for key: UIKey, commands: Bool) -> String? {
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
        if flags.contains(.alternate), commands {
            let letter = key.charactersIgnoringModifiers.lowercased()
            if letter == "c", shift { return "<A-C>" }
            if letter == "s", !shift { return "<A-s>" }
        }
        let characters = key.characters
        return characters.count == 1 ? characters : nil
    }

    /// True when a press was used (not passed on, no text is typed). One event
    /// can carry several presses (⇧ and a letter in one report of the keyboard).
    func handle(_ presses: Set<UIPress>, text: (any KeyboardTextTarget)? = nil) -> Bool {
        // A key press is the user's input, also when the keyboard mode is off.
        UserInputClock.note()
        if appCommand(presses) { return true }
        if citationCardEscape(presses) { return true }
        guard isEnabled || helpVisible else { return false }
        var used = false
        for press in presses.sorted(by: { $0.timestamp < $1.timestamp }) {
            guard let key = press.key else { continue }
            if handle(key, time: press.timestamp, text: text) { used = true }
        }
        return used
    }
    /// A law citation card goes first with Esc (no modifiers), only while one
    /// is shown, or for the other way of the press that closed it. Through
    /// the gate: a second delivery of an unused press is no new Esc, and the
    /// key-up of a used one stays away from the system too.
    private func citationCardEscape(_ presses: Set<UIPress>) -> Bool {
        guard let press = presses.first(where: { $0.key?.keyCode == .keyboardEscape }), let key = press.key,
              key.modifierFlags.intersection([.command, .shift, .alternate, .control]).isEmpty else { return false }
        let code = key.keyCode.rawValue
        guard gate.isFresh(key: code, time: press.timestamp),
              LawCitationPreviewModel.shared.consumeEscape(by: .press) else { return false }
        _ = gate.began(key: code, time: press.timestamp)
        gate.swallow(key: code)
        return true
    }
    /// ⌘F and ⌘L that reached a responder of the app: the menu did not take
    /// them (a disabled or conflicting entry, e.g. the system's Edit › Find).
    /// Same actions and rules as the menu (`AppCommandCenter`), at most once
    /// per press; anything else, or nothing to do, passes on unchanged.
    private func appCommand(_ presses: Set<UIPress>) -> Bool {
        for press in presses {
            guard let key = press.key,
                  key.modifierFlags.intersection([.command, .shift, .alternate, .control]) == .command else { continue }
            let command: AppCommandCenter.Command
            switch key.charactersIgnoringModifiers.lowercased() {
            case "f": command = .search
            case "l": command = .lawLookup
            default: continue
            }
            let center = AppCommandCenter.shared
            guard center.isAvailable(command) else { return false }
            let code = key.keyCode.rawValue
            // The responder chain walked on with this press: it was not used before.
            guard gate.began(key: code, time: press.timestamp) else { return false }
            // Used, or the menu ran it a moment ago: the press ends here either way.
            center.perform(command, by: .press)
            gate.swallow(key: code)
            if HangProbe.isInstalled { Self.log.notice("[noty.keys] app-command=\(command.rawValue, privacy: .public) responder=\(Self.responderName, privacy: .public)") }
            return true
        }
        return false
    }
    private func handle(_ key: UIKey, time: TimeInterval, text: (any KeyboardTextTarget)?) -> Bool {
        let code = key.keyCode.rawValue, token = Self.token(for: key, commands: context == .text && textPrompt == nil), tracing = HangProbe.isInstalled
        let before = context, typing = (editing && mode == .insert) || textPrompt != nil || activePanel?.input != nil
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

    private func evaluate(_ key: UIKey, token: String?, code: Int, text: (any KeyboardTextTarget)?) -> Bool {
        guard let token else {
            // A dead key (`^` on German layouts) must not start typing in normal mode.
            let arrows: [UIKeyboardHIDUsage] = [.keyboardLeftArrow, .keyboardRightArrow, .keyboardUpArrow, .keyboardDownArrow]
            guard !key.modifierFlags.contains(.command), !arrows.contains(key.keyCode), let context, context == .text else { return false }
            gate.swallow(key: code)
            return true
        }
        if !keyboardSeen { keyboardSeen = true }
        cancelRepeat()
        guard latch.allows(token, by: .press, now: Self.now) else {
            if HangProbe.isInstalled { outcome = "second-way" }
            gate.swallow(key: code)
            return true
        }
        guard dispatch(token, key: code, text: text) else { return false }
        latch.used(token, by: .press, now: Self.now)
        gate.swallow(key: code)
        return true
    }
    private static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// The key-command way of a key, where the system would otherwise take it
    /// (Esc, Tab). UIKit may bring one press this way, through `pressesBegan`
    /// or both: `dispatch` is the same, `KeyDeliveryLatch` lets one of them
    /// work. True: used. False: the caller does what the key does without the
    /// keyboard mode (a tab, leaving the text).
    @discardableResult
    func handle(token: String, text: (any KeyboardTextTarget)? = nil) -> Bool {
        UserInputClock.note()
        // A law citation card goes first with Esc, only while one is shown.
        if token == "<Esc>", LawCitationPreviewModel.shared.consumeEscape(by: .keyCommand) { return true }
        guard isEnabled || helpVisible else { return false }
        if !keyboardSeen { keyboardSeen = true }
        cancelRepeat()
        guard latch.allows(token, by: .keyCommand, now: Self.now) else {
            trace("command token=\(token) second-way")
            return true
        }
        outcome = ""
        let used = dispatch(token, key: nil, text: text)
        if used { latch.used(token, by: .keyCommand, now: Self.now) }
        if HangProbe.isInstalled {
            Self.log.notice("[noty.keys] command token=\(token, privacy: .public) used=\(used, privacy: .public) \(self.outcome, privacy: .public) responder=\(Self.responderName, privacy: .public)")
        }
        return used
    }

    /// What a key means now, whichever way it came.
    private func dispatch(_ token: String, key: Int?, text: (any KeyboardTextTarget)?) -> Bool {
        if helpVisible { helpVisible = false; return true }
        if paletteVisible {
            guard token == "<Esc>" else { return false }
            paletteVisible = false
            return true
        }
        if let activePanel, activePanel.typing { return panelKey(token, activePanel) }
        if textPrompt != nil { promptKey(token, editor: text); return true }
        if token == "<Esc>", activePanel == nil, editing, scope == .editor {
            guard let editor = text ?? UIResponder.currentFirstResponder as? any KeyboardTextTarget else {
                // The text is gone, a focus request that never came still holds `editing`.
                outcome = "text gone"
                handoff = false; textEnded()
                return true
            }
            if escape(in: editor) { outcome = "one level" } else {
                outcome = "leaves text"
                // Nothing may hold the text open any more: leaving is the last word.
                handoff = false
                editor.finishByEscape()
            }
            return true
        }
        return feed(token, key: key, text: text)
    }

    private func feed(_ token: String, key: Int?, text: (any KeyboardTextTarget)?) -> Bool {
        guard let context else { return false }
        // In a search list a digit is text, not a count.
        if parser.isIdle, token.first?.isNumber == true, typeUnbound(token) { return true }
        let editor = editing ? (text ?? UIResponder.currentFirstResponder as? any KeyboardTextTarget) : nil
        let result = parser.feed(token, context: context)
        if HangProbe.isInstalled { outcome = "\(result)" }
        defer { if context == .text, !engine.record(token, result) { show(.notInMacro) } }
        switch result {
        case .pending(let node):
            pending = parser.display; menu = node
            return true
        case .cancelled:
            pending = ""; menu = nil
            return true
        case .unbound:
            pending = ""; menu = nil
            if typeUnbound(token) { return true }
            // In a text no stray letter may be typed; arrows with ⇧ and the like stay native.
            // A panel keeps its keys, too: the responder behind it means nothing now.
            return context == .text || activePanel != nil
        case .action(let action, let count, let repeats, let register):
            pending = ""; menu = nil
            perform(action, count: count, register: register, context: context, text: editor)
            // A page or tool change can take the responder away with its sheet.
            if context == .page { reclaim() }
            // A recording takes each key once: a held key would run ahead of it.
            if repeats, let key, engine.recordingRegister == nil {
                repeatKey = key
                repeatTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(320))
                    // A lost key-up ends by itself; every other key cancels at once.
                    for _ in 0..<160 where !Task.isCancelled {
                        guard let self, self.repeatKey == key else { return }
                        self.perform(action, count: nil, context: context, text: self.editing ? UIResponder.currentFirstResponder as? any KeyboardTextTarget : nil)
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
    func escape(in editor: any KeyboardTextTarget) -> Bool {
        // A composition ends with what it holds, before anything reads the text.
        editor.unmarkText()
        guard isEnabled, scope == .editor else { return false }
        if textPrompt != nil { closePrompt(restoring: true, editor: editor); return true }
        // First Esc only drops a started sequence (`g`, `3`).
        if !parser.isIdle {
            _ = engine.record("<Esc>", .cancelled)
            dropSequence()
            return true
        }
        return editor.keyboardEscape()
    }

    private func perform(_ action: HelixAction, count: Int?, register: String? = nil, context: HelixContext, text: (any KeyboardTextTarget)?) {
        switch action {
        case .help: helpVisible = true; return
        case .palette: paletteVisible = true; return
        case .searchPrompt(let backward): openPrompt(.search(backward: backward), editor: text); return
        case .selectPrompt: openPrompt(.select, editor: text); return
        case .splitPrompt: openPrompt(.split, editor: text); return
        case .text(let command):
            engine.selectedRegister = register
            engine.autoPairs = pairsTyping
            if let text { text.keyboardRun(command, count: count) }
            return
        case .pageBreak: text?.insertPageBreak(); return
        default: break
        }
        if let activePanel, activePanel.context == context { activePanel.run(action, count); return }
        if context == .library { libraryActions?.run(action, count); return }
        if let text, action == .undo || action == .redo {
            text.keyboardUndo(redo: action == .redo)
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

    func togglePalette() { dropSequence(); paletteVisible.toggle() }
    /// „Helix ausschalten“ in the palette: the open text takes typing at once.
    func switchOff() {
        cancelPrompt(); setMode(.insert)
        UserDefaults.standard.set(false, forKey: AppSettingsKey.helixTextDocuments)
        modeChanged(); refreshLabel()
    }
    func toggleHelp() { dropSequence(); helpVisible.toggle() }
    /// Every key binding of the current context by name, then what only the menus offer.
    func paletteCommands() -> [PaletteCommand] {
        let context = shownContext
        let keys = HelixKeymap.commands(in: context).compactMap { row in
            row.action.flatMap { reachable($0) ? $0 : nil }.map { action in
                PaletteCommand(title: row.title, keys: row.label) { [weak self] in self?.runFromPalette(action, context: context) }
            }
        }
        let extra = activePanel?.commands() ?? []
        return extra + ((scope == .library ? libraryActions?.commands() : editorActions?.commands()) ?? []) + keys
    }
    /// Without the keyboard mode no engine runs and no keys reach the input
    /// line: these would do nothing.
    private func reachable(_ action: HelixAction) -> Bool {
        switch action {
        case .text, .searchPrompt, .selectPrompt, .splitPrompt: isEnabled
        default: true
        }
    }
    private func runFromPalette(_ action: HelixAction, context: HelixContext) {
        let text = editing ? UIResponder.currentFirstResponder as? any KeyboardTextTarget : nil
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
    private var observers: [NotificationObserverToken] = []
    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else { return }
        KeyboardRouter.shared.host = self
        KeyboardRouter.shared.reclaim()
        guard observers.isEmpty else { return }
        // At launch the window is not key yet; a finished text gives the focus back.
        // Delivered on the main queue whoever posts (GameController's keyboard
        // notifications promise no thread; the handlers are main-actor code).
        let center = NotificationCenter.default
        for name in [UITextField.textDidEndEditingNotification, UITextView.textDidEndEditingNotification,
                     UIWindow.didBecomeKeyNotification, UIApplication.didBecomeActiveNotification] {
            observers.append(NotificationObserverToken(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { KeyboardRouter.shared.reclaim() }
            }))
        }
        observers.append(NotificationObserverToken(center.addObserver(forName: .GCKeyboardDidDisconnect, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { KeyboardRouter.shared.keyboardDisconnected() }
        }))
    }
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
