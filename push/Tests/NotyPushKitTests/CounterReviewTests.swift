import Foundation
import XCTest
import NotebookCore
@testable import NotyPushKit

/// Findings of the counter-review of 08.11.2026 (docs/PUSH.md): rate limits
/// per category and per IPv6 /64, idempotent registrations (registration
/// id), APNs errors of one device. Fictitious data only.
final class CounterReviewTests: XCTestCase {
    var clock: Clock!
    var source: StubSource!
    var sender: MockSender!
    var dir: String!

    override func setUp() {
        clock = Clock(at(2026, 11, 9, 10, 3))
        source = StubSource()
        source.lessons = [lesson(1, at(2026, 11, 10, 8)), lesson(2, at(2026, 11, 10, 9, 45), subject: "Mathematik", subjectID: "1")]
        sender = MockSender()
        dir = temporaryDirectory()
    }

    func service(_ config: PushConfig = testConfig()) throws -> PushService {
        try makeService(dir: dir, config: config, source: source, sender: sender, clock: clock)
    }

    func router(_ service: PushService, _ config: PushConfig = testConfig()) -> APIRouter {
        APIRouter(service: service, config: config, now: { [clock] in clock!.now })
    }

    static func body(token: String = fakeToken, registrationID: String? = nil) -> Data {
        let registration = registrationID.map { #","registrationID":"\#($0)""# } ?? ""
        return Data("""
        {"deviceToken":"\(token)","apnsEnvironment":"sandbox","bundleID":"\(bundleID)","connectionID":"\(connectionID.uuidString)",
         "timeZone":"Europe/Berlin","consent":"webuntis-push-1"\(registration),
         "setup":{"server":"https://demo.webuntis.example/WebUntis","school":"demo-schule","user":"max.muster","key":"\(rfcKey)"}}
        """.utf8)
    }

    static func json(_ response: APIResponse) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any] ?? [:]
    }

    func post(_ router: APIRouter, _ body: Data, ip: String = "198.51.100.7") async -> APIResponse {
        await router.handle(APIRequest(method: "POST", path: "/v1/register", headers: ["content-type": "application/json"], body: body, clientIP: ip))
    }

    // MARK: Rate limits

    func testCleaningTheMinuteCountersKeepsHourlyLimits() async throws {
        var config = testConfig(); config.registrationsPerHourPerIP = 2; config.requestsPerMinutePerIP = 100_000
        let router = router(try service(config), config)
        for _ in 0..<2 { _ = await post(router, Data("{".utf8), ip: "203.0.113.1") }
        let limited = await post(router, Data("{".utf8), ip: "203.0.113.1")
        XCTAssertEqual(limited.status, 429)
        // Many addresses a few minutes later: the per-minute counters are cleaned (before: all
        // counters with the minute window, the hourly registration limit went with them).
        clock.set(clock.now.addingTimeInterval(180))
        for index in 0..<10_050 {
            _ = await router.handle(APIRequest(method: "GET", path: "/v1/health", clientIP: "10.\(index / 65_536).\(index / 256 % 256).\(index % 256)"))
        }
        XCTAssertLessThanOrEqual(router.requests.keyCount, 10_000)
        let still = await post(router, Data("{".utf8), ip: "203.0.113.1")
        XCTAssertEqual(still.status, 429, "Stundenlimit bleibt")
    }

    func testTooManyKeysEvictTheLeastRecentlyActiveNotAll() {
        let limiter = RateLimiter(window: 3600, maximumKeys: 20)
        let start = at(2026, 11, 9, 10)
        for index in 0..<25 {
            XCTAssertTrue(limiter.allow("k\(index)", limit: 1, now: start.addingTimeInterval(Double(index))))
        }
        XCTAssertLessThanOrEqual(limiter.keyCount, 20)
        let now = start.addingTimeInterval(30)
        XCTAssertFalse(limiter.allow("k24", limit: 1, now: now), "die jüngsten Schlüssel bleiben begrenzt")
        XCTAssertFalse(limiter.allow("k20", limit: 1, now: now))
        XCTAssertTrue(limiter.allow("k0", limit: 1, now: now), "der älteste wurde verworfen")
        // wait/record keep at most `limit` events and report the right wait.
        let failures = RateLimiter(window: 60)
        for second in 0..<5 { failures.record("x", limit: 3, now: start.addingTimeInterval(Double(second))) }
        XCTAssertEqual(failures.wait("x", limit: 3, now: start.addingTimeInterval(5)), 57, "bis das älteste der letzten drei geht")
        XCTAssertNil(failures.wait("x", limit: 3, now: start.addingTimeInterval(63)))
    }

    func testIPv6IsLimitedPerSlash64AndMappedIPv4AsIPv4() async throws {
        XCTAssertEqual(ClientAddress.key("2001:db8:1:2:aaaa::1"), "2001:db8:1:2::/64")
        XCTAssertEqual(ClientAddress.key("2001:DB8:1:2:bbbb:cccc:dddd:eeee"), "2001:db8:1:2::/64")
        XCTAssertNotEqual(ClientAddress.key("2001:db8:1:3::1"), ClientAddress.key("2001:db8:1:2::1"))
        XCTAssertEqual(ClientAddress.key("[2001:db8::1]"), "2001:db8:0:0::/64")
        XCTAssertEqual(ClientAddress.key("fe80::1%eth0"), "fe80:0:0:0::/64")
        XCTAssertEqual(ClientAddress.key("::ffff:198.51.100.7"), "198.51.100.7")
        XCTAssertEqual(ClientAddress.key("::ffff:c633:6407"), "198.51.100.7")
        XCTAssertEqual(ClientAddress.key("198.51.100.7"), "198.51.100.7")
        XCTAssertEqual(ClientAddress.key("::"), "0:0:0:0::/64")
        for invalid in ["2001:::1", "1:2:3:4:5:6:7:8:9", "::ffff:1.2.3", "12345::1", "g::1"] {
            XCTAssertEqual(ClientAddress.key(invalid), invalid, invalid)
        }
        // Five attempts per hour for the whole /64, whichever single addresses it uses.
        let router = router(try service())
        var statuses: [Int] = []
        for index in 1...6 { statuses.append(await post(router, Data("{".utf8), ip: "2001:db8:1:2::\(index)").status) }
        XCTAssertEqual(statuses, [400, 400, 400, 400, 400, 429])
        let neighbour = await post(router, Data("{".utf8), ip: "2001:db8:1:3::1")
        XCTAssertEqual(neighbour.status, 400, "anderes /64")
        // An IPv4-mapped address counts as its IPv4 address.
        var mapped: [Int] = []
        for index in 0..<6 {
            mapped.append(await post(router, Data("{".utf8), ip: index.isMultiple(of: 2) ? "198.51.100.9" : "::ffff:198.51.100.9").status)
        }
        XCTAssertEqual(mapped.last, 429)
    }

    func testRegistrationAttemptsPerHourForTheWholeService() async throws {
        var config = testConfig(); config.registrationAttemptsPerHour = 3; config.registrationsPerHourPerIP = 100
        XCTAssertEqual(PushConfig().registrationAttemptsPerHour, 60)
        let router = router(try service(config), config)
        var statuses: [Int] = []
        for index in 0..<4 { statuses.append(await post(router, Data("{".utf8), ip: "198.51.100.\(index)").status) }
        XCTAssertEqual(statuses, [400, 400, 400, 429], "auch ungültige Versuche zählen, über alle Adressen")
        let limited = await post(router, Data("{".utf8), ip: "198.51.100.50")
        XCTAssertGreaterThan(limited.retryAfter ?? 0, 0)
        clock.set(clock.now.addingTimeInterval(3601))
        let later = await post(router, Data("{".utf8), ip: "198.51.100.51")
        XCTAssertEqual(later.status, 400)
        var broken = testConfig(); broken.registrationAttemptsPerHour = 0
        XCTAssertFalse(broken.problems.isEmpty)
    }

    // MARK: Registration id

    func testTheSameRegistrationIDAnswersTheSameDeviceWithANewSecret() async throws {
        let service = try service()
        let router = router(service)
        let registrationID = UUID().uuidString
        let first = await post(router, Self.body(registrationID: registrationID))
        XCTAssertEqual(first.status, 201)
        let id = try XCTUnwrap(Self.json(first)["deviceID"] as? String)
        let oldSecret = try XCTUnwrap(Self.json(first)["deviceSecret"] as? String)
        // The app gave up waiting and sends the same registration again (here with a new token).
        clock.set(clock.now.addingTimeInterval(150))
        let newToken = String(repeating: "cd", count: 32)
        let second = await post(router, Self.body(token: newToken, registrationID: registrationID.lowercased()), ip: "198.51.100.8")
        XCTAssertEqual(second.status, 201)
        XCTAssertEqual(Self.json(second)["deviceID"] as? String, id, "dasselbe Gerät")
        let newSecret = try XCTUnwrap(Self.json(second)["deviceSecret"] as? String)
        XCTAssertNotEqual(newSecret, oldSecret)
        let count = await service.deviceCount
        XCTAssertEqual(count, 1, "kein zweites Gerät")
        let stored = await service.record(id)
        let record = try XCTUnwrap(stored)
        XCTAssertEqual(record.deviceToken, newToken)
        XCTAssertNotNil(record.registrationHash)
        XCTAssertFalse(record.registrationHash?.contains(registrationID.lowercased()) ?? true, "nur der Hash")
        func get(_ secret: String) async -> Int {
            await router.handle(APIRequest(method: "GET", path: "/v1/device", headers: ["authorization": "Bearer \(id).\(secret)"])).status
        }
        let old = await get(oldSecret), new = await get(newSecret)
        XCTAssertEqual([old, new], [401, 200], "altes Secret ungültig")
        // Another registration id is another device; an invalid one is refused.
        let other = await post(router, Self.body(token: String(repeating: "ef", count: 32), registrationID: UUID().uuidString), ip: "198.51.100.9")
        XCTAssertEqual(other.status, 201)
        XCTAssertNotEqual(Self.json(other)["deviceID"] as? String, id)
        let invalid = await post(router, Self.body(registrationID: "abc"), ip: "198.51.100.10")
        XCTAssertEqual(invalid.status, 400)
        XCTAssertEqual(Self.json(invalid)["error"] as? String, "invalid_registrationID")
        // Apps without the field keep working.
        let plain = await post(router, Self.body(token: String(repeating: "aa", count: 32)), ip: "198.51.100.11")
        XCTAssertEqual(plain.status, 201)
    }

    func testDeletingAnUnansweredRegistrationByItsID() async throws {
        let service = try service()
        let router = router(service)
        let registrationID = UUID().uuidString
        func delete(_ raw: String) async -> APIResponse {
            await router.handle(APIRequest(method: "DELETE", path: "/v1/device", headers: ["authorization": "Registration \(raw)"]))
        }
        let unknown = await delete(UUID().uuidString)
        XCTAssertEqual(unknown.status, 204, "nichts da: nichts zu tun")
        let created = await post(router, Self.body(registrationID: registrationID))
        XCTAssertEqual(created.status, 201)
        let wrong = await delete(UUID().uuidString)
        XCTAssertEqual(wrong.status, 204)
        var count = await service.deviceCount
        XCTAssertEqual(count, 1, "nur wer die ID kennt")
        let invalid = await delete("not-a-uuid")
        XCTAssertEqual(invalid.status, 400)
        let deleted = await delete(registrationID)
        XCTAssertEqual(deleted.status, 204)
        count = await service.deviceCount
        XCTAssertEqual(count, 0)
        let id = try XCTUnwrap(Self.json(created)["deviceID"] as? String)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir + "/devices/\(id).sealed"))
    }

    func testARunningRegistrationAnswersInProgressAndCanBeWithdrawn() async throws {
        let service = try service()
        let hash = try XCTUnwrap(APIRouter.registrationHash(UUID().uuidString))
        var input = registration(); input.registrationHash = hash
        let request = input
        let retried = UnsafeBox<Error?>(nil)
        // While the first attempt waits for WebUntis: the same registration again, then the app withdraws it.
        source.duringLoad = { [source] in
            source?.duringLoad = nil
            do { _ = try await service.register(request) } catch { retried.value = error }
            try? await service.deleteRegistration(hash: hash)
        }
        do { _ = try await service.register(input); XCTFail("zurückgezogen") }
        catch { XCTAssertEqual(error as? ServiceError, .registrationCancelled) }
        XCTAssertEqual(retried.value as? ServiceError, .registrationInProgress)
        let count = await service.deviceCount
        XCTAssertEqual(count, 0, "nichts gespeichert")
        XCTAssertEqual(router(service).response(for: ServiceError.registrationInProgress).status, 409)
        // Afterwards the same id registers normally.
        let result = try await service.register(input)
        let stored = await service.record(result.deviceID)?.registrationHash
        XCTAssertEqual(stored, hash)
    }

    // MARK: APNs errors of one device

    final class RoutingSender: PushSender, @unchecked Sendable {
        private let lock = NSLock()
        private var _sent: [String] = []
        let results: [String: PushResult]
        init(_ results: [String: PushResult]) { self.results = results }
        var sent: [String] { lock.withLock { _sent } }
        func send(_ message: PushMessage, to target: PushTarget) async -> PushResult {
            lock.withLock { _sent.append(target.deviceToken) }
            return results[target.deviceToken] ?? .delivered
        }
    }

    func testATopicErrorPausesOnlyThatDevice() async throws {
        XCTAssertEqual(APNs.classify(status: 400, body: Data(#"{"reason":"BadTopic"}"#.utf8)), .deviceConfigurationError("400 BadTopic"))
        XCTAssertEqual(APNs.classify(status: 403, body: Data(#"{"reason":"BadEnvironmentKeyInToken"}"#.utf8)),
                       .deviceConfigurationError("403 BadEnvironmentKeyInToken"))
        XCTAssertEqual(APNs.classify(status: 403, body: Data(#"{"reason":"InvalidProviderToken"}"#.utf8)), .providerError("403 InvalidProviderToken"))
        XCTAssertEqual(APNs.classify(status: 403, body: Data()), .providerError("403 "))

        let broken = String(repeating: "b1", count: 32), fine = String(repeating: "f1", count: 32)
        let routing = RoutingSender([broken: .deviceConfigurationError("400 TopicDisallowed")])
        let store = try DeviceStore(dataDirectory: dir, keyring: testKeyring())
        let service = PushService(config: testConfig(), store: store, source: source, sender: routing, now: { [clock] in clock!.now })
        let a = try await service.register(registration(token: broken)).deviceID
        let b = try await service.register(registration(token: fine)).deviceID
        var cancelled = lesson(1, at(2026, 11, 10, 8)); cancelled.statuses = [.cancelled]
        source.lessons = [cancelled, lesson(2, at(2026, 11, 10, 9, 45), subject: "Mathematik", subjectID: "1")]
        clock.set(at(2026, 11, 9, 11, 7))
        await service.poll(a)
        await service.poll(b)
        XCTAssertEqual(routing.sent, [broken, fine], "das zweite Gerät wird trotzdem beliefert")
        let first = await service.record(a)
        var record = try XCTUnwrap(first)
        XCTAssertEqual(record.history.map(\.delivery), [.pending], "nicht verworfen")
        XCTAssertEqual(record.state, .active)
        let second = await service.record(b)
        record = try XCTUnwrap(second)
        XCTAssertEqual(record.history.map(\.delivery), [.sent])
        // Five minutes later: the broken device waits, nothing global.
        clock.set(at(2026, 11, 9, 11, 12))
        await service.tick()
        XCTAssertEqual(routing.sent.count, 2)
        // After its pause (10 min) it is tried again.
        clock.set(at(2026, 11, 9, 11, 18))
        await service.tick()
        XCTAssertEqual(routing.sent, [broken, fine, broken])
    }
}

/// A value a `@Sendable` test closure can set (tests only).
final class UnsafeBox<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}
