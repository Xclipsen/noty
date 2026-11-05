import Foundation

/// What a paragraph holds in front of its text: leading tabs and spaces,
/// optionally a marker (list marker, arrow, „a)“, „(1)“ …) and the white
/// space behind it. Wrapped lines of the paragraph start where its text
/// starts (hanging indent, `TextHangingIndent`); Return carries the prefix on
/// (`TextListEditing.newline`, `TextListEditing.indentedNewline`). Computed
/// from the text alone, nothing of it is stored: editor, previews and PDF
/// derive it alike.
public struct TextParagraphPrefix: Equatable, Sendable {
    /// Leading tabs and spaces.
    public var indent: String
    /// The marker without the white space behind it; nil: indentation only.
    public var marker: String?
    /// Tabs and spaces between marker and text (at least one with a marker).
    public var separator: String

    /// UTF-16 length up to the text.
    public var length: Int { utf16(indent) + utf16(marker ?? "") + utf16(separator) }

    /// Markers standing for themselves, longer ones first („->“ before „-“).
    /// „a.“/„i.“ are no markers: German text such as „z. B.“ or „i. d. R.“
    /// would hit them. „a)“ is.
    static let symbols = ["->", "=>", "•", "◦", "▪", "-", "–", "*", "+", "→", "⇒", "☐", "☑"]

    /// The prefix at the start of `line` (a line, or its part in front of the
    /// caret). nil: the line starts with its text.
    public init?(line: String) {
        let indent = String(line.prefix { $0 == " " || $0 == "\t" })
        let rest = line.dropFirst(indent.count)
        var marker: String?, separator = ""
        if let token = Self.marker(at: rest) {
            let blank = rest.dropFirst(token.count).prefix { $0 == " " || $0 == "\t" }
            if !blank.isEmpty { marker = token; separator = String(blank) }
        }
        guard !indent.isEmpty || marker != nil else { return nil }
        self.indent = indent; self.marker = marker; self.separator = separator
    }

    private static func marker(at text: Substring) -> String? {
        if let symbol = symbols.first(where: { text.hasPrefix($0) }) { return symbol }
        let characters = Array(text.prefix(10))
        var index = 0
        let parenthesized = characters.first == "("
        if parenthesized { index = 1 }
        let digits = characters[index...].prefix { $0.isASCII && $0.isNumber }
        if !digits.isEmpty {
            let end = index + digits.count
            guard digits.count <= (parenthesized ? 3 : 6), end < characters.count else { return nil }
            let close = characters[end]
            guard parenthesized ? close == ")" : (close == "." || close == ")") else { return nil }
            return String(characters[0...end])
        }
        // „a)“, „B)“, „aa)“ (German outlines), „(a)“.
        let letters = characters[index...].prefix { $0.isASCII && $0.isLetter }
        guard (1...2).contains(letters.count), index + letters.count < characters.count,
              characters[index + letters.count] == ")",
              letters.count == 1 || (letters.first == letters.last && letters.first!.isLowercase) else { return nil }
        return String(characters[0...(index + letters.count)])
    }

    /// The marker Return puts on the next line: the same, the next number or
    /// letter, an open box behind a checked one. nil: no marker (none here, or
    /// the letters ran out behind „z)“).
    public var nextMarker: String? {
        guard let marker else { return nil }
        if marker == "☑" || marker == "☐" { return "☐" }
        let open = marker.hasPrefix("(") ? "(" : ""
        let close = String(marker.suffix(1))
        let body = marker.dropFirst(open.count).dropLast()
        guard close == ")" || close == "." else { return marker }
        if let number = Int(body) { return number < 999_999 ? "\(open)\(number + 1)\(close)" : marker }
        guard let letter = body.first, let scalar = letter.unicodeScalars.first, letter != "z", letter != "Z",
              let next = UnicodeScalar(scalar.value + 1) else { return nil }
        return open + String(repeating: Character(next), count: body.count) + close
    }

    /// One step of the indentation, the part Return on an empty line takes
    /// away (UTF-16 range inside `indent`): the last tab, otherwise the
    /// trailing spaces, at most four. nil without indentation.
    public var outdentStep: NSRange? { Self.outdentStep(of: indent) }

    static func outdentStep(of indent: String) -> NSRange? {
        let length = utf16(indent)
        guard length > 0 else { return nil }
        if indent.hasSuffix("\t") { return NSRange(location: length - 1, length: 1) }
        let spaces = min(4, indent.reversed().prefix { $0 == " " }.count)
        return NSRange(location: length - spaces, length: spaces)
    }
}

private func utf16(_ value: String) -> Int { (value as NSString).length }

/// Hanging indent: the wrapped lines of a paragraph with a prefix start where
/// its text starts on the first line, under the text behind „•“, „->“, „a)“
/// or behind its leading tabs. Not stored: the shared text container of
/// editor, previews, PDF and flow capacity computes it while it lays out.
public enum TextHangingIndent {
    /// Text behind a prefix further right than this share of the width does
    /// not hang: the wrapped lines would get too narrow.
    public static let maximumShare = 0.5

    /// Where the text of the paragraph starting at `start` begins on its first
    /// line (`firstLineIndent` plus the measured prefix, tabs on the grid of
    /// `TextTabs`). nil: no prefix, nothing behind it, or too far right.
    /// `measure`: the width of a UTF-16 range without tabs, in its own format.
    public static func bodyStart(in text: NSString, paragraphStart start: Int, firstLineIndent: Double,
                                 tabInterval: Double, width: Double, measure: (NSRange) -> Double) -> Double? {
        guard start >= 0, start < text.length, width > 0 else { return nil }
        let end = TextLines.end(text, start)
        // A prefix is short; a long line is not copied to find it.
        let head = text.substring(with: NSRange(location: start, length: min(end - start, 256)))
        guard let prefix = TextParagraphPrefix(line: head) else { return nil }
        let stop = start + prefix.length
        // Only white space: no text that could wrap.
        guard stop < end else { return nil }
        var x = firstLineIndent, run = start
        for index in start..<stop where text.character(at: index) == 9 {
            if index > run { x += measure(NSRange(location: run, length: index - run)) }
            x = TextTabs.nextStop(after: x, interval: tabInterval)
            run = index + 1
        }
        if stop > run { x += measure(NSRange(location: run, length: stop - run)) }
        guard x.isFinite, x > firstLineIndent, x <= width * maximumShare else { return nil }
        return x
    }
}
