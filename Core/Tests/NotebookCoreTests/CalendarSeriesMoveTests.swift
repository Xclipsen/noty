import XCTest
@testable import NotebookCore

/// „Alle Termine“ of a monthly series: exceptions, changed occurrences, the
/// end date, note links, topics and „Gelöschte Termine“ follow their
/// occurrence (the n-th of the series), not the civil days the first
/// occurrence moved – a month end makes the two differ. Daily and weekly
/// series keep the plain day shift. Fictitious data only.
final class CalendarSeriesMoveTests: XCTestCase {
    private func day(_ text: String) -> CivilDate { CivilDate(text)! }
    private func allDay(_ text: String) -> CalendarEventTiming { .allDay(start: day(text), end: day(text).adding(days: 1)) }
    private func series(_ timing: CalendarEventTiming, _ rule: CalendarRecurrence, id: UUID = UUID()) -> LocalCalendarEvent {
        LocalCalendarEvent(id: id, title: "Miete", timing: timing, recurrence: rule, createdAt: Date(timeIntervalSince1970: 1_790_000_000))
    }
    private func shown(_ timing: CalendarEventTiming, _ rule: CalendarRecurrence, _ from: String, _ to: String) -> [CalendarOccurrence] {
        CalendarSeries.expand([series(timing, rule)], from: day(from), to: day(to)).occurrences
    }
    private func dates(_ timing: CalendarEventTiming, _ rule: CalendarRecurrence, _ from: String, _ to: String) -> [CivilDate] {
        shown(timing, rule, from, to).compactMap(\.originalDate).sorted()
    }
    private func changed(_ original: String, on shownDay: String? = nil) -> CalendarOccurrenceOverride {
        CalendarOccurrenceOverride(originalDate: day(original), title: "Geändert", timing: allDay(shownDay ?? original))
    }

    // MARK: One day across a month end, there and back

    func testDeletedOccurrenceStaysDeletedAcrossAMonthEnd() throws {
        let old = allDay("2027-04-30"), new = allDay("2027-05-01")
        let rule = CalendarRecurrence(frequency: .monthly, exceptions: [day("2027-05-30")])
        let moved = CalendarSeries.moved(rule, from: old, to: new)
        XCTAssertEqual(moved.exceptions, [day("2027-06-01")])
        XCTAssertEqual(dates(new, moved, "2027-05-01", "2027-07-15"), [day("2027-05-01"), day("2027-07-01")])
        XCTAssertNoThrow(try moved.validate(for: new))
        // Back again: the same rule as before.
        XCTAssertEqual(CalendarSeries.moved(moved, from: new, to: old), rule)
    }

    func testChangedOccurrenceStaysWithItsOccurrenceOneDayBack() throws {
        let old = allDay("2027-05-01"), new = allDay("2027-04-30")
        let moved = CalendarSeries.moved(CalendarRecurrence(frequency: .monthly, overrides: [changed("2027-06-01")]), from: old, to: new)
        let item = try XCTUnwrap(moved.overrides.first)
        XCTAssertEqual(item.originalDate, day("2027-05-30"))
        // Only its title was changed: it stays on its occurrence's day.
        XCTAssertEqual(item.timing, allDay("2027-05-30"))
        let occurrences = shown(new, moved, "2027-04-30", "2027-08-01")
        XCTAssertEqual(occurrences.filter { $0.title == "Geändert" }.map(\.originalDate), [day("2027-05-30")])
        XCTAssertEqual(occurrences.compactMap(\.originalDate).sorted(), [day("2027-04-30"), day("2027-05-30"), day("2027-06-30"), day("2027-07-30")])
    }

    func testChangedOccurrenceKeepsItsOwnDeviation() throws {
        // Changed occurrence 30 May shown two days later (1 June); series one day later.
        let rule = CalendarRecurrence(frequency: .monthly, overrides: [changed("2027-05-30", on: "2027-06-01")])
        let moved = CalendarSeries.moved(rule, from: allDay("2027-04-30"), to: allDay("2027-05-01"))
        let item = try XCTUnwrap(moved.overrides.first)
        XCTAssertEqual(item.originalDate, day("2027-06-01"))
        XCTAssertEqual(item.timing, allDay("2027-06-03"))
    }

    func testThirtyDaysLater() {
        // 15 Jan → 14 Feb: the third occurrence (15 Mar) is the new third (14 Apr), not 15 Mar + 30 days.
        let old = allDay("2027-01-15"), new = allDay("2027-02-14")
        let rule = CalendarRecurrence(frequency: .monthly, end: .until(day("2027-04-15")), exceptions: [day("2027-03-15")],
                                      overrides: [changed("2027-04-15")])
        let moved = CalendarSeries.moved(rule, from: old, to: new)
        XCTAssertEqual(moved.exceptions, [day("2027-04-14")])
        XCTAssertEqual(moved.overrides.map(\.originalDate), [day("2027-05-14")])
        XCTAssertEqual(moved.end, .until(day("2027-05-15")))
        XCTAssertEqual(dates(new, moved, "2027-01-01", "2027-12-31"), [day("2027-02-14"), day("2027-03-14"), day("2027-05-14")])
    }

    // MARK: End date

    func testUntilKeepsTheSameLastOccurrence() {
        let old = allDay("2027-04-30"), new = allDay("2027-05-01")
        let rule = CalendarRecurrence(frequency: .monthly, end: .until(day("2027-05-30")))
        XCTAssertEqual(dates(old, rule, "2027-04-01", "2027-12-31").count, 2)
        let moved = CalendarSeries.moved(rule, from: old, to: new)
        XCTAssertEqual(moved.end, .until(day("2027-06-01")))
        XCTAssertEqual(dates(new, moved, "2027-04-01", "2027-12-31"), [day("2027-05-01"), day("2027-06-01")])
        XCTAssertNoThrow(try moved.validate(for: new))
        let back = CalendarSeries.moved(moved, from: new, to: old)
        XCTAssertEqual(dates(old, back, "2027-04-01", "2027-12-31"), [day("2027-04-30"), day("2027-05-30")])
        // An end between two occurrences keeps its distance where that changes nothing.
        let loose = CalendarRecurrence(frequency: .monthly, end: .until(day("2027-06-15")))
        XCTAssertEqual(CalendarSeries.moved(loose, from: old, to: new).end, .until(day("2027-06-16")))
    }

    // MARK: Yearly (every 12 months) over 29 February

    func testEveryTwelveMonthsOverLeapDay() {
        let old = allDay("2028-02-29"), new = allDay("2028-03-01")
        let rule = CalendarRecurrence(frequency: .monthly, interval: 12, exceptions: [day("2032-02-29")])
        XCTAssertEqual(dates(old, rule, "2028-01-01", "2029-12-31"), [day("2028-02-29")])
        let moved = CalendarSeries.moved(rule, from: old, to: new)
        XCTAssertEqual(moved.exceptions, [day("2032-03-01")])
        XCTAssertEqual(dates(new, moved, "2031-06-01", "2033-06-01"), [day("2033-03-01")])
        XCTAssertEqual(CalendarSeries.moved(moved, from: new, to: old), rule)
    }

    func testOccurrenceThatNoLongerExistsRestsAndNeverComesBack() throws {
        // 28 Feb yearly, 2029 deleted, 2030 changed; moved to 29 Feb: neither year has that day.
        let old = allDay("2028-02-28"), new = allDay("2028-02-29")
        let rule = CalendarRecurrence(frequency: .monthly, interval: 12, exceptions: [day("2029-02-28")], overrides: [changed("2030-02-28")])
        let moved = CalendarSeries.moved(rule, from: old, to: new)
        XCTAssertNoThrow(try moved.validate(for: new))
        XCTAssertEqual(shown(new, moved, "2028-03-05", "2030-05-01").count, 0, "nothing between the leap days, the changed one rests")
        XCTAssertEqual(dates(new, moved, "2032-01-01", "2032-12-31"), [day("2032-02-29")])
        // Back to the 28th: 2029 is still deleted, 2030 still changed.
        let back = CalendarSeries.moved(moved, from: new, to: old)
        XCTAssertEqual(back, rule)
        let again = shown(old, back, "2029-01-01", "2030-12-31")
        XCTAssertEqual(again.map(\.originalDate), [day("2030-02-28")])
        XCTAssertEqual(again.first?.title, "Geändert")
    }

    func testMovedToThe31stAndBack() {
        let old = allDay("2027-01-30"), new = allDay("2027-01-31")
        let rule = CalendarRecurrence(frequency: .monthly, exceptions: [day("2027-04-30"), day("2027-05-30")], overrides: [changed("2027-06-30")])
        let moved = CalendarSeries.moved(rule, from: old, to: new)
        XCTAssertNoThrow(try moved.validate(for: new))
        // April and June have no 31st; May is deleted.
        XCTAssertEqual(dates(new, moved, "2027-01-01", "2027-08-30"), [day("2027-01-31"), day("2027-03-31"), day("2027-07-31")])
        let back = CalendarSeries.moved(moved, from: new, to: old)
        XCTAssertEqual(back, rule)
        XCTAssertEqual(dates(old, back, "2027-04-05", "2027-07-01"), [day("2027-06-30")])
    }

    // MARK: Notes, topics and „Gelöschte Termine“ follow the same occurrence

    func testNotesTopicsAndDeletedEntriesFollowTheOccurrence() throws {
        var state = CalendarState()
        let event = series(allDay("2027-04-30"), CalendarRecurrence(frequency: .monthly, exceptions: [day("2027-06-30")]))
        state.events = [event]
        let written = Date(timeIntervalSince1970: 1_810_000_000)
        state.noteLinks = [CalendarNoteLink(target: .local(event: event.id, date: day("2027-05-30")), documentID: UUID(),
                                            contextTitle: "Miete", contextStart: written, contextEnd: written.addingTimeInterval(3_600))]
        state.lessonTopics = [CalendarLessonTopic(target: .local(event: event.id, date: day("2027-07-30")), topic: "Nebenkosten")]
        state.deletedEvents = [CalendarDeletedEvent(event: event, occurrence: day("2027-06-30"))]
        let undo = CalendarUndoSnapshot(capturing: state, event: event.id)

        var moved = event
        moved.timing = allDay("2027-05-01")
        moved.recurrence = CalendarSeries.moved(try XCTUnwrap(event.recurrence), from: event.timing, to: moved.timing)
        state.events = [moved]
        CalendarNoteLinks.retarget(state: &state, event: event.id, old: event, new: moved)

        XCTAssertEqual(state.noteLinks.first?.target, .local(event: event.id, date: day("2027-06-01")))
        XCTAssertEqual(state.lessonTopics.first?.target, .local(event: event.id, date: day("2027-08-01")))
        XCTAssertEqual(state.deletedEvents.first?.occurrence, day("2027-07-01"))
        XCTAssertEqual(state.deletedEvents.first?.event, moved)
        XCTAssertEqual(moved.recurrence?.exceptions, [day("2027-07-01")])
        XCTAssertEqual(CalendarNoteLinks.movedDate(day("2027-05-30"), old: event, new: moved), day("2027-06-01"))
        XCTAssertNoThrow(try state.validate())

        undo.restore(in: &state)
        XCTAssertEqual(state.events, [event])
        XCTAssertEqual(state.noteLinks.first?.target, .local(event: event.id, date: day("2027-05-30")))
        XCTAssertEqual(state.deletedEvents.first?.occurrence, day("2027-06-30"))
    }

    // MARK: Unchanged behaviour

    func testDailyAndWeeklySeriesKeepThePlainDayShift() {
        for frequency in [CalendarRecurrence.Frequency.daily, .weekly] {
            let rule = CalendarRecurrence(frequency: frequency, interval: 2, end: .until(day("2027-06-30")),
                                          exceptions: [day("2027-05-14"), day("2027-05-17")], overrides: [changed("2027-05-28")])
            for days in [-40, -1, 1, 30] {
                let old = allDay("2027-04-30"), new = CalendarEventTiming.allDay(start: day("2027-04-30").adding(days: days),
                                                                               end: day("2027-05-01").adding(days: days))
                let moved = CalendarSeries.moved(rule, from: old, to: new)
                let plain = CalendarSeries.shifted(rule, byDays: days)
                XCTAssertEqual(moved.exceptions, plain.exceptions)
                XCTAssertEqual(moved.overrides.map(\.originalDate), plain.overrides.map(\.originalDate))
                XCTAssertEqual(moved.end, plain.end)
                XCTAssertEqual(moved.overrides.first?.timing, allDay(day("2027-05-28").adding(days: days).description))
            }
        }
    }

    func testAChangedRuleKeepsTheDayShift() {
        // The form also turned the series weekly: nothing is mapped by month.
        let rule = CalendarRecurrence(frequency: .monthly, exceptions: [day("2027-05-30")])
        let moved = CalendarSeries.moved(rule, from: allDay("2027-04-30"), to: allDay("2027-05-01"), as: CalendarRecurrence(frequency: .weekly))
        XCTAssertEqual(moved.exceptions, [day("2027-05-31")])
    }

    func testAStaleDateNeverCollidesWithAMovedOccurrence() {
        // 31 May is no occurrence of a series on the 30th; shifted by a day it would land on the moved 30 May.
        let rule = CalendarRecurrence(frequency: .monthly, exceptions: [day("2027-05-31"), day("2027-05-30")],
                                      overrides: [changed("2027-06-30"), changed("2027-07-01")])
        let new = allDay("2027-05-01")
        let moved = CalendarSeries.moved(rule, from: allDay("2027-04-30"), to: new)
        XCTAssertEqual(moved.exceptions, [day("2027-06-01")])
        XCTAssertEqual(moved.overrides.map(\.originalDate), [day("2027-07-01"), day("2027-07-02")])
        XCTAssertNoThrow(try moved.validate(for: new))
    }
}
