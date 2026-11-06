// Wahl der Gesetzesfassung zu einem Veranlagungsjahr (docs/PARAGRAPH-LINKS.md, P2).
import Foundation

public enum LawVersionChoice {
    /// Date of the last change named in a version's status lines
    /// ("zuletzt geändert durch … v. 29.6.2026"), nil if none is readable.
    public static func lastChange(_ version: LawVersion) -> CivilDay? {
        nil // TODO(Core-Agent P2)
    }
    /// The version that applied in `year` (latest version whose last change is
    /// on or before 31.12.`year`); nil when the catalog cannot tell (then the
    /// current version is shown with a hint).
    public static func version(for year: Int, in entry: LawEntry) -> LawVersion? {
        nil // TODO(Core-Agent P2)
    }
}

/// Plain calendar day without time zone.
public struct CivilDay: Equatable, Comparable, Sendable {
    public var year: Int, month: Int, day: Int
    public init(year: Int, month: Int, day: Int) { self.year = year; self.month = month; self.day = day }
    public static func < (a: Self, b: Self) -> Bool { (a.year, a.month, a.day) < (b.year, b.month, b.day) }
    public var text: String { "\(day).\(month).\(year)" }
}
