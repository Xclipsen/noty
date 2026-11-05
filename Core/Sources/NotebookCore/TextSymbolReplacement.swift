import Foundation

/// Arrows and signs while typing (Einstellungen › Editor, `noty.editor.symbols`,
/// on by default): typing the last character of `->` writes `→`. The symbol is
/// text like any other, nothing else is stored. ⌫ directly behind it or undo
/// brings back what was typed (`typed`), like an autocorrection.
///
/// Signs that start a longer one become it with its last character: `<-` is
/// `←` at once, a following `>` turns `←` into `↔`. The calculator never
/// computes behind `<`, `>`, `!` or `~`, so `<=`, `>=`, `!=`, `~=` do not
/// collide with a typed „=“ (`TextCalculator`).
public enum TextSymbolReplacement {
    public struct Rule: Equatable, Sendable {
        /// The text in front of the caret after typing its last character.
        public let pattern: String
        public let symbol: String
        /// What was typed for it (the chained `<->` passed `←` on the way).
        public let typed: String
        init(_ pattern: String, _ symbol: String, typed: String? = nil) {
            self.pattern = pattern; self.symbol = symbol; self.typed = typed ?? pattern
        }
    }
    /// Longer patterns first.
    public static let rules: [Rule] = [
        Rule("<->", "↔"), Rule("<=>", "⇔"), Rule("←>", "↔", typed: "<->"), Rule("≤>", "⇔", typed: "<=>"),
        Rule("->", "→"), Rule("<-", "←"), Rule("=>", "⇒"),
        Rule("<=", "≤"), Rule(">=", "≥"), Rule("!=", "≠"), Rule("~=", "≈"), Rule("+-", "±"),
    ]

    public struct Replacement: Equatable, Sendable {
        public var edit: TextListEditing.Edit
        /// The symbol in the text after `edit`.
        public var symbol: NSRange
        /// What ⌫ right behind the symbol writes back.
        public var typed: String
    }

    /// The replacement for the character just typed in front of `caret`; nil:
    /// the text stays as typed.
    public static func replacement(in text: String, caret: Int) -> Replacement? {
        let source = text as NSString
        guard caret >= 2, caret <= source.length else { return nil }
        for rule in rules {
            let length = (rule.pattern as NSString).length
            guard caret >= length, source.substring(with: NSRange(location: caret - length, length: length)) == rule.pattern else { continue }
            let range = NSRange(location: caret - length, length: length)
            return Replacement(edit: .init(range: range, replacement: rule.symbol),
                               symbol: NSRange(location: range.location, length: (rule.symbol as NSString).length), typed: rule.typed)
        }
        return nil
    }

    /// ⌫ with the caret right behind a replaced symbol: the typed characters
    /// come back, the caret behind them. nil: an ordinary ⌫.
    public static func reverting(_ replacement: Replacement, in text: String, caret: Int) -> TextListEditing.Edit? {
        let source = text as NSString, symbol = replacement.symbol
        guard caret == NSMaxRange(symbol), NSMaxRange(symbol) <= source.length,
              source.substring(with: symbol) == replacement.edit.replacement else { return nil }
        return .init(range: symbol, replacement: replacement.typed)
    }
}
