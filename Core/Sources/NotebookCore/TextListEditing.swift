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
            let range = source.lineRange(for: NSRange(location: line.location, length: 0))
            var end = NSMaxRange(range)
            while end > line.location && [10, 13].contains(source.character(at: end - 1)) { end -= 1 }
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
    public static func newline(in text: String, range: NSRange) -> Edit? {
        let source = text as NSString
        guard range.location >= 0, range.length >= 0, range.location <= source.length, range.length <= source.length - range.location else { return nil }
        let line = source.lineRange(for: NSRange(location: range.location, length: 0))
        let before = source.substring(with: NSRange(location: line.location, length: range.location - line.location))
        let indent = String(before.prefix { $0 == " " || $0 == "\t" })
        guard let prefix = prefix(String(before.dropFirst(indent.count))) else { return nil }
        let content = String(before.dropFirst(indent.count + prefix.count))
        if content.trimmingCharacters(in: .whitespaces).isEmpty {
            return Edit(range: NSRange(location: line.location, length: range.location + range.length - line.location), replacement: "")
        }
        let next: String
        if prefix == "☑ " || prefix == "☐ " { next = "☐ " }
        else if let number = Int(prefix.dropLast(2)), number < 999_999 { next = "\(number + 1). " }
        else { next = prefix }
        return Edit(range: range, replacement: "\n" + indent + next)
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
        let lines = listLines(for: kind, in: text, range: range, level: level)
        let remove = !lines.isEmpty && lines.allSatisfy { matches(kind, $0.prefix) }
        let check = kind == .checkbox && remove && lines.contains { $0.prefix == "☐ " }
        return lines.enumerated().map { index, line in
            let value: String
            if check { value = "☑ " }
            else if remove { value = "" }
            else { value = switch kind { case .bullet: bullet(forLevel: level?(lineStart(text, line.location)) ?? 0); case .checkbox: "☐ "; case .numbered: "\(index + 1). " } }
            return Edit(range: NSRange(location: line.location, length: (line.prefix as NSString).length), replacement: value)
        }
    }
    public static func isActive(_ kind: Kind, in text: String, range: NSRange) -> Bool {
        let lines = selectedLines(in: text, range: range)
        return !lines.isEmpty && lines.allSatisfy { matches(kind, $0.prefix) }
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
            let start = source.lineRange(for: NSRange(location: line.location, length: 0)).location
            return source.substring(with: NSRange(location: start, length: line.location - start))
        }
        let indent = indentation(current), depth = level?(lineStart(text, current.location))
        func belongs(_ index: Int) -> Bool {
            matches(oldKind, all[index].prefix) && indentation(all[index]) == indent
                && level?(lineStart(text, all[index].location)) == depth
        }
        var first = index, last = index
        while first > 0 && belongs(first - 1) { first -= 1 }
        while last + 1 < all.count && belongs(last + 1) { last += 1 }
        return Array(all[first...last])
    }
    static func selectedLines(in text: String, range: NSRange) -> [(location: Int, prefix: String)] {
        let source = text as NSString
        guard range.location >= 0, range.length >= 0, range.location <= source.length,
              range.length <= source.length - range.location else { return [] }
        let selected = source.lineRange(for: NSRange(location: range.location, length: max(0, range.length - 1)))
        var cursor = selected.location, result: [(Int, String)] = []
        repeat {
            let line = source.lineRange(for: NSRange(location: cursor, length: 0))
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
