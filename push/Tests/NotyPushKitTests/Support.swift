import Foundation
import XCTest
import NotebookCore
@testable import NotyPushKit

// All fixtures are FICTITIOUS (invented server, school, user, key, token).

let berlin = TimeZone(identifier: "Europe/Berlin")!
let connectionID = UUID(uuidString: "00000000-0000-4000-8000-0000000000c1")!
/// RFC 6238 test secret „12345678901234567890“.
let rfcKey = "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"
let fakeToken = String(repeating: "ab", count: 32)
let bundleID = "XTL-BAFXLQ964V.XTL-BAFXLQ964V.de.la.noty.calendar"

var berlinCalendar: Calendar {
    var calendar = Calendar(identifier: .gregorian); calendar.timeZone = berlin; return calendar
}

/// Local Berlin wall-clock time.
func at(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int = 0) -> Date {
    berlinCalendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
}

func setup() -> WebUntisSetup {
    try! WebUntisSetup(server: "demo.webuntis.example", school: "demo-schule", user: "max.muster", key: rfcKey)
}

func lesson(_ id: Int, _ start: Date, minutes: Int = 45, subject: String = "Deutsch", subjectID: String = "2",
            rooms: [String] = ["R101"], statuses: [CalendarLessonStatus] = [], connection: UUID = connectionID) -> CalendarLesson {
    let date = CivilDate(start, calendar: berlinCalendar)
    let p = berlinCalendar.dateComponents([.hour, .minute], from: start)
    let key = CalendarOccurrenceKey(provider: "webuntis", connection: connection, sourceID: String(id), seriesID: "900",
                                    originalStart: "\(date)T" + String(format: "%02d:%02d", p.hour!, p.minute!))
    var lesson = CalendarLesson(key: key, date: date, start: start, end: start.addingTimeInterval(Double(minutes) * 60))
    lesson.subject = String(subject.prefix(1)); lesson.subjectLong = subject; lesson.subjectID = subjectID
    lesson.rooms = rooms; lesson.statuses = statuses
    lesson.rawStates = statuses.contains(.cancelled) ? ["CANCELLED"] : ["REGULAR"]
    return lesson
}

final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ date: Date) { value = date }
    var now: Date { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ date: Date) { lock.lock(); value = date; lock.unlock() }
}

/// Returns the configured lessons of the requested window, or an error.
final class StubSource: TimetableSource, @unchecked Sendable {
    private let lock = NSLock()
    private var _lessons: [CalendarLesson] = []
    private var _error: Error?
    private(set) var calls = 0
    /// Time zone of the last request (the connection's, not the device's).
    private(set) var lastTimeZone: TimeZone?
    /// Runs during `load` (e.g. to delete the device meanwhile).
    var duringLoad: (@Sendable () async -> Void)?

    var lessons: [CalendarLesson] { get { lock.lock(); defer { lock.unlock() }; return _lessons } set { lock.lock(); _lessons = newValue; lock.unlock() } }
    var error: Error? { get { lock.lock(); defer { lock.unlock() }; return _error } set { lock.lock(); _error = newValue; lock.unlock() } }

    func load(setup: WebUntisSetup, connection: UUID, timeZone: TimeZone, start: CivilDate, end: CivilDate, at time: Date) async throws -> CalendarTimetableFetch {
        lock.withLock { calls += 1; lastTimeZone = timeZone }
        if let duringLoad { await duringLoad() }
        if let error { throw error }
        let list = lessons.filter { $0.date >= start && $0.date < end }.map { lesson -> CalendarLesson in
            var copy = lesson; copy.key.connection = connection; return copy
        }
        return CalendarTimetableFetch(connection: connection, start: start, end: end, fetchedAt: time, lessons: list)
    }
}

final class MockSender: PushSender, @unchecked Sendable {
    private let lock = NSLock()
    private var _sent: [(PushMessage, PushTarget)] = []
    var result: PushResult = .delivered
    /// Runs during `send` (e.g. to change the device meanwhile).
    var duringSend: (@Sendable () async -> Void)?
    var sent: [(PushMessage, PushTarget)] { lock.lock(); defer { lock.unlock() }; return _sent }
    func send(_ message: PushMessage, to target: PushTarget) async -> PushResult {
        if let duringSend { await duringSend() }
        return lock.withLock { _sent.append((message, target)); return result }
    }
}

func temporaryDirectory() -> String {
    let path = NSTemporaryDirectory() + "noty-push-test-" + UUID().uuidString
    try! FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    return path
}

func testKeyring() -> DataKeyring { try! DataKeyring(keys: [Data(repeating: 7, count: 32)]) }

func testConfig() -> PushConfig {
    var config = PushConfig()
    config.apnsKeyID = "ABCDE12345"; config.teamID = "BAFXLQ964V"; config.allowedBundleIDs = [bundleID]
    // The fictitious fixtures use demo.webuntis.example (the default allows only *.webuntis.com).
    config.allowedUntisHostSuffixes = ["webuntis.example"]
    return config
}

func makeService(dir: String = temporaryDirectory(), config: PushConfig = testConfig(), source: StubSource, sender: MockSender,
                 clock: Clock) throws -> PushService {
    let store = try DeviceStore(dataDirectory: dir, keyring: testKeyring())
    return PushService(config: config, store: store, source: source, sender: sender, now: { clock.now })
}

func registration(token: String = fakeToken) -> RegistrationInput {
    RegistrationInput(deviceToken: token, environment: .sandbox, bundleID: bundleID, connectionID: connectionID,
                      timeZone: "Europe/Berlin", settings: DeviceSettings(), setup: setup())
}
