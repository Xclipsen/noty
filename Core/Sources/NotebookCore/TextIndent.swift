import Foundation

/// The front of a paragraph (docs/TEXT-FIELDS.md, „Einzug und Listen“):
/// leading tabs/spaces, then optionally one mark with white space behind it.
/// Everything up to `body` is the prefix; `body` is the first character of
/// the text, the place continuation lines hang under.
///
/// - List marks (`list`): `• ◦ ▪ - ☐ ☑` and `n.`, each followed by a space
///   (`TextListEditing.prefix`); Return continues them, ⌫ behind them removes them.
/// - Hanging marks (`hanging`): the same marks followed by a tab, and the
///   arrows `-> → => ⇒` followed by white space; only for the layout.
/// - Labels (`label`): a short word without spaces ending in „:“ (`Bsp.:`,
///   `Merke:`, at most 12 characters) followed by one or more tabs, also behind
///   a mark („• Bsp.:\tText“); only for the layout.
public struct TextParagraphPrefix: Equatable, Sendable {
    public enum Mark: Equatable, Sendable {
        case list(TextListEditing.Kind)
        case hanging
    }
    /// Start of the paragraph.
    public var start: Int
    /// End of the paragraph, before its line break.
    public var end: Int
    /// UTF-16 length of the leading tabs and spaces.
    public var leading: Int
    /// Leading tabs (they count as levels) and spaces (they do not).
    public var tabs: Int
    public var spaces: Int
    public var mark: Mark?
    /// The mark's own characters („•“, „12.“, „->“), without the white space behind it.
    public var marker: NSRange?
    /// Behind the mark and its white space (behind the leading white space without a mark).
    public var markEnd: Int
    /// A label („Bsp.:“) at `markEnd`, followed by tabs; only for the layout.
    public var label: NSRange?
    /// First character of the text behind mark and label: the hanging edge;
    /// `end` when the paragraph has no text.
    public var body: Int

    public var isList: Bool { if case .list = mark { true } else { false } }
    public var listKind: TextListEditing.Kind? { if case .list(let kind) = mark { kind } else { nil } }
    /// Nothing but the prefix.
    public var isEmpty: Bool { body >= end }
    /// The level of the paragraph: `indent` in 20-pt steps plus its leading tabs.
    public func level(indent: Double?) -> Int { TextListEditing.level(forIndent: indent) + tabs }
    /// Tab at `location` indents the whole paragraph: in or in front of the
    /// leading white space, or right behind a mark and exactly one space
    /// („• |“). Everywhere else (behind „1.\t“, after a label) Tab is a tab.
    public func tabIndents(at location: Int) -> Bool {
        if location <= start + leading { return true }
        guard let marker, oneSpaceAfterMark else { return false }
        return location > marker.location && location <= markEnd
    }
    /// The mark is followed by exactly one space (not a tab, not more).
    var oneSpaceAfterMark = false

    static let labelLength = 12

    /// The prefix of the paragraph holding `location`.
    public init(in text: NSString, at location: Int) {
        let start = TextLines.start(text, min(max(0, location), text.length))
        self.init(text: text, start: start)
    }
    init(text: NSString, start: Int) {
        self.start = start
        let end = TextLines.end(text, start)
        self.end = end
        var index = start
        tabs = 0; spaces = 0
        while index < end {
            let unit = text.character(at: index)
            if unit == 9 { tabs += 1 } else if unit == 32 { spaces += 1 } else { break }
            index += 1
        }
        leading = index - start
        mark = nil; marker = nil; label = nil
        // Every mark is short: the start of the text is enough (long paragraphs stay cheap).
        func rest(_ from: Int) -> String { text.substring(with: NSRange(location: from, length: min(end - from, 40))) }
        if let (kind, length) = Self.mark(in: rest(index)) {
            mark = kind
            marker = NSRange(location: index, length: length)
            index += length
            let blankStart = index
            while index < end, Self.isBlank(text.character(at: index)) { index += 1 }
            oneSpaceAfterMark = index == blankStart + 1 && text.character(at: blankStart) == 32
        }
        markEnd = index
        // A label also behind a mark: „• Bsp.:\tText“ hangs behind the tab.
        if let length = Self.label(in: rest(index)) {
            label = NSRange(location: index, length: length)
            index += length
            while index < end, Self.isBlank(text.character(at: index)) { index += 1 }
        }
        body = index
    }
    private static func isBlank(_ unit: unichar) -> Bool { unit == 9 || unit == 32 }

    /// The mark at the start of `rest` and its UTF-16 length (white space behind it excluded).
    private static func mark(in rest: String) -> (Mark, Int)? {
        let units = Array(rest.utf16)
        func blank(after length: Int) -> Bool { length < units.count && (units[length] == 9 || units[length] == 32) }
        if let list = TextListEditing.prefix(rest), let kind = [TextListEditing.Kind.checkbox, .bullet, .numbered].first(where: { TextListEditing.matches($0, list) }) {
            return (.list(kind), (list as NSString).length - 1)
        }
        for symbol in ["->", "=>", "→", "⇒", "•", "◦", "▪", "-", "☐", "☑"] where rest.hasPrefix(symbol) {
            let length = (symbol as NSString).length
            if blank(after: length) { return (.hanging, length) }
        }
        let digits = units.prefix { (48...57).contains($0) }.count
        if (1...6).contains(digits), digits < units.count, units[digits] == 46 /* . */, blank(after: digits + 1) {
            return (.hanging, digits + 1)
        }
        return nil
    }
    /// A short label at the start of `rest`: no white space inside, ends in
    /// „:“, a tab right behind it. Its UTF-16 length.
    private static func label(in rest: String) -> Int? {
        let units = Array(rest.utf16)
        guard let space = units.firstIndex(where: { $0 == 9 || $0 == 32 }), space > 1, units[space] == 9,
              units[space - 1] == 58 /* : */ else { return nil }
        let word = String(decoding: units[0..<space], as: UTF16.self)
        guard word.count <= labelLength, word.contains(where: \.isLetter) else { return nil }
        return space
    }
}

/// Hanging indent (docs/TEXT-FIELDS.md): the first line starts at the stored
/// paragraph indent, every further line of the paragraph under its first text
/// character (`TextParagraphPrefix.body`). Derived from the text when it is
/// laid out, never stored: TextKit's `headIndent` holds it, the stored indent
/// is `firstLineHeadIndent` (`storedIndent`).
public enum TextIndentLayout {
    /// Room a hanging line keeps at least, in ems of the paragraph's font.
    public static let minimumLineEms = 4.0

    /// `headIndent` of the paragraph starting at `paragraphStart`.
    /// - Parameters:
    ///   - indent: the stored indent (`firstLineHeadIndent`).
    ///   - tabInterval: the field's tab grid (`TextTabs.interval`), stops from the field's left edge.
    ///   - width: the text width of the field.
    ///   - em: the font size at the paragraph's text.
    ///   - measure: width of a range of `text` without tabs, in its own format.
    /// - Returns: `indent` without prefix and for centred or right-aligned
    ///   paragraphs; otherwise the x of the first text character, at most
    ///   `width − 4 em` (never back to the indent because of a narrow field).
    public static func hangingEdge(in text: NSString, at paragraphStart: Int, indent: Double, tabInterval: Double,
                                   width: Double, em: Double, alignment: TextAlignment? = nil,
                                   measure: (NSRange) -> Double) -> Double {
        let indent = indent.isFinite ? max(0, indent) : 0
        guard alignment != .center, alignment != .right, width.isFinite, width > 0, tabInterval > 0 else { return indent }
        let prefix = TextParagraphPrefix(in: text, at: paragraphStart)
        guard prefix.body > prefix.start else { return indent }
        var x = indent, segment = prefix.start
        for index in prefix.start..<prefix.body where text.character(at: index) == 9 {
            if index > segment { x += measure(NSRange(location: segment, length: index - segment)) }
            x = TextTabs.nextStop(after: x, interval: tabInterval)
            segment = index + 1
        }
        if prefix.body > segment { x += measure(NSRange(location: segment, length: prefix.body - segment)) }
        guard x.isFinite else { return indent }
        let limit = max(indent, width - minimumLineEms * max(1, em))
        return min(max(indent, x), limit)
    }

    /// The paragraph indent a text format stores: the first line's, never the
    /// derived hanging edge.
    public static func storedIndent(firstLineHeadIndent: Double, headIndent: Double) -> Double {
        min(240, max(0, firstLineHeadIndent.isFinite ? firstLineHeadIndent : 0))
    }

    /// Whether `box` is laid out with its hanging indents: only a free field,
    /// and only when its text with them (`heightWithHanging`, page units) fits
    /// the stored height. Otherwise exactly as before, without: an older field
    /// never grows, overflows or covers ink because of them. Editing measures
    /// the height with hanging indents (`fitted`), so an edited field fits and
    /// takes them over. One rule for editor, previews, search and PDF.
    public static func hangs(_ box: TextBox, heightWithHanging: Double) -> Bool {
        box.flowID == nil && !box.overflows(textHeight: heightWithHanging)
    }
}

/// Tab, ⇧Tab, the indent buttons, Return and ⌫ (docs/TEXT-FIELDS.md). New
/// indents are leading tabs; the older paragraph indent (`TextBoxStyle.indent`,
/// 20 pt per level) is only ever reduced. Edits are UTF-16 ranges of the text
/// before them.
public enum TextIndentEditing {
    public struct IndentChange: Equatable, Sendable {
        /// The paragraph (with its line break) in the text before the edits.
        public var paragraph: NSRange
        public var indent: Double
    }
    public struct Plan: Equatable, Sendable {
        /// Paragraph indents first (attributes only, text unchanged) …
        public var indents: [IndentChange]
        /// … then these text edits (tabs, list marks), ascending …
        public var edits: [TextListEditing.Edit]
        /// … then the renumbering, in the coordinates after `edits`.
        public var renumbering: [TextListEditing.Edit]
    }
    public enum Action: Equatable, Sendable {
        /// Replace `edit.range` by `edit.replacement`, the caret goes behind it.
        case edit(TextListEditing.Edit)
        case plan(Plan)
    }

    /// Paragraph starts touched by `selection`; one ending right behind a line
    /// break does not reach into the next paragraph.
    public static func paragraphStarts(in text: NSString, _ selection: NSRange) -> [Int] {
        var result = [TextLines.start(text, selection.location)]
        var index = selection.location
        let end = min(text.length, NSMaxRange(selection))
        while index < end {
            if TextLines.isBreak(text.character(at: index)), index + 1 < end { result.append(index + 1) }
            index += 1
        }
        return result
    }

    /// Tab (`outdent` false) or ⇧Tab. nil: Tab types an ordinary tab at the
    /// caret (replacing a selection); ⇧Tab does nothing.
    /// - Tab with the caret (or the selection's start) where it indents
    ///   (`TextParagraphPrefix.tabIndents`), or `wholeParagraphs` (the indent
    ///   button): a tab at the paragraph's start. Over several paragraphs: every
    ///   one that is not empty. An older indent becomes tabs first (rounded to
    ///   the tab grid), so the paragraph moves exactly one stop and its level is
    ///   its tabs.
    /// - ⇧Tab and the outdent button: every touched paragraph loses a leading
    ///   tab, else up to four leading spaces, else 20 pt of its older indent.
    /// - `canChangeIndent` false (a buffer without paragraph formats, a flow
    ///   segment): the older indent stays as it is and counts as a fixed level.
    /// List items take the bullet of their new level, moved numbers restart.
    public static func tab(_ box: TextBox, selection: NSRange, outdent: Bool, wholeParagraphs: Bool = false,
                           canChangeIndent: Bool = true,
                           context: TextListEditing.ListContext = .init(), continuation: Bool = false) -> Plan? {
        let source = box.text as NSString
        guard selection.location >= 0, selection.length >= 0, NSMaxRange(selection) <= source.length else { return nil }
        let starts = paragraphStarts(in: source, selection)
        if !outdent, starts.count == 1, !wholeParagraphs, !(continuation && starts[0] == 0),
           !TextParagraphPrefix(text: source, start: starts[0]).tabIndents(at: selection.location) { return nil }
        return plan(box, starts: starts, outdent: outdent, canChangeIndent: canChangeIndent, extra: [],
                    context: context, continuation: continuation)
    }

    /// The plan for `starts`; nil when no paragraph moves. `extra`: further
    /// edits of the same step (a selection Return replaces).
    private static func plan(_ box: TextBox, starts: [Int], outdent: Bool, canChangeIndent: Bool, extra: [TextListEditing.Edit],
                             context: TextListEditing.ListContext, continuation: Bool) -> Plan? {
        let source = box.text as NSString
        var indents: [IndentChange] = [], edits: [TextListEditing.Edit] = []
        for start in starts {
            // The first paragraph of a later flow page continues one of the page before.
            guard !(continuation && start == 0) else { continue }
            let prefix = TextParagraphPrefix(text: source, start: start)
            let indent = box.style(at: start).indent ?? 0
            let level = prefix.level(indent: indent)
            var newLevel = level
            let paragraph = TextLines.paragraphRange(source, NSRange(location: start, length: 0))
            if outdent {
                if prefix.leading > 0, source.character(at: start) == 9 {
                    edits.append(.init(range: NSRange(location: start, length: 1), replacement: ""))
                    newLevel -= 1
                } else if prefix.leading > 0 {
                    var count = 0
                    while count < 4, start + count < prefix.end, source.character(at: start + count) == 32 { count += 1 }
                    edits.append(.init(range: NSRange(location: start, length: count), replacement: ""))
                } else if indent > 0, canChangeIndent {
                    let reduced = max(0, indent - TextPlacement.indentStep)
                    indents.append(.init(paragraph: paragraph, indent: reduced))
                    newLevel = prefix.level(indent: reduced)
                } else { continue }
            } else {
                if starts.count > 1 {
                    guard start < source.length, !TextLines.isBreak(source.character(at: start)) else { continue }
                }
                var count = 1, converted = false
                if canChangeIndent, indent > 0 {
                    // The older indent as tabs on the field's grid, then one more.
                    count += Int((indent / TextTabs.interval(box)).rounded())
                    indents.append(.init(paragraph: paragraph, indent: 0))
                    newLevel = prefix.tabs + count; converted = true
                } else { newLevel += 1 }
                edits.append(.init(range: NSRange(location: start, length: 0), replacement: String(repeating: "\t", count: count)))
                if converted, newLevel == level, let marker = marker(prefix, in: source, level: newLevel) { edits.append(marker) }
            }
            if newLevel != level, let marker = marker(prefix, in: source, level: newLevel) { edits.append(marker) }
        }
        guard !indents.isEmpty || !edits.isEmpty else { return nil }
        edits += extra
        edits.sort { $0.range.location < $1.range.location }
        return Plan(indents: indents, edits: edits,
                    renumbering: renumbering(box, indents: indents, edits: edits, starts: starts, context: context, continuation: continuation))
    }

    /// A list item's mark on `level`: bullets of •◦▪ change their glyph, a
    /// number starts again at 1. „-“ and checkboxes stay.
    private static func marker(_ prefix: TextParagraphPrefix, in source: NSString, level: Int) -> TextListEditing.Edit? {
        guard let kind = prefix.listKind, let marker = prefix.marker else { return nil }
        let current = source.substring(with: marker)
        switch kind {
        case .bullet:
            let glyph = String(TextListEditing.bullet(forLevel: level).prefix(1))
            guard TextListEditing.bulletGlyphs.contains(current), current != glyph else { return nil }
            return .init(range: marker, replacement: glyph)
        case .numbered:
            return current == "1." ? nil : .init(range: marker, replacement: "1.")
        case .checkbox: return nil
        }
    }

    /// Renumbering of the lists around the changed paragraphs, in the
    /// coordinates after `edits`; runs starting at a moved item start at 1.
    private static func renumbering(_ box: TextBox, indents: [IndentChange], edits: [TextListEditing.Edit], starts: [Int],
                                    context: TextListEditing.ListContext, continuation: Bool) -> [TextListEditing.Edit] {
        var result = box
        for change in indents { result = result.restyled([change.paragraph]) { $0.indent = change.indent } }
        result = result.applying(edits)
        guard let first = starts.first, let last = starts.last else { return [] }
        let source = result.text as NSString
        let from = TextListEditing.selection(NSRange(location: first, length: 0), after: edits).location
        let to = min(source.length, TextLines.end(source, TextListEditing.selection(NSRange(location: last, length: 0), after: edits).location))
        let from0 = TextLines.start(source, min(from, source.length))
        return TextListEditing.normalize(result.text, level: result.listLevel(at:),
            changed: NSRange(location: from0, length: max(0, to - from0)), context: context,
            continuation: continuation, freshStarts: true)
    }

    /// Return at `range` in a paragraph. nil: an ordinary line break (the text
    /// view replaces a selection by it).
    /// - A selection over several paragraphs, or one starting inside the
    ///   prefix (before the mark's white space ends): ordinary.
    /// - A selection in one paragraph is replaced first; whether an item is
    ///   empty is decided without it.
    /// - List item with text: line break, the same leading white space and the next mark.
    /// - Empty list item: one level out (a tab, else 20 pt of the indent if
    ///   `canChangeIndent`); where nothing can move, and on level 0, the mark goes.
    /// - Any other paragraph with leading white space (arrows and labels
    ///   included, which are not continued): line break and the same white space.
    public static func newline(_ box: TextBox, range: NSRange, canChangeIndent: Bool = true,
                               context: TextListEditing.ListContext = .init(), continuation: Bool = false) -> Action? {
        let source = box.text as NSString
        guard range.location >= 0, range.length >= 0, NSMaxRange(range) <= source.length else { return nil }
        let prefix = TextParagraphPrefix(in: source, at: range.location)
        guard NSMaxRange(range) <= prefix.end, !(continuation && prefix.start == 0), range.location >= prefix.markEnd else { return nil }
        let leading = source.substring(with: NSRange(location: prefix.start, length: prefix.leading))
        guard prefix.isList, let marker = prefix.marker else {
            return leading.isEmpty ? nil : .edit(.init(range: range, replacement: "\n" + leading))
        }
        let before = source.substring(with: NSRange(location: prefix.markEnd, length: range.location - prefix.markEnd))
        let rest = source.substring(with: NSRange(location: NSMaxRange(range), length: prefix.end - NSMaxRange(range)))
        if before.trimmingCharacters(in: .whitespaces).isEmpty, rest.trimmingCharacters(in: .whitespaces).isEmpty {
            let indent = box.style(at: prefix.start).indent ?? 0
            let selected = range.length > 0 ? [TextListEditing.Edit(range: range, replacement: "")] : []
            if prefix.level(indent: indent) > 0,
               let plan = plan(box, starts: [prefix.start], outdent: true, canChangeIndent: canChangeIndent, extra: selected,
                               context: context, continuation: continuation) {
                return .plan(plan)
            }
            // The mark, the blank behind it and the selection go.
            return .edit(.init(range: NSRange(location: marker.location, length: max(prefix.markEnd, NSMaxRange(range)) - marker.location),
                               replacement: ""))
        }
        var mark = source.substring(with: NSRange(location: marker.location, length: prefix.markEnd - marker.location))
        switch prefix.listKind {
        case .checkbox?: mark = "☐" + mark.dropFirst()
        case .numbered?:
            let digits = mark.prefix { $0.isASCII && $0.isNumber }
            if let number = Int(digits), number < 999_999 { mark = "\(number + 1)" + mark.dropFirst(digits.count) }
        default: break
        }
        return .edit(.init(range: range, replacement: "\n" + leading + mark))
    }

    /// ⌫ at a caret. nil: an ordinary ⌫.
    /// - Right behind a list mark and its white space: the mark goes, the indent stays.
    /// - At the start of a paragraph with an older indent (if `canChangeIndent`):
    ///   20 pt less first, before the paragraph joins the one before.
    /// Behind leading tabs ⌫ deletes one tab, as usual.
    public static func backspace(_ box: TextBox, caret: Int, canChangeIndent: Bool = true,
                                 context: TextListEditing.ListContext = .init(), continuation: Bool = false) -> Action? {
        let source = box.text as NSString
        guard caret >= 0, caret <= source.length else { return nil }
        let prefix = TextParagraphPrefix(in: source, at: caret)
        guard !(continuation && prefix.start == 0) else { return nil }
        if prefix.isList, let marker = prefix.marker, caret == prefix.markEnd, caret > marker.location {
            return .edit(.init(range: NSRange(location: marker.location, length: prefix.markEnd - marker.location), replacement: ""))
        }
        let indent = box.style(at: prefix.start).indent ?? 0
        guard canChangeIndent, caret == prefix.start, indent > 0 else { return nil }
        let reduced = max(0, indent - TextPlacement.indentStep)
        let changes = [IndentChange(paragraph: TextLines.paragraphRange(source, NSRange(location: prefix.start, length: 0)), indent: reduced)]
        var edits: [TextListEditing.Edit] = []
        if let marker = marker(prefix, in: source, level: prefix.level(indent: reduced)) { edits.append(marker) }
        return .plan(Plan(indents: changes, edits: edits,
            renumbering: renumbering(box, indents: changes, edits: edits, starts: [prefix.start], context: context, continuation: continuation)))
    }
}

extension TextBox {
    /// The box after `plan` (the same steps the editors apply to their text storage).
    public func applying(_ plan: TextIndentEditing.Plan) -> TextBox {
        var box = self
        for change in plan.indents { box = box.restyled([change.paragraph]) { $0.indent = change.indent } }
        return box.applying(plan.edits).applying(plan.renumbering)
    }
}

/// Arrows while typing (Einstellungen › Editor, `noty.editor.arrows`, on by
/// default): `->` → `→`, `=>` → `⇒`, `<-` → `←`, `<->` → `↔`, only at the
/// start of a paragraph or behind white space, and only when the space behind
/// them is typed (as the automatic lists). ⌫ right behind it brings back what
/// was typed. Nothing else (no ≤ ≥ ≠ ±): the calculator's „=“ stays untouched.
public enum TextArrowReplacement {
    /// Longer patterns first: `<->` is not `<-` followed by `>`.
    public static let rules: [(typed: String, arrow: String)] = [("<->", "↔"), ("->", "→"), ("=>", "⇒"), ("<-", "←")]

    public struct Replacement: Equatable, Sendable {
        /// Replaces the typed characters (without the space) by the arrow.
        public var edit: TextListEditing.Edit
        /// What was typed, without the space.
        public var typed: String
        /// The arrow and its space after `edit`; ⌫ at its end restores.
        public var written: NSRange
    }

    /// The space just typed in front of `caret` completes an arrow. nil: nothing to replace.
    public static func replacement(in text: String, caret: Int) -> Replacement? {
        let source = text as NSString
        guard caret >= 3, caret <= source.length, source.character(at: caret - 1) == 32 else { return nil }
        let end = caret - 1
        for rule in rules {
            let length = (rule.typed as NSString).length
            guard end >= length else { continue }
            let range = NSRange(location: end - length, length: length)
            guard source.substring(with: range) == rule.typed else { continue }
            if range.location > 0 {
                let before = source.character(at: range.location - 1)
                guard before == 32 || before == 9 || TextLines.isBreak(before) else { continue }
            }
            let written = NSRange(location: range.location, length: (rule.arrow as NSString).length + 1)
            return Replacement(edit: .init(range: range, replacement: rule.arrow), typed: rule.typed, written: written)
        }
        return nil
    }

    /// ⌫ with the caret right behind a replaced arrow and its space: the typed
    /// characters and the space come back, the caret behind them. nil: an ordinary ⌫.
    public static func restoring(_ replacement: Replacement, in text: String, caret: Int) -> TextListEditing.Edit? {
        let source = text as NSString, written = replacement.written
        guard caret == NSMaxRange(written), NSMaxRange(written) <= source.length,
              source.substring(with: written) == replacement.edit.replacement + " " else { return nil }
        return .init(range: written, replacement: replacement.typed + " ")
    }
}
