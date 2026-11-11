import Foundation

// „Schnell anlegen“ (06.11.2026): one line of German text pre-fills the
// event form, e.g. „Mathe Klausur Fr 10 Uhr“ → title „Mathe Klausur“, next
// Friday 10:00–11:00. Nothing is saved from here; the user checks the form.
// Understood: heute/morgen/übermorgen, weekdays (Mo…So, also full names,
// optional „nächsten“), dates „12.11.“/„12.11.2026“/„12.11.26“, times
// „10 Uhr“, „10:30“, „10.30 Uhr“, „um 10“, ranges „10-12 Uhr“/„10:00–11:30“.
// Without a time the event is all-day.

public struct CalendarQuickEntry: Equatable, Sendable {
    public var title: String
    public var start: Date
    public var end: Date
    public var allDay: Bool

    /// `now` decides „heute“ and the next weekday (today counts only when
    /// the time has not passed yet). Nil only for an empty line.
    public static func parse(_ text: String, now: Date, calendar: Calendar) -> CalendarQuickEntry? {
        let tokens = text.replacingOccurrences(of: "–", with: "-").replacingOccurrences(of: "—", with: "-")
            .split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !tokens.isEmpty else { return nil }
        let today = calendar.startOfDay(for: now)

        enum Kind { case text, day(Date, weekday: Bool), dayRange(Date, Date), time(Int, Int), timeRange((Int, Int), (Int, Int)), uhr, filler }
        func clean(_ token: String) -> String { token.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ",;!?")) }
        let words = tokens.map(clean)
        let weekdays: [(names: [String], index: Int)] = [
            (["mo", "mo.", "montag"], 2), (["di", "di.", "dienstag"], 3), (["mi", "mi.", "mittwoch"], 4),
            (["do", "do.", "donnerstag"], 5), (["fr", "fr.", "freitag"], 6), (["sa", "sa.", "samstag"], 7), (["sonntag"], 1),
        ]
        func weekdayDate(_ index: Int, next: Bool) -> Date {
            let current = calendar.component(.weekday, from: today)
            var ahead = (index - current + 7) % 7
            if next, ahead == 0 { ahead = 7 }
            return calendar.date(byAdding: .day, value: ahead, to: today) ?? today
        }
        func date(_ word: String) -> Date? { parseDate(word, today: today, calendar: calendar) }
        let fillers: Set<String> = ["am", "um", "ab", "bis", "von", "nächsten", "nächster", "nächste", "kommenden"]
        var kinds = [Kind](repeating: .text, count: tokens.count)

        // Pass 1: what is unambiguous on its own.
        for (i, word) in words.enumerated() {
            let followedByUhr = i + 1 < words.count && words[i + 1] == "uhr"
            let isNext = i > 0 && (words[i - 1].hasPrefix("nächst") || words[i - 1] == "kommenden")
            if word == "uhr" { kinds[i] = .uhr; continue }
            if word == "heute" { kinds[i] = .day(today, weekday: false); continue }
            if word == "morgen" { kinds[i] = .day(calendar.date(byAdding: .day, value: 1, to: today) ?? today, weekday: false); continue }
            if word == "übermorgen" { kinds[i] = .day(calendar.date(byAdding: .day, value: 2, to: today) ?? today, weekday: false); continue }
            if let weekday = weekdays.first(where: { $0.names.contains(word) }) {
                kinds[i] = .day(weekdayDate(weekday.index, next: isNext), weekday: true); continue
            }
            // „So“ only capitalised as a weekday („so“ is an ordinary word).
            if tokens[i] == "So" || tokens[i] == "So." { kinds[i] = .day(weekdayDate(1, next: isNext), weekday: true); continue }
            if fillers.contains(word) { continue }
            let parts = word.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
            if parts.count == 2, let a = date(parts[0]), let b = date(parts[1]), b >= a { kinds[i] = .dayRange(a, b); continue }
            if !followedByUhr, !word.hasSuffix("uhr"), let day = date(word) { kinds[i] = .day(day, weekday: false); continue }
            let bare = word.hasSuffix("uhr") ? String(word.dropLast(3)) : word
            if parts.count == 2, let a = parseTime(parts[0], loose: true),
               let b = parseTime(parts[1].replacingOccurrences(of: "uhr", with: ""), loose: true),
               word.contains(":") || followedByUhr || word.hasSuffix("uhr") {
                kinds[i] = .timeRange(a, b); continue
            }
            if bare.contains(":"), let t = parseTime(bare, loose: true) { kinds[i] = .time(t.0, t.1); continue }
            if followedByUhr || word.hasSuffix("uhr"), let t = parseTime(bare, loose: true) { kinds[i] = .time(t.0, t.1); continue }
        }
        // Pass 2: „um 9“, „bis 11“, „so um 10“ (lower-case „so“ before a time).
        for (i, word) in words.enumerated() {
            guard case .text = kinds[i] else { continue }
            if i > 0, ["um", "ab", "bis", "von"].contains(words[i - 1]), let t = parseTime(word, loose: true) { kinds[i] = .time(t.0, t.1); continue }
            // „20 bis 24 Uhr“: the start of a range whose end is a time.
            if i + 2 < words.count, words[i + 1] == "bis", case .time = kinds[i + 2], let t = parseTime(word, loose: true) {
                kinds[i] = .time(t.0, t.1); continue
            }
            if word == "so", i + 1 < words.count {
                switch kinds[i + 1] { case .time, .timeRange: kinds[i] = .day(weekdayDate(1, next: false), weekday: true)
                default: if words[i + 1] == "um" { kinds[i] = .day(weekdayDate(1, next: false), weekday: true) } }
            }
        }
        // Pass 3: filler words count only next to a date or time.
        for (i, word) in words.enumerated() where fillers.contains(word) {
            guard i + 1 < words.count else { continue }
            switch kinds[i + 1] { case .day, .dayRange, .time, .timeRange: kinds[i] = .filler; default: break }
        }

        var day: Date?, endDay: Date?, weekdayGiven = false
        var startTime: (Int, Int)?, endTime: (Int, Int)?
        var titleWords: [String] = []
        for (i, kind) in kinds.enumerated() {
            switch kind {
            case .text: titleWords.append(tokens[i])
            case .uhr, .filler: break
            case .day(let date, let weekday):
                if day == nil { day = date; weekdayGiven = weekday }
                else if date > day! { endDay = date }
            case .dayRange(let a, let b): day = a; endDay = b
            case .time(let h, let m): if startTime == nil { startTime = (h, m) } else { endTime = (h, m) }
            case .timeRange(let a, let b): startTime = a; endTime = b
            }
        }
        var title = titleWords.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty { title = "Neuer Termin" }
        title = String(title.prefix(200))

        func at(_ t: (Int, Int), on date: Date) -> Date {
            // „24 Uhr“ is 0:00 of the next day.
            if t.0 == 24 { return calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: date)) ?? date }
            return calendar.date(bySettingHour: t.0, minute: t.1, second: 0, of: date) ?? date
        }
        if let startTime {
            var base = day ?? today
            var start = at(startTime, on: base)
            if start <= now, base == today {
                // Passed already: a bare time means tomorrow, today's weekday the next week.
                if day == nil { base = calendar.date(byAdding: .day, value: 1, to: base) ?? base }
                else if weekdayGiven { base = calendar.date(byAdding: .day, value: 7, to: base) ?? base }
                start = at(startTime, on: base)
            }
            var end = endTime.map { at($0, on: endDay ?? base) } ?? (calendar.date(byAdding: .hour, value: 1, to: start) ?? start)
            // „22–1 Uhr“ ends the next day.
            if end < start, endTime != nil, endDay == nil { end = calendar.date(byAdding: .day, value: 1, to: end) ?? end }
            if end <= start { end = calendar.date(byAdding: .hour, value: 1, to: start) ?? start }
            return CalendarQuickEntry(title: title, start: start, end: end, allDay: false)
        }
        let start = day ?? today
        let last = max(start, endDay ?? start)
        return CalendarQuickEntry(title: title, start: start, end: calendar.date(byAdding: .day, value: 1, to: last) ?? last, allDay: true)
    }

    /// The end as the event form shows it: the form's end of an all-day
    /// event is its last day (inclusive), `end` is exclusive – so „12.11. bis
    /// 14.11.“ (end 15.11.) gives 14.11. Never before the start; a timed
    /// entry keeps its end. Whole days through the calendar (a day of 23 or
    /// 25 hours is one day).
    public func formEnd(calendar: Calendar) -> Date {
        guard allDay else { return end }
        return max(start, CalendarDates.day(-1, after: end, calendar: calendar))
    }

    /// „10“, „10:30“, „10.30“, „9“ (hour only when `loose`).
    static func parseTime(_ text: String, loose: Bool) -> (Int, Int)? {
        let token = text.trimmingCharacters(in: .whitespaces)
        guard !token.isEmpty, token.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ":" || $0 == ".") }) else { return nil }
        let parts = token.split(separator: token.contains(":") ? ":" : ".", omittingEmptySubsequences: false)
        if parts.count == 1 {
            guard loose, let hour = Int(parts[0]), (0...24).contains(hour), parts[0].count <= 2 else { return nil }
            return (hour, 0)
        }
        guard parts.count == 2, parts[1].count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]),
              (0...24).contains(hour), (0...59).contains(minute), hour < 24 || minute == 0 else { return nil }
        // „12.11“ without „Uhr“ is a date, not 12:11.
        if token.contains("."), !loose { return nil }
        return (hour, minute)
    }

    /// „12.11.“, „12.11.2026“, „12.11.26“; a past date without year → next year.
    static func parseDate(_ token: String, today: Date, calendar: Calendar) -> Date? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard (2...3).contains(parts.count) || (parts.count == 4 && parts[3].isEmpty) else { return nil }
        guard let d = Int(parts[0]), let m = Int(parts[1]), (1...31).contains(d), (1...12).contains(m) else { return nil }
        let currentYear = calendar.component(.year, from: today)
        var year = currentYear
        var explicit = false
        if parts.count >= 3, !parts[2].isEmpty {
            guard let y = Int(parts[2]) else { return nil }
            year = parts[2].count == 2 ? 2000 + y : y
            explicit = true
        }
        guard let civil = CivilDate(year: year, month: m, day: d) else { return nil }
        var date = civil.start(in: calendar)
        if !explicit, date < today, let next = CivilDate(year: year + 1, month: m, day: d) { date = next.start(in: calendar) }
        return date
    }
}
