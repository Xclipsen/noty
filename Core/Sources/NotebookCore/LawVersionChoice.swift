// Wahl der Gesetzesfassung zu einem Veranlagungsjahr (docs/PARAGRAPH-LINKS.md, P2).
import Foundation

/// Which catalog version applied in a tax year, read from the status lines
/// of the versions (gesetze-im-internet.de / BMF-Handbücher).
///
/// Entscheidungen:
/// - Stand einer Fassung ist das späteste Datum einer in ihren Text
///   eingearbeiteten Änderung: „(Zuletzt) geändert durch … v. 29.6.2026“,
///   „Neugefasst durch Bek. v. 23.1.2025“, „(Mittelbare) Änderung durch … v. …
///   ist berücksichtigt / textlich nachgewiesen“, „Ergänzung … v. …“, „Stand
///   2. Juni 2026“, „… vom 1. Oktober 2010“. Zeilen mit „nicht ausführbar“,
///   „nicht berücksichtigt“, „nicht eingearbeitet“ oder „noch nicht in Kraft“
///   zählen nicht. Fundstellen wie „2002 I 679“ sind kein Datum.
/// - Es ist das Datum des **ändernden Gesetzes**, nicht das Inkrafttreten:
///   eine Näherung (ein im Dezember verkündetes Gesetz für das Folgejahr
///   zählt zum Verkündungsjahr). Die App zeigt die Fassung deshalb mit Hinweis.
/// - BMF-Handbücher („aus LStH 2026“, „aus AO-Handbuch 2026“) haben nur ein
///   Jahr: das Handbuch des Jahres gilt für diesen Veranlagungszeitraum, Stand
///   also 1.1. des Jahres (`CivilDay.yearOnly`). Ein volles Datum geht vor.
public enum LawVersionChoice {
    /// Date of the last change named in a version's status lines
    /// ("zuletzt geändert durch … v. 29.6.2026"), nil if none is readable.
    public static func lastChange(_ version: LawVersion) -> CivilDay? {
        lastChange(status: version.status)
    }

    static func lastChange(status: [String]) -> CivilDay? {
        var full: CivilDay? = nil, yearOnly: CivilDay? = nil
        for line in status {
            let lower = line.lowercased()
            guard !excluded.contains(where: lower.contains) else { continue }
            for day in dates(in: line) { full = max(full ?? day, day) }
            for year in handbookYears(in: line) {
                let day = CivilDay(year: year, month: 1, day: 1, yearOnly: true)
                yearOnly = max(yearOnly ?? day, day)
            }
        }
        return full ?? yearOnly
    }

    /// The version that applied in `year` (latest version whose last change is
    /// on or before 31.12.`year`); nil when the catalog cannot tell (then the
    /// current version is shown with a hint).
    ///
    /// Nil as well when any version has no readable date (the order is then
    /// unknown) or when two versions share the latest qualifying date and
    /// neither is the current one.
    public static func version(for year: Int, in entry: LawEntry) -> LawVersion? {
        var dated: [(version: LawVersion, day: CivilDay)] = []
        for version in entry.versions {
            guard let day = lastChange(version) else { return nil }
            dated.append((version, day))
        }
        let end = CivilDay(year: year, month: 12, day: 31)
        let qualifying = dated.filter { $0.day <= end }
        guard let latest = qualifying.map(\.day).max() else { return nil }
        let candidates = qualifying.filter { $0.day == latest }.map(\.version)
        if candidates.count == 1 { return candidates[0] }
        return candidates.first { $0.id == entry.currentVersion }
    }

    // MARK: - Parsing

    private static let excluded = ["nicht ausführbar", "nicht berücksichtigt", "nicht eingearbeitet", "noch nicht in kraft"]
    private static let months = ["januar", "februar", "märz", "april", "mai", "juni", "juli", "august", "september", "oktober", "november", "dezember"]

    /// "v. 29.6.2026", "vom 29.06.2026", "vom 1. Oktober 2010", "Stand 2. Juni 2026", "Stand: 2.6.2026".
    private static let datePattern = try! NSRegularExpression(
        pattern: #"(?:\bv\.|\bvom|\bStand:?)\s*(\d{1,2})\.\s*(?:(\d{1,2})\.\s*|([A-Za-zÄÖÜäöü]+)\s+)(\d{4})\b"#,
        options: [.caseInsensitive])
    /// "aus LStH 2026", "aus EStH 2025", "aus AO-Handbuch 2026".
    private static let handbookPattern = try! NSRegularExpression(
        pattern: #"\baus\s+(?:[A-ZÄÖÜ][A-Za-zÄÖÜäöü]*H|[A-Za-zÄÖÜäöü-]*Handbuch(?:s|es)?)\s+(\d{4})\b"#)

    static func dates(in line: String) -> [CivilDay] {
        let ns = line as NSString
        return datePattern.matches(in: line, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            func group(_ i: Int) -> String? { m.range(at: i).location == NSNotFound ? nil : ns.substring(with: m.range(at: i)) }
            guard let day = group(1).flatMap(Int.init), let year = group(4).flatMap(Int.init) else { return nil }
            let month: Int?
            if let number = group(2) { month = Int(number) } else { month = group(3).flatMap { months.firstIndex(of: $0.lowercased()) }.map { $0 + 1 } }
            guard let month, (1...12).contains(month), (1...31).contains(day), (1800...2200).contains(year) else { return nil }
            return CivilDay(year: year, month: month, day: day)
        }
    }

    static func handbookYears(in line: String) -> [Int] {
        let ns = line as NSString
        return handbookPattern.matches(in: line, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            Int(ns.substring(with: m.range(at: 1))).flatMap { (1800...2200).contains($0) ? $0 : nil }
        }
    }
}

/// Plain calendar day without time zone.
public struct CivilDay: Equatable, Comparable, Sendable {
    public var year: Int, month: Int, day: Int
    /// Only the year is known (BMF-Handbuch „LStH 2026“); month/day are 1.1.
    public var yearOnly: Bool
    public init(year: Int, month: Int, day: Int, yearOnly: Bool = false) {
        self.year = year; self.month = month; self.day = day; self.yearOnly = yearOnly
    }
    public static func < (a: Self, b: Self) -> Bool { (a.year, a.month, a.day) < (b.year, b.month, b.day) }
    public var text: String { yearOnly ? "\(year)" : "\(day).\(month).\(year)" }
}
