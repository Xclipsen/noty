import Foundation
import Crypto
import NotebookCore

/// Provider token (JWT, ES256) for APNs token-based authentication. Apple
/// accepts a token for one hour and asks not to renew it more often than
/// every 20 minutes; it is reused for 45 minutes here.
public final class APNsTokenProvider: @unchecked Sendable {
    let keyID: String
    let teamID: String
    let key: P256.Signing.PrivateKey
    private let lock = NSLock()
    private var cached: (token: String, issued: Date)?
    static let lifetime: TimeInterval = 45 * 60

    public init(keyID: String, teamID: String, pem: String) throws {
        self.keyID = keyID; self.teamID = teamID
        do { key = try P256.Signing.PrivateKey(pemRepresentation: pem) }
        catch { throw PushError.crypto("APNs-Schlüssel (.p8) nicht lesbar") }
    }

    public static func load(keyID: String, teamID: String, path: String) throws -> APNsTokenProvider {
        try APNsTokenProvider(keyID: keyID, teamID: teamID, pem: String(decoding: try Data(contentsOf: URL(fileURLWithPath: path)), as: UTF8.self))
    }

    /// Signed JWT: base64url(header).base64url(claims).base64url(r||s).
    public func makeToken(at date: Date) throws -> String {
        let header = #"{"alg":"ES256","kid":"\#(keyID)"}"#
        let claims = #"{"iss":"\#(teamID)","iat":\#(Int(date.timeIntervalSince1970))}"#
        let input = Secrets.base64URL(Data(header.utf8)) + "." + Secrets.base64URL(Data(claims.utf8))
        let signature = try key.signature(for: Data(input.utf8))
        return input + "." + Secrets.base64URL(signature.rawRepresentation)
    }

    public func token(now: Date) throws -> String {
        lock.lock(); defer { lock.unlock() }
        if let cached, now.timeIntervalSince(cached.issued) < Self.lifetime, now >= cached.issued { return cached.token }
        let token = try makeToken(at: now)
        cached = (token, now)
        return token
    }

    public func invalidate() {
        lock.lock(); cached = nil; lock.unlock()
    }
}

/// One alert push.
public struct PushMessage: Equatable, Sendable {
    public var title: String
    public var body: String
    /// Groups notifications on the device (one thread per connection).
    public var threadID: String
    /// Replaces an earlier notification with the same id (≤ 64 bytes).
    public var collapseID: String?
    /// After this, APNs no longer tries to deliver (nil: once, now).
    public var expiration: Date?
    /// App data under the key `noty` (see docs/PUSH.md).
    public var data: [String: PayloadValue]

    public init(title: String, body: String, threadID: String, collapseID: String? = nil, expiration: Date? = nil,
                data: [String: PayloadValue] = [:]) {
        self.title = title; self.body = body; self.threadID = threadID; self.collapseID = collapseID
        self.expiration = expiration; self.data = data
    }

    /// App data of `kind` with the keys the app reads (`CalendarPushPayload`, Core).
    public static func data(_ kind: CalendarPushPayload.Kind,
                            _ values: [CalendarPushPayload.Key: PayloadValue] = [:]) -> [String: PayloadValue] {
        var data = [CalendarPushPayload.Key.kind.rawValue: PayloadValue.string(kind.rawValue)]
        for (key, value) in values where key != .kind { data[key.rawValue] = value }
        return data
    }
}

public enum PayloadValue: Equatable, Sendable, Encodable {
    case string(String), int(Int), strings([String])
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .int(let v): try c.encode(v)
        case .strings(let v): try c.encode(v)
        }
    }
}

public struct PushTarget: Equatable, Sendable {
    public var deviceToken: String
    public var environment: APNsEnvironment
    public var topic: String
    public init(deviceToken: String, environment: APNsEnvironment, topic: String) {
        self.deviceToken = deviceToken; self.environment = environment; self.topic = topic
    }
}

public enum PushResult: Equatable, Sendable {
    case delivered
    /// 410, BadDeviceToken, Unregistered, DeviceTokenNotForTopic: stop sending to this token.
    case invalidToken(String)
    /// 429, 5xx, network: try again later.
    case retryLater(String)
    /// APNs refused the service itself (403 InvalidProviderToken/
    /// ExpiredProviderToken/…, wrong topic, unreadable key): a configuration
    /// error of the server, not of the change. Retried with a growing pause
    /// after the operator fixed it; nothing is marked as failed or sent.
    case providerError(String)
    /// Anything else (payload too large, malformed request): logged, not retried.
    case rejected(String)
}

public protocol PushSender: Sendable {
    func send(_ message: PushMessage, to target: PushTarget) async -> PushResult
}

public enum APNs {
    public static let maximumPayloadBytes = 4096

    /// `apns-collapse-id` is limited to 64 bytes: longer ids are hashed.
    public static func collapseID(_ id: String) -> String {
        if id.utf8.count <= 64 { return id }
        return "h." + Crypto.SHA256.hash(data: Data(id.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    struct Alert: Encodable { let title: String; let body: String }
    struct APS: Encodable {
        let alert: Alert
        let sound = "default"
        let threadID: String
        enum CodingKeys: String, CodingKey { case alert, sound, threadID = "thread-id" }
    }
    /// `{"aps": …, "noty": {…}}` (key `CalendarPushPayload.rootKey`).
    struct Payload: Encodable {
        let aps: APS
        let data: [String: PayloadValue]
        struct Key: CodingKey {
            let stringValue: String
            init(_ value: String) { stringValue = value }
            init?(stringValue: String) { self.stringValue = stringValue }
            var intValue: Int? { nil }
            init?(intValue: Int) { nil }
        }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: Key.self)
            try c.encode(aps, forKey: Key("aps"))
            try c.encode(data, forKey: Key(CalendarPushPayload.rootKey))
        }
    }

    /// JSON payload ≤ 4096 bytes: the body is shortened until it fits.
    public static func payload(_ message: PushMessage) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var body = message.body
        while true {
            let data = try encoder.encode(Payload(aps: APS(alert: Alert(title: message.title, body: body), threadID: message.threadID),
                                                  data: message.data))
            if data.count <= maximumPayloadBytes { return data }
            guard body.count > 20 else { throw PushError.transport("Payload zu groß") }
            body = String(body.prefix(body.count * 3 / 4)) + "…"
        }
    }

    public static func request(_ message: PushMessage, to target: PushTarget, token: String) throws -> HTTPRequest {
        guard target.deviceToken.count >= 64, target.deviceToken.count <= 400,
              target.deviceToken.allSatisfy({ $0.isHexDigit }) else { throw PushError.transport("Gerätetoken ungültig") }
        var headers = [
            "authorization: bearer \(token)",
            "apns-topic: \(target.topic)",
            "apns-push-type: alert",
            "apns-priority: 10",
            "content-type: application/json",
            "apns-expiration: \(Int(message.expiration?.timeIntervalSince1970 ?? 0))",
        ]
        if let collapse = message.collapseID { headers.append("apns-collapse-id: \(collapseID(collapse))") }
        return HTTPRequest(url: "https://\(target.environment.host)/3/device/\(target.deviceToken)", headers: headers,
                           body: try payload(message), http2: true, maxTime: 30, maxResponseBytes: 64_000)
    }

    struct Reason: Decodable { let reason: String? }

    /// Reasons of a 400 that mean the server's configuration (topic), not the message.
    static let configurationReasons: Set<String> = ["BadTopic", "TopicDisallowed", "MissingTopic", "BadCertificate",
                                                     "BadCertificateEnvironment"]

    public static func classify(status: Int, body: Data) -> PushResult {
        let reason = (try? JSONDecoder().decode(Reason.self, from: body))?.reason ?? ""
        switch status {
        case 200: return .delivered
        case 410: return .invalidToken(reason.isEmpty ? "Unregistered" : reason)
        case 400 where ["BadDeviceToken", "DeviceTokenNotForTopic"].contains(reason): return .invalidToken(reason)
        // 403: InvalidProviderToken, ExpiredProviderToken, MissingProviderToken, Forbidden, BadCertificate…
        case 403: return .providerError("\(status) \(reason)")
        case 400 where configurationReasons.contains(reason): return .providerError("\(status) \(reason)")
        case 429, 500...599: return .retryLater("\(status) \(reason)")
        default: return .rejected("\(status) \(reason)")
        }
    }
}

/// APNs over HTTP/2 via curl. A rejected provider token (403
/// ExpiredProviderToken/InvalidProviderToken) is renewed once; if APNs still
/// refuses it, the result is `providerError` (configuration, retried later).
public struct APNsClient: PushSender {
    let transport: HTTPTransport
    let tokens: APNsTokenProvider
    let now: @Sendable () -> Date

    public init(transport: HTTPTransport, tokens: APNsTokenProvider, now: @escaping @Sendable () -> Date = { Date() }) {
        self.transport = transport; self.tokens = tokens; self.now = now
    }

    public func send(_ message: PushMessage, to target: PushTarget) async -> PushResult {
        for attempt in 0..<2 {
            let token: String
            do { token = try tokens.token(now: now()) }
            catch { return .providerError("APNs-JWT nicht erzeugbar: \(error)") }
            do {
                let request = try APNs.request(message, to: target, token: token)
                let response = try await transport.send(request)
                let result = APNs.classify(status: response.status, body: response.body)
                if case .providerError(let reason) = result, response.status == 403, attempt == 0,
                   reason.contains("ProviderToken") {
                    tokens.invalidate(); continue
                }
                return result
            } catch let error as TransportError {
                return .retryLater("\(error)")
            } catch {
                return .rejected("\(error)")
            }
        }
        return .providerError("Providertoken abgelehnt")
    }
}
