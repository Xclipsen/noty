import Foundation

// Benachrichtigungen (docs/CALENDAR-PLAN.md, 08.11.2026): changes of the
// WebUntis timetable between two offline snapshots. Pure comparison only;
// the app records the result in the bell history and posts notifications.
//
// Conservative by design (plan §7: „Timeout, Parsefehler oder Teilantwort
// sind keine leere Kalenderliste“; „außerhalb des Fensters ≠ gelöscht“):
//  - Only days that BOTH snapshots cover and that the new one fetched again
//    (strictly newer fetch time) are compared. A day only the new snapshot
//    has (window moved on, first fetch, new connection) yields nothing; a day
//    the new one dropped (pruned, window moved away) yields nothing.
//  - Lessons are matched by the stable WebUntis period id (`sourceID`), never
//    by title or time. A period id that occurs twice in either side is
//    ambiguous and skipped. A lesson that disappeared is NOT reported as
//    cancelled (WebUntis may represent changes differently; only an explicit
//    status counts). A period that moved to a day that is not compared is
//    skipped.
//  - A day that had lessons and comes back without any (an empty answer
//    of WebUntis) is treated as not fetched again. An `added` lesson needs
//    a base day with lessons: after an empty day, the lessons coming back
//    are no „zusätzlich“ (the push service also keeps such a day in its
//    comparison base: `CalendarSourceSnapshot.mergeKeepingEmptiedDays`).
//    Exception: a day whose periods turn up on another day fetched again
//    (same period id: the whole day was moved) is no empty answer; it is
//    compared, and its lessons are reported as „verlegt“.
//  - Only lessons that still start after `now` are reported.
//  - Only the explicit status is used. Which `is` values WebUntis really
//    delivers besides REGULAR is unverified (plan §7), so a school whose
//    answers differ yields fewer reports, never invented ones.

public struct CalendarLessonChange: Identifiable, Equatable, Sendable {
    public enum Kind: String, Sendable, Codable, CaseIterable, Comparable {
        case cancelled, reinstated, moved, roomChanged, substitution, added

        var rank: Int { Self.allCases.firstIndex(of: self) ?? 0 }
        public static func < (a: Kind, b: Kind) -> Bool { a.rank < b.rank }
    }

    /// Ordered by importance (cancelled first). `cancelled` stands alone.
    public var kinds: [Kind]
    /// The lesson as the new snapshot has it.
    public var lesson: CalendarLesson
    /// The lesson as the old snapshot had it (nil for `added`).
    public var previous: CalendarLesson?

    /// Title of a change notification and of its bell entry.
    public static let notificationTitle = "Stundenplanänderung"

    /// Deterministic: the same change detected again has the same id (the
    /// history ignores it then), a further change of the same lesson a new one.
    /// The same change again after a different one in between („Ausfall“ →
    /// „findet statt“ → „Ausfall“) is recorded as `id~2`, `id~3`, …
    /// (`CalendarChangeRepeats`); this id itself never carries the suffix.
    public var id: String {
        let rooms = lesson.rooms.sorted().map(Self.idRoom).joined(separator: "+")
        let start = Int(lesson.start.timeIntervalSinceReferenceDate)
        return "change.\(lesson.key.sourceID).\(lesson.date).\(kinds.map(\.rawValue).joined(separator: "-")).\(start).\(rooms)"
    }

    public var primary: Kind { kinds.first ?? .substitution }

    /// A room as written in the id: „~“ belongs to the repeat generation at
    /// the end (`CalendarChangeRepeats.separator`) and is written „%7E“, so
    /// a room such as „R~2“ is never read as generation 2. Every other room
    /// keeps the id it always had.
    static func idRoom(_ room: String) -> String {
        room.replacingOccurrences(of: CalendarChangeRepeats.separator, with: "%7E")
    }

    /// „Do 12.11., 08:00 Deutsch fällt aus“, „Fr 13.11., 09:45 Mathematik jetzt in R 112 (statt R 101)“.
    /// Subject, time and room only (lock screen).
    public func text(calendar: Calendar) -> String {
        let when = CalendarChangeText.when(lesson.start, calendar: calendar)
        let subject = lesson.title
        switch primary {
        case .cancelled:
            return "\(when) \(subject) fällt aus"
        case .reinstated:
            return "\(when) \(subject) findet wieder statt" + roomSuffix
        case .moved:
            let from = previous.map { " (statt " + CalendarChangeText.when($0.start, calendar: calendar, sameDayAs: lesson.start) + ")" } ?? ""
            return "\(subject) verlegt auf \(when)\(from)" + roomSuffix
        case .roomChanged:
            let old = previous.map { $0.rooms.isEmpty ? "" : " (statt \($0.rooms.joined(separator: ", ")))" } ?? ""
            return "\(when) \(subject) jetzt in \(lesson.rooms.joined(separator: ", "))\(old)"
        case .substitution:
            if let previous, previous.title != subject {
                return "\(when) \(subject) statt \(previous.title)" + roomSuffix
            }
            return "\(when) \(subject): Vertretung" + roomSuffix
        case .added:
            return "\(when) \(subject) zusätzlich" + roomSuffix
        }
    }

    /// „ in R 112“ when the room is part of the change (or the lesson is new/moved).
    private var roomSuffix: String {
        guard !lesson.rooms.isEmpty, kinds.contains(.roomChanged) || primary == .added || primary == .moved || primary == .reinstated
        else { return "" }
        return " in " + lesson.rooms.joined(separator: ", ")
    }
}

enum CalendarChangeText {
    /// „Do 12.11., 08:00“; with `sameDayAs` on the same day only „08:00“.
    static func when(_ date: Date, calendar: Calendar, sameDayAs other: Date? = nil) -> String {
        let clock = CalendarText.clock(date, calendar: calendar)
        if let other, calendar.isDate(date, inSameDayAs: other) { return clock }
        return CalendarText.shortDay(date, calendar: calendar) + ", " + clock
    }
}

public enum CalendarChangeDetector {
    /// At most this many changes per comparison (a whole new timetable is
    /// no list of single changes; the rest is in the calendar itself).
    public static let maximumChanges = 100

    /// Days that both snapshots cover and that `new` fetched again later.
    /// A day that had lessons in `old` and has none in `new` counts as not
    /// fetched again (an empty answer is no list of vanished lessons) –
    /// unless one of its periods is in `new` on another day fetched again:
    /// then the day was moved, not emptied.
    public static func comparedDays(old: CalendarSourceSnapshot, new: CalendarSourceSnapshot) -> Set<CivilDate> {
        guard old.connection == new.connection else { return [] }
        func refetched(_ text: String) -> Bool {
            guard let oldTime = old.days[text], let newTime = new.days[text] else { return false }
            return newTime > oldTime
        }
        let oldBusy = Set(old.lessons.map(\.date))
        let newBusy = Set(new.lessons.map(\.date))
        var newDays: [String: Set<CivilDate>] = [:]
        for lesson in new.lessons { newDays[lesson.key.sourceID, default: []].insert(lesson.date) }
        var days = Set<CivilDate>()
        for text in new.days.keys {
            guard refetched(text), let day = CivilDate(text) else { continue }
            if oldBusy.contains(day) && !newBusy.contains(day) {
                let movedAway = old.lessons.contains { lesson in
                    lesson.date == day && (newDays[lesson.key.sourceID]?.contains { $0 != day && refetched($0.description) } ?? false)
                }
                guard movedAway else { continue }
            }
            days.insert(day)
        }
        return days
    }

    /// Changes of future lessons between `old` and `new` (see the file
    /// comment). Nil `old` (first fetch, new connection) yields nothing.
    public static func changes(old: CalendarSourceSnapshot?, new: CalendarSourceSnapshot, now: Date,
                               calendar: Calendar) -> [CalendarLessonChange] {
        guard let old, old.connection == new.connection else { return [] }
        let today = CivilDate(now, calendar: calendar)
        let days = comparedDays(old: old, new: new).filter { $0 >= today }
        guard !days.isEmpty else { return [] }
        // Period ids anywhere in each snapshot (a period that moved to a day
        // that is not compared must not count as vanished or added).
        let oldAll = Dictionary(grouping: old.lessons, by: \.key.sourceID)
        let newAll = Dictionary(grouping: new.lessons, by: \.key.sourceID)
        // Days with lessons in the base: only there a new period is „zusätzlich“.
        let oldBusy = Set(old.lessons.map(\.date))
        var result: [CalendarLessonChange] = []
        var handled = Set<String>()
        func unique(_ group: [CalendarLesson]?) -> CalendarLesson? {
            guard let group, group.count == 1 else { return nil }
            return group[0]
        }
        for lesson in new.lessons where days.contains(lesson.date) {
            let id = lesson.key.sourceID
            guard handled.insert(id).inserted else { continue }
            guard let current = unique(newAll[id]), lesson.start > now else { continue }
            if let group = oldAll[id] {
                guard let before = unique(group), days.contains(before.date) else { continue }
                let kinds = differences(before, current)
                if !kinds.isEmpty { result.append(CalendarLessonChange(kinds: kinds, lesson: current, previous: before)) }
            } else if !current.isCancelled, isIrregular(current), oldBusy.contains(current.date) {
                // A new period with an explicit irregular status (Vertretung,
                // Zusatzstunde, verlegte Stunde with a new id) on a day that
                // had lessons before. A new regular period is no change worth
                // a notification (new timetable); a base day without lessons
                // (free day, or an empty answer of WebUntis before) is no
                // reference: the lessons coming back are not „zusätzlich“.
                result.append(CalendarLessonChange(kinds: [.added], lesson: current, previous: nil))
            }
        }
        result.sort { ($0.lesson.start, $0.lesson.key.sourceID) < ($1.lesson.start, $1.lesson.key.sourceID) }
        return Array(result.prefix(maximumChanges))
    }

    /// What changed from `old` to `new` of the same period, most important first.
    static func differences(_ old: CalendarLesson, _ new: CalendarLesson) -> [CalendarLessonChange.Kind] {
        if new.isCancelled { return old.isCancelled ? [] : [.cancelled] }
        var kinds: [CalendarLessonChange.Kind] = []
        if old.isCancelled { kinds.append(.reinstated) }
        if new.start != old.start { kinds.append(.moved) }
        // A room that is only missing now is no information (never „kein Raum“).
        if !new.rooms.isEmpty, Set(new.rooms) != Set(old.rooms) { kinds.append(.roomChanged) }
        let subjectChanged: Bool = {
            if let a = old.subjectID, let b = new.subjectID { return a != b }
            return old.title != new.title
        }()
        let teacherChanged = !old.teachers.isEmpty && !new.teachers.isEmpty && Set(old.teachers) != Set(new.teachers)
        let newlySubstituted = new.statuses.contains(.substitution) && !old.statuses.contains(.substitution)
        if subjectChanged || teacherChanged || newlySubstituted { kinds.append(.substitution) }
        return kinds.sorted()
    }

    static func isIrregular(_ lesson: CalendarLesson) -> Bool {
        lesson.statuses.contains { status in
            switch status {
            case .substitution, .roomChanged: true
            case .cancelled, .exam, .other: false
            }
        }
    }
}

// MARK: Change ids and repeats

/// The parts of a raw change id `change.<periode>.<YYYY-MM-DD>.<arten>.<beginn>.<räume>[~n]`
/// (`CalendarLessonChange.id`, optionally with the repeat generation). The
/// period and the rooms may contain dots; the rooms never decide where the
/// date is (the first part after the period that is a date). The generation
/// is only a final „~n“: a „~“ inside a room is written „%7E“ in ids
/// (`CalendarLessonChange.idRoom`, since 11.2026); older ids are read as before.
public struct CalendarChangeID: Equatable, Sendable {
    /// WebUntis period id (`CalendarLesson.key.sourceID`).
    public var period: String
    public var day: CivilDate
    /// Raw values of `CalendarLessonChange.Kind`, joined by „-“ in the id.
    public var kinds: [String]
    /// Start in whole seconds since 2001-01-01 (as in the id).
    public var start: Int
    /// Rooms as in the id („R 1.01+R 2“), possibly empty.
    public var rooms: String
    /// 1 for the plain id, n ≥ 2 for `…~n`.
    public var generation: Int

    public init?(_ raw: String) {
        guard raw.hasPrefix("change.") else { return nil }
        let parts = raw.dropFirst("change.".count).split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard let dateIndex = parts.indices.dropFirst().first(where: { CivilDate(parts[$0]) != nil }),
              parts.count >= dateIndex + 3, let day = CivilDate(parts[dateIndex]), let start = Int(parts[dateIndex + 2]) else { return nil }
        period = parts[..<dateIndex].joined(separator: ".")
        self.day = day
        kinds = parts[dateIndex + 1].split(separator: "-").map(String.init)
        self.start = start
        var rooms = parts[(dateIndex + 3)...].joined(separator: ".")
        generation = 1
        if let mark = rooms.lastIndex(of: Character(CalendarChangeRepeats.separator)) {
            let digits = rooms[rooms.index(after: mark)...]
            if (1...4).contains(digits.count), digits.allSatisfy({ $0.isASCII && $0.isNumber }), !digits.hasPrefix("0"),
               let value = Int(digits), value >= 2 {
                generation = value
                rooms = String(rooms[..<mark])
            }
        }
        self.rooms = rooms
    }

    /// The id without repeat generation (`CalendarLessonChange.id`).
    public var base: String {
        "change.\(period).\(day).\(kinds.joined(separator: "-")).\(start).\(rooms)"
    }

    /// The full id (with `~n` from generation 2 on).
    public var id: String { generation > 1 ? base + CalendarChangeRepeats.separator + String(generation) : base }

    /// The lesson the change belongs to (period and day).
    public var lessonKey: String { "\(period)|\(day)" }

    /// Ausfall, findet wieder statt or any other change.
    public var category: String {
        kinds.contains("cancelled") ? "cancelled" : kinds.contains("reinstated") ? "reinstated" : "changed"
    }
}

/// The same change of a lesson again after a different one in between
/// („Ausfall“ → „findet wieder statt“ → „Ausfall“) gets the same
/// `CalendarLessonChange.id` as the first time. Deduplicating by id alone
/// swallowed it; it is recorded as `id~2` (then `~3` …) instead. A change
/// that the newest entry of the same lesson already says is the same one
/// detected again and is not recorded. Ids of first occurrences stay as
/// they were. Used by the push service (its history) and the app (bell,
/// `CalendarNotificationLog.identifyingRepeats`), each within its own origin.
public enum CalendarChangeRepeats {
    public static let separator = "~"

    /// How a freshly detected change `id` (raw, `change.…`) is recorded,
    /// given the raw change ids recorded before by the same origin, oldest
    /// first. `isNew == false`: the newest earlier entry of the same lesson
    /// says the same (`id` is then that entry's id); else `id` is the id to
    /// record (`change.…` or `change.…~n`).
    public static func resolve(_ id: String, earlier: [String]) -> (id: String, isNew: Bool) {
        guard let change = CalendarChangeID(id) else { return (id, !earlier.contains(id)) }
        let base = change.base
        var newest: (id: String, base: String)?
        for other in earlier {
            guard let parsed = CalendarChangeID(other), parsed.lessonKey == change.lessonKey else { continue }
            newest = (other, parsed.base)
        }
        if let newest, newest.base == base { return (newest.id, false) }
        return (next(id, earlier: earlier), true)
    }

    /// `id` recorded as a further occurrence after `earlier` (same origin):
    /// the plain id the first time, else `…~n` with the next generation.
    public static func next(_ id: String, earlier: [String]) -> String {
        guard var change = CalendarChangeID(id) else { return id }
        let base = change.base
        let generation = earlier.compactMap(CalendarChangeID.init).filter { $0.base == base }.map(\.generation).max() ?? 0
        guard generation > 0 else { return base }
        change.generation = generation + 1
        return change.id
    }
}
