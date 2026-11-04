import Foundation

// Kalender Stufe B1: the replaceable offline cache of an external source
// (WebUntis). It is NOT part of the confirmed calendar state: it can be
// dropped at any time and refilled from the source. Coverage is tracked per
// civil day; a day that was never loaded is „not loaded“, never „no lessons“.

/// Identity of one external occurrence: connection + source ids + the start
/// as the source delivered it. Neither title nor the current time alone.
public struct CalendarOccurrenceKey: Hashable, Sendable, Codable {
    public var provider: String
    public var connection: UUID
    /// Per-occurrence id of the source (WebUntis period `id`).
    public var sourceID: String
    /// Id of the series/course (WebUntis `lessonId`), if delivered.
    public var seriesID: String?
    /// Local start as delivered („2026-11-04T08:00“). WebUntis does not
    /// deliver an original start for moved lessons (unverified); B2 adds a
    /// mapping table for notes instead of guessing.
    public var originalStart: String

    public init(provider: String, connection: UUID, sourceID: String, seriesID: String?, originalStart: String) {
        self.provider = provider; self.connection = connection; self.sourceID = sourceID
        self.seriesID = seriesID; self.originalStart = originalStart
    }

    /// Stable string form for UI selection and later link tables.
    public var id: String { "\(provider)/\(connection.uuidString)/\(sourceID)/\(originalStart)" }
}

/// Normalized status of a lesson. Best effort from WebUntis `is` values and
/// changed elements (`orgId` ≠ `id`); unknown values are kept, shown neutrally.
public enum CalendarLessonStatus: Hashable, Sendable, Codable {
    case cancelled
    case exam
    /// Teacher/subject changed, irregular or additional lesson.
    case substitution
    case roomChanged
    /// A state this version does not know (raw value kept).
    case other(String)

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw {
        case "cancelled": self = .cancelled
        case "exam": self = .exam
        case "substitution": self = .substitution
        case "roomChanged": self = .roomChanged
        default: self = .other(raw.hasPrefix("other:") ? String(raw.dropFirst(6)) : raw)
        }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .cancelled: try c.encode("cancelled")
        case .exam: try c.encode("exam")
        case .substitution: try c.encode("substitution")
        case .roomChanged: try c.encode("roomChanged")
        case .other(let raw): try c.encode("other:" + raw)
        }
    }
}

/// One lesson of the timetable (read-only).
public struct CalendarLesson: Identifiable, Equatable, Sendable, Codable {
    public var key: CalendarOccurrenceKey
    public var id: String { key.id }
    /// Local civil date of the start (coverage bucket).
    public var date: CivilDate
    public var start: Date
    public var end: Date
    public var subject: String?
    public var subjectLong: String?
    public var rooms: [String] = []
    /// Rooms before a change (`orgId`), when delivered.
    public var originalRooms: [String] = []
    /// Only filled when the source delivers teachers (often not for students).
    public var teachers: [String] = []
    public var originalTeachers: [String] = []
    public var classes: [String] = []
    public var statuses: [CalendarLessonStatus] = []
    /// Raw `is` values as delivered (diagnosis; e.g. „REGULAR“).
    public var rawStates: [String] = []
    /// Lesson text / substitution text, when delivered.
    public var text: String?

    public init(key: CalendarOccurrenceKey, date: CivilDate, start: Date, end: Date) {
        self.key = key; self.date = date; self.start = start; self.end = end
    }

    /// „Mathematik“; falls back to the short name, then the text.
    public var title: String {
        subjectLong?.nilIfBlank ?? subject?.nilIfBlank ?? text?.nilIfBlank ?? "Unterricht"
    }
    public var isCancelled: Bool { statuses.contains(.cancelled) }
}

/// School holidays as delivered by the source; `end` exclusive.
public struct CalendarHoliday: Identifiable, Equatable, Sendable, Codable {
    public var id: String
    public var name: String
    public var start: CivilDate
    public var end: CivilDate
    public init(id: String, name: String, start: CivilDate, end: CivilDate) {
        self.id = id; self.name = name; self.start = start; self.end = end
    }
}

/// Result of one complete, validated timetable request.
public struct CalendarTimetableFetch: Sendable, Equatable {
    public let connection: UUID
    /// Requested civil days, `end` exclusive. Only these days are replaced.
    public let start: CivilDate
    public let end: CivilDate
    /// When the request started (an older answer never replaces a newer day).
    public let fetchedAt: Date
    public let lessons: [CalendarLesson]
    public init(connection: UUID, start: CivilDate, end: CivilDate, fetchedAt: Date, lessons: [CalendarLesson]) {
        self.connection = connection; self.start = start; self.end = end; self.fetchedAt = fetchedAt; self.lessons = lessons
    }
}

/// How far a shown range is loaded.
public enum CalendarCoverage: Equatable, Sendable {
    /// Every day loaded; `oldest` = earliest fetch time among them („Stand“).
    case loaded(oldest: Date)
    /// Some days loaded, some not.
    case partial(oldest: Date)
    case notLoaded
}

public struct CalendarSourceSnapshot: Equatable, Sendable, Codable {
    public static let currentFormat = 1
    public static let maximumDays = 1_200
    public static let maximumLessons = 40_000
    public static let maximumRequestDays = 62

    public var formatVersion = CalendarSourceSnapshot.currentFormat
    public var connection: UUID
    public var lessons: [CalendarLesson] = []
    /// Loaded civil days („YYYY-MM-DD“) → fetch time (seconds since 2001-01-01 UTC).
    public var days: [String: Double] = [:]
    public var holidays: [CalendarHoliday] = []
    public var holidaysFetchedAt: Date?

    public init(connection: UUID) { self.connection = connection }

    /// Lessons of a loaded day; nil when the day was never loaded.
    public func lessons(on day: CivilDate) -> [CalendarLesson]? {
        guard days[day.description] != nil else { return nil }
        return lessons.filter { $0.date == day }
    }

    public func coverage(from start: CivilDate, to end: CivilDate) -> CalendarCoverage {
        var oldest: Double?
        var missing = false
        var day = start
        var guardCount = 0
        while day < end, guardCount < 400 {
            if let t = days[day.description] { oldest = min(oldest ?? t, t) } else { missing = true }
            day = day.adding(days: 1); guardCount += 1
        }
        guard let oldest else { return .notLoaded }
        return missing ? .partial(oldest: Date(timeIntervalSinceReferenceDate: oldest)) : .loaded(oldest: Date(timeIntervalSinceReferenceDate: oldest))
    }

    /// Replaces exactly the requested days whose stored fetch is not newer.
    /// Lessons outside the requested range are ignored (never stored as a
    /// day without coverage). Returns the number of days taken over.
    @discardableResult
    public mutating func merge(_ fetch: CalendarTimetableFetch) throws -> Int {
        guard fetch.connection == connection else { throw CalendarStoreError.staleConnection }
        let span = fetch.start.days(to: fetch.end)
        guard span > 0, span <= Self.maximumRequestDays else { throw CalendarStoreError.invalidState }
        let time = fetch.fetchedAt.timeIntervalSinceReferenceDate
        guard time.isFinite else { throw CalendarStoreError.invalidState }
        var taken = Set<CivilDate>()
        var day = fetch.start
        while day < fetch.end {
            if let stored = days[day.description], stored > time { day = day.adding(days: 1); continue }
            taken.insert(day)
            day = day.adding(days: 1)
        }
        guard !taken.isEmpty else { return 0 }
        lessons.removeAll { taken.contains($0.date) }
        lessons += fetch.lessons.filter { taken.contains($0.date) && $0.key.connection == connection }
        for day in taken { days[day.description] = time }
        lessons.sort { ($0.start, $0.id) < ($1.start, $1.id) }
        prune(keepingAround: fetch.start)
        return taken.count
    }

    public mutating func replaceHolidays(_ holidays: [CalendarHoliday], fetchedAt: Date) {
        if let stored = holidaysFetchedAt, stored > fetchedAt { return }
        self.holidays = holidays.sorted { ($0.start, $0.id) < ($1.start, $1.id) }
        holidaysFetchedAt = fetchedAt
    }

    /// Bounded cache: the days farthest from `center` go first, with their lessons.
    mutating func prune(keepingAround center: CivilDate) {
        guard days.count > Self.maximumDays || lessons.count > Self.maximumLessons else { return }
        let ordered = days.keys.compactMap(CivilDate.init).sorted { abs(center.days(to: $0)) > abs(center.days(to: $1)) }
        var index = 0
        while index < ordered.count, days.count > Self.maximumDays || lessons.count > Self.maximumLessons {
            let day = ordered[index]
            days[day.description] = nil
            lessons.removeAll { $0.date == day }
            index += 1
        }
    }

    public func validate() throws {
        guard formatVersion == Self.currentFormat else { throw CalendarStoreError.unsupportedFormat(formatVersion) }
        guard days.count <= Self.maximumDays * 2, lessons.count <= Self.maximumLessons * 2, holidays.count <= 2_000,
              days.keys.allSatisfy({ CivilDate($0) != nil }), days.values.allSatisfy({ $0.isFinite }),
              Set(lessons.map(\.id)).count == lessons.count,
              lessons.allSatisfy({ $0.end >= $0.start && $0.key.connection == connection && days[$0.date.description] != nil }),
              holidays.allSatisfy({ $0.end > $0.start }) else { throw CalendarStoreError.invalidState }
    }

    private enum CodingKeys: String, CodingKey { case formatVersion, connection, lessons, days, holidays, holidaysFetchedAt }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try c.decode(Int.self, forKey: .formatVersion)
        // A newer cache is not read further (its fields may mean something else).
        guard formatVersion == Self.currentFormat else { throw CalendarStoreError.unsupportedFormat(formatVersion) }
        connection = try c.decode(UUID.self, forKey: .connection)
        lessons = try c.decode([CalendarLesson].self, forKey: .lessons)
        days = try c.decode([String: Double].self, forKey: .days)
        holidays = try c.decode([CalendarHoliday].self, forKey: .holidays)
        holidaysFetchedAt = try c.decodeIfPresent(Double.self, forKey: .holidaysFetchedAt).map { Date(timeIntervalSinceReferenceDate: $0) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(formatVersion, forKey: .formatVersion); try c.encode(connection, forKey: .connection)
        try c.encode(lessons, forKey: .lessons); try c.encode(days, forKey: .days); try c.encode(holidays, forKey: .holidays)
        try c.encodeIfPresent(holidaysFetchedAt?.timeIntervalSinceReferenceDate, forKey: .holidaysFetchedAt)
    }
}

extension String {
    var nilIfBlank: String? {
        let text = trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}
