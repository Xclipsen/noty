import Foundation

/// Motions, text objects and search of `TextEngine`, ported from Helix on
/// graphemes: a grapheme counts by its first scalar.
extension TextEngine {
    enum Category: Equatable {
        case lineBreak, whitespace, word, punctuation, other
        var isSpace: Bool { self == .lineBreak || self == .whitespace }
    }

    private static func category(of scalar: UnicodeScalar) -> Category {
        let properties = scalar.properties
        if scalar.value == 95 || properties.isAlphabetic || properties.numericType != nil { return .word }
        if properties.isWhitespace { return .whitespace }
        switch properties.generalCategory {
        case .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation, .initialPunctuation,
             .finalPunctuation, .otherPunctuation, .mathSymbol, .currencySymbol, .modifierSymbol: return .punctuation
        default: return .other
        }
    }
    /// The grapheme starting at `index`.
    func category(at index: Int) -> Category {
        let unit = text.character(at: index)
        if TextMotions.isLineBreak(unit) { return .lineBreak }
        if let scalar = UnicodeScalar(unit) { return Self.category(of: scalar) }
        guard index + 1 < text.length, UTF16.isLeadSurrogate(unit) else { return .other }
        let value = 0x10000 + (UInt32(unit) - 0xD800) << 10 + UInt32(text.character(at: index + 1)) - 0xDC00
        return UnicodeScalar(value).map(Self.category(of:)) ?? .other
    }
    /// Helix's two word kinds: a long word only ends at white space.
    private func isBoundary(_ a: Category, _ b: Category, long: Bool) -> Bool {
        if long, (a == .word && b == .punctuation) || (a == .punctuation && b == .word) { return false }
        return a != b
    }
    func grapheme(at index: Int) -> String {
        guard index < text.length else { return "" }
        return text.substring(with: NSRange(location: index, length: text.nextBoundary(index) - index))
    }

    // MARK: Words

    private func reached(_ motion: WordMotion, _ previous: Category, _ next: Category, long: Bool) -> Bool {
        guard isBoundary(previous, next, long: long) else { return false }
        switch motion {
        case .nextStart: return next == .lineBreak || !next.isSpace
        case .nextEnd, .previousStart: return !previous.isSpace || next == .lineBreak
        }
    }

    /// One word step (`range_to_target`).
    private func wordStep(_ motion: WordMotion, long: Bool, from origin: Selection) -> Selection {
        let backward = motion == .previousStart
        var anchor = origin.anchor, head = origin.head
        func peek(_ index: Int) -> Category? {
            if backward { return index > 0 ? category(at: text.previousBoundary(index)) : nil }
            return index < text.length ? category(at: index) : nil
        }
        func advance(_ index: Int) -> Int { backward ? text.previousBoundary(index) : text.nextBoundary(index) }
        var previous: Category? = backward ? (head < text.length ? category(at: head) : nil)
                                           : (head > 0 ? category(at: text.previousBoundary(head)) : nil)
        while let next = peek(head), next == .lineBreak { previous = next; head = advance(head) }
        if previous == .lineBreak { anchor = head }
        let start = head
        while let next = peek(head) {
            if previous == nil || reached(motion, previous!, next, long: long) {
                if head == start { anchor = head } else { break }
            }
            previous = next
            head = advance(head)
        }
        return Selection(anchor: anchor, head: head)
    }

    func moveWord(_ range: Selection, _ motion: WordMotion, long: Bool, count: Int, extend: Bool) -> Selection {
        let backward = motion == .previousStart
        if (backward && range.head == 0) || (!backward && range.head == text.length) { return range }
        var current: Selection
        if backward {
            current = range.anchor < range.head ? Selection(anchor: range.head, head: text.previousBoundary(range.head))
                                                : Selection(anchor: text.nextBoundary(range.head), head: range.head)
        } else {
            current = range.anchor < range.head ? Selection(anchor: text.previousBoundary(range.head), head: range.head)
                                                : Selection(anchor: range.head, head: text.nextBoundary(range.head))
        }
        for _ in 0..<count {
            let next = wordStep(motion, long: long, from: current)
            if next == current { break }
            current = next
        }
        guard extend else { return current }
        return put(range, blockCursor(of: current), extend: true)
    }
    /// `cursor(of:)` regardless of the mode.
    private func blockCursor(of range: Selection) -> Int { range.head > range.anchor ? text.previousBoundary(range.head) : range.head }

    // MARK: Find

    private func nextOccurrence(_ character: String, from start: Int, count: Int) -> Int? {
        guard start < text.length, count > 0 else { return nil }
        var position = start, found = 0
        while position < text.length {
            if grapheme(at: position) == character { found += 1; if found == count { return position } }
            position = text.nextBoundary(position)
        }
        return nil
    }
    private func previousOccurrence(_ character: String, from start: Int, count: Int) -> Int? {
        guard start > 0, count > 0 else { return nil }
        var position = start, found = 0
        while position > 0 {
            position = text.previousBoundary(position)
            if grapheme(at: position) == character { found += 1; if found == count { return position } }
        }
        return nil
    }

    func find(_ range: Selection, _ character: String, forward: Bool, inclusive: Bool, count: Int, extend: Bool) -> Selection {
        let origin = blockCursor(of: range)
        var target: Int?
        if forward {
            let start = text.nextBoundary(origin)
            if inclusive { target = nextOccurrence(character, from: start, count: count) }
            else {
                // `t` directly before the character goes on to the next one.
                let wanted = grapheme(at: start) == character ? count + 1 : count
                target = nextOccurrence(character, from: start, count: wanted).map(text.previousBoundary)
            }
        } else if inclusive {
            target = previousOccurrence(character, from: origin, count: count)
        } else {
            let wanted = grapheme(at: text.previousBoundary(origin)) == character ? count + 1 : count
            target = previousOccurrence(character, from: origin, count: wanted).map(text.nextBoundary)
        }
        guard let target else { return range }
        return extend ? put(range, target, extend: true) : put(.point(origin), target, extend: true)
    }

    // MARK: Pairs

    static let brackets: [(open: String, close: String)] = [("(", ")"), ("{", "}"), ("[", "]"), ("<", ">"), ("‘", "’"), ("“", "”"), ("«", "»"), ("「", "」"), ("（", "）")]
    static let pairs = brackets + [("\"", "\""), ("'", "'"), ("`", "`")]
    /// An unknown character is its own pair: `ms*` gives `*…*`.
    static func pair(for character: String) -> (open: String, close: String) {
        pairs.first { $0.open == character || $0.close == character } ?? (character, character)
    }

    /// `mm`: only from a bracket; quotes have no direction.
    func matchingBracket(_ position: Int) -> Int? {
        let bracket = grapheme(at: position)
        guard let pair = Self.brackets.first(where: { $0.open == bracket || $0.close == bracket }) else { return nil }
        let forward = pair.open == bracket, partner = forward ? pair.close : pair.open
        var index = position, open = 1
        while forward ? text.nextBoundary(index) < text.length : index > 0 {
            index = forward ? text.nextBoundary(index) : text.previousBoundary(index)
            let candidate = grapheme(at: index)
            if candidate == bracket { open += 1 } else if candidate == partner {
                open -= 1
                if open == 0 { return index }
            }
        }
        return nil
    }

    private func openingPair(_ open: String, _ close: String, from start: Int, count: Int) -> Int? {
        guard start < text.length else { return nil }
        if grapheme(at: start) == open { return start }
        var position = start
        for _ in 0..<count {
            var nested = 0
            while true {
                guard position > 0 else { return nil }
                position = text.previousBoundary(position)
                let character = grapheme(at: position)
                if character == close { nested += 1 } else if character == open {
                    if nested == 0 { break }
                    nested -= 1
                }
            }
        }
        return position
    }
    private func closingPair(_ open: String, _ close: String, from start: Int, count: Int) -> Int? {
        guard start < text.length else { return nil }
        if grapheme(at: start) == close { return start }
        var position = start
        for _ in 0..<count {
            var nested = 0
            while true {
                position = text.nextBoundary(position)
                guard position < text.length else { return nil }
                let character = grapheme(at: position)
                if character == open { nested += 1 } else if character == close {
                    if nested == 0 { break }
                    nested -= 1
                }
            }
        }
        return position
    }

    private func closestPair(around range: Selection, count: Int) -> (open: Int, close: Int)? {
        var stack: [String] = [], skip = count, position = range.from
        let reach = (open: text.nextBoundary(range.from), close: text.previousBoundary(range.to))
        while position < text.length {
            let character = grapheme(at: position)
            if Self.brackets.contains(where: { $0.open == character }) { stack.append(character) }
            else if let pair = Self.brackets.first(where: { $0.close == character }) {
                if stack.last == pair.open { stack.removeLast() }
                // The pair has to enclose the selection, not only its first character.
                else if let open = openingPair(pair.open, pair.close, from: position, count: 1), open <= reach.open, position >= reach.close {
                    skip -= 1
                    if skip == 0 { return (open, position) }
                }
            }
            position = text.nextBoundary(position)
        }
        return nil
    }

    /// The pair around a selection. nil `character`: the nearest bracket pair.
    func surroundingPair(_ character: String?, around range: Selection, count: Int) -> (open: Int, close: Int)? {
        guard let character else { return closestPair(around: range, count: count) }
        guard text.length >= 2 else { return nil }
        let pair = Self.pair(for: character), position = blockCursor(of: range)
        if pair.open == pair.close {
            // On the quote itself nobody can tell which side is meant.
            guard grapheme(at: position) != pair.open else { return nil }
            guard let open = previousOccurrence(pair.open, from: position, count: count),
                  let close = nextOccurrence(pair.close, from: position, count: count) else { return nil }
            return (open, close)
        }
        guard let open = openingPair(pair.open, pair.close, from: position, count: count),
              let close = closingPair(pair.open, pair.close, from: position, count: count) else { return nil }
        return (open, close)
    }

    // MARK: Text objects

    private func wordBoundary(_ start: Int, forward: Bool, long: Bool) -> Int {
        var position = start
        var previous: Category
        if forward { previous = position == 0 ? .whitespace : category(at: text.previousBoundary(position)) }
        else { previous = position == text.length ? .whitespace : category(at: position) }
        while forward ? position < text.length : position > 0 {
            let current = category(at: forward ? position : text.previousBoundary(position))
            if current.isSpace { return position }
            if !long, current != previous, position != 0, position != text.length { return position }
            position = forward ? text.nextBoundary(position) : text.previousBoundary(position)
            previous = current
        }
        return position
    }

    private func wordObject(_ range: Selection, around: Bool, long: Bool) -> Selection {
        let position = blockCursor(of: range)
        let start = wordBoundary(position, forward: false, long: long)
        let onWord = position < text.length && !category(at: position).isSpace
        let end = onWord ? wordBoundary(text.nextBoundary(position), forward: true, long: long) : position
        guard start != end else { return .point(start) }
        guard around else { return Selection(anchor: start, head: end) }
        var right = end
        while right < text.length, category(at: right) == .whitespace { right = text.nextBoundary(right) }
        if right > end { return Selection(anchor: start, head: right) }
        var left = start
        while left > 0, category(at: text.previousBoundary(left)) == .whitespace { left = text.previousBoundary(left) }
        return Selection(anchor: left, head: end)
    }

    private func paragraphObject(_ range: Selection, around: Bool, count: Int) -> Selection {
        let starts = lineStarts, position = blockCursor(of: range)
        func offset(_ line: Int) -> Int { line < starts.count ? starts[line] : text.length }
        func blank(_ line: Int) -> Bool { line < starts.count && TextMotions.lineEnd(text, starts[line]) == starts[line] }
        var line = starts.lastIndex { $0 <= position } ?? 0
        // Helix reads the line above for the "next" line, too.
        let previousBlank = blank(max(0, line - 1)), currentBlank = blank(line), nextBlank = previousBlank
        let onLastCharacter = text.previousBoundary(offset(line + 1)) == position
        func walkBack(_ line: inout Int) {
            while line > 0, blank(line - 1) { line -= 1 }
            while line > 0, !blank(line - 1) { line -= 1 }
        }
        var back = line
        if (previousBlank && !currentBlank) || (currentBlank && !nextBlank) { back += 1 }
        let onParagraphEnd = currentBlank && !nextBlank && onLastCharacter
        if !onParagraphEnd { walkBack(&back) }
        if onParagraphEnd { line += 1 }
        var done = 0
        for _ in 0..<count {
            var moved = false
            while line < starts.count, !blank(line) { line += 1; moved = true }
            while line < starts.count, blank(line) { line += 1 }
            if moved { done += 1 }
        }
        // At the end of the text the paragraph before counts instead of a missing one.
        if done != count, line >= starts.count { walkBack(&back) }
        if !around { while line > 0, blank(line - 1) { line -= 1 } }
        return Selection(anchor: offset(back), head: offset(line))
    }

    func select(_ object: TextObject, around: Bool, _ range: Selection, count: Int) -> Selection {
        switch object {
        case .word: return wordObject(range, around: around, long: false)
        case .longWord: return wordObject(range, around: around, long: true)
        case .paragraph: return paragraphObject(range, around: around, count: count)
        case .pair, .closestPair:
            var character: String?
            if case .pair(let value) = object { character = value }
            guard let found = surroundingPair(character, around: range, count: count) else { return range }
            let inner = around ? Selection(anchor: found.open, head: text.nextBoundary(found.close))
                               : Selection(anchor: text.nextBoundary(found.open), head: found.close)
            return inner.directed(backward: range.isBackward)
        }
    }

    // MARK: Search

    /// As Helix: line anchors, and lower case ignores case (smart case). What
    /// is no valid expression counts literally: notes hold stray brackets.
    private func expression(_ pattern: String) -> NSRegularExpression? {
        var options: NSRegularExpression.Options = [.anchorsMatchLines]
        if !pattern.contains(where: \.isUppercase) { options.insert(.caseInsensitive) }
        return (try? NSRegularExpression(pattern: pattern, options: options))
            ?? (try? NSRegularExpression(pattern: NSRegularExpression.escapedPattern(for: pattern), options: options))
    }
    func matches(_ pattern: String, in range: NSRange) -> [Selection] {
        guard let expression = expression(pattern) else { return [] }
        return expression.matches(in: string, options: [.withTransparentBounds, .withoutAnchoringBounds], range: range)
            .map { Selection(anchor: $0.range.location, head: NSMaxRange($0.range)) }
    }

    /// `n`/`N`: the next match behind the primary selection, around the end if
    /// there is none. In select mode it joins the selections.
    mutating func step(_ pattern: String, backward: Bool, count: Int, extend: Bool) -> Notice? {
        var notice: Notice?
        for _ in 0..<count {
            let current = primary
            let start = backward ? current.from : current.to
            var found = backward ? matches(pattern, in: NSRange(location: 0, length: start)).last
                                 : matches(pattern, in: NSRange(location: start, length: text.length - start)).first
            if found == nil {
                found = backward ? matches(pattern, in: NSRange(location: start, length: text.length - start)).last
                                 : matches(pattern, in: NSRange(location: 0, length: text.length)).first
                notice = found == nil ? .noMatch : .wrapped
            }
            guard let found, found.to > 0 else { break }
            setPrimary(found.directed(backward: current.isBackward), adding: extend)
        }
        return notice
    }

    /// `*`: the selections as a pattern, with word bounds where they stand on some.
    func selectionPattern() -> String {
        func isWord(_ index: Int) -> Bool { category(at: index) == .word }
        func atStart(_ index: Int) -> Bool {
            guard index < text.length else { return false }
            return index == 0 ? isWord(index) : !isWord(text.previousBoundary(index)) && isWord(index)
        }
        func atEnd(_ index: Int) -> Bool {
            guard index > 0, index < text.length else { return false }
            return isWord(text.previousBoundary(index)) && !isWord(index)
        }
        var seen = Set<String>()
        let parts = selections.compactMap { range -> String? in
            let body = NSRegularExpression.escapedPattern(for: text.substring(with: range.range))
            let part = (atStart(range.from) ? "\\b" : "") + body + (atEnd(range.to) ? "\\b" : "")
            return seen.insert(part).inserted ? part : nil
        }
        return parts.joined(separator: "|")
    }
}
