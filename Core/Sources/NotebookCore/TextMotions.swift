import Foundation

/// Cursor motions and edits of the keyboard mode on plain text (a free field
/// or a text document's whole flow). As in vim, normal mode stands on a
/// character: the caret offset is the character after it, never behind the
/// last character of a non-empty line. `up`/`down` follow the laid-out lines
/// and are left to the app, except for whole-line operators (`dj`).
public enum TextMotions {
    private enum Kind { case space, word, punctuation }
    private static func kind(_ unit: unichar) -> Kind {
        guard let scalar = UnicodeScalar(unit) else { return .word } // surrogates: letters, emoji
        if CharacterSet.whitespacesAndNewlines.contains(scalar) { return .space }
        if CharacterSet.alphanumerics.contains(scalar) || unit == 95 { return .word }
        return .punctuation
    }
    static func isBreak(_ unit: unichar) -> Bool { [10, 13, 0x2028, 0x2029].contains(unit) }
    public static func isLineBreak(_ unit: unichar) -> Bool { isBreak(unit) }

    /// Start of the line (paragraph) holding `caret`.
    public static func lineStart(_ text: NSString, _ caret: Int) -> Int {
        var index = min(caret, text.length)
        while index > 0, !isBreak(text.character(at: index - 1)) { index -= 1 }
        return index
    }
    /// End of that line, before its line break.
    public static func lineEnd(_ text: NSString, _ caret: Int) -> Int {
        var index = min(caret, text.length)
        while index < text.length, !isBreak(text.character(at: index)) { index += 1 }
        return index
    }
    private static func next(_ text: NSString, _ index: Int) -> Int {
        index >= text.length ? text.length : NSMaxRange(text.rangeOfComposedCharacterSequence(at: index))
    }
    private static func previous(_ text: NSString, _ index: Int) -> Int {
        index <= 0 ? 0 : text.rangeOfComposedCharacterSequence(at: index - 1).location
    }

    /// Normal mode's place: on the last character of a line, not behind it.
    public static func normalCaret(_ text: NSString, _ caret: Int) -> Int {
        let caret = min(max(0, caret), text.length), end = lineEnd(text, caret)
        return caret == end && end > lineStart(text, caret) ? previous(text, end) : caret
    }

    private static func wordForward(_ text: NSString, _ from: Int) -> Int {
        var index = from
        guard index < text.length else { return text.length }
        let start = kind(text.character(at: index))
        if start != .space { while index < text.length, kind(text.character(at: index)) == start { index += 1 } }
        while index < text.length, kind(text.character(at: index)) == .space {
            // An empty line is a word of its own.
            if isBreak(text.character(at: index)), index > from, index + 1 < text.length, isBreak(text.character(at: index + 1)) { return index + 1 }
            index += 1
        }
        return index
    }
    private static func wordBackward(_ text: NSString, _ from: Int) -> Int {
        var index = from
        while index > 0, kind(text.character(at: index - 1)) == .space { index -= 1 }
        guard index > 0 else { return 0 }
        let start = kind(text.character(at: index - 1))
        while index > 0, kind(text.character(at: index - 1)) == start { index -= 1 }
        return index
    }
    /// Last character of the current or next word.
    private static func wordEnd(_ text: NSString, _ from: Int) -> Int {
        var index = next(text, from)
        while index < text.length, kind(text.character(at: index)) == .space { index += 1 }
        guard index < text.length else { return max(from, previous(text, text.length)) }
        let start = kind(text.character(at: index))
        while index < text.length, kind(text.character(at: index)) == start { index += 1 }
        return previous(text, index)
    }
    private static func paragraph(_ text: NSString, _ from: Int, forward: Bool) -> Int {
        // The nearest empty line, or the end of the text.
        func empty(_ index: Int) -> Bool {
            index < text.length && isBreak(text.character(at: index)) && (index == 0 || isBreak(text.character(at: index - 1)))
        }
        var index = forward ? from + 1 : from - 1
        while index > 0, index < text.length, !empty(index) { index += forward ? 1 : -1 }
        return min(max(0, index), text.length)
    }
    private static func firstNonBlank(_ text: NSString, _ caret: Int) -> Int {
        var index = lineStart(text, caret)
        let end = lineEnd(text, caret)
        while index < end, kind(text.character(at: index)) == .space { index += 1 }
        return index
    }

    /// Where a motion leads, nil for the layout-bound `up`/`down`.
    public static func target(_ motion: TextMotion, in text: NSString, from caret: Int, count: Int = 1) -> Int? {
        let caret = min(max(0, caret), text.length)
        var position = caret
        func repeating(_ step: (Int) -> Int) -> Int { for _ in 0..<max(1, count) { position = step(position) }; return position }
        switch motion {
        case .up, .down: return nil
        case .left: let start = lineStart(text, caret); return repeating { max(start, previous(text, $0)) }
        case .right: let end = lineEnd(text, caret); return min(repeating { next(text, $0) }, normalCaret(text, end))
        case .wordForward: return repeating { wordForward(text, $0) }
        case .wordBackward: return repeating { wordBackward(text, $0) }
        case .wordEnd: return repeating { wordEnd(text, $0) }
        case .lineStart: return lineStart(text, caret)
        case .lineFirstNonBlank: return firstNonBlank(text, caret)
        case .lineEnd: return normalCaret(text, lineEnd(text, caret))
        case .documentStart: return 0
        case .documentEnd: return firstNonBlank(text, text.length)
        case .paragraphBackward: return repeating { paragraph(text, $0, forward: false) }
        case .paragraphForward: return repeating { paragraph(text, $0, forward: true) }
        case .innerWord: return caret
        }
    }

    /// Whole lines from `caret` (`count` lines down), with one line break;
    /// the last line of the text takes the break before it instead.
    public static func lineRange(in text: NSString, at caret: Int, count: Int = 1, trailingBreakOnly: Bool = false) -> NSRange {
        var end = lineEnd(text, caret)
        for _ in 1..<max(1, count) where end < text.length { end = lineEnd(text, next(text, end)) }
        let start = lineStart(text, caret)
        if end < text.length { return NSRange(location: start, length: next(text, end) - start) }
        if !trailingBreakOnly, start > 0 { let before = previous(text, start); return NSRange(location: before, length: end - before) }
        return NSRange(location: start, length: end - start)
    }

    /// What an operator covers: a range and whether it works on whole lines.
    public static func range(of motion: TextMotion, in text: NSString, from caret: Int, count: Int = 1) -> (range: NSRange, linewise: Bool) {
        let caret = min(max(0, caret), text.length)
        func span(_ a: Int, _ b: Int) -> NSRange { NSRange(location: min(a, b), length: abs(a - b)) }
        switch motion {
        case .up:
            // No line above: nothing happens, like vim (`dk` must not take this line).
            guard lineStart(text, caret) > 0 else { return (NSRange(location: caret, length: 0), true) }
            var start = caret
            for _ in 0..<max(1, count) where lineStart(text, start) > 0 { start = previous(text, lineStart(text, start)) }
            let first = lineStart(text, start)
            return (linesBetween(text, first, caret), true)
        case .down:
            guard lineEnd(text, caret) < text.length else { return (NSRange(location: caret, length: 0), true) }
            return (lineRange(in: text, at: caret, count: max(1, count) + 1), true)
        case .documentStart: return (linesBetween(text, 0, caret), true)
        case .documentEnd: return (linesBetween(text, caret, text.length), true)
        case .innerWord:
            guard caret < text.length else { return (NSRange(location: caret, length: 0), false) }
            let current = kind(text.character(at: caret))
            var start = caret, end = caret
            while start > 0, !isBreak(text.character(at: start - 1)), kind(text.character(at: start - 1)) == current { start -= 1 }
            while end < text.length, !isBreak(text.character(at: end)), kind(text.character(at: end)) == current { end += 1 }
            return (span(start, end), false)
        case .wordForward:
            // Stays on the line, like vim: `dw` on a line's last word keeps the break.
            let goal = target(motion, in: text, from: caret, count: count) ?? caret
            return (span(caret, min(goal, count > 1 ? goal : max(lineEnd(text, caret), caret))), false)
        case .wordEnd:
            return (span(caret, next(text, target(motion, in: text, from: caret, count: count) ?? caret)), false)
        case .lineEnd: return (span(caret, lineEnd(text, caret)), false)
        case .right: return (span(caret, min(lineEnd(text, caret), repeated(next, text, caret, count))), false)
        default: return (span(caret, target(motion, in: text, from: caret, count: count) ?? caret), false)
        }
    }
    /// The lines from `caret`, without the line break behind the last one.
    public static func lineContent(in text: NSString, at caret: Int, count: Int = 1) -> NSRange {
        let start = lineStart(text, caret)
        var end = lineEnd(text, caret)
        for _ in 1..<max(1, count) where end < text.length { end = lineEnd(text, next(text, end)) }
        return NSRange(location: start, length: end - start)
    }

    /// What `c` replaces, where that is less than `d` deletes: whole lines
    /// stay as an empty line for the new text, and `cw` ends with the word
    /// (vim's exception), its space stays.
    public static func changeRange(of motion: TextMotion, in text: NSString, from caret: Int, count: Int = 1) -> NSRange {
        let found = range(of: motion, in: text, from: caret, count: count)
        guard found.range.length > 0 else { return found.range }
        var first = lineStart(text, caret), last = lineEnd(text, caret)
        switch motion {
        case .down: for _ in 0..<max(1, count) where last < text.length { last = lineEnd(text, next(text, last)) }
        case .up: for _ in 0..<max(1, count) where first > 0 { first = lineStart(text, previous(text, first)) }
        case .documentStart: first = 0
        case .documentEnd: last = text.length
        case .wordForward where caret < text.length && kind(text.character(at: caret)) != .space:
            var end = caret
            for step in 0..<max(1, count) {
                if step > 0 { end = wordForward(text, end) }
                guard end < text.length else { break }
                let word = kind(text.character(at: end))
                while end < text.length, kind(text.character(at: end)) == word { end += 1 }
            }
            return NSRange(location: caret, length: end - caret)
        default: return found.range
        }
        return NSRange(location: first, length: last - first)
    }
    private static func repeated(_ step: (NSString, Int) -> Int, _ text: NSString, _ from: Int, _ count: Int) -> Int {
        var position = from
        for _ in 0..<max(1, count) { position = step(text, position) }
        return position
    }
    private static func linesBetween(_ text: NSString, _ from: Int, _ to: Int) -> NSRange {
        var lines = 1, index = lineEnd(text, from)
        while index < to, index < text.length { lines += 1; index = lineEnd(text, next(text, index)) }
        return lineRange(in: text, at: from, count: lines)
    }

    public struct Edit: Equatable, Sendable {
        public var range: NSRange
        public var replacement: String
        /// Caret afterwards.
        public var caret: Int
        public init(range: NSRange, replacement: String, caret: Int) { self.range = range; self.replacement = replacement; self.caret = caret }
    }

    /// `x` / `X`.
    public static func deleteCharacter(in text: NSString, at caret: Int, before: Bool, count: Int = 1) -> Edit? {
        let start = lineStart(text, caret), end = lineEnd(text, caret)
        if before {
            let from = (0..<max(1, count)).reduce(caret) { position, _ in max(start, previous(text, position)) }
            return from == caret ? nil : Edit(range: NSRange(location: from, length: caret - from), replacement: "", caret: from)
        }
        guard caret < end else { return nil }
        let to = min(end, repeated(next, text, caret, count))
        return Edit(range: NSRange(location: caret, length: to - caret), replacement: "", caret: caret)
    }

    /// `p` / `P`. A register of whole lines goes on its own line, its caret on
    /// the first character of the inserted text; other text beside the caret.
    public static func paste(_ register: String, linewise: Bool, in text: NSString, at caret: Int, before: Bool, count: Int = 1) -> Edit {
        let repeated = String(repeating: register, count: max(1, count))
        if linewise {
            var body = repeated
            if !body.hasSuffix("\n") { body += "\n" }
            if before {
                let start = lineStart(text, caret)
                return Edit(range: NSRange(location: start, length: 0), replacement: body, caret: start)
            }
            let end = lineEnd(text, caret)
            if end < text.length {
                let start = next(text, end)
                return Edit(range: NSRange(location: start, length: 0), replacement: body, caret: start)
            }
            body.removeLast()
            return Edit(range: NSRange(location: end, length: 0), replacement: "\n" + body, caret: end + 1)
        }
        let at = before || caret >= lineEnd(text, caret) ? caret : next(text, caret)
        return Edit(range: NSRange(location: at, length: 0), replacement: repeated, caret: at + max(0, (repeated as NSString).length - 1))
    }

    /// `J`: the line break and the indentation behind it become one space.
    public static func joinLines(in text: NSString, at caret: Int) -> Edit? {
        let end = lineEnd(text, caret)
        guard end < text.length else { return nil }
        var after = next(text, end)
        while after < text.length, [32, 9].contains(text.character(at: after)) { after += 1 }
        let joined = after < text.length && !isBreak(text.character(at: after)) && end > lineStart(text, caret)
        return Edit(range: NSRange(location: end, length: after - end), replacement: joined ? " " : "", caret: end)
    }

    /// The offset and a pending line break of an insert entry.
    public static func insertion(_ entry: TextInsertEntry, in text: NSString, at caret: Int) -> Edit {
        func plain(_ offset: Int) -> Edit { Edit(range: NSRange(location: offset, length: 0), replacement: "", caret: offset) }
        switch entry {
        case .here: return plain(caret)
        case .afterCaret: return plain(min(lineEnd(text, caret), next(text, caret)))
        case .lineStart: return plain(firstNonBlank(text, caret))
        case .lineEnd: return plain(lineEnd(text, caret))
        case .lineBelow:
            let end = lineEnd(text, caret)
            return Edit(range: NSRange(location: end, length: 0), replacement: "\n", caret: end + 1)
        case .lineAbove:
            let start = lineStart(text, caret)
            return Edit(range: NSRange(location: start, length: 0), replacement: "\n", caret: start)
        }
    }
}
