import Foundation
import CryptoKit
import Security
import NotebookCore

/// Access data of the Untis Mobile „Freigabe“ in the device keychain only:
/// never in UserDefaults, files, logs or backups. One item per connection
/// (`CalendarConnectionRecord.id`), readable after the first unlock, bound
/// to this device (`…ThisDeviceOnly`: not in iCloud keychain or device backups).
enum WebUntisKeychain {
    private static let service = "noty.calendar.webuntis"

    enum Failure: Error, LocalizedError {
        case status(OSStatus)
        var errorDescription: String? {
            if case .status(let code) = self { return "Der Schlüsselbund hat die Zugangsdaten nicht angenommen (\(code))." }
            return nil
        }
    }

    private static func query(_ id: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: id.uuidString]
    }

    static func save(_ setup: WebUntisSetup, id: UUID) throws {
        let data = try JSONEncoder().encode(setup)
        SecItemDelete(query(id) as CFDictionary)
        var item = query(id)
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw Failure.status(status) }
    }

    /// Nil when missing or unusable (re-validated after reading).
    static func load(_ id: UUID) -> WebUntisSetup? { read(id).setup }

    /// As `load`, and whether the keychain was not readable yet (device
    /// locked since its start: `errSecInteractionNotAllowed`). The
    /// background refresh then does nothing instead of reporting the
    /// access data as missing. The item's protection class is unchanged
    /// (`AfterFirstUnlockThisDeviceOnly` already allows background reads
    /// after the first unlock).
    static func read(_ id: UUID) -> (setup: WebUntisSetup?, locked: Bool) {
        var request = query(id)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data,
              let stored = try? JSONDecoder().decode(WebUntisSetup.self, from: data) else { return (nil, status == errSecInteractionNotAllowed) }
        return (try? WebUntisSetup(server: stored.server, school: stored.school, user: stored.user, key: stored.key,
                                   schoolNumber: stored.schoolNumber), false)
    }

    static func delete(_ id: UUID) throws {
        let status = SecItemDelete(query(id) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure.status(status) }
    }
}

/// One WebUntis session (JSON-RPC over https, cookies only in memory). No
/// request content, credential or answer is logged. Call `finish()` after use.
final class WebUntisClient: Sendable {
    let setup: WebUntisSetup
    private let session: URLSession

    init(setup: WebUntisSetup) {
        self.setup = setup
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 60
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = true
        configuration.httpCookieAcceptPolicy = .always
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration)
    }

    func finish() { session.finishTasksAndInvalidate() }

    static func hmacSHA1(_ key: Data, _ message: Data) -> Data {
        Data(HMAC<Insecure.SHA1>.authenticationCode(for: message, using: SymmetricKey(data: key)))
    }

    /// Logged-in element and master data (subjects, rooms, holidays).
    func user() async throws -> WebUntisUser {
        let body = try WebUntis.userDataBody(setup, at: Date(), hmacSHA1: Self.hmacSHA1)
        return try WebUntis.parseUserData(try await post("getUserData2017", body: body))
    }

    /// Complete, validated lessons of [start, end), with the homework
    /// delivered with their periods (Stufe C; before 08.11.2026 the app
    /// dropped it here, so no homework ever reached the offline cache).
    func timetable(user: WebUntisUser, start: CivilDate, end: CivilDate, connection: UUID,
                   timeZone: TimeZone) async throws -> (lessons: [CalendarLesson], homework: [CalendarHomework]) {
        let body = try WebUntis.timetableBody(setup, user: user, start: start, end: end, at: Date(), hmacSHA1: Self.hmacSHA1)
        let data = try await post("getTimetable2017", body: body)
        return try WebUntis.parseTimetableWithHomework(data, user: user, connection: connection, timeZone: timeZone, start: start, end: end)
    }

    private func post(_ method: String, body: Data) async throws -> Data {
        guard let url = WebUntis.endpoint(setup, method: method) else { throw WebUntisError.invalidSetup("Server") }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw WebUntisError.invalidResponse("keine HTTP-Antwort") }
        guard http.statusCode == 200 else { throw WebUntisError.http(http.statusCode) }
        guard data.count <= WebUntis.maximumResponseBytes else { throw WebUntisError.tooLarge }
        return data
    }

    /// Short German text for the quiet status line.
    static func message(_ error: Error) -> String {
        if let error = error as? URLError {
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed: return "Keine Internetverbindung"
            case .timedOut: return "Zeitüberschreitung"
            case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed: return "Server nicht erreichbar"
            case .serverCertificateUntrusted, .serverCertificateHasBadDate, .secureConnectionFailed: return "Sichere Verbindung fehlgeschlagen"
            default: return "Netzwerkfehler (\(error.code.rawValue))"
            }
        }
        if let error = error as? WebUntisError {
            switch WebUntis.problem(error) {
            case .schoolUnknown: return "Schule unbekannt – bitte neu verbinden"
            case .authentication: return "Anmeldung abgelehnt (Benutzer/Schlüssel oder Uhrzeit des iPads) – bitte neu verbinden"
            case .serverUnreachable, .unreadable: return error.localizedDescription
            case .other(let text): return text
            }
        }
        return error.localizedDescription
    }

    /// Full plain-German sentence for „Verbindung testen“/„Verbinden“:
    /// server unreachable, school unknown, user/key rejected or answer
    /// unreadable (shape only). Never contains the key.
    static func testMessage(_ error: Error) -> String {
        if let error = error as? URLError {
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
                return "Keine Internetverbindung. Bitte WLAN prüfen und erneut testen."
            case .cannotFindHost, .dnsLookupFailed:
                return WebUntisProblem.serverUnreachable("Diese Adresse gibt es nicht.").message
            case .cannotConnectToHost:
                return WebUntisProblem.serverUnreachable("Der Server nimmt keine Verbindung an.").message
            case .timedOut:
                return WebUntisProblem.serverUnreachable("Zeitüberschreitung.").message
            case .serverCertificateUntrusted, .serverCertificateHasBadDate, .secureConnectionFailed, .serverCertificateHasUnknownRoot:
                return WebUntisProblem.serverUnreachable("Sichere Verbindung fehlgeschlagen.").message
            default:
                return "Netzwerkfehler (\(error.code.rawValue)). Bitte erneut testen."
            }
        }
        if let error = error as? WebUntisError { return WebUntis.problem(error).message }
        return error.localizedDescription
    }
}
