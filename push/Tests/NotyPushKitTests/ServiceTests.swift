import Foundation
import XCTest
import NotebookCore
@testable import NotyPushKit

final class ServiceTests: XCTestCase {
    var clock: Clock!
    var source: StubSource!
    var sender: MockSender!
    var dir: String!

    // Monday 09.11.2026; lessons on Tuesday and Wednesday.
    let deutsch = { lesson(1, at(2026, 11, 10, 8, 0), subject: "Deutsch", subjectID: "2") }
    let mathe = { lesson(2, at(2026, 11, 10, 9, 45), subject: "Mathematik", subjectID: "1") }
    let englisch = { lesson(3, at(2026, 11, 11, 8, 0), subject: "Englisch", subjectID: "3") }

    override func setUp() {
        clock = Clock(at(2026, 11, 9, 10, 3))
        source = StubSource()
        source.lessons = [deutsch(), mathe(), englisch()]
        sender = MockSender()
        dir = temporaryDirectory()
    }

    func service(_ config: PushConfig = testConfig()) throws -> PushService {
        try makeService(dir: dir, config: config, source: source, sender: sender, clock: clock)
    }

    func cancelled(_ lesson: CalendarLesson) -> CalendarLesson {
        var copy = lesson; copy.statuses = [.cancelled]; copy.rawStates = ["CANCELLED"]; return copy
    }

    func testFirstFetchIsBaselineAndAChangeIsPushedOnce() async throws {
        let service = try service()
        let registered = try await service.register(registration())
        XCTAssertEqual(sender.sent.count, 0, "Basis: keine Mitteilung")
        XCTAssertEqual(source.calls, 1)
        XCTAssertNotNil(registered.status.baselineAt)
        XCTAssertGreaterThan(registered.status.nextPoll, clock.now)

        clock.set(at(2026, 11, 9, 11, 7))
        source.lessons = [cancelled(deutsch()), mathe(), englisch()]
        await service.poll(registered.deviceID)
        XCTAssertEqual(sender.sent.count, 1)
        let (message, target) = sender.sent[0]
        XCTAssertEqual(message.title, "Stundenplanänderung")
        XCTAssertEqual(message.body, "Di 10.11., 08:00 Deutsch fällt aus")
        XCTAssertEqual(target.topic, bundleID)
        XCTAssertEqual(target.environment, .sandbox)
        XCTAssertEqual(message.threadID, "noty.calendar.changes.\(connectionID.uuidString)")
        XCTAssertEqual(message.expiration, at(2026, 11, 10, 8, 0))
        // The change id is the one Core computes (the app dedupes with it).
        let changeID = try XCTUnwrap(message.data["changeID"])
        guard case .string(let id) = changeID else { return XCTFail() }
        XCTAssertTrue(id.hasPrefix("change.1.2026-11-10.cancelled."))
        XCTAssertEqual(message.collapseID, id)
        XCTAssertEqual(message.data["periodID"], .string("1"))
        XCTAssertEqual(message.data["day"], .string("2026-11-10"))
        XCTAssertEqual(message.data["entryID"], .string(deutsch().id))
        XCTAssertEqual(message.data["kind"], .string("change"))

        // Same state again: nothing new.
        clock.set(at(2026, 11, 9, 12, 7))
        await service.poll(registered.deviceID)
        XCTAssertEqual(sender.sent.count, 1)
        let history = try await service.changes(id: registered.deviceID, since: nil)
        XCTAssertEqual(history.changes.map(\.delivery), [.sent])
        XCTAssertEqual(history.changes.first?.id, id)
        let none = try await service.changes(id: registered.deviceID, since: at(2026, 11, 9, 11, 30))
        XCTAssertTrue(none.changes.isEmpty)
    }

    func testDetectedIDMatchesCoreDetectorDirectly() async throws {
        var old = CalendarSourceSnapshot(connection: connectionID)
        try old.merge(CalendarTimetableFetch(connection: connectionID, start: CivilDate("2026-11-09")!, end: CivilDate("2026-11-23")!,
                                             fetchedAt: at(2026, 11, 9, 10), lessons: [deutsch()]))
        var new = old
        try new.merge(CalendarTimetableFetch(connection: connectionID, start: CivilDate("2026-11-09")!, end: CivilDate("2026-11-23")!,
                                             fetchedAt: at(2026, 11, 9, 11), lessons: [cancelled(deutsch())]))
        let core = CalendarChangeDetector.changes(old: old, new: new, now: at(2026, 11, 9, 11), calendar: berlinCalendar)
        let adapted = CoreChangeDetector().changes(old: old, new: new, now: at(2026, 11, 9, 11), calendar: berlinCalendar)
        XCTAssertEqual(core.map(\.id), adapted.map(\.id))
        XCTAssertEqual(adapted.map(\.kinds), [["cancelled"]])
        XCTAssertEqual(adapted.first?.text, core.first?.text(calendar: berlinCalendar))
    }

    func testQuietHoursCollectAndSendOneSummaryAtSix() async throws {
        let service = try service()
        let id = try await service.register(registration()).deviceID
        clock.set(at(2026, 11, 9, 21, 30))
        var moved = mathe(); moved.rooms = ["R202"]
        source.lessons = [deutsch(), moved, englisch()]
        await service.poll(id)
        clock.set(at(2026, 11, 9, 22, 30))
        source.lessons = [deutsch(), moved, cancelled(englisch())]
        await service.poll(id)
        XCTAssertEqual(sender.sent.count, 0, "Ruhezeit: keine Mitteilung")
        clock.set(at(2026, 11, 10, 5, 59))
        await service.tick()
        XCTAssertEqual(sender.sent.count, 0)
        clock.set(at(2026, 11, 10, 6, 0))
        await service.tick()
        XCTAssertEqual(sender.sent.count, 1)
        let message = sender.sent[0].0
        XCTAssertEqual(message.title, "2 Stundenplanänderungen")
        XCTAssertEqual(message.body, "Di 10.11., 09:45 Mathematik jetzt in R202 (statt R101)\nMi 11.11., 08:00 Englisch fällt aus")
        XCTAssertEqual(message.data["kind"], .string("summary"))
        guard case .strings(let ids)? = message.data["changeIDs"] else { return XCTFail() }
        XCTAssertEqual(ids.count, 2)
        let history = try await service.changes(id: id, since: nil).changes
        XCTAssertEqual(Set(history.map(\.delivery)), [.summarized])
        await service.tick()
        XCTAssertEqual(sender.sent.count, 1, "nicht doppelt")
    }

    func testPendingChangeExpiresWhenLessonBegan() async throws {
        let service = try service()
        let id = try await service.register(registration()).deviceID
        clock.set(at(2026, 11, 10, 5, 10))  // Tuesday 5:10, quiet until 6
        source.lessons = [cancelled(deutsch()), mathe(), englisch()]
        // Quiet end moved to 9:00 for this test: the 8:00 lesson begins first.
        var settings = DeviceSettings(); settings.quietEnd = 9 * 60
        _ = try await service.update(id: id, UpdateInput(settings: settings))
        await service.poll(id)
        clock.set(at(2026, 11, 10, 9, 0))
        await service.tick()
        XCTAssertEqual(sender.sent.count, 0)
        let deliveries = try await service.changes(id: id, since: nil).changes.map(\.delivery)
        XCTAssertEqual(deliveries, [.expired])
    }

    func testErrorsAndVanishedLessonsNeverBecomeCancellations() async throws {
        let service = try service()
        let id = try await service.register(registration()).deviceID
        let before = await service.record(id)!.snapshot
        clock.set(at(2026, 11, 9, 11, 7))
        source.error = WebUntisError.invalidResponse("Format")
        await service.poll(id)
        var record = await service.record(id)!
        XCTAssertEqual(record.failures, 1)
        XCTAssertEqual(record.snapshot, before, "Fehler ersetzt den Vergleichsstand nicht")
        XCTAssertNotNil(record.lastError)
        XCTAssertEqual(record.nextPoll, at(2026, 11, 9, 12, record.pollMinute(spread: 15)))
        source.error = TransportError.timeout
        await service.poll(id)
        source.error = nil
        // A lesson missing from the answer is not reported as cancelled.
        source.lessons = [deutsch(), mathe()]
        clock.set(at(2026, 11, 9, 14, 7))
        await service.poll(id)
        XCTAssertEqual(sender.sent.count, 0)
        record = await service.record(id)!
        XCTAssertEqual(record.failures, 0)
        XCTAssertNil(record.lastError)
    }

    func testRepeatedAuthFailureMarksDeviceAndPushesOneNotice() async throws {
        let service = try service()
        let id = try await service.register(registration()).deviceID
        clock.set(at(2026, 11, 9, 11, 7))
        source.error = WebUntisError.server(code: -8504, message: "bad credentials")
        await service.poll(id)
        var state = await service.record(id)!.state
        XCTAssertEqual(state, .active, "einmalig: noch kein Zugangsproblem")
        clock.set(at(2026, 11, 9, 12, 7))
        await service.poll(id)
        state = await service.record(id)!.state
        XCTAssertEqual(state, .authFailed)
        await service.tick()
        XCTAssertEqual(sender.sent.count, 1)
        XCTAssertEqual(sender.sent[0].0.title, "Untis-Zugang prüfen")
        XCTAssertEqual(sender.sent[0].0.data["kind"], .string("auth"))
        let calls = source.calls
        clock.set(at(2026, 11, 9, 15, 7))
        await service.tick()
        XCTAssertEqual(source.calls, calls, "kein Abruf mehr mit abgelehnter Freigabe")
        XCTAssertEqual(sender.sent.count, 1, "Hinweis nur einmal")
        // The same Freigabe sent again (the app reached WebUntis with it) is a retry.
        source.error = nil
        let retried = try await service.update(id: id, UpdateInput(setup: setup()))
        XCTAssertEqual(retried.state, .active, "erneut gesendete gleiche Freigabe startet neu")
        source.error = WebUntisError.server(code: -8504, message: "bad credentials")
        clock.set(at(2026, 11, 9, 16, 7)); await service.poll(id)
        clock.set(at(2026, 11, 9, 17, 7)); await service.poll(id)
        state = await service.record(id)!.state
        XCTAssertEqual(state, .authFailed)
        // A new Freigabe (PUT) makes it active again with a new baseline.
        source.error = nil
        var other = setup(); other.user = "max.muster2"
        let status = try await service.update(id: id, UpdateInput(setup: other))
        XCTAssertEqual(status.state, .active)
    }

    func testInvalidTokenPausesDeviceUntilNewToken() async throws {
        let service = try service()
        let id = try await service.register(registration()).deviceID
        sender.result = .invalidToken("BadDeviceToken")
        clock.set(at(2026, 11, 9, 11, 7))
        source.lessons = [cancelled(deutsch()), mathe(), englisch()]
        await service.poll(id)
        var record = await service.record(id)!
        XCTAssertEqual(record.state, .tokenInvalid)
        let calls = source.calls
        clock.set(at(2026, 11, 9, 13, 7))
        await service.tick()
        XCTAssertEqual(source.calls, calls)
        sender.result = .delivered
        let newToken = String(repeating: "cd", count: 32)
        _ = try await service.update(id: id, UpdateInput(deviceToken: newToken))
        record = await service.record(id)!
        XCTAssertEqual(record.state, .active)
        XCTAssertEqual(record.deviceToken, newToken)
    }

    func testDeleteDuringPollDoesNotResurrectDevice() async throws {
        let service = try service()
        let id = try await service.register(registration()).deviceID
        source.duringLoad = { try? await service.delete(id: id) }
        clock.set(at(2026, 11, 9, 11, 7))
        await service.poll(id)
        let record = await service.record(id)
        XCTAssertNil(record)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir + "/devices/\(id).sealed"))
    }

    func testDisabledChangesAreOnlyHistory() async throws {
        let service = try service()
        var input = registration(); input.settings.changes = false
        let id = try await service.register(input).deviceID
        clock.set(at(2026, 11, 9, 11, 7))
        source.lessons = [cancelled(deutsch()), mathe(), englisch()]
        await service.poll(id)
        XCTAssertEqual(sender.sent.count, 0)
        let deliveries = try await service.changes(id: id, since: nil).changes.map(\.delivery)
        XCTAssertEqual(deliveries, [.disabled])
    }

    func testManyChangesAtOnceBecomeOneSummary() async throws {
        let service = try service()
        source.lessons = (0..<6).map { lesson(10 + $0, at(2026, 11, 10, 8 + $0)) }
        let id = try await service.register(registration()).deviceID
        clock.set(at(2026, 11, 9, 11, 7))
        source.lessons = (0..<6).map { cancelled(lesson(10 + $0, at(2026, 11, 10, 8 + $0))) }
        await service.poll(id)
        XCTAssertEqual(sender.sent.count, 1)
        XCTAssertEqual(sender.sent[0].0.title, "6 Stundenplanänderungen")
        XCTAssertTrue(sender.sent[0].0.body.hasSuffix("\n…"))
    }

    func testTwoChangesOutsideQuietHoursAreSingleNotifications() async throws {
        let service = try service()
        let id = try await service.register(registration()).deviceID
        clock.set(at(2026, 11, 9, 11, 7))
        source.lessons = [cancelled(deutsch()), mathe(), cancelled(englisch())]
        await service.poll(id)
        XCTAssertEqual(sender.sent.map(\.0.title), ["Stundenplanänderung", "Stundenplanänderung"])
    }

    func testDeviceLimitAndReRegistrationReplacesOldEntry() async throws {
        var config = testConfig(); config.maxDevices = 1
        let service = try service(config)
        let first = try await service.register(registration())
        do { _ = try await service.register(registration(token: String(repeating: "ef", count: 32))); XCTFail() }
        catch { XCTAssertEqual(error as? ServiceError, .limitReached) }
        let again = try await service.register(registration())
        XCTAssertNotEqual(first.deviceID, again.deviceID)
        let count = await service.deviceCount
        XCTAssertEqual(count, 1)
        let authenticatedOld = await service.authenticate(id: first.deviceID, secret: first.secret)
        let authenticatedNew = await service.authenticate(id: again.deviceID, secret: again.secret)
        XCTAssertFalse(authenticatedOld)
        XCTAssertTrue(authenticatedNew)
    }

    func testRejectedFreigabeIsNotStored() async throws {
        let service = try service()
        source.error = WebUntisError.server(code: -8504, message: "bad credentials")
        do { _ = try await service.register(registration()); XCTFail() }
        catch { XCTAssertEqual(error as? ServiceError, .untis(.authentication)) }
        source.error = WebUntisError.http(503)
        do { _ = try await service.register(registration()); XCTFail() }
        catch { XCTAssertEqual(error as? ServiceError, .untis(.transient("WebUntis nicht erreichbar"))) }
        let count = await service.deviceCount
        XCTAssertEqual(count, 0)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir + "/devices"), [])
    }

    func testMissedPollAtNightIsNotMadeUp() async throws {
        let service = try service()
        let id = try await service.register(registration()).deviceID
        let calls = source.calls
        clock.set(at(2026, 11, 9, 23, 0))
        await service.tick()
        XCTAssertEqual(source.calls, calls)
        let next = await service.record(id)!.nextPoll
        XCTAssertEqual(berlinCalendar.component(.hour, from: next), 5)
        clock.set(next)
        await service.tick()
        XCTAssertEqual(source.calls, calls + 1)
    }

    func testRestartKeepsStateAndSnapshotTrimmed() async throws {
        let id: String
        do {
            let service = try service()
            id = try await service.register(registration()).deviceID
        }
        // Next week: old days are trimmed from the comparison snapshot.
        clock.set(at(2026, 11, 16, 10, 7))
        let reopened = try service()
        await reopened.poll(id)
        let snapshot = await reopened.record(id)!.snapshot!
        XCTAssertFalse(snapshot.days.keys.contains("2026-11-10"))
        XCTAssertTrue(snapshot.homework.isEmpty)
        XCTAssertTrue(snapshot.holidays.isEmpty)
    }
}
