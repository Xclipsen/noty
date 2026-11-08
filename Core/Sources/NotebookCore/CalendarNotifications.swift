import Foundation

// Benachrichtigungen (docs/CALENDAR-PLAN.md, 08.11.2026). Pure parts of the
// notification system; the app (UserNotifications, BackgroundTasks) only
// hands the results to iPadOS and stores the history file.
//
//  - `CalendarNotificationSettings`: the user's choices (device preference,
//    not calendar data: not in the calendar package, not in backups).
//  - `CalendarOverview`: text of the „Morgen-Überblick“ of one day.
//  - `CalendarNotificationPlanner`: overviews of the next days plus the
//    reminders (`CalendarReminderPlanner`) within the pending budget.
//  - `CalendarNotificationLog`: the bell history (derived data per area).

public struct CalendarNotificationSettings: Codable, Equatable, Sendable {
    /// Stundenplanänderungen (WebUntis).
    public var changes = true
    /// Morgen-Überblick at `overviewMinute` (minutes after midnight, 6:45).
    public var overview = true
    public var overviewMinute = 6 * 60 + 45
    /// Erinnerung vor eigenen Terminen: timed own events without their own
    /// reminder use `eventMinutes`; an event's own reminder always wins.
    public var eventReminders = true
    public var eventMinutes = 15
    /// Ruhezeiten (21:00–06:00): no system notification for changes and
    /// lesson reminders; the overview moves to the end. Reminders of own
    /// events still come (set on purpose).
    public var quietHours = true
    public var quietStart = 21 * 60
    public var quietEnd = 6 * 60

    public init() {}

    public static let eventPresets = [5, 10, 15, 30, 60]

    /// Minutes of the day in `calendar` (wall clock).
    static func minuteOfDay(_ date: Date, calendar: Calendar) -> Int {
        let p = calendar.dateComponents([.hour, .minute], from: date)
        return (p.hour ?? 0) * 60 + (p.minute ?? 0)
    }

    /// True when `date` lies in the quiet hours (start inclusive, end exclusive;
    /// over midnight when start > end; none when start == end or switched off).
    public func isQuiet(_ date: Date, calendar: Calendar) -> Bool {
        guard quietHours, quietStart != quietEnd else { return false }
        let minute = Self.minuteOfDay(date, calendar: calendar)
        if quietStart < quietEnd { return minute >= quietStart && minute < quietEnd }
        return minute >= quietStart || minute < quietEnd
    }

    /// The overview time of `day`, moved to the end of the quiet hours when
    /// it falls into them; nil when that end is no longer on `day`.
    public func overviewTime(on day: CivilDate, calendar: Calendar) -> Date? {
        let start = day.start(in: calendar)
        guard let planned = calendar.date(bySettingHour: overviewMinute / 60, minute: overviewMinute % 60, second: 0, of: start) else { return nil }
        guard isQuiet(planned, calendar: calendar) else { return planned }
        guard let end = calendar.date(bySettingHour: quietEnd / 60, minute: quietEnd % 60, second: 0, of: start),
              end > planned, calendar.isDate(end, inSameDayAs: start) else { return nil }
        return end
    }

    public var isValid: Bool {
        let day = 0..<(24 * 60)
        return day.contains(overviewMinute) && day.contains(quietStart) && day.contains(quietEnd) && (0...1_440).contains(eventMinutes)
    }

    private enum CodingKeys: String, CodingKey {
        case changes, overview, overviewMinute, eventReminders, eventMinutes, quietHours, quietStart, quietEnd
    }
    /// Tolerant: missing or invalid keys keep the defaults.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T { (try? c.decodeIfPresent(T.self, forKey: key)) ?? fallback }
        let d = CalendarNotificationSettings()
        changes = value(.changes, d.changes); overview = value(.overview, d.overview)
        overviewMinute = value(.overviewMinute, d.overviewMinute)
        eventReminders = value(.eventReminders, d.eventReminders); eventMinutes = value(.eventMinutes, d.eventMinutes)
        quietHours = value(.quietHours, d.quietHours); quietStart = value(.quietStart, d.quietStart); quietEnd = value(.quietEnd, d.quietEnd)
        if !isValid { self = d }
    }
}

/// The „Morgen-Überblick“ of one day.
public enum CalendarOverview {
    /// Title and body for `day`, or nil when the day has neither lessons
    /// (loaded offline timetable) nor own/system events: no overview on
    /// weekends, holidays or free days. Homework appears only here.
    public static func content(day: CivilDate, state: CalendarState, snapshot: CalendarSourceSnapshot?,
                               systemEvents: [CalendarSystemEvent], calendar: Calendar) -> (title: String, body: String)? {
        let start = day.start(in: calendar)
        let end = day.adding(days: 1).start(in: calendar)
        var lines: [String] = []
        // Lessons only from a loaded day of the committed connection.
        let timetable = snapshot.flatMap { $0.connection == state.connection?.id ? $0 : nil }
        let lessons = (timetable?.lessons(on: day) ?? []).sorted { ($0.start, $0.id) < ($1.start, $1.id) }
        if !lessons.isEmpty {
            if let first = lessons.first(where: { !$0.isCancelled }) {
                var line = "Beginn \(CalendarText.clock(first.start, calendar: calendar)): \(first.title)"
                if !first.rooms.isEmpty { line += ", " + first.rooms.joined(separator: ", ") }
                lines.append(line)
            } else {
                lines.append("Alle Stunden fallen aus.")
            }
            let changed = lessons.filter { lesson in
                lesson.statuses.contains { status in
                    switch status {
                    case .cancelled, .substitution, .roomChanged: true
                    case .exam, .other: false
                    }
                }
            }
            if !changed.isEmpty && lessons.contains(where: { !$0.isCancelled }) {
                let parts = changed.prefix(3).map { lesson -> String in
                    let clock = CalendarText.clock(lesson.start, calendar: calendar)
                    if lesson.isCancelled { return "\(clock) \(lesson.title) fällt aus" }
                    if lesson.statuses.contains(.roomChanged), !lesson.rooms.isEmpty {
                        return "\(clock) \(lesson.title) in \(lesson.rooms.joined(separator: ", "))"
                    }
                    return "\(clock) \(lesson.title) Vertretung"
                }
                lines.append("Änderungen: " + parts.joined(separator: "; ") + (changed.count > 3 ? " (+\(changed.count - 3))" : ""))
            }
        }
        // Homework due on the day (open only, as the sidebar shows it).
        let homework = CalendarHomeworkItem.items(snapshot: timetable, marks: state.homeworkDone, source: state.connection?.source)
            .filter { !$0.done && $0.homework.due == day }
        if !homework.isEmpty {
            var subjects: [String] = []
            for item in homework {
                let name = item.homework.subject?.nilIfBlank ?? "ohne Fach"
                if !subjects.contains(name) { subjects.append(name) }
            }
            let names = subjects.prefix(4).joined(separator: ", ") + (subjects.count > 4 ? " …" : "")
            lines.append((homework.count == 1 ? "Hausaufgabe fällig: " : "\(homework.count) Hausaufgaben fällig: ") + names)
        }
        // Own events and visible system events of the day.
        var events: [(start: Date, allDay: Bool, title: String)] = []
        for occurrence in CalendarSeries.expand(state.events, from: day.adding(days: -31), to: day.adding(days: 1)).occurrences {
            let interval = occurrence.timing.interval(in: calendar)
            guard interval.start < end, interval.end > start || (interval.start >= start && interval.end == interval.start) else { continue }
            events.append((interval.start, occurrence.timing.isAllDay, occurrence.title))
        }
        for event in CalendarSystemMatching.visible(systemEvents, settings: state.settings.systemCalendars) where !event.cancelled {
            guard event.start < end, event.end > start || (event.start >= start && event.end == event.start) else { continue }
            events.append((event.start, event.allDay, event.title))
        }
        events.sort { ($0.allDay ? 0 : 1, $0.start, $0.title) < ($1.allDay ? 0 : 1, $1.start, $1.title) }
        if !events.isEmpty {
            let parts = events.prefix(3).map { ($0.allDay || $0.start < start ? "ganztägig" : CalendarText.clock($0.start, calendar: calendar)) + " " + $0.title }
            lines.append((events.count == 1 ? "Termin: " : "Termine: ") + parts.joined(separator: "; ") + (events.count > 3 ? " (+\(events.count - 3))" : ""))
        }
        guard !lessons.isEmpty || !events.isEmpty else { return nil }
        return ("Dein Tag · " + CalendarChangeText.day(start, calendar: calendar), lines.joined(separator: "\n"))
    }
}

public enum CalendarNotificationPlanner {
    /// Overviews are planned for today and the next days (they are planned
    /// first, so a full reminder budget never pushes them out).
    public static let overviewDays = 7

    /// Overviews of the next days, then the reminders, together at most
    /// `limit` pending requests (iPadOS keeps about 64 per app). Earliest
    /// first. `plannedUntil`/`deferred` describe the reminders.
    public static func plan(state: CalendarState, snapshot: CalendarSourceSnapshot?, systemEvents: [CalendarSystemEvent],
                            settings: CalendarNotificationSettings, namespace: String, now: Date, calendar: Calendar,
                            limit: Int = CalendarReminderPlanner.limit,
                            horizonDays: Int = CalendarReminderPlanner.horizonDays) -> CalendarReminderPlan {
        var overviews: [CalendarReminderRequest] = []
        let prefix = CalendarReminder.prefix + (namespace.isEmpty ? "" : namespace + ".")
        if settings.overview {
            let today = CivilDate(now, calendar: calendar)
            for offset in 0..<overviewDays {
                let day = today.adding(days: offset)
                guard let fire = settings.overviewTime(on: day, calendar: calendar), fire > now,
                      let content = CalendarOverview.content(day: day, state: state, snapshot: snapshot, systemEvents: systemEvents,
                                                             calendar: calendar) else { continue }
                overviews.append(CalendarReminderRequest(id: prefix + "overview.\(day)", kind: .overview, fireDate: fire,
                                                         title: content.title, body: content.body, day: day))
            }
        }
        let room = min(limit, max(0, limit - overviews.count))
        var plan = CalendarReminderPlan()
        if room > 0 {
            plan = CalendarReminderPlanner.plan(state: state, snapshot: snapshot, now: now, calendar: calendar, limit: room,
                                                horizonDays: horizonDays, namespace: namespace,
                                                eventDefaultMinutes: settings.eventReminders ? settings.eventMinutes : nil,
                                                eventsEnabled: settings.eventReminders,
                                                lessonQuiet: { settings.isQuiet($0, calendar: calendar) })
        }
        plan.requests = (plan.requests + overviews.prefix(limit)).sorted { ($0.fireDate, $0.id) < ($1.fireDate, $1.id) }
        return plan
    }
}

// MARK: Bell history

/// One entry of the bell history.
public struct CalendarNotificationRecord: Codable, Identifiable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case change, overview, event, lesson }
    /// The notification identifier (deterministic; the same id is kept once).
    public var id: String
    public var kind: Kind
    public var title: String
    public var body: String
    /// When it was detected or delivered.
    public var date: Date
    public var day: CivilDate?
    public var entryID: String?
    public var read = false

    public init(id: String, kind: Kind, title: String, body: String, date: Date, day: CivilDate? = nil, entryID: String? = nil, read: Bool = false) {
        self.id = id; self.kind = kind; self.title = title; self.body = body; self.date = date
        self.day = day; self.entryID = entryID; self.read = read
    }

    /// The history entry of a timetable change.
    public init(change: CalendarLessonChange, date: Date, calendar: Calendar, namespace: String) {
        let prefix = CalendarNotificationLog.changePrefix + (namespace.isEmpty ? "" : namespace + ".")
        self.init(id: prefix + change.id, kind: .change, title: "Stundenplanänderung", body: change.text(calendar: calendar),
                  date: date, day: change.lesson.date, entryID: change.lesson.id)
    }

    private enum CodingKeys: String, CodingKey { case id, kind, title, body, date, day, entryID, read }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        kind = try c.decode(Kind.self, forKey: .kind)
        title = try c.decode(String.self, forKey: .title)
        body = try c.decode(String.self, forKey: .body)
        date = Date(timeIntervalSinceReferenceDate: try c.decode(Double.self, forKey: .date))
        day = try c.decodeIfPresent(CivilDate.self, forKey: .day)
        entryID = try c.decodeIfPresent(String.self, forKey: .entryID)
        read = try c.decodeIfPresent(Bool.self, forKey: .read) ?? false
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(kind, forKey: .kind); try c.encode(title, forKey: .title)
        try c.encode(body, forKey: .body); try c.encode(date.timeIntervalSinceReferenceDate, forKey: .date)
        try c.encodeIfPresent(day, forKey: .day); try c.encodeIfPresent(entryID, forKey: .entryID)
        try c.encode(read, forKey: .read)
    }

    var isValid: Bool {
        (1...500).contains(id.count) && title.count <= 500 && body.count <= 5_000 && (entryID?.count ?? 0) <= 500
            && date.timeIntervalSinceReferenceDate.isFinite
    }
}

/// The bell history of one area: derived, replaceable data (a lost or
/// unreadable file is an empty history), newest first, bounded.
public struct CalendarNotificationLog: Codable, Equatable, Sendable {
    public static let currentFormat = 1
    public static let maximumRecords = 200
    public static let maximumDays = 60
    /// Identifier prefix of change notifications. Deliberately not under
    /// `CalendarReminder.prefix`: replacing the pending plan never removes
    /// a change notification that is about to be delivered.
    public static let changePrefix = "noty.calendar-change."

    public var formatVersion = CalendarNotificationLog.currentFormat
    public private(set) var records: [CalendarNotificationRecord] = []

    public init() {}

    public var unreadCount: Int { records.filter { !$0.read }.count }

    /// Adds the records whose id is not known yet (a change detected again,
    /// a delivered notification seen twice), drops old ones and returns
    /// the newly added records.
    @discardableResult
    public mutating func add(_ new: [CalendarNotificationRecord], now: Date) -> [CalendarNotificationRecord] {
        var known = Set(records.map(\.id))
        var added: [CalendarNotificationRecord] = []
        for record in new where record.isValid && known.insert(record.id).inserted { added.append(record) }
        records += added
        prune(now: now)
        let kept = Set(records.map(\.id))
        return added.filter { kept.contains($0.id) }
    }

    /// Newest first; at most `maximumRecords`, nothing older than `maximumDays`.
    public mutating func prune(now: Date) {
        let limit = now.addingTimeInterval(-Double(Self.maximumDays) * 86_400)
        records = records.filter { $0.date >= limit }
        records.sort { ($0.date, $0.id) > ($1.date, $1.id) }
        if records.count > Self.maximumRecords { records.removeLast(records.count - Self.maximumRecords) }
    }

    public mutating func markRead(_ id: String) {
        if let index = records.firstIndex(where: { $0.id == id }) { records[index].read = true }
    }
    public mutating func markAllRead() {
        for index in records.indices { records[index].read = true }
    }
    public mutating func removeAll() { records = [] }

    private enum CodingKeys: String, CodingKey { case formatVersion, records }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try c.decode(Int.self, forKey: .formatVersion)
        guard formatVersion == Self.currentFormat else { throw CalendarStoreError.unsupportedFormat(formatVersion) }
        // Single unreadable entries are dropped (derived data), never the rest.
        records = ((try? c.decode([Lenient].self, forKey: .records)) ?? []).compactMap(\.record).filter(\.isValid)
        var seen = Set<String>()
        records = records.filter { seen.insert($0.id).inserted }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(formatVersion, forKey: .formatVersion)
        try c.encode(records, forKey: .records)
    }

    private struct Lenient: Decodable {
        let record: CalendarNotificationRecord?
        init(from decoder: Decoder) throws { record = try? CalendarNotificationRecord(from: decoder) }
    }

    /// Reads a stored history: nil for a newer format (the app leaves that
    /// file alone), an empty history for unreadable bytes.
    public static func decode(_ data: Data) -> CalendarNotificationLog? {
        do { return try JSONDecoder().decode(CalendarNotificationLog.self, from: data) }
        catch CalendarStoreError.unsupportedFormat(let version) where version > currentFormat { return nil }
        catch { return CalendarNotificationLog() }
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }
}

extension CalendarLessonChange {
    /// One text for several changes found at once (one notification instead of a flood).
    public static func summary(_ changes: [CalendarLessonChange], calendar: Calendar) -> (title: String, body: String) {
        guard changes.count > 1 else { return ("Stundenplanänderung", changes.first?.text(calendar: calendar) ?? "") }
        let lines = changes.prefix(3).map { $0.text(calendar: calendar) }
        return ("\(changes.count) Stundenplanänderungen", lines.joined(separator: "\n") + (changes.count > 3 ? "\n…" : ""))
    }
}
