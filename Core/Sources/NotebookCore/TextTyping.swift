import Foundation

/// What typing in the keyboard mode does beyond the typed characters
/// (docs/KEYBOARD.md): Helix's indent and pairs, for the two text paths and
/// the engine. Lists stay with `TextListEditing`, it goes first.
public enum TextTyping {
    private static let pairs: [(open: String, close: String)] = [("(", ")"), ("[", "]"), ("{", "}"), ("\"", "\""), ("'", "'")]

    public struct Pairing: Equatable, Sendable {
        /// Goes in at the caret; empty: the character is already there.
        public var insert: String
        /// How far the caret moves, it may stay inside `insert`.
        public var advance: Int
    }

    /// Typing `typed` at `caret`; nil: nothing special, it is typed as it is.
    /// Only an open pair next to no word character closes itself.
    public static func pairing(_ typed: String, in text: NSString, at caret: Int) -> Pairing? {
        guard let pair = pairs.first(where: { $0.open == typed || $0.close == typed }) else { return nil }
        let same = pair.open == pair.close
        if typed == pair.close, unit(in: text, at: caret) == pair.close { return Pairing(insert: "", advance: 1) }
        guard typed == pair.open else { return nil }
        let closes = !isAlphanumeric(text, at: caret) && (!same || caret == 0 || !isAlphanumeric(text, at: caret - 1))
        return closes ? Pairing(insert: pair.open + pair.close, advance: 1) : nil
    }

    /// ⌫ between the two halves of a pair: both go. Nil: as usual.
    public static func pairDeletion(in text: NSString, at caret: Int) -> NSRange? {
        guard caret > 0, let open = unit(in: text, at: caret - 1), let close = unit(in: text, at: caret),
              pairs.contains(where: { $0.open == open && $0.close == close }) else { return nil }
        return NSRange(location: caret - 1, length: 2)
    }

    /// A line break at `range` that keeps the leading white space; the caret
    /// goes behind the replacement. As Helix, white space in front of the
    /// caret does not stay at the end of the old line. Nil: an unindented
    /// line, the plain line break does it.
    public static func newline(in text: String, range: NSRange) -> TextListEditing.Edit? {
        let source = text as NSString
        guard range.location >= 0, range.length >= 0, NSMaxRange(range) <= source.length else { return nil }
        let line = TextLines.start(source, range.location), end = TextLines.end(source, line)
        var first = line
        while first < end, isBlank(source.character(at: first)) { first += 1 }
        guard first > line else { return nil }
        guard range.length == 0 else {
            return .init(range: range, replacement: "\n" + source.substring(with: NSRange(location: line, length: first - line)))
        }
        if first >= range.location {
            // Nothing but white space in front: the line break goes before it.
            let before = NSRange(location: line, length: range.location - line)
            return .init(range: before, replacement: "\n" + source.substring(with: before))
        }
        var trimmed = range.location
        while trimmed > first, isBlank(source.character(at: trimmed - 1)) { trimmed -= 1 }
        return .init(range: NSRange(location: trimmed, length: range.location - trimmed),
                     replacement: "\n" + source.substring(with: NSRange(location: line, length: first - line)))
    }

    private static func isBlank(_ unit: unichar) -> Bool { unit == 32 || unit == 9 }
    private static func unit(in text: NSString, at index: Int) -> String? {
        index >= 0 && index < text.length ? text.substring(with: NSRange(location: index, length: 1)) : nil
    }
    /// The grapheme around `index`, by its first scalar, as `TextEngine.category`.
    private static func isAlphanumeric(_ text: NSString, at index: Int) -> Bool {
        guard index >= 0, index < text.length else { return false }
        let grapheme = text.substring(with: text.rangeOfComposedCharacterSequence(at: index))
        guard let properties = grapheme.unicodeScalars.first?.properties else { return false }
        return properties.isAlphabetic || properties.numericType != nil
    }
}
