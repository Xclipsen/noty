import Foundation

/// UTF-16 ranges match UITextView, including emoji and composed characters.
public enum TextListEditing {
    public struct Edit: Equatable, Sendable {
        public var range: NSRange
        public var replacement: String
        public init(range: NSRange, replacement: String) { self.range = range; self.replacement = replacement }
    }
    public static func newline(in text: String, range: NSRange) -> Edit? {
        let source = text as NSString
        guard range.location <= source.length, range.length <= source.length - range.location else { return nil }
        let line = source.lineRange(for: NSRange(location: range.location, length: 0))
        let before = source.substring(with: NSRange(location: line.location, length: range.location - line.location))
        guard let prefix = prefix(before) else { return nil }
        let content = String(before.dropFirst(prefix.count))
        if content.trimmingCharacters(in: .whitespaces).isEmpty {
            return Edit(range: NSRange(location: line.location, length: range.location + range.length - line.location), replacement: "")
        }
        let next: String
        if prefix == "☑ " || prefix == "☐ " { next = "☐ " }
        else if let number = Int(prefix.dropLast(2)), number < 999_999 { next = "\(number + 1). " }
        else { next = prefix }
        return Edit(range: range, replacement: "\n" + next)
    }
    public static func checkbox(in text: String, range: NSRange) -> Edit? {
        let source = text as NSString
        guard range.location <= source.length, range.length <= source.length - range.location else { return nil }
        let line = source.lineRange(for: NSRange(location: range.location, length: 0))
        let value = source.substring(with: line)
        guard value.hasPrefix("☐ ") || value.hasPrefix("☑ ") else { return nil }
        return Edit(range: NSRange(location: line.location, length: 1), replacement: value.hasPrefix("☐") ? "☑" : "☐")
    }
    public enum Kind: Sendable { case bullet, numbered, checkbox }

    /// Prefix-only edits keep the attributed text of the actual words intact.
    /// Tapping an already applied list style removes it, including checked tasks.
    public static func toggle(_ kind: Kind, in text: String, range: NSRange) -> [Edit] {
        let lines = selectedLines(in: text, range: range)
        let remove = !lines.isEmpty && lines.allSatisfy { matches(kind, $0.prefix) }
        return lines.enumerated().map { index, line in
            let value: String
            if remove { value = "" }
            else { value = switch kind { case .bullet: "• "; case .checkbox: "☐ "; case .numbered: "\(index + 1). " } }
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
    private static func matches(_ kind: Kind, _ prefix: String) -> Bool {
        switch kind {
        case .bullet: prefix == "• " || prefix == "- "
        case .checkbox: prefix == "☐ " || prefix == "☑ "
        case .numbered: Int(prefix.dropLast(2)) != nil && prefix.hasSuffix(". ")
        }
    }
    private static func selectedLines(in text: String, range: NSRange) -> [(location: Int, prefix: String)] {
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
    private static func prefix(_ line: String) -> String? {
        for value in ["• ", "- ", "☐ ", "☑ "] where line.hasPrefix(value) { return value }
        let digits = line.prefix { $0.isASCII && $0.isNumber }
        if !digits.isEmpty, digits.count <= 6, line.dropFirst(digits.count).hasPrefix(". ") { return digits + ". " }
        return nil
    }
}
