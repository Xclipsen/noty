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
    /// Deliberately so (Einzug-Audit, 05.11.2026): a larger heading widens the
    /// grid of the whole field, changing that would move existing alignments.
    public static func interval(_ box: TextBox) -> Double {
        // `styleRuns`: text between the stored runs has the field's style.
        let sizes = box.styleRuns.map(\.style.fontSize)
        return interval(fontSize: sizes.max() ?? box.style.fontSize)
    }

    /// The stop a tab starting at `x` runs to: always a next one, also exactly on a stop.
    public static func nextStop(after x: Double, interval: Double) -> Double {
        guard interval > 0, x.isFinite else { return x }
        return (floor(max(0, x) / interval + 1e-9) + 1) * interval
    }
}
