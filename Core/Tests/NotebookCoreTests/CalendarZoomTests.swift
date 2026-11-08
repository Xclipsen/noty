import XCTest
@testable import NotebookCore

/// Zoom zwischen Ansichten (docs/CALENDAR-PLAN.md, 08.11.2026).
final class CalendarZoomTests: XCTestCase {
    private let berlin = CalendarDates.german(timeZone: TimeZone(identifier: "Europe/Berlin")!)

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0) -> Date {
        berlin.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
    }
    private func step(_ direction: CalendarZoom.Direction, _ mode: CalendarMode, anchor: Date, target: Date?,
                      today: Date? = nil) -> CalendarZoom.Step? {
        CalendarZoom.step(direction, from: mode, anchor: anchor, target: target, today: today ?? date(2026, 11, 8), calendar: berlin)
    }

    func testModeOrder() {
        XCTAssertEqual(CalendarMode.year.finer, .month)
        XCTAssertEqual(CalendarMode.month.finer, .week)
        XCTAssertEqual(CalendarMode.week.finer, .day)
        XCTAssertNil(CalendarMode.day.finer)
        XCTAssertEqual(CalendarMode.day.coarser, .week)
        XCTAssertEqual(CalendarMode.week.coarser, .month)
        XCTAssertEqual(CalendarMode.month.coarser, .year)
        XCTAssertNil(CalendarMode.year.coarser)
        for mode in CalendarMode.allCases {
            if let finer = mode.finer { XCTAssertEqual(finer.coarser, mode) }
        }
    }

    func testZoomInOpensThePeriodUnderTheFingers() {
        // Year 2026, anchor in March, today in November: pinch on June opens June (its 1st).
        XCTAssertEqual(step(.zoomIn, .year, anchor: date(2026, 3, 5, 14), target: date(2026, 6, 1)),
                       .init(mode: .month, anchor: date(2026, 6, 1)))
        // Pinch on March keeps the anchor day, on November goes to today.
        XCTAssertEqual(step(.zoomIn, .year, anchor: date(2026, 3, 5), target: date(2026, 3, 1)),
                       .init(mode: .month, anchor: date(2026, 3, 5)))
        XCTAssertEqual(step(.zoomIn, .year, anchor: date(2026, 3, 5), target: date(2026, 11, 1)),
                       .init(mode: .month, anchor: date(2026, 11, 8)))
        // Month → the week row (its Monday, also from the previous month).
        XCTAssertEqual(step(.zoomIn, .month, anchor: date(2026, 12, 15), target: date(2026, 11, 30)),
                       .init(mode: .week, anchor: date(2026, 11, 30)))
        // Week → exactly that day, even if anchor or today lie in the week.
        XCTAssertEqual(step(.zoomIn, .week, anchor: date(2026, 11, 3), target: date(2026, 11, 5)),
                       .init(mode: .day, anchor: date(2026, 11, 5)))
        XCTAssertNil(step(.zoomIn, .day, anchor: date(2026, 11, 5), target: nil))
    }

    func testKeyboardZoomKeepsTheAnchor() {
        XCTAssertEqual(step(.zoomIn, .year, anchor: date(2026, 3, 5, 9), target: nil), .init(mode: .month, anchor: date(2026, 3, 5)))
        XCTAssertEqual(step(.zoomIn, .month, anchor: date(2026, 3, 5), target: nil), .init(mode: .week, anchor: date(2026, 3, 5)))
        XCTAssertEqual(step(.zoomOut, .day, anchor: date(2026, 3, 5, 9), target: nil), .init(mode: .week, anchor: date(2026, 3, 5)))
        XCTAssertEqual(step(.zoomOut, .week, anchor: date(2026, 3, 5), target: nil), .init(mode: .month, anchor: date(2026, 3, 5)))
        XCTAssertEqual(step(.zoomOut, .month, anchor: date(2026, 3, 5), target: nil), .init(mode: .year, anchor: date(2026, 3, 5)))
        XCTAssertNil(step(.zoomOut, .year, anchor: date(2026, 3, 5), target: nil))
        // Zooming out ignores a target: the anchor's period is highlighted instead.
        XCTAssertEqual(step(.zoomOut, .week, anchor: date(2026, 3, 5), target: date(2027, 1, 1)), .init(mode: .month, anchor: date(2026, 3, 5)))
    }

    func testRoundTripReturnsToTheSamePeriod() {
        // ⌘- then ⌘+ lands where it started.
        let anchor = date(2026, 11, 4)
        for mode in [CalendarMode.day, .week, .month] {
            let out = step(.zoomOut, mode, anchor: anchor, target: nil)!
            let back = step(.zoomIn, out.mode, anchor: out.anchor, target: CalendarZoom.focus(mode, anchor: anchor, calendar: berlin))!
            XCTAssertEqual(back.mode, mode)
            XCTAssertEqual(CalendarDates.range(mode, anchor: back.anchor, weekDays: 7, calendar: berlin).start,
                           CalendarDates.range(mode, anchor: anchor, weekDays: 7, calendar: berlin).start)
        }
    }

    func testFocusKeysMatchTheCoarserView() {
        // Saturday 31.10.2026: its week row starts Monday 26.10. (in the month grid).
        let saturday = date(2026, 10, 31, 18)
        XCTAssertEqual(CalendarZoom.focus(.week, anchor: saturday, calendar: berlin), date(2026, 10, 26))
        XCTAssertEqual(CalendarZoom.focus(.month, anchor: saturday, calendar: berlin), date(2026, 10, 1))
        XCTAssertEqual(CalendarZoom.focus(.day, anchor: saturday, calendar: berlin), date(2026, 10, 31))
        XCTAssertEqual(CalendarZoom.focus(.year, anchor: saturday, calendar: berlin), date(2026, 1, 1))
        let grid = CalendarMonthGrid(month: saturday, calendar: berlin)
        XCTAssertTrue(grid.weeks.contains { $0.days.first == CalendarZoom.focus(.week, anchor: saturday, calendar: berlin) })
        // DST change (25.10.2026) does not shift the keys.
        XCTAssertEqual(CalendarZoom.focus(.week, anchor: date(2026, 10, 25, 12), calendar: berlin), date(2026, 10, 19))
    }

    func testTargetHitTesting() {
        let a = CalendarZoom.Frame(start: date(2026, 1, 1), minX: 0, minY: 0, maxX: 100, maxY: 100)
        let b = CalendarZoom.Frame(start: date(2026, 2, 1), minX: 120, minY: 0, maxX: 220, maxY: 100)
        let c = CalendarZoom.Frame(start: date(2026, 3, 1), minX: 0, minY: 130, maxX: 100, maxY: 230)
        let frames = [b, c, a]
        XCTAssertEqual(CalendarZoom.target(atX: 50, y: 50, in: frames), a.start)
        XCTAssertEqual(CalendarZoom.target(atX: 150, y: 90, in: frames), b.start)
        // Between tiles: the nearest one.
        XCTAssertEqual(CalendarZoom.target(atX: 50, y: 120, in: frames), c.start)
        XCTAssertEqual(CalendarZoom.target(atX: 105, y: 50, in: frames), a.start)
        // Exactly in the middle: the earlier period, independent of order.
        XCTAssertEqual(CalendarZoom.target(atX: 110, y: 50, in: frames), a.start)
        XCTAssertEqual(CalendarZoom.target(atX: 110, y: 50, in: frames.reversed()), a.start)
        XCTAssertNil(CalendarZoom.target(atX: 0, y: 0, in: []))
        // Day columns: only the head is reported, any height below it counts.
        let monday = CalendarZoom.Frame(start: date(2026, 11, 2), minX: 52, minY: 0, maxX: 200, maxY: 58)
        let tuesday = CalendarZoom.Frame(start: date(2026, 11, 3), minX: 200, minY: 0, maxX: 348, maxY: 58)
        XCTAssertEqual(CalendarZoom.target(atX: 260, y: 700, in: [monday, tuesday], horizontalOnly: true), tuesday.start)
    }

    func testPinchThresholds() {
        XCTAssertNil(CalendarPinch.direction(1))
        XCTAssertNil(CalendarPinch.direction(1.15))
        XCTAssertNil(CalendarPinch.direction(0.9))
        XCTAssertEqual(CalendarPinch.direction(1.2), .zoomIn)
        XCTAssertEqual(CalendarPinch.direction(1 / 1.2), .zoomOut)
        XCTAssertNil(CalendarPinch.direction(1.4, decisive: true))
        XCTAssertEqual(CalendarPinch.direction(1.6, decisive: true), .zoomIn)
        XCTAssertEqual(CalendarPinch.direction(0.6, decisive: true), .zoomOut)
        XCTAssertNil(CalendarPinch.direction(.nan))
        XCTAssertNil(CalendarPinch.direction(0))
    }

    func testPinchFeedbackStaysAHint() {
        XCTAssertEqual(CalendarPinch.feedbackScale(1, possible: true), 1, accuracy: 1e-9)
        XCTAssertGreaterThan(CalendarPinch.feedbackScale(1.2, possible: true), 1)
        XCTAssertLessThan(CalendarPinch.feedbackScale(0.8, possible: true), 1)
        // Monotonic and bounded.
        var last = 0.0
        for m in stride(from: 0.2, through: 5, by: 0.1) {
            let s = CalendarPinch.feedbackScale(m, possible: true)
            XCTAssertGreaterThanOrEqual(s, last)
            XCTAssertLessThanOrEqual(abs(s - 1), CalendarPinch.maximumFeedback + 1e-9)
            last = s
        }
        // Symmetric in log space; the end of the scale only gives way a little.
        XCTAssertEqual(CalendarPinch.feedbackScale(1.5, possible: true) - 1, 1 - CalendarPinch.feedbackScale(1 / 1.5, possible: true), accuracy: 1e-9)
        XCTAssertLessThan(abs(CalendarPinch.feedbackScale(3, possible: false) - 1), CalendarPinch.maximumFeedback / 2)
        XCTAssertEqual(CalendarPinch.feedbackScale(.infinity, possible: true), 1)
    }
}
