import XCTest
@testable import NotebookCore

/// Start hour of the week/day grid (`CalendarScrollStart`): entries in view,
/// a running school day, no entries, clamping and the conversion from dates.
final class CalendarScrollStartTests: XCTestCase {
    private typealias Item = CalendarScrollStart.Item
    private func item(_ day: Int, _ start: String, _ end: String) -> Item {
        func minutes(_ text: String) -> Int {
            let parts = text.split(separator: ":").map { Int($0)! }
            return parts[0] * 60 + parts[1]
        }
        return Item(day: day, start: minutes(start), end: minutes(end))
    }
    private func hour(_ items: [Item], today: (Int, String)? = nil) -> Int {
        CalendarScrollStart.hour(items: items, today: today.map { (day: $0.0, minute: item(0, $0.1, $0.1).start) })
    }
    /// Monday to Friday, lessons 8:00–13:15, Wednesday from 7:45.
    private var schoolWeek: [Item] {
        (0..<5).flatMap { day in [item(day, day == 2 ? "07:45" : "08:00", "09:30"), item(day, "09:50", "11:20"), item(day, "11:40", "13:15")] }
    }

    func testEarliestStartMinusHalfAnHourOnTheFullHour() {
        XCTAssertEqual(hour([item(0, "08:00", "09:30")]), 7)
        XCTAssertEqual(hour([item(0, "08:30", "09:30")]), 8)
        XCTAssertEqual(hour([item(0, "08:29", "09:30")]), 7)
        XCTAssertEqual(hour(schoolWeek), 7, "7:45 am Mittwoch: 7:15 → 7:00")
        XCTAssertEqual(hour([item(3, "14:00", "15:00"), item(1, "16:00", "17:00")]), 13, "frühester Beginn aller gezeigten Tage")
        XCTAssertEqual(hour([item(0, "00:10", "01:00")]), 0, "nie vor 0 Uhr")
        XCTAssertEqual(hour([item(0, "23:40", "24:00")]), 23)
    }

    func testWithoutEntriesSevenOrNowMinusAnHour() {
        XCTAssertEqual(hour([]), 7)
        XCTAssertEqual(hour([], today: (2, "14:20")), 13)
        XCTAssertEqual(hour([], today: (0, "00:30")), 0)
        XCTAssertEqual(hour([item(0, "09:00", "09:00")]), 7, "Termin ohne Dauer zählt nicht")
    }

    func testRunningDayMovesOnButKeepsWhatIsNotOver() {
        // Day view of today, lessons until 13:15.
        let day = [item(0, "08:00", "09:30"), item(0, "09:50", "11:20"), item(0, "11:40", "13:15")]
        XCTAssertEqual(hour(day, today: (0, "07:10")), 7, "vor Schulbeginn: erste Stunde")
        XCTAssertEqual(hour(day, today: (0, "10:15")), 9, "jetzt − 1 h, laufende Stunde ab 9:50 bleibt sichtbar")
        XCTAssertEqual(hour(day, today: (0, "12:30")), 11, "nächste/laufende Stunde 11:40 begrenzt: 11:10 → 11")
        XCTAssertEqual(hour(day, today: (0, "18:00")), 7, "Tag vorbei: wieder die Termine")
        // A long block that started long ago stays in view from its start.
        XCTAssertEqual(hour([item(0, "08:00", "14:00")], today: (0, "12:00")), 7)
        // School week, today Wednesday: Thursday's 8:00 is not over yet.
        XCTAssertEqual(hour(schoolWeek, today: (2, "10:30")), 7)
        // Friday (last day shown): the past days' mornings scroll away.
        XCTAssertEqual(hour(schoolWeek, today: (4, "10:30")), 9)
        // Today shown without own entries, entries on another day: the entries rule.
        XCTAssertEqual(hour([item(1, "08:00", "09:00")], today: (0, "15:00")), 7)
    }

    func testItemsFromDatesClampToEachShownDay() {
        let calendar = CalendarDates.german(timeZone: TimeZone(identifier: "Europe/Berlin")!)
        func at(_ d: Int, _ h: Int, _ m: Int = 0) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: 11, day: d, hour: h, minute: m))!
        }
        let days = [at(9, 0), at(10, 0), at(11, 0)]
        let items = CalendarScrollStart.items(days: days, entries: [
            (at(9, 8), at(9, 9, 30)),       // Monday
            (at(10, 22), at(11, 1, 30)),    // over midnight: Tuesday until 24:00, Wednesday from 0:00
            (at(12, 8), at(12, 9)),         // not shown
        ], calendar: calendar)
        XCTAssertEqual(items, [Item(day: 0, start: 480, end: 570), Item(day: 1, start: 1320, end: 1440), Item(day: 2, start: 0, end: 90)])
        // Daylight saving end (25.10.2026): wall-clock minutes.
        let dst = CalendarScrollStart.items(days: [at(25, 0)], entries: [(at(25, 8), at(25, 9))], calendar: calendar)
        XCTAssertEqual(dst, [Item(day: 0, start: 480, end: 540)])
    }
}
