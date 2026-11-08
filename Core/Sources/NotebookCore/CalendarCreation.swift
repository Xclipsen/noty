import Foundation

// Kalender, „Termin per Halten und Ziehen anlegen (08.11.2026)“
// (docs/CALENDAR-PLAN.md): the pure part of creating an event by holding
// on free space and dragging – quarter-hour cells of the time grid, the
// span from the pressed cell to the cell under the finger in either order,
// the day column with hysteresis, all-day day ranges, and wall clock →
// instant across daylight saving. No storage format is involved: a timed
// span over several days is an ordinary `CalendarEventTiming.timed`.

public enum CalendarCreation {
    /// Grid step and shortest span, in minutes.
    public static let step = 15
    public static let minimumMinutes = 15

    /// One quarter-hour cell of the time grid: day column (index into the
    /// shown days) and the cell's first minute (0, 15, …, 1425).
    public struct Cell: Equatable, Comparable, Sendable {
        public var day: Int
        public var minute: Int
        public init(day: Int, minute: Int) { self.day = day; self.minute = minute }
        public static func < (a: Cell, b: Cell) -> Bool { (a.day, a.minute) < (b.day, b.minute) }
    }

    /// A span over the shown days. `endMinute` is exclusive and may be 1440
    /// (midnight after `endDay`).
    public struct Span: Equatable, Sendable {
        public var startDay: Int
        public var startMinute: Int
        public var endDay: Int
        public var endMinute: Int
        public init(startDay: Int, startMinute: Int, endDay: Int, endMinute: Int) {
            self.startDay = startDay; self.startMinute = startMinute; self.endDay = endDay; self.endMinute = endMinute
        }
        /// Whether the span lies on more than one day column (ending at 24:00 does not count).
        public var spansDays: Bool { endDay > startDay && !(endDay == startDay + 1 && endMinute == 0) }
        /// The part of the span on day column `day` (minutes 0…1440), nil if none.
        public func segment(on day: Int) -> (start: Int, end: Int)? {
            guard day >= startDay, day <= endDay else { return nil }
            let start = day == startDay ? startMinute : 0
            let end = day == endDay ? endMinute : 24 * 60
            return end > start ? (start, end) : nil
        }
    }

    /// The cell under a point `minutes` into the day of column `day`
    /// (unsnapped, may lie above or below the day). Clamped to the day
    /// (0:00 … 23:45) and to the columns `0..<dayCount`.
    public static func cell(day: Int, minutes: Double, dayCount: Int) -> Cell {
        let column = min(max(0, day), max(0, dayCount - 1))
        let value = minutes.isFinite ? minutes : 0
        let snapped = Int((value / Double(step)).rounded(.down)) * step
        return Cell(day: column, minute: min(max(0, snapped), 24 * 60 - step))
    }

    /// From the pressed cell to the cell under the finger, both included and
    /// in either order: the earlier cell starts, the later one's end ends.
    /// Never shorter than one cell (`minimumMinutes`).
    public static func span(from anchor: Cell, to current: Cell) -> Span {
        let first = min(anchor, current), last = max(anchor, current)
        return Span(startDay: first.day, startMinute: first.minute, endDay: last.day, endMinute: last.minute + step)
    }

    /// The day column under `x` (measured from the first column). Leaving
    /// `current` needs `hysteresis` points beyond its edge, so a finger
    /// dragging along a column border does not flip the day. Clamped to
    /// `0..<count`.
    public static func column(x: Double, width: Double, count: Int, current: Int?, hysteresis: Double = 16) -> Int {
        guard count > 0, width > 0, x.isFinite else { return max(0, min(current ?? 0, max(0, count - 1))) }
        let raw = min(max(0, Int((x / width).rounded(.down))), count - 1)
        guard let current, current != raw, (0..<count).contains(current) else { return raw }
        let lower = Double(current) * width - hysteresis, upper = Double(current + 1) * width + hysteresis
        return x >= lower && x < upper ? current : raw
    }

    /// Inclusive range of day indices from the pressed day to the day under
    /// the finger, in either order, clamped to `0..<count`.
    public static func days(from anchor: Int, to current: Int, count: Int) -> ClosedRange<Int> {
        let limit = max(0, count - 1)
        let a = min(max(0, anchor), limit), b = min(max(0, current), limit)
        return min(a, b)...max(a, b)
    }

    /// The cell index under a point of a grid of `columns` × `rows` equal
    /// cells (month: day `row * 7 + column`), clamped to the grid.
    public static func gridIndex(x: Double, y: Double, cellWidth: Double, cellHeight: Double, columns: Int, rows: Int) -> Int {
        guard columns > 0, rows > 0, cellWidth > 0, cellHeight > 0, x.isFinite, y.isFinite else { return 0 }
        let column = min(max(0, Int((x / cellWidth).rounded(.down))), columns - 1)
        let row = min(max(0, Int((y / cellHeight).rounded(.down))), rows - 1)
        return row * columns + column
    }

    /// The instant whose wall clock on `day` shows `minute` (0…1440; 1440 =
    /// the start of the next day) – the grid places times by their wall
    /// clock. A time in a daylight-saving gap (02:30 on the last Sunday of
    /// March in Berlin) becomes the first moment after the gap (03:00); a
    /// repeated time (October) the first of the two.
    public static func instant(minute: Int, of day: Date, calendar: Calendar) -> Date {
        let start = calendar.startOfDay(for: day)
        let next = CalendarDates.day(1, after: start, calendar: calendar)
        guard minute > 0 else { return start }
        guard minute < 24 * 60 else { return next }
        func wall(_ date: Date) -> Int { CalendarDates.minutesIntoDay(date, day: start, calendar: calendar) }
        let parts = calendar.dateComponents([.year, .month, .day], from: start)
        if let date = calendar.date(from: DateComponents(year: parts.year, month: parts.month, day: parts.day,
                                                         hour: minute / 60, minute: minute % 60)),
           date > start, date < next, wall(date) == minute {
            // Repeated hour: the first occurrence.
            for back in [3_600.0, 1_800.0] {
                let earlier = date.addingTimeInterval(-back)
                if earlier > start, wall(earlier) == minute { return earlier }
            }
            return date
        }
        // In a gap: the first whole minute whose wall clock is at or after `minute`.
        var low = start, high = next
        while high.timeIntervalSince(low) > 60 {
            let half = (high.timeIntervalSince(low) / 120).rounded(.down) * 60
            let middle = low.addingTimeInterval(max(60, half))
            if wall(middle) >= minute { high = middle } else { low = middle }
        }
        return high
    }

    /// Start and end of `span` over the shown `days` (day starts). The end
    /// is always after the start, at least `minimumMinutes` (both ends in
    /// one daylight-saving gap would otherwise meet). Nil when the span lies
    /// outside the days.
    public static func dates(_ span: Span, days: [Date], calendar: Calendar) -> (start: Date, end: Date)? {
        guard days.indices.contains(span.startDay), days.indices.contains(span.endDay) else { return nil }
        let start = instant(minute: span.startMinute, of: days[span.startDay], calendar: calendar)
        var end = instant(minute: span.endMinute, of: days[span.endDay], calendar: calendar)
        if end.timeIntervalSince(start) < Double(minimumMinutes * 60) {
            end = calendar.date(byAdding: .minute, value: minimumMinutes, to: start) ?? start.addingTimeInterval(Double(minimumMinutes * 60))
        }
        return (start, end)
    }

    /// Placeholder text: „09:15–10:30“, „23:00–24:00“ (ends at midnight),
    /// „Mo 09:00 – Mi 11:00“ (over several days).
    public static func label(start: Date, end: Date, calendar: Calendar) -> String {
        let clockStart = CalendarText.clock(start, calendar: calendar)
        if calendar.isDate(start, inSameDayAs: end) { return "\(clockStart)–\(CalendarText.clock(end, calendar: calendar))" }
        let nextDay = CalendarDates.day(1, after: start, calendar: calendar)
        if end == nextDay { return "\(clockStart)–24:00" }
        let a = CalendarText.shortWeekdays[CalendarDates.weekdayIndex(start, calendar: calendar)]
        // A span ending at midnight belongs to the day before.
        let last = calendar.startOfDay(for: end) == end ? end.addingTimeInterval(-1) : end
        let b = CalendarText.shortWeekdays[CalendarDates.weekdayIndex(last, calendar: calendar)]
        let clockEnd = calendar.startOfDay(for: end) == end ? "24:00" : CalendarText.clock(end, calendar: calendar)
        return "\(a) \(clockStart) – \(b) \(clockEnd)"
    }

    /// All-day placeholder: „Ganztägig“, „Ganztägig · 3 Tage“.
    public static func allDayLabel(days: Int) -> String {
        days <= 1 ? "Ganztägig" : "Ganztägig · \(days) Tage"
    }
}
