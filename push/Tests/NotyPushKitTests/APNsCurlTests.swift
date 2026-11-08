import Foundation
import XCTest
import Crypto
@testable import NotyPushKit

final class APNsCurlTests: XCTestCase {
    func testJWTIsES256SignedWithKidAndIssuer() throws {
        let key = P256.Signing.PrivateKey()
        let provider = try APNsTokenProvider(keyID: "ABCDE12345", teamID: "BAFXLQ964V", pem: key.pemRepresentation)
        let token = try provider.makeToken(at: Date(timeIntervalSince1970: 1_800_000_000))
        let parts = token.split(separator: ".").map(String.init)
        XCTAssertEqual(parts.count, 3)
        func decode(_ text: String) -> Data {
            var base = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            while base.count % 4 != 0 { base += "=" }
            return Data(base64Encoded: base)!
        }
        let header = try JSONSerialization.jsonObject(with: decode(parts[0])) as! [String: Any]
        let claims = try JSONSerialization.jsonObject(with: decode(parts[1])) as! [String: Any]
        XCTAssertEqual(header["alg"] as? String, "ES256")
        XCTAssertEqual(header["kid"] as? String, "ABCDE12345")
        XCTAssertEqual(claims["iss"] as? String, "BAFXLQ964V")
        XCTAssertEqual(claims["iat"] as? Int, 1_800_000_000)
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: decode(parts[2]))
        XCTAssertEqual(decode(parts[2]).count, 64)
        XCTAssertTrue(key.publicKey.isValidSignature(signature, for: Data((parts[0] + "." + parts[1]).utf8)))
        XCTAssertThrowsError(try APNsTokenProvider(keyID: "A", teamID: "B", pem: "kein Schlüssel"))
    }

    func testTokenIsCachedFor45Minutes() throws {
        let provider = try APNsTokenProvider(keyID: "ABCDE12345", teamID: "BAFXLQ964V", pem: P256.Signing.PrivateKey().pemRepresentation)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let first = try provider.token(now: start)
        XCTAssertEqual(try provider.token(now: start.addingTimeInterval(40 * 60)), first)
        XCTAssertNotEqual(try provider.token(now: start.addingTimeInterval(46 * 60)), first)
    }

    func testPayloadAndHeaders() throws {
        let message = PushMessage(title: "Stundenplanänderung", body: "Di 10.11., 08:00 Deutsch fällt aus", threadID: "noty.calendar.changes.X",
                                  collapseID: String(repeating: "c", count: 80), expiration: Date(timeIntervalSince1970: 1_800_000_000),
                                  data: ["kind": .string("change"), "changeIDs": .strings(["a"]), "lessonStart": .int(5)])
        let request = try APNs.request(message, to: PushTarget(deviceToken: fakeToken, environment: .sandbox, topic: bundleID), token: "JWT")
        XCTAssertEqual(request.url, "https://api.sandbox.push.apple.com/3/device/\(fakeToken)")
        XCTAssertTrue(request.http2)
        XCTAssertTrue(request.headers.contains("apns-push-type: alert"))
        XCTAssertTrue(request.headers.contains("apns-topic: \(bundleID)"))
        XCTAssertTrue(request.headers.contains("apns-expiration: 1800000000"))
        XCTAssertTrue(request.headers.contains("authorization: bearer JWT"))
        let collapse = request.headers.first { $0.hasPrefix("apns-collapse-id: ") }!.dropFirst("apns-collapse-id: ".count)
        XCTAssertLessThanOrEqual(collapse.utf8.count, 64)
        XCTAssertEqual(APNs.collapseID("kurz"), "kurz")
        let json = try JSONSerialization.jsonObject(with: request.body!) as! [String: Any]
        let aps = json["aps"] as! [String: Any]
        XCTAssertEqual((aps["alert"] as! [String: Any])["body"] as? String, "Di 10.11., 08:00 Deutsch fällt aus")
        XCTAssertEqual(aps["thread-id"] as? String, "noty.calendar.changes.X")
        XCTAssertEqual((json["noty"] as! [String: Any])["kind"] as? String, "change")
        XCTAssertEqual(APNsEnvironment.production.host, "api.push.apple.com")
        XCTAssertThrowsError(try APNs.request(message, to: PushTarget(deviceToken: "zz", environment: .sandbox, topic: bundleID), token: "JWT"))
    }

    func testOversizedBodyIsShortenedBelow4KB() throws {
        let message = PushMessage(title: "T", body: String(repeating: "ä", count: 5000), threadID: "t")
        let data = try APNs.payload(message)
        XCTAssertLessThanOrEqual(data.count, APNs.maximumPayloadBytes)
        XCTAssertNotNil(try JSONSerialization.jsonObject(with: data))
    }

    func testResponseClassification() {
        XCTAssertEqual(APNs.classify(status: 200, body: Data()), .delivered)
        XCTAssertEqual(APNs.classify(status: 410, body: Data(#"{"reason":"Unregistered"}"#.utf8)), .invalidToken("Unregistered"))
        XCTAssertEqual(APNs.classify(status: 400, body: Data(#"{"reason":"BadDeviceToken"}"#.utf8)), .invalidToken("BadDeviceToken"))
        XCTAssertEqual(APNs.classify(status: 400, body: Data(#"{"reason":"DeviceTokenNotForTopic"}"#.utf8)), .invalidToken("DeviceTokenNotForTopic"))
        XCTAssertEqual(APNs.classify(status: 400, body: Data(#"{"reason":"PayloadTooLarge"}"#.utf8)), .rejected("400 PayloadTooLarge"))
        XCTAssertEqual(APNs.classify(status: 429, body: Data()), .retryLater("429 "))
        XCTAssertEqual(APNs.classify(status: 503, body: Data()), .retryLater("503 "))
    }

    final class FakeTransport: HTTPTransport, @unchecked Sendable {
        var responses: [HTTPResponse]
        var requests: [HTTPRequest] = []
        init(_ responses: [HTTPResponse]) { self.responses = responses }
        func send(_ request: HTTPRequest) async throws -> HTTPResponse {
            requests.append(request)
            return responses.removeFirst()
        }
    }

    func testExpiredProviderTokenIsRenewedOnce() async throws {
        let provider = try APNsTokenProvider(keyID: "ABCDE12345", teamID: "BAFXLQ964V", pem: P256.Signing.PrivateKey().pemRepresentation)
        let transport = FakeTransport([HTTPResponse(status: 403, body: Data(#"{"reason":"ExpiredProviderToken"}"#.utf8)), HTTPResponse(status: 200, body: Data())])
        let clock = Clock(Date(timeIntervalSince1970: 1_800_000_000))
        let client = APNsClient(transport: transport, tokens: provider, now: { clock.now })
        let result = await client.send(PushMessage(title: "a", body: "b", threadID: "t"), to: PushTarget(deviceToken: fakeToken, environment: .sandbox, topic: bundleID))
        XCTAssertEqual(result, .delivered)
        XCTAssertEqual(transport.requests.count, 2)
    }

    // MARK: curl

    func testCurlConfigEscapesAndRefusesUnsafeInput() throws {
        let text = try CurlTransport.configText(HTTPRequest(url: "https://h.example/x?a=1", headers: ["A: b\"c"], body: Data(#"{"k":"a\"b\\c\/"}"#.utf8)))
        XCTAssertTrue(text.contains(#"url = "https://h.example/x?a=1""#))
        XCTAssertTrue(text.contains(#"header = "A: b\"c""#))
        XCTAssertTrue(text.contains(#"data-binary = "{\"k\":\"a\\\"b\\\\c\\/\"}""#))
        XCTAssertTrue(text.contains(#"proto = "=https""#))
        XCTAssertFalse(text.contains("location"))
        XCTAssertThrowsError(try CurlTransport.configText(HTTPRequest(url: "http://h.example")))
        XCTAssertThrowsError(try CurlTransport.configText(HTTPRequest(url: "https://h.example", headers: ["A: b\nurl = x"])))
        XCTAssertThrowsError(try CurlTransport.configText(HTTPRequest(url: "https://h.example", body: Data("@/etc/passwd".utf8))))
        XCTAssertEqual(CurlTransport.parseOutput(Data("{\"a\":1}\n200".utf8)), HTTPResponse(status: 200, body: Data("{\"a\":1}".utf8)))
        XCTAssertEqual(CurlTransport.parseOutput(Data("\n410".utf8)), HTTPResponse(status: 410, body: Data()))
        XCTAssertNil(CurlTransport.parseOutput(Data("kaputt".utf8)))
    }

    /// The real curl parses the generated config: a body sent to a local
    /// file URL is refused (https only), proving `proto` is applied.
    func testRealCurlReadsConfigFromStdin() async throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/curl") else { throw XCTSkip("kein curl") }
        let dir = temporaryDirectory()
        // Fake curl: echoes its stdin config and a status (process plumbing, no network).
        let fake = dir + "/curl"
        try "#!/bin/sh\n[ \"$1\" = -q ] && [ \"$2\" = -K ] && [ \"$3\" = - ] || exit 2\ncat\nprintf '\\n201'\n".write(toFile: fake, atomically: true, encoding: .utf8)
        chmod(fake, 0o755)
        let response = try await CurlTransport(curlPath: fake).send(HTTPRequest(url: "https://h.example/", body: Data("{}".utf8)))
        XCTAssertEqual(response.status, 201)
        XCTAssertTrue(String(decoding: response.body, as: UTF8.self).contains("data-binary = \"{}\""))
        // Real curl: a non-https URL in the config is refused by `proto`.
        var config = try CurlTransport.configText(HTTPRequest(url: "https://h.example/"))
        config = config.replacingOccurrences(of: "https://h.example/", with: "file:///etc/hostname")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        process.arguments = ["-q", "-K", "-"]
        let input = Pipe(); process.standardInput = input
        process.standardOutput = Pipe(); process.standardError = Pipe()
        try process.run()
        input.fileHandleForWriting.write(Data(config.utf8)); try input.fileHandleForWriting.close()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 1, "curl muss nicht-https ablehnen (CURLE_UNSUPPORTED_PROTOCOL)")
    }

    func testCurlExitCodesMapToTransportErrors() async throws {
        let dir = temporaryDirectory()
        for (code, expected) in [(28, TransportError.timeout), (63, .tooLarge), (6, .unreachable(6))] {
            let fake = dir + "/curl\(code)"
            try "#!/bin/sh\ncat >/dev/null\nexit \(code)\n".write(toFile: fake, atomically: true, encoding: .utf8)
            chmod(fake, 0o755)
            do { _ = try await CurlTransport(curlPath: fake).send(HTTPRequest(url: "https://h.example/")); XCTFail() }
            catch { XCTAssertEqual(error as? TransportError, expected) }
        }
    }
}
