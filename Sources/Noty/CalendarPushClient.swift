import Foundation
import UIKit
import Security
import NotebookCore

/// Push-Dienst (docs/PUSH.md, „Was in der App …“): noty calendar meldet sich
/// beim eigenen Server noty-push an, damit Stundenplanänderungen auch bei
/// geschlossener App als Mitteilung kommen. Nur nach ausdrücklicher
/// Einwilligung (`consentVersion`) wird die WebUntis-Freigabe hochgeladen;
/// ohne sie bleibt alles lokal wie bisher.
enum CalendarPush {
    static let consentVersion = "webuntis-push-1"
    static let consentTitle = "Mitteilungen auch bei geschlossener App?"
    static let consentText = "Damit Stundenplanänderungen auch bei geschlossener App gemeldet werden, speichert noty calendar deine WebUntis-Freigabe (Server, Schule, Benutzer, Schlüssel) verschlüsselt auf dem noty-Server (noty.xclipsen.de). Der Server ruft deinen Stundenplan stündlich zwischen 5 und 21 Uhr ab (am Wochenende seltener) und schickt Mitteilungen über Apple. Gespeichert werden außerdem dieses Gerät (Mitteilungs-Token) und die Stunden der nächsten zwei Wochen zum Vergleich. ‚Trennen‘ oder ‚Mitteilungen aus‘ löscht alles auf dem Server sofort."

    /// Only noty calendar talks to the server (its bundle id is the only
    /// allowed APNs topic there).
    /// Apps with push: noty and noty calendar (each its own topic = bundle id).
    static let channels: Set<String> = ["stable", "calendar"]

    enum Availability: Equatable, Sendable {
        /// `environment`: „sandbox“ or „production“ as the server expects it.
        case available(environment: String)
        case unavailable(String)
        /// Another app of the family (noty, noty dev, noty AI): no push at all.
        case otherChannel
    }

    static let availability: Availability = {
        let channel = Bundle.main.object(forInfoDictionaryKey: "NotyChannel") as? String ?? "stable"
        guard Self.channels.contains(channel) else { return .otherChannel }
        guard baseURL != nil else { return .unavailable("Die Adresse des Mitteilungsdienstes fehlt in dieser Version.") }
        switch provisionedAPSEnvironment() {
        case "development": return .available(environment: "sandbox")
        case "production": return .available(environment: "production")
        default:
            return .unavailable("Diese Installation ist nicht für Push-Mitteilungen signiert (aps-environment fehlt im Profil).")
        }
    }()

    /// Info.plist `NotyPushURL`, e.g. „https://noty.xclipsen.de/push“ (paths `/v1/…` follow).
    static var baseURL: URL? {
        guard let text = Bundle.main.object(forInfoDictionaryKey: "NotyPushURL") as? String, let url = URL(string: text),
              url.scheme == "https", url.host != nil else { return nil }
        return url
    }

    /// `aps-environment` of the embedded provisioning profile (development
    /// or production); nil without profile or without the capability. The
    /// token APNs hands out belongs to exactly this environment.
    static func provisionedAPSEnvironment() -> String? {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let raw = try? Data(contentsOf: url),
              let start = raw.range(of: Data("<?xml".utf8)), let end = raw.range(of: Data("</plist>".utf8), in: start.lowerBound..<raw.endIndex),
              let plist = try? PropertyListSerialization.propertyList(from: raw.subdata(in: start.lowerBound..<end.upperBound), format: nil)
                as? [String: Any],
              let entitlements = plist["Entitlements"] as? [String: Any] else { return nil }
        return entitlements["aps-environment"] as? String
    }

    /// Default zone of a WebUntis connection (`connect` creates them with it).
    static let defaultTimeZone = CalendarDefaults.timeZoneIdentifier

    /// Time zone as the server accepts it (region identifiers or UTC).
    static func zone(_ zone: TimeZone) -> String {
        let id = zone.identifier
        return id.count <= 64 && (id.contains("/") || id == "UTC") ? id : defaultTimeZone
    }

    /// `connectionTimeZone`: the zone the lessons of the connection are in
    /// (`CalendarConnectionRecord.timeZone`), Europe/Berlin when unusable.
    static func connectionZone(_ connection: CalendarConnectionRecord?) -> String {
        zone(connection.flatMap { TimeZone(identifier: $0.timeZone) } ?? CalendarDefaults.timeZone)
    }
}

/// Device id and secret of the registration in the device keychain only
/// (`…ThisDeviceOnly`: never in files, UserDefaults, iCloud or backups).
enum CalendarPushKeychain {
    struct Credentials: Codable, Equatable, Sendable {
        let deviceID: String
        let secret: String
    }

    private static let service = "noty.calendar.push"
    private static let account = "device"
    /// The random id of a registration whose answer has not arrived (yet).
    private static let registrationAccount = "registration"

    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    private static func store(_ data: Data, account: String) throws {
        SecItemDelete(query(account) as CFDictionary)
        var item = query(account)
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw WebUntisKeychain.Failure.status(status) }
    }

    /// `locked`: not readable yet (device not unlocked since its start).
    private static func load(account: String) -> (data: Data?, locked: Bool) {
        var request = query(account)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return (nil, status == errSecInteractionNotAllowed) }
        return (data, false)
    }

    private static func remove(account: String) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw WebUntisKeychain.Failure.status(status) }
    }

    static func save(_ credentials: Credentials) throws {
        try store(try JSONEncoder().encode(credentials), account: account)
    }

    /// `locked`: not readable yet (device not unlocked since its start).
    static func read() -> (credentials: Credentials?, locked: Bool) {
        let stored = load(account: account)
        return (stored.data.flatMap { try? JSONDecoder().decode(Credentials.self, from: $0) }, stored.locked)
    }

    static func delete() throws { try remove(account: account) }

    /// Registration id (a UUID) chosen before `POST /v1/register` and kept
    /// until its answer arrived or the server confirmed its deletion: a
    /// registration whose answer got lost (timeout, app closed) is found
    /// again by it – never a device on the server the app knows nothing of.
    static func savePendingRegistration(_ id: String) throws { try store(Data(id.utf8), account: registrationAccount) }

    static func readPendingRegistration() -> (id: String?, locked: Bool) {
        let stored = load(account: registrationAccount)
        let id = stored.data.map { String(decoding: $0, as: UTF8.self) }.flatMap { UUID(uuidString: $0) != nil ? $0 : nil }
        return (id, stored.locked)
    }

    static func deletePendingRegistration() throws { try remove(account: registrationAccount) }
}

/// What the app remembers about its registration besides the secret: a
/// device preference (UserDefaults), no calendar data, no secret. Tolerant:
/// unknown or missing fields keep their defaults.
struct CalendarPushState: Codable, Equatable, Sendable {
    /// The user's choice: nil = not asked yet, false = local only.
    var wanted: Bool?
    /// Consent version the user agreed to, and when.
    var consent: String?
    var consentDate: Date?
    /// The WebUntis connection (and its area) push is meant for.
    var connectionID: UUID?
    var namespace: String?
    /// The server knows this device (as far as the app knows).
    var registered = false
    /// The connection the server polls for.
    var serverConnectionID: UUID?
    /// `status.state` of the last answer: active, authFailed, tokenInvalid.
    var serverState: String?
    /// German category of the server's last WebUntis problem.
    var serverError: String?
    /// The app's last problem with the server (German sentence).
    var lastError: String?
    var lastFailure: Date?
    /// Last successful answer of the server.
    var lastContact: Date?
    /// What the server has, to send only changes (`PUT`).
    var sentToken: String?
    var sentEnvironment: String?
    var sentSettings: CalendarNotificationSettings?
    var sentTimeZone: String?
    /// `since` of the next `GET /v1/changes` (Unix seconds, whole).
    var since: Int?
    /// „Aus“/„Trennen“ could not reach the server yet: repeated at the next start.
    var pendingDelete = false
    /// Last automatic registration attempt (no hammering after a failure).
    var lastRegisterAttempt: Date?
    /// Last automatic retry of the same Freigabe after „Untis-Zugang prüfen“.
    var lastAuthRetry: Date?

    private static let key = "noty.calendar.push.state"

    init() {}

    static func load() -> CalendarPushState {
        guard let data = UserDefaults.standard.data(forKey: key),
              let value = try? JSONDecoder().decode(CalendarPushState.self, from: data) else { return CalendarPushState() }
        return value
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Self.key) }
    }

    private enum CodingKeys: String, CodingKey {
        case wanted, consent, consentDate, connectionID, namespace, registered, serverConnectionID, serverState, serverError, lastError,
             lastFailure, lastContact, sentToken, sentEnvironment, sentSettings, sentTimeZone, since, pendingDelete, lastRegisterAttempt,
             lastAuthRetry
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys) -> T? { try? c.decodeIfPresent(T.self, forKey: key) }
        wanted = value(.wanted); consent = value(.consent); consentDate = value(.consentDate)
        connectionID = value(.connectionID); namespace = value(.namespace); registered = value(.registered) ?? false
        serverConnectionID = value(.serverConnectionID); serverState = value(.serverState); serverError = value(.serverError)
        lastError = value(.lastError); lastFailure = value(.lastFailure); lastContact = value(.lastContact)
        sentToken = value(.sentToken); sentEnvironment = value(.sentEnvironment); sentSettings = value(.sentSettings)
        sentTimeZone = value(.sentTimeZone); since = value(.since); pendingDelete = value(.pendingDelete) ?? false
        lastRegisterAttempt = value(.lastRegisterAttempt); lastAuthRetry = value(.lastAuthRetry)
    }

    /// Forget everything the server had (after 204 or 401).
    mutating func clearServer() {
        registered = false; serverConnectionID = nil; serverState = nil; serverError = nil
        sentToken = nil; sentEnvironment = nil; sentSettings = nil; sentTimeZone = nil; since = nil
    }
}

/// HTTP of the push API (docs/PUSH.md, „HTTP-API“). No request content,
/// token or secret is logged.
struct CalendarPushAPI: Sendable {
    let base: URL

    struct Failure: Error, LocalizedError, Sendable {
        let status: Int
        let code: String?
        let message: String
        /// 429: seconds the server asks to wait (`Retry-After`).
        var retryAfter: TimeInterval? = nil
        var errorDescription: String? { message }
        /// The server itself says it does not know this device (401 with
        /// `unauthorized` from noty-push): its data are gone there. Any other
        /// 401 (e.g. from a proxy) proves nothing.
        var deviceUnknown: Bool { status == 401 && code == "unauthorized" }
        var rateLimited: Bool { status == 429 }
        /// The server may have done the work although no success came back:
        /// no answer, a gateway timeout, or the same registration still running.
        var outcomeUnknown: Bool { status == 0 || status == 409 || status == 504 || (status >= 500 && code == nil) }
    }

    struct Status: Decodable, Sendable {
        let deviceID: String
        let state: String
        let connectionID: String?
        let lastError: String?
        /// Last (successful) WebUntis fetch of the server, Unix seconds.
        let lastPoll: Double?
        let lastSuccess: Double?
    }
    struct Registered: Decodable, Sendable { let deviceID: String; let deviceSecret: String; let status: Status }
    struct StatusBody: Decodable, Sendable { let status: Status }
    struct Change: Decodable, Sendable {
        let id: String
        let title: String
        let body: String
        let detected: Double
        let day: String
        let entryID: String
    }
    struct Changes: Decodable, Sendable { let changes: [Change]; let status: Status; let serverTime: Double }

    struct Setup: Encodable, Sendable {
        let server: String, school: String, user: String, key: String
        let schoolNumber: String?
        init(_ setup: WebUntisSetup) {
            server = setup.server; school = setup.school; user = setup.user; key = setup.key; schoolNumber = setup.schoolNumber
        }
    }
    struct Register: Encodable, Sendable {
        let deviceToken: String, apnsEnvironment: String, bundleID: String, connectionID: String, timeZone: String, consent: String
        /// Zone of the connection's lessons (the server's default is Europe/Berlin).
        let connectionTimeZone: String
        let setup: Setup
        let settings: CalendarNotificationSettings
        /// Random id of this registration (`CalendarPushKeychain.savePendingRegistration`):
        /// sent again after a lost answer, the server answers with the same device.
        let registrationID: String
    }
    struct Update: Encodable, Sendable {
        var deviceToken: String?, apnsEnvironment: String?, bundleID: String?, connectionID: String?, timeZone: String?, consent: String?
        var connectionTimeZone: String?
        var setup: Setup?
        var settings: CalendarNotificationSettings?
        var isEmpty: Bool {
            deviceToken == nil && apnsEnvironment == nil && bundleID == nil && connectionID == nil && timeZone == nil && setup == nil
                && settings == nil && connectionTimeZone == nil
        }
        /// A new Freigabe, connection or lesson zone: the server fetches from WebUntis first.
        var waitsForWebUntis: Bool { setup != nil || connectionID != nil || connectionTimeZone != nil }
    }

    /// A registration or a new Freigabe waits for the server's test fetch
    /// from WebUntis (2 × up to 40 s, the server gives up after 150 s, nginx
    /// after 120 s); everything else answers at once (a background refresh
    /// must not spend its time on a server that does not answer).
    static let slowTimeout: TimeInterval = 130
    static let quickTimeout: TimeInterval = 20

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = quickTimeout
        configuration.timeoutIntervalForResource = slowTimeout + 10
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    func register(_ body: Register) async throws -> Registered {
        try decode(Registered.self, try await send("POST", "v1/register", body: try JSONEncoder().encode(body), authorization: nil, expect: 201,
                                                   timeout: Self.slowTimeout))
    }

    func update(_ body: Update, credentials: CalendarPushKeychain.Credentials) async throws -> Status {
        try decode(StatusBody.self, try await send("PUT", "v1/device", body: try JSONEncoder().encode(body), authorization: Self.bearer(credentials),
                                                   expect: 200, timeout: body.waitsForWebUntis ? Self.slowTimeout : Self.quickTimeout)).status
    }

    func delete(credentials: CalendarPushKeychain.Credentials) async throws {
        _ = try await send("DELETE", "v1/device", body: nil, authorization: Self.bearer(credentials), expect: 204)
    }

    /// Deletes what a registration with this id created (or withdraws it
    /// while it still runs); 204 also when the server knows nothing of it.
    func deleteRegistration(_ registrationID: String) async throws {
        _ = try await send("DELETE", "v1/device", body: nil, authorization: "Registration " + registrationID, expect: 204)
    }

    /// `GET /v1/device`: the light contact that keeps the device on the server.
    func status(credentials: CalendarPushKeychain.Credentials) async throws -> Status {
        try decode(StatusBody.self, try await send("GET", "v1/device", body: nil, authorization: Self.bearer(credentials), expect: 200)).status
    }

    private static func bearer(_ credentials: CalendarPushKeychain.Credentials) -> String {
        "Bearer \(credentials.deviceID).\(credentials.secret)"
    }

    func changes(since: Int?, credentials: CalendarPushKeychain.Credentials) async throws -> Changes {
        // Whole seconds only: the nginx path check allows [A-Za-z0-9=&_-] in the query.
        let query = since.map { "since=\(max(0, $0))" }
        return try decode(Changes.self, try await send("GET", "v1/changes", query: query, body: nil, authorization: Self.bearer(credentials),
                                                       expect: 200))
    }

    private func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw Failure(status: 200, code: nil, message: "Der Mitteilungsdienst hat unlesbar geantwortet.") }
    }

    private func send(_ method: String, _ path: String, query: String? = nil, body: Data?, authorization: String?,
                      expect: Int, timeout: TimeInterval = CalendarPushAPI.quickTimeout) async throws -> Data {
        var url = base.appendingPathComponent(path)
        if let query, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            components.percentEncodedQuery = query
            url = components.url ?? url
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let authorization { request.setValue(authorization, forHTTPHeaderField: "Authorization") }
        let data: Data, response: URLResponse
        do { (data, response) = try await Self.session.data(for: request) }
        catch { throw Failure(status: 0, code: "network", message: Self.networkMessage(error)) }
        guard let http = response as? HTTPURLResponse else { throw Failure(status: 0, code: nil, message: "Keine Antwort vom Mitteilungsdienst.") }
        guard http.statusCode == expect else {
            var failure = Self.failure(http.statusCode, data)
            if failure.rateLimited { failure.retryAfter = Self.retryAfter(http.value(forHTTPHeaderField: "Retry-After")) }
            throw failure
        }
        return data
    }

    /// `Retry-After` in seconds (an HTTP date is not sent by noty-push); 60 s
    /// without a usable value, at most 6 h.
    static func retryAfter(_ value: String?) -> TimeInterval {
        guard let value, let seconds = Int(value.trimmingCharacters(in: .whitespaces)), seconds >= 0 else { return 60 }
        return TimeInterval(min(seconds, 6 * 3600))
    }

    private struct ErrorBody: Decodable { let error: String; let message: String }

    /// German sentence for an answer other than the expected one.
    static func failure(_ status: Int, _ data: Data) -> Failure {
        let body = try? JSONDecoder().decode(ErrorBody.self, from: data)
        switch (status, body?.error) {
        case (403, "limit_reached"):
            return Failure(status: status, code: body?.error, message: "Mitteilungsdienst voll: Der Server nimmt keine weiteren Geräte an.")
        case (401, "unauthorized"):
            return Failure(status: status, code: "unauthorized", message: "Der Mitteilungsdienst kennt dieses Gerät nicht mehr.")
        case (401, _):
            return Failure(status: status, code: nil, message: "Der Mitteilungsdienst hat die Anfrage nicht angenommen (HTTP 401).")
        case (409, "registration_in_progress"):
            return Failure(status: status, code: body?.error, message: "Die Anmeldung läuft auf dem Server noch. noty fragt in ein paar Minuten erneut.")
        case (429, _):
            return Failure(status: status, code: "rate_limited",
                           message: body?.message ?? "Der Mitteilungsdienst ist gerade ausgelastet. noty versucht es später erneut.")
        case (_, .some):
            return Failure(status: status, code: body?.error, message: body?.message ?? "Fehler des Mitteilungsdienstes (HTTP \(status)).")
        default:
            return Failure(status: status, code: nil, message: status == 404 || status >= 500
                           ? "Der Mitteilungsdienst ist gerade nicht erreichbar (HTTP \(status))."
                           : "Der Mitteilungsdienst hat die Anfrage abgelehnt (HTTP \(status)).")
        }
    }

    static func networkMessage(_ error: Error) -> String {
        guard let error = error as? URLError else { return "Mitteilungsdienst nicht erreichbar." }
        switch error.code {
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed: return "Keine Internetverbindung."
        case .timedOut: return "Mitteilungsdienst: Zeitüberschreitung."
        case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed: return "Mitteilungsdienst nicht erreichbar."
        case .serverCertificateUntrusted, .serverCertificateHasBadDate, .secureConnectionFailed, .serverCertificateHasUnknownRoot:
            return "Sichere Verbindung zum Mitteilungsdienst fehlgeschlagen."
        default: return "Netzwerkfehler beim Mitteilungsdienst (\(error.code.rawValue))."
        }
    }
}

/// The app side of the push service: registration, updates, sign-off and
/// the bell merge, one operation after the other (`serial`). The server is
/// only told what changed; a device that is not wanted or whose changes
/// are switched off is signed off (its data deleted on the server).
@MainActor
final class CalendarPushClient: ObservableObject {
    static let shared = CalendarPushClient()

    @Published private(set) var state = CalendarPushState.load()
    @Published private(set) var working = false
    /// APNs token of this launch (hex), nil until APNs answered.
    private(set) var token: String?
    private var queue: Task<Void, Never>?
    private var lastFetch: Date?
    /// `status.lastSuccess` of the server's last answer (this launch only):
    /// when the server itself last fetched the timetable successfully.
    private var serverLastSuccess: Date?
    /// The server asked to wait (429 with `Retry-After`): no request before.
    /// Shown in the sheet („bittet um eine Pause bis …“); the server keeps
    /// polling and notifying meanwhile.
    @Published private(set) var blockedUntil: Date?
    /// The server did not answer (network, 5xx) or not within the short
    /// limit before local change notifications: those do not wait for it
    /// again before this moment (`refreshBeforeLocalChanges`, `keepAlive`).
    private var quietUntil: Date?
    /// The last registration's outcome is unknown (no answer): the same
    /// registration id goes again after a few minutes, not after 30.
    private var retryRegistrationSoon = false
    /// Last daily contact attempt (`keepAlive`), this launch.
    private var lastKeepAlive: Date?
    /// A registration whose secret the keychain refused and whose deletion
    /// failed: deleted again at the next sync of this launch.
    private var orphan: CalendarPushKeychain.Credentials?
    /// Why the last `DELETE` did not go through (for the sentence in the sheet).
    private var lastDeleteError: Error?

    // MARK: Live Activity „Schultag“ (docs/LIVE-ACTIVITY-PLAN.md, Schritt 2)

    /// Tokens of ActivityKit for the push service (hex, this launch only).
    /// ÜBERGABESTELLE Schritt 2: noch NICHT an noty-push gemeldet. Der
    /// Server-Schritt ergänzt hier `PUT /v1/device` (oder einen eigenen
    /// Endpunkt) um `liveActivity: {startToken, activities: [{id, day, token}]}`
    /// und sendet an Topic `<Bundle-ID>.push-type.liveactivity` mit dem
    /// content-state aus `SchoolDayContentState` (JSON-Vertrag im Plan).
    struct LiveActivityTokens: Equatable, Sendable {
        /// The update token of one running tile.
        struct Running: Equatable, Sendable {
            /// „YYYY-MM-DD“ (`SchoolDayAttributes.day`).
            var day: String
            var token: String
        }
        /// Push-to-start token (iPadOS 17.2+), starts a tile without noty running.
        var startToken: String?
        /// Activity id → its day and update token.
        var activities: [String: Running] = [:]
    }
    /// Nothing shows these (no `@Published`); Schritt 2 reads them.
    private(set) var liveActivityTokens = LiveActivityTokens()

    func receivedLiveActivityStartToken(_ token: String) {
        liveActivityTokens.startToken = token
        // TODO Schritt 2: an noty-push melden (nur mit Push-Einwilligung, wie das Geräte-Token).
    }

    func receivedLiveActivityToken(_ token: String, activity: String, day: String) {
        liveActivityTokens.activities[activity] = LiveActivityTokens.Running(day: day, token: token)
        // TODO Schritt 2: an noty-push melden; ein ungültiges Token verwirft nur diese Activity.
    }

    func liveActivityEnded(_ activity: String) {
        liveActivityTokens.activities[activity] = nil
        // TODO Schritt 2: dem Server sagen, dass diese Activity vorbei ist.
    }

    var availability: CalendarPush.Availability { CalendarPush.availability }
    var isAvailable: Bool { if case .available = availability { true } else { false } }

    private func change(_ edit: (inout CalendarPushState) -> Void) {
        var next = state
        edit(&next)
        guard next != state else { return }
        state = next
        next.save()
    }

    /// One operation at a time, in call order.
    private func serial(_ work: @escaping @MainActor () async -> Void) async {
        let previous = queue
        let task = Task { @MainActor in
            await previous?.value
            self.working = true
            await work()
            self.working = false
        }
        queue = task
        await task.value
    }

    // MARK: Launch and token

    /// App start: ask APNs for the token when push is wanted, finish a
    /// sign-off that could not reach the server before.
    func launched() {
        guard isAvailable else { return }
        if state.wanted == true { UIApplication.shared.registerForRemoteNotifications() }
        if state.pendingDelete { Task { await self.sync(nil) } }
        Task { await self.keepAlive() }
    }

    func received(token data: Data) {
        token = data.map { String(format: "%02x", $0) }.joined()
        Task { await self.sync(CalendarNotificationHub.shared.model) }
    }

    func failed(_ error: Error) {
        change {
            $0.lastError = "Apple hat kein Mitteilungs-Token geliefert (\(error.localizedDescription))."
            $0.lastFailure = Date()
        }
    }

    // MARK: State for the app

    /// Push is in charge of the change notifications of `connection`: the
    /// app keeps its own findings in the bell only. Any problem (no answer,
    /// Untis access or token paused, other connection) → local notifications.
    /// Before the app announces changes it renews an old contact
    /// (`refreshBeforeLocalChanges`), so the last answer is current; the
    /// server's own activity is its last successful WebUntis fetch
    /// (`status.lastSuccess`): a server that has not fetched for 36 h sends
    /// nothing either.
    func isActive(for connection: UUID?) -> Bool {
        guard isAvailable, let connection, state.wanted == true, state.registered, !state.pendingDelete,
              state.serverConnectionID == connection, state.serverState == "active", let contact = state.lastContact,
              Date().timeIntervalSince(contact) < 36 * 3600 else { return false }
        if let failure = state.lastFailure, failure >= contact { return false }
        if let success = serverLastSuccess, Date().timeIntervalSince(success) >= 36 * 3600 { return false }
        return true
    }

    private var isBlocked: Bool { blockedUntil.map { $0 > Date() } ?? false }
    private var isQuiet: Bool { quietUntil.map { $0 > Date() } ?? false }

    /// Before `recordChanges` decides about local notifications: a contact
    /// older than 30 minutes (or none in this launch, or a failure since) is
    /// renewed with one `GET /v1/changes` – the server's history then is in
    /// the bell (the same changes are not announced twice) and `isActive`
    /// reflects the server now. Only for the connection push is meant for.
    /// Waits at most `limit` seconds (also for a registration still in the
    /// queue): the answer may still arrive later, then only into the bell.
    /// No answer in time, or a network/server error: the next local changes
    /// do not wait for this server again for 10 minutes.
    func refreshBeforeLocalChanges(_ model: CalendarModel, limit: TimeInterval = 5) async {
        guard isAvailable, let base = CalendarPush.baseURL, state.wanted == true, state.registered, !state.pendingDelete,
              let target = state.connectionID, model.connection?.id == target, UIApplication.shared.isProtectedDataAvailable,
              !isBlocked, !isQuiet else { return }
        let failedSince = state.lastFailure.map { failure in state.lastContact.map { failure >= $0 } ?? true } ?? false
        if let contact = state.lastContact, Date().timeIntervalSince(contact) < 30 * 60, serverLastSuccess != nil, !failedSince { return }
        let work = Task { @MainActor in
            await self.serial {
                guard !self.isBlocked, self.state.registered, let credentials = CalendarPushKeychain.read().credentials else { return }
                await self.fetchChanges(api: CalendarPushAPI(base: base), credentials: credentials, model: model, target: target)
            }
        }
        if !(await Self.finishes(work, within: limit)) { quietUntil = Date().addingTimeInterval(10 * 60) }
    }

    /// Waits for `work` at most `seconds`; true when it finished in time.
    /// The work itself goes on either way.
    private static func finishes(_ work: Task<Void, Never>, within seconds: TimeInterval) async -> Bool {
        let gate = FirstResult()
        Task { @MainActor in await work.value; gate.finish(true) }
        Task { @MainActor in try? await Task.sleep(for: .seconds(seconds)); gate.finish(false) }
        return await gate.value()
    }

    /// The first of several answers (`finishes`).
    @MainActor private final class FirstResult {
        private var result: Bool?
        private var continuation: CheckedContinuation<Bool, Never>?
        func value() async -> Bool {
            if let result { return result }
            return await withCheckedContinuation { continuation = $0 }
        }
        func finish(_ value: Bool) {
            guard result == nil else { return }
            result = value
            continuation?.resume(returning: value)
            continuation = nil
        }
    }

    /// At most once a day a light authenticated contact (`GET /v1/device`)
    /// at launch and in a background refresh, whichever area is shown: the
    /// server deletes devices without any contact after 120 days, and an
    /// app used rarely (holidays) must not lose its registration for that.
    func keepAlive() async {
        // A busy queue talks to the server already (and renews the contact when it gets an answer).
        guard isAvailable, CalendarPush.baseURL != nil, state.wanted == true, state.registered, !state.pendingDelete, !working,
              UIApplication.shared.isProtectedDataAvailable, !isBlocked, !isQuiet else { return }
        if let contact = state.lastContact, Date().timeIntervalSince(contact) < 24 * 3600 { return }
        if let attempt = lastKeepAlive, Date().timeIntervalSince(attempt) < 3600 { return }
        await serial { await self.contactIfDue() }
    }

    /// `keepAlive` inside the queue (also from `reconcile`).
    private func contactIfDue() async {
        guard let base = CalendarPush.baseURL, state.wanted == true, state.registered, !state.pendingDelete, !isBlocked, !isQuiet,
              state.lastContact.map({ Date().timeIntervalSince($0) >= 24 * 3600 }) ?? true,
              lastKeepAlive.map({ Date().timeIntervalSince($0) >= 3600 }) ?? true,
              let credentials = CalendarPushKeychain.read().credentials else { return }
        lastKeepAlive = Date()
        do {
            let status = try await CalendarPushAPI(base: base).status(credentials: credentials)
            apply(status)
            change { $0.lastContact = Date(); $0.lastError = nil; $0.lastFailure = nil }
        } catch let failure as CalendarPushAPI.Failure where failure.deviceUnknown {
            try? CalendarPushKeychain.delete()
            change { $0.clearServer() }
        } catch {
            fail(error)
        }
    }

    /// Whether to offer the consent after connecting WebUntis.
    func shouldOffer(for model: CalendarModel) -> Bool {
        isAvailable && state.wanted == nil && model.connection != nil && model.notificationSettings.changes
    }

    func isOn(for model: CalendarModel) -> Bool {
        state.wanted == true && state.connectionID != nil && state.connectionID == model.connection?.id
    }

    var hasConsent: Bool { state.consent == CalendarPush.consentVersion }

    // MARK: User actions

    /// „Zustimmen“ (or „Ein“ with consent given): push for the connection
    /// of `model`. Asks for notification permission if not asked yet.
    func enable(for model: CalendarModel) async {
        guard isAvailable, let connection = model.connection else { return }
        change {
            $0.wanted = true
            if $0.consent != CalendarPush.consentVersion { $0.consent = CalendarPush.consentVersion; $0.consentDate = Date() }
            $0.connectionID = connection.id
            $0.namespace = model.notificationNamespace
            $0.lastRegisterAttempt = nil
            $0.lastError = nil
        }
        if !model.notificationSettings.changes { model.updateNotificationSettings { $0.changes = true } }
        if await model.requestReminderPermission() != .allowed {
            change { $0.lastError = "Mitteilungen für noty sind auf dem iPad nicht erlaubt; ohne Erlaubnis kann der Server nichts zustellen." }
        }
        UIApplication.shared.registerForRemoteNotifications()
        await sync(model, force: true)
    }

    /// „Nicht jetzt“ in the consent: stays local, not asked again.
    func decline() { change { $0.wanted = false } }

    /// „Aus“: signs off and deletes everything on the server.
    func disable() async {
        change { $0.wanted = false }
        await serial { await self.signOff() }
    }

    /// „Erneut versuchen“. While the server asked for a pause (429) nothing
    /// is sent; the sheet says until when.
    func retry(_ model: CalendarModel) async {
        quietUntil = nil
        if let until = blockedUntil, until > Date() {
            if !state.registered { change { $0.lastError = Self.pauseText(until); $0.lastFailure = Date() } }
            return
        }
        await sync(model, force: true)
    }

    /// „Der Mitteilungsdienst bittet um eine Pause bis 14:05.“
    static func pauseText(_ until: Date) -> String {
        "Der Mitteilungsdienst bittet um eine Pause bis \(until.formatted(date: .omitted, time: .shortened))."
    }

    /// A connection of `model` was replaced (`old` → `new`) or removed (`new` nil).
    func connectionChanged(_ model: CalendarModel, from old: UUID?, to new: UUID?) async {
        guard isAvailable, let old, state.connectionID == old else { return }
        if let new {
            // A new Freigabe in the same area: push follows it (PUT with new setup and consent).
            change { $0.connectionID = new; $0.namespace = model.notificationNamespace; $0.lastRegisterAttempt = nil }
            await sync(model, force: true)
        } else {
            // „Trennen“: the server's copy of the Freigabe goes too; asked again on the next connection.
            change { $0.wanted = nil; $0.connectionID = nil; $0.namespace = nil }
            await serial { await self.signOff() }
        }
    }

    /// An area was deleted (Bereiche): when push belongs to its connection,
    /// the server's copy of the Freigabe goes as well (like „Trennen“).
    func areaRemoved(namespace: String) async {
        guard isAvailable, state.namespace == namespace else { return }
        change { $0.wanted = nil; $0.connectionID = nil; $0.namespace = nil }
        await serial { await self.signOff() }
    }

    // MARK: Reconciling

    /// Brings the server in line with the wish of the user (and of `model`,
    /// the shown area) and merges the server's change history into the bell.
    func sync(_ model: CalendarModel?, force: Bool = false) async {
        await serial { await self.reconcile(model, force: force) }
    }

    private func reconcile(_ model: CalendarModel?, force: Bool) async {
        guard case .available(let environment) = availability, let base = CalendarPush.baseURL,
              UIApplication.shared.isProtectedDataAvailable else { return }
        let api = CalendarPushAPI(base: base)
        // The server asked to wait (429): nothing before that moment, also not on „Erneut versuchen“.
        guard !isBlocked else { return }
        if let orphan, await deleteOnServer(orphan, api: api) { self.orphan = nil }
        if state.pendingDelete { guard await signOff() else { return } }
        guard state.wanted == true, state.consent == CalendarPush.consentVersion, let target = state.connectionID else { return }
        let keychain = CalendarPushKeychain.read()
        guard !keychain.locked else { return }
        guard let model, model.loaded, model.connection?.id == target else {
            // Another area is shown: only a new token is passed on, and the daily contact.
            if let credentials = keychain.credentials, state.registered, let token, token != state.sentToken {
                var body = CalendarPushAPI.Update()
                body.deviceToken = token; body.apnsEnvironment = environment
                _ = await put(body, api: api, credentials: credentials, model: nil)
            }
            await contactIfDue()
            return
        }
        // Change notifications off: nothing for the server to do; its data goes.
        guard model.notificationSettings.changes else {
            if state.registered || keychain.credentials != nil || CalendarPushKeychain.readPendingRegistration().id != nil { await signOff() }
            return
        }
        guard let token else { UIApplication.shared.registerForRemoteNotifications(); return }
        let zone = CalendarPush.zone(model.calendar.timeZone)
        guard let credentials = keychain.credentials, state.registered else {
            // A secret without known registration (e.g. app reinstalled: the keychain outlives it)
            // is signed off first, so no stale device keeps being polled on the server. The
            // secret goes only when the server confirmed; otherwise it stays (pendingDelete).
            if keychain.credentials != nil { guard await signOff() else { return } }
            await register(api: api, model: model, target: target, token: token, environment: environment, zone: zone, force: force)
            return
        }
        var body = CalendarPushAPI.Update()
        // APNs refused the token: sent again (a new one, or the same after the next start or on „erneut versuchen“).
        if token != state.sentToken || (state.serverState == "tokenInvalid" && (force || lastFetch == nil)) { body.deviceToken = token }
        if environment != state.sentEnvironment { body.apnsEnvironment = environment }
        if model.notificationSettings != state.sentSettings { body.settings = model.notificationSettings }
        if zone != state.sentTimeZone { body.timeZone = zone }
        let retryAuth = state.serverState == "authFailed" && model.syncError == nil && model.lastSuccess != nil
            && (force || state.lastAuthRetry.map { Date().timeIntervalSince($0) > 6 * 3600 } ?? true)
        if state.serverConnectionID != target || retryAuth {
            // New Freigabe (or the same one that works again in the app): sent with the consent.
            guard let setup = WebUntisKeychain.load(target) else { return }
            body.connectionID = target.uuidString
            body.connectionTimeZone = CalendarPush.connectionZone(model.connection)
            body.setup = CalendarPushAPI.Setup(setup)
            body.consent = CalendarPush.consentVersion
            if retryAuth { change { $0.lastAuthRetry = Date() } }
        }
        if !body.isEmpty {
            switch await put(body, api: api, credentials: credentials, model: model) {
            case .ok: break
            case .unknownDevice:
                await register(api: api, model: model, target: target, token: token, environment: environment, zone: zone, force: true)
                return
            case .failed: return
            }
        }
        if force || lastFetch.map({ Date().timeIntervalSince($0) > 20 }) ?? true {
            await fetchChanges(api: api, credentials: credentials, model: model, target: target)
        }
    }

    private func register(api: CalendarPushAPI, model: CalendarModel, target: UUID, token: String, environment: String, zone: String,
                          force: Bool) async {
        // Needs permission (otherwise nothing could be shown) and the Freigabe of this iPad.
        guard model.reminderPermission == .allowed, let setup = WebUntisKeychain.load(target),
              let bundleID = Bundle.main.bundleIdentifier else { return }
        let pending = CalendarPushKeychain.readPendingRegistration()
        guard !pending.locked else { return }
        // After a failure automatic attempts wait 30 minutes (the server limits registrations per hour);
        // a registration whose answer got lost goes again after 3 minutes, with the same id.
        let pause: TimeInterval = pending.id != nil && retryRegistrationSoon ? 3 * 60 : 30 * 60
        if !force, let last = state.lastRegisterAttempt, Date().timeIntervalSince(last) < pause { return }
        // The id is stored before the request: whatever becomes of the answer, the
        // server's device is found again by it (same device, new secret) or deleted.
        let registrationID = pending.id ?? UUID().uuidString.lowercased()
        if pending.id == nil {
            do { try CalendarPushKeychain.savePendingRegistration(registrationID) } catch {
                change { $0.lastError = "Der Schlüsselbund hat die Anmeldung nicht angenommen."; $0.lastFailure = Date() }
                return
            }
        }
        change { $0.lastRegisterAttempt = Date() }
        let body = CalendarPushAPI.Register(deviceToken: token, apnsEnvironment: environment, bundleID: bundleID,
                                            connectionID: target.uuidString, timeZone: zone, consent: CalendarPush.consentVersion,
                                            connectionTimeZone: CalendarPush.connectionZone(model.connection),
                                            setup: CalendarPushAPI.Setup(setup), settings: model.notificationSettings,
                                            registrationID: registrationID)
        do {
            let result = try await api.register(body)
            retryRegistrationSoon = false
            let credentials = CalendarPushKeychain.Credentials(deviceID: result.deviceID, secret: result.deviceSecret)
            do { try CalendarPushKeychain.save(credentials) } catch {
                // Without the secret the device could never be signed off: delete it right away
                // (or, if that fails, at the next sync of this launch, or by its registration id).
                if await deleteOnServer(credentials, api: api) { try? CalendarPushKeychain.deletePendingRegistration() } else { orphan = credentials }
                change { $0.lastError = "Der Schlüsselbund hat die Anmeldung nicht angenommen; nichts bleibt auf dem Server."; $0.lastFailure = Date() }
                return
            }
            try? CalendarPushKeychain.deletePendingRegistration()
            let settings = model.notificationSettings
            change {
                $0.clearServer()
                $0.registered = true
                $0.serverConnectionID = target
                $0.sentToken = token; $0.sentEnvironment = environment; $0.sentSettings = settings; $0.sentTimeZone = zone
                $0.since = nil
                $0.lastContact = Date(); $0.lastError = nil; $0.lastFailure = nil
                $0.lastRegisterAttempt = nil
            }
            apply(result.status)
            await fetchChanges(api: api, credentials: credentials, model: model, target: target)
        } catch {
            // No answer (timeout, gateway, still running): the server may have the device; the same id again soon.
            retryRegistrationSoon = (error as? CalendarPushAPI.Failure)?.outcomeUnknown ?? true
            fail(error)
        }
    }

    private enum PutResult { case ok, unknownDevice, failed }

    private func put(_ body: CalendarPushAPI.Update, api: CalendarPushAPI, credentials: CalendarPushKeychain.Credentials,
                     model: CalendarModel?) async -> PutResult {
        do {
            let status = try await api.update(body, credentials: credentials)
            change {
                if let token = body.deviceToken { $0.sentToken = token }
                if let environment = body.apnsEnvironment { $0.sentEnvironment = environment }
                if let settings = body.settings { $0.sentSettings = settings }
                if let zone = body.timeZone { $0.sentTimeZone = zone }
                if let connection = body.connectionID.flatMap(UUID.init(uuidString:)) { $0.serverConnectionID = connection; $0.since = nil }
                $0.lastContact = Date(); $0.lastError = nil; $0.lastFailure = nil
            }
            apply(status)
            return .ok
        } catch let failure as CalendarPushAPI.Failure where failure.deviceUnknown {
            // The server deleted the device (30 days paused, or reset): register anew.
            try? CalendarPushKeychain.delete()
            change { $0.clearServer() }
            return .unknownDevice
        } catch {
            fail(error)
            return .failed
        }
    }

    private func fetchChanges(api: CalendarPushAPI, credentials: CalendarPushKeychain.Credentials, model: CalendarModel, target: UUID) async {
        lastFetch = Date()
        do {
            let result = try await api.changes(since: state.since, credentials: credentials)
            apply(result.status)
            // Only entries of the connection the server polls for this area.
            if result.status.connectionID.flatMap(UUID.init(uuidString:)) == target, model.connection?.id == target {
                model.mergePushChanges(result.changes)
            }
            // A little overlap: entries found again are known by their id.
            // An implausible server time (not finite, far future) leaves the cursor where it is.
            let serverTime = result.serverTime
            let next = serverTime.isFinite && serverTime > 0 && serverTime < 1e11 ? max(0, Int(serverTime.rounded(.down)) - 120) : state.since
            change { $0.since = next; $0.lastContact = Date(); $0.lastError = nil; $0.lastFailure = nil }
        } catch let failure as CalendarPushAPI.Failure where failure.deviceUnknown {
            try? CalendarPushKeychain.delete()
            change { $0.clearServer() }
        } catch {
            fail(error)
        }
    }

    private func apply(_ status: CalendarPushAPI.Status) {
        serverLastSuccess = status.lastSuccess.flatMap { $0.isFinite ? Date(timeIntervalSince1970: $0) : nil }
        change {
            $0.serverState = status.state
            $0.serverError = status.lastError
            if let connection = status.connectionID.flatMap(UUID.init(uuidString:)) { $0.serverConnectionID = connection }
        }
    }

    /// Records a failed request. A 429 blocks requests for `Retry-After`
    /// and is no failure of the service: a registered device stays in the
    /// server's charge (`isActive` unchanged), the sheet shows the pause.
    /// No answer or a server error: local change notifications do not wait
    /// for the server for 10 minutes (`refreshBeforeLocalChanges`).
    private func fail(_ error: Error) {
        if let failure = error as? CalendarPushAPI.Failure {
            if failure.rateLimited {
                let until = Date().addingTimeInterval(failure.retryAfter ?? 60)
                blockedUntil = until
                if !state.registered { change { $0.lastError = Self.pauseText(until); $0.lastFailure = Date() } }
                return
            }
            if failure.status == 0 || failure.status >= 500 { quietUntil = Date().addingTimeInterval(10 * 60) }
        } else {
            quietUntil = Date().addingTimeInterval(10 * 60)
        }
        change { $0.lastError = Self.text(error); $0.lastFailure = Date() }
    }

    /// `DELETE /v1/device`: true when nothing is left on the server (204, or
    /// a 401 by which the server confirms it does not know the device). A
    /// 429, another 401 or a network error leave it there.
    private func deleteOnServer(_ credentials: CalendarPushKeychain.Credentials, api: CalendarPushAPI) async -> Bool {
        do {
            try await api.delete(credentials: credentials)
            return true
        } catch let failure as CalendarPushAPI.Failure where failure.deviceUnknown {
            return true
        } catch {
            if let failure = error as? CalendarPushAPI.Failure, failure.rateLimited {
                blockedUntil = Date().addingTimeInterval(failure.retryAfter ?? 60)
            }
            lastDeleteError = error
            return false
        }
    }

    /// `DELETE /v1/device` by registration id: true only after 204 (the
    /// server deleted or withdrew it, or never had it). Anything else leaves
    /// the id for the next attempt.
    private func deleteRegistrationOnServer(_ registrationID: String, api: CalendarPushAPI) async -> Bool {
        do {
            try await api.deleteRegistration(registrationID)
            return true
        } catch {
            if let failure = error as? CalendarPushAPI.Failure, failure.rateLimited {
                blockedUntil = Date().addingTimeInterval(failure.retryAfter ?? 60)
            }
            lastDeleteError = error
            return false
        }
    }

    /// `DELETE /v1/device`; the secret goes only after 204 (or a confirmed
    /// 401: already gone), a registration whose answer never came only
    /// after 204 to its registration id. Offline, rate-limited or any other
    /// answer: remembered and repeated at the next start/sync. True when
    /// nothing is left on the server.
    @discardableResult
    private func signOff() async -> Bool {
        let keychain = CalendarPushKeychain.read()
        let pending = CalendarPushKeychain.readPendingRegistration()
        guard !keychain.locked, !pending.locked else { change { $0.pendingDelete = true }; return false }
        guard keychain.credentials != nil || pending.id != nil else {
            change { $0.pendingDelete = false; $0.clearServer() }
            return true
        }
        change { $0.pendingDelete = true }
        guard let base = CalendarPush.baseURL, !isBlocked else { return false }
        let api = CalendarPushAPI(base: base)
        func notYet() -> Bool {
            let reason = lastDeleteError.map(Self.text) ?? "keine Antwort"
            change {
                $0.lastError = "Abmeldung beim Mitteilungsdienst noch nicht möglich (\(reason)). noty wiederholt sie beim nächsten Start."
                $0.lastFailure = Date()
            }
            return false
        }
        if let credentials = keychain.credentials {
            guard await deleteOnServer(credentials, api: api) else { return notYet() }
            try? CalendarPushKeychain.delete()
        }
        if let registrationID = pending.id {
            guard await deleteRegistrationOnServer(registrationID, api: api) else { return notYet() }
            try? CalendarPushKeychain.deletePendingRegistration()
            retryRegistrationSoon = false
        }
        change {
            $0.pendingDelete = false
            $0.clearServer()
            $0.lastError = nil; $0.lastFailure = nil; $0.lastContact = nil
        }
        return true
    }

    private static func text(_ error: Error) -> String {
        (error as? CalendarPushAPI.Failure)?.message ?? error.localizedDescription
    }

    // MARK: Routing of taps

    /// Area namespace of a push payload's connection (nil: unknown, e.g.
    /// the connection was replaced since). Readable outside the main actor.
    nonisolated static func namespace(forConnection raw: String?) -> String? {
        guard let raw, let id = UUID(uuidString: raw) else { return nil }
        let state = CalendarPushState.load()
        return state.connectionID == id ? state.namespace : nil
    }
}
