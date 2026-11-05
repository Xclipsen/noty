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
    /// Return in a paragraph with a marker (list, arrow, „a)“, „(1)“ …): the
    /// next line gets the same indentation and the next marker. On an empty
    /// item it moves out one step of its leading white space, without any it
    /// ends the item (`TextParagraphPrefix`). nil: no marker in front of the caret.
    public static func newline(in text: String, range: NSRange) -> Edit? {
        let source = text as NSString
        guard range.location >= 0, range.length >= 0, range.location <= source.length, range.length <= source.length - range.location else { return nil }
        let line = TextLines.lineRange(source, NSRange(location: range.location, length: 0))
        let before = source.substring(with: NSRange(location: line.location, length: range.location - line.location))
        guard let item = TextParagraphPrefix(line: before), item.marker != nil else { return nil }
        let content = (before as NSString).substring(from: item.length)
        var end = NSMaxRange(range)
        while end < source.length, !TextLines.isBreak(source.character(at: end)) { end += 1 }
        let rest = source.substring(with: NSRange(location: NSMaxRange(range), length: end - NSMaxRange(range)))
        // An empty item ends the list; with text behind the caret it is a normal split.
        if content.trimmingCharacters(in: .whitespaces).isEmpty, rest.trimmingCharacters(in: .whitespaces).isEmpty {
            if let step = item.outdentStep {
                // One step out, the marker stays: replaced up to the caret, which stays behind it.
                let start = line.location + step.location
                return Edit(range: NSRange(location: start, length: NSMaxRange(range) - start),
                            replacement: (before as NSString).substring(from: NSMaxRange(step)))
            }
            return Edit(range: NSRange(location: line.location, length: range.location + range.length - line.location), replacement: "")
        }
        return Edit(range: range, replacement: "\n" + item.indent + (item.nextMarker.map { $0 + item.separator } ?? ""))
    }
    /// Return in an indented paragraph without a marker: the next line starts
    /// with the same tabs and spaces. On a line of nothing but white space it
    /// takes one step of it away instead (as on an empty list item). nil: no
    /// indentation, or the caret stands in it with text behind (a plain break).
    public static func indentedNewline(in text: String, range: NSRange) -> Edit? {
        let source = text as NSString
        guard range.location >= 0, range.length >= 0, NSMaxRange(range) <= source.length else { return nil }
        let start = TextLines.start(source, range.location), end = TextLines.end(source, start)
        var first = start
        while first < end, source.character(at: first) == 32 || source.character(at: first) == 9 { first += 1 }
        guard first > start else { return nil }
        let indent = source.substring(with: NSRange(location: start, length: first - start))
        if range.location > first { return Edit(range: range, replacement: "\n" + indent) }
        guard first == end, range.length == 0, range.location == end,
              let step = TextParagraphPrefix.outdentStep(of: indent) else { return nil }
        return Edit(range: NSRange(location: start + step.location, length: step.length), replacement: "")
    }
    public static func checkbox(in text: String, range: NSRange) -> Edit? {
        let source = text as NSString
        guard range.location >= 0, range.length >= 0, range.location <= source.length, range.length <= source.length - range.location else { return nil }
        guard let selected = selectedLines(in: text, range: NSRange(location: range.location, length: 0)).first else { return nil }
        let value = selected.prefix
        guard value.hasPrefix("☐ ") || value.hasPrefix("☑ ") else { return nil }
        return Edit(range: NSRange(location: selected.location, length: 1), replacement: value.hasPrefix("☐") ? "☑" : "☐")
    }
    public enum Kind: Sendable {
        case bullet, numbered, checkbox, arrow
        static let all: [Kind] = [.checkbox, .bullet, .numbered, .arrow]
    }

    /// Prefix-only edits keep the attributed text of the actual words intact.
    /// Tasks cycle absent → open → checked → absent; other lists toggle.
    public static func toggle(_ kind: Kind, in text: String, range: NSRange, level: ((Int) -> Int)? = nil) -> [Edit] {
        let lines = withoutBlankLines(listLines(for: kind, in: text, range: range, level: level), in: text)
        let remove = !lines.isEmpty && lines.allSatisfy { matches(kind, $0.prefix) }
        let check = kind == .checkbox && remove && lines.contains { $0.prefix == "☐ " }
        return lines.enumerated().map { index, line in
            let value: String
            if check { value = "☑ " }
            else if remove { value = "" }
            else { value = switch kind { case .bullet: bullet(forLevel: level?(lineStart(text, line.location)) ?? 0); case .checkbox: "☐ "; case .numbered: "\(index + 1). "; case .arrow: "→ " } }
            return Edit(range: NSRange(location: line.location, length: (line.prefix as NSString).length), replacement: value)
        }
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
    /// „→ “ list (Pfeil-Aufzählung); „-> “ and „=> “ stay as typed when the
    /// typing replacement is off (`TextSymbolReplacement`).
    static let arrowMarkers = ["→ ", "⇒ ", "-> ", "=> "]
    static func matches(_ kind: Kind, _ prefix: String) -> Bool {
        switch kind {
        case .bullet: prefix == "• " || prefix == "- " || prefix == "◦ " || prefix == "▪ "
        case .checkbox: prefix == "☐ " || prefix == "☑ "
        case .numbered: Int(prefix.dropLast(2)) != nil && prefix.hasSuffix(". ")
        case .arrow: arrowMarkers.contains(prefix)
        }
    }
    /// Changing a list's kind at a caret affects its connected entries. Explicit
    /// selections and toggling the current kind retain their local scope.
    private static func listLines(for kind: Kind, in text: String, range: NSRange, level: ((Int) -> Int)? = nil) -> [(location: Int, prefix: String)] {
        let selected = selectedLines(in: text, range: range)
        guard range.length == 0, let current = selected.first,
              let oldKind = Kind.all.first(where: { matches($0, current.prefix) }),
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
        var first = index, last = index
        while first > 0 && belongs(first - 1) { first -= 1 }
        while last + 1 < all.count && belongs(last + 1) { last += 1 }
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
        for value in ["• ", "- ", "◦ ", "▪ ", "☐ ", "☑ "] + arrowMarkers where line.hasPrefix(value) { return value }
        let digits = line.prefix { $0.isASCII && $0.isNumber }
        if !digits.isEmpty, digits.count <= 6, line.dropFirst(digits.count).hasPrefix(". ") { return digits + ". " }
        return nil
    }
}
