import Foundation

// Kalender Stufe B1 (docs/CALENDAR-PLAN.md): confirmed calendar state of one
// area – own local events, settings and the (non-secret) record of a source
// connection. Platform independent; the app maps it to its views.

/// A civil date without time or time zone („2026-11-04“). All-day events use
/// these with an exclusive end, never midnight-UTC substitutes.
public struct CivilDate: Hashable, Comparable, Sendable, Codable, CustomStringConvertible {
    public let year: Int
    public let month: Int
    public let day: Int

    /// Valid Gregorian dates of the years 1…9999 only.
    public init?(year: Int, month: Int, day: Int) {
        guard (1...9999).contains(year), (1...12).contains(month), (1...31).contains(day) else { return nil }
        var parts = DateComponents(); parts.year = year; parts.month = month; parts.day = day
        guard let date = Self.utc.date(from: parts) else { return nil }
        let back = Self.utc.dateComponents([.year, .month, .day], from: date)
        guard back.year == year, back.month == month, back.day == day else { return nil }
        self.year = year; self.month = month; self.day = day
    }

    /// „YYYY-MM-DD“, exactly (also the WebUntis date form).
    public init?(_ text: String) {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard text.count == 10, parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              parts.allSatisfy({ $0.allSatisfy { $0.isASCII && $0.isNumber } }),
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]) else { return nil }
        self.init(year: y, month: m, day: d)
    }

    /// The civil date of `date` as seen by `calendar` (its time zone).
    public init(_ date: Date, calendar: Calendar) {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        // Components of a real date are a valid civil date; years are clamped to 1…9999.
        self = CivilDate(year: min(9999, max(1, parts.year ?? 1)), month: parts.month ?? 1, day: parts.day ?? 1) ?? .epoch
    }

    static let epoch = CivilDate(year: 1970, month: 1, day: 1)!

    public var description: String { String(format: "%04d-%02d-%02d", year, month, day) }

    /// Start of this day in `calendar` (time zone aware; a day may start after
    /// 00:00 where midnight does not exist).
    public func start(in calendar: Calendar) -> Date {
        var parts = DateComponents(); parts.year = year; parts.month = month; parts.day = day; parts.hour = 12
        let noon = calendar.date(from: parts) ?? Date(timeIntervalSince1970: 0)
        return calendar.startOfDay(for: noon)
    }

    /// Civil day arithmetic (UTC Gregorian: no daylight saving involved).
    public func adding(days: Int) -> CivilDate {
        let base = Self.utc.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
        let moved = Self.utc.date(byAdding: .day, value: days, to: base) ?? base
        return CivilDate(moved, calendar: Self.utc)
    }

    /// Whole days from `self` to `other` (negative when `other` is earlier).
    public func days(to other: CivilDate) -> Int {
        let a = Self.utc.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
        let b = Self.utc.date(from: DateComponents(year: other.year, month: other.month, day: other.day, hour: 12))!
        return Self.utc.dateComponents([.day], from: a, to: b).day ?? 0
    }

    public static func < (a: CivilDate, b: CivilDate) -> Bool {
        (a.year, a.month, a.day) < (b.year, b.month, b.day)
    }

    public init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let value = CivilDate(text) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Ungültiges Datum"))
        }
        self = value
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }

    static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
}

/// When a local event takes place.
public enum CalendarEventTiming: Equatable, Sendable, Codable {
    /// Civil dates, `end` exclusive (a one-day event on 4 Nov ends 5 Nov).
    case allDay(start: CivilDate, end: CivilDate)
    /// Absolute instants plus the time zone the user entered them in. Stored
    /// as seconds since 2001-01-01 00:00 UTC (Foundation reference date,
    /// exact round trip), like every instant in the calendar formats.
    case timed(start: Date, end: Date, timeZone: String)

    private enum CodingKeys: String, CodingKey { case kind, startDate, endDate, start, end, timeZone }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "allDay":
            self = .allDay(start: try c.decode(CivilDate.self, forKey: .startDate), end: try c.decode(CivilDate.self, forKey: .endDate))
        case "timed":
            self = .timed(start: Date(timeIntervalSinceReferenceDate: try c.decode(Double.self, forKey: .start)),
                          end: Date(timeIntervalSinceReferenceDate: try c.decode(Double.self, forKey: .end)),
                          timeZone: try c.decode(String.self, forKey: .timeZone))
        default:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "Unbekannte Terminart")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .allDay(let start, let end):
            try c.encode("allDay", forKey: .kind); try c.encode(start, forKey: .startDate); try c.encode(end, forKey: .endDate)
        case .timed(let start, let end, let zone):
            try c.encode("timed", forKey: .kind)
            try c.encode(start.timeIntervalSinceReferenceDate, forKey: .start); try c.encode(end.timeIntervalSinceReferenceDate, forKey: .end)
            try c.encode(zone, forKey: .timeZone)
        }
    }

    public var isAllDay: Bool { if case .allDay = self { return true }; return false }

    /// Display interval in `calendar`; all-day: start of the first day to the
    /// start of the exclusive end day.
    public func interval(in calendar: Calendar) -> (start: Date, end: Date) {
        switch self {
        case .allDay(let start, let end): (start.start(in: calendar), end.start(in: calendar))
        case .timed(let start, let end, _): (start, end)
        }
    }

    /// Nil when valid, otherwise a German explanation for the form.
    public var problem: String? {
        switch self {
        case .allDay(let start, let end):
            guard end > start else { return "Das Ende liegt vor dem Beginn. Bitte eine gültige Zeitspanne wählen." }
            guard start.days(to: end) <= CalendarState.maximumEventDays else { return "Ein Termin darf höchstens fünf Jahre dauern." }
        case .timed(let start, let end, let zone):
            guard TimeZone(identifier: zone) != nil else { return "Unbekannte Zeitzone." }
            guard CalendarState.validInstant(start), CalendarState.validInstant(end) else { return "Ungültiges Datum." }
            guard end > start else { return "Das Ende liegt vor dem Beginn. Bitte eine gültige Zeitspanne wählen." }
            guard end.timeIntervalSince(start) <= Double(CalendarState.maximumEventDays) * 86_400 + 7_200 else {
                return "Ein Termin darf höchstens fünf Jahre dauern."
            }
        }
        return nil
    }
}

/// An own event of the local calendar „Persönlich“. Stable identity: `id`
/// survives every edit and move (later note links reference it).
public struct LocalCalendarEvent: Identifiable, Equatable, Sendable, Codable {
    public let id: UUID
    public var title: String
    public var location: String
    public var details: String
    public var timing: CalendarEventTiming
    /// Repetition (format 2); nil: a single event. `timing` is the first occurrence.
    public var recurrence: CalendarRecurrence?
    /// Reminder (format 3): minutes before the start (`CalendarReminder.presets`);
    /// nil = none (the default). Applies to every occurrence of a series.
    public var reminderMinutes: Int?
    public var createdAt: Date
    public var modifiedAt: Date

    public init(id: UUID = UUID(), title: String, location: String = "", details: String = "",
                timing: CalendarEventTiming, recurrence: CalendarRecurrence? = nil, reminderMinutes: Int? = nil,
                createdAt: Date = Date(), modifiedAt: Date? = nil) {
        self.id = id; self.title = title; self.location = location; self.details = details
        self.timing = timing; self.recurrence = recurrence; self.reminderMinutes = reminderMinutes
        self.createdAt = createdAt; self.modifiedAt = modifiedAt ?? createdAt
    }

    private enum CodingKeys: String, CodingKey { case id, title, location, details, timing, recurrence, reminderMinutes, createdAt, modifiedAt }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        location = try c.decodeIfPresent(String.self, forKey: .location) ?? ""
        details = try c.decodeIfPresent(String.self, forKey: .details) ?? ""
        timing = try c.decode(CalendarEventTiming.self, forKey: .timing)
        recurrence = try c.decodeIfPresent(CalendarRecurrence.self, forKey: .recurrence)
        reminderMinutes = try c.decodeIfPresent(Int.self, forKey: .reminderMinutes)
        createdAt = Date(timeIntervalSinceReferenceDate: try c.decode(Double.self, forKey: .createdAt))
        modifiedAt = Date(timeIntervalSinceReferenceDate: try c.decode(Double.self, forKey: .modifiedAt))
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(title, forKey: .title)
        try c.encode(location, forKey: .location); try c.encode(details, forKey: .details)
        try c.encode(timing, forKey: .timing)
        try c.encodeIfPresent(recurrence, forKey: .recurrence)
        try c.encodeIfPresent(reminderMinutes, forKey: .reminderMinutes)
        try c.encode(createdAt.timeIntervalSinceReferenceDate, forKey: .createdAt)
        try c.encode(modifiedAt.timeIntervalSinceReferenceDate, forKey: .modifiedAt)
    }
}

/// Per-area view settings.
public struct CalendarSettings: Equatable, Sendable, Codable {
    /// 5 = Monday–Friday, 7 = whole week.
    public var weekDays: Int = 5
    /// `CalendarMode.rawValue` of the last view.
    public var mode: String = CalendarMode.week.rawValue
    /// Subject colours chosen by the user (format 2): subject key
    /// (`CalendarSubjectColor.key`) → colour name. Missing: automatic.
    public var subjectColors: [String: String] = [:]
    /// Library folder „Kalendernotizen“ by identity (format 2); never by name.
    public var notesFolderID: UUID?
    /// „Unterricht: Erinnerung X Minuten vorher“ (format 3); nil = off (the
    /// default). One of `CalendarReminder.lessonPresets`; cancelled lessons never.
    public var lessonReminderMinutes: Int?
    public init() {}

    private enum CodingKeys: String, CodingKey { case weekDays, mode, subjectColors, notesFolderID, lessonReminderMinutes }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        weekDays = try c.decodeIfPresent(Int.self, forKey: .weekDays) ?? 5
        mode = try c.decodeIfPresent(String.self, forKey: .mode) ?? CalendarMode.week.rawValue
        subjectColors = try c.decodeIfPresent([String: String].self, forKey: .subjectColors) ?? [:]
        notesFolderID = try c.decodeIfPresent(UUID.self, forKey: .notesFolderID)
        lessonReminderMinutes = try c.decodeIfPresent(Int.self, forKey: .lessonReminderMinutes)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(weekDays, forKey: .weekDays); try c.encode(mode, forKey: .mode)
        if !subjectColors.isEmpty { try c.encode(subjectColors, forKey: .subjectColors) }
        try c.encodeIfPresent(notesFolderID, forKey: .notesFolderID)
        try c.encodeIfPresent(lessonReminderMinutes, forKey: .lessonReminderMinutes)
    }
}

/// Non-secret record of a source connection. Credentials live only in the
/// device keychain under `id`; this record never contains them.
public struct CalendarConnectionRecord: Identifiable, Equatable, Sendable, Codable {
    public enum Kind: String, Codable, Sendable { case webUntis }
    public let id: UUID
    public var kind: Kind
    /// Shown name, e.g. the school login name (no user name, no key).
    public var label: String
    /// Time zone of the source's local times (WebUntis: the school's).
    public var timeZone: String
    public var connectedAt: Date
    /// Non-secret identity of the source account (format 2): a SHA-256 over
    /// server, school and user (`WebUntis.sourceIdentity`). Reconnecting the
    /// same „Freigabe“ gives the same identity, so lesson notes come back.
    /// Nil for B1 records: the connection id stands in.
    public var sourceIdentity: String?

    public init(id: UUID = UUID(), kind: Kind = .webUntis, label: String, timeZone: String = "Europe/Berlin",
                connectedAt: Date = Date(), sourceIdentity: String? = nil) {
        self.id = id; self.kind = kind; self.label = label; self.timeZone = timeZone; self.connectedAt = connectedAt
        self.sourceIdentity = sourceIdentity
    }

    /// The source key lesson notes are anchored to.
    public var source: String { sourceIdentity ?? "connection:" + id.uuidString }

    private enum CodingKeys: String, CodingKey { case id, kind, label, timeZone, connectedAt, sourceIdentity }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        kind = try c.decode(Kind.self, forKey: .kind)
        label = try c.decode(String.self, forKey: .label)
        timeZone = try c.decode(String.self, forKey: .timeZone)
        connectedAt = Date(timeIntervalSinceReferenceDate: try c.decode(Double.self, forKey: .connectedAt))
        sourceIdentity = try c.decodeIfPresent(String.self, forKey: .sourceIdentity)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(kind, forKey: .kind); try c.encode(label, forKey: .label)
        try c.encode(timeZone, forKey: .timeZone); try c.encode(connectedAt.timeIntervalSinceReferenceDate, forKey: .connectedAt)
        try c.encodeIfPresent(sourceIdentity, forKey: .sourceIdentity)
    }
}

/// The confirmed calendar state of one area (one revision of `Calendar/`).
public struct CalendarState: Equatable, Sendable, Codable {
    /// Content format. A newer one locks the package (never read partially,
    /// never replaced by an older state). 1 = B1; 2 = B2 (series, note links,
    /// lesson mappings, subject colours, notes folder, source identity);
    /// 3 = B3 (reminders, lesson reminder setting, deleted events).
    public static let currentFormat = 3
    /// Older formats this version reads and migrates on its next commit
    /// (the exact old bytes are archived first, `CalendarStore`).
    public static let migratableFormats = 1..<currentFormat
    public static let maximumEvents = 20_000
    public static let maximumEventDays = 5 * 366
    public static let maximumLinks = 20_000
    public static let maximumMappings = 20_000
    public static let maximumDeleted = 1_000
    public var formatVersion = CalendarState.currentFormat
    public var events: [LocalCalendarEvent] = []
    public var settings = CalendarSettings()
    /// At most one source connection (WebUntis).
    public var connection: CalendarConnectionRecord?
    /// Event notes: links to ordinary notebooks by identity (format 2).
    public var noteLinks: [CalendarNoteLink] = []
    /// Lessons the user assigned anew after WebUntis delivered them under
    /// another period id (format 2); notes follow them.
    public var lessonMappings: [CalendarLessonMapping] = []
    /// „Gelöschte Termine“ (format 3): own events or single occurrences
    /// deleted by the user, recoverable until removed for good. Their note
    /// links stay in `noteLinks` (notes are never deleted with an event).
    public var deletedEvents: [CalendarDeletedEvent] = []

    public init() {}

    private enum CodingKeys: String, CodingKey { case formatVersion, events, settings, connection, noteLinks, lessonMappings, deletedEvents }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try c.decode(Int.self, forKey: .formatVersion)
        events = try c.decode([LocalCalendarEvent].self, forKey: .events)
        settings = try c.decodeIfPresent(CalendarSettings.self, forKey: .settings) ?? CalendarSettings()
        connection = try c.decodeIfPresent(CalendarConnectionRecord.self, forKey: .connection)
        noteLinks = try c.decodeIfPresent([CalendarNoteLink].self, forKey: .noteLinks) ?? []
        lessonMappings = try c.decodeIfPresent([CalendarLessonMapping].self, forKey: .lessonMappings) ?? []
        deletedEvents = try c.decodeIfPresent([CalendarDeletedEvent].self, forKey: .deletedEvents) ?? []
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(formatVersion, forKey: .formatVersion); try c.encode(events, forKey: .events)
        try c.encode(settings, forKey: .settings); try c.encodeIfPresent(connection, forKey: .connection)
        try c.encode(noteLinks, forKey: .noteLinks); try c.encode(lessonMappings, forKey: .lessonMappings)
        if !deletedEvents.isEmpty { try c.encode(deletedEvents, forKey: .deletedEvents) }
    }

    static func validate(_ event: LocalCalendarEvent) throws {
        guard validTitle(event.title) == event.title, event.location.count <= 500, event.details.count <= 20_000,
              event.timing.problem == nil, validInstant(event.createdAt), validInstant(event.modifiedAt),
              event.reminderMinutes.map({ CalendarReminder.presets.contains($0) }) ?? true else {
            throw CalendarStoreError.invalidState
        }
        if let recurrence = event.recurrence { try recurrence.validate(for: event.timing) }
    }

    /// Nothing but defaults: an area without calendar data.
    public var isEmpty: Bool {
        events.isEmpty && connection == nil && noteLinks.isEmpty && lessonMappings.isEmpty && deletedEvents.isEmpty
            && settings == CalendarSettings()
    }

    static func validInstant(_ date: Date) -> Bool {
        let t = date.timeIntervalSince1970
        return t.isFinite && (-62_135_596_800...253_402_300_799).contains(t)
    }

    public static func validTitle(_ title: String) -> String? {
        let text = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...200).contains(text.count), !text.contains("\n"), !text.contains("\r") else { return nil }
        return text
    }

    /// Structural checks; a revision that fails them is not acknowledged.
    public func validate() throws {
        guard formatVersion == Self.currentFormat else { throw CalendarStoreError.unsupportedFormat(formatVersion) }
        guard events.count <= Self.maximumEvents, Set(events.map(\.id)).count == events.count,
              [5, 7].contains(settings.weekDays), CalendarMode(rawValue: settings.mode) != nil else {
            throw CalendarStoreError.invalidState
        }
        for event in events { try Self.validate(event) }
        guard deletedEvents.count <= Self.maximumDeleted, Set(deletedEvents.map(\.id)).count == deletedEvents.count else {
            throw CalendarStoreError.invalidState
        }
        let active = Set(events.map(\.id))
        for deleted in deletedEvents {
            try Self.validate(deleted.event)
            guard Self.validInstant(deleted.deletedAt) else { throw CalendarStoreError.invalidState }
            if let date = deleted.occurrence {
                // One occurrence of a series: the series knows the date.
                guard let rule = deleted.event.recurrence,
                      CalendarSeries.generates(date, timing: deleted.event.timing, rule: rule) else { throw CalendarStoreError.invalidState }
            } else {
                // A whole event is either active or deleted, never both.
                guard !active.contains(deleted.event.id) else { throw CalendarStoreError.invalidState }
            }
        }
        guard settings.lessonReminderMinutes.map({ CalendarReminder.lessonPresets.contains($0) }) ?? true else {
            throw CalendarStoreError.invalidState
        }
        if let connection {
            guard !connection.label.isEmpty, connection.label.count <= 200, TimeZone(identifier: connection.timeZone) != nil,
                  Self.validInstant(connection.connectedAt), (connection.sourceIdentity?.count ?? 0) <= 200 else {
                throw CalendarStoreError.invalidState
            }
        }
        guard settings.subjectColors.count <= 2_000,
              settings.subjectColors.allSatisfy({ (1...300).contains($0.key.count) && CalendarSubjectColor.choosable.contains($0.value) }) else {
            throw CalendarStoreError.invalidState
        }
        guard noteLinks.count <= Self.maximumLinks, Set(noteLinks.map(\.id)).count == noteLinks.count,
              noteLinks.allSatisfy({ $0.isValid }) else { throw CalendarStoreError.invalidState }
        guard lessonMappings.count <= Self.maximumMappings, Set(lessonMappings.map(\.id)).count == lessonMappings.count,
              lessonMappings.allSatisfy({ $0.isValid }) else { throw CalendarStoreError.invalidState }
    }
}

/// One entry of „Gelöschte Termine“ (format 3).
public struct CalendarDeletedEvent: Identifiable, Equatable, Sendable, Codable {
    public let id: UUID
    /// The event as it was when deleted (a series with all its exceptions).
    public var event: LocalCalendarEvent
    /// Nil: the whole event (or series) was deleted. Otherwise one occurrence
    /// of the series `event.id` („Nur dieser Termin“), stored as an exception
    /// of the active series; restoring removes that exception again.
    public var occurrence: CivilDate?
    public var deletedAt: Date

    public init(id: UUID = UUID(), event: LocalCalendarEvent, occurrence: CivilDate? = nil, deletedAt: Date = Date()) {
        self.id = id; self.event = event; self.occurrence = occurrence; self.deletedAt = deletedAt
    }

    private enum CodingKeys: String, CodingKey { case id, event, occurrence, deletedAt }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        event = try c.decode(LocalCalendarEvent.self, forKey: .event)
        occurrence = try c.decodeIfPresent(CivilDate.self, forKey: .occurrence)
        deletedAt = Date(timeIntervalSinceReferenceDate: try c.decode(Double.self, forKey: .deletedAt))
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(event, forKey: .event)
        try c.encodeIfPresent(occurrence, forKey: .occurrence)
        try c.encode(deletedAt.timeIntervalSinceReferenceDate, forKey: .deletedAt)
    }
}

public enum CalendarStoreError: Error, LocalizedError, Equatable {
    case unsupportedFormat(Int)
    case invalidState
    case noCompleteRevision
    case concurrentChange
    case locked
    case busy
    case staleConnection

    public var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let version):
            "Die Kalenderdaten (Format \(version)) stammen von einer neueren noty-Version. Sie bleiben unverändert; Änderungen am Kalender sind gesperrt."
        case .invalidState: "Die Kalenderdaten sind ungültig und wurden nicht gespeichert."
        case .noCompleteRevision: "Kein vollständiger, geprüfter Kalenderstand gefunden. Vorhandene Dateien bleiben erhalten; Änderungen am Kalender sind gesperrt."
        case .concurrentChange: "Die Kalenderdaten wurden inzwischen an anderer Stelle gespeichert. Damit nichts überschrieben wird, wurde nicht gespeichert. Bitte den Kalender neu öffnen."
        case .locked: "Der Kalender ist schreibgeschützt, weil seine Daten nicht sicher gelesen werden konnten."
        case .busy: "Der Kalender dieses Bereichs wird bereits an anderer Stelle bearbeitet."
        case .staleConnection: "Die Verbindung wurde inzwischen geändert; das Ergebnis wurde verworfen."
        }
    }
}
