import Foundation

/// Where the hour grid of week and day starts (the hour at the top edge when
/// a period is shown). The rule, in this order:
///
/// 1. **Termine:** the earliest start of a timed entry on the shown days
///    (lessons, own and system events; all-day entries do not count), minus
///    30 minutes, rounded down to the full hour.
/// 2. **Heute läuft noch:** today is among the shown days and the current
///    time is before the end of today's last timed entry: the start moves on
///    to the current time minus one hour (full hour) – but never past the
///    start (minus 30 minutes) of an entry that is not over yet, neither
///    today's next or running one nor one on a later shown day. In a school
///    week this keeps tomorrow's first lesson in view; on the last school day
///    or in the day view the morning that is over scrolls away.
/// 3. **Keine Termine:** the current time minus one hour when today is
///    shown, otherwise 7:00 (a school morning).
///
/// Minutes count from the start of the entry's shown day and are clamped to
/// that day (an entry from the evening before starts at 0). The result is an
/// hour 0…23; the grid itself keeps the bottom edge at 24:00.
public enum CalendarScrollStart {
    /// A timed entry on one shown day.
    public struct Item: Equatable, Sendable {
        /// Index of the shown day (days in date order).
        public var day: Int
        /// Minutes from that day's start, 0…1440.
        public var start: Int
        public var end: Int

        public init(day: Int, start: Int, end: Int) {
            self.day = day; self.start = start; self.end = end
        }
    }

    /// Lead before the first entry and before an entry not over yet.
    public static let lead = 30
    /// Without entries and without today.
    public static let defaultHour = 7

    /// `today`: index of today among the shown days and the current minute
    /// of the day; nil when today is not shown.
    public static func hour(items: [Item], today: (day: Int, minute: Int)?) -> Int {
        let timed = items.map { Item(day: $0.day, start: clampMinute($0.start), end: clampMinute($0.end)) }
            .filter { $0.end > $0.start }
        guard let first = timed.map(\.start).min() else {
            guard let today else { return defaultHour }
            return clampHour(floorHour(today.minute - 60))
        }
        let base = clampHour(floorHour(first - lead))
        guard let today else { return base }
        guard let lastEnd = timed.filter({ $0.day == today.day }).map(\.end).max(), today.minute < lastEnd else { return base }
        var start = floorHour(today.minute - 60)
        let pending = timed.filter { $0.day > today.day || ($0.day == today.day && $0.end > today.minute) }.map(\.start)
        if let next = pending.min() { start = min(start, floorHour(next - lead)) }
        return clampHour(max(base, start))
    }

    /// The items of the shown `days` from entries given as (start, end) dates,
    /// each clamped to every shown day it touches.
    public static func items(days: [Date], entries: [(start: Date, end: Date)], calendar: Calendar) -> [Item] {
        var result: [Item] = []
        for (index, day) in days.enumerated() {
            let dayStart = calendar.startOfDay(for: day)
            guard let next = calendar.date(byAdding: .day, value: 1, to: dayStart) else { continue }
            for entry in entries where entry.end > dayStart && entry.start < next {
                let start = max(0, minutes(from: dayStart, to: entry.start, calendar: calendar))
                let end = min(24 * 60, entry.end >= next ? 24 * 60 : minutes(from: dayStart, to: entry.end, calendar: calendar))
                result.append(Item(day: index, start: start, end: end))
            }
        }
        return result
    }

    /// Wall-clock minutes (daylight saving days keep their clock hours).
    private static func minutes(from dayStart: Date, to date: Date, calendar: Calendar) -> Int {
        guard date > dayStart else { return 0 }
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        let sameDay = calendar.isDate(date, inSameDayAs: dayStart)
        return sameDay ? (parts.hour ?? 0) * 60 + (parts.minute ?? 0) : 24 * 60
    }

    private static func clampMinute(_ value: Int) -> Int { min(24 * 60, max(0, value)) }
    private static func floorHour(_ minute: Int) -> Int { Int((Double(minute) / 60).rounded(.down)) }
    private static func clampHour(_ hour: Int) -> Int { min(23, max(0, hour)) }
}
