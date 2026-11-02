import Foundation

/// Displayed lines for `j`/`k`. The engine knows no pages or views: the app
/// injects its layout, the default counts logical lines.
public protocol TextEngineLayout {
    /// Lines of one screen, for ⌃d ⌃u ⌃f ⌃b.
    var visibleLines: Int { get }
    /// The offset `lines` displayed lines away (negative: up). `goal` is what
    /// this call returned before (an x position, a column), nil on a new start.
    func verticalTarget(from offset: Int, lines: Int, goal: Double?, in text: NSString) -> (offset: Int, goal: Double)
}

public struct LogicalLineLayout: TextEngineLayout {
    public var visibleLines: Int
    public init(visibleLines: Int = 40) { self.visibleLines = visibleLines }

    public func verticalTarget(from offset: Int, lines: Int, goal: Double?, in text: NSString) -> (offset: Int, goal: Double) {
        var start = TextLines.start(text, offset)
        var column = 0, walked = start
        while walked < offset { walked = text.nextBoundary(walked); column += 1 }
        let wanted = goal.map { Int($0) } ?? column
        for _ in 0..<abs(lines) {
            if lines > 0 {
                let end = TextLines.end(text, start)
                guard end < text.length else { break }
                start = text.nextBoundary(end)
            } else {
                guard start > 0 else { break }
                start = TextLines.start(text, text.previousBoundary(start))
            }
        }
        let end = TextLines.end(text, start)
        var position = start, steps = 0
        while steps < wanted, position < end { position = text.nextBoundary(position); steps += 1 }
        return (position, Double(wanted))
    }
}

extension NSString {
    /// Grapheme boundaries; `\r\n` by hand, Foundation on Linux splits it.
    func nextBoundary(_ index: Int) -> Int {
        guard index < length else { return length }
        if index + 1 < length, character(at: index) == 13, character(at: index + 1) == 10 { return index + 2 }
        return NSMaxRange(rangeOfComposedCharacterSequence(at: index))
    }
    func previousBoundary(_ index: Int) -> Int {
        guard index > 0 else { return 0 }
        if index > 1, character(at: index - 1) == 10, character(at: index - 2) == 13 { return index - 2 }
        return rangeOfComposedCharacterSequence(at: index - 1).location
    }
    func alignedDown(_ index: Int) -> Int { index >= length ? length : rangeOfComposedCharacterSequence(at: max(0, index)).location }
    func alignedUp(_ index: Int) -> Int {
        guard index < length else { return length }
        let range = rangeOfComposedCharacterSequence(at: max(0, index))
        return range.location == index ? index : NSMaxRange(range)
    }
}

/// The text commands of the keyboard mode as pure state, modelled on Helix
/// (docs/KEYBOARD.md): selections first, then the action. `text` is a free
/// field or a text document's whole flow, offsets are UTF-16 units on grapheme
/// boundaries. Commands change this value and return the edits for the app.
public struct TextEngine {
    public enum Mode: String, Sendable { case normal, insert, select }

    /// `anchor` and `head` are gaps between characters; a forward selection
    /// ends behind `head`. Outside insert mode a selection covers at least one
    /// grapheme, except on the empty place behind the text's last character.
    /// In insert mode `head` is the caret.
    public struct Selection: Equatable, Sendable {
        public var anchor: Int
        public var head: Int
        /// Column or x position that `j`/`k` keep over shorter lines.
        var goal: Double?
        public init(anchor: Int, head: Int) { self.anchor = anchor; self.head = head }
        public static func point(_ offset: Int) -> Selection { Selection(anchor: offset, head: offset) }
        public var from: Int { min(anchor, head) }
        public var to: Int { max(anchor, head) }
        public var isEmpty: Bool { anchor == head }
        public var range: NSRange { NSRange(location: from, length: to - from) }
        public var isBackward: Bool { head < anchor }
        public static func == (a: Selection, b: Selection) -> Bool { a.anchor == b.anchor && a.head == b.head }
        func directed(backward: Bool) -> Selection {
            backward ? Selection(anchor: to, head: from) : Selection(anchor: from, head: to)
        }
        func overlaps(_ other: Selection) -> Bool { from == other.from || (to > other.from && other.to > from) }
        func merged(with other: Selection) -> Selection {
            if isBackward, other.isBackward { return Selection(anchor: max(anchor, other.anchor), head: min(head, other.head)) }
            return Selection(anchor: min(from, other.from), head: max(to, other.to))
        }
    }

    public struct Edit: Equatable, Sendable {
        public var range: NSRange
        public var replacement: String
        public init(range: NSRange, replacement: String) { self.range = range; self.replacement = replacement }
    }

    /// One value per selection, as Helix. A value ending in a line break makes
    /// the register linewise: `p` then works on whole lines. A system
    /// pasteboard string fits in as one value.
    public struct Register: Equatable, Sendable {
        public var values: [String]
        public init(values: [String]) { self.values = values }
        public init(_ string: String) { values = [string] }
        public var isLinewise: Bool { values.contains { TextEngine.endsWithBreak($0) } }
        /// For the system pasteboard.
        public var joined: String { values.joined(separator: "\n") }
    }

    public enum Direction: Sendable { case left, right, up, down }
    public enum WordMotion: Sendable { case nextStart, previousStart, nextEnd }
    public enum InsertEntry: Sendable { case before, after, lineStart, lineEnd, lineBelow, lineAbove }
    public enum TextObject: Equatable, Sendable {
        case word, longWord, paragraph
        /// Any bracket or quote, by one of its characters.
        case pair(String)
        /// The nearest pair around the selection.
        case closestPair
    }

    public enum Command: Equatable, Sendable {
        // Motions: a new selection, in select mode the selection grows.
        case move(Direction)
        case word(WordMotion, long: Bool)
        /// `f F t T`; `inclusive` selects the character itself.
        case find(String, forward: Bool, inclusive: Bool)
        case gotoFileStart, gotoLastLine, gotoLine, gotoLineStart, gotoLineEnd, gotoFirstNonBlank
        /// ⌃d ⌃u ⌃f ⌃b, in screens (`TextEngineLayout.visibleLines`).
        case screen(Double)
        /// `]p`, `[p`.
        case paragraph(forward: Bool)
        // Selections
        case selectAll, extendLine, extendToLineBounds, collapse, flip, keepPrimary, copyToNextLine, copyToPreviousLine
        /// ⌥s: every line of the selections becomes a selection.
        case splitOnLines
        case matchBracket
        case selectObject(TextObject, around: Bool)
        // Edits
        case delete, change, yank, replaceWithRegister
        case paste(before: Bool)
        case replace(String)
        case switchCase, lowercase, joinLines, indent, unindent
        case surroundAdd(String)
        /// nil: the nearest pair (`mdm`).
        case surroundDelete(String?)
        case surroundReplace(String?, with: String)
        // Modes
        case insert(InsertEntry), toggleSelect, escape
        // Search: the query comes from the app (`search`, `selectMatches`, `splitMatches`).
        case searchNext, searchPrevious, searchSelection
        // Jump list (⌃s ⌃o ⌃i)
        case saveSelection, jumpBackward, jumpForward
        /// `.`: the last text a command opened insert mode for.
        case repeatInsert
        /// `Q`, `q`, by `selectedRegister`.
        case toggleRecording, playMacro
    }

    public enum Notice: Sendable {
        case wrapped, noMatch, pairNotFound
        /// `performAtPrimary` gave up the other selections.
        case primaryOnly
        case registerEmpty
        /// A macro ran into `TextEngine.macroLimit` or called itself.
        case macroStopped
        /// `record`: this command changes something else than the text.
        case notInMacro
    }

    public struct Outcome: Equatable, Sendable {
        /// Back to front and in offsets of the text before the command:
        /// applying them in this order keeps the later offsets valid.
        public var edits: [Edit] = []
        /// All of `edits` as one replacement, for one undo step or one flow edit.
        public var combinedEdit: Edit?
        /// The register changed: time to fill the system pasteboard.
        public var yanked = false
        /// Esc found nothing left to undo in the text: the app leaves it.
        public var leavesText = false
        /// `~`, `` ` ``, `r`: the characters stay where they are, so does
        /// their format (`textEdits(in:)`).
        public var keepsFormat = false
        public var notice: Notice?
        public init() {}
    }

    public internal(set) var text: NSString
    public internal(set) var selections: [Selection]
    public internal(set) var primaryIndex = 0
    public internal(set) var mode: Mode
    /// The default register, the one the system pasteboard follows.
    public var register: Register?
    /// `"a`: named registers, in memory only.
    public var registers: [String: Register] = [:]
    /// `"a` of the next command, it takes the name along.
    public var selectedRegister: String?
    /// The last search (`/`, `*`), a regular expression.
    public internal(set) var searchQuery: String?
    public var layout: any TextEngineLayout = LogicalLineLayout()
    /// What `>` inserts.
    public var indentUnit = "\t"
    /// The setting for automatic pairs; `.` needs it, too.
    public var autoPairs = false
    /// `x` or `X` made the selection: on a last line without line break it
    /// still counts as a whole line (docs/KEYBOARD.md, Abweichungen).
    private var wholeLineSelection = false

    var jumps: [Jump] = []
    var jumpIndex = 0
    var jumpOwner: UUID?
    /// The insert run a command opened; `lastInsert` once it ended.
    var insertRun: InsertRun?
    var lastInsert: (entry: Command, typed: TypedText)?
    /// `endInsertRun` found the indent of an unused new line.
    var unusedIndent: NSRange?
    var macros: [String: [MacroStep]] = [:]
    var recording: MacroRecording?
    /// Registers of the macros that are playing; a macro never calls itself.
    var playing: [String] = []
    var macroBudget = 0
    var macroDeadline = Date.distantPast
    /// Commands of `.` or a macro run here: they stay out of a recording.
    var nested = 0
    /// `performAtPrimary` is running (a page's text view).
    private var typesAtPrimary = false

    public init(text: String = "", caret: Int = 0, mode: Mode = .normal) {
        self.text = text as NSString
        self.mode = mode
        selections = [.point(min(max(0, caret), self.text.length))]
        settle()
    }

    public var string: String { text as String }
    public var primary: Selection { selections[primaryIndex] }
    /// The primary selection as the app shows it.
    public var selectedRange: NSRange { primary.range }
    /// Where the block cursor of the primary selection stands; in insert mode the caret.
    public var cursor: Int { cursor(of: primary) }
    /// More than the single grapheme under a cursor is selected.
    public var hasWideSelection: Bool { selections.contains(where: isWide) }
    /// The same for the primary selection, the one the app shows.
    public var primaryIsWide: Bool { isWide(primary) }

    /// One selection as the app has to show it (text editor 2 shows all of them).
    public struct ShownSelection: Equatable, Sendable {
        public var range: NSRange
        public var cursor: Int
        public var isPrimary: Bool
        /// More than the grapheme under the cursor: marked, not only a block cursor.
        public var isWide: Bool
        public init(range: NSRange, cursor: Int, isPrimary: Bool, isWide: Bool) {
            self.range = range; self.cursor = cursor; self.isPrimary = isPrimary; self.isWide = isWide
        }
    }
    public var shownSelections: [ShownSelection] {
        selections.enumerated().map { index, selection in
            ShownSelection(range: selection.range, cursor: cursor(of: selection), isPrimary: index == primaryIndex, isWide: isWide(selection))
        }
    }

    /// The app's text and selection before a command: undo, tapping and native
    /// typing happen outside. An unchanged state keeps all selections; a caret
    /// on the primary cursor counts as unchanged, the app may show it that way.
    /// In insert mode the selection follows the typed text. `mode` is a new
    /// start (a tap opens insert mode): the given selection counts as it is.
    public mutating func sync(text newText: String, selection: NSRange, mode newMode: Mode? = nil) {
        let same = newText == string
        let unchanged = selection == selectedRange || (selection.length == 0 && selection.location == cursor)
        let wasInsert = mode == .insert
        if let newMode { mode = newMode; insertRun = nil }
        else if !same, wasInsert { insertRun?.native = true }
        guard !(same && unchanged && newMode == nil) else { settle(); return }
        let old = primary, delta = (newText as NSString).length - text.length
        if !same, !jumps.isEmpty { mapJumps([Self.difference(from: text, to: newText as NSString)]) }
        text = newText as NSString
        wholeLineSelection = false
        let start = min(max(0, selection.location), text.length), end = min(start + selection.length, text.length)
        var next = Selection(anchor: start, head: end)
        if wasInsert, newMode == nil, selection.length == 0 {
            // `i` keeps the selection ahead of the caret, `a` behind it.
            if old.isBackward, old.anchor + delta >= start { next.anchor = old.anchor + delta }
            else if !old.isBackward, old.anchor <= start { next.anchor = old.anchor }
        }
        selections = [next]; primaryIndex = 0
        settle()
    }

    /// Selections stay usable after every change: on boundaries, at least one
    /// grapheme wide outside insert mode, sorted and without overlaps.
    mutating func settle() {
        selections = selections.map { range in
            var result = aligned(range)
            if mode != .insert, result.isEmpty { result.head = text.nextBoundary(result.head) }
            return result
        }
        normalize()
    }
    private func aligned(_ range: Selection) -> Selection {
        var result = range
        let length = text.length
        result.anchor = min(max(0, result.anchor), length); result.head = min(max(0, result.head), length)
        if result.isBackward { result.anchor = text.alignedUp(result.anchor); result.head = text.alignedDown(result.head) }
        else if result.isEmpty { result.anchor = text.alignedDown(result.anchor); result.head = result.anchor }
        else { result.anchor = text.alignedDown(result.anchor); result.head = text.alignedUp(result.head) }
        return result
    }
    private mutating func normalize() {
        guard selections.count > 1 else { primaryIndex = 0; return }
        var result: [Selection] = [], primary = 0
        let order = selections.indices.sorted { (selections[$0].from, $0) < (selections[$1].from, $1) }
        for index in order {
            if let last = result.last, last.overlaps(selections[index]) {
                result[result.count - 1] = last.merged(with: selections[index])
            } else { result.append(selections[index]) }
            if index == primaryIndex { primary = result.count - 1 }
        }
        selections = result; primaryIndex = primary
    }

    mutating func setPrimary(_ range: Selection, adding: Bool) {
        if adding { selections.append(range); primaryIndex = selections.count - 1 } else { selections[primaryIndex] = range }
        settle()
    }

    func cursor(of range: Selection) -> Int {
        mode != .insert && range.head > range.anchor ? text.previousBoundary(range.head) : range.head
    }
    func isWide(_ range: Selection) -> Bool { range.to > text.nextBoundary(range.from) }
    /// Helix's `put_cursor`: the block cursor goes to `position`. Extending
    /// keeps the grapheme under the anchor selected when the direction turns.
    func put(_ range: Selection, _ position: Int, extend: Bool) -> Selection {
        guard extend else { return .point(position) }
        var anchor = range.anchor
        if range.head >= range.anchor, position < range.anchor { anchor = text.nextBoundary(range.anchor) }
        else if range.head < range.anchor, position >= range.anchor { anchor = text.previousBoundary(range.anchor) }
        return anchor <= position ? Selection(anchor: anchor, head: text.nextBoundary(position)) : Selection(anchor: anchor, head: position)
    }

    // MARK: Edits

    /// Position `position` after ascending edits. Text inserted at the edge of
    /// a selection stays outside it; a replacement of the same length keeps
    /// inner positions, as Helix's sticky mapping does.
    private func mapped(_ position: Int, before: Bool, _ edits: [Edit]) -> Int {
        var delta = 0
        for edit in edits {
            let start = edit.range.location, end = NSMaxRange(edit.range), length = (edit.replacement as NSString).length
            if position < start { break }
            if edit.range.length == 0, position == start {
                if before { break }
            } else if position < end {
                if position == start { return start + delta }
                if edit.range.length == length { return position + delta }
                return start + delta + (before ? 0 : length)
            }
            delta += length - edit.range.length
        }
        return position + delta
    }
    func mapped(_ range: Selection, _ edits: [Edit]) -> Selection {
        var result = range
        if range.isEmpty {
            result.anchor = mapped(range.anchor, before: false, edits); result.head = result.anchor
        } else if range.isBackward {
            result.head = mapped(range.head, before: false, edits); result.anchor = mapped(range.anchor, before: true, edits)
        } else {
            result.anchor = mapped(range.anchor, before: false, edits); result.head = mapped(range.head, before: true, edits)
        }
        return result
    }

    /// Applies ascending edits. `selecting`: selections in the new text,
    /// otherwise the current ones move along.
    mutating func commit(_ edits: [Edit], selecting new: [Selection]? = nil, into outcome: inout Outcome) {
        guard !edits.isEmpty else { return }
        let changed = NSMutableString(string: string)
        for edit in edits.reversed() { changed.replaceCharacters(in: edit.range, with: edit.replacement) }
        selections = new ?? selections.map { mapped($0, edits) }
        mapJumps(edits)
        let start = edits[0].range.location, end = edits.map { NSMaxRange($0.range) }.max() ?? start
        let delta = changed.length - text.length
        outcome.combinedEdit = Edit(range: NSRange(location: start, length: end - start),
                                    replacement: changed.substring(with: NSRange(location: start, length: end - start + delta)))
        outcome.edits += edits.reversed()
        text = changed
    }

    static func endsWithBreak(_ value: String) -> Bool {
        let units = value as NSString
        return units.length > 0 && TextLines.isBreak(units.character(at: units.length - 1))
    }
    private var textEndsWithBreak: Bool { text.length > 0 && TextLines.isBreak(text.character(at: text.length - 1)) }

    /// Offsets where the lines of `range` begin (first and last line).
    func lineBounds(_ range: Selection) -> (first: Int, last: Int) {
        let last = range.isEmpty ? range.to : max(text.previousBoundary(range.to), range.from)
        return (TextLines.start(text, range.from), TextLines.start(text, last))
    }
    /// Behind the line that begins at `line`: the next line, or the end of the text.
    func nextLine(_ line: Int) -> Int {
        let end = TextLines.end(text, line)
        return end < text.length ? text.nextBoundary(end) : text.length
    }
    /// Line beginnings; a line break at the end opens an empty last line, as in a rope.
    var lineStarts: [Int] {
        var result = [0], index = 0
        while index < text.length {
            if TextLines.isBreak(text.character(at: index)) { index = text.nextBoundary(index); result.append(index) } else { index += 1 }
        }
        return result
    }
    func firstNonBlank(_ line: Int) -> Int? {
        let end = TextLines.end(text, line)
        var index = line
        while index < end {
            if !category(at: index).isSpace { return index }
            index = text.nextBoundary(index)
        }
        return nil
    }

    // MARK: Commands

    /// Runs a command; `count` is what the parser collected (nil: none typed).
    /// Insert mode only takes `escape`; typing goes through `insertText`.
    @discardableResult
    public mutating func perform(_ command: Command, count: Int? = nil) -> Outcome {
        var outcome = Outcome()
        guard mode != .insert || command == .escape else { return outcome }
        let times = max(1, count ?? 1), extend = mode == .select
        let wholeLines = wholeLineSelection, named = selectedRegister
        wholeLineSelection = false
        selectedRegister = nil
        var reduced = false
        if typesAtPrimary, mode != .insert, selections.count > 1 {
            // `.` and a macro's commands come here, too: only these type.
            switch command {
            case .change, .insert, .repeatInsert: selections = [primary]; primaryIndex = 0; reduced = true
            default: break
            }
        }
        switch command {
        case .move(.up), .move(.down), .screen: break
        default: selections = selections.map { var range = $0; range.goal = nil; return range }
        }
        switch command {
        case .move(.left), .move(.right):
            let forward = command == .move(.right)
            selections = selections.map { range in
                var position = cursor(of: range)
                for _ in 0..<times { position = forward ? text.nextBoundary(position) : text.previousBoundary(position) }
                return put(range, position, extend: extend)
            }
        case .move(.up): moveVertically(-times, extend: extend)
        case .move(.down): moveVertically(times, extend: extend)
        case .screen(let screens):
            let lines = Int((Double(layout.visibleLines) * abs(screens)).rounded(.down))
            moveVertically(max(1, lines) * (screens < 0 ? -1 : 1), extend: extend)
        case .word(let motion, let long): selections = selections.map { moveWord($0, motion, long: long, count: times, extend: extend) }
        case .find(let character, let forward, let inclusive):
            selections = selections.map { find($0, character, forward: forward, inclusive: inclusive, count: times, extend: extend) }
        case .gotoFileStart:
            pushJump()
            if count != nil { gotoLine(times, extend: extend) } else { selections = selections.map { put($0, 0, extend: extend) } }
        case .gotoLastLine: pushJump(); gotoLine(Int.max, extend: extend)
        case .gotoLine:
            if count != nil { pushJump(); gotoLine(times, extend: false) } // Helix has no extending `G`
        case .gotoLineStart:
            selections = selections.map { put($0, TextLines.start(text, cursor(of: $0)), extend: extend) }
        case .gotoLineEnd:
            selections = selections.map { range in
                let line = TextLines.start(text, cursor(of: range))
                return put(range, max(line, text.previousBoundary(TextLines.end(text, line))), extend: extend)
            }
        case .gotoFirstNonBlank:
            selections = selections.map { range in
                firstNonBlank(TextLines.start(text, cursor(of: range))).map { put(range, $0, extend: extend) } ?? range
            }
        case .paragraph(let forward): selections = selections.map { moveParagraph($0, forward: forward, count: times, extend: extend) }

        case .selectAll: selections = [Selection(anchor: 0, head: text.length)]; primaryIndex = 0
        case .extendLine: selections = selections.map { extendLine($0, count: times) }; wholeLineSelection = true
        case .extendToLineBounds:
            selections = selections.map { range in
                let lines = lineBounds(range)
                return Selection(anchor: lines.first, head: nextLine(lines.last)).directed(backward: range.isBackward)
            }
            wholeLineSelection = true
        case .collapse: selections = selections.map { .point(cursor(of: $0)) }
        case .flip: selections = selections.map { Selection(anchor: $0.head, head: $0.anchor) }
        case .keepPrimary: selections = [primary]; primaryIndex = 0
        case .copyToNextLine: copyToLine(times, forward: true)
        case .copyToPreviousLine: copyToLine(times, forward: false)
        case .splitOnLines: splitOnLines()
        case .matchBracket:
            selections = selections.map { range in matchingBracket(cursor(of: range)).map { put(range, $0, extend: extend) } ?? range }
        case .selectObject(let object, let around): selections = selections.map { select(object, around: around, $0, count: times) }

        case .yank:
            outcome.yanked = yank(wholeLines: wholeLines, into: named)
            wholeLineSelection = wholeLines
            mode = .normal
        case .delete, .change: delete(change: command == .change, wholeLines: wholeLines, register: named, into: &outcome)
        case .paste(let before): paste(before: before, count: times, selectsPasted: !extend, register: named, into: &outcome); mode = .normal
        case .replaceWithRegister: replaceWithRegister(count: times, register: named, into: &outcome); mode = .normal
        case .replace(let character): replaceCharacters(with: character, into: &outcome); mode = .normal
        case .switchCase: replaceSelections(Self.switchedCase, into: &outcome); mode = .normal
        case .lowercase: replaceSelections({ $0.lowercased() }, into: &outcome); mode = .normal
        case .joinLines: joinLines(into: &outcome)
        case .indent: indent(times, into: &outcome); mode = .normal
        case .unindent: unindent(times, into: &outcome); mode = .normal
        case .surroundAdd(let character): surroundAdd(character, into: &outcome); mode = .normal
        case .surroundDelete(let character): surroundChange(character, with: nil, count: times, into: &outcome)
        case .surroundReplace(let character, let new): surroundChange(character, with: new, count: times, into: &outcome)

        case .insert(let entry): enterInsert(entry, count: times, into: &outcome)
        case .toggleSelect:
            if mode == .select { mode = .normal } else {
                // At the very end the selection still has to take a grapheme.
                selections = selections.map { range in
                    range.isEmpty && range.head == text.length ? Selection(anchor: text.previousBoundary(range.anchor), head: range.head) : range
                }
                mode = .select
            }
        case .escape:
            switch mode {
            case .insert:
                endInsertRun()
                if let blank = unusedIndent { commit([Edit(range: blank, replacement: "")], into: &outcome) }
                mode = .normal
            case .select: mode = .normal
            case .normal:
                if hasWideSelection { selections = selections.map { .point(cursor(of: $0)) } }
                else if selections.count > 1 { selections = [primary]; primaryIndex = 0 }
                else { outcome.leavesText = true }
            }
            if !outcome.leavesText { recordEscape() }

        case .searchNext, .searchPrevious:
            if let searchQuery { outcome.notice = step(searchQuery, backward: command == .searchPrevious, count: times, extend: extend) }
        case .searchSelection: searchQuery = selectionPattern()

        case .saveSelection: pushJump()
        case .jumpBackward: jumpBackward(times)
        case .jumpForward: jumpForward(times)
        case .repeatInsert:
            wholeLineSelection = wholeLines
            repeatInsert(times, into: &outcome)
        case .toggleRecording: toggleRecording(named)
        case .playMacro: playMacro(named, count: times, into: &outcome)
        }
        settle()
        if reduced, outcome.notice == nil { outcome.notice = .primaryOnly }
        // Only `i`, `a`, `c` … come here in insert mode.
        if mode == .insert, insertRun == nil, command != .escape { insertRun = InsertRun(entry: command, base: text, start: primary.head) }
        return outcome
    }

    /// `perform` for an app that types at one caret only (a page's text view):
    /// `c`, `i`, `a`, `o` … would otherwise work on selections it cannot show
    /// or type at, so these keep the primary selection first.
    public mutating func performAtPrimary(_ command: Command, count: Int? = nil) -> Outcome {
        typesAtPrimary = true
        defer { typesAtPrimary = false }
        return perform(command, count: count)
    }

    /// `/` and `?`: remembers the query (a regular expression, literal if it
    /// is none; lower case ignores case) and goes to its next match.
    @discardableResult
    public mutating func search(_ query: String, backward: Bool = false) -> Outcome {
        var outcome = Outcome()
        guard !query.isEmpty else { return outcome }
        searchQuery = query
        outcome.notice = step(query, backward: backward, count: 1, extend: mode == .select)
        settle()
        return outcome
    }

    /// `s`: every match inside the selections becomes a selection; no match
    /// keeps them. The pattern also becomes the search for `n`.
    @discardableResult
    public mutating func selectMatches(_ pattern: String) -> Outcome {
        var outcome = Outcome()
        guard !pattern.isEmpty else { return outcome }
        searchQuery = pattern
        var found: [Selection] = []
        for range in selections { found += matches(pattern, in: range.range).filter { !($0.isEmpty && $0.from == range.to) } }
        guard !found.isEmpty else { outcome.notice = .noMatch; return outcome }
        selections = found; primaryIndex = 0
        settle()
        return outcome
    }

    /// `S`: the selections fall apart at every match, without one they only
    /// run forward. The pattern also becomes the search for `n`.
    @discardableResult
    public mutating func splitMatches(_ pattern: String) -> Outcome {
        var outcome = Outcome()
        guard !pattern.isEmpty else { return outcome }
        searchQuery = pattern
        var found: [Selection] = [], hit = false
        for range in selections {
            guard !range.isEmpty else { found.append(range); continue }
            var start = range.from
            for match in matches(pattern, in: range.range) {
                hit = true
                found.append(Selection(anchor: start, head: match.from))
                start = match.to
            }
            if start < range.to { found.append(Selection(anchor: start, head: range.to)) }
        }
        if !hit { outcome.notice = .noMatch }
        selections = found; primaryIndex = 0
        settle()
        return outcome
    }

    /// Typing at every caret, for several selections; the app's native typing
    /// of a single one comes in through `sync`. A line break keeps the indent.
    @discardableResult
    public mutating func insertText(_ string: String) -> Outcome {
        guard mode == .insert, !string.isEmpty else { return Outcome() }
        return type { engine, caret in
            if string == "\n", let edit = TextTyping.newline(in: engine.string, range: NSRange(location: caret, length: 0)) {
                return (edit.range, edit.replacement, (edit.replacement as NSString).length)
            }
            if engine.autoPairs, let pair = TextTyping.pairing(string, in: engine.text, at: caret) {
                return (NSRange(location: caret, length: 0), pair.insert, pair.advance)
            }
            return (NSRange(location: caret, length: 0), string, (string as NSString).length)
        }
    }

    /// `change` gives each caret its edit and how far into the replacement the caret goes.
    private mutating func type(_ change: (TextEngine, Int) -> (range: NSRange, replacement: String, advance: Int)) -> Outcome {
        var outcome = Outcome()
        var edits: [Edit] = [], moved: [Selection] = [], shift = 0, end = 0
        for (index, range) in selections.enumerated() {
            var item = change(self, range.head)
            if item.range.location < end { item.range = NSRange(location: range.head, length: 0) }
            end = NSMaxRange(item.range)
            let delta = (item.replacement as NSString).length - item.range.length
            let head = item.range.location + shift + item.advance
            if index == 0 {
                // No replacement: the caret stepped over the typed character.
                let typed = item.replacement.isEmpty && item.range.length == 0 ? text.substring(with: NSRange(location: range.head, length: item.advance)) : item.replacement
                logTyping(typed, advance: item.advance)
            }
            if !item.replacement.isEmpty || item.range.length > 0 { edits.append(Edit(range: item.range, replacement: item.replacement)) }
            if range.isEmpty { moved.append(.point(head)) }
            // A one-wide selection ahead of a new pair shrinks to the closing half.
            else if range.isBackward { moved.append(Selection(anchor: !isWide(range) && item.advance < (item.replacement as NSString).length ? head + 1 : range.anchor + shift + delta, head: head)) }
            else { moved.append(Selection(anchor: min(range.anchor + shift, head), head: head)) }
            shift += delta
        }
        commit(edits, selecting: moved, into: &outcome)
        if edits.isEmpty { selections = moved }
        settle()
        return outcome
    }

    /// ⌫ at every caret.
    @discardableResult
    public mutating func deleteBackward() -> Outcome {
        var outcome = Outcome()
        guard mode == .insert else { return outcome }
        var edits: [Edit] = [], end = 0
        for (index, range) in selections.enumerated() where range.head > 0 {
            let pair = autoPairs && !isWide(range) ? TextTyping.pairDeletion(in: text, at: range.head) : nil
            let start = max(end, pair?.location ?? text.previousBoundary(range.head))
            let stop = pair.map(NSMaxRange) ?? range.head
            if start < stop { edits.append(Edit(range: NSRange(location: start, length: stop - start), replacement: "")) }
            end = stop
            if index == 0 { logDeletion(pair: pair != nil) }
        }
        commit(edits, into: &outcome)
        settle()
        return outcome
    }

    /// What `.` and a macro replay: the text as it stands, indent included.
    /// With automatic pairs it goes through them again, Helix replays keys.
    mutating func typeAgain(_ typed: TypedText) -> Outcome {
        if autoPairs {
            var composer = EditComposer(length: text.length), outcome = Outcome()
            for character in typed.text {
                let value = String(character)
                composer.add(type { engine, caret in
                    let pair = TextTyping.pairing(value, in: engine.text, at: caret)
                    return (NSRange(location: caret, length: 0), pair?.insert ?? value, pair?.advance ?? (value as NSString).length)
                })
            }
            composer.finish(in: text, into: &outcome)
            return outcome
        }
        let body = typed.text + typed.tail, advance = (typed.text as NSString).length
        guard !body.isEmpty else { return Outcome() }
        return type { _, caret in (NSRange(location: caret, length: 0), body, advance) }
    }

    // MARK: Selections

    private mutating func moveVertically(_ lines: Int, extend: Bool) {
        selections = selections.map { range in
            let found = layout.verticalTarget(from: cursor(of: range), lines: lines, goal: range.goal, in: text)
            // Extending must not swallow the line break of the last written line.
            if extend, found.offset == text.length, TextLines.start(text, found.offset) == found.offset { return range }
            var result = put(range, found.offset, extend: extend)
            result.goal = found.goal
            return result
        }
    }

    /// Line `number` (from 1), at most the last line with content.
    private mutating func gotoLine(_ number: Int, extend: Bool) {
        let starts = lineStarts
        let last = starts.count > 1 && starts[starts.count - 1] == text.length ? starts.count - 2 : starts.count - 1
        let target = starts[min(number - 1, last)]
        selections = selections.map { put($0, target, extend: extend) }
    }

    private func extendLine(_ range: Selection, count: Int) -> Selection {
        let lines = lineBounds(range)
        let complete = range.from == lines.first && range.to == nextLine(lines.last)
        var head = lines.last
        for _ in 0..<(complete ? count + 1 : count) { head = nextLine(head) }
        return Selection(anchor: lines.first, head: head)
    }

    private mutating func copyToLine(_ count: Int, forward: Bool) {
        var result = selections, newPrimary = 0
        let starts = lineStarts
        func row(_ offset: Int) -> (row: Int, column: Int) {
            let line = (starts.lastIndex { $0 <= offset }) ?? 0
            var column = 0, position = starts[line]
            while position < offset { position = text.nextBoundary(position); column += 1 }
            return (line, column)
        }
        func place(_ line: Int, _ column: Int) -> (offset: Int, column: Int) {
            let end = TextLines.end(text, starts[line])
            var position = starts[line], steps = 0
            while steps < column, position < end { position = text.nextBoundary(position); steps += 1 }
            return (position, steps)
        }
        for (index, range) in selections.enumerated() {
            let primary = index == primaryIndex
            let inward = range.anchor < range.head ? (head: text.previousBoundary(range.head), anchor: range.anchor)
                                                   : (head: range.head, anchor: text.previousBoundary(range.anchor))
            let head = row(inward.head), anchor = row(inward.anchor)
            let height = abs(head.row - anchor.row) + 1
            if primary { newPrimary = result.count }
            result.append(range)
            var made = 0, step = 1
            while made < count {
                let offset = step * height
                let anchorRow = forward ? anchor.row + offset : max(0, anchor.row - offset)
                let headRow = forward ? head.row + offset : max(0, head.row - offset)
                guard anchorRow < starts.count, headRow < starts.count else { break }
                let newAnchor = place(anchorRow, anchor.column), newHead = place(headRow, head.column)
                // Lines that are too short are skipped.
                if newAnchor.column == anchor.column, newHead.column == head.column {
                    if primary { newPrimary = result.count }
                    result.append(put(.point(newAnchor.offset), newHead.offset, extend: true))
                    made += 1
                }
                if anchorRow == 0, headRow == 0 { break }
                step += 1
            }
        }
        selections = result; primaryIndex = newPrimary
    }

    private mutating func splitOnLines() {
        var result: [Selection] = []
        for range in selections {
            guard !range.isEmpty else { result.append(range); continue }
            var start = range.from, index = range.from
            while index < range.to {
                if TextLines.isBreak(text.character(at: index)) {
                    result.append(Selection(anchor: start, head: index))
                    index = text.nextBoundary(index)
                    start = index
                } else { index += 1 }
            }
            if start < range.to { result.append(Selection(anchor: start, head: range.to)) }
        }
        selections = result; primaryIndex = 0
    }

    // MARK: Yank, delete, paste

    private func takesBreakBefore(_ range: Selection, wholeLines: Bool) -> Bool {
        wholeLines && !textEndsWithBreak && range.to == text.length && range.from > 0 && !range.isEmpty
    }

    /// False if there was nothing to take: an empty place must not wipe the register.
    /// Also false for a named register: only the default one reaches the system pasteboard.
    private mutating func yank(wholeLines: Bool, into name: String?) -> Bool {
        var values = selections.map { text.substring(with: $0.range) }
        guard name != "_", values.contains(where: { !$0.isEmpty }) else { return false }
        // The last line lacks the break that makes it a line in the register.
        if wholeLines, !textEndsWithBreak, let last = selections.last, last.to == text.length, !last.isEmpty {
            values[values.count - 1] += "\n"
        }
        guard let name, !Self.isDefaultRegister(name) else { register = Register(values: values); return true }
        registers[name] = Register(values: values)
        return false
    }
    /// `"`, as in Helix, and the two of the system clipboard: the default
    /// register already follows it.
    private static func isDefaultRegister(_ name: String) -> Bool { ["\"", "+", "*"].contains(name) }
    private func contents(of name: String?) -> Register? {
        guard let name, !Self.isDefaultRegister(name) else { return register }
        return registers[name]
    }

    private func isWholeLines(_ range: Selection) -> Bool {
        let lines = lineBounds(range)
        guard lines.first == range.from, nextLine(lines.last) == range.to else { return false }
        var index = range.from
        while index < range.to { if TextLines.isBreak(text.character(at: index)) { return true }; index += 1 }
        return false
    }

    private mutating func delete(change: Bool, wholeLines: Bool, register name: String?, into outcome: inout Outcome) {
        outcome.yanked = yank(wholeLines: wholeLines, into: name)
        let linewise = change && selections.allSatisfy(isWholeLines)
        var edits: [Edit] = [], carets: [Selection] = [], shift = 0
        var mergedIntoLastLine = false, previousEnd = 0
        for range in selections {
            var start = range.from
            // A selection in front may already hold that break.
            if !change, takesBreakBefore(range, wholeLines: wholeLines), text.previousBoundary(start) >= previousEnd {
                start = text.previousBoundary(start); mergedIntoLastLine = true
            }
            previousEnd = range.to
            // Whole lines stay as one empty line for the new text, indented like the line behind.
            let keepsLine = linewise && (range.to < text.length || textEndsWithBreak)
            let indent = keepsLine ? indentation(ofLine: range.to) : ""
            let replacement = keepsLine ? indent + "\n" : ""
            edits.append(Edit(range: NSRange(location: start, length: range.to - start), replacement: replacement))
            carets.append(.point(start + shift + (indent as NSString).length))
            shift += (replacement as NSString).length - (range.to - start)
        }
        commit(edits.filter { $0.range.length > 0 }, selecting: carets, into: &outcome)
        if mergedIntoLastLine, let last = selections.indices.last { selections[last] = .point(TextLines.start(text, text.length)) }
        mode = change ? .insert : .normal
    }

    /// `selectsPasted`: in select mode the selection stays where it is.
    private mutating func paste(before: Bool, count: Int, selectsPasted: Bool, register name: String?, into outcome: inout Outcome) {
        guard let register = contents(of: name), !register.values.isEmpty else {
            if name != nil, name != "_" { outcome.notice = .registerEmpty }
            return
        }
        let linewise = register.isLinewise
        var edits: [Edit] = [], ranges: [Selection] = [], shift = 0
        for (index, range) in selections.enumerated() {
            let value = String(repeating: register.values[min(index, register.values.count - 1)], count: count)
            var position: Int, inserted = value, skip = 0
            switch (before, linewise) {
            case (true, true): position = lineBounds(range).first
            case (false, true):
                position = nextLine(lineBounds(range).last)
                // No line behind the last one: the new line brings the break itself.
                if position == text.length, !textEndsWithBreak {
                    let body = Self.endsWithBreak(value) && value.count > 1 ? String(value.dropLast()) : value
                    inserted = text.length == 0 ? body : "\n" + body
                    skip = text.length == 0 ? 0 : 1
                }
            case (true, false): position = range.from
            case (false, false): position = range.to
            }
            let length = (inserted as NSString).length
            edits.append(Edit(range: NSRange(location: position, length: 0), replacement: inserted))
            ranges.append(Selection(anchor: position + shift + skip, head: position + shift + length).directed(backward: range.isBackward))
            shift += length
        }
        commit(edits.sorted { $0.range.location < $1.range.location }, selecting: selectsPasted ? ranges : nil, into: &outcome)
    }

    private mutating func replaceWithRegister(count: Int, register name: String?, into outcome: inout Outcome) {
        guard let register = contents(of: name), !register.values.isEmpty else {
            if name != nil, name != "_" { outcome.notice = .registerEmpty }
            return
        }
        var edits: [Edit] = [], index = 0
        for range in selections where !range.isEmpty {
            let value = register.values[min(index, register.values.count - 1)]
            edits.append(Edit(range: range.range, replacement: String(repeating: value, count: count)))
            index += 1
        }
        commit(edits, into: &outcome)
    }

    /// `r`: every grapheme of the selections, line breaks included.
    private mutating func replaceCharacters(with character: String, into outcome: inout Outcome) {
        replaceSelections({ String(repeating: character, count: $0.count) }, into: &outcome)
    }
    private mutating func replaceSelections(_ change: (String) -> String, into outcome: inout Outcome) {
        let edits = selections.filter { !$0.isEmpty }.map { Edit(range: $0.range, replacement: change(text.substring(with: $0.range))) }
        commit(edits, into: &outcome)
        outcome.keepsFormat = true
    }
    private static func switchedCase(_ value: String) -> String {
        var result = ""
        for scalar in value.unicodeScalars {
            let properties = scalar.properties
            if properties.isLowercase { result += properties.uppercaseMapping }
            else if properties.isUppercase { result += properties.lowercaseMapping }
            else { result.unicodeScalars.append(scalar) }
        }
        return result
    }

    private mutating func joinLines(into outcome: inout Outcome) {
        let starts = lineStarts
        var edits: [Edit] = []
        for range in selections {
            let bounds = lineBounds(range)
            let first = starts.lastIndex { $0 <= bounds.first } ?? 0
            var last = starts.lastIndex { $0 <= bounds.last } ?? 0
            if first == last { last = min(last + 1, starts.count - 1) }
            for line in first..<max(first, last) {
                let start = TextLines.end(text, starts[line])
                var end = starts[line + 1]
                let lineEnd = TextLines.end(text, end)
                while end < lineEnd, [32, 9].contains(text.character(at: end)) { end += 1 }
                edits.append(Edit(range: NSRange(location: start, length: end - start), replacement: end == lineEnd ? "" : " "))
            }
        }
        var seen = Set<Int>()
        commit(edits.sorted { $0.range.location < $1.range.location }.filter { seen.insert($0.range.location).inserted }, into: &outcome)
    }

    /// Beginnings of all selected lines, each once.
    private var selectedLines: [Int] {
        var lines = Set<Int>()
        for range in selections {
            let bounds = lineBounds(range)
            var line = bounds.first
            while true {
                lines.insert(line)
                let next = nextLine(line)
                guard line < bounds.last, next > line else { break }
                line = next
            }
        }
        return lines.sorted()
    }

    private mutating func indent(_ count: Int, into outcome: inout Outcome) {
        let unit = String(repeating: indentUnit, count: count)
        let edits = selectedLines.filter { firstNonBlank($0) != nil }.map { Edit(range: NSRange(location: $0, length: 0), replacement: unit) }
        commit(edits, into: &outcome)
    }

    private mutating func unindent(_ count: Int, into outcome: inout Outcome) {
        let tabWidth = 4, wanted = count * max(1, indentUnit == "\t" ? tabWidth : (indentUnit as NSString).length)
        var edits: [Edit] = []
        for line in selectedLines {
            let end = TextLines.end(text, line)
            var width = 0, position = line
            while position < end, width < wanted {
                let unit = text.character(at: position)
                if unit == 32 { width += 1 } else if unit == 9 { width = (width / tabWidth + 1) * tabWidth } else { break }
                position += 1
            }
            if position > line { edits.append(Edit(range: NSRange(location: line, length: position - line), replacement: "")) }
        }
        commit(edits, into: &outcome)
    }

    private mutating func surroundAdd(_ character: String, into outcome: inout Outcome) {
        let pair = Self.pair(for: character)
        let added = (pair.open as NSString).length + (pair.close as NSString).length
        var edits: [Edit] = [], ranges: [Selection] = [], shift = 0
        for range in selections {
            edits.append(Edit(range: NSRange(location: range.from, length: 0), replacement: pair.open))
            edits.append(Edit(range: NSRange(location: range.to, length: 0), replacement: pair.close))
            ranges.append(Selection(anchor: range.from + shift, head: range.to + shift + added).directed(backward: range.isBackward))
            shift += added
        }
        commit(edits, selecting: ranges, into: &outcome)
    }

    /// `md` and `mr`; a selection without its pair changes nothing at all.
    private mutating func surroundChange(_ character: String?, with new: String?, count: Int, into outcome: inout Outcome) {
        var positions: [(offset: Int, replacement: String)] = []
        let pair = new.map(Self.pair)
        for range in selections {
            guard let found = surroundingPair(character, around: range, count: count),
                  !positions.contains(where: { $0.offset == found.open || $0.offset == found.close }) else {
                outcome.notice = .pairNotFound; return
            }
            positions.append((found.open, pair?.open ?? ""))
            positions.append((found.close, pair?.close ?? ""))
        }
        let edits = positions.sorted { $0.offset < $1.offset }.map { place in
            Edit(range: NSRange(location: place.offset, length: text.nextBoundary(place.offset) - place.offset), replacement: place.replacement)
        }
        commit(edits, into: &outcome)
        mode = .normal
    }

    // MARK: Insert mode

    private mutating func enterInsert(_ entry: InsertEntry, count: Int, into outcome: inout Outcome) {
        mode = .insert
        switch entry {
        case .before: selections = selections.map { Selection(anchor: $0.to, head: $0.from) }
        case .after: selections = selections.map { Selection(anchor: $0.from, head: $0.to) }
        case .lineStart:
            selections = selections.map { range in
                let line = TextLines.start(text, cursorBeforeInsert(range))
                return .point(firstNonBlank(line) ?? line)
            }
        case .lineEnd: selections = selections.map { .point(TextLines.end(text, cursorBeforeInsert($0))) }
        case .lineBelow, .lineAbove:
            var edits: [Edit] = [], carets: [Selection] = [], shift = 0
            for range in selections {
                let bounds = lineBounds(range), below = entry == .lineBelow
                let position = below ? TextLines.end(text, bounds.last) : bounds.first
                let indent = indentation(ofLine: below ? bounds.last : bounds.first), step = (indent as NSString).length + 1
                edits.append(Edit(range: NSRange(location: position, length: 0), replacement: String(repeating: below ? "\n" + indent : indent + "\n", count: count)))
                for line in 0..<count { carets.append(.point(position + shift + line * step + step - (below ? 0 : 1))) }
                shift += count * step
            }
            commit(edits, selecting: carets, into: &outcome)
        }
    }
    /// What a new line takes over from the line at `offset`, exactly as it stands.
    func indentation(ofLine offset: Int) -> String {
        let line = TextLines.start(text, offset), end = TextLines.end(text, line)
        var first = line
        while first < end, [32, 9].contains(text.character(at: first)) { first += 1 }
        return text.substring(with: NSRange(location: line, length: first - line))
    }
    /// The block cursor of a selection: the mode has already changed here.
    private func cursorBeforeInsert(_ range: Selection) -> Int {
        range.head > range.anchor ? text.previousBoundary(range.head) : range.head
    }
}
