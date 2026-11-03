import Foundation

/// Tab stops of every text: an endless, even grid from the left text edge
/// that grows with the font, so a tab looks the same on a paper page and on a
/// large scan. Not stored anywhere; the same style builds editor, preview and
/// PDF, so all three place a tab alike.
public enum TextTabs {
    /// 35 pt (about 1.25 cm) at the usual 14 pt.
    public static func interval(fontSize: Double) -> Double { max(8, (fontSize * 2.5).rounded()) }

    /// One grid per field, whatever size single words or a line's first
    /// character have: lines of a field only line up on the same stops.
    /// The largest size in the text decides, a heading keeps usable tabs.
    public static func interval(_ box: TextBox) -> Double {
        let sizes = (box.runs ?? []).filter { $0.length > 0 }.map(\.style.fontSize)
        return interval(fontSize: sizes.max() ?? box.style.fontSize)
    }

    /// The stop a tab starting at `x` runs to: always a next one, also exactly on a stop.
    public static func nextStop(after x: Double, interval: Double) -> Double {
        guard interval > 0, x.isFinite else { return x }
        return (floor(max(0, x) / interval + 1e-9) + 1) * interval
    }

    /// What Tab or ⇧Tab changes without typing a tab at the caret:
    /// a selection over several lines moves line by line (empty lines stay),
    /// ⇧Tab takes back the tab before the caret, otherwise the one at the line
    /// start. nil: nothing of this applies.
    public static func edits(in text: String, selection: NSRange, outdent: Bool) -> [TextListEditing.Edit]? {
        let source = text as NSString
        guard selection.location >= 0, selection.length >= 0, NSMaxRange(selection) <= source.length else { return nil }
        let lines = starts(in: source, selection)
        if lines.count > 1 {
            let edits: [TextListEditing.Edit] = lines.compactMap { start in
                if outdent { return leadingTab(source, start) }
                let empty = start >= source.length || TextLines.isBreak(source.character(at: start))
                return empty ? nil : .init(range: NSRange(location: start, length: 0), replacement: "\t")
            }
            return edits.isEmpty ? nil : edits
        }
        guard outdent else { return nil }
        if selection.length == 0, selection.location > 0, source.character(at: selection.location - 1) == 9 {
            return [.init(range: NSRange(location: selection.location - 1, length: 1), replacement: "")]
        }
        return leadingTab(source, TextLines.start(source, selection.location)).map { [$0] }
    }
    private static func leadingTab(_ source: NSString, _ start: Int) -> TextListEditing.Edit? {
        guard start < source.length, source.character(at: start) == 9 else { return nil }
        return .init(range: NSRange(location: start, length: 1), replacement: "")
    }
    /// Line starts touched by the selection; a selection ending right behind
    /// a line break does not reach into the next line.
    private static func starts(in source: NSString, _ selection: NSRange) -> [Int] {
        var result = [TextLines.start(source, selection.location)]
        var index = selection.location
        let end = NSMaxRange(selection)
        while index < end {
            if TextLines.isBreak(source.character(at: index)), index + 1 < end { result.append(index + 1) }
            index += 1
        }
        return result
    }
}
