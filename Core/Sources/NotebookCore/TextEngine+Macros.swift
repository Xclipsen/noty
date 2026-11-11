import Foundation

/// The jump list, `.` and macros of `TextEngine` (docs/KEYBOARD.md). `.` and a
/// macro run commands on this value alone and hand the app one composed
/// outcome: the views may stay behind the text between the commands, and undo
/// takes it back as one step.
extension TextEngine {
    /// How many steps of macros one `q` may run, nested ones included; each
    /// round of `.` counts as one step, also outside a macro.
    static let macroLimit = 5_000
    static let macroSeconds = 2.0

    /// The outermost `.` or `q` of a key opens the budget, nested ones share it.
    private mutating func openBudget() {
        guard nested == 0 else { return }
        macroBudget = Self.macroLimit
        macroDeadline = Date(timeIntervalSinceNow: Self.macroSeconds)
    }
    /// One more step: false once the steps or the time are used up.
    private mutating func spendBudget() -> Bool {
        macroBudget -= 1
        return macroBudget >= 0 && Date() < macroDeadline
    }
    private static let jumpCapacity = 30

    struct Jump: Equatable {
        var selections: [Selection]
        var primary: Int
    }

    /// What insert mode left behind, native typing included: `deleted`
    /// graphemes before the place it began, then `text`, then the caret, then
    /// `tail` (the closing half of a pair).
    public struct TypedText: Equatable, Sendable {
        public var deleted = 0
        public var text = ""
        public var tail = ""
        public init(deleted: Int = 0, text: String = "", tail: String = "") { self.deleted = deleted; self.text = text; self.tail = tail }
    }

    struct InsertRun {
        let entry: Command
        /// The text at the start, for the difference to native typing.
        let base: NSString
        let start: Int
        var typed = TypedText()
        var native = false
    }

    public enum MacroStep: Equatable, Sendable {
        /// A token of NOR or SEL.
        case key(String)
        case typed(TypedText)
        /// `/`, `?`, `s`, `S` with what the input line held.
        case prompt(HelixAction, String)
    }

    struct MacroRecording {
        var register: String
        var steps: [MacroStep] = []
        /// The keys of a sequence that is still open.
        var sequence: [String] = []
    }

    // MARK: Jump list

    /// Helix's `JumpList`: a saved place behind the current one is dropped,
    /// going back from the end first saves where it starts.
    mutating func pushJump() { pushJump(Jump(selections: selections, primary: primaryIndex)) }
    /// How many of the oldest places a full list dropped.
    @discardableResult
    private mutating func pushJump(_ jump: Jump) -> Int {
        jumps.removeSubrange(min(jumpIndex, jumps.count)...)
        guard jumps.last != jump else { return 0 }
        let dropped = max(0, jumps.count - Self.jumpCapacity + 1)
        jumps.removeFirst(dropped)
        jumps.append(jump)
        jumpIndex = jumps.count
        return dropped
    }
    /// `/`, `?`, `s` and `S` ended: the jump goes back to where the input line opened.
    public mutating func rememberJump(from start: TextEngine) {
        pushJump(Jump(selections: start.selections, primary: start.primaryIndex))
    }
    mutating func jumpBackward(_ count: Int) {
        var target = jumpIndex - count
        guard target >= 0 else { return }
        if jumpIndex == jumps.count {
            target = max(0, target - pushJump(Jump(selections: selections, primary: primaryIndex)))
        }
        jumpIndex = target
        guard jumpIndex < jumps.count else { return }
        if jumps[jumpIndex] == Jump(selections: selections, primary: primaryIndex) {
            guard jumpIndex > 0 else { jumpIndex = 0; return }
            jumpIndex -= 1
        }
        restore(jumps[jumpIndex])
    }
    mutating func jumpForward(_ count: Int) {
        guard jumpIndex + count < jumps.count else { return }
        jumpIndex += count
        restore(jumps[jumpIndex])
    }
    private mutating func restore(_ jump: Jump) {
        selections = jump.selections
        primaryIndex = min(jump.primary, selections.count - 1)
    }
    /// Saved places move with the text; `settle` clamps what is left of a removed one.
    mutating func mapJumps(_ edits: [Edit]) {
        guard !jumps.isEmpty else { return }
        jumps = jumps.map { jump in Jump(selections: jump.selections.map { mapped($0, edits) }, primary: jump.primary) }
    }
    /// Offsets of another text mean nothing here: `owner` is the text the app shows.
    public mutating func useJumps(of owner: UUID) {
        guard jumpOwner != owner else { return }
        jumpOwner = owner; jumps = []; jumpIndex = 0
    }

    /// The one replacement that turns `old` into `new`.
    static func difference(from old: NSString, to new: NSString) -> Edit {
        let (prefix, suffix) = commonEnds(old, new, prefixLimit: min(old.length, new.length))
        return Edit(range: NSRange(location: prefix, length: old.length - prefix - suffix),
                    replacement: new.substring(with: NSRange(location: prefix, length: new.length - prefix - suffix)))
    }
    private static func commonEnds(_ old: NSString, _ new: NSString, prefixLimit: Int) -> (prefix: Int, suffix: Int) {
        var prefix = 0, suffix = 0
        while prefix < prefixLimit, old.character(at: prefix) == new.character(at: prefix) { prefix += 1 }
        let room = min(old.length, new.length) - prefix
        while suffix < room, old.character(at: old.length - 1 - suffix) == new.character(at: new.length - 1 - suffix) { suffix += 1 }
        return (prefix, suffix)
    }

    // MARK: Insert runs

    /// What the app typed natively between `start` and `caret`.
    static func typedText(from old: NSString, to new: NSString, start: Int, caret: Int) -> TypedText {
        let limit = min(start, caret, old.length, new.length)
        var prefix = 0
        while prefix < limit, old.character(at: prefix) == new.character(at: prefix) { prefix += 1 }
        prefix = new.alignedDown(prefix)
        var typed = TypedText(text: new.substring(with: NSRange(location: prefix, length: caret - prefix)))
        var place = prefix
        while place < min(start, old.length) { place = old.nextBoundary(place); typed.deleted += 1 }
        // Behind the caret only the rest of a pair counts, not a list numbered anew.
        var suffix = 0
        let room = min(old.length - start, new.length - caret)
        while suffix < room, old.character(at: old.length - 1 - suffix) == new.character(at: new.length - 1 - suffix) { suffix += 1 }
        let tail = new.substring(with: NSRange(location: caret, length: new.length - suffix - caret))
        if (tail as NSString).length <= 8, !tail.contains(where: \.isNewline) { typed.tail = tail }
        return typed
    }
    mutating func logTyping(_ typed: String, advance: Int) {
        guard var run = insertRun else { return }
        let value = typed as NSString
        if run.typed.tail.hasPrefix(typed), value.length == advance {
            // The closing half of a pair was typed over.
            run.typed.tail.removeFirst(typed.count)
            run.typed.text += typed
        } else {
            run.typed.text += value.substring(to: advance)
            run.typed.tail = value.substring(from: advance) + run.typed.tail
        }
        insertRun = run
    }
    mutating func logDeletion(pair: Bool) {
        guard var run = insertRun else { return }
        if run.typed.text.isEmpty { run.typed.deleted += 1 } else { run.typed.text.removeLast() }
        if pair { run.typed.tail = String(run.typed.tail.dropFirst()) }
        insertRun = run
    }
    /// Ends the insert run. Returns the indent of the new line it opened if
    /// nothing was written there; the range holds for the current text only.
    mutating func endInsertRun() -> NSRange? {
        guard let run = insertRun else { return nil }
        insertRun = nil
        let typed = run.native ? Self.typedText(from: run.base, to: text, start: run.start, caret: primary.head) : run.typed
        lastInsert = (run.entry, typed)
        if nested == 0 { recording?.steps.append(.typed(typed)) }
        return indentLeftOver(run, typed)
    }
    /// Helix's `try_restore_indent`: Esc takes the indent of a new line back
    /// if nothing was written on it.
    private func indentLeftOver(_ run: InsertRun, _ typed: TypedText) -> NSRange? {
        guard selections.count == 1, typed.deleted == 0, typed.tail.isEmpty else { return nil }
        let blank = { (text: Substring) in text.allSatisfy { $0 == " " || $0 == "\t" } }
        // What was typed first: `.` must not read a long line for every ordinary insert.
        switch run.entry {
        case .insert(.lineBelow), .insert(.lineAbove): guard blank(typed.text[...]) else { return nil }
        default: guard typed.text.hasPrefix("\n"), blank(typed.text.dropFirst()) else { return nil }
        }
        let caret = primary.head
        guard caret == TextLines.end(text, caret) else { return nil }
        let line = TextLines.start(text, caret)
        guard caret > line, firstNonBlank(line) == nil else { return nil }
        // On the first line the new line has no line break in front of it.
        if run.entry == .insert(.lineAbove), TextLines.start(text, run.start) == 0 { return nil }
        return NSRange(location: line, length: caret - line)
    }
    mutating func recordEscape() {
        if nested == 0 { recording?.steps.append(.key("<Esc>")) }
    }

    /// `.`: the command that opened insert mode, what was typed, Esc.
    mutating func repeatInsert(_ times: Int, into outcome: inout Outcome) {
        // Helix starts out with `normal_mode` as the last insert.
        guard let last = lastInsert else { mode = .normal; return }
        var composer = EditComposer(length: text.length)
        openBudget()
        nested += 1
        for _ in 0..<times {
            guard spendBudget() else { composer.notice = .repeatStopped; break }
            composer.add(perform(last.entry))
            composer.add(replay(last.typed))
            composer.add(perform(.escape))
        }
        nested -= 1
        lastInsert = last
        composer.finish(in: text, into: &outcome)
    }
    private mutating func replay(_ typed: TypedText) -> Outcome {
        var composer = EditComposer(length: text.length), outcome = Outcome()
        for _ in 0..<typed.deleted { composer.add(deleteBackward()) }
        composer.add(typeAgain(typed))
        insertRun?.typed = typed
        insertRun?.native = false
        composer.finish(in: text, into: &outcome)
        return outcome
    }

    // MARK: Macros

    /// The register a recording runs into, for the mode indicator.
    public var recordingRegister: String? { recording?.register }

    mutating func toggleRecording(_ name: String?) {
        if let done = recording {
            macros[done.register] = done.steps
            recording = nil
        } else {
            recording = MacroRecording(register: name ?? "@")
        }
    }
    /// The text ended: a recording keeps what it has, the jump list goes.
    public mutating func textEnded() {
        if recording != nil { toggleRecording(nil) }
        jumpOwner = nil; jumps = []; jumpIndex = 0
    }

    /// A key of NOR or SEL, after it ran: `result` is what the parser made of
    /// it. Insert mode and Esc come in by themselves. False: this command
    /// changes something else than the text and stays out of the macro.
    @discardableResult
    public mutating func record(_ token: String, _ result: HelixParseResult) -> Bool {
        guard recording != nil else { return true }
        switch result {
        case .pending: recording?.sequence.append(token)
        case .cancelled, .unbound: recording?.sequence = []
        case .action(let action, _, _, _):
            defer { recording?.sequence = [] }
            switch action {
            case .text(.toggleRecording), .searchPrompt, .selectPrompt, .splitPrompt, .escape: break
            case .text:
                let keys = (recording?.sequence ?? []) + [token]
                recording?.steps += keys.map(MacroStep.key)
            default: return false
            }
        }
        return true
    }
    /// An input line ended with Enter.
    public mutating func recordPrompt(_ action: HelixAction, query: String) {
        recording?.steps.append(.prompt(action, query))
    }

    mutating func playMacro(_ name: String?, count: Int, into outcome: inout Outcome) {
        let register = name ?? "@"
        guard !playing.contains(register) else { outcome.notice = .macroStopped; return }
        guard let steps = macros[register], !steps.isEmpty else { outcome.notice = .registerEmpty; return }
        let outermost = playing.isEmpty, outer = layout
        if outermost {
            // The views do not know the text a macro is writing: it counts logical lines.
            layout = LogicalLineLayout(visibleLines: outer.visibleLines)
        }
        var composer = EditComposer(length: text.length), stopped = false
        openBudget()
        playing.append(register); nested += 1
        for _ in 0..<count where !stopped {
            var parser = HelixParser()
            for step in steps {
                guard spendBudget() else { stopped = true; break }
                play(step, parser: &parser, into: &composer)
            }
        }
        // Stopped in the middle of a text: the rest of the macro is gone, its mode with it.
        if mode == .insert { composer.add(perform(.escape)) }
        playing.removeLast(); nested -= 1
        if outermost { layout = outer }
        // A `.` inside that ran out of steps stopped the macro, too.
        if stopped || macroBudget < 0 || composer.notice == .repeatStopped { composer.notice = .macroStopped }
        composer.finish(in: text, into: &outcome)
    }
    private mutating func play(_ step: MacroStep, parser: inout HelixParser, into composer: inout EditComposer) {
        switch step {
        case .typed(let typed): if mode == .insert { composer.add(replay(typed)) }
        case .prompt(let action, let query):
            let start = self
            switch action {
            case .searchPrompt(let backward): composer.add(search(query, backward: backward))
            case .selectPrompt: composer.add(selectMatches(query))
            case .splitPrompt: composer.add(splitMatches(query))
            default: break
            }
            if !query.isEmpty { rememberJump(from: start) }
        case .key(let token):
            if mode == .insert {
                if token == "<Esc>" { composer.add(perform(.escape)) }
                return
            }
            switch parser.feed(token, context: .text) {
            case .action(.text(let command), let count, _, let register):
                selectedRegister = register
                composer.add(perform(command, count: count))
            case .action(.escape, _, _, _): composer.add(perform(.escape))
            default: break
            }
        }
    }
}

/// Edits of several commands as one change of the text before the first: what
/// no command touched stays out of the result, so its format stays.
struct EditComposer {
    private enum Piece {
        case old(start: Int, length: Int)
        case new(NSString)
        var length: Int {
            switch self {
            case .old(_, let length): length
            case .new(let text): text.length
            }
        }
    }
    private var pieces: [Piece]
    private let length: Int
    var yanked = false
    var notice: TextEngine.Notice?
    init(length: Int) { self.length = length; pieces = length > 0 ? [.old(start: 0, length: length)] : [] }

    mutating func add(_ outcome: TextEngine.Outcome) {
        for edit in outcome.edits { apply(edit) }
        yanked = yanked || outcome.yanked
        notice = outcome.notice ?? notice
    }
    private mutating func apply(_ edit: TextEngine.Edit) {
        var result: [Piece] = [], offset = 0
        var inserted = edit.replacement.isEmpty
        let start = edit.range.location, end = NSMaxRange(edit.range)
        // New text next to new text becomes one piece: `9999.` keeps few pieces.
        func push(_ piece: Piece) {
            if case .new(let text) = piece, case .new(let before)? = result.last {
                result[result.count - 1] = .new(before.appending(text as String) as NSString)
            } else { result.append(piece) }
        }
        func insert() {
            guard !inserted else { return }
            inserted = true
            push(.new(edit.replacement as NSString))
        }
        func part(_ piece: Piece, _ from: Int, _ to: Int) {
            guard to > from else { return }
            switch piece {
            case .old(let origin, _): result.append(.old(start: origin + from, length: to - from))
            case .new(let text): push(.new(text.substring(with: NSRange(location: from, length: to - from)) as NSString))
            }
        }
        for piece in pieces {
            let next = offset + piece.length
            if next <= start { result.append(piece) }
            else if offset >= end {
                insert()
                push(piece)
            } else {
                part(piece, 0, start - offset)
                insert()
                part(piece, end - offset, piece.length)
            }
            offset = next
        }
        insert()
        pieces = result
    }
    /// Into `outcome`, `text` being the text after the last command.
    func finish(in text: NSString, into outcome: inout TextEngine.Outcome) {
        var edits: [TextEngine.Edit] = [], position = 0, added = ""
        func flush(until end: Int) {
            guard end > position || !added.isEmpty else { return }
            edits.append(.init(range: NSRange(location: position, length: end - position), replacement: added))
            added = ""
        }
        for piece in pieces {
            switch piece {
            case .new(let value): added += value as String
            case .old(let start, let count):
                flush(until: start)
                position = start + count
            }
        }
        flush(until: length)
        outcome.yanked = outcome.yanked || yanked
        outcome.notice = notice ?? outcome.notice
        guard let first = edits.first else { return }
        outcome.edits = edits.reversed()
        let start = first.range.location, end = NSMaxRange(edits[edits.count - 1].range)
        let delta = edits.reduce(0) { $0 + ($1.replacement as NSString).length - $1.range.length }
        outcome.combinedEdit = .init(range: NSRange(location: start, length: end - start),
                                     replacement: text.substring(with: NSRange(location: start, length: end - start + delta)))
        // A replacement of the same length stays in the formats of its place.
        outcome.keepsFormat = true
    }
}
