import Foundation

/// UTF-16 ranges match UITextView, including emoji and composed characters.
public enum TextListEditing {
    public struct TaskItem: Equatable, Sendable {
        public let marker: NSRange
        public let body: NSRange
        public let checked: Bool
    }
    /// Semantic prefixes remain backward compatible; all renderers draw circles.
    public static func taskItems(in text: String) -> [TaskItem] {
        let source = text as NSString
        return selectedLines(in: text, range: NSRange(location: 0, length: source.length)).compactMap { line in
            guard matches(.checkbox, line.prefix) else { return nil }
            let range = TextLines.lineRange(source, NSRange(location: line.location, length: 0))
            var end = NSMaxRange(range)
            while end > line.location && TextLines.isBreak(source.character(at: end - 1)) { end -= 1 }
            let start = line.location + (line.prefix as NSString).length
            return TaskItem(marker: NSRange(location: line.location, length: 1),
                body: NSRange(location: start, length: max(0, end - start)), checked: line.prefix == "☑ ")
        }
    }
    public struct Edit: Equatable, Sendable {
        public var range: NSRange
        public var replacement: String
        public init(range: NSRange, replacement: String) { self.range = range; self.replacement = replacement }
    }
    public static func checkbox(in text: String, range: NSRange) -> Edit? {
        let source = text as NSString
        guard range.location >= 0, range.length >= 0, range.location <= source.length, range.length <= source.length - range.location else { return nil }
        guard let selected = selectedLines(in: text, range: NSRange(location: range.location, length: 0)).first else { return nil }
        let value = selected.prefix
        guard value.hasPrefix("☐ ") || value.hasPrefix("☑ ") else { return nil }
        return Edit(range: NSRange(location: selected.location, length: 1), replacement: value.hasPrefix("☐") ? "☑" : "☐")
    }
    public enum Kind: Sendable { case bullet, numbered, checkbox }

    /// Prefix-only edits keep the attributed text of the actual words intact.
    /// Tasks cycle absent → open → checked → absent; other lists toggle.
    public static func toggle(_ kind: Kind, in text: String, range: NSRange, level: ((Int) -> Int)? = nil) -> [Edit] {
        let lines = withoutBlankLines(listLines(for: kind, in: text, range: range, level: level), in: text)
        let remove = !lines.isEmpty && lines.allSatisfy { matches(kind, $0.prefix) }
        let check = kind == .checkbox && remove && lines.contains { $0.prefix == "☐ " }
        let numbers = kind == .numbered && !remove ? numbering(lines.map(\.location), in: text, level: level) : [:]
        return lines.enumerated().map { index, line in
            let value: String
            if check { value = "☑ " }
            else if remove { value = "" }
            else { value = switch kind {
                case .bullet: bullet(forLevel: depth(text, line.location, level))
                case .checkbox: "☐ "
                case .numbered: "\(numbers[line.location] ?? index + 1). "
            } }
            return Edit(range: NSRange(location: line.location, length: (line.prefix as NSString).length), replacement: value)
        }
    }
    /// The numbers of the lines that become numbered items (their marks at
    /// `locations`) by the one list rule (`walk`, as `normalize` counts
    /// afterwards): per level, on over one blank line between items, from 1
    /// after two blank lines or a normal paragraph, on from a list right above.
    private static func numbering(_ locations: [Int], in text: String, level: ((Int) -> Int)?) -> [Int: Int] {
        let targets = Set(locations)
        var list = paragraphs(in: text, level: level ?? { _ in 0 }, continuation: false), changed = Set<Int>()
        for index in list.indices where targets.contains(list[index].prefixLocation) {
            list[index].kind = .numbered; list[index].number = 1; list[index].empty = false; changed.insert(index)
        }
        let state = walk(list, context: ListContext(), touched: { _ in false }) { index, item in
            changed.contains(index) ? 1 : item.number ?? 1
        }
        var result: [Int: Int] = [:]
        for run in state.runs { for (index, number) in run.items where changed.contains(index) { result[list[index].prefixLocation] = number } }
        return result
    }
    /// The level of the list line whose mark is at `location`: the older
    /// indent level (`level`) plus the tabs in front of the mark.
    private static func depth(_ text: String, _ location: Int, _ level: ((Int) -> Int)?) -> Int {
        let source = text as NSString, start = lineStart(text, location)
        var tabs = 0
        for index in start..<min(location, source.length) where source.character(at: index) == 9 { tabs += 1 }
        return (level?(start) ?? 0) + tabs
    }
    public static func isActive(_ kind: Kind, in text: String, range: NSRange) -> Bool {
        let lines = withoutBlankLines(selectedLines(in: text, range: range), in: text)
        return !lines.isEmpty && lines.allSatisfy { matches(kind, $0.prefix) }
    }
    /// Empty lines of a selection stay empty and do not count, a list over
    /// them goes on numbering; a caret on an empty line still gets a marker.
    private static func withoutBlankLines(_ lines: [(location: Int, prefix: String)], in text: String) -> [(location: Int, prefix: String)] {
        let source = text as NSString
        let filled = lines.filter { !$0.prefix.isEmpty || ($0.location < source.length && !TextLines.isBreak(source.character(at: $0.location))) }
        return filled.isEmpty ? lines : filled
    }
    public static func selection(_ selection: NSRange, after edits: [Edit]) -> NSRange {
        func mapped(_ location: Int) -> Int {
            var delta = 0
            for edit in edits.sorted(by: { $0.range.location < $1.range.location }) {
                if location < edit.range.location { break }
                let count = (edit.replacement as NSString).length
                if location <= NSMaxRange(edit.range) { return edit.range.location + delta + count }
                delta += count - edit.range.length
            }
            return location + delta
        }
        let start = mapped(selection.location), end = mapped(NSMaxRange(selection))
        return NSRange(location: start, length: max(0, end - start))
    }
    static func matches(_ kind: Kind, _ prefix: String) -> Bool {
        switch kind {
        case .bullet: prefix == "• " || prefix == "- " || prefix == "◦ " || prefix == "▪ "
        case .checkbox: prefix == "☐ " || prefix == "☑ "
        case .numbered: Int(prefix.dropLast(2)) != nil && prefix.hasSuffix(". ")
        }
    }
    /// Changing a list's kind at a caret affects its connected entries. Explicit
    /// selections and toggling the current kind retain their local scope.
    private static func listLines(for kind: Kind, in text: String, range: NSRange, level: ((Int) -> Int)? = nil) -> [(location: Int, prefix: String)] {
        let selected = selectedLines(in: text, range: range)
        guard range.length == 0, let current = selected.first,
              let oldKind = [Kind.checkbox, .bullet, .numbered].first(where: { matches($0, current.prefix) }),
              oldKind != kind else { return selected }
        let source = text as NSString
        let all = selectedLines(in: text, range: NSRange(location: 0, length: source.length))
        guard let index = all.firstIndex(where: { $0.location == current.location }) else { return selected }
        func indentation(_ line: (location: Int, prefix: String)) -> String {
            let start = TextLines.lineRange(source, NSRange(location: line.location, length: 0)).location
            return source.substring(with: NSRange(location: start, length: line.location - start))
        }
        let indent = indentation(current), depth = level?(lineStart(text, current.location))
        func belongs(_ index: Int) -> Bool {
            matches(oldKind, all[index].prefix) && indentation(all[index]) == indent
                && level?(lineStart(text, all[index].location)) == depth
        }
        // One blank line between two entries keeps them connected, as the numbering (`walk`).
        func blank(_ index: Int) -> Bool {
            all[index].prefix.isEmpty && (all[index].location >= source.length || TextLines.isBreak(source.character(at: all[index].location)))
        }
        var first = index, last = index
        while true {
            if first > 0, belongs(first - 1) { first -= 1 }
            else if first > 1, blank(first - 1), belongs(first - 2) { first -= 2 }
            else { break }
        }
        while true {
            if last + 1 < all.count, belongs(last + 1) { last += 1 }
            else if last + 2 < all.count, blank(last + 1), belongs(last + 2) { last += 2 }
            else { break }
        }
        return Array(all[first...last])
    }
    static func selectedLines(in text: String, range: NSRange) -> [(location: Int, prefix: String)] {
        let source = text as NSString
        guard range.location >= 0, range.length >= 0, range.location <= source.length,
              range.length <= source.length - range.location else { return [] }
        // The lines of every selected character: a selection ending right behind a break stays in front of the next line.
        let selected = TextLines.lineRange(source, range)
        var cursor = selected.location, result: [(Int, String)] = []
        repeat {
            let line = TextLines.lineRange(source, NSRange(location: cursor, length: 0))
            let value = source.substring(with: line)
            let indent = value.prefix { $0 == " " || $0 == "\t" }
            let start = cursor + (String(indent) as NSString).length
            result.append((start, prefix(String(value.dropFirst(indent.count))) ?? ""))
            let next = NSMaxRange(line)
            if next <= cursor { break }
            cursor = next
        } while cursor < NSMaxRange(selected)
        return result
    }
    static func prefix(_ line: String) -> String? {
        for value in ["• ", "- ", "◦ ", "▪ ", "☐ ", "☑ "] where line.hasPrefix(value) { return value }
        let digits = line.prefix { $0.isASCII && $0.isNumber }
        if !digits.isEmpty, digits.count <= 6, line.dropFirst(digits.count).hasPrefix(". ") { return digits + ". " }
        return nil
    }
}
