import Foundation
import XCTest
import NotebookCore
@testable import NotyPushKit

final class APITests: XCTestCase {
    var clock: Clock!
    var source: StubSource!
    var sender: MockSender!
    var router: APIRouter!
    var service: PushService!

    override func setUp() {
        clock = Clock(at(2026, 11, 9, 10, 3))
        source = StubSource()
        source.lessons = [lesson(1, at(2026, 11, 10, 8))]
        sender = MockSender()
        service = try! makeService(source: source, sender: sender, clock: clock)
        router = APIRouter(service: service, config: testConfig(), now: { [clock] in clock!.now })
    }

    func body(token: String = fakeToken, bundle: String = bundleID, consent: String = "webuntis-push-1", key: String = rfcKey,
              environment: String = "sandbox") -> Data {
        Data("""
        {"deviceToken":"\(token)","apnsEnvironment":"\(environment)","bundleID":"\(bundle)","connectionID":"\(connectionID.uuidString)",
         "timeZone":"Europe/Berlin","consent":"\(consent)",
         "setup":{"server":"https://demo.webuntis.example/WebUntis","school":"demo-schule","user":"max.muster","key":"\(key)"},
         "settings":{"changes":true,"quietHours":true,"quietStart":1260,"quietEnd":360}}
        """.utf8)
    }

    func post(_ data: Data, ip: String = "198.51.100.7") async -> APIResponse {
        await router.handle(APIRequest(method: "POST", path: "/v1/register", headers: ["content-type": "application/json"], body: data, clientIP: ip))
    }

    func json(_ response: APIResponse) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any] ?? [:]
    }

    func register() async throws -> (id: String, secret: String) {
        let response = await post(body())
        XCTAssertEqual(response.status, 201, String(decoding: response.body, as: UTF8.self))
        let object = json(response)
        return (try XCTUnwrap(object["deviceID"] as? String), try XCTUnwrap(object["deviceSecret"] as? String))
    }

    func authorized(_ method: String, _ path: String, _ device: (id: String, secret: String), query: [String: String] = [:],
                    body: Data = Data()) async -> APIResponse {
        await router.handle(APIRequest(method: method, path: path, query: query,
                                       headers: ["authorization": "Bearer \(device.id).\(device.secret)", "content-type": "application/json"],
                                       body: body))
    }

    func testRegisterReturnsSecretAndNeverEchoesTheFreigabe() async throws {
        let response = await post(body())
        XCTAssertEqual(response.status, 201)
        let text = String(decoding: response.body, as: UTF8.self)
        XCTAssertFalse(text.contains(rfcKey) || text.contains("max.muster") || text.contains(fakeToken))
        let status = json(response)["status"] as? [String: Any]
        XCTAssertEqual(status?["state"] as? String, "active")
        XCTAssertEqual(status?["environment"] as? String, "sandbox")
        let record = await service.record(json(response)["deviceID"] as! String)!
        XCTAssertEqual(record.setup.server, "demo.webuntis.example")
        XCTAssertEqual(record.settings.quietStart, 21 * 60)
    }

    func testRegistrationValidation() async {
        let cases: [(Data, String)] = [
            (body(token: "nothex"), "invalid_deviceToken"),
            (body(bundle: "de.other.app"), "invalid_bundleID"),
            (body(consent: ""), "consent_required"),
            (body(key: "0189"), "invalid_setup"),
            (body(environment: "staging"), "invalid_apnsEnvironment"),
            (Data("{".utf8), "invalid_json"),
        ]
        for (data, code) in cases {
            let response = await post(data, ip: UUID().uuidString)
            XCTAssertEqual(response.status, 400)
            XCTAssertEqual(json(response)["error"] as? String, code)
            XCTAssertFalse(String(decoding: response.body, as: UTF8.self).contains(rfcKey))
        }
        let noType = await router.handle(APIRequest(method: "POST", path: "/v1/register", body: body()))
        XCTAssertEqual(json(noType)["error"] as? String, "invalid_json")
        let count = await service.deviceCount
        XCTAssertEqual(count, 0)
    }

    func testUntisRejectionIsReportedInGerman() async {
        source.error = WebUntisError.server(code: -8504, message: "bad credentials")
        let response = await post(body())
        XCTAssertEqual(response.status, 422)
        XCTAssertEqual(json(response)["error"] as? String, "untis_rejected")
        XCTAssertTrue((json(response)["message"] as? String ?? "").contains("Benutzer oder Schlüssel"))
        source.error = TransportError.timeout
        let unreachable = await post(body(), ip: "198.51.100.8")
        XCTAssertEqual(unreachable.status, 502)
    }

    func testAuthenticatedEndpoints() async throws {
        let device = try await register()
        let wrong = (device.id, String(repeating: "x", count: 43))
        let rejected = await authorized("GET", "/v1/changes", wrong)
        XCTAssertEqual(rejected.status, 401)
        let missing = await router.handle(APIRequest(method: "GET", path: "/v1/changes"))
        XCTAssertEqual(missing.status, 401)

        clock.set(at(2026, 11, 9, 11, 7))
        var gone = lesson(1, at(2026, 11, 10, 8)); gone.statuses = [.cancelled]
        source.lessons = [gone]
        await service.poll(device.id)
        let changes = await authorized("GET", "/v1/changes", device, query: ["since": "0"])
        XCTAssertEqual(changes.status, 200)
        let list = json(changes)["changes"] as? [[String: Any]]
        XCTAssertEqual(list?.count, 1)
        XCTAssertEqual(list?.first?["body"] as? String, "Di 10.11., 08:00 Deutsch fällt aus")
        XCTAssertEqual(list?.first?["delivery"] as? String, "sent")
        XCTAssertEqual(list?.first?["day"] as? String, "2026-11-10")
        let later = await authorized("GET", "/v1/changes", device, query: ["since": String(Int(clock.now.timeIntervalSince1970))])
        XCTAssertEqual((json(later)["changes"] as? [Any])?.count, 0)
        let bad = await authorized("GET", "/v1/changes", device, query: ["since": "gestern"])
        XCTAssertEqual(bad.status, 400)

        let update = await authorized("PUT", "/v1/device", device, body: Data(#"{"apnsEnvironment":"production","deviceToken":"\#(String(repeating: "12", count: 32))"}"#.utf8))
        XCTAssertEqual(update.status, 200)
        XCTAssertEqual((json(update)["status"] as? [String: Any])?["environment"] as? String, "production")
        let setupWithoutConsent = await authorized("PUT", "/v1/device", device, body: Data(#"{"setup":{"server":"demo.webuntis.example","school":"s","user":"u","key":"\#(rfcKey)"}}"#.utf8))
        XCTAssertEqual(json(setupWithoutConsent)["error"] as? String, "consent_required")

        let status = await authorized("GET", "/v1/device", device)
        XCTAssertEqual(status.status, 200)
        let deleted = await authorized("DELETE", "/v1/device", device)
        XCTAssertEqual(deleted.status, 204)
        let afterDelete = await authorized("GET", "/v1/changes", device)
        XCTAssertEqual(afterDelete.status, 401)
        let count = await service.deviceCount
        XCTAssertEqual(count, 0)
    }

    func testLimitsAndUnknownPaths() async throws {
        let big = await router.handle(APIRequest(method: "POST", path: "/v1/register", body: Data(count: APIRouter.maximumBodyBytes + 1)))
        XCTAssertEqual(big.status, 413)
        let unknown = await router.handle(APIRequest(method: "GET", path: "/v1/register"))
        XCTAssertEqual(unknown.status, 404)
        let health = await router.handle(APIRequest(method: "GET", path: "/v1/health"))
        XCTAssertEqual(health.status, 200)
        // 5 registrations per hour and address.
        var statuses: [Int] = []
        for _ in 0..<6 { statuses.append(await post(Data("{".utf8), ip: "203.0.113.9").status) }
        XCTAssertEqual(statuses, [400, 400, 400, 400, 400, 429])
        clock.set(clock.now.addingTimeInterval(3601))
        let again = await post(Data("{".utf8), ip: "203.0.113.9")
        XCTAssertEqual(again.status, 400)
    }

    func testDeviceLimitResponse() async throws {
        var config = testConfig(); config.maxDevices = 1
        router = APIRouter(service: service, config: config, now: { [clock] in clock!.now })
        let service2 = try makeService(config: config, source: source, sender: sender, clock: clock)
        router = APIRouter(service: service2, config: config, now: { [clock] in clock!.now })
        _ = try await register()
        let second = await post(body(token: String(repeating: "ef", count: 32)), ip: "198.51.100.99")
        XCTAssertEqual(second.status, 403)
        XCTAssertEqual(json(second)["error"] as? String, "limit_reached")
    }

    func testSplitURI() {
        let parts = APIRequest.split("/v1/changes?since=12&since=13&x")
        XCTAssertEqual(parts.path, "/v1/changes")
        XCTAssertEqual(parts.query["since"], "12")
    }
}

/// End to end over a real loopback socket (NIO) with the system curl as client.
final class HTTPServerTests: XCTestCase {
    func testServesHealthAndRejectsOversizedBodies() async throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/curl") else { throw XCTSkip("kein curl") }
        let clock = Clock(at(2026, 11, 9, 10))
        let service = try makeService(source: StubSource(), sender: MockSender(), clock: clock)
        let router = APIRouter(service: service, config: testConfig())
        let port = Int.random(in: 20_000...40_000)
        let server = HTTPServer(router: router, host: "127.0.0.1", port: port)
        try server.start()
        defer { server.stop() }
        func curl(_ args: [String]) throws -> String {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
            process.arguments = ["-q", "-s", "-w", "\n%{http_code}"] + args
            let output = Pipe(); process.standardOutput = output
            try process.run(); process.waitUntilExit()
            return String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        }
        XCTAssertEqual(try curl(["http://127.0.0.1:\(port)/v1/health"]), "{\"ok\":true}\n200")
        XCTAssertTrue(try curl(["http://127.0.0.1:\(port)/v1/nope"]).hasSuffix("404"))
        let big = String(repeating: "a", count: 20_000)
        XCTAssertTrue(try curl(["-X", "POST", "-H", "Content-Type: application/json", "--data-binary", big, "http://127.0.0.1:\(port)/v1/register"]).hasSuffix("413"))
        XCTAssertTrue(try curl(["-X", "POST", "-H", "Content-Type: application/json", "--data-binary", "{}", "http://127.0.0.1:\(port)/v1/register"]).hasSuffix("400"))
        XCTAssertThrowsError(try HTTPServer(router: router, host: "0.0.0.0", port: port + 1).start())
    }
}

/// WebUntis access through the transport with Core's request bodies and parser.
final class WebUntisSourceTests: XCTestCase {
    final class Recorder: HTTPTransport, @unchecked Sendable {
        var requests: [HTTPRequest] = []
        let answers: [String: String]
        init(_ answers: [String: String]) { self.answers = answers }
        func send(_ request: HTTPRequest) async throws -> HTTPResponse {
            requests.append(request)
            let method = URLComponents(string: request.url)?.queryItems?.first { $0.name == "m" }?.value ?? ""
            return HTTPResponse(status: answers[method] == nil ? 404 : 200, body: Data((answers[method] ?? "").utf8))
        }
    }

    static let user = """
    {"jsonrpc":"2.0","id":"r0","result":{"userData":{"elemType":"STUDENT","elemId":4711,"displayName":"Muster Max"},
     "masterData":{"subjects":[{"id":2,"name":"D","longName":"Deutsch"}],"rooms":[{"id":10,"name":"R101"}],"klassen":[],"teachers":[],"holidays":[]}}}
    """
    static let timetable = """
    {"jsonrpc":"2.0","id":"r1","result":{"timetable":{"periods":[
     {"id":77,"lessonId":9002,"startDateTime":"2026-11-10T08:00Z","endDateTime":"2026-11-10T08:45Z",
      "elements":[{"type":"SUBJECT","id":2,"orgId":2},{"type":"ROOM","id":10,"orgId":10}],"is":["CANCELLED"]}]}}}
    """

    func testLoadsThroughCoreParserWithTOTPAuth() async throws {
        let transport = Recorder(["getUserData2017": Self.user, "getTimetable2017": Self.timetable])
        let fetch = try await WebUntisCurlSource(transport: transport).load(
            setup: setup(), connection: connectionID, timeZone: berlin, start: CivilDate("2026-11-09")!, end: CivilDate("2026-11-23")!,
            at: at(2026, 11, 9, 10))
        XCTAssertEqual(fetch.lessons.count, 1)
        XCTAssertEqual(fetch.lessons[0].title, "Deutsch")
        XCTAssertTrue(fetch.lessons[0].isCancelled)
        XCTAssertEqual(fetch.lessons[0].start, at(2026, 11, 10, 8))
        XCTAssertEqual(transport.requests.count, 2)
        XCTAssertTrue(transport.requests[0].url.hasPrefix("https://demo.webuntis.example/WebUntis/jsonrpc_intern.do?m=getUserData2017"))
        let body = try JSONSerialization.jsonObject(with: transport.requests[1].body!) as! [String: Any]
        let params = (body["params"] as! [[String: Any]])[0]
        XCTAssertEqual(params["startDate"] as? String, "2026-11-09")
        XCTAssertEqual(params["endDate"] as? String, "2026-11-22")
        let auth = params["auth"] as! [String: Any]
        XCTAssertEqual(auth["user"] as? String, "max.muster")
        XCTAssertNotNil(auth["otp"] as? Int)

        let failing = Recorder(["getUserData2017": Self.user])
        do {
            _ = try await WebUntisCurlSource(transport: failing).load(setup: setup(), connection: connectionID, timeZone: berlin,
                                                                       start: CivilDate("2026-11-09")!, end: CivilDate("2026-11-23")!, at: Date())
            XCTFail()
        } catch { XCTAssertEqual(PollFailure.classify(error), .transient("WebUntis nicht erreichbar")) }
        XCTAssertEqual(PollFailure.classify(WebUntisError.server(code: -8504, message: "x")), .authentication)
        XCTAssertEqual(PollFailure.classify(WebUntisError.server(code: -8500, message: "school")), .authentication)
    }
}
