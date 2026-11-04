import Foundation

// Kalender Stufe B3: which reminders the app hands to iPadOS. Pure planning
// only; the app (UserNotifications) adds and removes the requests. iPadOS
// keeps about 64 pending local notifications per app, so the plan is a
// rolling window: the earliest reminders up to `limit`, one deterministic
// identifier per occurrence (the same occurrence always replaces its own
// request, never a duplicate), no repeating triggers. Rescheduled on app
// activation, after a WebUntis refresh and after every change.

public enum CalendarReminder {
    /// Minutes before the start of an own event: zum Beginn, 5, 10, 15, 30
    /// Minuten, 1 Stunde, 1 Tag.
    public static let presets = [0, 5, 10, 15, 30, 60, 1_440]
    /// „Unterricht: Erinnerung X Minuten vorher“.
    public static let lessonPresets = [5, 10, 15, 30, 60]
    /// All-day events are reminded relative to this wall-clock time of their
    /// first day (09:00), not to midnight.
    public static let allDayHour = 9
    /// Identifier prefix of every calendar request (the app removes pending
    /// requests with this prefix that the current plan no longer contains).
    public static let prefix = "noty.calendar."

    /// „Zum Beginn“, „10 Minuten vorher“, „1 Stunde vorher“, „1 Tag vorher“.
    public static func text(_ minutes: Int) -> String {
        switch minutes {
        case 0: "Zum Beginn"
        case 60: "1 Stunde vorher"
        case 1_440: "1 Tag vorher"
        default: "\(minutes) Minuten vorher"
        }
    }

    /// When the reminder of `timing` fires. A day before keeps the wall
    /// clock (calendar day in the event's time zone, daylight saving safe);
    /// minutes are exact intervals before the absolute start.
    public static func fireDate(_ timing: CalendarEventTiming, minutes: Int, calendar: Calendar) -> Date? {
        switch timing {
        case .timed(let start, _, let zone):
            if minutes == 1_440 {
                var zoned = calendar
                zoned.timeZone = TimeZone(identifier: zone) ?? calendar.timeZone
                return zoned.date(byAdding: .day, value: -1, to: start)
            }
            return start.addingTimeInterval(-Double(minutes) * 60)
        case .allDay(let first, _):
            let day = first.start(in: calendar)
            guard let reference = calendar.date(bySettingHour: allDayHour, minute: 0, second: 0, of: day) else { return nil }
            if minutes == 1_440 { return calendar.date(byAdding: .day, value: -1, to: reference) }
            return reference.addingTimeInterval(-Double(minutes) * 60)
        }
    }
}

public struct CalendarReminderRequest: Equatable, Sendable {
    public enum Kind: String, Sendable { case event, lesson }
    /// Deterministic per occurrence (`noty.calendar.event.<id>.<date>` /
    /// `noty.calendar.lesson.<period>.<date>`); never contains a fire time.
    public let id: String
    public let kind: Kind
    public let fireDate: Date
    public let title: String
    public let body: String
}

public struct CalendarReminderPlan: Equatable, Sendable {
    /// Earliest first, at most `limit`.
    public var requests: [CalendarReminderRequest] = []
    /// Reminders before this instant are all planned („Erinnerungen geplant
    /// bis …“); nil when no reminder is switched on at all.
    public var plannedUntil: Date?
    /// Reminders inside the horizon left for a later reschedule (cap).
    public var deferred = 0
}

public enum CalendarReminderPlanner {
    /// Below the iPadOS limit of about 64 pending requests per app, leaving
    /// room for the app's other reminders (signing profile).
    public static let limit = 50
    /// How far ahead reminders are planned at most.
    public static let horizonDays = 30

    /// The reminders of `state` (own events with a reminder, lessons of the
    /// offline timetable when the lesson setting is on; cancelled lessons
    /// never) that fire after `now` and within the horizon. `snapshot` only
    /// counts when it belongs to the committed connection.
    public static func plan(state: CalendarState, snapshot: CalendarSourceSnapshot?, now: Date, calendar: Calendar,
                            limit: Int = limit, horizonDays: Int = horizonDays) -> CalendarReminderPlan {
        let eventsOn = state.events.contains { $0.reminderMinutes != nil }
        let lessonMinutes = state.settings.lessonReminderMinutes
        guard eventsOn || lessonMinutes != nil else { return CalendarReminderPlan() }
        let horizon = calendar.date(byAdding: .day, value: horizonDays, to: now) ?? now.addingTimeInterval(Double(horizonDays) * 86_400)
        var candidates: [CalendarReminderRequest] = []
        if eventsOn {
            let today = CivilDate(now, calendar: calendar)
            // Occurrences starting up to a day after the horizon may still fire inside it.
            let expansion = CalendarSeries.expand(state.events.filter { $0.reminderMinutes != nil },
                                                  from: today.adding(days: -2), to: today.adding(days: horizonDays + 3))
            let minutes = Dictionary(state.events.map { ($0.id, $0.reminderMinutes) }, uniquingKeysWith: { a, _ in a })
            for occurrence in expansion.occurrences {
                guard let offset = minutes[occurrence.eventID] ?? nil,
                      let fire = CalendarReminder.fireDate(occurrence.timing, minutes: offset, calendar: calendar),
                      fire > now, fire < horizon else { continue }
                let interval = occurrence.timing.interval(in: calendar)
                var body = CalendarText.numericDate(interval.start, calendar: calendar) + " · "
                    + (occurrence.timing.isAllDay ? "ganztägig" : CalendarText.timeRange(interval.start, interval.end, calendar: calendar))
                if !occurrence.location.isEmpty { body += " · " + occurrence.location }
                candidates.append(CalendarReminderRequest(
                    id: CalendarReminder.prefix + "event.\(occurrence.eventID.uuidString).\(occurrence.originalDate?.description ?? "single")",
                    kind: .event, fireDate: fire, title: occurrence.title, body: body))
            }
        }
        if let lessonMinutes, let snapshot, snapshot.connection == state.connection?.id {
            var seen = Set<String>()
            for lesson in snapshot.lessons where !lesson.isCancelled {
                let fire = lesson.start.addingTimeInterval(-Double(lessonMinutes) * 60)
                guard fire > now, fire < horizon else { continue }
                let id = CalendarReminder.prefix + "lesson.\(lesson.key.sourceID).\(lesson.date)"
                guard seen.insert(id).inserted else { continue }
                var body = "Unterricht " + CalendarText.numericDate(lesson.start, calendar: calendar) + " · "
                    + CalendarText.timeRange(lesson.start, lesson.end, calendar: calendar)
                if !lesson.rooms.isEmpty { body += " · Raum " + lesson.rooms.joined(separator: ", ") }
                candidates.append(CalendarReminderRequest(id: id, kind: .lesson, fireDate: fire, title: lesson.title, body: body))
            }
        }
        candidates.sort { ($0.fireDate, $0.id) < ($1.fireDate, $1.id) }
        var plan = CalendarReminderPlan()
        guard candidates.count > limit else {
            plan.requests = candidates
            plan.plannedUntil = horizon
            return plan
        }
        // Everything before the first reminder that does not fit is planned:
        // reminders at the same instant as the cut are left out together, so
        // „geplant bis“ is exact.
        let cut = candidates[limit].fireDate
        var kept = candidates.prefix(limit).filter { $0.fireDate < cut }
        if kept.isEmpty { kept = Array(candidates.prefix(limit)) }
        plan.requests = Array(kept)
        plan.plannedUntil = kept.count == limit && kept.last!.fireDate == cut ? kept.last!.fireDate : cut
        plan.deferred = candidates.count - kept.count
        return plan
    }
}
