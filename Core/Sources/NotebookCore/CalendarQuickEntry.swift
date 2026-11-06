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

    /// `now` decides „heute“ and the next weekday (today counts when the
    /// time has not passed yet). Nil only for an empty line.
    public static func parse(_ text: String, now: Date, calendar: Calendar) -> CalendarQuickEntry? {
        var tokens = text.replacingOccurrences(of: "–", with: "-").replacingOccurrences(of: "—", with: "-")
            .split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !tokens.isEmpty else { return nil }
        let today = calendar.startOfDay(for: now)
        var day: Date?
        var weekdayGiven = false
        var startTime: (Int, Int)?
        var endTime: (Int, Int)?
        var used = Set<Int>()

        func clean(_ token: String) -> String { token.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ",;!?")) }

        let weekdays: [(names: [String], index: Int)] = [
            (["mo", "mo.", "montag"], 2), (["di", "di.", "dienstag"], 3), (["mi", "mi.", "mittwoch"], 4),
            (["do", "do.", "donnerstag"], 5), (["fr", "fr.", "freitag"], 6), (["sa", "sa.", "samstag"], 7), (["so", "so.", "sonntag"], 1),
        ]

        for (index, raw) in tokens.enumerated() {
            let token = clean(raw)
            if ["heute"].contains(token) { day = today; used.insert(index); continue }
            if token == "morgen" { day = calendar.date(byAdding: .day, value: 1, to: today); used.insert(index); continue }
            if token == "übermorgen" { day = calendar.date(byAdding: .day, value: 2, to: today); used.insert(index); continue }
            if ["nächsten", "nächster", "nächste", "am", "um", "ab", "bis"].contains(token) { used.insert(index); continue }
            if token == "uhr" { used.insert(index); continue }
            if let weekday = weekdays.first(where: { $0.names.contains(token) }) {
                weekdayGiven = true
                let current = calendar.component(.weekday, from: today)
                var ahead = (weekday.index - current + 7) % 7
                if index > 0, clean(tokens[index - 1]).hasPrefix("nächst"), ahead == 0 { ahead = 7 }
                day = calendar.date(byAdding: .day, value: ahead, to: today)
                used.insert(index); continue
            }
            let followedByUhr = index + 1 < tokens.count && clean(tokens[index + 1]) == "uhr"
            if !followedByUhr, !token.hasSuffix("uhr"), let date = parseDate(token, today: today, calendar: calendar) {
                day = date; used.insert(index); continue
            }
            // Times: a range first, then a single time („10“ only next to „Uhr“ or after „um“).
            let parts = token.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
            if parts.count == 2, let a = parseTime(parts[0], loose: true), let b = parseTime(parts[1].replacingOccurrences(of: "uhr", with: ""), loose: true) {
                startTime = a; endTime = b; used.insert(index); continue
            }
            let nextIsUhr = index + 1 < tokens.count && clean(tokens[index + 1]) == "uhr"
            let afterUm = index > 0 && ["um", "ab"].contains(clean(tokens[index - 1]))
            let afterBis = index > 0 && clean(tokens[index - 1]) == "bis"
            let bare = token.hasSuffix("uhr") ? String(token.dropLast(3)) : token
            if let time = parseTime(bare, loose: nextIsUhr || afterUm || afterBis || token.hasSuffix("uhr")) {
                if afterBis, startTime != nil { endTime = time } else if startTime == nil { startTime = time } else { endTime = time }
                used.insert(index); continue
            }
        }
        tokens = tokens.enumerated().filter { !used.contains($0.offset) }.map(\.element)
        var title = tokens.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty { title = "Neuer Termin" }
        title = String(title.prefix(200))

        if let startTime {
            var base = day ?? today
            func at(_ t: (Int, Int), on date: Date) -> Date {
                calendar.date(bySettingHour: t.0, minute: t.1, second: 0, of: date) ?? date
            }
            var start = at(startTime, on: base)
            // Only a time, already passed today: tomorrow.
            if day == nil, !weekdayGiven, start <= now { base = calendar.date(byAdding: .day, value: 1, to: base) ?? base; start = at(startTime, on: base) }
            var end = endTime.map { at($0, on: base) } ?? (calendar.date(byAdding: .hour, value: 1, to: start) ?? start)
            if end <= start { end = calendar.date(byAdding: .hour, value: 1, to: start) ?? start }
            return CalendarQuickEntry(title: title, start: start, end: end, allDay: false)
        }
        let start = day ?? today
        return CalendarQuickEntry(title: title, start: start, end: calendar.date(byAdding: .day, value: 1, to: start) ?? start, allDay: true)
    }

    /// „10“, „10:30“, „10.30“, „9“ (hour only when `loose`).
    static func parseTime(_ text: String, loose: Bool) -> (Int, Int)? {
        let token = text.trimmingCharacters(in: .whitespaces)
        guard !token.isEmpty, token.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ":" || $0 == ".") }) else { return nil }
        let parts = token.split(separator: token.contains(":") ? ":" : ".", omittingEmptySubsequences: false)
        if parts.count == 1 {
            guard loose, let hour = Int(parts[0]), (0...23).contains(hour), parts[0].count <= 2 else { return nil }
            return (hour, 0)
        }
        guard parts.count == 2, parts[1].count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]),
              (0...23).contains(hour), (0...59).contains(minute) else { return nil }
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
