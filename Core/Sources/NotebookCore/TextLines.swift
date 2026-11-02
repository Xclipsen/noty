import Foundation

/// Lines of plain text: a line runs up to its line break.
public enum TextLines {
    /// U+000C: a manual page break in the flow of a text document. It ends its
    /// line, the flow goes on on the next page (`Notebook.reflowText`).
    public static let pageBreak: unichar = 0x0C
    public static let pageBreakText = "\u{0C}"

    public static func isBreak(_ unit: unichar) -> Bool { [10, pageBreak, 13, 0x2028, 0x2029].contains(unit) }

    /// Start of the line holding `offset`.
    public static func start(_ text: NSString, _ offset: Int) -> Int {
        var index = min(offset, text.length)
        while index > 0, !isBreak(text.character(at: index - 1)) { index -= 1 }
        return index
    }
    /// End of that line, before its line break.
    public static func end(_ text: NSString, _ offset: Int) -> Int {
        var index = min(offset, text.length)
        while index < text.length, !isBreak(text.character(at: index)) { index += 1 }
        return index
    }

    /// `NSString.lineRange`: Foundation does not end a line at U+000C.
    public static func lineRange(_ text: NSString, _ range: NSRange) -> NSRange {
        pageBounded(text.lineRange(for: range), around: range, in: text)
    }
    /// `NSString.paragraphRange`, likewise.
    public static func paragraphRange(_ text: NSString, _ range: NSRange) -> NSRange {
        pageBounded(text.paragraphRange(for: range), around: range, in: text)
    }
    private static func pageBounded(_ whole: NSRange, around range: NSRange, in text: NSString) -> NSRange {
        var start = range.location
        while start > whole.location, text.character(at: start - 1) != pageBreak { start -= 1 }
        var end = NSMaxRange(range) - (range.length > 0 ? 1 : 0)
        while end < NSMaxRange(whole), text.character(at: end) != pageBreak { end += 1 }
        return NSRange(location: start, length: min(end + 1, NSMaxRange(whole)) - start)
    }

    /// Offsets of the page breaks, ascending.
    static func pageBreaks(in text: NSString) -> [Int] {
        var result: [Int] = [], search = NSRange(location: 0, length: text.length)
        while search.length > 0 {
            let found = text.range(of: pageBreakText, options: .literal, range: search)
            guard found.location != NSNotFound else { break }
            result.append(found.location)
            search = NSRange(location: NSMaxRange(found), length: text.length - NSMaxRange(found))
        }
        return result
    }
}
