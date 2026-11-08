import Foundation
import NotebookCore

public struct APIRequest: Sendable {
    public var method: String
    /// Path without query, e.g. „/v1/register“.
    public var path: String
    public var query: [String: String]
    /// Lower-case names.
    public var headers: [String: String]
    public var body: Data
    public var clientIP: String

    public init(method: String, path: String, query: [String: String] = [:], headers: [String: String] = [:], body: Data = Data(),
                clientIP: String = "127.0.0.1") {
        self.method = method; self.path = path; self.query = query; self.headers = headers; self.body = body; self.clientIP = clientIP
    }

    /// Splits „/v1/changes?since=1“ into path and query (first value wins).
    public static func split(_ uri: String) -> (path: String, query: [String: String]) {
        guard let components = URLComponents(string: uri) else { return (uri, [:]) }
        var query: [String: String] = [:]
        for item in components.queryItems ?? [] where query[item.name] == nil { query[item.name] = item.value ?? "" }
        return (components.path, query)
    }
}

public struct APIResponse: Sendable, Equatable {
    public var status: Int
    public var body: Data
    /// Seconds for a `Retry-After` header (429).
    public var retryAfter: Int?
    public var headers: [(String, String)] {
        [("Content-Type", "application/json; charset=utf-8"), ("Cache-Control", "no-store")]
            + (retryAfter.map { [("Retry-After", String(max(1, $0)))] } ?? [])
    }
    public init(status: Int, body: Data, retryAfter: Int? = nil) { self.status = status; self.body = body; self.retryAfter = retryAfter }
    public static func == (a: APIResponse, b: APIResponse) -> Bool { a.status == b.status && a.body == b.body && a.retryAfter == b.retryAfter }

    static func json<T: Encodable>(_ status: Int, _ value: T) -> APIResponse {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        return APIResponse(status: status, body: (try? encoder.encode(value)) ?? Data("{}".utf8))
    }

    struct Failure: Encodable { let error: String; let message: String }
    static func error(_ status: Int, _ code: String, _ message: String) -> APIResponse {
        json(status, Failure(error: code, message: message))
    }

    static func rateLimited(_ message: String, retryAfter: TimeInterval) -> APIResponse {
        var response = error(429, "rate_limited", message)
        response.retryAfter = Int(retryAfter.rounded(.up))
        return response
    }
}

/// Sliding-window counters (in memory; a restart resets them).
final class RateLimiter: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String: [Date]] = [:]

    /// Records an event for `key` and tells whether it stays within `limit` per `window`.
    func allow(_ key: String, limit: Int, window: TimeInterval, now: Date) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let since = now.addingTimeInterval(-window)
        var list = (events[key] ?? []).filter { $0 > since }
        guard list.count < limit else { events[key] = list; return false }
        list.append(now)
        events[key] = list
        if events.count > 10_000 { events = events.filter { $0.value.contains { $0 > since } } }
        return true
    }

    /// Nil while `key` stays below `limit` events per `window` (nothing is
    /// recorded), else the seconds until the oldest event leaves the window.
    func wait(_ key: String, limit: Int, window: TimeInterval, now: Date) -> TimeInterval? {
        lock.lock(); defer { lock.unlock() }
        let since = now.addingTimeInterval(-window)
        let list = (events[key] ?? []).filter { $0 > since }
        events[key] = list.isEmpty ? nil : list
        guard list.count >= limit, let oldest = list.min() else { return nil }
        return max(1, oldest.addingTimeInterval(window).timeIntervalSince(now))
    }

    /// Records an event for `key` (counted by `wait`).
    func record(_ key: String, window: TimeInterval, now: Date) {
        lock.lock(); defer { lock.unlock() }
        let since = now.addingTimeInterval(-window)
        events[key] = (events[key] ?? []).filter { $0 > since } + [now]
        if events.count > 10_000 { events = events.filter { $0.value.contains { $0 > since } } }
    }
}

/// HTTP API (behind nginx, docs/PUSH.md):
///   GET    /v1/health
///   POST   /v1/register            → 201 {deviceID, deviceSecret, status}
///   PUT    /v1/device   (Bearer)   → 200 {status}
///   DELETE /v1/device   (Bearer)   → 204
///   GET    /v1/changes?since=UNIX  (Bearer) → 200 {changes, status}
/// Authorization: `Bearer <deviceID>.<deviceSecret>`.
public final class APIRouter: Sendable {
    public static let maximumBodyBytes = 16 * 1024
    /// Failed authentications per device id and hour; then 429 (never 401,
    /// the app deletes its secret on 401) until the window has passed.
    public static let authFailuresPerHour = 120

    let service: PushService
    let config: PushConfig
    let limiter = RateLimiter()
    let now: @Sendable () -> Date

    public init(service: PushService, config: PushConfig, now: @escaping @Sendable () -> Date = { Date() }) {
        self.service = service; self.config = config; self.now = now
    }

    public func handle(_ request: APIRequest) async -> APIResponse {
        let time = now()
        guard request.body.count <= Self.maximumBodyBytes else { return .error(413, "too_large", "Anfrage zu groß.") }
        guard limiter.allow("ip:" + request.clientIP, limit: config.requestsPerMinutePerIP, window: 60, now: time) else {
            return .rateLimited("Zu viele Anfragen. Bitte später erneut versuchen.", retryAfter: 60)
        }
        switch (request.method, request.path) {
        case ("GET", "/v1/health"):
            return .json(200, ["ok": true])
        case ("POST", "/v1/register"):
            // Per address every attempt counts (before any work); the daily
            // limit of the whole service only counts registrations that
            // succeeded, so invalid requests cannot use it up.
            guard limiter.allow("register-ip:" + request.clientIP, limit: config.registrationsPerHourPerIP, window: 3600, now: time) else {
                return .rateLimited("Zu viele Anmeldungen. Bitte später erneut versuchen.", retryAfter: 3600)
            }
            if let wait = limiter.wait("register", limit: config.registrationsPerDay, window: 86_400, now: time) {
                return .rateLimited("Zu viele Anmeldungen. Bitte später erneut versuchen.", retryAfter: wait)
            }
            let response = await register(request)
            if response.status == 201 { limiter.record("register", window: 86_400, now: now()) }
            return response
        case ("PUT", "/v1/device"), ("DELETE", "/v1/device"), ("GET", "/v1/changes"), ("GET", "/v1/device"):
            let id: String
            switch await authenticate(request) {
            case .device(let value): id = value
            case .unauthorized:
                return .error(401, "unauthorized", "Gerät unbekannt oder abgemeldet. Bitte Mitteilungen in der App neu einrichten.")
            case .rateLimited(let wait):
                return .rateLimited("Zu viele fehlgeschlagene Anmeldungen dieses Geräts. Bitte später erneut versuchen.", retryAfter: wait)
            }
            if request.method != "DELETE" { await service.recordContact(id: id) }
            switch request.method {
            case "PUT": return await update(id, request)
            case "DELETE":
                do { try await service.delete(id: id); return APIResponse(status: 204, body: Data()) }
                catch { return response(for: error) }
            default:
                if request.path == "/v1/device" {
                    guard let status = await service.status(id: id) else { return .error(404, "not_found", "Gerät unbekannt.") }
                    return .json(200, ["status": status])
                }
                return await changes(id, request)
            }
        default:
            return .error(404, "not_found", "Unbekannter Pfad.")
        }
    }

    // MARK: Auth

    enum Authentication: Equatable { case device(String), unauthorized, rateLimited(TimeInterval) }

    /// Only failed attempts count towards the limit of a device id: a correct
    /// secret is never answered with 401 because someone else guessed.
    func authenticate(_ request: APIRequest) async -> Authentication {
        guard let header = request.headers["authorization"], header.count <= 200, header.hasPrefix("Bearer ") else { return .unauthorized }
        let value = header.dropFirst("Bearer ".count)
        guard let dot = value.firstIndex(of: ".") else { return .unauthorized }
        let id = String(value[..<dot]), secret = String(value[value.index(after: dot)...])
        guard DeviceStore.isValidID(id), (20...100).contains(secret.count) else { return .unauthorized }
        let key = "auth-failed:" + id
        if let wait = limiter.wait(key, limit: Self.authFailuresPerHour, window: 3600, now: now()) { return .rateLimited(wait) }
        guard await service.authenticate(id: id, secret: secret) else {
            limiter.record(key, window: 3600, now: now())
            return .unauthorized
        }
        return .device(id)
    }

    // MARK: Bodies

    struct SetupBody: Decodable { let server: String; let school: String; let user: String; let key: String; let schoolNumber: String? }
    struct RegisterBody: Decodable {
        let deviceToken: String
        let apnsEnvironment: String
        let bundleID: String
        let connectionID: String
        /// Device time zone (schedule, quiet hours).
        let timeZone: String?
        /// Time zone of the connection (`CalendarConnectionRecord.timeZone`); default Europe/Berlin.
        let connectionTimeZone: String?
        let consent: String
        let setup: SetupBody
        let settings: DeviceSettings?
    }
    struct UpdateBody: Decodable {
        let deviceToken: String?
        let apnsEnvironment: String?
        let bundleID: String?
        let connectionID: String?
        let timeZone: String?
        let connectionTimeZone: String?
        let consent: String?
        let setup: SetupBody?
        let settings: DeviceSettings?
    }

    enum Invalid: Error { case field(String) }

    static func token(_ raw: String) throws -> String {
        let token = raw.lowercased()
        guard (64...400).contains(token.count), token.count % 2 == 0, token.allSatisfy({ $0.isHexDigit }) else { throw Invalid.field("deviceToken") }
        return token
    }
    static func environment(_ raw: String) throws -> APNsEnvironment {
        guard let value = APNsEnvironment(rawValue: raw) else { throw Invalid.field("apnsEnvironment") }
        return value
    }
    func bundle(_ raw: String) throws -> String {
        guard config.allowedBundleIDs.contains(raw) else { throw Invalid.field("bundleID") }
        return raw
    }
    static func connection(_ raw: String) throws -> UUID {
        guard let id = UUID(uuidString: raw) else { throw Invalid.field("connectionID") }
        return id
    }
    static func zone(_ raw: String?, field: String = "timeZone") throws -> String {
        let value = raw ?? CalendarDefaults.timeZoneIdentifier
        guard value.count <= 64, TimeZone(identifier: value) != nil, value.contains("/") || value == "UTC" else { throw Invalid.field(field) }
        return value
    }
    static func setup(_ body: SetupBody) throws -> WebUntisSetup {
        guard body.key.count <= 256, body.server.count <= 300 else { throw Invalid.field("setup") }
        do { return try WebUntisSetup(server: body.server, school: body.school, user: body.user, key: body.key, schoolNumber: body.schoolNumber) }
        catch { throw Invalid.field("setup") }
    }
    static func settings(_ value: DeviceSettings?) -> DeviceSettings { value ?? DeviceSettings() }

    func decode<T: Decodable>(_ type: T.Type, _ request: APIRequest) -> T? {
        guard request.headers["content-type"]?.lowercased().hasPrefix("application/json") == true else { return nil }
        return try? JSONDecoder().decode(T.self, from: request.body)
    }

    func validationError(_ error: Error) -> APIResponse {
        if case Invalid.field(let name) = error {
            return .error(400, "invalid_\(name)", name == "setup"
                ? "Die WebUntis-Freigabe ist unvollständig oder ungültig."
                : "Ungültiger Wert: \(name).")
        }
        return .error(400, "invalid", "Ungültige Anfrage.")
    }

    // MARK: Handlers

    struct Registered: Encodable { let deviceID: String; let deviceSecret: String; let status: DeviceStatus }

    func register(_ request: APIRequest) async -> APIResponse {
        guard let body = decode(RegisterBody.self, request) else { return .error(400, "invalid_json", "Ungültige Anfrage.") }
        guard body.consent == config.consentVersion else {
            return .error(400, "consent_required", "Die Einwilligung zur Speicherung der Freigabe auf dem Server fehlt oder ist veraltet.")
        }
        let input: RegistrationInput
        do {
            input = RegistrationInput(deviceToken: try Self.token(body.deviceToken), environment: try Self.environment(body.apnsEnvironment),
                                      bundleID: try bundle(body.bundleID), connectionID: try Self.connection(body.connectionID),
                                      timeZone: try Self.zone(body.timeZone), settings: Self.settings(body.settings),
                                      setup: try Self.setup(body.setup),
                                      connectionTimeZone: try Self.zone(body.connectionTimeZone, field: "connectionTimeZone"))
        } catch { return validationError(error) }
        do {
            let result = try await service.register(input)
            return .json(201, Registered(deviceID: result.deviceID, deviceSecret: result.secret, status: result.status))
        } catch { return response(for: error) }
    }

    func update(_ id: String, _ request: APIRequest) async -> APIResponse {
        guard let body = decode(UpdateBody.self, request) else { return .error(400, "invalid_json", "Ungültige Anfrage.") }
        var input = UpdateInput()
        do {
            if let value = body.deviceToken { input.deviceToken = try Self.token(value) }
            if let value = body.apnsEnvironment { input.environment = try Self.environment(value) }
            if let value = body.bundleID { input.bundleID = try bundle(value) }
            if let value = body.connectionID { input.connectionID = try Self.connection(value) }
            if body.timeZone != nil { input.timeZone = try Self.zone(body.timeZone) }
            if body.connectionTimeZone != nil { input.connectionTimeZone = try Self.zone(body.connectionTimeZone, field: "connectionTimeZone") }
            if let value = body.setup {
                guard body.consent == config.consentVersion else {
                    return .error(400, "consent_required", "Die Einwilligung zur Speicherung der Freigabe auf dem Server fehlt oder ist veraltet.")
                }
                input.setup = try Self.setup(value)
            }
            input.settings = body.settings
        } catch { return validationError(error) }
        do { return .json(200, ["status": try await service.update(id: id, input)]) }
        catch { return response(for: error) }
    }

    struct ChangesBody: Encodable { let changes: [ChangeEntry]; let status: DeviceStatus; let serverTime: Date }

    func changes(_ id: String, _ request: APIRequest) async -> APIResponse {
        var since: Date?
        if let raw = request.query["since"] {
            guard let seconds = Double(raw), seconds.isFinite, seconds >= 0, seconds < 1e11 else {
                return .error(400, "invalid_since", "since: Unix-Zeit in Sekunden erwartet.")
            }
            since = Date(timeIntervalSince1970: seconds)
        }
        do {
            let result = try await service.changes(id: id, since: since)
            return .json(200, ChangesBody(changes: result.changes, status: result.status, serverTime: now()))
        } catch { return response(for: error) }
    }

    func response(for error: Error) -> APIResponse {
        switch error {
        case ServiceError.limitReached:
            return .error(403, "limit_reached", "Der Mitteilungsdienst nimmt keine weiteren Geräte an.")
        case ServiceError.notFound:
            return .error(404, "not_found", "Gerät unbekannt.")
        case ServiceError.serverNotAllowed:
            let hosts = config.allowedUntisHostSuffixes.map { "<schule>." + $0 }.joined(separator: ", ")
            return .error(400, "invalid_server", "Der Mitteilungsdienst ruft nur WebUntis-Server der Form \(hosts) ab; diese Freigabe nennt einen anderen Server.")
        case ServiceError.untis(let failure):
            if failure == .authentication {
                return .error(422, "untis_rejected", failure.message)
            }
            return .error(502, "untis_unavailable", "WebUntis war für den Server nicht erreichbar oder lieferte keine lesbare Antwort. Bitte später erneut versuchen.")
        default:
            Log.error("interner Fehler: \(error)")
            return .error(500, "internal", "Interner Fehler des Mitteilungsdienstes.")
        }
    }
}
