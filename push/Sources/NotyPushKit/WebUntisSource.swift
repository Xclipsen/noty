import Foundation
import NotebookCore

/// Loads one complete, validated timetable range. Request bodies and
/// parsing come from Core (`WebUntis`), exactly as in the app.
public protocol TimetableSource: Sendable {
    func load(setup: WebUntisSetup, connection: UUID, timeZone: TimeZone, start: CivilDate, end: CivilDate,
              at time: Date) async throws -> CalendarTimetableFetch
}

public struct WebUntisCurlSource: TimetableSource {
    let transport: HTTPTransport
    public init(transport: HTTPTransport) { self.transport = transport }

    public func load(setup: WebUntisSetup, connection: UUID, timeZone: TimeZone, start: CivilDate, end: CivilDate,
                     at time: Date) async throws -> CalendarTimetableFetch {
        let userBody = try WebUntis.userDataBody(setup, at: Date(), hmacSHA1: Secrets.hmacSHA1)
        let user = try WebUntis.parseUserData(try await post(setup, "getUserData2017", userBody))
        let body = try WebUntis.timetableBody(setup, user: user, start: start, end: end, at: Date(), hmacSHA1: Secrets.hmacSHA1)
        let parsed = try WebUntis.parseTimetableWithHomework(try await post(setup, "getTimetable2017", body), user: user,
                                                             connection: connection, timeZone: timeZone, start: start, end: end)
        return CalendarTimetableFetch(connection: connection, start: start, end: end, fetchedAt: time,
                                      lessons: parsed.lessons, homework: parsed.homework)
    }

    private func post(_ setup: WebUntisSetup, _ method: String, _ body: Data) async throws -> Data {
        guard let url = WebUntis.endpoint(setup, method: method)?.absoluteString else { throw WebUntisError.invalidSetup("Server") }
        let response = try await transport.send(HTTPRequest(
            url: url, headers: ["Content-Type: application/json", "Accept: application/json", "User-Agent: noty-push"],
            body: body, maxTime: 40, maxResponseBytes: WebUntis.maximumResponseBytes))
        guard response.status == 200 else { throw WebUntisError.http(response.status) }
        return response.body
    }
}

/// How a failed poll is treated.
public enum PollFailure: Equatable, Sendable {
    /// User/key/school rejected: counts towards „Untis-Zugang prüfen“.
    case authentication
    /// Anything else (network, HTTP, unreadable answer): retried with backoff.
    case transient(String)

    public static func classify(_ error: Error) -> PollFailure {
        if let error = error as? WebUntisError {
            switch WebUntis.problem(error) {
            case .authentication, .schoolUnknown: return .authentication
            case .serverUnreachable: return .transient("WebUntis nicht erreichbar")
            case .unreadable: return .transient("WebUntis-Antwort unlesbar")
            case .other: return .transient("WebUntis-Fehler")
            }
        }
        if let error = error as? TransportError { return .transient("Netzwerk: \(error)") }
        if error is CalendarStoreError { return .transient("Antwort nicht übernehmbar") }
        return .transient("Fehler")
    }

    /// Plain German text for the app (never WebUntis' own message text).
    public var message: String {
        switch self {
        case .authentication: return WebUntisProblem.authentication.message
        case .transient(let text): return text
        }
    }
}
