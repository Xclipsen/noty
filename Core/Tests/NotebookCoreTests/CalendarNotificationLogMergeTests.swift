import XCTest
@testable import NotebookCore

/// Bell history: a notification shown or tapped before the stored history
/// was read (cold start by tapping a notification) is merged into it –
/// it never replaces it. Fictitious data only.
final class CalendarNotificationLogMergeTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_794_000_000)

    private func record(_ id: String, minutesAgo: Double, read: Bool = false, kind: CalendarNotificationRecord.Kind = .event) -> CalendarNotificationRecord {
        CalendarNotificationRecord(id: id, kind: kind, title: "Titel \(id)", body: "Text", date: now.addingTimeInterval(-minutesAgo * 60),
                                   day: CivilDate("2026-11-12"), entryID: "entry-\(id)", read: read)
    }

    /// A history as stored on disk: read back from its bytes.
    private func stored(_ records: [CalendarNotificationRecord]) throws -> CalendarNotificationLog {
        var log = CalendarNotificationLog()
        log.add(records, now: now)
        return try XCTUnwrap(CalendarNotificationLog.decode(try log.encoded()))
    }

    func testEarlyDeliveryIsAddedAndTheStoredHistoryIsKept() throws {
        let before = try stored([record("alt-gelesen", minutesAgo: 300, read: true), record("alt-ungelesen", minutesAgo: 200),
                                 record("alt-neuer", minutesAgo: 100)])
        XCTAssertEqual(before.unreadCount, 2)
        // The tapped notification arrives while the model still starts.
        let merged = CalendarNotificationLog.merging(stored: before, early: [record("angetippt", minutesAgo: 1)], now: now)
        XCTAssertEqual(merged.added.map(\.id), ["angetippt"])
        // Newest first, nothing lost, read state as stored.
        XCTAssertEqual(merged.log.records.map(\.id), ["angetippt", "alt-neuer", "alt-ungelesen", "alt-gelesen"])
        XCTAssertEqual(merged.log.records.map(\.read), [false, false, false, true])
        XCTAssertEqual(merged.log.unreadCount, 3)
        // What is written afterwards holds all of it.
        let written = try XCTUnwrap(CalendarNotificationLog.decode(try merged.log.encoded()))
        XCTAssertEqual(written.records.map(\.id), ["angetippt", "alt-neuer", "alt-ungelesen", "alt-gelesen"])
    }

    func testKnownEntriesAreNotAddedAgainAndStayRead() throws {
        let before = try stored([record("a", minutesAgo: 300, read: true), record("b", minutesAgo: 200)])
        // The same notification seen twice before the read, and one that is stored (and read) already.
        let early = [record("neu", minutesAgo: 2), record("neu", minutesAgo: 2), record("a", minutesAgo: 300), record("b", minutesAgo: 200)]
        let merged = CalendarNotificationLog.merging(stored: before, early: early, now: now)
        XCTAssertEqual(merged.added.map(\.id), ["neu"])
        XCTAssertEqual(merged.log.records.map(\.id), ["neu", "b", "a"])
        let a = try XCTUnwrap(merged.log.records.first { $0.id == "a" })
        XCTAssertTrue(a.read)
        XCTAssertEqual(merged.log.unreadCount, 2)
    }

    func testNothingEarlyLeavesTheStoredHistoryAsItIs() throws {
        let before = try stored([record("a", minutesAgo: 300, read: true), record("b", minutesAgo: 200)])
        let merged = CalendarNotificationLog.merging(stored: before, early: [], now: now)
        XCTAssertEqual(merged.log, before)
        XCTAssertTrue(merged.added.isEmpty)
        // Only known entries: nothing to write either.
        let known = CalendarNotificationLog.merging(stored: before, early: [record("b", minutesAgo: 200)], now: now)
        XCTAssertTrue(known.added.isEmpty)
        XCTAssertEqual(known.log.records.map(\.id), before.records.map(\.id))
    }

    func testEarlyDeliveriesWithoutStoredHistory() {
        let merged = CalendarNotificationLog.merging(stored: CalendarNotificationLog(), early: [record("x", minutesAgo: 5), record("y", minutesAgo: 1)], now: now)
        XCTAssertEqual(merged.log.records.map(\.id), ["y", "x"])
        XCTAssertEqual(merged.added.map(\.id), ["x", "y"])
    }

    func testAChangeThePushServiceAlreadyStoredIsNotAddedByTheApp() throws {
        // The same timetable change, found by the server (stored, read) and delivered early by the app.
        let namespace = "calendar.abc"
        let id = try XCTUnwrap(sampleChangeID())
        XCTAssertNotNil(CalendarNotificationLog.changeMatchKey(CalendarNotificationLog.changePrefix + namespace + "." + id))
        let push = CalendarNotificationRecord(id: CalendarNotificationLog.pushChangeID(namespace: namespace, changeID: id), kind: .change,
                                              title: "Stundenplan", body: "Ausfall", date: now.addingTimeInterval(-600), read: true)
        let own = CalendarNotificationRecord(id: CalendarNotificationLog.changePrefix + namespace + "." + id, kind: .change,
                                             title: "Stundenplan", body: "Ausfall", date: now.addingTimeInterval(-60))
        let before = try stored([push])
        let merged = CalendarNotificationLog.merging(stored: before, early: [own], now: now)
        XCTAssertTrue(merged.added.isEmpty)
        XCTAssertEqual(merged.log.records.map(\.id), [push.id])
        XCTAssertEqual(merged.log.unreadCount, 0)
    }

    /// A raw change id („change.…“) as the change detection writes it: a cancelled lesson.
    private func sampleChangeID() -> String? {
        let connection = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
        let calendar = CalendarDates.german(timeZone: TimeZone(identifier: "Europe/Berlin")!)
        guard let day = CivilDate("2026-11-12") else { return nil }
        let start = day.start(in: calendar).addingTimeInterval(8 * 3600)
        let key = CalendarOccurrenceKey(provider: "webuntis", connection: connection, sourceID: "77", seriesID: "88", originalStart: "2026-11-12T08:00")
        let old = CalendarLesson(key: key, date: day, start: start, end: start.addingTimeInterval(45 * 60))
        var cancelled = old
        cancelled.statuses = [.cancelled]
        return CalendarLessonChange(kinds: [.cancelled], lesson: cancelled, previous: old).id
    }
}
