import XCTest
@testable import NotebookCore

final class CalendarLayoutTests: XCTestCase {
    private let berlin = CalendarDates.german(timeZone: TimeZone(identifier: "Europe/Berlin")!)

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0, _ calendar: Calendar? = nil) -> Date {
        let calendar = calendar ?? berlin
        return calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }
    private func ymd(_ value: Date, _ calendar: Calendar? = nil) -> [Int] {
        let p = (calendar ?? berlin).dateComponents([.year, .month, .day, .hour, .minute], from: value)
        return [p.year!, p.month!, p.day!, p.hour!, p.minute!]
    }

    func testGermanCalendarStartsOnMondayAndUsesISOWeeks() {
        XCTAssertEqual(berlin.firstWeekday, 2)
        XCTAssertEqual(berlin.minimumDaysInFirstWeek, 4)
        XCTAssertEqual(berlin.locale?.identifier, "de_DE")
        XCTAssertEqual(CalendarDates.weekdayIndex(date(2026, 11, 2), calendar: berlin), 0) // Monday
        XCTAssertEqual(CalendarDates.weekdayIndex(date(2026, 11, 8), calendar: berlin), 6) // Sunday
        // A Gregorian calendar with US settings gives the same Monday start.
        var us = Calendar(identifier: .gregorian)
        us.timeZone = berlin.timeZone; us.firstWeekday = 1
        XCTAssertEqual(CalendarDates.weekdayIndex(date(2026, 11, 3), calendar: us), 1)
    }

    func testFiveAndSevenDayWeeks() {
        let tuesday = date(2026, 11, 3, 14, 30)
        let five = CalendarDates.weekDays(containing: tuesday, count: 5, calendar: berlin)
        XCTAssertEqual(five.map { ymd($0) }, (2...6).map { [2026, 11, $0, 0, 0] })
        let seven = CalendarDates.weekDays(containing: tuesday, count: 7, calendar: berlin)
        XCTAssertEqual(seven.count, 7)
        XCTAssertEqual(ymd(seven[6]), [2026, 11, 8, 0, 0])
        // Sunday belongs to the week that started on the Monday before.
        XCTAssertEqual(ymd(CalendarDates.startOfWeek(date(2026, 11, 8, 23, 59), calendar: berlin)), [2026, 11, 2, 0, 0])
        let range = CalendarDates.range(.week, anchor: tuesday, weekDays: 5, calendar: berlin)
        XCTAssertEqual(ymd(range.start), [2026, 11, 2, 0, 0])
        XCTAssertEqual(ymd(range.end), [2026, 11, 7, 0, 0]) // exclusive: Saturday
    }

    func testDaylightSavingChangesKeepCivilDays() {
        // 25.10.2026: back to CET, the day has 25 hours.
        let week = CalendarDates.weekDays(containing: date(2026, 10, 22), count: 7, calendar: berlin)
        XCTAssertEqual(week.map { ymd($0) }, (19...25).map { [2026, 10, $0, 0, 0] })
        let next = CalendarDates.day(7, after: week[0], calendar: berlin)
        XCTAssertEqual(ymd(next), [2026, 10, 26, 0, 0])
        XCTAssertEqual(next.timeIntervalSince(week[0]), 169 * 3600) // not 7 × 24 h
        XCTAssertEqual(ymd(CalendarDates.shift(date(2026, 10, 25), mode: .day, by: 1, calendar: berlin)), [2026, 10, 26, 0, 0])
        // 29.03.2026: to CEST, the day has 23 hours.
        let spring = CalendarDates.weekDays(containing: date(2026, 3, 29, 12), count: 7, calendar: berlin)
        XCTAssertEqual(spring.map { ymd($0) }, (23...29).map { [2026, 3, $0, 0, 0] })
        XCTAssertEqual(ymd(CalendarDates.shift(spring[0], mode: .week, by: 1, calendar: berlin)), [2026, 3, 30, 0, 0])
        // Wall-clock grid positions on both days.
        let fall = date(2026, 10, 25)
        XCTAssertEqual(CalendarDates.minutesIntoDay(date(2026, 10, 25, 1, 30), day: fall, calendar: berlin), 90)
        XCTAssertEqual(CalendarDates.minutesIntoDay(date(2026, 10, 25, 3, 30), day: fall, calendar: berlin), 210)
        XCTAssertEqual(CalendarDates.minutesIntoDay(date(2026, 3, 29, 3, 15), day: date(2026, 3, 29), calendar: berlin), 195)
        XCTAssertEqual(CalendarDates.minutesIntoDay(date(2026, 10, 24, 23), day: fall, calendar: berlin), 0)
        XCTAssertEqual(CalendarDates.minutesIntoDay(date(2026, 10, 26, 0, 30), day: fall, calendar: berlin), 1440)
    }

    func testEveryDayStepStaysOnTheNextCivilDayInSeveralZones() {
        // Zones with DST at midnight (Santiago, Havana) have days without 00:00.
        for zone in ["Europe/Berlin", "America/Santiago", "America/Havana", "Australia/Lord_Howe"] {
            guard let timeZone = TimeZone(identifier: zone) else { continue }
            let calendar = CalendarDates.german(timeZone: timeZone)
            var day = calendar.startOfDay(for: date(2025, 12, 30, 12, 0, calendar))
            for _ in 0..<800 {
                let next = CalendarDates.day(1, after: day, calendar: calendar)
                XCTAssertEqual(CalendarDates.days(from: day, to: next, calendar: calendar), 1, "\(zone) \(day)")
                XCTAssertEqual(next, calendar.startOfDay(for: next), zone)
                XCTAssertGreaterThan(next.timeIntervalSince(day), 20 * 3600, zone)
                day = next
            }
            // Every week of 2026 starts on a Monday.
            var monday = CalendarDates.startOfWeek(date(2026, 1, 1, 12, 0, calendar), calendar: calendar)
            for _ in 0..<53 {
                XCTAssertEqual(CalendarDates.weekdayIndex(monday, calendar: calendar), 0, zone)
                monday = CalendarDates.shift(monday, mode: .week, by: 1, calendar: calendar)
            }
        }
    }

    func testISOWeekOneAndFiftyThreeAtYearBoundaries() {
        XCTAssertTrue(CalendarDates.isoWeek(date(2026, 12, 28), calendar: berlin) == (53, 2026))
        XCTAssertTrue(CalendarDates.isoWeek(date(2027, 1, 1), calendar: berlin) == (53, 2026))
        XCTAssertTrue(CalendarDates.isoWeek(date(2027, 1, 3), calendar: berlin) == (53, 2026))
        XCTAssertTrue(CalendarDates.isoWeek(date(2027, 1, 4), calendar: berlin) == (1, 2027))
        // 1.1.2026 is a Thursday: week 1 of 2026 starts on 29.12.2025.
        XCTAssertTrue(CalendarDates.isoWeek(date(2025, 12, 29), calendar: berlin) == (1, 2026))
        XCTAssertTrue(CalendarDates.isoWeek(date(2021, 1, 1), calendar: berlin) == (53, 2020))
        XCTAssertTrue(CalendarDates.isoWeek(date(2026, 11, 3), calendar: berlin) == (45, 2026))
        // Week across the year: next week from 30.12.2026.
        XCTAssertEqual(ymd(CalendarDates.shift(date(2026, 12, 30), mode: .week, by: 1, calendar: berlin)), [2027, 1, 6, 0, 0])
        XCTAssertEqual(ymd(CalendarDates.shift(date(2027, 1, 2), mode: .day, by: -2, calendar: berlin)), [2026, 12, 31, 0, 0])
    }

    func testMonthGridUsesWholeISOWeeks() {
        let november = CalendarMonthGrid(month: date(2026, 11, 17), calendar: berlin)
        XCTAssertEqual(november.weeks.map(\.number), [44, 45, 46, 47, 48, 49])
        XCTAssertEqual(ymd(november.weeks[0].days[0]), [2026, 10, 26, 0, 0])
        XCTAssertEqual(ymd(november.weeks[5].days[6]), [2026, 12, 6, 0, 0])
        XCTAssertFalse(november.contains(november.weeks[0].days[0], calendar: berlin))
        XCTAssertTrue(november.contains(november.weeks[0].days[6], calendar: berlin)) // Sunday 1.11.
        XCTAssertTrue(november.weeks.allSatisfy { $0.days.count == 7 })
        // December: the last row carries 1.–3.1.2027 under KW 53.
        let december = CalendarMonthGrid(month: date(2026, 12, 1), calendar: berlin)
        XCTAssertEqual(december.weeks.map(\.number), [49, 50, 51, 52, 53])
        XCTAssertEqual(ymd(december.weeks[4].days[6]), [2027, 1, 3, 0, 0])
        // February 2027 starts on a Monday and fills exactly four rows.
        let february = CalendarMonthGrid(month: date(2027, 2, 14), calendar: berlin)
        XCTAssertEqual(february.weeks.map(\.number), [5, 6, 7, 8])
        // January 2027 begins inside KW 53 of 2026.
        XCTAssertEqual(CalendarMonthGrid(month: date(2027, 1, 1), calendar: berlin).weeks.first?.number, 53)
    }

    func testLeapYearMonthsAndSteps() {
        XCTAssertEqual(CalendarDates.monthDays(date(2028, 2, 10), calendar: berlin).count, 29)
        XCTAssertEqual(CalendarDates.monthDays(date(2027, 2, 10), calendar: berlin).count, 28)
        XCTAssertEqual(CalendarDates.monthDays(date(2100, 2, 10), calendar: berlin).count, 28)
        XCTAssertEqual(ymd(CalendarDates.shift(date(2028, 1, 31), mode: .month, by: 1, calendar: berlin)), [2028, 2, 29, 0, 0])
        XCTAssertEqual(ymd(CalendarDates.shift(date(2028, 2, 29), mode: .year, by: 1, calendar: berlin)), [2029, 2, 28, 0, 0])
        let grid = CalendarMonthGrid(month: date(2028, 2, 1), calendar: berlin)
        XCTAssertEqual(grid.weeks.count, 5)
        XCTAssertEqual(ymd(grid.weeks[4].days[1]), [2028, 2, 29, 0, 0])
        let year = CalendarDates.range(.year, anchor: date(2028, 7, 1), weekDays: 5, calendar: berlin)
        XCTAssertEqual(CalendarDates.days(from: year.start, to: year.end, calendar: berlin), 366)
        XCTAssertEqual(CalendarDates.yearMonths(date(2028, 7, 1), calendar: berlin).map { ymd($0)[1] }, Array(1...12))
        let month = CalendarDates.range(.month, anchor: date(2028, 2, 29, 18), weekDays: 7, calendar: berlin)
        XCTAssertEqual(ymd(month.start), [2028, 2, 1, 0, 0])
        XCTAssertEqual(ymd(month.end), [2028, 3, 1, 0, 0])
    }

    func testOccurrenceDayMembership() {
        let day = date(2026, 11, 3)
        XCTAssertTrue(CalendarDates.timed(start: date(2026, 11, 3, 8), end: date(2026, 11, 3, 9, 30), touches: day, calendar: berlin))
        XCTAssertTrue(CalendarDates.timed(start: date(2026, 11, 2, 22), end: date(2026, 11, 3, 1), touches: day, calendar: berlin))
        XCTAssertFalse(CalendarDates.timed(start: date(2026, 11, 2, 22), end: date(2026, 11, 3), touches: day, calendar: berlin))
        XCTAssertTrue(CalendarDates.timed(start: date(2026, 11, 3, 10), end: date(2026, 11, 3, 10), touches: day, calendar: berlin))
        // All-day: exclusive end day.
        XCTAssertTrue(CalendarDates.allDay(start: date(2026, 11, 2), endExclusive: date(2026, 11, 4), covers: day, calendar: berlin))
        XCTAssertFalse(CalendarDates.allDay(start: date(2026, 11, 2), endExclusive: date(2026, 11, 3), covers: day, calendar: berlin))
        // A missing/equal end still covers the start day.
        XCTAssertTrue(CalendarDates.allDay(start: day, endExclusive: day, covers: day, calendar: berlin))
        let week = CalendarDates.weekDays(containing: day, count: 5, calendar: berlin)
        XCTAssertTrue(CalendarAllDayLayout.columns(start: date(2026, 10, 30), endExclusive: date(2026, 11, 3), days: week, calendar: berlin)! == (0, 0))
        XCTAssertTrue(CalendarAllDayLayout.columns(start: date(2026, 11, 4), endExclusive: date(2026, 11, 14), days: week, calendar: berlin)! == (2, 4))
        XCTAssertNil(CalendarAllDayLayout.columns(start: date(2026, 11, 7), endExclusive: date(2026, 11, 9), days: week, calendar: berlin))
    }

    func testOverlappingOccurrencesShareColumns() {
        // 08:00–09:30, 08:45–09:45, 09:00–10:00 overlap; 10:00–11:00 stands alone.
        let placed = CalendarOverlapLayout.place([(480, 570), (525, 585), (540, 600), (600, 660)])
        XCTAssertEqual(placed, [.init(column: 0, columns: 3), .init(column: 1, columns: 3), .init(column: 2, columns: 3), .init(column: 0, columns: 1)])
        // A freed column is reused while the group continues.
        let chain = CalendarOverlapLayout.place([(60, 120), (0, 60), (30, 90)])
        XCTAssertEqual(chain, [.init(column: 0, columns: 2), .init(column: 0, columns: 2), .init(column: 1, columns: 2)])
        // Zero-length entries count with the drawn minimum height.
        let short = CalendarOverlapLayout.place([(600, 600), (605, 640)], minimumLength: 15)
        XCTAssertEqual(short.map(\.columns), [2, 2])
        XCTAssertEqual(CalendarOverlapLayout.place([(600, 600), (620, 640)], minimumLength: 15).map(\.columns), [1, 1])
        XCTAssertEqual(CalendarOverlapLayout.place([]), [])
        // Identical slots: input order decides the columns.
        XCTAssertEqual(CalendarOverlapLayout.place([(0, 30), (0, 30)]).map(\.column), [0, 1])
    }

    func testAllDayLanes() {
        XCTAssertEqual(CalendarAllDayLayout.lanes([(0, 4), (1, 1), (2, 3), (4, 4)]), [0, 1, 1, 1])
        XCTAssertEqual(CalendarAllDayLayout.lanes([(1, 1), (0, 2)]), [1, 0])
        XCTAssertEqual(CalendarAllDayLayout.lanes([]), [])
    }

    func testMonthOverflowNeverDropsEntries() {
        XCTAssertTrue(CalendarOverflow.split(total: 5, capacity: 3) == (2, 3))
        XCTAssertTrue(CalendarOverflow.split(total: 3, capacity: 3) == (3, 0))
        XCTAssertTrue(CalendarOverflow.split(total: 2, capacity: 0) == (0, 2))
        XCTAssertTrue(CalendarOverflow.split(total: 2, capacity: 1) == (0, 2))
        XCTAssertTrue(CalendarOverflow.split(total: 0, capacity: 2) == (0, 0))
        for total in 0...12 {
            for capacity in -1...8 {
                let split = CalendarOverflow.split(total: total, capacity: capacity)
                XCTAssertEqual(split.shown + split.hidden, total)
                XCTAssertLessThanOrEqual(split.shown + (split.hidden > 0 ? 1 : 0), max(capacity, split.hidden > 0 ? 1 : 0))
                XCTAssertTrue(split.hidden == 0 || split.hidden >= 2 || capacity <= 1, "„+ 1 weitere“ would replace exactly one entry")
            }
        }
    }

    func testSubjectColoursAreStable() {
        let a = CalendarSubjectColor.index(for: "Rechnungswesen", paletteCount: 8)
        XCTAssertEqual(a, CalendarSubjectColor.index(for: "rechnungswesen", paletteCount: 8))
        XCTAssertTrue((0..<8).contains(a))
        // FNV-1a, fixed for every launch (not Swift's seeded hash).
        XCTAssertEqual(CalendarSubjectColor.index(for: "a", paletteCount: 1_000_000), Int(UInt32(0xE40C292C) % 1_000_000))
        XCTAssertEqual(CalendarSubjectColor.index(for: "x", paletteCount: 0), 0)
    }

    func testGermanTitles() {
        let tuesday = date(2026, 11, 3, 8, 5)
        XCTAssertEqual(CalendarText.title(.week, anchor: tuesday, weekDays: 5, calendar: berlin), "KW 45 · 2.–6. November 2026")
        XCTAssertEqual(CalendarText.title(.week, anchor: tuesday, weekDays: 7, calendar: berlin), "KW 45 · 2.–8. November 2026")
        XCTAssertEqual(CalendarText.title(.week, anchor: date(2026, 10, 28), weekDays: 7, calendar: berlin), "KW 44 · 26. Okt. – 1. Nov. 2026")
        XCTAssertEqual(CalendarText.title(.week, anchor: date(2027, 1, 2), weekDays: 5, calendar: berlin), "KW 53 · 28. Dez. 2026 – 1. Jan. 2027")
        XCTAssertEqual(CalendarText.title(.month, anchor: tuesday, weekDays: 5, calendar: berlin), "November 2026")
        XCTAssertEqual(CalendarText.title(.year, anchor: tuesday, weekDays: 5, calendar: berlin), "2026")
        XCTAssertEqual(CalendarText.title(.day, anchor: tuesday, weekDays: 5, calendar: berlin), "Dienstag, 3. November 2026")
        XCTAssertEqual(CalendarText.shortDate(tuesday, calendar: berlin), "Di, 3. Nov.")
        XCTAssertEqual(CalendarText.numericDate(tuesday, calendar: berlin), "03.11.2026")
        XCTAssertEqual(CalendarText.clock(tuesday, calendar: berlin), "08:05")
        XCTAssertEqual(CalendarText.clock(date(2026, 11, 3, 23, 59), calendar: berlin), "23:59")
        XCTAssertEqual(CalendarText.timeRange(date(2026, 11, 3, 8), date(2026, 11, 3, 9, 30), calendar: berlin), "08:00–09:30")
        XCTAssertEqual(CalendarText.timeRange(date(2026, 11, 3, 22), date(2026, 11, 4, 1), calendar: berlin), "22:00 – Mi 01:00")
        XCTAssertEqual(CalendarText.dayRange(tuesday, tuesday, calendar: berlin), "3. November 2026")
        XCTAssertEqual(CalendarText.headline(.week, anchor: tuesday, weekDays: 5, calendar: berlin), "November 2026")
        XCTAssertEqual(CalendarText.headline(.week, anchor: date(2026, 10, 28), weekDays: 5, calendar: berlin), "Oktober 2026")
        XCTAssertEqual(CalendarText.headline(.week, anchor: date(2026, 10, 28), weekDays: 7, calendar: berlin), "Okt. – Nov. 2026")
        XCTAssertEqual(CalendarText.headline(.week, anchor: date(2027, 1, 2), weekDays: 5, calendar: berlin), "Dez. 2026 – Jan. 2027")
        XCTAssertEqual(CalendarText.headline(.month, anchor: tuesday, weekDays: 5, calendar: berlin), "November 2026")
        XCTAssertEqual(CalendarText.headline(.year, anchor: tuesday, weekDays: 5, calendar: berlin), "2026")
        XCTAssertEqual(CalendarText.headline(.day, anchor: tuesday, weekDays: 5, calendar: berlin), "3. November 2026")
        XCTAssertEqual(CalendarText.more(3), "+ 3 weitere")
        XCTAssertEqual(CalendarText.more(1), "+ 1 weiterer", "ein Termin: maskulin")
        XCTAssertEqual(CalendarText.shortDay(tuesday, calendar: berlin), "Di 3.11.")
        XCTAssertEqual(CalendarText.minuteOfDay(tuesday, calendar: berlin), 8 * 60 + 5)
        XCTAssertEqual(CalendarText.clock(minuteOfDay: 8 * 60 + 5), "08:05")
        XCTAssertEqual(CalendarText.clock(minuteOfDay: 21 * 60), "21:00")
        XCTAssertEqual(CalendarText.clock(minuteOfDay: 24 * 60 + 30), "00:30")
        XCTAssertEqual(CalendarText.numericDate(CivilDate("2026-11-03")!), "03.11.2026")
        XCTAssertEqual(CalendarMode.allCases.map(\.title), ["Jahr", "Monat", "Woche", "Tag"])
    }
}
