import XCTest
@testable import NotebookCore

/// Termin per Halten und Ziehen anlegen (docs/CALENDAR-PLAN.md, 08.11.2026).
final class CalendarCreationTests: XCTestCase {
    private let berlin = CalendarDates.german(timeZone: TimeZone(identifier: "Europe/Berlin")!)

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0) -> Date {
        berlin.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }
    private func utc(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int = 0) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }
    private typealias Cell = CalendarCreation.Cell
    private typealias Span = CalendarCreation.Span

    func testCellSnapsDownToTheQuarterHourAndClampsToTheDay() {
        XCTAssertEqual(CalendarCreation.cell(day: 2, minutes: 9 * 60 + 14.9, dayCount: 5), Cell(day: 2, minute: 9 * 60))
        XCTAssertEqual(CalendarCreation.cell(day: 2, minutes: 9 * 60 + 15, dayCount: 5), Cell(day: 2, minute: 9 * 60 + 15))
        // Above 0:00 and below 24:00 (finger in the inset or past the grid).
        XCTAssertEqual(CalendarCreation.cell(day: 0, minutes: -40, dayCount: 5), Cell(day: 0, minute: 0))
        XCTAssertEqual(CalendarCreation.cell(day: 0, minutes: 24 * 60 + 30, dayCount: 5), Cell(day: 0, minute: 23 * 60 + 45))
        XCTAssertEqual(CalendarCreation.cell(day: 0, minutes: 24 * 60, dayCount: 5), Cell(day: 0, minute: 23 * 60 + 45))
        // Columns outside the shown days and non-finite values.
        XCTAssertEqual(CalendarCreation.cell(day: 9, minutes: 60, dayCount: 5), Cell(day: 4, minute: 60))
        XCTAssertEqual(CalendarCreation.cell(day: -1, minutes: .nan, dayCount: 5), Cell(day: 0, minute: 0))
        XCTAssertEqual(CalendarCreation.cell(day: 0, minutes: 60, dayCount: 0), Cell(day: 0, minute: 60))
    }

    func testSpanCoversBothCellsInEitherOrderAndAtLeastOneStep() {
        let press = Cell(day: 1, minute: 9 * 60 + 15)
        // Held without moving: one cell, 15 minutes.
        XCTAssertEqual(CalendarCreation.span(from: press, to: press), Span(startDay: 1, startMinute: 555, endDay: 1, endMinute: 570))
        // Down: the press starts, the finger's cell ends (included).
        XCTAssertEqual(CalendarCreation.span(from: press, to: Cell(day: 1, minute: 10 * 60 + 15)),
                       Span(startDay: 1, startMinute: 555, endDay: 1, endMinute: 630))
        // Up: start and end swap – the finger starts, the pressed cell ends.
        XCTAssertEqual(CalendarCreation.span(from: press, to: Cell(day: 1, minute: 8 * 60)),
                       Span(startDay: 1, startMinute: 480, endDay: 1, endMinute: 570))
        // The last cell of the day ends at 24:00.
        XCTAssertEqual(CalendarCreation.span(from: Cell(day: 0, minute: 23 * 60), to: Cell(day: 0, minute: 23 * 60 + 45)),
                       Span(startDay: 0, startMinute: 1380, endDay: 0, endMinute: 1440))
        for span in [CalendarCreation.span(from: press, to: press), CalendarCreation.span(from: press, to: Cell(day: 0, minute: 0))] {
            XCTAssertGreaterThanOrEqual((span.endDay - span.startDay) * 1440 + span.endMinute - span.startMinute, CalendarCreation.minimumMinutes)
        }
    }

    func testSpanOverSeveralDaysFollowsDayAndTime() {
        // Mo 09:00 pressed, finger on We 10:45: Mo 09:00 – We 11:00.
        let forward = CalendarCreation.span(from: Cell(day: 0, minute: 540), to: Cell(day: 2, minute: 645))
        XCTAssertEqual(forward, Span(startDay: 0, startMinute: 540, endDay: 2, endMinute: 660))
        XCTAssertTrue(forward.spansDays)
        // Backwards to the day before, later on that day: still the earlier day starts.
        let back = CalendarCreation.span(from: Cell(day: 2, minute: 540), to: Cell(day: 1, minute: 900))
        XCTAssertEqual(back, Span(startDay: 1, startMinute: 900, endDay: 2, endMinute: 555))
        // Segments per day column (the placeholder draws them).
        XCTAssertEqual(forward.segment(on: 0).map { [$0.start, $0.end] }, [540, 1440])
        XCTAssertEqual(forward.segment(on: 1).map { [$0.start, $0.end] }, [0, 1440])
        XCTAssertEqual(forward.segment(on: 2).map { [$0.start, $0.end] }, [0, 660])
        XCTAssertNil(forward.segment(on: 3))
        // Ending at 24:00 of the same day is one day.
        XCTAssertFalse(Span(startDay: 0, startMinute: 1380, endDay: 0, endMinute: 1440).spansDays)
        XCTAssertFalse(Span(startDay: 0, startMinute: 1380, endDay: 1, endMinute: 0).spansDays)
        XCTAssertNil(Span(startDay: 0, startMinute: 1380, endDay: 1, endMinute: 0).segment(on: 1))
    }

    func testColumnChangesOnlyClearlyBeyondTheBorder() {
        // Columns 100 pt wide, 5 days.
        XCTAssertEqual(CalendarCreation.column(x: 150, width: 100, count: 5, current: nil), 1)
        // 10 pt into the next column: stays (hysteresis 16 pt).
        XCTAssertEqual(CalendarCreation.column(x: 210, width: 100, count: 5, current: 1), 1)
        XCTAssertEqual(CalendarCreation.column(x: 90, width: 100, count: 5, current: 1), 1)
        // Clearly beyond: changes.
        XCTAssertEqual(CalendarCreation.column(x: 220, width: 100, count: 5, current: 1), 2)
        XCTAssertEqual(CalendarCreation.column(x: 80, width: 100, count: 5, current: 1), 0)
        // Far away jumps directly; outside the grid clamps.
        XCTAssertEqual(CalendarCreation.column(x: 450, width: 100, count: 5, current: 1), 4)
        XCTAssertEqual(CalendarCreation.column(x: 900, width: 100, count: 5, current: 1), 4)
        XCTAssertEqual(CalendarCreation.column(x: -30, width: 100, count: 5, current: 3), 0)
        // One column (day view): always 0.
        XCTAssertEqual(CalendarCreation.column(x: 500, width: 300, count: 1, current: 0), 0)
        XCTAssertEqual(CalendarCreation.column(x: .infinity, width: 100, count: 5, current: 2), 2)
    }

    func testAllDayRangesAndMonthGridIndex() {
        XCTAssertEqual(CalendarCreation.days(from: 3, to: 1, count: 7), 1...3)
        XCTAssertEqual(CalendarCreation.days(from: 2, to: 2, count: 7), 2...2)
        XCTAssertEqual(CalendarCreation.days(from: 5, to: 40, count: 35), 5...34)
        XCTAssertEqual(CalendarCreation.days(from: -2, to: 3, count: 7), 0...3)
        // Month: 7 columns of 100 pt, rows of 80 pt; row-major like reading.
        XCTAssertEqual(CalendarCreation.gridIndex(x: 250, y: 90, cellWidth: 100, cellHeight: 80, columns: 7, rows: 5), 9)
        XCTAssertEqual(CalendarCreation.gridIndex(x: -10, y: -10, cellWidth: 100, cellHeight: 80, columns: 7, rows: 5), 0)
        XCTAssertEqual(CalendarCreation.gridIndex(x: 9_999, y: 9_999, cellWidth: 100, cellHeight: 80, columns: 7, rows: 5), 34)
        XCTAssertEqual(CalendarCreation.gridIndex(x: 10, y: 10, cellWidth: 0, cellHeight: 80, columns: 7, rows: 5), 0)
    }

    func testDatesUseTheWallClockOfTheShownDays() {
        let days = CalendarDates.weekDays(containing: date(2026, 11, 9), count: 5, calendar: berlin)
        let span = CalendarCreation.span(from: Cell(day: 0, minute: 9 * 60 + 15), to: Cell(day: 0, minute: 10 * 60 + 15))
        let dates = CalendarCreation.dates(span, days: days, calendar: berlin)
        XCTAssertEqual(dates?.start, date(2026, 11, 9, 9, 15))
        XCTAssertEqual(dates?.end, date(2026, 11, 9, 10, 30))
        // Ends at 24:00: the start of the next day.
        let late = CalendarCreation.dates(Span(startDay: 4, startMinute: 1380, endDay: 4, endMinute: 1440), days: days, calendar: berlin)
        XCTAssertEqual(late?.end, date(2026, 11, 14))
        // Over several days.
        let multi = CalendarCreation.dates(Span(startDay: 0, startMinute: 540, endDay: 2, endMinute: 660), days: days, calendar: berlin)
        XCTAssertEqual(multi?.start, date(2026, 11, 9, 9))
        XCTAssertEqual(multi?.end, date(2026, 11, 11, 11))
        // Outside the shown days: nothing.
        XCTAssertNil(CalendarCreation.dates(Span(startDay: 0, startMinute: 0, endDay: 5, endMinute: 15), days: days, calendar: berlin))
    }

    func testDaylightSavingSpringForward() {
        // 29.03.2026, Berlin: 02:00 CET → 03:00 CEST; 02:00–02:59 do not exist.
        let sunday = date(2026, 3, 29)
        XCTAssertEqual(CalendarCreation.instant(minute: 60, of: sunday, calendar: berlin), utc(2026, 3, 29, 0))
        XCTAssertEqual(CalendarCreation.instant(minute: 150, of: sunday, calendar: berlin), utc(2026, 3, 29, 1), "02:30 → 03:00")
        XCTAssertEqual(CalendarCreation.instant(minute: 120, of: sunday, calendar: berlin), utc(2026, 3, 29, 1), "02:00 → 03:00")
        XCTAssertEqual(CalendarCreation.instant(minute: 180, of: sunday, calendar: berlin), utc(2026, 3, 29, 1))
        XCTAssertEqual(CalendarCreation.instant(minute: 195, of: sunday, calendar: berlin), utc(2026, 3, 29, 1, 15))
        // Both ends in the gap: the end still lies after the start.
        let gap = CalendarCreation.dates(Span(startDay: 0, startMinute: 135, endDay: 0, endMinute: 165), days: [sunday], calendar: berlin)!
        XCTAssertEqual(gap.start, utc(2026, 3, 29, 1))
        XCTAssertEqual(gap.end.timeIntervalSince(gap.start), 15 * 60)
        // 01:00–04:00 on the wall clock is two real hours.
        let short = CalendarCreation.dates(Span(startDay: 0, startMinute: 60, endDay: 0, endMinute: 240), days: [sunday], calendar: berlin)!
        XCTAssertEqual(short.end.timeIntervalSince(short.start), 2 * 3_600)
    }

    func testDaylightSavingFallBack() {
        // 25.10.2026, Berlin: 03:00 CEST → 02:00 CET; 02:00–02:59 happen twice.
        let sunday = date(2026, 10, 25)
        XCTAssertEqual(CalendarCreation.instant(minute: 150, of: sunday, calendar: berlin), utc(2026, 10, 25, 0, 30), "the first 02:30")
        XCTAssertEqual(CalendarCreation.instant(minute: 120, of: sunday, calendar: berlin), utc(2026, 10, 25, 0))
        XCTAssertEqual(CalendarCreation.instant(minute: 180, of: sunday, calendar: berlin), utc(2026, 10, 25, 2))
        XCTAssertEqual(CalendarCreation.instant(minute: 1440, of: sunday, calendar: berlin), date(2026, 10, 26))
        XCTAssertEqual(CalendarCreation.instant(minute: 0, of: sunday, calendar: berlin), sunday)
        // 01:00–04:00 on the wall clock is four real hours.
        let long = CalendarCreation.dates(Span(startDay: 0, startMinute: 60, endDay: 0, endMinute: 240), days: [sunday], calendar: berlin)!
        XCTAssertEqual(long.end.timeIntervalSince(long.start), 4 * 3_600)
        // An ordinary day keeps exact minutes.
        XCTAssertEqual(CalendarCreation.instant(minute: 9 * 60 + 45, of: date(2026, 10, 26), calendar: berlin), date(2026, 10, 26, 9, 45))
    }

    func testDatesAreValidTimingForTheForm() {
        // Whatever the drag gives, the timing passes the form's checks.
        let days = CalendarDates.weekDays(containing: date(2026, 3, 26), count: 7, calendar: berlin)
        for (a, b) in [(Cell(day: 3, minute: 120), Cell(day: 3, minute: 135)), (Cell(day: 6, minute: 1425), Cell(day: 0, minute: 0)),
                       (Cell(day: 0, minute: 0), Cell(day: 6, minute: 1425))] {
            let span = CalendarCreation.span(from: a, to: b)
            let dates = try! XCTUnwrap(CalendarCreation.dates(span, days: days, calendar: berlin))
            XCTAssertGreaterThan(dates.end, dates.start)
            XCTAssertNil(CalendarEventTiming.timed(start: dates.start, end: dates.end, timeZone: "Europe/Berlin").problem)
        }
    }

    func testLabels() {
        XCTAssertEqual(CalendarCreation.label(start: date(2026, 11, 9, 9, 15), end: date(2026, 11, 9, 10, 30), calendar: berlin), "09:15–10:30")
        XCTAssertEqual(CalendarCreation.label(start: date(2026, 11, 9, 23), end: date(2026, 11, 10), calendar: berlin), "23:00–24:00")
        XCTAssertEqual(CalendarCreation.label(start: date(2026, 11, 9, 9), end: date(2026, 11, 11, 11), calendar: berlin), "Mo 09:00 – Mi 11:00")
        XCTAssertEqual(CalendarCreation.label(start: date(2026, 11, 9, 9), end: date(2026, 11, 12), calendar: berlin), "Mo 09:00 – Mi 24:00")
        XCTAssertEqual(CalendarCreation.allDayLabel(days: 1), "Ganztägig")
        XCTAssertEqual(CalendarCreation.allDayLabel(days: 3), "Ganztägig · 3 Tage")
    }
}
