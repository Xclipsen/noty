import Foundation
import NotebookCore

public enum APNsEnvironment: String, Codable, Sendable, CaseIterable {
    case sandbox, production
    public var host: String { self == .sandbox ? "api.sandbox.push.apple.com" : "api.push.apple.com" }
}

public enum DeviceState: String, Codable, Sendable {
    /// Polled and notified.
    case active
    /// WebUntis rejected the access twice in a row; waits for a new Freigabe (PUT).
    case authFailed
    /// APNs says the token is invalid (410/BadDeviceToken); waits for a new token (PUT).
    case tokenInvalid
}

/// What happened to a detected change.
public enum ChangeDelivery: String, Codable, Sendable {
    case sent
    /// Part of one summary push.
    case summarized
    /// Detected in the quiet hours, waits for their end.
    case pending
    /// Waited for the quiet end, but the lesson had begun by then.
    case expired
    /// Change notifications are switched off for this device.
    case disabled
    /// APNs refused or was unreachable; only in the history.
    case failed
}

/// One detected timetable change (history for the in-app bell, `GET /v1/changes`).
public struct ChangeEntry: Codable, Equatable, Sendable {
    /// `CalendarLessonChange.id` from Core: the same id the app computes locally.
    public var id: String
    public var kinds: [String]
    public var title: String
    public var body: String
    public var detected: Date
    public var day: CivilDate
    /// `CalendarLesson.id` (contains the app's connection id).
    public var entryID: String
    /// WebUntis period id.
    public var periodID: String
    public var lessonStart: Date
    public var delivery: ChangeDelivery
}

/// Notification settings of the device that matter here (subset of the
/// app's `CalendarNotificationSettings`, the same type from Core).
public typealias DeviceSettings = CalendarNotificationSettings

/// Everything the service keeps about one device; stored sealed as one file.
public struct DeviceRecord: Codable, Sendable {
    public static let currentFormat = 1
    public static let maximumHistory = 200
    public static let historyDays = 60

    public var formatVersion = DeviceRecord.currentFormat
    public var id: String
    public var secretHash: String
    public var created: Date
    public var updated: Date
    /// Incremented by every API change; a poll that started on an older
    /// generation does not write its result.
    public var generation: Int = 0
    public var deviceToken: String
    public var environment: APNsEnvironment
    public var bundleID: String
    public var connectionID: UUID
    public var timeZone: String
    public var settings: DeviceSettings
    public var setup: WebUntisSetup
    public var state: DeviceState = .active
    public var snapshot: CalendarSourceSnapshot?
    public var baselineAt: Date?
    public var lastPoll: Date?
    public var lastSuccess: Date?
    public var nextPoll: Date
    public var failures: Int = 0
    public var authFailures: Int = 0
    /// Short German category of the last error (no details from WebUntis).
    public var lastError: String?
    /// „Untis-Zugang prüfen“ was pushed (or is waiting for the quiet end).
    public var authNotice: AuthNotice = .none
    public var history: [ChangeEntry] = []

    public enum AuthNotice: String, Codable, Sendable { case none, pending, sent }

    public var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZone) ?? TimeZone(identifier: "Europe/Berlin")!
        calendar.locale = Locale(identifier: "de_DE")
        return calendar
    }

    /// Minute after the full hour at which this device is polled.
    public func pollMinute(spread: Int) -> Int {
        Int(id.unicodeScalars.reduce(UInt32(0)) { ($0 &* 31) &+ $1.value } % UInt32(max(1, spread)))
    }

    public mutating func addHistory(_ entries: [ChangeEntry], now: Date) {
        history += entries
        let limit = now.addingTimeInterval(-Double(Self.historyDays) * 86_400)
        history.removeAll { $0.detected < limit }
        history.sort { ($0.detected, $0.id) < ($1.detected, $1.id) }
        if history.count > Self.maximumHistory { history.removeFirst(history.count - Self.maximumHistory) }
    }

    func validated() throws -> DeviceRecord {
        guard formatVersion == Self.currentFormat else { throw PushError.storage("unbekanntes Geräteformat \(formatVersion)") }
        var copy = self
        // Codable bypasses the checks of WebUntisSetup.init: run them again.
        copy.setup = try WebUntisSetup(server: setup.server, school: setup.school, user: setup.user, key: setup.key,
                                       schoolNumber: setup.schoolNumber)
        try snapshot?.validate()
        guard TimeZone(identifier: timeZone) != nil else { throw PushError.storage("Zeitzone") }
        return copy
    }
}
