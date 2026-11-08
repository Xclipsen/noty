import Foundation
import XCTest
import Crypto
import NotebookCore
@testable import NotyPushKit

/// Findings of the review of 08.11.2026 (docs/PUSH.md): host allowlist,
/// rate limits, devices without contact, repeated changes, empty answers,
/// time zones, delivery state across device changes, APNs provider errors,
/// long requests. Fictitious data only.
final class ReviewFixTests: XCTestCase {
    var clock: Clock!
    var source: StubSource!
    var sender: MockSender!
    var dir: String!

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

    func changeID(_ message: PushMessage) -> String? {
        if case .string(let id)? = message.data[CalendarPushPayload.Key.changeID.rawValue] { return id }
        return nil
    }

    // MARK: 1 Host allowlist, rate limits, devices without contact

    func testOnlySubdomainsOfAllowedSuffixesWithoutPortOrIPAreAccepted() {
        let config = PushConfig()
        XCTAssertEqual(config.allowedUntisHostSuffixes, ["webuntis.com"])
        for host in ["schule.webuntis.com", "nessa.webuntis.com", "a-b.c.webuntis.com", "SCHULE.WebUntis.com"] {
            XCTAssertTrue(config.allowsUntisServer(host), host)
        }
        for host in ["webuntis.com", "schule.webuntis.com:8443", "evil.example", "webuntis.com.evil.example", "xwebuntis.com",
                     "x.notwebuntis.com", "127.0.0.1", "10.0.0.1:443", "[::1]", "-x.webuntis.com", "a..webuntis.com", ""] {
            XCTAssertFalse(config.allowsUntisServer(host), host)
        }
        var broken = testConfig(); broken.allowedUntisHostSuffixes = ["1.2"]
        XCTAssertFalse(broken.problems.isEmpty, "IP-Präfix als Domain")
        broken.allowedUntisHostSuffixes = []
        XCTAssertFalse(broken.problems.isEmpty)
        XCTAssertTrue(testConfig().problems.isEmpty)
        XCTAssertTrue(PushConfig.isHostSuffix("webuntis.com"))
        XCTAssertFalse(PushConfig.isHostSuffix("webuntis.com:443"))
    }

    func testRegistrationWithForeignServerIsRefusedWithoutAnyRequest() async throws {
        let service = try service()
        var input = registration()
        input.setup = try WebUntisSetup(server: "intranet.example.org", school: "s", user: "u", key: rfcKey)
        do { _ = try await service.register(input); XCTFail() } catch { XCTAssertEqual(error as? ServiceError, .serverNotAllowed) }
        XCTAssertEqual(source.calls, 0, "keine Anfrage an fremde Server")
        let router = APIRouter(service: service, config: testConfig(), now: { [clock] in clock!.now })
        let response = await router.handle(APIRequest(method: "POST", path: "/v1/register", headers: ["content-type": "application/json"],
                                                      body: Self.body(server: "https://192.168.0.1:8443/WebUntis"), clientIP: "198.51.100.1"))
        XCTAssertEqual(response.status, 400)
        XCTAssertEqual(Self.json(response)["error"] as? String, "invalid_server")
        XCTAssertEqual(source.calls, 0)
        // PUT with a new Freigabe for a foreign server: refused as well.
        let id = try await service.register(registration()).deviceID
        let calls = source.calls
        do { _ = try await service.update(id: id, UpdateInput(setup: input.setup)); XCTFail() }
        catch { XCTAssertEqual(error as? ServiceError, .serverNotAllowed) }
        XCTAssertEqual(source.calls, calls)
        // A stored Freigabe outside a narrowed list is not polled.
        var narrowed = testConfig(); narrowed.allowedUntisHostSuffixes = ["webuntis.com"]
        let reopened = try self.service(narrowed)
        clock.set(at(2026, 11, 9, 11, 7))
        await reopened.poll(id)
        XCTAssertEqual(source.calls, calls)
        let lastError = await reopened.record(id)?.lastError
        XCTAssertEqual(lastError, "WebUntis-Server nicht zugelassen")
    }

    func testDailyLimitCountsOnlySuccessfulRegistrations() async throws {
        var config = testConfig(); config.registrationsPerDay = 2; config.registrationsPerHourPerIP = 100
        let service = try service(config)
        let router = APIRouter(service: service, config: config, now: { [clock] in clock!.now })
        func post(_ body: Data, _ ip: String) async -> APIResponse {
            await router.handle(APIRequest(method: "POST", path: "/v1/register", headers: ["content-type": "application/json"],
                                           body: body, clientIP: ip))
        }
        for index in 0..<5 {
            let invalid = await post(Data("{".utf8), "198.51.100.\(index)")
            XCTAssertEqual(invalid.status, 400)
        }
        source.error = WebUntisError.server(code: -8504, message: "bad credentials")
        let rejected = await post(Self.body(), "198.51.100.20")
        XCTAssertEqual(rejected.status, 422, "abgelehnte Freigabe zählt nicht zum Tageslimit")
        source.error = nil
        let first = await post(Self.body(token: String(repeating: "a1", count: 32)), "198.51.100.21")
        let second = await post(Self.body(token: String(repeating: "a2", count: 32)), "198.51.100.22")
        XCTAssertEqual([first.status, second.status], [201, 201])
        let third = await post(Self.body(token: String(repeating: "a3", count: 32)), "198.51.100.23")
        XCTAssertEqual(third.status, 429)
        XCTAssertNotNil(third.retryAfter)
        XCTAssertTrue(third.headers.contains { $0.0 == "Retry-After" && Int($0.1) ?? 0 > 0 })
        // Per address every attempt still counts first.
        var strict = testConfig(); strict.registrationsPerHourPerIP = 1
        let limited = APIRouter(service: service, config: strict, now: { [clock] in clock!.now })
        _ = await limited.handle(APIRequest(method: "POST", path: "/v1/register", body: Data("{".utf8), clientIP: "203.0.113.5"))
        let again = await limited.handle(APIRequest(method: "POST", path: "/v1/register", body: Data("{".utf8), clientIP: "203.0.113.5"))
        XCTAssertEqual(again.status, 429)
        XCTAssertEqual(again.retryAfter, 3600)
    }

    func testFailedAuthenticationsAreLimitedWith429NeverWith401ForTheRightSecret() async throws {
        var config = testConfig(); config.requestsPerMinutePerIP = 100_000
        let service = try service(config)
        let router = APIRouter(service: service, config: config, now: { [clock] in clock!.now })
        let registered = try await service.register(registration())
        func get(_ secret: String) async -> APIResponse {
            await router.handle(APIRequest(method: "GET", path: "/v1/device", headers: ["authorization": "Bearer \(registered.deviceID).\(secret)"]))
        }
        // Successful requests never count.
        for _ in 0..<(APIRouter.authFailuresPerHour + 10) {
            let ok = await get(registered.secret)
            XCTAssertEqual(ok.status, 200)
        }
        let wrong = String(repeating: "x", count: 43)
        for _ in 0..<APIRouter.authFailuresPerHour {
            let failed = await get(wrong)
            XCTAssertEqual(failed.status, 401)
        }
        let limited = await get(wrong)
        XCTAssertEqual(limited.status, 429)
        let right = await get(registered.secret)
        XCTAssertEqual(right.status, 429, "richtiges Secret: 429 (App behält es), nicht 401")
        XCTAssertGreaterThan(right.retryAfter ?? 0, 0)
        XCTAssertEqual(Self.json(right)["error"] as? String, "rate_limited")
        clock.set(clock.now.addingTimeInterval(3601))
        let later = await get(registered.secret)
        XCTAssertEqual(later.status, 200)
    }

    func testDevicesWithoutContactAreDeletedAfterTheConfiguredDays() async throws {
        let service = try service()
        let router = APIRouter(service: service, config: testConfig(), now: { [clock] in clock!.now })
        XCTAssertEqual(PushConfig().noContactRetentionDays, 120, "länger als die Sommerferien")
        let silent = try await service.register(registration()).deviceID
        let used = try await service.register(registration(token: String(repeating: "cd", count: 32)))
        clock.set(clock.now.addingTimeInterval(46 * 86_400))
        await service.maintenance(now: clock.now)
        let afterHolidays = await service.record(silent)
        XCTAssertNotNil(afterHolidays, "46 Tage ohne Kontakt (Sommerferien): bleibt")
        clock.set(clock.now.addingTimeInterval(54 * 86_400))
        let response = await router.handle(APIRequest(method: "GET", path: "/v1/changes",
                                                      headers: ["authorization": "Bearer \(used.deviceID).\(used.secret)"]))
        XCTAssertEqual(response.status, 200)
        let contact = await service.record(used.deviceID)?.lastContact
        XCTAssertEqual(contact, clock.now, "authentifizierter Kontakt wird gespeichert")
        clock.set(clock.now.addingTimeInterval(21 * 86_400))
        await service.maintenance(now: clock.now)
        let gone = await service.record(silent)
        let kept = await service.record(used.deviceID)
        XCTAssertNil(gone, "121 Tage ohne Kontakt: gelöscht, auch wenn aktiv")
        XCTAssertNotNil(kept)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir + "/devices/\(silent).sealed"))
        // Records written before lastContact existed fall back to `updated`.
        var record = try XCTUnwrap(kept); record.lastContact = nil
        XCTAssertEqual(record.contact, record.updated)
        var config = testConfig(); config.noContactRetentionDays = 3
        XCTAssertFalse(config.problems.isEmpty, "mindestens 7 Tage")
    }

    // MARK: 2 The same change again after a different one

    func testCancellationAgainAfterReinstatementIsPushedAgain() async throws {
        let service = try service()
        let id = try await service.register(registration()).deviceID
        let states = [cancelled(deutsch()), deutsch(), cancelled(deutsch())]
        for (hour, state) in zip([11, 12, 13], states) {
            clock.set(at(2026, 11, 9, hour, 7))
            source.lessons = [state, mathe(), englisch()]
            await service.poll(id)
        }
        XCTAssertEqual(sender.sent.map(\.0.body), ["Di 10.11., 08:00 Deutsch fällt aus",
                                                   "Di 10.11., 08:00 Deutsch findet wieder statt in R101",
                                                   "Di 10.11., 08:00 Deutsch fällt aus"])
        let ids = sender.sent.compactMap { changeID($0.0) }
        XCTAssertEqual(ids.count, 3)
        XCTAssertEqual(ids[2], ids[0] + "~2", "erneuter Ausfall: eigene ID, die erste bleibt unverändert")
        XCTAssertFalse(ids[0].contains("~"))
        XCTAssertEqual(sender.sent[2].0.collapseID, ids[2])
        // The same state again: nothing new.
        clock.set(at(2026, 11, 9, 14, 7))
        await service.poll(id)
        XCTAssertEqual(sender.sent.count, 3)
        let history = try await service.changes(id: id, since: nil).changes
        XCTAssertEqual(history.map(\.id), ids)
        XCTAssertEqual(history.map(\.delivery), [.sent, .sent, .sent])
    }

    // MARK: 4 Empty answer of WebUntis

    func testEmptyAnswerKeepsTheComparisonBaseAndBringsNoAdditionsLater() async throws {
        var vertretung = deutsch(); vertretung.statuses = [.substitution]; vertretung.subjectLong = "Biologie"
        source.lessons = [vertretung, mathe(), englisch()]
        let service = try service()
        let id = try await service.register(registration()).deviceID
        clock.set(at(2026, 11, 9, 11, 7))
        source.lessons = []
        await service.poll(id)
        let kept = await service.record(id)!.snapshot!
        XCTAssertEqual(kept.lessons.count, 3, "Tage mit Unterricht, die leer zurückkommen, behalten ihren Stand")
        clock.set(at(2026, 11, 9, 12, 7))
        source.lessons = [vertretung, mathe(), englisch()]
        await service.poll(id)
        XCTAssertEqual(sender.sent.count, 0, "zurückkehrende Stunden sind nicht „zusätzlich“")
        // A real change after the gap is still found against the kept state.
        clock.set(at(2026, 11, 9, 13, 7))
        source.lessons = [vertretung, cancelled(mathe()), englisch()]
        await service.poll(id)
        XCTAssertEqual(sender.sent.map(\.0.body), ["Di 10.11., 09:45 Mathematik fällt aus"])
    }

    // MARK: 5 Time zones

    func testLessonsUseTheConnectionTimeZoneQuietHoursTheDevices() async throws {
        let service = try service()
        var input = registration(); input.timeZone = "America/New_York"
        let id = try await service.register(input).deviceID
        XCTAssertEqual(source.lastTimeZone?.identifier, CalendarDefaults.timeZoneIdentifier, "Stunden in der Zeitzone der Verbindung")
        var record = await service.record(id)!
        XCTAssertEqual(record.connectionTimeZone, "Europe/Berlin")
        XCTAssertEqual(record.connectionTimeZoneIdentifier, "Europe/Berlin")
        // 11:07 in Berlin is 05:07 in New York: quiet hours of the device.
        clock.set(at(2026, 11, 9, 11, 7))
        source.lessons = [cancelled(deutsch()), mathe(), englisch()]
        await service.poll(id)
        XCTAssertEqual(source.lastTimeZone?.identifier, "Europe/Berlin")
        XCTAssertEqual(sender.sent.count, 0)
        let bodies = try await service.changes(id: id, since: nil).changes.map(\.body)
        XCTAssertEqual(bodies, ["Di 10.11., 08:00 Deutsch fällt aus"])
        clock.set(at(2026, 11, 9, 12, 1))  // 06:01 in New York
        await service.tick()
        XCTAssertEqual(sender.sent.map(\.0.body), ["Di 10.11., 08:00 Deutsch fällt aus"], "Text in Schulzeit")
        // The device zone moves only the schedule: no new baseline.
        var calls = source.calls
        _ = try await service.update(id: id, UpdateInput(timeZone: "Europe/Berlin"))
        XCTAssertEqual(source.calls, calls)
        // Another connection zone is a new baseline.
        _ = try await service.update(id: id, UpdateInput(connectionTimeZone: "Europe/Vienna"))
        XCTAssertEqual(source.calls, calls + 1)
        XCTAssertEqual(source.lastTimeZone?.identifier, "Europe/Vienna")
        record = await service.record(id)!
        XCTAssertEqual(record.connectionTimeZone, "Europe/Vienna")
        calls = source.calls
        _ = try await service.update(id: id, UpdateInput(connectionTimeZone: "Europe/Vienna"))
        XCTAssertEqual(source.calls, calls)
    }

    func testAPIAcceptsAndValidatesTheConnectionTimeZone() async throws {
        let service = try service()
        let router = APIRouter(service: service, config: testConfig(), now: { [clock] in clock!.now })
        func post(_ body: Data) async -> APIResponse {
            await router.handle(APIRequest(method: "POST", path: "/v1/register", headers: ["content-type": "application/json"],
                                           body: body, clientIP: UUID().uuidString))
        }
        let bad = await post(Self.body(connectionTimeZone: "Mars/Olympus"))
        XCTAssertEqual(Self.json(bad)["error"] as? String, "invalid_connectionTimeZone")
        let ok = await post(Self.body(connectionTimeZone: "Europe/Vienna"))
        XCTAssertEqual(ok.status, 201)
        let id = try XCTUnwrap(Self.json(ok)["deviceID"] as? String)
        let zone = await service.record(id)?.connectionTimeZone
        XCTAssertEqual(zone, "Europe/Vienna")
        XCTAssertEqual(source.lastTimeZone?.identifier, "Europe/Vienna")
    }

    // MARK: 7 Delivery state across device changes

    func testDeliveryIsRecordedAlthoughTheDeviceChangedDuringTheSend() async throws {
        let service = try service()
        let id = try await service.register(registration()).deviceID
        sender.duringSend = { _ = try? await service.update(id: id, UpdateInput(settings: DeviceSettings())) }
        clock.set(at(2026, 11, 9, 11, 7))
        source.lessons = [cancelled(deutsch()), mathe(), englisch()]
        await service.poll(id)
        sender.duringSend = nil
        let deliveries = try await service.changes(id: id, since: nil).changes.map(\.delivery)
        XCTAssertEqual(deliveries, [.sent])
        await service.tick()
        XCTAssertEqual(sender.sent.count, 1, "nicht doppelt")
    }

    func testInvalidVerdictForAnOldTokenDoesNotPauseTheNewOne() async throws {
        let service = try service()
        let id = try await service.register(registration()).deviceID
        let newToken = String(repeating: "cd", count: 32)
        sender.result = .invalidToken("BadDeviceToken")
        sender.duringSend = { [sender] in
            sender?.duringSend = nil
            _ = try? await service.update(id: id, UpdateInput(deviceToken: newToken))
        }
        clock.set(at(2026, 11, 9, 11, 7))
        source.lessons = [cancelled(deutsch()), mathe(), englisch()]
        await service.poll(id)
        var record = await service.record(id)!
        XCTAssertEqual(record.state, .active)
        XCTAssertEqual(record.history.map(\.delivery), [.pending], "mit dem neuen Token erneut")
        sender.result = .delivered
        clock.set(at(2026, 11, 9, 11, 8))
        await service.tick()
        XCTAssertEqual(sender.sent.last?.1.deviceToken, newToken)
        record = await service.record(id)!
        XCTAssertEqual(record.history.map(\.delivery), [.sent])
    }

    // MARK: 8 APNs refuses the service (configuration)

    func testProviderErrorsAreRetriedWithBackoffNotMarkedFailedOrSent() async throws {
        XCTAssertEqual(APNs.classify(status: 403, body: Data(#"{"reason":"InvalidProviderToken"}"#.utf8)), .providerError("403 InvalidProviderToken"))
        XCTAssertEqual(APNs.classify(status: 403, body: Data(#"{"reason":"ExpiredProviderToken"}"#.utf8)), .providerError("403 ExpiredProviderToken"))
        XCTAssertEqual(APNs.classify(status: 400, body: Data(#"{"reason":"TopicDisallowed"}"#.utf8)),
                       .deviceConfigurationError("400 TopicDisallowed"), "Topic: nur dieses Gerät (Gegen-Review)")
        XCTAssertEqual(APNs.classify(status: 400, body: Data(#"{"reason":"PayloadTooLarge"}"#.utf8)), .rejected("400 PayloadTooLarge"))

        let service = try service()
        let id = try await service.register(registration()).deviceID
        sender.result = .providerError("403 InvalidProviderToken")
        clock.set(at(2026, 11, 9, 11, 7))
        source.lessons = [cancelled(deutsch()), mathe(), englisch()]
        await service.poll(id)
        XCTAssertEqual(sender.sent.count, 1)
        var record = await service.record(id)!
        XCTAssertEqual(record.history.map(\.delivery), [.pending], "nicht endgültig fehlgeschlagen")
        XCTAssertEqual(record.state, .active)
        clock.set(at(2026, 11, 9, 11, 12))
        await service.tick()
        XCTAssertEqual(sender.sent.count, 1, "Pause nach Konfigurationsfehler")
        clock.set(at(2026, 11, 9, 11, 18))
        await service.tick()
        XCTAssertEqual(sender.sent.count, 2, "erneut nach 10 min")
        clock.set(at(2026, 11, 9, 11, 30))
        await service.tick()
        XCTAssertEqual(sender.sent.count, 2, "Pause verdoppelt (20 min)")
        sender.result = .delivered
        clock.set(at(2026, 11, 9, 11, 39))
        await service.tick()
        XCTAssertEqual(sender.sent.count, 3)
        record = await service.record(id)!
        XCTAssertEqual(record.history.map(\.delivery), [.sent])
    }

    func testAuthNoticeIsNotMarkedSentOnProviderError() async throws {
        let service = try service()
        let id = try await service.register(registration()).deviceID
        source.error = WebUntisError.server(code: -8504, message: "bad credentials")
        sender.result = .providerError("403 InvalidProviderToken")
        clock.set(at(2026, 11, 9, 11, 7)); await service.poll(id)
        clock.set(at(2026, 11, 9, 12, 7)); await service.poll(id)  // authFailed: notice tried at once
        XCTAssertEqual(sender.sent.map(\.0.title), [PushService.authTitle])
        await service.tick()
        var notice = await service.record(id)!.authNotice
        XCTAssertEqual(notice, .pending, "nicht als gesendet verbucht")
        XCTAssertEqual(sender.sent.count, 1, "Pause")
        sender.result = .delivered
        clock.set(at(2026, 11, 9, 12, 20)); await service.tick()
        notice = await service.record(id)!.authNotice
        XCTAssertEqual(notice, .sent)
        XCTAssertEqual(sender.sent.last?.0.title, PushService.authTitle)
        XCTAssertEqual(sender.sent.last?.0.data[CalendarPushPayload.Key.kind.rawValue], .string(CalendarPushPayload.Kind.auth.rawValue))
    }

    func testClientReportsAProviderTokenRefusedAfterRenewalAsProviderError() async throws {
        let provider = try APNsTokenProvider(keyID: "ABCDE12345", teamID: "BAFXLQ964V", pem: P256.Signing.PrivateKey().pemRepresentation)
        let refused = HTTPResponse(status: 403, body: Data(#"{"reason":"InvalidProviderToken"}"#.utf8))
        let transport = APNsCurlTests.FakeTransport([refused, refused])
        let client = APNsClient(transport: transport, tokens: provider)
        let result = await client.send(PushMessage(title: "a", body: "b", threadID: "t"),
                                       to: PushTarget(deviceToken: fakeToken, environment: .sandbox, topic: bundleID))
        XCTAssertEqual(result, .providerError("403 InvalidProviderToken"))
        XCTAssertEqual(transport.requests.count, 2, "einmal erneuert")
    }

    // MARK: 9 „Zweimal hintereinander“

    func testAuthRejectionsMustFollowEachOther() async throws {
        let service = try service()
        let id = try await service.register(registration()).deviceID
        let rejected = WebUntisError.server(code: -8504, message: "bad credentials")
        for (hour, error) in zip([11, 12, 13], [rejected, TransportError.timeout, rejected] as [Error]) {
            clock.set(at(2026, 11, 9, hour, 7))
            source.error = error
            await service.poll(id)
        }
        let record = await service.record(id)!
        XCTAssertEqual(record.state, .active, "dazwischen ein anderer Fehler: nicht zweimal hintereinander")
        XCTAssertEqual(record.authFailures, 1)
    }

    // MARK: 11 One definition for texts and payload keys

    func testPayloadKeysAndTextsComeFromCore() throws {
        let record = DeviceRecord(id: UUID().uuidString.lowercased(), secretHash: "", created: clock.now, updated: clock.now,
                                  deviceToken: fakeToken, environment: .sandbox, bundleID: bundleID, connectionID: connectionID,
                                  timeZone: "Europe/Berlin", settings: DeviceSettings(), setup: setup(), nextPoll: clock.now)
        let entry = ChangeEntry(id: "change.1.2026-11-10.cancelled.1.R101", kinds: ["cancelled"], title: CalendarLessonChange.notificationTitle,
                                body: "Di 10.11., 08:00 Deutsch fällt aus", detected: clock.now, day: CivilDate("2026-11-10")!,
                                entryID: deutsch().id, periodID: "1", lessonStart: at(2026, 11, 10, 8), delivery: .pending)
        let keys = Set(CalendarPushPayload.Key.allCases.map(\.rawValue))
        let single = PushService.message(entry, record: record)
        XCTAssertTrue(Set(single.data.keys).isSubset(of: keys))
        XCTAssertEqual(Set(single.data.keys), keys, "Einzeländerung trägt alle Schlüssel")
        var other = entry; other.id += "~2"; other.body = "Mi 11.11., 08:00 Englisch fällt aus"
        let summary = PushService.summaryMessage([entry, other], record: record, now: clock.now)
        XCTAssertEqual(summary.title, CalendarLessonChange.summary(bodies: [entry.body, other.body]).title)
        XCTAssertEqual(summary.data["kind"], .string("summary"))
        XCTAssertTrue(Set(summary.data.keys).isSubset(of: keys))
        XCTAssertEqual(PushService.testMessage(now: clock.now).data, ["kind": .string("test")])
        let json = try JSONSerialization.jsonObject(with: APNs.payload(single)) as! [String: Any]
        XCTAssertNotNil(json[CalendarPushPayload.rootKey] as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["aps", "noty"])
    }

    // MARK: 6 Long requests over the socket

    func testSlowRegistrationIsAnsweredDespiteTheIdleTimeout() async throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/curl") else { throw XCTSkip("kein curl") }
        source.duringLoad = { try? await Task.sleep(nanoseconds: 2_500_000_000) }
        let service = try service()
        let router = APIRouter(service: service, config: testConfig(), now: { [clock] in clock!.now })
        let port = Int.random(in: 40_001...60_000)
        let server = HTTPServer(router: router, host: "127.0.0.1", port: port, idleTimeout: .seconds(1))
        try server.start()
        defer { server.stop() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        process.arguments = ["-q", "-s", "-o", "/dev/null", "-w", "%{http_code}", "-X", "POST", "-H", "Content-Type: application/json",
                             "--data-binary", String(decoding: Self.body(), as: UTF8.self), "http://127.0.0.1:\(port)/v1/register"]
        let output = Pipe(); process.standardOutput = output
        try process.run(); process.waitUntilExit()
        let status = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertEqual(status, "201", "Antwort trotz 2,5 s Verarbeitung bei 1 s Leerlaufgrenze")
    }

    // MARK: Helpers

    static func body(token: String = fakeToken, server: String = "https://demo.webuntis.example/WebUntis",
                     connectionTimeZone: String? = nil) -> Data {
        let zone = connectionTimeZone.map { #","connectionTimeZone":"\#($0)""# } ?? ""
        return Data("""
        {"deviceToken":"\(token)","apnsEnvironment":"sandbox","bundleID":"\(bundleID)","connectionID":"\(connectionID.uuidString)",
         "timeZone":"Europe/Berlin"\(zone),"consent":"webuntis-push-1",
         "setup":{"server":"\(server)","school":"demo-schule","user":"max.muster","key":"\(rfcKey)"}}
        """.utf8)
    }

    static func json(_ response: APIResponse) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any] ?? [:]
    }
}
