import Foundation

/// iPadOS offers the result of a calculation after „=“ and inserts it directly
/// behind the sign; the app has no say in that (`mathExpressionCompletionType`
/// only switches it on or off). This finds such an insertion so that a space
/// can follow. A result typed by hand looks the same and gets the space too.
public enum MathResultSpacing {
    /// The space to add after the change from `before` to `after`, with the
    /// caret behind the new text (UTF-16 offset); nil for every other change.
    public static func edit(before: String, after: String, caret: Int) -> TextListEditing.Edit? {
        let old = before as NSString, new = after as NSString
        let count = new.length - old.length
        guard count >= 1, caret >= count, caret <= new.length else { return nil }
        let start = caret - count
        guard start >= 2, new.character(at: start - 1) == 61,
              new.substring(to: start) == old.substring(to: start),
              new.substring(from: caret) == old.substring(from: start),
              isResult(new.substring(with: NSRange(location: start, length: count))) else { return nil }
        let line = TextLines.start(new, start)
        guard isExpression(new.substring(with: NSRange(location: line, length: start - 1 - line))) else { return nil }
        return .init(range: NSRange(location: start, length: 0), replacement: " ")
    }
    /// „20“, „1.234,5“, „−3“, „25%“, „5000 m“.
    private static func isResult(_ text: String) -> Bool {
        text.range(of: #"^[-−]?[0-9][0-9.,']*(%| ?\p{L}{1,5})?$"#, options: .regularExpression) != nil
    }
    /// Left of the sign stands a calculation, no „a == b“ and no plain „x“ or „Seite 3“.
    private static func isExpression(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let last = trimmed.last, !"=<>!".contains(last), trimmed.contains(where: \.isNumber) else { return false }
        return trimmed.contains(where: { "+-−*/×÷:^%".contains($0) }) || trimmed.contains(" in ")
    }
}
