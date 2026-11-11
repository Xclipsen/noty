import Foundation

// Kalender Stufe B2: repetitions of own events (daily, weekly, monthly), the
// end of a series (never, after n, until a date), single exceptions and
// single changed occurrences, and the bounded expansion of series into the
// occurrences of a shown range. Calendar math goes through civil dates and
// the series' time zone (wall clock kept across daylight saving), never
// fixed 24 × 60 × 60 seconds.

/// Repetition of an own event. The event's `timing` is the first occurrence.
public struct CalendarRecurrence: Equatable, Sendable, Codable {
    public enum Frequency: String, Codable, Sendable, CaseIterable {
        case daily, weekly, monthly
    }

    public enum End: Equatable, Sendable, Codable {
        case never
        /// Total number of occurrences generated, the first included (exceptions
        /// still count, like RFC 5545 COUNT with EXDATE).
        case afterCount(Int)
        /// Last possible original date, inclusive (series time zone).
        case until(CivilDate)

        private enum CodingKeys: String, CodingKey { case kind, count, date }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            switch try c.decode(String.self, forKey: .kind) {
            case "never": self = .never
            case "count": self = .afterCount(try c.decode(Int.self, forKey: .count))
            case "until": self = .until(try c.decode(CivilDate.self, forKey: .date))
            default: throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "Unbekanntes Serienende")
            }
        }
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .never: try c.encode("never", forKey: .kind)
            case .afterCount(let count): try c.encode("count", forKey: .kind); try c.encode(count, forKey: .count)
            case .until(let date): try c.encode("until", forKey: .kind); try c.encode(date, forKey: .date)
            }
        }
    }

    public static let maximumInterval = 99
    public static let maximumCount = 999
    public static let maximumExceptions = 2_000
    public static let maximumOverrides = 2_000

    public var frequency: Frequency
    /// Every n days/weeks/months (1 = every).
    public var interval: Int
    public var end: End
    /// Original dates removed from the series („Nur dieser Termin“ gelöscht).
    public var exceptions: [CivilDate]
    /// Occurrences changed on their own („Nur dieser Termin“ bearbeitet/verschoben).
    public var overrides: [CalendarOccurrenceOverride]

    public init(frequency: Frequency, interval: Int = 1, end: End = .never,
                exceptions: [CivilDate] = [], overrides: [CalendarOccurrenceOverride] = []) {
        self.frequency = frequency; self.interval = interval; self.end = end
        self.exceptions = exceptions; self.overrides = overrides
    }

    private enum CodingKeys: String, CodingKey { case frequency, interval, end, exceptions, overrides }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        frequency = try c.decode(Frequency.self, forKey: .frequency)
        interval = try c.decodeIfPresent(Int.self, forKey: .interval) ?? 1
        end = try c.decode(End.self, forKey: .end)
        exceptions = try c.decodeIfPresent([CivilDate].self, forKey: .exceptions) ?? []
        overrides = try c.decodeIfPresent([CalendarOccurrenceOverride].self, forKey: .overrides) ?? []
    }

    /// Structural checks against the first occurrence `timing`.
    public func validate(for timing: CalendarEventTiming) throws {
        guard (1...Self.maximumInterval).contains(interval),
              exceptions.count <= Self.maximumExceptions, Set(exceptions).count == exceptions.count,
              overrides.count <= Self.maximumOverrides, Set(overrides.map(\.originalDate)).count == overrides.count else {
            throw CalendarStoreError.invalidState
        }
        switch end {
        case .never: break
        case .afterCount(let count): guard (1...Self.maximumCount).contains(count) else { throw CalendarStoreError.invalidState }
        case .until(let date): guard date >= CalendarSeries.firstDate(of: timing) else { throw CalendarStoreError.invalidState }
        }
        for item in overrides {
            guard CalendarState.validTitle(item.title) == item.title, item.location.count <= 500, item.details.count <= 20_000,
                  item.timing.problem == nil else { throw CalendarStoreError.invalidState }
        }
    }

    /// „Wöchentlich“, „Alle 2 Wochen · bis 20.12.2026“, „Monatlich · 10 Mal“.
    public var text: String {
        var parts: [String]
        switch (frequency, interval) {
        case (.daily, 1): parts = ["Täglich"]
        case (.weekly, 1): parts = ["Wöchentlich"]
        case (.monthly, 1): parts = ["Monatlich"]
        case (.daily, let n): parts = ["Alle \(n) Tage"]
        case (.weekly, let n): parts = ["Alle \(n) Wochen"]
        case (.monthly, let n): parts = ["Alle \(n) Monate"]
        }
        switch end {
        case .never: break
        case .afterCount(let count): parts.append("\(count) Mal")
        case .until(let date): parts.append(String(format: "bis %02d.%02d.%04d", date.day, date.month, date.year))
        }
        return parts.joined(separator: " · ")
    }
}

/// One occurrence of a series changed on its own. `originalDate` is the
/// occurrence's date as the series generates it (its identity, also for notes).
public struct CalendarOccurrenceOverride: Equatable, Sendable, Codable {
    public var originalDate: CivilDate
    public var title: String
    public var location: String
    public var details: String
    public var timing: CalendarEventTiming

    public init(originalDate: CivilDate, title: String, location: String = "", details: String = "", timing: CalendarEventTiming) {
        self.originalDate = originalDate; self.title = title; self.location = location; self.details = details; self.timing = timing
    }
}

/// One shown occurrence of an own event (single event or one of a series).
public struct CalendarOccurrence: Equatable, Sendable {
    public var eventID: UUID
    /// The generated date of a series occurrence (identity); nil for single events.
    public var originalDate: CivilDate?
    public var title: String
    public var location: String
    public var details: String
    public var timing: CalendarEventTiming
    /// Changed on its own („Nur dieser Termin“).
    public var isOverride: Bool

    /// The note target of this occurrence (a series occurrence owns its notes).
    public var noteTarget: CalendarNoteTarget { .local(event: eventID, date: originalDate) }
}

public struct CalendarExpansion: Equatable, Sendable {
    public var occurrences: [CalendarOccurrence] = []
    /// Series whose occurrences in the range were not all produced (limit
    /// reached). Shown to the user, never cut silently.
    public var truncated: [UUID] = []
}

/// Generation of series dates and occurrences.
public enum CalendarSeries {
    /// At most this many occurrences of one series per expansion.
    public static let maximumPerSeries = 500
    /// At most this many generated dates are inspected per series.
    public static let maximumSteps = 20_000
    /// Longest range one expansion may cover.
    public static let maximumRangeDays = 800

    /// Civil date of the first occurrence (series time zone for timed events).
    public static func firstDate(of timing: CalendarEventTiming) -> CivilDate {
        switch timing {
        case .allDay(let start, _): return start
        case .timed(let start, _, let zone): return CivilDate(start, calendar: zoned(zone))
        }
    }

    static func zoned(_ identifier: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: identifier) ?? TimeZone(identifier: "UTC")!
        return calendar
    }

    /// The `index`-th generated date (0 = first), or nil when that month has
    /// no such day (a monthly series on the 31st skips shorter months).
    public static func date(_ index: Int, first: CivilDate, rule: CalendarRecurrence) -> CivilDate? {
        let step = index * rule.interval
        switch rule.frequency {
        case .daily: return first.adding(days: step)
        case .weekly: return first.adding(days: 7 * step)
        case .monthly:
            let months = first.year * 12 + (first.month - 1) + step
            return CivilDate(year: months / 12, month: months % 12 + 1, day: first.day)
        }
    }

    /// Generated position of `date` (ignoring exceptions and the series end),
    /// or nil when the series never generates it.
    static func index(of date: CivilDate, first: CivilDate, rule: CalendarRecurrence) -> Int? {
        guard date >= first else { return nil }
        switch rule.frequency {
        case .daily, .weekly:
            let unit = rule.frequency == .daily ? rule.interval : 7 * rule.interval
            let days = first.days(to: date)
            return days % unit == 0 ? days / unit : nil
        case .monthly:
            guard date.day == first.day else { return nil }
            let months = (date.year - first.year) * 12 + (date.month - first.month)
            return months % rule.interval == 0 ? months / rule.interval : nil
        }
    }

    /// Whether the series (with its end, without exceptions) generates `date`.
    public static func generates(_ date: CivilDate, timing: CalendarEventTiming, rule: CalendarRecurrence) -> Bool {
        let first = firstDate(of: timing)
        guard let index = index(of: date, first: first, rule: rule) else { return false }
        switch rule.end {
        case .never: return true
        case .until(let last): return date <= last
        case .afterCount(let count):
            // Skipped months do not count: count the real dates before `date`.
            guard rule.frequency == .monthly else { return index < count }
            var produced = 0
            for step in 0...index where Self.date(step, first: first, rule: rule) != nil {
                produced += 1
                if produced > count { return false }
            }
            return produced <= count
        }
    }

    /// The timing of the occurrence generated for `date`: the first
    /// occurrence's wall-clock start and end moved to that date in the
    /// series' time zone (daylight saving keeps the wall clock).
    public static func timing(on date: CivilDate, base: CalendarEventTiming) -> CalendarEventTiming {
        switch base {
        case .allDay(let start, let end):
            return .allDay(start: date, end: date.adding(days: start.days(to: end)))
        case .timed(let start, let end, let zone):
            let calendar = zoned(zone)
            let a = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: start)
            let b = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: end)
            let firstDay = CivilDate(start, calendar: calendar)
            let endDays = firstDay.days(to: CivilDate(end, calendar: calendar))
            let endDate = date.adding(days: endDays)
            let newStart = calendar.date(from: DateComponents(year: date.year, month: date.month, day: date.day,
                                                              hour: a.hour, minute: a.minute, second: a.second)) ?? start
            var newEnd = calendar.date(from: DateComponents(year: endDate.year, month: endDate.month, day: endDate.day,
                                                            hour: b.hour, minute: b.minute, second: b.second)) ?? end
            // A wall clock lost in a gap may end up before the start: keep the length.
            if newEnd <= newStart { newEnd = newStart.addingTimeInterval(end.timeIntervalSince(start)) }
            return .timed(start: newStart, end: newEnd, timeZone: zone)
        }
    }

    /// Length in civil days a single occurrence may reach back into the range.
    static func spanDays(_ timing: CalendarEventTiming) -> Int {
        switch timing {
        case .allDay(let start, let end): return max(1, start.days(to: end))
        case .timed(let start, let end, let zone):
            let calendar = zoned(zone)
            return CivilDate(start, calendar: calendar).days(to: CivilDate(end, calendar: calendar)) + 1
        }
    }

    /// Occurrences of `events` that may touch the civil range [start, end)
    /// (callers filter exactly by their own interval). Bounded per series and
    /// by `maximumRangeDays`; what was not produced is reported in `truncated`.
    public static func expand(_ events: [LocalCalendarEvent], from start: CivilDate, to end: CivilDate) -> CalendarExpansion {
        var result = CalendarExpansion()
        let rangeEnd = start.days(to: end) > maximumRangeDays ? start.adding(days: maximumRangeDays) : end
        for event in events {
            guard let rule = event.recurrence else {
                result.occurrences.append(CalendarOccurrence(eventID: event.id, originalDate: nil, title: event.title,
                    location: event.location, details: event.details, timing: event.timing, isOverride: false))
                continue
            }
            var truncated = rangeEnd != end
            let first = firstDate(of: event.timing)
            let slack = spanDays(event.timing) + 1
            let excluded = Set(rule.exceptions)
            var overrides: [CivilDate: CalendarOccurrenceOverride] = [:]
            for item in rule.overrides { overrides[item.originalDate] = item }
            let windowStart = start.adding(days: -slack)
            let windowEnd = rangeEnd.adding(days: 1)
            // Jump close to the range (count ends start at 0: produced dates count).
            var index = 0
            if case .afterCount = rule.end {} else {
                switch rule.frequency {
                case .daily, .weekly:
                    let unit = rule.frequency == .daily ? rule.interval : 7 * rule.interval
                    index = max(0, first.days(to: windowStart) / unit)
                case .monthly:
                    let months = (windowStart.year - first.year) * 12 + (windowStart.month - first.month) - 1
                    index = max(0, months / rule.interval)
                }
            }
            var produced = 0, shown = 0, steps = 0
            while true {
                if steps >= maximumSteps { truncated = true; break }
                steps += 1
                guard let day = Self.date(index, first: first, rule: rule) else {
                    // Skipped month: keeps going; the date after it may still fit.
                    if Self.date(index + 1, first: first, rule: rule).map({ $0 >= windowEnd }) == true { break }
                    index += 1; continue
                }
                index += 1
                if case .afterCount(let count) = rule.end {
                    produced += 1
                    if produced > count { break }
                }
                if case .until(let last) = rule.end, day > last { break }
                if day >= windowEnd { break }
                guard day >= windowStart, !excluded.contains(day), overrides[day] == nil else { continue }
                if shown >= maximumPerSeries { truncated = true; break }
                shown += 1
                result.occurrences.append(CalendarOccurrence(eventID: event.id, originalDate: day, title: event.title,
                    location: event.location, details: event.details, timing: timing(on: day, base: event.timing), isOverride: false))
            }
            // Changed occurrences may have moved far from their original date.
            for item in rule.overrides.sorted(by: { $0.originalDate < $1.originalDate })
            where !excluded.contains(item.originalDate) && generates(item.originalDate, timing: event.timing, rule: rule) {
                let day = firstDate(of: item.timing)
                guard day < windowEnd, day.adding(days: spanDays(item.timing)) >= start else { continue }
                result.occurrences.append(CalendarOccurrence(eventID: event.id, originalDate: item.originalDate, title: item.title,
                    location: item.location, details: item.details, timing: item.timing, isOverride: true))
            }
            if truncated { result.truncated.append(event.id) }
        }
        return result
    }

    /// The series after a change of „Alle Termine“ that moved the first
    /// occurrence by `days`: exceptions and changed occurrences move along,
    /// so they keep meaning the same occurrences.
    /// The plain day shift – right for daily and weekly series only; a
    /// monthly series is moved by occurrence (`CalendarSeries.moved`).
    public static func shifted(_ rule: CalendarRecurrence, byDays days: Int) -> CalendarRecurrence {
        guard days != 0 else { return rule }
        var next = rule
        next.exceptions = rule.exceptions.map { $0.adding(days: days) }
        next.overrides = rule.overrides.map { var item = $0; item.originalDate = item.originalDate.adding(days: days); return item }
        if case .until(let last) = rule.end { next.end = .until(last.adding(days: days)) }
        return next
    }
}
