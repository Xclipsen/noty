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

    /// Deterministic: the same change detected again has the same id (the
    /// history ignores it then), a further change of the same lesson a new one.
    public var id: String {
        let rooms = lesson.rooms.sorted().joined(separator: "+")
        let start = Int(lesson.start.timeIntervalSinceReferenceDate)
        return "change.\(lesson.key.sourceID).\(lesson.date).\(kinds.map(\.rawValue).joined(separator: "-")).\(start).\(rooms)"
    }

    public var primary: Kind { kinds.first ?? .substitution }

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
        return day(date, calendar: calendar) + ", " + clock
    }

    /// „Do 12.11.“
    static func day(_ date: Date, calendar: Calendar) -> String {
        let p = calendar.dateComponents([.month, .day], from: date)
        return "\(CalendarText.shortWeekdays[CalendarDates.weekdayIndex(date, calendar: calendar)]) \(p.day ?? 1).\(p.month ?? 1)."
    }
}

public enum CalendarChangeDetector {
    /// At most this many changes per comparison (a whole new timetable is
    /// no list of single changes; the rest is in the calendar itself).
    public static let maximumChanges = 100

    /// Days that both snapshots cover and that `new` fetched again later.
    public static func comparedDays(old: CalendarSourceSnapshot, new: CalendarSourceSnapshot) -> Set<CivilDate> {
        guard old.connection == new.connection else { return [] }
        var days = Set<CivilDate>()
        for (text, newTime) in new.days {
            guard let oldTime = old.days[text], newTime > oldTime, let day = CivilDate(text) else { continue }
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
            } else if !current.isCancelled, isIrregular(current) {
                // A new period with an explicit irregular status (Vertretung,
                // Zusatzstunde, verlegte Stunde with a new id). A new regular
                // period is no change worth a notification (new timetable).
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
