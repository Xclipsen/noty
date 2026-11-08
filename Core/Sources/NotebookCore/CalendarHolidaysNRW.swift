import Foundation

// Ferien-Rückfall NRW (docs/CALENDAR-PLAN.md, 06.11.2026). Holidays come
// preferably from WebUntis (school specific). Where WebUntis delivers none,
// the school holidays of Nordrhein-Westfalen from the embedded table below
// are shown, plus the statutory public holidays of NRW, computed (Easter
// based). No network needed.
//
// SOURCE of the table: Ferienordnung des Ministeriums für Schule und Bildung
// NRW (schulministerium.nrw, „Ferientermine“) as published for 2025/26 to
// 2027/28 (KMK-Übersicht der Länder). Entered from the developer model's
// knowledge on 06.11.2026, NOT downloaded. Checked by an independent review
// against BASS 19-1 and Kalenderpedia: confirmed, except that there are no
// Pfingstferien 2028 (removed) and Sommerferien 2028 (10.07.–22.08.) were
// found only on a calendar page – PROVISIONAL until the ministry lists them. School-specific movable
// days („bewegliche Ferientage“) are not included (only WebUntis knows them).
// End dates in the table are the last holiday (inclusive), as published.

public enum CalendarHolidaysNRW {
    public enum Origin: String, Sendable, Equatable {
        /// From WebUntis (the school's own calendar).
        case webUntis
        /// Embedded NRW table (fallback).
        case schoolTable
        /// Statutory public holiday of NRW (computed).
        case publicHoliday
    }

    public struct Day: Equatable, Sendable, Identifiable {
        public var holiday: CalendarHoliday
        public var origin: Origin
        public var id: String { origin.rawValue + "/" + holiday.id + "/" + holiday.start.description }
    }

    /// (name, first day, last day inclusive).
    static let schoolTable: [(String, String, String)] = [
        ("Herbstferien", "2025-10-13", "2025-10-25"),
        ("Weihnachtsferien", "2025-12-22", "2026-01-06"),
        ("Osterferien", "2026-03-30", "2026-04-11"),
        ("Pfingstferien", "2026-05-26", "2026-05-26"),
        ("Sommerferien", "2026-07-20", "2026-09-01"),
        ("Herbstferien", "2026-10-17", "2026-10-31"),
        ("Weihnachtsferien", "2026-12-23", "2027-01-06"),
        ("Osterferien", "2027-03-22", "2027-04-03"),
        ("Pfingstferien", "2027-05-18", "2027-05-18"),
        ("Sommerferien", "2027-07-19", "2027-08-31"),
        ("Herbstferien", "2027-10-23", "2027-11-06"),
        ("Weihnachtsferien", "2027-12-24", "2028-01-08"),
        ("Osterferien", "2028-04-10", "2028-04-22"),
        ("Sommerferien", "2028-07-10", "2028-08-22"), // vorläufig, siehe oben
    ]

    /// The table as holidays (`end` exclusive).
    public static var schoolHolidays: [CalendarHoliday] {
        schoolTable.compactMap { name, first, last in
            guard let start = CivilDate(first), let end = CivilDate(last) else { return nil }
            return CalendarHoliday(id: "nrw-\(first)", name: name, start: start, end: end.adding(days: 1))
        }
    }

    /// First and last year the table covers (outside: only public holidays).
    public static let tableYears = 2025...2028

    /// Easter Sunday (Gregorian, anonymous algorithm „Meeus/Jones/Butcher“).
    public static func easterSunday(_ year: Int) -> CivilDate? {
        let a = year % 19, b = year / 100, c = year % 100, d = b / 4, e = b % 4
        let f = (b + 8) / 25, g = (b - f + 1) / 3
        let h = (19 * a + b - d - g + 15) % 30
        let i = c / 4, k = c % 4
        let l = (32 + 2 * e + 2 * i - h - k) % 7
        let m = (a + 11 * h + 22 * l) / 451
        let month = (h + l - 7 * m + 114) / 31, day = (h + l - 7 * m + 114) % 31 + 1
        return CivilDate(year: year, month: month, day: day)
    }

    /// Statutory public holidays of NRW in `year` (one day each). Easter
    /// Sunday and Whit Sunday are not statutory holidays in NRW.
    public static func publicHolidays(_ year: Int) -> [CalendarHoliday] {
        guard let easter = easterSunday(year) else { return [] }
        var days: [(String, CivilDate?)] = [
            ("Neujahr", CivilDate(year: year, month: 1, day: 1)),
            ("Karfreitag", easter.adding(days: -2)),
            ("Ostermontag", easter.adding(days: 1)),
            ("Tag der Arbeit", CivilDate(year: year, month: 5, day: 1)),
            ("Christi Himmelfahrt", easter.adding(days: 39)),
            ("Pfingstmontag", easter.adding(days: 50)),
            ("Fronleichnam", easter.adding(days: 60)),
            ("Tag der Deutschen Einheit", CivilDate(year: year, month: 10, day: 3)),
            ("Allerheiligen", CivilDate(year: year, month: 11, day: 1)),
            ("1. Weihnachtstag", CivilDate(year: year, month: 12, day: 25)),
            ("2. Weihnachtstag", CivilDate(year: year, month: 12, day: 26)),
        ]
        days.sort { ($0.1 ?? easter) < ($1.1 ?? easter) }
        return days.compactMap { name, date in
            date.map { CalendarHoliday(id: "feiertag-\($0)", name: name, start: $0, end: $0.adding(days: 1)) }
        }
    }

    /// Holidays to show in [from, to): WebUntis holidays as delivered; table
    /// holidays only where they do not overlap the span WebUntis covers
    /// (first start to last end of its holidays – inside it the school's
    /// calendar decides, also about omissions); public holidays unless a
    /// shown school holiday already covers that day (no double band).
    public static func holidays(from: CivilDate, to: CivilDate, webUntis: [CalendarHoliday]) -> [Day] {
        guard from < to else { return [] }
        func overlaps(_ h: CalendarHoliday) -> Bool { h.start < to && h.end > from }
        var result = webUntis.filter(overlaps).map { Day(holiday: $0, origin: .webUntis) }
        let covered: (start: CivilDate, end: CivilDate)? = webUntis.isEmpty ? nil
            : (webUntis.map(\.start).min()!, webUntis.map(\.end).max()!)
        for holiday in schoolHolidays where overlaps(holiday) {
            if let covered, holiday.start < covered.end, holiday.end > covered.start { continue }
            result.append(Day(holiday: holiday, origin: .schoolTable))
        }
        let school = result.map(\.holiday)
        for year in max(1, from.year)...min(9999, to.year) {
            for holiday in publicHolidays(year) where overlaps(holiday) {
                if school.contains(where: { $0.start <= holiday.start && $0.end > holiday.start }) { continue }
                result.append(Day(holiday: holiday, origin: .publicHoliday))
            }
        }
        return result.sorted { ($0.holiday.start, $0.id) < ($1.holiday.start, $1.id) }
    }
}
