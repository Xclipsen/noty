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
        if TextLines.isBreak(unit) { return .lineBreak }
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

    // MARK: Paragraphs

    /// `]p`, `[p` (`move_next_paragraph`, `move_prev_paragraph`): only lines
    /// without any character separate, white space counts as text.
    func moveParagraph(_ range: Selection, forward: Bool, count: Int, extend: Bool) -> Selection {
        let starts = lineStarts, position = blockCursor(of: range)
        func offset(_ line: Int) -> Int { line < starts.count ? starts[line] : text.length }
        func blank(_ line: Int) -> Bool { line < starts.count && TextLines.end(text, starts[line]) == starts[line] }
        var line = starts.lastIndex { $0 <= position } ?? 0
        let skips: Bool, atEdge: Bool
        if forward {
            atEdge = text.previousBoundary(offset(line + 1)) == position
            skips = blank(line) && !blank(min(starts.count - 1, line + 1))
        } else {
            atEdge = starts[line] == position
            skips = blank(max(0, line - 1)) && !blank(line)
        }
        // Past the character at the paragraph's edge.
        if skips, forward ? atEdge : !atEdge { line += 1 }
        var previous = line
        for _ in 0..<count {
            if forward {
                while line < starts.count, !blank(line) { line += 1 }
                while line < starts.count, blank(line) { line += 1 }
            } else {
                while line > 0, blank(line - 1) { line -= 1 }
                while line > 0, !blank(line - 1) { line -= 1 }
            }
            if line == previous { break }
            previous = line
        }
        let head = offset(line)
        if extend { return Selection(anchor: put(range, head, extend: true).anchor, head: head) }
        let fromHead = forward ? skips && atEdge : !(skips && atEdge)
        return Selection(anchor: fromHead ? range.head : position, head: head)
    }

    // MARK: Find

    /// `f<CR>` means every line break, also the CRLF of pasted Windows text (one grapheme).
    private func isCharacter(_ grapheme: String, _ character: String) -> Bool {
        grapheme == character || (character == "\n" && grapheme == "\r\n")
    }
    private func nextOccurrence(_ character: String, from start: Int, count: Int) -> Int? {
        guard start < text.length, count > 0 else { return nil }
        var position = start, found = 0
        while position < text.length {
            if isCharacter(grapheme(at: position), character) { found += 1; if found == count { return position } }
            position = text.nextBoundary(position)
        }
        return nil
    }
    private func previousOccurrence(_ character: String, from start: Int, count: Int) -> Int? {
        guard start > 0, count > 0 else { return nil }
        var position = start, found = 0
        while position > 0 {
            position = text.previousBoundary(position)
            if isCharacter(grapheme(at: position), character) { found += 1; if found == count { return position } }
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
                let wanted = isCharacter(grapheme(at: start), character) ? count + 1 : count
                target = nextOccurrence(character, from: start, count: wanted).map(text.previousBoundary)
            }
        } else if inclusive {
            target = previousOccurrence(character, from: origin, count: count)
        } else {
            let wanted = isCharacter(grapheme(at: text.previousBoundary(origin)), character) ? count + 1 : count
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

    /// One pass from the start of the text: `partners` keeps the open brackets
    /// of each kind that are still waiting, the same partner `openingPair`
    /// finds going back, without going back for every closing bracket
    /// (a list of „1)“ items has many without a partner).
    private func closestPair(around range: Selection, count: Int) -> (open: Int, close: Int)? {
        var stack: [String] = [], skip = count, position = 0
        var partners = [[Int]](repeating: [], count: Self.brackets.count)
        let reach = (open: text.nextBoundary(range.from), close: text.previousBoundary(range.to))
        while position < text.length {
            let character = grapheme(at: position), inside = position >= range.from
            if let kind = Self.brackets.firstIndex(where: { $0.open == character }) {
                partners[kind].append(position)
                if inside { stack.append(character) }
            } else if let kind = Self.brackets.firstIndex(where: { $0.close == character }) {
                let open = partners[kind].popLast()
                if inside {
                    if stack.last == Self.brackets[kind].open { stack.removeLast() }
                    // The pair has to enclose the selection, not only its first character.
                    else if let open, open <= reach.open, position >= reach.close {
                        skip -= 1
                        if skip == 0 { return (open, position) }
                    }
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
        func blank(_ line: Int) -> Bool { line < starts.count && TextLines.end(text, starts[line]) == starts[line] }
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
    fileprivate func expression(_ pattern: String) -> NSRegularExpression? {
        var options: NSRegularExpression.Options = [.anchorsMatchLines]
        if !pattern.contains(where: \.isUppercase) { options.insert(.caseInsensitive) }
        return (try? NSRegularExpression(pattern: pattern, options: options))
            ?? (try? NSRegularExpression(pattern: NSRegularExpression.escapedPattern(for: pattern), options: options))
    }
    func matches(_ pattern: String, in range: NSRange) -> [Selection] {
        Search(pattern, in: self)?.matches(in: range) ?? []
    }

    /// One search over the text as it stands: the expression and the text it
    /// reads are made once. Each regular expression call reads the whole
    /// text again, so a count (`9999n`) takes the places from one list of all
    /// matches. That list gives what a search from `start` gives, except
    /// where one of its matches reaches over `start`: a search from there
    /// may find a match inside it, so only there it searches again.
    struct Search {
        let expression: NSRegularExpression
        let subject: String
        let length: Int
        /// One call per step as before (`n` once): no list needed.
        let single: Bool
        private static let options: NSRegularExpression.MatchingOptions = [.withTransparentBounds, .withoutAnchoringBounds]
        private var list: [Selection]?

        init?(_ pattern: String, in engine: TextEngine, single: Bool = false) {
            guard let expression = engine.expression(pattern) else { return nil }
            self.expression = expression
            // A phrase reads on over a page break as over a space; the offsets stay.
            subject = engine.string.replacingOccurrences(of: TextLines.pageBreakText, with: " ")
            length = engine.text.length
            self.single = single
        }
        func matches(in range: NSRange) -> [Selection] {
            expression.matches(in: subject, options: Self.options, range: range)
                .map { Selection(anchor: $0.range.location, head: NSMaxRange($0.range)) }
        }
        private func first(in range: NSRange) -> Selection? {
            expression.firstMatch(in: subject, options: Self.options, range: range)
                .map { Selection(anchor: $0.range.location, head: NSMaxRange($0.range)) }
        }
        private func behind(_ start: Int) -> NSRange { NSRange(location: start, length: length - start) }

        /// All matches and the index of the first one starting at `offset`
        /// or later; nil if a match runs over `offset` (then: search again).
        private mutating func place(_ offset: Int) -> (all: [Selection], index: Int)? {
            if list == nil { list = matches(in: NSRange(location: 0, length: length)) }
            let all = list!
            var low = 0, high = all.count
            while low < high {
                let middle = (low + high) / 2
                if all[middle].from < offset { low = middle + 1 } else { high = middle }
            }
            if low > 0, all[low - 1].to > offset { return nil }
            return (all, low)
        }
        /// The first match behind `start`.
        mutating func next(from start: Int) -> Selection? {
            guard !single, let (all, index) = place(start) else { return first(in: behind(start)) }
            return index < all.count ? all[index] : nil
        }
        /// From the start of the text, the way `next` goes round.
        mutating func first() -> Selection? {
            guard !single else { return first(in: behind(0)) }
            if list == nil { list = matches(in: behind(0)) }
            return list!.first
        }
        /// The last match that ends at `start` or in front of it.
        mutating func previous(before start: Int) -> Selection? {
            // Right at `start` a search up to there may still find an empty match where the list has a longer one.
            guard !single, let (all, index) = place(start), index == all.count || all[index].from > start || all[index].to == start else {
                return matches(in: NSRange(location: 0, length: start)).last
            }
            // Behind `index` all start at `start` or later; an empty one there still ends there.
            var last = index
            while last < all.count, all[last].to <= start { last += 1 }
            return last > 0 ? all[last - 1] : nil
        }
        /// The last match behind `start`, the way `previous` goes round.
        mutating func last(from start: Int) -> Selection? {
            guard !single, let (all, index) = place(start) else { return matches(in: behind(start)).last }
            return index < all.count ? all.last : nil
        }
    }

    /// `n`/`N`: the next match behind the primary selection, around the end if
    /// there is none. In select mode it joins the selections. A count runs
    /// round after round only until the places repeat.
    mutating func step(_ pattern: String, backward: Bool, count: Int, extend: Bool) -> Notice? {
        guard var search = Search(pattern, in: self, single: count == 1) else { return .noMatch }
        var notice: Notice?, remaining = count, index = 0
        var seen: [[Int]: Int]? = [:]
        while remaining > 0 {
            let current = primary
            let start = backward ? current.from : current.to
            var found = backward ? search.previous(before: start) : search.next(from: start)
            if found == nil {
                found = backward ? search.last(from: start) : search.first()
                notice = found == nil ? .noMatch : .wrapped
            }
            guard let found, found.to > 0 else { break }
            setPrimary(found.directed(backward: current.isBackward), adding: extend)
            remaining -= 1
            // The same place with the same selections again: the next rounds only repeat.
            let covered = selections.reduce(0) { $0 + $1.to - $1.from }
            let state = [primary.anchor, primary.head, selections.count, covered]
            if remaining > 0, let earlier = seen?[state] {
                remaining %= index - earlier
                seen = nil
            } else { seen?[state] = index }
            index += 1
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
            // The search reads a page break as a space (`Search`).
            let body = NSRegularExpression.escapedPattern(for: text.substring(with: range.range)
                .replacingOccurrences(of: TextLines.pageBreakText, with: " "))
            let part = (atStart(range.from) ? "\\b" : "") + body + (atEnd(range.to) ? "\\b" : "")
            return seen.insert(part).inserted ? part : nil
        }
        return parts.joined(separator: "|")
    }
}
