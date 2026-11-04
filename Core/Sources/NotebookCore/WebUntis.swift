import Foundation

// Kalender Stufe B1: WebUntis over the Untis Mobile „Freigabe“ (WebUntis →
// Profil → Freigaben: QR code with user and key). This is an UNOFFICIAL
// access path, approved by the user on 04.11.2026 because the school offers
// neither public timetables nor iCal. Protocol as verified once on that day:
// JSON-RPC 2.0 to `/WebUntis/jsonrpc_intern.do?m=<method>&school=<school>&v=i2.2`
// with `auth {clientTime, user, otp}` (TOTP, RFC 6238, SHA-1, 30 s, 6 digits).
// Status values other than „REGULAR“ are taken from community documentation
// and are UNVERIFIED; unknown values are kept and shown neutrally.
// Network, keychain and HMAC live in the app; this file is pure parsing.

public enum WebUntisError: Error, LocalizedError, Equatable {
    case invalidSetup(String)
    case invalidResponse(String)
    case server(code: Int?, message: String)
    case http(Int)
    case tooLarge

    public var errorDescription: String? {
        switch self {
        case .invalidSetup(let reason): "Freigabe ungültig: \(reason)"
        case .invalidResponse(let reason): "WebUntis-Antwort unvollständig oder unbekannt (\(reason)). Der bisherige Stand bleibt erhalten."
        case .server(let code, let message):
            code.map { "WebUntis meldet einen Fehler (\($0)): \(message)" } ?? "WebUntis meldet einen Fehler: \(message)"
        case .http(let status): "WebUntis ist nicht erreichbar (HTTP \(status)). Der bisherige Stand bleibt erhalten."
        case .tooLarge: "Die WebUntis-Antwort ist zu groß. Der bisherige Stand bleibt erhalten."
        }
    }
}

/// Access data of a Untis Mobile „Freigabe“. Secret: user and key go only to
/// the keychain, never into files, logs or backups.
public struct WebUntisSetup: Equatable, Sendable, Codable {
    /// Host (optionally with port), e.g. „example.webuntis.com“.
    public var server: String
    /// School login name as in the QR code (sent unchanged).
    public var school: String
    public var user: String
    /// Base32 secret, normalized (upper case, no spaces/padding).
    public var key: String
    public var schoolNumber: String?

    public init(server: String, school: String, user: String, key: String, schoolNumber: String? = nil) throws {
        guard let host = WebUntis.normalizedServer(server) else { throw WebUntisError.invalidSetup("Server") }
        let school = school.trimmingCharacters(in: .whitespacesAndNewlines)
        let user = user.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...200).contains(school.count), !school.contains(where: { $0.isNewline }) else { throw WebUntisError.invalidSetup("Schule") }
        guard (1...200).contains(user.count), !user.contains(where: { $0.isNewline }) else { throw WebUntisError.invalidSetup("Benutzer") }
        let key = WebUntis.normalizedKey(key)
        guard let secret = TOTP.base32Decode(key), secret.count >= 5 else { throw WebUntisError.invalidSetup("Schlüssel") }
        self.server = host; self.school = school; self.user = user; self.key = key
        self.schoolNumber = schoolNumber?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
    }

    public var secret: Data { TOTP.base32Decode(key) ?? Data() }
}

/// Element of the logged-in user (student) and the master data needed to
/// name the periods.
public struct WebUntisUser: Sendable, Equatable {
    public var elementType: String
    public var elementID: Int
    public var displayName: String?
    public var subjects: [Int: (name: String?, longName: String?)] = [:]
    public var rooms: [Int: String] = [:]
    public var teachers: [Int: String] = [:]
    public var classes: [Int: String] = [:]
    public var holidays: [CalendarHoliday] = []

    public static func == (a: WebUntisUser, b: WebUntisUser) -> Bool {
        a.elementType == b.elementType && a.elementID == b.elementID && a.displayName == b.displayName
            && a.rooms == b.rooms && a.teachers == b.teachers && a.classes == b.classes && a.holidays == b.holidays
            && a.subjects.mapValues { [$0.name, $0.longName] } == b.subjects.mapValues { [$0.name, $0.longName] }
    }
}

public enum WebUntis {
    public static let maximumResponseBytes = 16_000_000
    public static let maximumPeriods = 10_000

    // MARK: Setup

    /// Host[:port] of a server entry: accepts „host“, „https://host“ and
    /// „https://host/WebUntis/…“. Only https is used.
    public static func normalizedServer(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = text.range(of: "://") {
            guard text[..<range.lowerBound].lowercased() == "https" else { return nil }
            text = String(text[range.upperBound...])
        }
        if let slash = text.firstIndex(of: "/") { text = String(text[..<slash]) }
        text = text.lowercased()
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count), let host = parts.first, (3...253).contains(host.count),
              host.contains("."), !host.hasPrefix("."), !host.hasSuffix("."), !host.contains(".."),
              host.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == ".") }) else { return nil }
        if parts.count == 2 {
            guard let port = Int(parts[1]), (1...65535).contains(port), String(port) == parts[1] else { return nil }
        }
        return text
    }

    /// Non-secret identity of an account for anchoring lesson notes: SHA-256
    /// over server, school and user (no key). The same „Freigabe“ connected
    /// again gives the same identity.
    public static func sourceIdentity(_ setup: WebUntisSetup) -> String {
        "webuntis:" + SHA256.hexDigest(Data("\(setup.server)\n\(setup.school.lowercased())\n\(setup.user.lowercased())".utf8))
    }

    public static func normalizedKey(_ raw: String) -> String {
        raw.uppercased().filter { !$0.isWhitespace && $0 != "=" && $0 != "-" }
    }

    /// Content of the „Freigabe“ QR code:
    /// `untis://setschool?url=…&school=…&user=…&key=…&schoolNumber=…`
    /// (community documented; parsed tolerantly: key case, order, extra items).
    public static func parseSetup(_ text: String) throws -> WebUntisSetup {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix("untis://"), let components = URLComponents(string: trimmed) else {
            throw WebUntisError.invalidSetup("Kein Untis-Mobile-QR-Code")
        }
        var values: [String: String] = [:]
        for item in components.queryItems ?? [] {
            let name = item.name.lowercased()
            if values[name] == nil, let value = item.value { values[name] = value }
        }
        guard let server = values["url"] ?? values["server"] else { throw WebUntisError.invalidSetup("Server fehlt") }
        guard let school = values["school"] else { throw WebUntisError.invalidSetup("Schule fehlt") }
        guard let user = values["user"] else { throw WebUntisError.invalidSetup("Benutzer fehlt") }
        guard let key = values["key"] else { throw WebUntisError.invalidSetup("Schlüssel fehlt") }
        return try WebUntisSetup(server: server, school: school, user: user, key: key, schoolNumber: values["schoolnumber"])
    }

    // MARK: Requests

    public static func endpoint(_ setup: WebUntisSetup, method: String) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        let parts = setup.server.split(separator: ":")
        components.host = parts.first.map(String.init)
        if parts.count == 2 { components.port = Int(parts[1]) }
        components.path = "/WebUntis/jsonrpc_intern.do"
        // Query items as in the QR code; URLComponents encodes what is needed.
        components.queryItems = [URLQueryItem(name: "m", value: method), URLQueryItem(name: "school", value: setup.school),
                                 URLQueryItem(name: "v", value: "i2.2")]
        return components.url
    }

    struct Auth: Encodable { let clientTime: Int64; let user: String; let otp: Int }
    struct UserDataParams: Encodable {
        let elementId = 0, deviceOs = "AND", deviceOsVersion = ""
        let auth: Auth
    }
    struct TimetableParams: Encodable {
        let id: Int, type: String, startDate: String, endDate: String
        let masterDataTimestamp = 0, timetableTimestamp = 0
        let timetableTimestamps: [Int] = []
        let auth: Auth
    }
    struct Request<P: Encodable>: Encodable {
        let id: String, method: String, params: [P]
        let jsonrpc = "2.0"
    }

    static func auth(_ setup: WebUntisSetup, at time: Date, hmac: (Data, Data) -> Data) -> Auth {
        Auth(clientTime: Int64((time.timeIntervalSince1970 * 1000).rounded()), user: setup.user,
             otp: Int(TOTP.code(secret: setup.secret, at: time, hmacSHA1: hmac)) ?? 0)
    }

    public static func userDataBody(_ setup: WebUntisSetup, at time: Date, requestID: String = UUID().uuidString,
                                    hmacSHA1: (Data, Data) -> Data) throws -> Data {
        try JSONEncoder().encode(Request(id: requestID, method: "getUserData2017",
                                         params: [UserDataParams(auth: auth(setup, at: time, hmac: hmacSHA1))]))
    }

    /// `end` exclusive here; WebUntis gets the inclusive last day.
    public static func timetableBody(_ setup: WebUntisSetup, user: WebUntisUser, start: CivilDate, end: CivilDate,
                                     at time: Date, requestID: String = UUID().uuidString,
                                     hmacSHA1: (Data, Data) -> Data) throws -> Data {
        try JSONEncoder().encode(Request(id: requestID, method: "getTimetable2017", params: [TimetableParams(
            id: user.elementID, type: user.elementType, startDate: start.description, endDate: end.adding(days: -1).description,
            auth: auth(setup, at: time, hmac: hmacSHA1))]))
    }

    // MARK: Responses

    private struct RPCError: Decodable { let code: Int?; let message: String? }
    private struct Envelope<R: Decodable>: Decodable { let result: R?; let error: RPCError? }
    private struct Ignored: Decodable { init(from decoder: Decoder) throws {} }

    private struct Named: Decodable {
        let id: Int; let name: String?; let longName: String?
        enum CodingKeys: String, CodingKey { case id, name, longName, firstName, lastName }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(Int.self, forKey: .id)
            let first = try? c.decodeIfPresent(String.self, forKey: .firstName)
            let last = try? c.decodeIfPresent(String.self, forKey: .lastName)
            name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? last ?? nil
            longName = (try? c.decodeIfPresent(String.self, forKey: .longName))
                ?? [first, last].compactMap { $0 }.joined(separator: " ").nilIfBlank
        }
    }
    private struct Holiday: Decodable {
        let id: Int?; let name: String?; let longName: String?; let startDate: String; let endDate: String
    }
    private struct Master: Decodable {
        let subjects: [Named]?; let rooms: [Named]?; let teachers: [Named]?; let klassen: [Named]?; let holidays: [Holiday]?
    }
    private struct UserData: Decodable { let elemType: String; let elemId: Int; let displayName: String? }
    private struct UserResult: Decodable { let userData: UserData; let masterData: Master }

    private static func decode<R: Decodable>(_ type: R.Type, _ data: Data) throws -> R {
        guard data.count <= maximumResponseBytes else { throw WebUntisError.tooLarge }
        let envelope: Envelope<R>
        do { envelope = try JSONDecoder().decode(Envelope<R>.self, from: data) }
        catch { throw WebUntisError.invalidResponse("Format") }
        if let error = envelope.error {
            throw WebUntisError.server(code: error.code, message: error.message?.nilIfBlank ?? "unbekannt")
        }
        guard let result = envelope.result else { throw WebUntisError.invalidResponse("kein Ergebnis") }
        return result
    }

    public static func parseUserData(_ data: Data) throws -> WebUntisUser {
        let result = try decode(UserResult.self, data)
        let type = result.userData.elemType.uppercased()
        guard ["STUDENT", "CLASS", "TEACHER", "ROOM", "SUBJECT"].contains(type), result.userData.elemId > 0 else {
            throw WebUntisError.invalidResponse("Benutzerelement")
        }
        var user = WebUntisUser(elementType: type, elementID: result.userData.elemId, displayName: result.userData.displayName?.nilIfBlank)
        for subject in result.masterData.subjects ?? [] { user.subjects[subject.id] = (subject.name?.nilIfBlank, subject.longName?.nilIfBlank) }
        for room in result.masterData.rooms ?? [] { if let name = room.name?.nilIfBlank ?? room.longName?.nilIfBlank { user.rooms[room.id] = name } }
        for teacher in result.masterData.teachers ?? [] {
            if let name = teacher.name?.nilIfBlank ?? teacher.longName?.nilIfBlank { user.teachers[teacher.id] = name }
        }
        for klasse in result.masterData.klassen ?? [] { if let name = klasse.name?.nilIfBlank { user.classes[klasse.id] = name } }
        for (index, holiday) in (result.masterData.holidays ?? []).enumerated() {
            // WebUntis end dates are inclusive (assumption, to verify on the
            // device against the school calendar); stored exclusive.
            guard let start = CivilDate(holiday.startDate), let last = CivilDate(holiday.endDate), last >= start,
                  start.days(to: last) <= 366 else { throw WebUntisError.invalidResponse("Ferien") }
            let name = holiday.longName?.nilIfBlank ?? holiday.name?.nilIfBlank ?? "Ferien"
            user.holidays.append(CalendarHoliday(id: holiday.id.map(String.init) ?? "index-\(index)", name: name,
                                                 start: start, end: last.adding(days: 1)))
        }
        return user
    }

    private struct Element: Decodable { let type: String; let id: Int; let orgId: Int? }
    private struct Texts: Decodable { let lesson: String?; let substitution: String?; let info: String? }
    private struct Period: Decodable {
        let id: Int
        let lessonId: Int?
        let startDateTime: String
        let endDateTime: String
        let elements: [Element]
        let states: [String]
        let texts: Texts?
        let hasExam: Bool
        enum CodingKeys: String, CodingKey { case id, lessonId, startDateTime, endDateTime, elements, `is`, text, exam }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(Int.self, forKey: .id)
            lessonId = try? c.decodeIfPresent(Int.self, forKey: .lessonId)
            startDateTime = try c.decode(String.self, forKey: .startDateTime)
            endDateTime = try c.decode(String.self, forKey: .endDateTime)
            elements = (try? c.decodeIfPresent([Element].self, forKey: .elements)) ?? []
            if let list = try? c.decodeIfPresent([String].self, forKey: .is) { states = list }
            else if let single = try? c.decodeIfPresent(String.self, forKey: .is) { states = [single] }
            else if c.contains(.is), (try? c.decodeNil(forKey: .is)) != true { states = ["?"] }
            else { states = [] }
            texts = try? c.decodeIfPresent(Texts.self, forKey: .text)
            hasExam = c.contains(.exam) && (try? c.decodeNil(forKey: .exam)) == false
        }
    }
    private struct Timetable: Decodable { let periods: [Period] }
    private struct TimetableResult: Decodable { let timetable: Timetable }

    /// Normalized lessons of a complete answer for [start, end). Any invalid
    /// period rejects the whole answer: a partial answer never replaces the
    /// stored days. Lessons starting outside the range are dropped.
    public static func parseTimetable(_ data: Data, user: WebUntisUser, connection: UUID, timeZone: TimeZone,
                                      start: CivilDate, end: CivilDate) throws -> [CalendarLesson] {
        let result = try decode(TimetableResult.self, data)
        guard result.timetable.periods.count <= maximumPeriods else { throw WebUntisError.tooLarge }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        var lessons: [CalendarLesson] = []
        var seen = Set<String>()
        for period in result.timetable.periods {
            guard let from = localDateTime(period.startDateTime), let to = localDateTime(period.endDateTime),
                  let startDate = calendar.date(from: from.components), let endDate = calendar.date(from: to.components),
                  endDate > startDate, endDate.timeIntervalSince(startDate) <= 86_400 else {
                throw WebUntisError.invalidResponse("Stundenzeit")
            }
            guard from.date >= start, from.date < end else { continue }
            let key = CalendarOccurrenceKey(provider: "webuntis", connection: connection, sourceID: String(period.id),
                                            seriesID: period.lessonId.map(String.init), originalStart: from.text)
            guard seen.insert(key.id).inserted else { throw WebUntisError.invalidResponse("doppelte Stunde") }
            var lesson = CalendarLesson(key: key, date: from.date, start: startDate, end: endDate)
            var statuses: [CalendarLessonStatus] = []
            func add(_ status: CalendarLessonStatus) { if !statuses.contains(status) { statuses.append(status) } }
            for element in period.elements {
                let changed = element.orgId.map { $0 != 0 && $0 != element.id } ?? false
                switch element.type.uppercased() {
                case "SUBJECT":
                    let names = user.subjects[element.id]
                    lesson.subject = names?.name ?? lesson.subject
                    lesson.subjectLong = names?.longName ?? lesson.subjectLong
                    if lesson.subjectID == nil { lesson.subjectID = String(element.id) }
                    if changed { add(.substitution) }
                case "ROOM":
                    if let name = user.rooms[element.id] { lesson.rooms.append(name) }
                    if changed { add(.roomChanged); if let old = element.orgId.flatMap({ user.rooms[$0] }) { lesson.originalRooms.append(old) } }
                case "TEACHER":
                    if let name = user.teachers[element.id] { lesson.teachers.append(name) }
                    if changed { add(.substitution); if let old = element.orgId.flatMap({ user.teachers[$0] }) { lesson.originalTeachers.append(old) } }
                case "CLASS":
                    if let name = user.classes[element.id] { lesson.classes.append(name) }
                default: break
                }
            }
            lesson.rawStates = period.states
            for state in period.states { if let status = status(state) { add(status) } }
            if period.hasExam { add(.exam) }
            lesson.statuses = statuses
            lesson.text = [period.texts?.lesson, period.texts?.substitution, period.texts?.info]
                .compactMap { $0?.nilIfBlank }.joined(separator: " · ").nilIfBlank
            lessons.append(lesson)
        }
        return lessons.sorted { ($0.start, $0.id) < ($1.start, $1.id) }
    }

    /// Best-effort mapping (only „REGULAR“ verified); unknown states are kept.
    static func status(_ raw: String) -> CalendarLessonStatus? {
        switch raw.uppercased() {
        case "REGULAR", "": nil
        case "CANCELLED", "CANCEL", "CANCELED": .cancelled
        case "EXAM": .exam
        case "IRREGULAR", "SUBSTITUTION", "ADDITIONAL", "SHIFT": .substitution
        case "ROOMSUBSTITUTION", "ROOM_SUBSTITUTION": .roomChanged
        default: .other(raw)
        }
    }

    /// „YYYY-MM-DDTHH:MM“ (optionally „:SS“) in the school's local time.
    static func localDateTime(_ text: String) -> (date: CivilDate, components: DateComponents, text: String)? {
        let parts = text.split(separator: "T", omittingEmptySubsequences: false)
        guard parts.count == 2, let date = CivilDate(String(parts[0])) else { return nil }
        let time = parts[1].split(separator: ":", omittingEmptySubsequences: false)
        guard (2...3).contains(time.count), time.allSatisfy({ $0.count == 2 && $0.allSatisfy { $0.isASCII && $0.isNumber } }),
              let hour = Int(time[0]), let minute = Int(time[1]), (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        let second = time.count == 3 ? Int(time[2]) ?? 0 : 0
        guard (0...59).contains(second) else { return nil }
        return (date, DateComponents(year: date.year, month: date.month, day: date.day, hour: hour, minute: minute, second: second),
                "\(date)T" + String(format: "%02d:%02d", hour, minute))
    }
}

/// RFC 6238 time-based one-time passwords. The HMAC-SHA1 comes from the
/// caller (CryptoKit in the app), so this stays platform independent.
public enum TOTP {
    public static let period: Double = 30
    public static let digits = 6

    public static func base32Decode(_ text: String) -> Data? {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        var lookup: [Character: UInt8] = [:]
        for (index, char) in alphabet.enumerated() { lookup[char] = UInt8(index) }
        var buffer: UInt32 = 0, bits = 0
        var output = Data()
        for char in text.uppercased() where char != "=" {
            guard let value = lookup[char] else { return nil }
            buffer = (buffer << 5) | UInt32(value)
            bits += 5
            if bits >= 8 {
                output.append(UInt8((buffer >> UInt32(bits - 8)) & 0xFF))
                bits -= 8
            }
            buffer &= (1 << UInt32(bits)) - 1
        }
        return output.isEmpty ? nil : output
    }

    public static func counter(at time: Date) -> UInt64 {
        UInt64(max(0, (time.timeIntervalSince1970 / period).rounded(.down)))
    }

    public static func code(secret: Data, at time: Date, digits: Int = TOTP.digits, hmacSHA1: (Data, Data) -> Data) -> String {
        var counter = counter(at: time).bigEndian
        let message = withUnsafeBytes(of: &counter) { Data($0) }
        let hash = [UInt8](hmacSHA1(secret, message))
        guard hash.count >= 20 else { return String(repeating: "0", count: digits) }
        let offset = Int(hash[hash.count - 1] & 0x0F)
        let binary = (UInt32(hash[offset] & 0x7F) << 24) | (UInt32(hash[offset + 1]) << 16)
            | (UInt32(hash[offset + 2]) << 8) | UInt32(hash[offset + 3])
        var modulus: UInt32 = 1
        for _ in 0..<digits { modulus *= 10 }
        let value = binary % modulus
        let text = String(value)
        return String(repeating: "0", count: max(0, digits - text.count)) + text
    }
}
