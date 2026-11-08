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

/// Sliding-window counters of one category (in memory; a restart resets
/// them). Every category has its own limiter and so its own window: tidying
/// the per-minute counters never drops hourly or daily ones. At most
/// `maximumKeys` keys: expired keys go from time to time (amortized), and if
/// there are still too many, the keys whose newest event is oldest – their
/// limits start again, never all of them. A key keeps at most `limit` events.
final class RateLimiter: @unchecked Sendable {
    let window: TimeInterval
    let maximumKeys: Int
    /// Every this many recorded events expired keys are dropped.
    static let tidyInterval = 512
    private let lock = NSLock()
    private var events: [String: [Date]] = [:]
    private var writes = 0

    init(window: TimeInterval, maximumKeys: Int = 10_000) {
        self.window = window
        self.maximumKeys = max(10, maximumKeys)
    }

    /// Keys held now (tests).
    var keyCount: Int { lock.withLock { events.count } }

    /// Records an event for `key` and tells whether it stays within `limit` per window.
    func allow(_ key: String, limit: Int, now: Date) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let list = current(key, now: now)
        guard list.count < limit else { events[key] = list; return false }
        store(key, list + [now], limit: limit, now: now)
        return true
    }

    /// Nil while `key` stays below `limit` events per window (nothing is
    /// recorded), else the seconds until it is below the limit again.
    func wait(_ key: String, limit: Int, now: Date) -> TimeInterval? {
        lock.lock(); defer { lock.unlock() }
        let list = current(key, now: now)
        events[key] = list.isEmpty ? nil : list
        guard list.count >= max(1, limit) else { return nil }
        let leaving = list[list.count - max(1, limit)]
        return max(1, leaving.addingTimeInterval(window).timeIntervalSince(now))
    }

    /// Records an event for `key` (counted by `wait` with the same `limit`).
    func record(_ key: String, limit: Int, now: Date) {
        lock.lock(); defer { lock.unlock() }
        store(key, current(key, now: now) + [now], limit: limit, now: now)
    }

    /// Events of `key` within the window, oldest first.
    private func current(_ key: String, now: Date) -> [Date] {
        let since = now.addingTimeInterval(-window)
        return (events[key] ?? []).filter { $0 > since }.sorted()
    }

    private func store(_ key: String, _ list: [Date], limit: Int, now: Date) {
        events[key] = Array(list.sorted().suffix(max(1, limit)))
        writes &+= 1
        if events.count > maximumKeys || writes % Self.tidyInterval == 0 { tidy(now: now) }
    }

    private func tidy(now: Date) {
        let since = now.addingTimeInterval(-window)
        events = events.filter { $0.value.contains { $0 > since } }
        guard events.count > maximumKeys else { return }
        // Still too many active keys: the least recently active go, down to 90 %
        // (so the next eviction is again some insertions away).
        let keep = maximumKeys * 9 / 10
        let newest = events.sorted { ($0.value.last ?? .distantPast, $0.key) > ($1.value.last ?? .distantPast, $1.key) }
        events = Dictionary(uniqueKeysWithValues: newest.prefix(keep).map { ($0.key, $0.value) })
    }
}

/// What a client address is limited by: IPv4 as it is, IPv6 by its /64
/// network (one connection usually holds a whole /64, single addresses cost
/// nothing), an IPv4-mapped IPv6 address (`::ffff:a.b.c.d`) as that IPv4
/// address. Anything unparsable is used as it is (at most 64 characters).
enum ClientAddress {
    static func key(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if text.hasPrefix("["), let end = text.firstIndex(of: "]") { text = String(text[text.index(after: text.startIndex)..<end]) }
        if let zone = text.firstIndex(of: "%") { text = String(text[..<zone]) }
        guard text.contains(":"), let groups = ipv6Groups(text) else { return String(text.prefix(64)) }
        if groups[0..<5].allSatisfy({ $0 == 0 }) && groups[5] == 0xffff {
            return "\(groups[6] >> 8).\(groups[6] & 0xff).\(groups[7] >> 8).\(groups[7] & 0xff)"
        }
        return groups[0..<4].map { String($0, radix: 16) }.joined(separator: ":") + "::/64"
    }

    /// The eight 16-bit groups of an IPv6 address („::“ and a final dotted
    /// IPv4 part allowed), nil when it is none.
    static func ipv6Groups(_ text: String) -> [UInt16]? {
        func parse(_ part: String, allowIPv4: Bool) -> [UInt16]? {
            if part.isEmpty { return [] }
            var result: [UInt16] = []
            let pieces = part.split(separator: ":", omittingEmptySubsequences: false)
            for (index, piece) in pieces.enumerated() {
                if piece.contains(".") {
                    guard allowIPv4, index == pieces.count - 1, let value = ipv4(piece) else { return nil }
                    result += [UInt16(value >> 16), UInt16(value & 0xffff)]
                } else {
                    guard (1...4).contains(piece.count), piece.allSatisfy({ $0.isASCII && $0.isHexDigit }),
                          let value = UInt16(piece, radix: 16) else { return nil }
                    result.append(value)
                }
            }
            return result
        }
        let halves = text.components(separatedBy: "::")
        switch halves.count {
        case 1:
            guard let all = parse(text, allowIPv4: true), all.count == 8 else { return nil }
            return all
        case 2:
            guard let head = parse(halves[0], allowIPv4: false), let tail = parse(halves[1], allowIPv4: true),
                  head.count + tail.count <= 7 else { return nil }
            return head + Array(repeating: 0, count: 8 - head.count - tail.count) + tail
        default:
            return nil
        }
    }

    static func ipv4(_ text: Substring) -> UInt32? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var value: UInt32 = 0
        for part in parts {
            guard (1...3).contains(part.count), part.allSatisfy({ $0.isASCII && $0.isNumber }), let byte = UInt32(part), byte <= 255 else {
                return nil
            }
            value = value << 8 | byte
        }
        return value
    }
}

/// HTTP API (behind nginx, docs/PUSH.md):
///   GET    /v1/health
///   POST   /v1/register            → 201 {deviceID, deviceSecret, status}
///   PUT    /v1/device   (Bearer)   → 200 {status}
///   DELETE /v1/device   (Bearer)   → 204
///   DELETE /v1/device   (Registration) → 204: a registration whose answer the app never got
///   GET    /v1/device   (Bearer)   → 200 {status}
///   GET    /v1/changes?since=UNIX  (Bearer) → 200 {changes, status}
/// Authorization: `Bearer <deviceID>.<deviceSecret>`, or for the deletion of
/// an unanswered registration `Registration <registrationID>` (the random
/// id the app sent with `POST /v1/register`).
public final class APIRouter: Sendable {
    public static let maximumBodyBytes = 16 * 1024
    /// Failed authentications per device id and hour; then 429 (never 401,
    /// the app deletes its secret on 401) until the window has passed.
    public static let authFailuresPerHour = 120

    let service: PushService
    let config: PushConfig
    /// One limiter per category, each with its own window.
    let requests = RateLimiter(window: 60)
    let registrationsPerAddress = RateLimiter(window: 3600)
    let registrationAttempts = RateLimiter(window: 3600, maximumKeys: 10)
    let registrationsPerDay = RateLimiter(window: 86_400, maximumKeys: 10)
    let authFailures = RateLimiter(window: 3600)
    let now: @Sendable () -> Date

    public init(service: PushService, config: PushConfig, now: @escaping @Sendable () -> Date = { Date() }) {
        self.service = service; self.config = config; self.now = now
    }

    public func handle(_ request: APIRequest) async -> APIResponse {
        let time = now()
        guard request.body.count <= Self.maximumBodyBytes else { return .error(413, "too_large", "Anfrage zu groß.") }
        let address = ClientAddress.key(request.clientIP)
        guard requests.allow(address, limit: config.requestsPerMinutePerIP, now: time) else {
            return .rateLimited("Zu viele Anfragen. Bitte später erneut versuchen.", retryAfter: 60)
        }
        switch (request.method, request.path) {
        case ("GET", "/v1/health"):
            return .json(200, ["ok": true])
        case ("POST", "/v1/register"):
            // Per address and for the whole service every attempt counts
            // (before any work); the daily limit only counts registrations
            // that succeeded, so invalid requests cannot use it up.
            guard registrationsPerAddress.allow(address, limit: config.registrationsPerHourPerIP, now: time) else {
                return .rateLimited("Zu viele Anmeldungen. Bitte später erneut versuchen.", retryAfter: 3600)
            }
            guard registrationAttempts.allow("all", limit: config.registrationAttemptsPerHour, now: time) else {
                let wait = registrationAttempts.wait("all", limit: config.registrationAttemptsPerHour, now: time) ?? 60
                return .rateLimited("Zu viele Anmeldungen. Bitte später erneut versuchen.", retryAfter: wait)
            }
            if let wait = registrationsPerDay.wait("all", limit: config.registrationsPerDay, now: time) {
                return .rateLimited("Zu viele Anmeldungen. Bitte später erneut versuchen.", retryAfter: wait)
            }
            let response = await register(request)
            if response.status == 201 { registrationsPerDay.record("all", limit: config.registrationsPerDay, now: now()) }
            return response
        case ("DELETE", "/v1/device") where request.headers["authorization"]?.hasPrefix(Self.registrationScheme) == true:
            // A registration the app gave up waiting for: only who knows its random id can delete it.
            guard let hash = Self.registrationHash(fromHeader: request.headers["authorization"]) else {
                return .error(400, "invalid_registrationID", "Ungültiger Wert: registrationID.")
            }
            do { try await service.deleteRegistration(hash: hash); return APIResponse(status: 204, body: Data()) }
            catch { return response(for: error) }
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

    /// `Authorization: Registration <registrationID>`.
    static let registrationScheme = "Registration "

    /// SHA-256 (hex) of a registration id: a UUID, compared in lower case.
    /// The server keeps only this hash.
    public static func registrationHash(_ raw: String) -> String? {
        guard raw.count == 36, let id = UUID(uuidString: raw) else { return nil }
        return Secrets.hash("registration/" + id.uuidString.lowercased())
    }

    static func registrationHash(fromHeader header: String?) -> String? {
        guard let header, header.count <= 100, header.hasPrefix(registrationScheme) else { return nil }
        return registrationHash(String(header.dropFirst(registrationScheme.count)))
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
        // Deliberate (ReviewFixTests): over the limit even the right secret gets
        // 429, never 401 – the app keeps its secret and retries later. Only
        // someone who knows the (non-public) device id could cause that wait.
        if let wait = authFailures.wait(id, limit: Self.authFailuresPerHour, now: now()) { return .rateLimited(wait) }
        guard await service.authenticate(id: id, secret: secret) else {
            authFailures.record(id, limit: Self.authFailuresPerHour, now: now())
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
        /// Random UUID of the app for this registration (optional, since
        /// 11.2026): sent again after a timeout, the same device answers
        /// with a new secret instead of a second device being created.
        let registrationID: String?
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
    static func settings(_ value: DeviceSettings?) throws -> DeviceSettings {
        guard let value else { return DeviceSettings() }
        guard value.isValid else { throw Invalid.field("settings") }
        return value
    }

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
        var input: RegistrationInput
        do {
            input = RegistrationInput(deviceToken: try Self.token(body.deviceToken), environment: try Self.environment(body.apnsEnvironment),
                                      bundleID: try bundle(body.bundleID), connectionID: try Self.connection(body.connectionID),
                                      timeZone: try Self.zone(body.timeZone), settings: try Self.settings(body.settings),
                                      setup: try Self.setup(body.setup),
                                      connectionTimeZone: try Self.zone(body.connectionTimeZone, field: "connectionTimeZone"))
            if let raw = body.registrationID {
                guard let hash = Self.registrationHash(raw) else { throw Invalid.field("registrationID") }
                input.registrationHash = hash
            }
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
            if let settings = body.settings {
                guard settings.isValid else { throw Invalid.field("settings") }
                input.settings = settings
            }
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
        case ServiceError.registrationInProgress:
            var response = APIResponse.error(409, "registration_in_progress",
                                             "Diese Anmeldung wird gerade noch bearbeitet. Bitte in einer Minute erneut versuchen.")
            response.retryAfter = 60
            return response
        case ServiceError.registrationCancelled:
            return .error(410, "registration_cancelled", "Diese Anmeldung wurde inzwischen zurückgezogen.")
        case ServiceError.busy:
            var response = APIResponse.error(503, "busy", "Der Mitteilungsdienst prüft gerade andere Freigaben. Bitte gleich erneut versuchen.")
            response.retryAfter = 30
            return response
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
