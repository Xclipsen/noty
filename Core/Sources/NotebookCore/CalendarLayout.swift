import Foundation

// Platform-independent date and layout logic of the calendar views
// (docs/CALENDAR-PLAN.md, Stufe A). No events, storage or providers here:
// the views project whatever occurrences they are given. Day and week
// arithmetic always goes through `Calendar`, never fixed 24 × 60 × 60 seconds.

/// Shown range of the calendar.
public enum CalendarMode: String, CaseIterable, Sendable, Identifiable {
    case year, month, week, day
    public var id: String { rawValue }
    /// Segment order of the toolbar: „Jahr · Monat · Woche · Tag“.
    public var title: String {
        switch self {
        case .year: "Jahr"
        case .month: "Monat"
        case .week: "Woche"
        case .day: "Tag"
        }
    }
}

public enum CalendarDates {
    /// German calendar: ISO 8601 (Monday first, ISO week numbers, week 1
    /// contains the first Thursday), `de_DE`.
    public static func german(timeZone: TimeZone = .current) -> Calendar {
        var calendar = Calendar(identifier: .iso8601)
        calendar.locale = Locale(identifier: "de_DE")
        calendar.timeZone = timeZone
        calendar.firstWeekday = 2
        calendar.minimumDaysInFirstWeek = 4
        return calendar
    }

    /// 0 = Monday … 6 = Sunday, independent of the calendar's `firstWeekday`.
    public static func weekdayIndex(_ date: Date, calendar: Calendar) -> Int {
        (calendar.component(.weekday, from: date) + 5) % 7
    }

    /// Start of the day `offset` days after `day`'s start. A missing midnight
    /// (DST at 00:00) yields the first existing moment of that day.
    public static func day(_ offset: Int, after day: Date, calendar: Calendar) -> Date {
        let start = calendar.startOfDay(for: day)
        guard offset != 0 else { return start }
        // Noon never falls into a DST gap; adding days keeps the wall clock.
        let noon = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: start) ?? start
        let moved = calendar.date(byAdding: .day, value: offset, to: noon) ?? noon
        return calendar.startOfDay(for: moved)
    }

    /// Monday of the ISO week containing `date`.
    public static func startOfWeek(_ date: Date, calendar: Calendar) -> Date {
        day(-weekdayIndex(date, calendar: calendar), after: date, calendar: calendar)
    }

    /// Day starts of the shown week: Monday–Friday (`count` 5) or Monday–Sunday (7).
    public static func weekDays(containing date: Date, count: Int, calendar: Calendar) -> [Date] {
        let monday = startOfWeek(date, calendar: calendar)
        return (0..<max(1, min(7, count))).map { day($0, after: monday, calendar: calendar) }
    }

    /// ISO week number and its week-based year (28.12.2026 → 53/2026, 1.1.2027 → 53/2026).
    public static func isoWeek(_ date: Date, calendar: Calendar) -> (week: Int, year: Int) {
        (calendar.component(.weekOfYear, from: date), calendar.component(.yearForWeekOfYear, from: date))
    }

    public static func startOfMonth(_ date: Date, calendar: Calendar) -> Date {
        let parts = calendar.dateComponents([.year, .month], from: date)
        return calendar.date(from: DateComponents(year: parts.year, month: parts.month, day: 1))
            .map { calendar.startOfDay(for: $0) } ?? calendar.startOfDay(for: date)
    }

    public static func startOfYear(_ date: Date, calendar: Calendar) -> Date {
        let year = calendar.component(.year, from: date)
        return calendar.date(from: DateComponents(year: year, month: 1, day: 1))
            .map { calendar.startOfDay(for: $0) } ?? calendar.startOfDay(for: date)
    }

    /// Day starts of the month containing `date` (28–31 entries).
    public static func monthDays(_ date: Date, calendar: Calendar) -> [Date] {
        let first = startOfMonth(date, calendar: calendar)
        let count = calendar.range(of: .day, in: .month, for: first)?.count ?? 30
        return (0..<count).map { day($0, after: first, calendar: calendar) }
    }

    /// The twelve month starts of `date`'s calendar year.
    public static func yearMonths(_ date: Date, calendar: Calendar) -> [Date] {
        let first = startOfYear(date, calendar: calendar)
        return (0..<12).compactMap { month in
            calendar.date(byAdding: .month, value: month, to: first).map { startOfMonth($0, calendar: calendar) }
        }
    }

    /// Back/forward: one year, month, week or day. Month steps clamp the day
    /// (31.1. → 28./29.2.); the anchor keeps its day position otherwise.
    public static func shift(_ date: Date, mode: CalendarMode, by steps: Int, calendar: Calendar) -> Date {
        let anchor = calendar.startOfDay(for: date)
        switch mode {
        case .day: return day(steps, after: anchor, calendar: calendar)
        case .week: return day(7 * steps, after: anchor, calendar: calendar)
        case .month, .year:
            let noon = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: anchor) ?? anchor
            let moved = calendar.date(byAdding: mode == .month ? .month : .year, value: steps, to: noon) ?? noon
            return calendar.startOfDay(for: moved)
        }
    }

    /// First and exclusive last day start of what a mode shows around `anchor`.
    /// The month range is the month itself, not the padded grid.
    public static func range(_ mode: CalendarMode, anchor: Date, weekDays count: Int, calendar: Calendar) -> (start: Date, end: Date) {
        switch mode {
        case .day:
            let start = calendar.startOfDay(for: anchor)
            return (start, day(1, after: start, calendar: calendar))
        case .week:
            let days = weekDays(containing: anchor, count: count, calendar: calendar)
            return (days[0], day(1, after: days[days.count - 1], calendar: calendar))
        case .month:
            let start = startOfMonth(anchor, calendar: calendar)
            let next = calendar.date(byAdding: .month, value: 1, to: start).map { startOfMonth($0, calendar: calendar) } ?? start
            return (start, next)
        case .year:
            let start = startOfYear(anchor, calendar: calendar)
            let next = calendar.date(byAdding: .year, value: 1, to: start).map { startOfYear($0, calendar: calendar) } ?? start
            return (start, next)
        }
    }

    /// Wall-clock position of `date` in the 24-hour grid of `day`, in minutes
    /// 0…1440. Before the day → 0, from the next day on → 1440. On DST days
    /// the grid keeps 24 rows; times are placed by their wall clock.
    public static func minutesIntoDay(_ date: Date, day: Date, calendar: Calendar) -> Int {
        let start = calendar.startOfDay(for: day)
        if date <= start { return 0 }
        if date >= self.day(1, after: start, calendar: calendar) { return 24 * 60 }
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return min(24 * 60, max(0, (parts.hour ?? 0) * 60 + (parts.minute ?? 0)))
    }

    /// Whether a timed occurrence `[start, end)` touches `day`. A zero-length
    /// occurrence belongs to the day it starts on.
    public static func timed(start: Date, end: Date, touches day: Date, calendar: Calendar) -> Bool {
        let dayStart = calendar.startOfDay(for: day)
        let next = self.day(1, after: dayStart, calendar: calendar)
        if end <= start { return start >= dayStart && start < next }
        return start < next && end > dayStart
    }

    /// All-day occurrences use civil day starts with an exclusive end day.
    public static func allDay(start: Date, endExclusive: Date, covers day: Date, calendar: Calendar) -> Bool {
        let value = calendar.startOfDay(for: day)
        let first = calendar.startOfDay(for: start)
        let end = max(calendar.startOfDay(for: endExclusive), self.day(1, after: first, calendar: calendar))
        return value >= first && value < end
    }

    /// Number of civil days between the days of two dates (DST-safe). Counted
    /// noon to noon: a day without midnight starts at 01:00, and 01:00 to the
    /// next midnight is less than one calendar day.
    public static func days(from start: Date, to end: Date, calendar: Calendar) -> Int {
        func noon(_ date: Date) -> Date {
            let day = calendar.startOfDay(for: date)
            return calendar.date(bySettingHour: 12, minute: 0, second: 0, of: day) ?? day
        }
        return calendar.dateComponents([.day], from: noon(start), to: noon(end)).day ?? 0
    }
}

/// Month grid in whole ISO weeks (Monday–Sunday), 4–6 rows.
public struct CalendarMonthGrid: Sendable, Equatable {
    public struct Week: Sendable, Equatable {
        public let number: Int
        public let days: [Date]
    }
    public let month: Date
    public let weeks: [Week]

    public init(month date: Date, calendar: Calendar) {
        let first = CalendarDates.startOfMonth(date, calendar: calendar)
        let days = CalendarDates.monthDays(first, calendar: calendar)
        let last = days.last ?? first
        var monday = CalendarDates.startOfWeek(first, calendar: calendar)
        var weeks: [Week] = []
        while monday <= last && weeks.count < 6 {
            let row = (0..<7).map { CalendarDates.day($0, after: monday, calendar: calendar) }
            weeks.append(Week(number: CalendarDates.isoWeek(monday, calendar: calendar).week, days: row))
            monday = CalendarDates.day(7, after: monday, calendar: calendar)
        }
        self.month = first
        self.weeks = weeks
    }

    public func contains(_ day: Date, calendar: Calendar) -> Bool {
        calendar.isDate(day, equalTo: month, toGranularity: .month)
    }
}

/// Side-by-side placement of overlapping timed occurrences in one day column.
public struct CalendarColumnPlacement: Equatable, Sendable {
    /// Zero-based column inside the overlap group.
    public var column: Int
    /// Columns of the whole overlap group (the width divisor).
    public var columns: Int
    public init(column: Int, columns: Int) { self.column = column; self.columns = columns }
}

public enum CalendarOverlapLayout {
    /// `slots` are minute ranges of one day (start, end). Occurrences shorter
    /// than `minimumLength` count with that length, as they are drawn at least
    /// that tall. Groups of transitively overlapping occurrences share one
    /// column count; each takes the first free column. Result in input order.
    public static func place(_ slots: [(start: Int, end: Int)], minimumLength: Int = 15) -> [CalendarColumnPlacement] {
        var result = Array(repeating: CalendarColumnPlacement(column: 0, columns: 1), count: slots.count)
        let order = slots.indices.sorted {
            let a = slots[$0], b = slots[$1]
            if a.start != b.start { return a.start < b.start }
            if a.end != b.end { return a.end > b.end }
            return $0 < $1
        }
        func end(_ index: Int) -> Int { max(slots[index].end, slots[index].start + max(1, minimumLength)) }
        var group: [Int] = []
        var columnEnds: [Int] = []
        var groupEnd = Int.min
        func closeGroup() {
            for index in group { result[index].columns = max(1, columnEnds.count) }
            group = []; columnEnds = []; groupEnd = .min
        }
        for index in order {
            let start = slots[index].start
            if !group.isEmpty && start >= groupEnd { closeGroup() }
            let column = columnEnds.firstIndex { $0 <= start } ?? columnEnds.count
            if column == columnEnds.count { columnEnds.append(end(index)) } else { columnEnds[column] = end(index) }
            result[index].column = column
            group.append(index)
            groupEnd = max(groupEnd, end(index))
        }
        closeGroup()
        return result
    }
}

/// Lanes of the all-day row: spans over the shown day columns stack without overlapping.
public enum CalendarAllDayLayout {
    /// `spans` are inclusive column ranges (first…last). Longer spans first
    /// within the same start; result is the lane per span in input order.
    public static func lanes(_ spans: [(first: Int, last: Int)]) -> [Int] {
        var result = Array(repeating: 0, count: spans.count)
        let order = spans.indices.sorted {
            let a = spans[$0], b = spans[$1]
            if a.first != b.first { return a.first < b.first }
            if a.last != b.last { return a.last > b.last }
            return $0 < $1
        }
        var laneEnds: [Int] = []
        for index in order {
            let span = spans[index]
            if let lane = laneEnds.firstIndex(where: { $0 < span.first }) {
                laneEnds[lane] = span.last; result[index] = lane
            } else {
                laneEnds.append(span.last); result[index] = laneEnds.count - 1
            }
        }
        return result
    }

    /// Inclusive column range of an all-day span `[start, endExclusive)` in
    /// the shown `days`, or nil when it lies outside.
    public static func columns(start: Date, endExclusive: Date, days: [Date], calendar: Calendar) -> (first: Int, last: Int)? {
        let covered = days.indices.filter {
            CalendarDates.allDay(start: start, endExclusive: endExclusive, covers: days[$0], calendar: calendar)
        }
        guard let first = covered.first, let last = covered.last else { return nil }
        return (first, last)
    }
}

/// Limited space in a month cell: never cut silently.
public enum CalendarOverflow {
    /// With room for `capacity` single-line rows, how many entries are shown
    /// and how many the „+ n weitere“ row stands for. The overflow row takes
    /// one of the rows itself; `shown + hidden == total` always holds.
    public static func split(total: Int, capacity: Int) -> (shown: Int, hidden: Int) {
        let total = max(0, total)
        if total <= max(0, capacity) { return (total, 0) }
        let shown = max(0, capacity - 1)
        return (shown, total - shown)
    }
}

/// Stable automatic subject colours: the same subject gets the same palette
/// slot on every launch and device (Swift's `hashValue` is seeded per process).
/// Colours are stored by name; blue (selection), red (today) and green (own
/// events) are not subject colours. State is never shown by colour alone.
public enum CalendarSubjectColor {
    /// Automatic palette (order is part of the stable assignment).
    public static let automatic = ["orange", "purple", "teal", "pink", "yellow", "brown", "cyan", "olive"]
    /// What the user may choose per subject.
    public static let choosable = automatic + ["indigo", "mint", "gray"]
    /// Default of own events („Persönlich“).
    public static let personal = "green"

    public static func index(for subject: String, paletteCount: Int) -> Int {
        guard paletteCount > 0 else { return 0 }
        var hash: UInt32 = 2_166_136_261
        for byte in subject.lowercased().utf8 { hash = (hash ^ UInt32(byte)) &* 16_777_619 }
        return Int(hash % UInt32(paletteCount))
    }

    /// Identity of a subject: the WebUntis subject id when delivered, else its name.
    public static func key(subjectID: String?, name: String) -> String {
        if let id = subjectID?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty { return "webuntis:" + id }
        return "name:" + name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// The chosen colour, else the automatic one for `key`.
    public static func name(for key: String, chosen: [String: String]) -> String {
        if let value = chosen[key], choosable.contains(value) { return value }
        return automatic[index(for: key, paletteCount: automatic.count)]
    }

    /// German names for the picker.
    public static func title(_ name: String) -> String {
        switch name {
        case "orange": "Orange"
        case "purple": "Violett"
        case "teal": "Petrol"
        case "pink": "Rosa"
        case "yellow": "Gelb"
        case "brown": "Braun"
        case "cyan": "Türkis"
        case "olive": "Oliv"
        case "indigo": "Indigo"
        case "mint": "Mint"
        case "gray": "Grau"
        case "green": "Grün"
        default: name
        }
    }
}

/// Fixed German wording, independent of the device's region and 12/24-hour setting.
public enum CalendarText {
    public static let months = ["Januar", "Februar", "März", "April", "Mai", "Juni", "Juli",
                                "August", "September", "Oktober", "November", "Dezember"]
    public static let shortMonths = ["Jan.", "Feb.", "März", "Apr.", "Mai", "Juni", "Juli",
                                     "Aug.", "Sept.", "Okt.", "Nov.", "Dez."]
    /// Index 0 = Monday.
    public static let weekdays = ["Montag", "Dienstag", "Mittwoch", "Donnerstag", "Freitag", "Samstag", "Sonntag"]
    public static let shortWeekdays = ["Mo", "Di", "Mi", "Do", "Fr", "Sa", "So"]

    /// „08:05“, always 24 hours.
    public static func clock(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }

    /// Minutes after midnight of `date` on the wall clock of `calendar` (0…1439).
    public static func minuteOfDay(_ date: Date, calendar: Calendar) -> Int {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }

    /// „08:05“ from minutes after midnight (settings such as quiet hours);
    /// always 24 hours, wraps around at midnight.
    public static func clock(minuteOfDay minute: Int) -> String {
        let value = ((minute % 1_440) + 1_440) % 1_440
        return String(format: "%02d:%02d", value / 60, value % 60)
    }

    /// „Mo 9.11.“ (notification texts: change texts, „Dein Tag · Mo 9.11.“).
    public static func shortDay(_ date: Date, calendar: Calendar) -> String {
        let p = calendar.dateComponents([.month, .day], from: date)
        return "\(shortWeekdays[CalendarDates.weekdayIndex(date, calendar: calendar)]) \(p.day ?? 1).\(p.month ?? 1)."
    }

    /// Grid label of a full hour: „08:00“ … „23:00“.
    public static func hour(_ hour: Int) -> String { String(format: "%02d:00", hour) }

    /// „08:00–09:30“; ends on a later day carry that day („22:00 – Mi 01:00“).
    public static func timeRange(_ start: Date, _ end: Date, calendar: Calendar) -> String {
        if calendar.isDate(start, inSameDayAs: end) || end <= start {
            return "\(clock(start, calendar: calendar))–\(clock(end, calendar: calendar))"
        }
        let weekday = shortWeekdays[CalendarDates.weekdayIndex(end, calendar: calendar)]
        return "\(clock(start, calendar: calendar)) – \(weekday) \(clock(end, calendar: calendar))"
    }

    /// „Dienstag, 3. November 2026“.
    public static func longDate(_ date: Date, calendar: Calendar) -> String {
        let p = calendar.dateComponents([.year, .month, .day], from: date)
        return "\(weekdays[CalendarDates.weekdayIndex(date, calendar: calendar)]), \(p.day ?? 1). \(months[(p.month ?? 1) - 1]) \(p.year ?? 0)"
    }

    /// „Di, 3. Nov.“ (headers, back buttons).
    public static func shortDate(_ date: Date, calendar: Calendar) -> String {
        let p = calendar.dateComponents([.month, .day], from: date)
        return "\(shortWeekdays[CalendarDates.weekdayIndex(date, calendar: calendar)]), \(p.day ?? 1). \(shortMonths[(p.month ?? 1) - 1])"
    }

    /// „03.11.2026“ (note titles such as „Rechnungswesen · 03.11.2026“).
    public static func numericDate(_ date: Date, calendar: Calendar) -> String {
        let p = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%02d.%02d.%04d", p.day ?? 1, p.month ?? 1, p.year ?? 0)
    }

    /// „03.11.2026“ of a civil day (no time zone involved).
    public static func numericDate(_ day: CivilDate) -> String {
        String(format: "%02d.%02d.%04d", day.day, day.month, day.year)
    }

    /// „2.–6. November 2026“, „26. Okt. – 1. Nov. 2026“, „28. Dez. 2026 – 3. Jan. 2027“.
    public static func dayRange(_ first: Date, _ last: Date, calendar: Calendar) -> String {
        let a = calendar.dateComponents([.year, .month, .day], from: first)
        let b = calendar.dateComponents([.year, .month, .day], from: last)
        let (ad, am, ay) = (a.day ?? 1, (a.month ?? 1) - 1, a.year ?? 0)
        let (bd, bm, by) = (b.day ?? 1, (b.month ?? 1) - 1, b.year ?? 0)
        if ay != by { return "\(ad). \(shortMonths[am]) \(ay) – \(bd). \(shortMonths[bm]) \(by)" }
        if am != bm { return "\(ad). \(shortMonths[am]) – \(bd). \(shortMonths[bm]) \(by)" }
        if ad == bd { return "\(ad). \(months[am]) \(ay)" }
        return "\(ad).–\(bd). \(months[am]) \(ay)"
    }

    /// Toolbar title of the shown range.
    public static func title(_ mode: CalendarMode, anchor: Date, weekDays count: Int, calendar: Calendar) -> String {
        switch mode {
        case .year: return String(calendar.component(.year, from: anchor))
        case .month:
            let p = calendar.dateComponents([.year, .month], from: anchor)
            return "\(months[(p.month ?? 1) - 1]) \(p.year ?? 0)"
        case .week:
            let days = CalendarDates.weekDays(containing: anchor, count: count, calendar: calendar)
            let week = CalendarDates.isoWeek(days[0], calendar: calendar)
            return "KW \(week.week) · \(dayRange(days[0], days[days.count - 1], calendar: calendar))"
        case .day: return longDate(anchor, calendar: calendar)
        }
    }

    /// Calm toolbar headline: the month(s) of the shown days, the exact
    /// range stays in `title` (VoiceOver) and the KW in the grid.
    /// Week: „November 2026“, „Okt. – Nov. 2026“, „Dez. 2026 – Jan. 2027“;
    /// day: „3. November 2026“ (the weekday stands in the column head).
    public static func headline(_ mode: CalendarMode, anchor: Date, weekDays count: Int, calendar: Calendar) -> String {
        switch mode {
        case .year, .month: return title(mode, anchor: anchor, weekDays: count, calendar: calendar)
        case .day:
            let p = calendar.dateComponents([.year, .month, .day], from: anchor)
            return "\(p.day ?? 1). \(months[(p.month ?? 1) - 1]) \(p.year ?? 0)"
        case .week:
            let days = CalendarDates.weekDays(containing: anchor, count: count, calendar: calendar)
            let a = calendar.dateComponents([.year, .month], from: days[0])
            let b = calendar.dateComponents([.year, .month], from: days[days.count - 1])
            let (am, ay, bm, by) = ((a.month ?? 1) - 1, a.year ?? 0, (b.month ?? 1) - 1, b.year ?? 0)
            if ay != by { return "\(shortMonths[am]) \(ay) – \(shortMonths[bm]) \(by)" }
            if am != bm { return "\(shortMonths[am]) – \(shortMonths[bm]) \(by)" }
            return "\(months[am]) \(ay)"
        }
    }

    /// „+ 1 weiterer“, „+ 3 weitere“ (hidden entries of a month cell: „Termin“).
    public static func more(_ count: Int) -> String { count == 1 ? "+ 1 weiterer" : "+ \(count) weitere" }
}
