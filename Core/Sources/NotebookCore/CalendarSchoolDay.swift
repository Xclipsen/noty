import Foundation

// Live Activity „Schultag“ und Widget „Heute“ (docs/LIVE-ACTIVITY-PLAN.md).
// Pure parts: the lessons of one day as a compact list (`SchoolDayLesson`),
// the state at a moment (`SchoolDayContentState`, also the JSON contract of
// the push service: only standard Codable types, times as whole Unix
// seconds), the moments the state changes and when an activity has to be
// started, restarted (8-h limit) and ended. Derived data only: the source is
// the offline timetable (`CalendarSourceSnapshot`) of the shown area.

/// One lesson as the lock screen shows it. JSON keys = property names.
public struct SchoolDayLesson: Codable, Hashable, Sendable {
    /// „Mathematik“ (`CalendarLesson.title`), at most 40 characters.
    public var title: String
    /// Rooms joined with „, “; nil without room. At most 24 characters.
    public var room: String?
    /// Unix seconds (whole).
    public var start: Int
    public var end: Int
    /// „fällt aus“, „Vertretung“, „Raumwechsel“, „Vertretung, Raumwechsel“, „Prüfung“; nil for a regular lesson.
    public var note: String?
    /// The note is a change (shown red): cancelled, substitution or room change.
    public var changed: Bool
    public var cancelled: Bool
    /// Calendar entry id of the lesson (`CalendarLesson.id`) for the deep link; nil when unknown.
    public var entryID: String?

    public init(title: String, room: String? = nil, start: Int, end: Int, note: String? = nil, changed: Bool = false,
                cancelled: Bool = false, entryID: String? = nil) {
        self.title = title; self.room = room; self.start = start; self.end = end; self.note = note
        self.changed = changed; self.cancelled = cancelled; self.entryID = entryID
    }

    public static let maximumTitle = 40
    public static let maximumRoom = 24

    /// The lock-screen form of a timetable lesson.
    public init(lesson: CalendarLesson) {
        let statuses = lesson.statuses
        var notes: [String] = []
        if statuses.contains(.cancelled) { notes = ["fällt aus"] } else {
            if statuses.contains(.substitution) { notes.append("Vertretung") }
            if statuses.contains(.roomChanged) { notes.append("Raumwechsel") }
            if notes.isEmpty, statuses.contains(.exam) { notes.append("Prüfung") }
        }
        let changed = statuses.contains { status in
            switch status {
            case .cancelled, .substitution, .roomChanged: true
            case .exam, .other: false
            }
        }
        let rooms = lesson.rooms.compactMap(\.nilIfBlank).joined(separator: ", ")
        self.init(title: String(lesson.title.prefix(Self.maximumTitle)),
                  room: rooms.isEmpty ? nil : String(rooms.prefix(Self.maximumRoom)),
                  start: Int(lesson.start.timeIntervalSince1970.rounded(.down)),
                  end: Int(lesson.end.timeIntervalSince1970.rounded(.down)),
                  note: notes.isEmpty ? nil : notes.joined(separator: ", "),
                  changed: changed, cancelled: lesson.isCancelled,
                  entryID: lesson.id.count <= 200 ? lesson.id : nil)
    }

    var isValid: Bool { end >= start && !title.isEmpty }
}

/// What the day is doing at a moment. JSON values: "before", "lesson", "break", "free", "done".
public enum SchoolDayPhase: String, Codable, Hashable, Sendable {
    /// Before the first lesson that takes place.
    case before
    case lesson
    /// A short gap between two lessons (`break` in JSON).
    case pause = "break"
    /// Freistunde: a gap at least one lesson long, or a cancelled lesson in the gap.
    case free
    /// After the last lesson that takes place.
    case done
}

/// The immutable attributes of a „Schultag“ activity (ActivityKit
/// `attributes`; the app adds the ActivityKit conformance). JSON keys =
/// property names.
public struct SchoolDayAttributes: Codable, Hashable, Sendable {
    /// WebUntis connection (`CalendarConnectionRecord.id`, uppercase UUID string).
    public var connectionID: String
    /// Civil day „YYYY-MM-DD“ (Europe/Berlin).
    public var day: String
    public init(connectionID: String, day: String) { self.connectionID = connectionID; self.day = day }
}

/// The changing data of a „Schultag“ activity (ActivityKit `content-state`).
/// Synthesized Codable on purpose: APNs content-state is decoded with the
/// standard `JSONDecoder`, so every non-optional key must be sent; optional
/// keys may be left out. Times are whole Unix seconds.
public struct SchoolDayContentState: Codable, Hashable, Sendable {
    public static let currentVersion = 1
    /// Contract version (1).
    public var v: Int
    public var phase: SchoolDayPhase
    /// Since when the phase runs and when it ends (countdown `phaseStart...phaseEnd`).
    public var phaseStart: Int
    public var phaseEnd: Int
    /// `lesson`: the running lesson; otherwise nil.
    public var current: SchoolDayLesson?
    /// The next lesson: `before` → the first lesson that takes place; otherwise
    /// the first lesson (also a cancelled one) after the running one or after now.
    public var next: SchoolDayLesson?
    /// „Stunde 3/6“: the running lesson's number, otherwise the number of the
    /// next lesson that takes place (`count` when done). Cancelled lessons do not count.
    public var number: Int
    public var count: Int
    /// First start and last end of the lessons that take place (day progress).
    public var dayStart: Int
    public var dayEnd: Int

    public init(phase: SchoolDayPhase, phaseStart: Int, phaseEnd: Int, current: SchoolDayLesson?, next: SchoolDayLesson?,
                number: Int, count: Int, dayStart: Int, dayEnd: Int) {
        v = Self.currentVersion
        self.phase = phase; self.phaseStart = phaseStart; self.phaseEnd = phaseEnd; self.current = current; self.next = next
        self.number = number; self.count = count; self.dayStart = dayStart; self.dayEnd = dayEnd
    }

    /// True while the first lesson is still further away than the countdown
    /// range: `before` holds from midnight on, but `phaseStart` is only
    /// `CalendarSchoolDay.leadTime` before the lesson (the tile starts then).
    /// A countdown over `phaseStart...phaseEnd` would lie entirely in the
    /// future, so the widget „Heute“ shows the start time until `phaseStart`
    /// (a transition, so its timeline has an entry there).
    public func showsStartTime(at time: Int) -> Bool { phase == .before && time < phaseStart }

    /// The JSON as the push service sends it (ActivityKit: at most 4 KB with the attributes).
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }
}

/// When a „Schultag“ activity runs (Unix seconds).
public struct SchoolDayActivityPlan: Equatable, Sendable {
    /// 30 minutes before the first lesson that takes place.
    public var start: Int
    /// End of the last lesson that takes place (ended right away).
    public var end: Int
    /// iPadOS ends an activity after 8 h: at these moments the running one is
    /// ended and a new one started (every 7 h 45 min after `start`).
    public var restarts: [Int]
}

/// The state of a school day (pure; lessons of one civil day).
public struct CalendarSchoolDay: Equatable, Sendable {
    public static let leadTime = 30 * 60
    /// iPadOS keeps an activity at most 8 h; 15 minutes margin.
    public static let maximumRun = 8 * 3600 - 15 * 60
    /// A gap at least this long is a Freistunde even with the shortest lesson shorter.
    public static let minimumFreeGap = 30 * 60

    /// Lessons that take place, sorted, without exact duplicates (same start
    /// and end: parallel groups show the first).
    public let taking: [SchoolDayLesson]
    /// `taking` plus the cancelled lessons inside the day (shown as „fällt aus“).
    public let visible: [SchoolDayLesson]

    /// Nil without a lesson that takes place (weekend, holidays, all cancelled):
    /// no activity, the widget says „kein Unterricht“.
    public init?(lessons: [SchoolDayLesson]) {
        let valid = lessons.filter(\.isValid).sorted { ($0.start, $0.end, $0.title) < ($1.start, $1.end, $1.title) }
        var taking: [SchoolDayLesson] = []
        for lesson in valid where !lesson.cancelled {
            if taking.contains(where: { $0.start == lesson.start && $0.end == lesson.end }) { continue }
            taking.append(lesson)
        }
        guard let first = taking.first else { return nil }
        let end = taking.map(\.end).max() ?? first.end
        self.taking = taking
        let cancelled = valid.filter { lesson in
            lesson.cancelled && lesson.start >= first.start && lesson.start < end
                && !taking.contains { $0.start == lesson.start && $0.end == lesson.end }
        }
        var seen = Set<String>()
        visible = (taking + cancelled).sorted { ($0.start, $0.end, $0.title) < ($1.start, $1.end, $1.title) }
            .filter { seen.insert("\($0.start)|\($0.end)|\($0.title)|\($0.cancelled)").inserted }
    }

    /// The lessons of `day` from the offline timetable; nil when that day was
    /// never loaded (not „no lessons“).
    public static func lessons(snapshot: CalendarSourceSnapshot?, day: CivilDate) -> [SchoolDayLesson]? {
        guard let lessons = snapshot?.lessons(on: day) else { return nil }
        // Only lessons: a period without duration or over several days (WebUntis
        // events) is no lesson of the school day.
        return lessons.filter { $0.end > $0.start && $0.end.timeIntervalSince($0.start) <= 12 * 3600 }.map(SchoolDayLesson.init(lesson:))
    }

    public var dayStart: Int { taking[0].start }
    public var dayEnd: Int { taking.map(\.end).max() ?? taking[0].end }
    public var count: Int { taking.count }

    /// A gap at least as long as the shortest lesson (but at least 30 min) is
    /// a Freistunde; a long lunch break therefore counts as one as well.
    public var freeThreshold: Int {
        max(Self.minimumFreeGap, taking.map { $0.end - $0.start }.filter { $0 > 0 }.min() ?? 45 * 60)
    }

    public var plan: SchoolDayActivityPlan {
        let start = dayStart - Self.leadTime, end = dayEnd
        var restarts: [Int] = []
        var next = start + Self.maximumRun
        while next < end { restarts.append(next); next += Self.maximumRun }
        return SchoolDayActivityPlan(start: start, end: end, restarts: restarts)
    }

    /// Every moment the state changes, from the activity start to the end:
    /// start, each start/end of a lesson that takes place, each start of a
    /// cancelled lesson (the „Danach“ line moves on), end. Sorted, unique.
    public var transitions: [Int] {
        let start = dayStart - Self.leadTime, end = dayEnd
        var times = Set([start, end])
        for lesson in taking { times.insert(lesson.start); times.insert(lesson.end) }
        for lesson in visible where lesson.cancelled { times.insert(lesson.start) }
        return times.filter { $0 >= start && $0 <= end }.sorted()
    }

    /// The first transition after `time` (the moment the shown state is outdated).
    public func nextTransition(after time: Int) -> Int? { transitions.first { $0 > time } }

    /// The state at `time` (Unix seconds).
    public func state(at time: Int) -> SchoolDayContentState {
        let start = dayStart, end = dayEnd
        if time < start {
            return SchoolDayContentState(phase: .before, phaseStart: start - Self.leadTime, phaseEnd: start, current: nil, next: taking[0],
                                         number: 1, count: count, dayStart: start, dayEnd: end)
        }
        if time >= end {
            return SchoolDayContentState(phase: .done, phaseStart: end, phaseEnd: end, current: nil, next: nil,
                                         number: count, count: count, dayStart: start, dayEnd: end)
        }
        // Running: the lesson that started last (overlapping lessons: the newer one).
        if let index = taking.indices.last(where: { taking[$0].start <= time && time < taking[$0].end }) {
            let current = taking[index]
            let later = visible.filter { $0.start > current.start && $0 != current && $0.start > time }
            let next = later.first { $0.start >= current.end } ?? later.first
            return SchoolDayContentState(phase: .lesson, phaseStart: current.start, phaseEnd: current.end, current: current, next: next,
                                         number: index + 1, count: count, dayStart: start, dayEnd: end)
        }
        // Gap between two lessons (time < end, so one more lesson follows).
        let previousEnd = taking.map(\.end).filter { $0 <= time }.max() ?? start
        let nextIndex = taking.firstIndex { $0.start > time } ?? taking.count - 1
        let gapEnd = taking[nextIndex].start
        let cancelledInGap = visible.contains { $0.cancelled && $0.start < gapEnd && $0.end > previousEnd }
        let free = cancelledInGap || gapEnd - previousEnd >= freeThreshold
        let next = visible.first { $0.start > time }
        return SchoolDayContentState(phase: free ? .free : .pause, phaseStart: previousEnd, phaseEnd: gapEnd, current: nil, next: next,
                                     number: nextIndex + 1, count: count, dayStart: start, dayEnd: end)
    }

    public func state(at date: Date) -> SchoolDayContentState { state(at: Int(date.timeIntervalSince1970.rounded(.down))) }
}

/// The derived file the app writes into the App Group for the widget „Heute“
/// (`NotyWidgets/<Kanal>/schoolday.json`): the lessons of today and tomorrow
/// of the shown area, replaced after every refresh, removed without a
/// connection. Not a second store of calendar data: the widget only reads it.
public struct SchoolDayWidgetFile: Codable, Equatable, Sendable {
    public static let currentFormat = 1
    public static let maximumLessons = 40

    public struct Day: Codable, Equatable, Sendable {
        /// „YYYY-MM-DD“.
        public var day: String
        /// All lessons of the day (also cancelled ones); empty = loaded, no lessons.
        public var lessons: [SchoolDayLesson]
        public init(day: String, lessons: [SchoolDayLesson]) { self.day = day; self.lessons = lessons }
    }

    public var formatVersion = SchoolDayWidgetFile.currentFormat
    /// Channel and area (`CalendarNotificationHub.namespace`) of the writer.
    public var namespace: String
    public var connectionID: String
    /// When written (Unix seconds); the widget says „Stand …“.
    public var written: Int
    /// Only loaded days (a missing day was never loaded).
    public var days: [Day]

    public init(namespace: String, connectionID: String, written: Int, days: [Day]) {
        self.namespace = namespace; self.connectionID = connectionID; self.written = written
        self.days = days.map { Day(day: $0.day, lessons: Array($0.lessons.prefix(Self.maximumLessons))) }
    }

    /// Today and tomorrow of `snapshot` (loaded days only).
    public init(namespace: String, connectionID: UUID, snapshot: CalendarSourceSnapshot, now: Date, calendar: Calendar) {
        let today = CivilDate(now, calendar: calendar)
        var days: [Day] = []
        for day in [today, today.adding(days: 1)] {
            if let lessons = CalendarSchoolDay.lessons(snapshot: snapshot, day: day) {
                days.append(Day(day: day.description, lessons: lessons.sorted { ($0.start, $0.title) < ($1.start, $1.title) }))
            }
        }
        self.init(namespace: namespace, connectionID: connectionID.uuidString, written: Int(now.timeIntervalSince1970), days: days)
    }

    public func lessons(on day: CivilDate) -> [SchoolDayLesson]? { days.first { $0.day == day.description }?.lessons }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    /// Nil for unreadable bytes or another format (the widget then shows „App öffnen“).
    public static func decode(_ data: Data) -> SchoolDayWidgetFile? {
        guard data.count <= 200_000, let file = try? JSONDecoder().decode(SchoolDayWidgetFile.self, from: data),
              file.formatVersion == currentFormat else { return nil }
        return file
    }
}

/// What the widget „Heute“ shows at a moment: today's state, or after the
/// last lesson the start of tomorrow.
public enum SchoolDayWidgetContent: Equatable, Sendable {
    case notLoaded
    case noLessonsToday(tomorrow: SchoolDayLesson?)
    case today(SchoolDayContentState)
    /// Today is over; the first lesson of tomorrow (nil: none or not loaded).
    case doneToday(tomorrow: SchoolDayLesson?)

    public static func at(_ date: Date, file: SchoolDayWidgetFile?, calendar: Calendar) -> SchoolDayWidgetContent {
        guard let file else { return .notLoaded }
        let today = CivilDate(date, calendar: calendar)
        let tomorrow = file.lessons(on: today.adding(days: 1)).flatMap(CalendarSchoolDay.init(lessons:))?.taking.first
        guard let lessons = file.lessons(on: today) else { return .notLoaded }
        guard let day = CalendarSchoolDay(lessons: lessons) else { return .noLessonsToday(tomorrow: tomorrow) }
        let state = day.state(at: date)
        return state.phase == .done ? .doneToday(tomorrow: tomorrow) : .today(state)
    }

    /// Timeline moments of the widget from `date` on: now, every transition of
    /// today, and the next midnight (the day changes).
    public static func timeline(from date: Date, file: SchoolDayWidgetFile?, calendar: Calendar) -> [Date] {
        var result = [date]
        let today = CivilDate(date, calendar: calendar)
        let now = Int(date.timeIntervalSince1970)
        if let lessons = file?.lessons(on: today), let day = CalendarSchoolDay(lessons: lessons) {
            result += day.transitions.filter { $0 > now }.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        }
        result.append(today.adding(days: 1).start(in: calendar))
        return result
    }
}
