import Foundation

/// Lines of plain text: a line runs up to its line break.
public enum TextLines {
    public static func isBreak(_ unit: unichar) -> Bool { [10, 13, 0x2028, 0x2029].contains(unit) }

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
}
