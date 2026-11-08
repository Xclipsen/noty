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
    static let channel = "calendar"

    enum Availability: Equatable, Sendable {
        /// `environment`: „sandbox“ or „production“ as the server expects it.
        case available(environment: String)
        case unavailable(String)
        /// Another app of the family (noty, noty dev, noty AI): no push at all.
        case otherChannel
    }

    static let availability: Availability = {
        let channel = Bundle.main.object(forInfoDictionaryKey: "NotyChannel") as? String
        guard channel == Self.channel else { return .otherChannel }
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

    /// Time zone as the server accepts it (region identifiers or UTC).
    static func zone(_ zone: TimeZone) -> String {
        let id = zone.identifier
        return id.count <= 64 && (id.contains("/") || id == "UTC") ? id : "Europe/Berlin"
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

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    static func save(_ credentials: Credentials) throws {
        let data = try JSONEncoder().encode(credentials)
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw WebUntisKeychain.Failure.status(status) }
    }

    /// `locked`: not readable yet (device not unlocked since its start).
    static func read() -> (credentials: Credentials?, locked: Bool) {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data,
              let value = try? JSONDecoder().decode(Credentials.self, from: data) else { return (nil, status == errSecInteractionNotAllowed) }
        return (value, false)
    }

    static func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw WebUntisKeychain.Failure.status(status) }
    }
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
        var errorDescription: String? { message }
    }

    struct Status: Decodable, Sendable {
        let deviceID: String
        let state: String
        let connectionID: String?
        let lastError: String?
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
        let setup: Setup
        let settings: CalendarNotificationSettings
    }
    struct Update: Encodable, Sendable {
        var deviceToken: String?, apnsEnvironment: String?, bundleID: String?, connectionID: String?, timeZone: String?, consent: String?
        var setup: Setup?
        var settings: CalendarNotificationSettings?
        var isEmpty: Bool {
            deviceToken == nil && apnsEnvironment == nil && bundleID == nil && connectionID == nil && timeZone == nil && setup == nil
                && settings == nil
        }
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        // A registration waits for the server's test fetch from WebUntis.
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 90
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    func register(_ body: Register) async throws -> Registered {
        try decode(Registered.self, try await send("POST", "v1/register", body: try JSONEncoder().encode(body), credentials: nil, expect: 201))
    }

    func update(_ body: Update, credentials: CalendarPushKeychain.Credentials) async throws -> Status {
        try decode(StatusBody.self, try await send("PUT", "v1/device", body: try JSONEncoder().encode(body), credentials: credentials, expect: 200))
            .status
    }

    func delete(credentials: CalendarPushKeychain.Credentials) async throws {
        _ = try await send("DELETE", "v1/device", body: nil, credentials: credentials, expect: 204)
    }

    func changes(since: Int?, credentials: CalendarPushKeychain.Credentials) async throws -> Changes {
        // Whole seconds only: the nginx path check allows [A-Za-z0-9=&_-] in the query.
        let query = since.map { "since=\(max(0, $0))" }
        return try decode(Changes.self, try await send("GET", "v1/changes", query: query, body: nil, credentials: credentials, expect: 200))
    }

    private func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw Failure(status: 200, code: nil, message: "Der Mitteilungsdienst hat unlesbar geantwortet.") }
    }

    private func send(_ method: String, _ path: String, query: String? = nil, body: Data?, credentials: CalendarPushKeychain.Credentials?,
                      expect: Int) async throws -> Data {
        var url = base.appendingPathComponent(path)
        if let query, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            components.percentEncodedQuery = query
            url = components.url ?? url
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let credentials { request.setValue("Bearer \(credentials.deviceID).\(credentials.secret)", forHTTPHeaderField: "Authorization") }
        let data: Data, response: URLResponse
        do { (data, response) = try await Self.session.data(for: request) }
        catch { throw Failure(status: 0, code: "network", message: Self.networkMessage(error)) }
        guard let http = response as? HTTPURLResponse else { throw Failure(status: 0, code: nil, message: "Keine Antwort vom Mitteilungsdienst.") }
        guard http.statusCode == expect else { throw Self.failure(http.statusCode, data) }
        return data
    }

    private struct ErrorBody: Decodable { let error: String; let message: String }

    /// German sentence for an answer other than the expected one.
    static func failure(_ status: Int, _ data: Data) -> Failure {
        let body = try? JSONDecoder().decode(ErrorBody.self, from: data)
        switch (status, body?.error) {
        case (403, "limit_reached"):
            return Failure(status: status, code: body?.error, message: "Mitteilungsdienst voll: Der Server nimmt keine weiteren Geräte an.")
        case (401, _):
            return Failure(status: status, code: "unauthorized", message: "Der Mitteilungsdienst kennt dieses Gerät nicht mehr.")
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

    // MARK: Live Activity „Schultag“ (docs/LIVE-ACTIVITY-PLAN.md, Schritt 2)

    /// Tokens of ActivityKit for the push service (hex, this launch only).
    /// ÜBERGABESTELLE Schritt 2: noch NICHT an noty-push gemeldet. Der
    /// Server-Schritt ergänzt hier `PUT /v1/device` (oder einen eigenen
    /// Endpunkt) um `liveActivity: {startToken, activities: [{id, day, token}]}`
    /// und sendet an Topic `<Bundle-ID>.push-type.liveactivity` mit dem
    /// content-state aus `SchoolDayContentState` (JSON-Vertrag im Plan).
    struct LiveActivityTokens: Equatable, Sendable {
        /// Push-to-start token (iPadOS 17.2+), starts a tile without noty running.
        var startToken: String?
        /// Activity id → (day „YYYY-MM-DD“, update token) of running tiles.
        var activities: [String: (day: String, token: String)] = [:]
        static func == (a: Self, b: Self) -> Bool {
            a.startToken == b.startToken && a.activities.mapValues { "\($0.day)|\($0.token)" } == b.activities.mapValues { "\($0.day)|\($0.token)" }
        }
    }
    @Published private(set) var liveActivityTokens = LiveActivityTokens()

    func receivedLiveActivityStartToken(_ token: String) {
        liveActivityTokens.startToken = token
        // TODO Schritt 2: an noty-push melden (nur mit Push-Einwilligung, wie das Geräte-Token).
    }

    func receivedLiveActivityToken(_ token: String, activity: String, day: String) {
        liveActivityTokens.activities[activity] = (day, token)
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
    func isActive(for connection: UUID?) -> Bool {
        guard isAvailable, let connection, state.wanted == true, state.registered, !state.pendingDelete,
              state.serverConnectionID == connection, state.serverState == "active", let contact = state.lastContact,
              Date().timeIntervalSince(contact) < 36 * 3600 else { return false }
        if let failure = state.lastFailure, failure >= contact { return false }
        return true
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

    /// „Erneut versuchen“.
    func retry(_ model: CalendarModel) async { await sync(model, force: true) }

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
        if state.pendingDelete { guard await signOff() else { return } }
        guard state.wanted == true, state.consent == CalendarPush.consentVersion, let target = state.connectionID else { return }
        let keychain = CalendarPushKeychain.read()
        guard !keychain.locked else { return }
        guard let model, model.loaded, model.connection?.id == target else {
            // Another area is shown: only a new token is passed on.
            if let credentials = keychain.credentials, state.registered, let token, token != state.sentToken {
                var body = CalendarPushAPI.Update()
                body.deviceToken = token; body.apnsEnvironment = environment
                _ = await put(body, api: api, credentials: credentials, model: nil)
            }
            return
        }
        // Change notifications off: nothing for the server to do; its data goes.
        guard model.notificationSettings.changes else {
            if state.registered || keychain.credentials != nil { await signOff() }
            return
        }
        guard let token else { UIApplication.shared.registerForRemoteNotifications(); return }
        let zone = CalendarPush.zone(model.calendar.timeZone)
        guard let credentials = keychain.credentials, state.registered else {
            // A secret without known registration (e.g. app reinstalled: the keychain outlives it)
            // is signed off first, so no stale device keeps being polled on the server.
            if let stale = keychain.credentials {
                try? await api.delete(credentials: stale)
                try? CalendarPushKeychain.delete()
            }
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
        // After a failure automatic attempts wait 30 minutes (the server limits registrations per hour).
        if !force, let last = state.lastRegisterAttempt, Date().timeIntervalSince(last) < 30 * 60 { return }
        change { $0.lastRegisterAttempt = Date() }
        let body = CalendarPushAPI.Register(deviceToken: token, apnsEnvironment: environment, bundleID: bundleID,
                                            connectionID: target.uuidString, timeZone: zone, consent: CalendarPush.consentVersion,
                                            setup: CalendarPushAPI.Setup(setup), settings: model.notificationSettings)
        do {
            let result = try await api.register(body)
            let credentials = CalendarPushKeychain.Credentials(deviceID: result.deviceID, secret: result.deviceSecret)
            do { try CalendarPushKeychain.save(credentials) } catch {
                // Without the secret the device could never be signed off: delete it right away.
                try? await api.delete(credentials: credentials)
                change { $0.lastError = "Der Schlüsselbund hat die Anmeldung nicht angenommen; nichts bleibt auf dem Server."; $0.lastFailure = Date() }
                return
            }
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
            change { $0.lastError = Self.text(error); $0.lastFailure = Date() }
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
        } catch let failure as CalendarPushAPI.Failure where failure.status == 401 {
            // The server deleted the device (30 days paused, or reset): register anew.
            try? CalendarPushKeychain.delete()
            change { $0.clearServer() }
            return .unknownDevice
        } catch {
            change { $0.lastError = Self.text(error); $0.lastFailure = Date() }
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
            let next = max(0, Int(result.serverTime.rounded(.down)) - 120)
            change { $0.since = next; $0.lastContact = Date(); $0.lastError = nil; $0.lastFailure = nil }
        } catch let failure as CalendarPushAPI.Failure where failure.status == 401 {
            try? CalendarPushKeychain.delete()
            change { $0.clearServer() }
        } catch {
            change { $0.lastError = Self.text(error); $0.lastFailure = Date() }
        }
    }

    private func apply(_ status: CalendarPushAPI.Status) {
        change {
            $0.serverState = status.state
            $0.serverError = status.lastError
            if let connection = status.connectionID.flatMap(UUID.init(uuidString:)) { $0.serverConnectionID = connection }
        }
    }

    /// `DELETE /v1/device`; the secret goes only after 204 (or 401: already
    /// gone). Offline: remembered and repeated at the next start. True when
    /// nothing is left on the server.
    @discardableResult
    private func signOff() async -> Bool {
        let keychain = CalendarPushKeychain.read()
        guard !keychain.locked else { change { $0.pendingDelete = true }; return false }
        guard let credentials = keychain.credentials else {
            change { $0.pendingDelete = false; $0.clearServer() }
            return true
        }
        change { $0.pendingDelete = true }
        guard let base = CalendarPush.baseURL else { return false }
        do {
            try await CalendarPushAPI(base: base).delete(credentials: credentials)
        } catch let failure as CalendarPushAPI.Failure where failure.status == 401 {
            // Unknown to the server: nothing left there.
        } catch {
            change {
                $0.lastError = "Abmeldung beim Mitteilungsdienst noch nicht möglich (\(Self.text(error))). noty wiederholt sie beim nächsten Start."
                $0.lastFailure = Date()
            }
            return false
        }
        try? CalendarPushKeychain.delete()
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
