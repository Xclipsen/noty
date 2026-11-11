import XCTest
@testable import NotebookCore

/// Live Activity „Schultag“ / Widget „Heute“ (docs/LIVE-ACTIVITY-PLAN.md):
/// phases, Freistunde vs. Pause, cancelled lessons, transitions, the 8-h
/// restart plan, the JSON contract of the push service and the widget file.
/// Fictitious data only.
final class CalendarSchoolDayTests: XCTestCase {
    private let berlin = CalendarDates.german(timeZone: TimeZone(identifier: "Europe/Berlin")!)
    private let connection = UUID(uuidString: "6F1C2A4E-0000-4000-8000-000000000001")!

    private func at(_ h: Int, _ m: Int = 0, day: Int = 9) -> Int {
        Int(berlin.date(from: DateComponents(year: 2026, month: 11, day: day, hour: h, minute: m))!.timeIntervalSince1970)
    }

    private func lesson(_ title: String, _ h: Int, _ m: Int, minutes: Int = 45, room: String? = "R 101", cancelled: Bool = false,
                        note: String? = nil, day: Int = 9) -> SchoolDayLesson {
        let start = at(h, m, day: day)
        return SchoolDayLesson(title: title, room: room, start: start, end: start + minutes * 60, note: cancelled ? "fällt aus" : note,
                               changed: cancelled || note != nil, cancelled: cancelled, entryID: "id-\(title)-\(h)\(m)")
    }

    /// 1. 08:00 Mathe, 2. 08:45 Deutsch, (Pause 15) 3. 09:45 Englisch,
    /// 4. 10:30 Physik fällt aus, 5. 11:30 Chemie, (Mittag 75) 6. 13:30 Sport.
    private var monday: [SchoolDayLesson] {
        [lesson("Mathematik", 8, 0, room: "R 112"), lesson("Deutsch", 8, 45, room: "R 204"), lesson("Englisch", 9, 45),
         lesson("Physik", 10, 30, cancelled: true), lesson("Chemie", 11, 30, note: "Raumwechsel"), lesson("Sport", 13, 30, minutes: 90)]
    }

    func testNoLessonsOrAllCancelledIsNoSchoolDay() {
        XCTAssertNil(CalendarSchoolDay(lessons: []))
        XCTAssertNil(CalendarSchoolDay(lessons: [lesson("Mathematik", 8, 0, cancelled: true)]))
    }

    func testDayBoundsCountAndPlan() throws {
        let day = try XCTUnwrap(CalendarSchoolDay(lessons: monday.shuffled()))
        XCTAssertEqual(day.count, 5, "the cancelled lesson does not count")
        XCTAssertEqual(day.dayStart, at(8))
        XCTAssertEqual(day.dayEnd, at(15))
        XCTAssertEqual(day.plan.start, at(7, 30))
        XCTAssertEqual(day.plan.end, at(15))
        XCTAssertEqual(day.plan.restarts, [], "7 h 30 min stay under the limit")
    }

    func testBeforeLessonPauseFreeDone() throws {
        let day = try XCTUnwrap(CalendarSchoolDay(lessons: monday))
        let before = day.state(at: at(7, 40))
        XCTAssertEqual(before.phase, .before)
        XCTAssertEqual(before.next?.title, "Mathematik")
        XCTAssertEqual(before.phaseStart, at(7, 30)); XCTAssertEqual(before.phaseEnd, at(8))
        XCTAssertEqual(before.number, 1); XCTAssertEqual(before.count, 5)

        let first = day.state(at: at(8, 10))
        XCTAssertEqual(first.phase, .lesson)
        XCTAssertEqual(first.current?.title, "Mathematik"); XCTAssertEqual(first.current?.room, "R 112")
        XCTAssertEqual(first.next?.title, "Deutsch")
        XCTAssertEqual(first.phaseEnd, at(8, 45)); XCTAssertEqual(first.number, 1)

        // Lesson end = next lesson start: the next lesson runs at once.
        XCTAssertEqual(day.state(at: at(8, 45)).current?.title, "Deutsch")

        let pause = day.state(at: at(9, 35))
        XCTAssertEqual(pause.phase, .pause, "15 minutes between two lessons")
        XCTAssertEqual(pause.phaseStart, at(9, 30)); XCTAssertEqual(pause.phaseEnd, at(9, 45))
        XCTAssertEqual(pause.next?.title, "Englisch"); XCTAssertEqual(pause.number, 3)

        // Englisch: next is the cancelled Physik (shown with its mark).
        let third = day.state(at: at(10, 0))
        XCTAssertEqual(third.next?.title, "Physik"); XCTAssertEqual(third.next?.note, "fällt aus")
        XCTAssertEqual(third.next?.cancelled, true); XCTAssertEqual(third.number, 3)

        let free = day.state(at: at(10, 40))
        XCTAssertEqual(free.phase, .free, "a cancelled lesson in the gap")
        XCTAssertEqual(free.phaseStart, at(10, 30)); XCTAssertEqual(free.phaseEnd, at(11, 30))
        XCTAssertEqual(free.next?.title, "Chemie"); XCTAssertEqual(free.next?.note, "Raumwechsel"); XCTAssertEqual(free.next?.changed, true)
        XCTAssertEqual(free.number, 4)

        let lunch = day.state(at: at(12, 30))
        XCTAssertEqual(lunch.phase, .free, "a gap at least one lesson long")
        XCTAssertEqual(lunch.phaseEnd, at(13, 30))

        let last = day.state(at: at(14, 0))
        XCTAssertEqual(last.phase, .lesson); XCTAssertEqual(last.number, 5); XCTAssertNil(last.next)

        let done = day.state(at: at(15))
        XCTAssertEqual(done.phase, .done); XCTAssertNil(done.current); XCTAssertNil(done.next)
        XCTAssertEqual(done.number, 5)
    }

    func testCancelledFirstLessonMovesTheStart() throws {
        let day = try XCTUnwrap(CalendarSchoolDay(lessons: [lesson("Mathematik", 8, 0, cancelled: true), lesson("Deutsch", 8, 45)]))
        XCTAssertEqual(day.dayStart, at(8, 45))
        XCTAssertEqual(day.plan.start, at(8, 15))
        let before = day.state(at: at(8, 20))
        XCTAssertEqual(before.phase, .before); XCTAssertEqual(before.next?.title, "Deutsch")
        XCTAssertEqual(day.count, 1)
        XCTAssertFalse(day.visible.contains { $0.cancelled }, "cancelled lessons outside the day are not shown")
    }

    func testCancelledLastLessonEndsTheDayEarlier() throws {
        let day = try XCTUnwrap(CalendarSchoolDay(lessons: [lesson("Mathematik", 8, 0), lesson("Deutsch", 8, 45, cancelled: true)]))
        XCTAssertEqual(day.dayEnd, at(8, 45))
        XCTAssertNil(day.state(at: at(8, 10)).next)
    }

    func testParallelDuplicatesAndOverlap() throws {
        // Two groups at the same time: one slot; a cancelled one beside a taking one is hidden.
        let day = try XCTUnwrap(CalendarSchoolDay(lessons: [lesson("Französisch", 8, 0), lesson("Latein", 8, 0),
                                                            lesson("Spanisch", 8, 0, cancelled: true), lesson("Deutsch", 8, 45)]))
        XCTAssertEqual(day.count, 2)
        XCTAssertEqual(day.state(at: at(8, 5)).current?.title, "Französisch")
        XCTAssertEqual(day.state(at: at(8, 5)).next?.title, "Deutsch")
        // Overlap: the newer lesson is the current one.
        let overlap = try XCTUnwrap(CalendarSchoolDay(lessons: [lesson("Mathematik", 8, 0, minutes: 90), lesson("Deutsch", 8, 45)]))
        XCTAssertEqual(overlap.state(at: at(9, 0)).current?.title, "Deutsch")
        XCTAssertEqual(overlap.dayEnd, at(9, 30))
    }

    func testShortBreakVsFreeThreshold() throws {
        // 60-minute lessons: a 45-minute gap is still a break.
        let day = try XCTUnwrap(CalendarSchoolDay(lessons: [lesson("A", 8, 0, minutes: 60), lesson("B", 9, 45, minutes: 60)]))
        XCTAssertEqual(day.freeThreshold, 3600)
        XCTAssertEqual(day.state(at: at(9, 10)).phase, .pause)
        // Very short lessons: at least 30 minutes for a Freistunde.
        let short = try XCTUnwrap(CalendarSchoolDay(lessons: [lesson("A", 8, 0, minutes: 10), lesson("B", 8, 25, minutes: 10)]))
        XCTAssertEqual(short.freeThreshold, 1800)
        XCTAssertEqual(short.state(at: at(8, 15)).phase, .pause)
    }

    func testTransitions() throws {
        let day = try XCTUnwrap(CalendarSchoolDay(lessons: monday))
        XCTAssertEqual(day.transitions, [at(7, 30), at(8), at(8, 45), at(9, 30), at(9, 45), at(10, 30), at(11, 30), at(12, 15),
                                         at(13, 30), at(15)])
        XCTAssertEqual(day.nextTransition(after: at(8, 10)), at(8, 45))
        XCTAssertNil(day.nextTransition(after: at(15)))
        // Between two transitions the state does not change.
        for (a, b) in zip(day.transitions, day.transitions.dropFirst()) {
            XCTAssertEqual(day.state(at: a), day.state(at: b - 1), "constant in [\(a), \(b))")
        }
        // A cancelled lesson inside a lesson's slot moves the „Danach“ line at its start.
        let moved = try XCTUnwrap(CalendarSchoolDay(lessons: [lesson("A", 8, 0), lesson("X", 9, 0, cancelled: true), lesson("B", 10, 0)]))
        XCTAssertTrue(moved.transitions.contains(at(9)))
        XCTAssertEqual(moved.state(at: at(8, 59)).next?.title, "X")
        XCTAssertEqual(moved.state(at: at(9, 0)).next?.title, "B")
    }

    func testRestartPlanForLongDays() throws {
        let day = try XCTUnwrap(CalendarSchoolDay(lessons: [lesson("A", 7, 0), lesson("B", 16, 0, minutes: 90)]))
        let plan = day.plan
        XCTAssertEqual(plan.start, at(6, 30)); XCTAssertEqual(plan.end, at(17, 30))
        XCTAssertEqual(plan.restarts, [at(14, 15)], "7 h 45 min after the start")
        let longer = try XCTUnwrap(CalendarSchoolDay(lessons: [lesson("A", 6, 0), lesson("B", 22, 0, minutes: 60)]))
        XCTAssertEqual(longer.plan.restarts, [at(13, 15), at(21, 0)])
        XCTAssertTrue(longer.plan.restarts.allSatisfy { $0 < longer.plan.end })
    }

    func testFromSnapshotLessonLabels() throws {
        let civil = CivilDate("2026-11-09")!
        func make(_ id: String, _ h: Int, _ statuses: [CalendarLessonStatus], rooms: [String] = ["R 1"]) -> CalendarLesson {
            let start = Date(timeIntervalSince1970: TimeInterval(at(h)))
            let key = CalendarOccurrenceKey(provider: "webuntis", connection: connection, sourceID: id, seriesID: nil, originalStart: "x\(h)")
            var value = CalendarLesson(key: key, date: civil, start: start, end: start.addingTimeInterval(2700))
            value.subjectLong = "Fach \(id)"; value.rooms = rooms; value.statuses = statuses
            return value
        }
        var snapshot = CalendarSourceSnapshot(connection: connection)
        snapshot.lessons = [make("1", 8, [.cancelled, .roomChanged]), make("2", 9, [.substitution, .roomChanged], rooms: ["A", "B"]),
                            make("3", 10, [.exam]), make("4", 11, [.other("X")], rooms: [" "]), make("5", 12, [.roomChanged])]
        XCTAssertNil(CalendarSchoolDay.lessons(snapshot: snapshot, day: civil), "day not loaded")
        snapshot.days[civil.description] = 0
        let lessons = try XCTUnwrap(CalendarSchoolDay.lessons(snapshot: snapshot, day: civil))
        XCTAssertEqual(lessons.map(\.note), ["fällt aus", "Vertretung, Raumwechsel", "Prüfung", nil, "Raumwechsel"])
        XCTAssertEqual(lessons.map(\.changed), [true, true, false, false, true])
        XCTAssertEqual(lessons.map(\.cancelled), [true, false, false, false, false])
        XCTAssertEqual(lessons[1].room, "A, B"); XCTAssertNil(lessons[3].room)
        XCTAssertEqual(lessons[0].entryID, snapshot.lessons[0].id)
        XCTAssertEqual(lessons[0].end - lessons[0].start, 2700)
        XCTAssertEqual(CalendarSchoolDay.lessons(snapshot: snapshot, day: civil.adding(days: 1)), nil)
    }

    func testLongTextsAreCut() {
        let civil = CivilDate("2026-11-09")!
        let key = CalendarOccurrenceKey(provider: "webuntis", connection: connection, sourceID: "1", seriesID: nil, originalStart: "x")
        var value = CalendarLesson(key: key, date: civil, start: Date(timeIntervalSince1970: 0), end: Date(timeIntervalSince1970: 60))
        value.subjectLong = String(repeating: "M", count: 300); value.rooms = [String(repeating: "R", count: 100)]
        let lesson = SchoolDayLesson(lesson: value)
        XCTAssertEqual(lesson.title.count, SchoolDayLesson.maximumTitle)
        XCTAssertEqual(lesson.room?.count, SchoolDayLesson.maximumRoom)
    }

    // MARK: JSON contract (docs/LIVE-ACTIVITY-PLAN.md)

    func testContentStateJSONContract() throws {
        let day = try XCTUnwrap(CalendarSchoolDay(lessons: monday))
        let state = day.state(at: at(10, 0))
        let data = try state.encoded()
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["v", "phase", "phaseStart", "phaseEnd", "current", "next", "number", "count", "dayStart", "dayEnd"])
        XCTAssertEqual(object["v"] as? Int, 1)
        XCTAssertEqual(object["phase"] as? String, "lesson")
        XCTAssertEqual(object["phaseStart"] as? Int, at(9, 45))
        let current = try XCTUnwrap(object["current"] as? [String: Any])
        XCTAssertEqual(Set(current.keys), ["title", "room", "start", "end", "changed", "cancelled", "entryID"], "nil note left out")
        XCTAssertLessThan(data.count, 1_500, "far below 4 KB")
        // The standard decoder (as ActivityKit uses it for APNs) reads it back.
        XCTAssertEqual(try JSONDecoder().decode(SchoolDayContentState.self, from: data), state)
        XCTAssertEqual(try JSONDecoder().decode(SchoolDayPhase.self, from: Data(#""break""#.utf8)), .pause)
    }

    func testDocumentedExampleDecodes() throws {
        // The example of docs/LIVE-ACTIVITY-PLAN.md, exactly as the push service sends it.
        let json = #"""
        {"v":1,"phase":"lesson","phaseStart":1794213900,"phaseEnd":1794216600,
         "current":{"title":"Mathematik","room":"R 112","start":1794213900,"end":1794216600,"changed":false,"cancelled":false,
                    "entryID":"webuntis/6F1C2A4E-0000-4000-8000-000000000001/4711/2026-11-09T09:45"},
         "next":{"title":"Deutsch","room":"R 204","start":1794216900,"end":1794219600,"note":"fällt aus","changed":true,"cancelled":true},
         "number":3,"count":6,"dayStart":1794207600,"dayEnd":1794226500}
        """#
        let state = try JSONDecoder().decode(SchoolDayContentState.self, from: Data(json.utf8))
        XCTAssertEqual(state.phase, .lesson); XCTAssertEqual(state.number, 3)
        XCTAssertEqual(state.next?.note, "fällt aus"); XCTAssertNil(state.current?.note)
        let attributes = try JSONDecoder().decode(SchoolDayAttributes.self,
                                                  from: Data(#"{"connectionID":"6F1C2A4E-0000-4000-8000-000000000001","day":"2026-11-09"}"#.utf8))
        XCTAssertEqual(attributes.day, "2026-11-09")
        // Missing required keys are refused (the server must send them all).
        XCTAssertThrowsError(try JSONDecoder().decode(SchoolDayContentState.self, from: Data(#"{"v":1,"phase":"lesson"}"#.utf8)))
    }

    func testWorstCaseSizeStaysSmall() throws {
        let long = String(repeating: "W", count: 40), room = String(repeating: "R", count: 24), id = String(repeating: "i", count: 200)
        let lesson = SchoolDayLesson(title: long, room: room, start: 1, end: 2, note: "Vertretung, Raumwechsel", changed: true, entryID: id)
        let state = SchoolDayContentState(phase: .lesson, phaseStart: 1, phaseEnd: 2, current: lesson, next: lesson, number: 12, count: 12,
                                          dayStart: 1, dayEnd: 2)
        XCTAssertLessThan(try state.encoded().count, 1_200)
    }

    // MARK: Widget file

    /// From midnight on the widget is in `before`, but the countdown range
    /// starts 30 minutes before the first lesson: until then the widget shows
    /// the start time, and its timeline switches exactly at that moment.
    func testWidgetShowsStartTimeUntilTheCountdownBegins() throws {
        let civil = CivilDate("2026-11-09")!
        var snapshot = CalendarSourceSnapshot(connection: connection)
        let start = Date(timeIntervalSince1970: TimeInterval(at(8)))
        let key = CalendarOccurrenceKey(provider: "webuntis", connection: connection, sourceID: "1", seriesID: nil, originalStart: "x")
        var value = CalendarLesson(key: key, date: civil, start: start, end: start.addingTimeInterval(2700))
        value.subjectLong = "Mathematik"
        snapshot.lessons = [value]
        snapshot.days[civil.description] = 0
        let early = Date(timeIntervalSince1970: TimeInterval(at(6, 30)))
        let file = SchoolDayWidgetFile(namespace: "calendar.abc", connectionID: connection, snapshot: snapshot, now: early, calendar: berlin)

        struct NotToday: Error { let time: Int }
        func state(_ time: Int) throws -> SchoolDayContentState {
            guard case .today(let state) = SchoolDayWidgetContent.at(Date(timeIntervalSince1970: TimeInterval(time)), file: file, calendar: berlin) else {
                throw NotToday(time: time)
            }
            return state
        }
        let before = try state(at(6, 30))
        XCTAssertEqual(before.phase, .before)
        XCTAssertEqual(before.phaseStart, at(7, 30), "the countdown range still starts with the tile")
        XCTAssertEqual(before.phaseEnd, at(8))
        XCTAssertTrue(before.showsStartTime(at: at(6, 30)), "06:30: the start time, not a countdown that has not begun")
        XCTAssertTrue(try state(at(0, 1)).showsStartTime(at: at(0, 1)))
        XCTAssertTrue(before.showsStartTime(at: at(7, 30) - 1))
        XCTAssertFalse(try state(at(7, 30)).showsStartTime(at: at(7, 30)), "from 07:30 on the countdown runs")
        XCTAssertFalse(try state(at(7, 45)).showsStartTime(at: at(7, 45)))
        let lesson = try state(at(8, 10))
        XCTAssertEqual(lesson.phase, .lesson)
        XCTAssertFalse(lesson.showsStartTime(at: at(8, 10)))
        XCTAssertFalse(lesson.showsStartTime(at: at(6)), "only the phase before the first lesson")

        // The entry that replaces the start time by the countdown.
        let moments = SchoolDayWidgetContent.timeline(from: early, file: file, calendar: berlin).map { Int($0.timeIntervalSince1970) }
        XCTAssertEqual(Array(moments.prefix(3)), [at(6, 30), at(7, 30), at(8)])
        let switched = try XCTUnwrap(moments.first { $0 > at(6, 30) })
        XCTAssertFalse(try state(switched).showsStartTime(at: switched))
    }

    func testWidgetFileAndContent() throws {
        let civil = CivilDate("2026-11-09")!
        var snapshot = CalendarSourceSnapshot(connection: connection)
        let start = Date(timeIntervalSince1970: TimeInterval(at(8)))
        let key = CalendarOccurrenceKey(provider: "webuntis", connection: connection, sourceID: "1", seriesID: nil, originalStart: "x")
        var value = CalendarLesson(key: key, date: civil, start: start, end: start.addingTimeInterval(2700))
        value.subjectLong = "Mathematik"
        snapshot.lessons = [value]
        snapshot.days[civil.description] = 0
        let now = Date(timeIntervalSince1970: TimeInterval(at(7)))
        let file = SchoolDayWidgetFile(namespace: "calendar.abc", connectionID: connection, snapshot: snapshot, now: now, calendar: berlin)
        XCTAssertEqual(file.days.map(\.day), ["2026-11-09"], "tomorrow was not loaded")
        let decoded = try XCTUnwrap(SchoolDayWidgetFile.decode(try file.encoded()))
        XCTAssertEqual(decoded, file)
        XCTAssertNil(SchoolDayWidgetFile.decode(Data("{}".utf8)))

        guard case .today(let state) = SchoolDayWidgetContent.at(now, file: file, calendar: berlin) else { return XCTFail() }
        XCTAssertEqual(state.phase, .before)
        XCTAssertEqual(SchoolDayWidgetContent.at(Date(timeIntervalSince1970: TimeInterval(at(9))), file: file, calendar: berlin),
                       .doneToday(tomorrow: nil))
        XCTAssertEqual(SchoolDayWidgetContent.at(Date(timeIntervalSince1970: TimeInterval(at(9, day: 10))), file: file, calendar: berlin),
                       .notLoaded)
        XCTAssertEqual(SchoolDayWidgetContent.at(now, file: nil, calendar: berlin), .notLoaded)

        var empty = file
        empty.days = [.init(day: "2026-11-09", lessons: []), .init(day: "2026-11-10", lessons: [lesson("Deutsch", 9, 0, day: 10)])]
        XCTAssertEqual(SchoolDayWidgetContent.at(now, file: empty, calendar: berlin),
                       .noLessonsToday(tomorrow: lesson("Deutsch", 9, 0, day: 10)))

        let moments = SchoolDayWidgetContent.timeline(from: now, file: file, calendar: berlin)
        XCTAssertEqual(moments.map { Int($0.timeIntervalSince1970) }, [at(7), at(7, 30), at(8), at(8, 45), at(0, day: 10)])
    }
}
