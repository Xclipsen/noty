import XCTest
@testable import NotebookCore

/// Benachrichtigungen (docs/CALENDAR-PLAN.md, 08.11.2026): timetable change
/// detection (coverage, window shift, missing days, duplicate ids, daylight
/// saving, past lessons), the notification plan (overview, quiet hours,
/// default reminder, budget) and the bell history. Fictitious data only.
final class CalendarNotificationTests: XCTestCase {
    private let zone = "Europe/Berlin"
    private var berlin: Calendar { CalendarDates.german(timeZone: TimeZone(identifier: zone)!) }
    private let connection = UUID()
    private let created = Date(timeIntervalSince1970: 1_790_000_000)

    private func day(_ text: String) -> CivilDate { CivilDate(text)! }
    private func at(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int = 0) -> Date {
        berlin.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    private func lesson(_ period: String, _ date: String, _ h: Int, _ min: Int = 0, subject: String = "Mathematik", subjectID: String = "12",
                        rooms: [String] = ["R 101"], statuses: [CalendarLessonStatus] = []) -> CalendarLesson {
        let civil = day(date)
        let start = at(civil.year, civil.month, civil.day, h, min)
        let key = CalendarOccurrenceKey(provider: "webuntis", connection: connection, sourceID: period, seriesID: "88",
                                        originalStart: "\(date)T" + String(format: "%02d:%02d", h, min))
        var value = CalendarLesson(key: key, date: civil, start: start, end: start.addingTimeInterval(45 * 60))
        value.subjectLong = subject; value.subjectID = subjectID; value.rooms = rooms; value.statuses = statuses
        return value
    }

    /// A snapshot that covers `days` (fetched at `time`) with `lessons`.
    private func snapshot(_ lessons: [CalendarLesson], days: [String], time: Double) -> CalendarSourceSnapshot {
        var value = CalendarSourceSnapshot(connection: connection)
        value.lessons = lessons
        for day in days { value.days[day] = time }
        return value
    }

    private let week = ["2026-11-09", "2026-11-10", "2026-11-11", "2026-11-12", "2026-11-13"]
    private var now: Date { at(2026, 11, 8, 18) }

    // MARK: Change detection

    func testStatusChangesAreDetectedAndDistinguished() {
        let old = snapshot([lesson("1", "2026-11-12", 8, subject: "Deutsch", subjectID: "3"),
                            lesson("2", "2026-11-13", 9, 45),
                            lesson("3", "2026-11-13", 11, 30, subject: "Englisch", subjectID: "5"),
                            lesson("4", "2026-11-11", 8, subject: "Physik", subjectID: "7"),
                            lesson("5", "2026-11-10", 8, subject: "Kunst", subjectID: "9", statuses: [.cancelled]),
                            lesson("6", "2026-11-10", 10)], days: week, time: 100)
        let new = snapshot([lesson("1", "2026-11-12", 8, subject: "Deutsch", subjectID: "3", statuses: [.cancelled]),
                            lesson("2", "2026-11-13", 9, 45, rooms: ["R 112"], statuses: [.roomChanged]),
                            lesson("3", "2026-11-13", 13, 15, subject: "Englisch", subjectID: "5", statuses: [.substitution]),
                            lesson("4", "2026-11-11", 8, subject: "Chemie", subjectID: "8", statuses: [.substitution]),
                            lesson("5", "2026-11-10", 8, subject: "Kunst", subjectID: "9"),
                            lesson("6", "2026-11-10", 10)], days: week, time: 200)
        let changes = CalendarChangeDetector.changes(old: old, new: new, now: now, calendar: berlin)
        let byPeriod = Dictionary(uniqueKeysWithValues: changes.map { ($0.lesson.key.sourceID, $0) })
        XCTAssertEqual(changes.count, 5, "unveränderte Stunde 6 meldet nichts")
        XCTAssertEqual(byPeriod["1"]?.kinds, [.cancelled])
        XCTAssertEqual(byPeriod["1"]?.text(calendar: berlin), "Do 12.11., 08:00 Deutsch fällt aus")
        XCTAssertEqual(byPeriod["2"]?.kinds, [.roomChanged])
        XCTAssertEqual(byPeriod["2"]?.text(calendar: berlin), "Fr 13.11., 09:45 Mathematik jetzt in R 112 (statt R 101)")
        XCTAssertEqual(byPeriod["3"]?.kinds, [.moved, .substitution])
        XCTAssertEqual(byPeriod["3"]?.text(calendar: berlin), "Englisch verlegt auf Fr 13.11., 13:15 (statt 11:30) in R 101")
        XCTAssertEqual(byPeriod["4"]?.kinds, [.substitution])
        XCTAssertEqual(byPeriod["4"]?.text(calendar: berlin), "Mi 11.11., 08:00 Chemie statt Physik")
        XCTAssertEqual(byPeriod["5"]?.kinds, [.reinstated])
        XCTAssertEqual(changes.map(\.lesson.start), changes.map(\.lesson.start).sorted(), "chronologisch")
        // Deterministic ids: the same comparison again gives the same ids.
        XCTAssertEqual(CalendarChangeDetector.changes(old: old, new: new, now: now, calendar: berlin).map(\.id), changes.map(\.id))
        XCTAssertEqual(Set(changes.map(\.id)).count, changes.count)
    }

    func testFirstFetchNewConnectionAndUnchangedRefetchYieldNothing() {
        let lessons = week.enumerated().map { lesson("\($0.offset)", $0.element, 8, statuses: $0.offset == 2 ? [.cancelled] : []) }
        let new = snapshot(lessons, days: week, time: 200)
        XCTAssertTrue(CalendarChangeDetector.changes(old: nil, new: new, now: now, calendar: berlin).isEmpty, "erster Abruf: keine Flut")
        var other = snapshot([], days: week, time: 100)
        other.connection = UUID()
        XCTAssertTrue(CalendarChangeDetector.changes(old: other, new: new, now: now, calendar: berlin).isEmpty, "neue Verbindung")
        // Empty old cache (never loaded) is no comparison either.
        XCTAssertTrue(CalendarChangeDetector.changes(old: CalendarSourceSnapshot(connection: connection), new: new, now: now, calendar: berlin).isEmpty)
        // The same lessons fetched again: nothing.
        XCTAssertTrue(CalendarChangeDetector.changes(old: snapshot(lessons, days: week, time: 100), new: new, now: now, calendar: berlin).isEmpty)
    }

    func testOnlyDaysBothSnapshotsCoverAndTheNewOneFetchedAgainCount() {
        // Old covers Mo–Mi, new Mi–Fr (window moved): only Wednesday is compared.
        let old = snapshot([lesson("1", "2026-11-09", 8), lesson("2", "2026-11-11", 8)], days: Array(week.prefix(3)), time: 100)
        var newLessons = [lesson("2", "2026-11-11", 8, statuses: [.cancelled]),
                          lesson("3", "2026-11-12", 8, statuses: [.cancelled]),
                          lesson("4", "2026-11-13", 8, statuses: [.substitution])]
        var new = snapshot(newLessons, days: Array(week.suffix(3)), time: 200)
        // Monday kept from the old fetch (same time): not compared, its lesson stays.
        new.days["2026-11-09"] = 100
        new.lessons.append(lesson("1", "2026-11-09", 8))
        var changes = CalendarChangeDetector.changes(old: old, new: new, now: now, calendar: berlin)
        XCTAssertEqual(changes.map(\.lesson.key.sourceID), ["2"], "neue Tage (Fensterverschiebung) melden nichts, auch keinen Ausfall")
        XCTAssertEqual(CalendarChangeDetector.comparedDays(old: old, new: new), [day("2026-11-11")])
        // A day the new snapshot no longer has (pruned) is never a cancellation.
        newLessons = [lesson("2", "2026-11-11", 8)]
        new = snapshot(newLessons, days: ["2026-11-11"], time: 200)
        XCTAssertTrue(CalendarChangeDetector.changes(old: old, new: new, now: now, calendar: berlin).isEmpty)
        // A lesson missing from a refetched day is not reported (only explicit status counts).
        new = snapshot([], days: Array(week.prefix(3)), time: 200)
        XCTAssertTrue(CalendarChangeDetector.changes(old: old, new: new, now: now, calendar: berlin).isEmpty)
        // An older fetch time (an answer that lost the race) is not compared.
        new = snapshot([lesson("2", "2026-11-11", 8, statuses: [.cancelled])], days: Array(week.prefix(3)), time: 50)
        XCTAssertTrue(CalendarChangeDetector.changes(old: old, new: new, now: now, calendar: berlin).isEmpty)
        // Missing days in between (gap in the old cache) stay uncompared.
        let gappy = snapshot([lesson("1", "2026-11-09", 8)], days: ["2026-11-09", "2026-11-11"], time: 100)
        new = snapshot([lesson("9", "2026-11-10", 8, statuses: [.cancelled])], days: Array(week.prefix(3)), time: 200)
        changes = CalendarChangeDetector.changes(old: gappy, new: new, now: now, calendar: berlin)
        XCTAssertTrue(changes.isEmpty, "Dienstag war vorher nicht geladen")
    }

    func testPastLessonsDuplicateIdsAndMovesOutOfTheComparedDaysAreSkipped() {
        let today = "2026-11-09"
        let old = snapshot([lesson("1", today, 8), lesson("2", today, 10), lesson("3", today, 12), lesson("3", "2026-11-10", 12),
                            lesson("4", "2026-11-10", 8)], days: [today, "2026-11-10"], time: 100)
        var duplicate = lesson("3", "2026-11-10", 12, statuses: [.cancelled])
        duplicate.key.originalStart = "x"
        let new = snapshot([lesson("1", today, 8, statuses: [.cancelled]), lesson("2", today, 10, statuses: [.cancelled]),
                            lesson("3", today, 12, statuses: [.cancelled]), duplicate,
                            lesson("4", "2026-11-20", 8, statuses: [.substitution])],
                           days: [today, "2026-11-10", "2026-11-20"], time: 200)
        let changes = CalendarChangeDetector.changes(old: old, new: new, now: at(2026, 11, 9, 9), calendar: berlin)
        XCTAssertEqual(changes.map(\.lesson.key.sourceID), ["2"],
                       "08:00 vorbei; Periode 3 doppelt (mehrdeutig); Periode 4 an einen nicht verglichenen Tag verschoben")
    }

    func testAddedIrregularLessonsCountRegularNewPeriodsDoNot() {
        let old = snapshot([lesson("1", "2026-11-10", 8)], days: week, time: 100)
        let new = snapshot([lesson("1", "2026-11-10", 8), lesson("7", "2026-11-10", 9, subject: "Biologie", statuses: [.substitution]),
                            lesson("8", "2026-11-11", 9, subject: "Sport")], days: week, time: 200)
        let changes = CalendarChangeDetector.changes(old: old, new: new, now: now, calendar: berlin)
        XCTAssertEqual(changes.map(\.kinds), [[.added]])
        XCTAssertEqual(changes.first?.text(calendar: berlin), "Di 10.11., 09:00 Biologie zusätzlich in R 101")
    }

    func testDaylightSavingKeepsLessonsEqualAndDetectsRealShift() {
        // Monday 26.10.2026, the day after summer time ended.
        let days = ["2026-10-26", "2026-10-27"]
        let old = snapshot([lesson("1", "2026-10-26", 8), lesson("2", "2026-10-27", 8)], days: days, time: 100)
        // Re-parsed lessons (fresh Date values from the same wall clock) are equal: nothing.
        let same = snapshot([lesson("1", "2026-10-26", 8), lesson("2", "2026-10-27", 8)], days: days, time: 200)
        XCTAssertTrue(CalendarChangeDetector.changes(old: old, new: same, now: at(2026, 10, 24, 12), calendar: berlin).isEmpty)
        let shifted = snapshot([lesson("1", "2026-10-26", 9), lesson("2", "2026-10-27", 8)], days: days, time: 200)
        let changes = CalendarChangeDetector.changes(old: old, new: shifted, now: at(2026, 10, 24, 12), calendar: berlin)
        XCTAssertEqual(changes.map(\.kinds), [[.moved]])
        XCTAssertEqual(changes.first?.text(calendar: berlin), "Mathematik verlegt auf Mo 26.10., 09:00 (statt 08:00) in R 101")
        // A room that is only missing now is no change.
        let roomless = snapshot([lesson("1", "2026-10-26", 8, rooms: []), lesson("2", "2026-10-27", 8)], days: days, time: 200)
        XCTAssertTrue(CalendarChangeDetector.changes(old: old, new: roomless, now: at(2026, 10, 24, 12), calendar: berlin).isEmpty)
    }

    // MARK: Settings and quiet hours

    func testQuietHoursAndOverviewTime() {
        var settings = CalendarNotificationSettings()
        XCTAssertTrue(settings.isQuiet(at(2026, 11, 9, 21), calendar: berlin))
        XCTAssertTrue(settings.isQuiet(at(2026, 11, 9, 5, 59), calendar: berlin))
        XCTAssertFalse(settings.isQuiet(at(2026, 11, 9, 6), calendar: berlin))
        XCTAssertFalse(settings.isQuiet(at(2026, 11, 9, 20, 59), calendar: berlin))
        XCTAssertEqual(settings.overviewTime(on: day("2026-11-09"), calendar: berlin), at(2026, 11, 9, 6, 45))
        // Daylight saving day: 06:45 stays 06:45 wall clock.
        XCTAssertEqual(settings.overviewTime(on: day("2026-10-25"), calendar: berlin), at(2026, 10, 25, 6, 45))
        // Overview inside the quiet hours moves to their end.
        settings.overviewMinute = 5 * 60 + 30
        XCTAssertEqual(settings.overviewTime(on: day("2026-11-09"), calendar: berlin), at(2026, 11, 9, 6))
        settings.overviewMinute = 22 * 60
        XCTAssertNil(settings.overviewTime(on: day("2026-11-09"), calendar: berlin), "Ende der Ruhezeit erst am nächsten Tag")
        settings.quietHours = false
        XCTAssertEqual(settings.overviewTime(on: day("2026-11-09"), calendar: berlin), at(2026, 11, 9, 22))
        // Quiet hours within one day; equal start/end means none.
        settings.quietHours = true; settings.quietStart = 12 * 60; settings.quietEnd = 14 * 60
        XCTAssertTrue(settings.isQuiet(at(2026, 11, 9, 13), calendar: berlin))
        XCTAssertFalse(settings.isQuiet(at(2026, 11, 9, 22), calendar: berlin))
        settings.quietEnd = 12 * 60
        XCTAssertFalse(settings.isQuiet(at(2026, 11, 9, 12), calendar: berlin))
        // Tolerant decoding: invalid values fall back to the defaults, unknown keys are ignored.
        let decoded = try? JSONDecoder().decode(CalendarNotificationSettings.self, from: Data(#"{"overviewMinute": 99999, "x": 1}"#.utf8))
        XCTAssertEqual(decoded, CalendarNotificationSettings())
        let partial = try? JSONDecoder().decode(CalendarNotificationSettings.self, from: Data(#"{"changes": false}"#.utf8))
        XCTAssertEqual(partial?.changes, false)
        XCTAssertEqual(partial?.overviewMinute, 6 * 60 + 45)
    }

    // MARK: Overview and plan

    private func state(events: [LocalCalendarEvent] = []) -> CalendarState {
        var state = CalendarState()
        state.connection = CalendarConnectionRecord(id: connection, label: "Beispielschule", connectedAt: created, sourceIdentity: "webuntis:test")
        state.events = events
        return state
    }

    func testOverviewContentAndNoOverviewOnFreeDays() {
        var cache = snapshot([lesson("1", "2026-11-09", 8, subject: "Deutsch", statuses: [.cancelled]),
                              lesson("2", "2026-11-09", 8, 50, rooms: ["R 204"]),
                              lesson("3", "2026-11-09", 9, 45, subject: "Englisch", rooms: ["R 112"], statuses: [.roomChanged])],
                             days: week + ["2026-11-14", "2026-11-15"], time: 100)
        cache.homework = [CalendarHomework(id: "h1", lessonID: "88", periodID: "2", periodDate: day("2026-11-09"), assigned: day("2026-11-05"),
                                           due: day("2026-11-09"), subject: "Mathematik", text: "S. 12"),
                          CalendarHomework(id: "h2", lessonID: "88", periodID: "2", periodDate: day("2026-11-09"), assigned: nil,
                                           due: day("2026-11-09"), subject: "Mathematik", text: "S. 13"),
                          CalendarHomework(id: "h3", lessonID: "88", periodID: "2", periodDate: day("2026-11-09"), assigned: nil,
                                           due: day("2026-11-09"), subject: "Physik", text: "erledigt")]
        let dentist = LocalCalendarEvent(title: "Zahnarzt", timing: .timed(start: at(2026, 11, 9, 15), end: at(2026, 11, 9, 16), timeZone: zone),
                                         createdAt: created)
        var current = state(events: [dentist])
        current.homeworkDone = [CalendarHomeworkMark(source: "webuntis:test", homeworkID: "h3", doneAt: created)]
        let monday = CalendarOverview.content(day: day("2026-11-09"), state: current, snapshot: cache, systemEvents: [], calendar: berlin)
        XCTAssertEqual(monday?.title, "Dein Tag · Mo 9.11.")
        XCTAssertEqual(monday?.body, """
            Beginn 08:50: Mathematik, R 204
            Änderungen: 08:00 Deutsch fällt aus; 09:45 Englisch in R 112
            2 Hausaufgaben fällig: Mathematik
            Termin: 15:00 Zahnarzt
            """)
        // Saturday loaded without lessons and without events: no overview.
        XCTAssertNil(CalendarOverview.content(day: day("2026-11-14"), state: current, snapshot: cache, systemEvents: [], calendar: berlin))
        // Not loaded and no events: no overview; with a system event on Sunday: an overview of the event only.
        XCTAssertNil(CalendarOverview.content(day: day("2026-11-20"), state: current, snapshot: cache, systemEvents: [], calendar: berlin))
        var system = CalendarSystemEvent(itemID: "a", externalID: nil, calendarID: "c", title: "Training",
                                         start: at(2026, 11, 15, 10), end: at(2026, 11, 15, 11))
        current.settings.systemCalendars = CalendarSystemSettings(enabled: true)
        XCTAssertEqual(CalendarOverview.content(day: day("2026-11-15"), state: current, snapshot: cache, systemEvents: [system], calendar: berlin)?.body,
                       "Termin: 10:00 Training")
        system.cancelled = true
        XCTAssertNil(CalendarOverview.content(day: day("2026-11-15"), state: current, snapshot: cache, systemEvents: [system], calendar: berlin))
        // A snapshot of another connection is never used.
        current.connection = CalendarConnectionRecord(label: "Andere", connectedAt: created)
        XCTAssertEqual(CalendarOverview.content(day: day("2026-11-09"), state: current, snapshot: cache, systemEvents: [], calendar: berlin)?.body,
                       "Termin: 15:00 Zahnarzt")
    }

    func testPlanPutsOverviewsFirstKeepsBudgetAndHonoursQuietHours() {
        var lessons: [CalendarLesson] = []
        var days: [String] = []
        for offset in 0..<28 {
            let date = day("2026-11-09").adding(days: offset)
            days.append(date.description)
            guard CalendarDates.weekdayIndex(date.start(in: berlin), calendar: berlin) < 5 else { continue }
            for hour in 8..<14 { lessons.append(lesson("\(date)-\(hour)", date.description, hour)) }
        }
        // A lesson at 21:30 (quiet hours) and an own event at 22:00 without own reminder.
        lessons.append(lesson("late", "2026-11-09", 21, 30))
        let cache = snapshot(lessons, days: days, time: 100)
        let late = LocalCalendarEvent(title: "Konzert", timing: .timed(start: at(2026, 11, 9, 22), end: at(2026, 11, 9, 23), timeZone: zone),
                                      createdAt: created)
        let trip = LocalCalendarEvent(title: "Ausflug", timing: .allDay(start: day("2026-11-12"), end: day("2026-11-13")), createdAt: created)
        var current = state(events: [late, trip])
        current.settings.lessonReminderMinutes = 10
        let settings = CalendarNotificationSettings()
        let plan = CalendarNotificationPlanner.plan(state: current, snapshot: cache, systemEvents: [], settings: settings,
                                                    namespace: "calendar.abc", now: now, calendar: berlin)
        XCTAssertEqual(plan.requests.count, CalendarReminderPlanner.limit, "Budget eingehalten")
        let overviews = plan.requests.filter { $0.kind == .overview }
        XCTAssertEqual(overviews.map(\.day), ["2026-11-09", "2026-11-10", "2026-11-11", "2026-11-12", "2026-11-13"].map(day),
                       "Überblick nur an Tagen mit Unterricht/Terminen, Wochenende ohne")
        XCTAssertEqual(overviews.first?.fireDate, at(2026, 11, 9, 6, 45))
        XCTAssertTrue(plan.requests.allSatisfy { $0.id.hasPrefix("noty.calendar.calendar.abc.") }, "Kanal/Bereich im Kennzeichen")
        XCTAssertFalse(plan.requests.contains { $0.id.contains("lesson.late.") }, "Stundenerinnerung in der Ruhezeit entfällt")
        let concert = plan.requests.first { $0.kind == .event && $0.title == "Konzert" }
        XCTAssertEqual(concert?.fireDate, at(2026, 11, 9, 21, 45), "eigene Termine: Standard 15 Minuten, auch in der Ruhezeit")
        XCTAssertEqual(concert?.entryID, CalendarNoteTarget.local(event: late.id, date: nil).key)
        XCTAssertFalse(plan.requests.contains { $0.title == "Ausflug" }, "ganztägig ohne eigene Erinnerung: keine Standarderinnerung")
        XCTAssertEqual(plan.requests.map(\.fireDate), plan.requests.map(\.fireDate).sorted())
        XCTAssertEqual(Set(plan.requests.map(\.id)).count, plan.requests.count)
        XCTAssertNotNil(plan.plannedUntil)
        XCTAssertGreaterThan(plan.deferred, 0)
        // The lesson reminders carry their target.
        let lessonRequest = plan.requests.first { $0.kind == .lesson }
        XCTAssertEqual(lessonRequest?.day, day("2026-11-09"))
        XCTAssertEqual(lessonRequest?.entryID, lessons.first?.id)
        // Switched off: no overview, no own-event reminder; same input → same plan.
        var off = settings
        off.overview = false; off.eventReminders = false
        let quiet = CalendarNotificationPlanner.plan(state: current, snapshot: cache, systemEvents: [], settings: off,
                                                     namespace: "calendar.abc", now: now, calendar: berlin)
        XCTAssertFalse(quiet.requests.contains { $0.kind == .overview || $0.kind == .event })
        XCTAssertEqual(CalendarNotificationPlanner.plan(state: current, snapshot: cache, systemEvents: [], settings: settings,
                                                        namespace: "calendar.abc", now: now, calendar: berlin), plan)
        // The old planner without namespace keeps its identifiers.
        XCTAssertTrue(CalendarReminderPlanner.plan(state: current, snapshot: cache, now: now, calendar: berlin).requests
            .allSatisfy { $0.id.hasPrefix("noty.calendar.lesson.") || $0.id.hasPrefix("noty.calendar.event.") })
    }

    func testEventOwnReminderWinsOverTheDefault() {
        let event = LocalCalendarEvent(title: "Klausur", timing: .timed(start: at(2026, 11, 10, 8), end: at(2026, 11, 10, 9), timeZone: zone),
                                       reminderMinutes: 60, createdAt: created)
        var settings = CalendarNotificationSettings()
        settings.overview = false
        let plan = CalendarNotificationPlanner.plan(state: state(events: [event]), snapshot: nil, systemEvents: [], settings: settings,
                                                    namespace: "", now: now, calendar: berlin)
        XCTAssertEqual(plan.requests.map(\.fireDate), [at(2026, 11, 10, 7)])
        XCTAssertEqual(plan.requests.first?.id, "noty.calendar.event.\(event.id.uuidString).single")
    }

    // MARK: History

    func testHistoryDeduplicatesBoundsAndSurvivesDamage() throws {
        var log = CalendarNotificationLog()
        let change = CalendarLessonChange(kinds: [.cancelled], lesson: lesson("1", "2026-11-12", 8, statuses: [.cancelled]), previous: nil)
        let record = CalendarNotificationRecord(change: change, date: now, calendar: berlin, namespace: "calendar.abc")
        XCTAssertTrue(record.id.hasPrefix(CalendarNotificationLog.changePrefix + "calendar.abc."))
        XCTAssertFalse(record.id.hasPrefix(CalendarReminder.prefix), "Änderungen nicht unter dem Präfix des Erinnerungsplans")
        XCTAssertEqual(record.entryID, change.lesson.id)
        XCTAssertEqual(log.add([record], now: now).count, 1)
        XCTAssertEqual(log.add([record], now: now).count, 0, "dieselbe Änderung nur einmal")
        XCTAssertEqual(log.unreadCount, 1)
        log.markRead(record.id)
        XCTAssertEqual(log.unreadCount, 0)
        // Bounded: 200 newest, nothing older than 60 days.
        let many = (0..<250).map { CalendarNotificationRecord(id: "r\($0)", kind: .event, title: "T", body: "", date: now.addingTimeInterval(Double($0))) }
        log.add(many, now: now.addingTimeInterval(300))
        XCTAssertEqual(log.records.count, CalendarNotificationLog.maximumRecords)
        XCTAssertEqual(log.records.first?.id, "r249", "neueste zuerst")
        log.add([CalendarNotificationRecord(id: "old", kind: .event, title: "T", body: "", date: now.addingTimeInterval(-61 * 86_400))], now: now)
        XCTAssertFalse(log.records.contains { $0.id == "old" })
        log.markAllRead()
        XCTAssertEqual(log.unreadCount, 0)
        // Round trip; damaged bytes are an empty history; a newer format is left alone (nil).
        let bytes = try log.encoded()
        XCTAssertEqual(CalendarNotificationLog.decode(bytes), log)
        XCTAssertEqual(CalendarNotificationLog.decode(Data("kaputt".utf8)), CalendarNotificationLog())
        XCTAssertNil(CalendarNotificationLog.decode(Data(#"{"formatVersion": 2, "records": []}"#.utf8)))
        // One damaged record does not cost the others.
        let mixed = Data(#"{"formatVersion":1,"records":[{"id":"a","kind":"event","title":"A","body":"","date":1},{"id":"b","kind":"unbekannt"}]}"#.utf8)
        XCTAssertEqual(CalendarNotificationLog.decode(mixed)?.records.map(\.id), ["a"])
    }

    func testSummaryOfSeveralChanges() {
        let changes = (1...5).map { CalendarLessonChange(kinds: [.cancelled], lesson: lesson("\($0)", "2026-11-12", 7 + $0, statuses: [.cancelled]), previous: nil) }
        let summary = CalendarLessonChange.summary(changes, calendar: berlin)
        XCTAssertEqual(summary.title, "5 Stundenplanänderungen")
        XCTAssertEqual(summary.body.components(separatedBy: "\n").count, 4)
        XCTAssertEqual(CalendarLessonChange.summary(Array(changes.prefix(1)), calendar: berlin).body, "Do 12.11., 08:00 Mathematik fällt aus")
    }
}
