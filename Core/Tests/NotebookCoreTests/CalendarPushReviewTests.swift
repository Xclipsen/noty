import XCTest
@testable import NotebookCore

/// Review findings of 08.11.2026 (docs/PUSH.md) in Core: the same change
/// again after a different one (ids, bell, both origins), empty WebUntis
/// answers, shared texts, payload keys and defaults. Fictitious data only.
final class CalendarPushReviewTests: XCTestCase {
    private var berlin: Calendar { CalendarDates.german(timeZone: TimeZone(identifier: "Europe/Berlin")!) }
    private let connection = UUID()
    private let namespace = "calendar.abc12"

    private func day(_ text: String) -> CivilDate { CivilDate(text)! }
    private func at(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int = 0) -> Date {
        berlin.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    private func lesson(_ period: String, _ date: String, _ h: Int, subject: String = "Mathematik", rooms: [String] = ["R 1.01"],
                        statuses: [CalendarLessonStatus] = []) -> CalendarLesson {
        let civil = day(date)
        let start = at(civil.year, civil.month, civil.day, h)
        let key = CalendarOccurrenceKey(provider: "webuntis", connection: connection, sourceID: period, seriesID: "88",
                                        originalStart: "\(date)T" + String(format: "%02d:00", h))
        var value = CalendarLesson(key: key, date: civil, start: start, end: start.addingTimeInterval(45 * 60))
        value.subjectLong = subject; value.subjectID = "12"; value.rooms = rooms; value.statuses = statuses
        return value
    }

    private func snapshot(_ lessons: [CalendarLesson], days: [String], time: Double) -> CalendarSourceSnapshot {
        var value = CalendarSourceSnapshot(connection: connection)
        value.lessons = lessons
        for day in days { value.days[day] = time }
        return value
    }

    private let week = ["2026-11-09", "2026-11-10", "2026-11-11", "2026-11-12", "2026-11-13"]
    private var now: Date { at(2026, 11, 8, 18) }

    // MARK: Change ids

    func testChangeIDsParseWithDotsInPeriodAndRoomsAndTheRepeatGeneration() throws {
        let change = CalendarLessonChange(kinds: [.roomChanged, .substitution], lesson: lesson("77", "2026-11-12", 8, rooms: ["R 1.12", "H.2"]),
                                          previous: lesson("77", "2026-11-12", 8))
        let parsed = try XCTUnwrap(CalendarChangeID(change.id))
        XCTAssertEqual(parsed.period, "77")
        XCTAssertEqual(parsed.day, day("2026-11-12"))
        XCTAssertEqual(parsed.kinds, ["roomChanged", "substitution"])
        XCTAssertEqual(parsed.rooms, "H.2+R 1.12")
        XCTAssertEqual(parsed.generation, 1)
        XCTAssertEqual(parsed.base, change.id)
        XCTAssertEqual(parsed.id, change.id)
        XCTAssertEqual(parsed.category, "changed")
        let repeated = try XCTUnwrap(CalendarChangeID(change.id + "~3"))
        XCTAssertEqual(repeated.generation, 3)
        XCTAssertEqual(repeated.base, change.id)
        XCTAssertEqual(repeated.rooms, "H.2+R 1.12")
        // Periods with dots, empty rooms; „~0“/„~1“/„~01“ are no generation.
        XCTAssertEqual(CalendarChangeID("change.a.b.2026-11-12.cancelled.5.")?.period, "a.b")
        XCTAssertEqual(CalendarChangeID("change.1.2026-11-12.cancelled.5.~2")?.rooms, "")
        XCTAssertEqual(CalendarChangeID("change.1.2026-11-12.cancelled.5.~2")?.generation, 2)
        for raw in ["change.1.2026-11-12.cancelled.5.R~1", "change.1.2026-11-12.cancelled.5.R~0", "change.1.2026-11-12.cancelled.5.R~02"] {
            XCTAssertEqual(CalendarChangeID(raw)?.generation, 1, raw)
            XCTAssertEqual(CalendarChangeID(raw)?.id, raw)
        }
        XCTAssertNil(CalendarChangeID("summary.1"))
        XCTAssertNil(CalendarChangeID("change.2026-11-12.cancelled.5.R"))
    }

    func testTheSameChangeAgainAfterAnotherOneIsANewChange() {
        let cancelled = CalendarLessonChange(kinds: [.cancelled], lesson: lesson("1", "2026-11-12", 8, statuses: [.cancelled]), previous: nil).id
        let back = CalendarLessonChange(kinds: [.reinstated], lesson: lesson("1", "2026-11-12", 8), previous: nil).id
        let other = CalendarLessonChange(kinds: [.cancelled], lesson: lesson("2", "2026-11-12", 9, statuses: [.cancelled]), previous: nil).id
        var history: [String] = []
        func record(_ id: String) -> (id: String, isNew: Bool) {
            let result = CalendarChangeRepeats.resolve(id, earlier: history)
            if result.isNew { history.append(result.id) }
            return result
        }
        XCTAssertEqual(record(cancelled).id, cancelled)
        XCTAssertFalse(record(cancelled).isNew, "dieselbe Änderung erneut erkannt")
        XCTAssertEqual(record(other).id, other, "andere Stunde stört nicht")
        XCTAssertEqual(record(back).id, back)
        let again = record(cancelled)
        XCTAssertTrue(again.isNew, "Ausfall → findet statt → Ausfall")
        XCTAssertEqual(again.id, cancelled + "~2")
        let detectedAgain = record(cancelled)
        XCTAssertFalse(detectedAgain.isNew)
        XCTAssertEqual(detectedAgain.id, cancelled + "~2", "die jüngste Eintragung dieser Stunde")
        XCTAssertEqual(record(back).id, back + "~2")
        XCTAssertEqual(record(cancelled).id, cancelled + "~3")
        XCTAssertEqual(history, [cancelled, other, back, cancelled + "~2", back + "~2", cancelled + "~3"])
        // Unparseable ids: plain dedupe by id.
        XCTAssertFalse(CalendarChangeRepeats.resolve("x", earlier: ["x"]).isNew)
        XCTAssertTrue(CalendarChangeRepeats.resolve("y", earlier: ["x"]).isNew)
    }

    func testBellRecordsTheRepeatOnceAndMatchesBothOriginsByGeneration() {
        let old = lesson("77", "2026-11-12", 8)
        let cancelled = CalendarLessonChange(kinds: [.cancelled], lesson: lesson("77", "2026-11-12", 8, statuses: [.cancelled]), previous: old)
        let back = CalendarLessonChange(kinds: [.reinstated], lesson: old, previous: cancelled.lesson)
        func local(_ change: CalendarLessonChange, _ minutes: Double) -> CalendarNotificationRecord {
            CalendarNotificationRecord(change: change, date: now.addingTimeInterval(minutes * 60), calendar: berlin, namespace: namespace)
        }
        func push(_ raw: String, _ minutes: Double) -> CalendarNotificationRecord {
            CalendarNotificationRecord(id: CalendarNotificationLog.pushChangeID(namespace: namespace, changeID: raw), kind: .change,
                                       title: CalendarLessonChange.notificationTitle, body: "", date: now.addingTimeInterval(minutes * 60),
                                       day: day("2026-11-12"), entryID: old.id)
        }
        // App alone: Ausfall, findet statt, Ausfall again.
        var log = CalendarNotificationLog()
        for (change, minutes) in [(cancelled, 0.0), (back, 60), (cancelled, 120)] {
            let records = log.identifyingRepeats([local(change, minutes)])
            XCTAssertEqual(log.addChanges(records, now: now).count, 1)
        }
        let ids = log.records.map(\.id)
        XCTAssertEqual(ids.first, local(cancelled, 0).id + "~2", "neuester zuerst, eigene ID")
        XCTAssertEqual(Set(ids).count, 3)
        // Detected again (same state): the newest entry's id, left out by addChanges.
        let again = log.identifyingRepeats([local(cancelled, 180)])
        XCTAssertEqual(again.map(\.id), [local(cancelled, 0).id + "~2"])
        XCTAssertEqual(log.addChanges(again, now: now).count, 0)
        // A delivered notification collected again keeps its id (no new repeat).
        XCTAssertEqual(log.addChanges([local(cancelled, 0)], now: now).count, 0)
        // Other kinds and other records pass unchanged.
        let event = CalendarNotificationRecord(id: "noty.calendar.event.1", kind: .event, title: "T", body: "", date: now)
        XCTAssertEqual(log.identifyingRepeats([event]), [event])

        // The server's entries of the same three changes: each matched with the app's (generation counts).
        XCTAssertEqual(log.addChanges([push(cancelled.id, 1), push(back.id, 61), push(cancelled.id + "~2", 121)], now: now).count, 0)
        XCTAssertEqual(CalendarNotificationLog.changeMatchKey(push(cancelled.id + "~2", 0).id),
                       CalendarNotificationLog.changeMatchKey(local(cancelled, 0).id + "~2"))
        XCTAssertNotEqual(CalendarNotificationLog.changeMatchKey(push(cancelled.id + "~2", 0).id),
                          CalendarNotificationLog.changeMatchKey(local(cancelled, 0).id))

        // App saw the first Ausfall only, the server all three: the repeat comes from the server.
        var partial = CalendarNotificationLog()
        partial.addChanges(partial.identifyingRepeats([local(cancelled, 0)]), now: now)
        let added = partial.addChanges([push(cancelled.id, 1), push(back.id, 61), push(cancelled.id + "~2", 121)], now: now)
        XCTAssertEqual(added.map(\.id), [push(back.id, 61).id, push(cancelled.id + "~2", 121).id])
        XCTAssertEqual(CalendarNotificationLog.pushRawChangeID(push(cancelled.id + "~2", 0).id), cancelled.id + "~2")
        XCTAssertEqual(partial.relatedChangeIDs(push(cancelled.id, 1).id), [push(cancelled.id, 1).id, local(cancelled, 0).id])
    }

    // MARK: Empty answers

    func testAnEmptiedDayIsNotComparedAndLessonsComingBackAreNotAdded() throws {
        let substitution = lesson("7", "2026-11-10", 9, subject: "Biologie", statuses: [.substitution])
        let full = snapshot([lesson("1", "2026-11-10", 8), substitution, lesson("3", "2026-11-11", 8)], days: week, time: 100)
        // WebUntis answers without any period for Tuesday and Wednesday.
        let empty = snapshot([], days: week, time: 200)
        XCTAssertEqual(CalendarChangeDetector.comparedDays(old: full, new: empty), [day("2026-11-09"), day("2026-11-12"), day("2026-11-13")])
        XCTAssertTrue(CalendarChangeDetector.changes(old: full, new: empty, now: now, calendar: berlin).isEmpty)
        // The lessons come back (the app's display took the empty days over): nothing is „zusätzlich“.
        let back = snapshot(full.lessons, days: week, time: 300)
        XCTAssertTrue(CalendarChangeDetector.changes(old: empty, new: back, now: now, calendar: berlin).isEmpty)
        // A new irregular period on a day with lessons is still reported.
        let added = snapshot(full.lessons + [lesson("8", "2026-11-11", 10, subject: "Sport", statuses: [.substitution])], days: week, time: 400)
        XCTAssertEqual(CalendarChangeDetector.changes(old: back, new: added, now: now, calendar: berlin).map(\.kinds), [[.added]])
        // … but not on a day without lessons before (no reference).
        let freeDay = snapshot(full.lessons + [lesson("9", "2026-11-13", 10, subject: "Sport", statuses: [.substitution])], days: week, time: 400)
        XCTAssertTrue(CalendarChangeDetector.changes(old: back, new: freeDay, now: now, calendar: berlin).isEmpty)
    }

    func testMergeKeepingEmptiedDaysKeepsTheComparisonBase() throws {
        let start = day("2026-11-09"), end = day("2026-11-14")
        var base = CalendarSourceSnapshot(connection: connection)
        try base.merge(CalendarTimetableFetch(connection: connection, start: start, end: end, fetchedAt: Date(timeIntervalSinceReferenceDate: 100),
                                              lessons: [lesson("1", "2026-11-10", 8), lesson("3", "2026-11-11", 8)]))
        let emptyFetch = CalendarTimetableFetch(connection: connection, start: start, end: end, fetchedAt: Date(timeIntervalSinceReferenceDate: 200),
                                                lessons: [lesson("3", "2026-11-11", 8)])
        XCTAssertEqual(base.emptiedDays(by: emptyFetch), [day("2026-11-10")])
        var kept = base
        let taken = try kept.mergeKeepingEmptiedDays(emptyFetch)
        XCTAssertEqual(taken, 4)
        XCTAssertEqual(kept.lessons.map(\.key.sourceID), ["1", "3"], "Dienstag behält seine Stunde")
        XCTAssertEqual(kept.days["2026-11-10"], 100, "und seinen Abrufzeitpunkt")
        XCTAssertEqual(kept.days["2026-11-11"], 200)
        XCTAssertNoThrow(try kept.validate())
        // The plain merge (what the app shows) takes the empty day over.
        var shown = base
        let all = try shown.merge(emptyFetch)
        XCTAssertEqual(all, 5)
        XCTAssertEqual(shown.lessons.map(\.key.sourceID), ["3"])
    }

    // MARK: Shared texts, keys, defaults

    func testSummaryFromTextsEqualsSummaryFromChanges() {
        let changes = (1...4).map { CalendarLessonChange(kinds: [.cancelled], lesson: lesson("\($0)", "2026-11-12", 7 + $0, statuses: [.cancelled]), previous: nil) }
        let fromChanges = CalendarLessonChange.summary(changes, calendar: berlin)
        let fromTexts = CalendarLessonChange.summary(bodies: changes.map { $0.text(calendar: berlin) })
        XCTAssertEqual(fromChanges.title, fromTexts.title)
        XCTAssertEqual(fromChanges.body, fromTexts.body)
        XCTAssertEqual(fromTexts.title, "4 Stundenplanänderungen")
        XCTAssertTrue(fromTexts.body.hasSuffix("\n…"))
        XCTAssertEqual(CalendarLessonChange.summary(bodies: ["A"]).title, CalendarLessonChange.notificationTitle)
        XCTAssertEqual(CalendarLessonChange.summary(bodies: ["A"]).body, "A")
        XCTAssertEqual(CalendarLessonChange.notificationTitle, "Stundenplanänderung")
        let record = CalendarNotificationRecord(change: changes[0], date: now, calendar: berlin, namespace: namespace)
        XCTAssertEqual(record.title, CalendarLessonChange.notificationTitle)
    }

    func testPushPayloadKeysAndDefaultsStayAsTheAppAndServerUseThem() {
        XCTAssertEqual(CalendarPushPayload.rootKey, "noty")
        XCTAssertEqual(CalendarPushPayload.Key.allCases.map(\.rawValue),
                       ["kind", "connectionID", "changeID", "changeIDs", "day", "entryID", "periodID", "lessonStart"])
        XCTAssertEqual(CalendarPushPayload.Kind.allCases.map(\.rawValue), ["change", "summary", "auth", "test"])
        XCTAssertEqual(CalendarDefaults.timeZoneIdentifier, "Europe/Berlin")
        XCTAssertEqual(CalendarDefaults.timeZone.identifier, "Europe/Berlin")
        XCTAssertEqual(CalendarConnectionRecord(label: "x").timeZone, CalendarDefaults.timeZoneIdentifier)
        XCTAssertEqual("  a ".nilIfBlank, "a")
        XCTAssertNil(" \n".nilIfBlank)
    }

    // MARK: Gegen-Review 08.11.2026

    func testARoomWithTildeAndDigitsIsNoRepeatGeneration() throws {
        let change = CalendarLessonChange(kinds: [.roomChanged], lesson: lesson("5", "2026-11-12", 8, rooms: ["R~2"]),
                                          previous: lesson("5", "2026-11-12", 8))
        XCTAssertTrue(change.id.hasSuffix(".R%7E2"), change.id)
        let parsed = try XCTUnwrap(CalendarChangeID(change.id))
        XCTAssertEqual(parsed.generation, 1)
        XCTAssertEqual(parsed.rooms, "R%7E2")
        XCTAssertEqual(parsed.base, change.id)
        // The repeat of it carries the generation behind the escaped room.
        let first = CalendarChangeRepeats.resolve(change.id, earlier: [])
        XCTAssertEqual(first.id, change.id)
        let other = CalendarLessonChange(kinds: [.cancelled], lesson: lesson("5", "2026-11-12", 8, statuses: [.cancelled]), previous: nil).id
        let again = CalendarChangeRepeats.resolve(change.id, earlier: [change.id, other])
        XCTAssertTrue(again.isNew)
        XCTAssertEqual(again.id, change.id + "~2")
        XCTAssertEqual(CalendarChangeID(again.id)?.generation, 2)
        XCTAssertEqual(CalendarChangeID(again.id)?.rooms, "R%7E2")
        // Rooms without „~“ keep their ids.
        let plain = CalendarLessonChange(kinds: [.roomChanged], lesson: lesson("5", "2026-11-12", 8, rooms: ["R 1.12"]), previous: nil)
        XCTAssertTrue(plain.id.hasSuffix(".R 1.12"))
    }

    func testADayWhoseLessonsAllMovedIsComparedAndReportedAsMoved() throws {
        let start = day("2026-11-09"), end = day("2026-11-14")
        var base = CalendarSourceSnapshot(connection: connection)
        try base.merge(CalendarTimetableFetch(connection: connection, start: start, end: end, fetchedAt: Date(timeIntervalSinceReferenceDate: 100),
                                              lessons: [lesson("1", "2026-11-10", 8), lesson("2", "2026-11-10", 9), lesson("3", "2026-11-11", 8)]))
        // Tuesday's two periods moved to Thursday (same period ids), Tuesday comes back empty.
        let moved = CalendarTimetableFetch(connection: connection, start: start, end: end, fetchedAt: Date(timeIntervalSinceReferenceDate: 200),
                                           lessons: [lesson("3", "2026-11-11", 8), lesson("1", "2026-11-12", 8), lesson("2", "2026-11-12", 9)])
        XCTAssertEqual(base.emptiedDays(by: moved), [], "verlegt, keine leere Antwort")
        var server = base
        XCTAssertEqual(try server.mergeKeepingEmptiedDays(moved), 5)
        XCTAssertEqual(server.lessons(on: day("2026-11-10"))?.count, 0)
        XCTAssertTrue(CalendarChangeDetector.comparedDays(old: base, new: server).contains(day("2026-11-10")))
        let changes = CalendarChangeDetector.changes(old: base, new: server, now: now, calendar: berlin)
        XCTAssertEqual(changes.map(\.kinds), [[.moved], [.moved]])
        XCTAssertEqual(changes.map(\.lesson.key.sourceID), ["1", "2"])
        // The app (plain merge) finds the same.
        var shown = base
        try shown.merge(moved)
        XCTAssertEqual(CalendarChangeDetector.changes(old: base, new: shown, now: now, calendar: berlin).count, 2)
        // A day that only comes back empty (nothing of it elsewhere) stays an empty answer.
        let empty = CalendarTimetableFetch(connection: connection, start: start, end: end, fetchedAt: Date(timeIntervalSinceReferenceDate: 200),
                                           lessons: [lesson("3", "2026-11-11", 8)])
        XCTAssertEqual(base.emptiedDays(by: empty), [day("2026-11-10")])
        var kept = base
        try kept.merge(empty)
        XCTAssertFalse(CalendarChangeDetector.comparedDays(old: base, new: kept).contains(day("2026-11-10")))
    }

    func testTheAppAnnouncesARepeatAfterTheServerRecordedSomethingElse() {
        let old = lesson("77", "2026-11-12", 8)
        let cancelled = CalendarLessonChange(kinds: [.cancelled], lesson: lesson("77", "2026-11-12", 8, statuses: [.cancelled]), previous: old)
        let back = CalendarLessonChange(kinds: [.reinstated], lesson: old, previous: cancelled.lesson)
        func local(_ change: CalendarLessonChange, _ minutes: Double) -> CalendarNotificationRecord {
            CalendarNotificationRecord(change: change, date: now.addingTimeInterval(minutes * 60), calendar: berlin, namespace: namespace)
        }
        func push(_ raw: String, _ minutes: Double) -> CalendarNotificationRecord {
            CalendarNotificationRecord(id: CalendarNotificationLog.pushChangeID(namespace: namespace, changeID: raw), kind: .change,
                                       title: CalendarLessonChange.notificationTitle, body: "", date: now.addingTimeInterval(minutes * 60),
                                       day: day("2026-11-12"), entryID: old.id)
        }
        // App: Ausfall. Server (only): findet wieder statt. Then the app sees Ausfall again (push not in charge).
        var log = CalendarNotificationLog()
        log.addChanges(log.identifyingRepeats([local(cancelled, 0)]), now: now)
        log.addChanges([push(back.id, 60)], now: now)
        let again = log.identifyingRepeats([local(cancelled, 120)])
        XCTAssertEqual(again.map(\.id), [local(cancelled, 0).id + "~2"], "eine weitere Änderung, nicht die alte")
        XCTAssertEqual(log.addChanges(again, now: now).count, 1)
        // Detected once more: the same as the newest entry, left out.
        XCTAssertEqual(log.addChanges(log.identifyingRepeats([local(cancelled, 180)]), now: now).count, 0)

        // The server said the same since (its own Ausfall): still only once.
        var same = CalendarNotificationLog()
        same.addChanges(same.identifyingRepeats([local(cancelled, 0)]), now: now)
        same.addChanges([push(cancelled.id, 5)], now: now)
        XCTAssertEqual(same.identifyingRepeats([local(cancelled, 120)]).map(\.id), [local(cancelled, 0).id])
        XCTAssertEqual(same.addChanges(same.identifyingRepeats([local(cancelled, 120)]), now: now).count, 0)
    }
}
