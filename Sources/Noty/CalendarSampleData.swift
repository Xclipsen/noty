import SwiftUI
import NotebookCore

// Shared calendar view types and the BEISPIELDATEN of the design review
// (docs/CALENDAR-PLAN.md). The samples are frei erfunden (Stundenplan,
// Lehrkräfte, Räume, Termine, Ferien), shown only with „Beispieldaten
// anzeigen“, never stored and never mixed with real entries.

/// Calendars shown. Only own entries of „Persönlich“ are writable here;
/// `system` (Apple Kalender/Outlook über EventKit, Stufe C, IDs „system/…“)
/// is read-only by default – whether a single system calendar may be
/// written is decided by the model (`canEdit`, after the data merge).
enum CalendarSource: String, CaseIterable, Identifiable, Hashable {
    case timetable, personal, holidays, system
    var id: String { rawValue }
    var title: String {
        switch self {
        case .timetable: "Stundenplan"
        case .personal: "Persönlich"
        case .holidays: "Ferien"
        case .system: "Kalender"
        }
    }
    /// Symbol of the source in lists and chips.
    var symbol: String {
        switch self {
        case .timetable: "graduationcap"
        case .personal: "person.crop.circle"
        case .holidays: "sun.max"
        case .system: "calendar"
        }
    }
    var readOnly: Bool { self != .personal }
}

enum CalendarEventStatus: Hashable {
    case normal, cancelled, exam
    case substitution(String)
    case roomChanged(String)
    /// A source state this version does not know; shown neutrally.
    case other(String)

    var label: String? {
        switch self {
        case .normal: nil
        case .cancelled: "Ausfall"
        case .exam: "Prüfung"
        case .substitution: "Änderung"
        case .roomChanged: "Raumänderung"
        case .other: "Hinweis"
        }
    }
    var symbol: String? {
        switch self {
        case .normal: nil
        case .cancelled: "xmark.circle"
        case .exam: "pencil.and.list.clipboard"
        case .substitution: "arrow.triangle.swap"
        case .roomChanged: "door.left.hand.open"
        case .other: "info.circle"
        }
    }
    var note: String? {
        switch self {
        case .substitution(let text), .roomChanged(let text), .other(let text): text
        default: nil
        }
    }
}

/// One shown occurrence. All-day entries use day starts with an exclusive end.
struct CalendarEntry: Identifiable, Hashable {
    let id: String
    var title: String
    var subject: String?
    var source: CalendarSource
    var start: Date
    var end: Date
    var allDay = false
    var room: String?
    var teacher: String?
    var status = CalendarEventStatus.normal
    var details: String?
    var seriesID: String?
    var repeatText: String?
    var reminder: String?
    /// Fictitious, already written note pages (typed text) of the sample.
    var samplePages: [String] = []
    /// Fictitious entry of the design samples: never stored, never editable.
    var isSample = false
    /// Own event of the confirmed state (`LocalCalendarEvent.id`).
    var localID: UUID?
    /// Further status lines beside the main status.
    var statusNotes: [String] = []
    /// Generated date of a series occurrence (its identity, also of its note).
    var originalDate: CivilDate?
    /// What a note written beside this entry belongs to (nil: no notes).
    var noteTarget: CalendarNoteTarget?
    /// Colour by name (`CalendarSubjectColor`); nil: automatic from the subject.
    var colorName: String?
    /// Subject identity of a lesson (its adjustable colour).
    var subjectKey: String?
    /// Read-only stand-in of a lesson note whose lesson is gone or not loaded.
    var ghostLinkID: UUID?

    /// Entry id of an own event: „local/<id>“, a series occurrence
    /// „local/<id>/<YYYY-MM-DD>“ (equal to its note target's key).
    static func localID(_ id: UUID, _ date: CivilDate?) -> String {
        CalendarNoteTarget.local(event: id, date: date).key
    }
}

enum CalendarPalette {
    /// Subject colours: `CalendarSubjectColor` (by name). Blue stays reserved
    /// for selection and actions, red for today and the current time, green
    /// for own entries.
    static let personal = Color.green
    static let holidays = Color.gray
    /// Fallback of system calendars (EventKit) until their own colour is known.
    static let system = Color(red: 0.55, green: 0.6, blue: 0.95)
    static let selection = Color(uiColor: .systemBlue)
    static let today = Color(uiColor: .systemRed)
    /// Hairlines of grids and cells: quieter than the system separator.
    static let hairline = Color(uiColor: .separator).opacity(0.45)
    /// Hour labels, week numbers and other quiet captions.
    static let quiet = Color(uiColor: .tertiaryLabel)
    /// Event background: a faint tint of the subject colour, stronger when selected.
    static func tint(_ color: Color, selected: Bool = false, cancelled: Bool = false) -> Color {
        color.opacity(selected ? 0.30 : cancelled ? 0.06 : 0.15)
    }

    static func color(_ event: CalendarEntry) -> Color {
        if let name = event.colorName { return color(named: name) }
        switch event.source {
        case .personal: return personal
        case .holidays: return holidays
        case .system: return system
        case .timetable:
            let key = CalendarSubjectColor.key(subjectID: nil, name: event.subject ?? event.title)
            return color(named: CalendarSubjectColor.name(for: key, chosen: [:]))
        }
    }

    /// The named colours of `CalendarSubjectColor` (stored by name).
    static func color(named name: String) -> Color {
        switch name {
        case "orange": .orange
        case "purple": .purple
        case "teal": .teal
        case "pink": .pink
        case "yellow": .yellow
        case "brown": .brown
        case "cyan": .cyan
        case "olive": Color(red: 0.62, green: 0.68, blue: 0.2)
        case "indigo": .indigo
        case "mint": .mint
        case "gray": .gray
        case "green": personal
        default: .gray
        }
    }
}

/// Generates the fictitious entries for a year (plus the neighbouring weeks
/// shown by the month grid). The week of „today“ gets the special cases of
/// the design review: written notes, cancellation, substitution, exam,
/// overlaps and a crowded day.
enum CalendarSamples {
    private struct Lesson { let subject: String; let room: String; let teacher: String }
    private static let slots: [(Int, Int, Int, Int)] = [(8, 0, 9, 30), (9, 45, 11, 15), (11, 35, 13, 5), (13, 50, 15, 20)]
    private static let rw = Lesson(subject: "Rechnungswesen", room: "R 204", teacher: "Fr. Lindner")
    private static let de = Lesson(subject: "Deutsch", room: "R 112", teacher: "Hr. Okafor")
    private static let ma = Lesson(subject: "Mathematik", room: "R 204", teacher: "Fr. Brandt")
    private static let en = Lesson(subject: "Englisch", room: "R 108", teacher: "Fr. Hale")
    private static let wl = Lesson(subject: "Wirtschaftslehre", room: "R 210", teacher: "Hr. Sander")
    private static let po = Lesson(subject: "Politik", room: "R 112", teacher: "Fr. Novak")
    private static let it = Lesson(subject: "Informatik", room: "EDV 2", teacher: "Hr. Demir")
    private static let sp = Lesson(subject: "Sport", room: "Turnhalle", teacher: "Fr. Kühn")
    private static let et = Lesson(subject: "Ethik", room: "R 115", teacher: "Hr. Weiß")
    /// Monday … Friday, nil = free period.
    private static let timetable: [[Lesson?]] = [
        [de, ma, wl, nil],
        [rw, en, po, sp],
        [it, ma, rw, nil],
        [wl, de, en, et],
        [ma, rw, it, nil],
    ]
    /// Fictitious school holidays (month, day, month, day exclusive end); not a real state's dates.
    private static let holidays: [(String, Int, Int, Int, Int)] = [
        ("Winterferien (Beispiel)", 2, 9, 2, 14),
        ("Osterferien (Beispiel)", 3, 30, 4, 11),
        ("Pfingstferien (Beispiel)", 5, 26, 5, 30),
        ("Sommerferien (Beispiel)", 7, 20, 8, 29),
        ("Herbstferien (Beispiel)", 10, 19, 10, 31),
        ("Weihnachtsferien (Beispiel)", 12, 21, 12, 32),
        ("Weihnachtsferien (Beispiel)", 1, 1, 1, 6),
    ]

    static func events(year anchor: Date, today: Date, calendar: Calendar) -> [CalendarEntry] {
        let yearStart = CalendarDates.startOfYear(anchor, calendar: calendar)
        let year = calendar.component(.year, from: yearStart)
        let first = CalendarDates.day(-14, after: yearStart, calendar: calendar)
        let last = CalendarDates.day(380, after: yearStart, calendar: calendar)
        func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
            // Day 32 of December = 1 January of the next year.
            calendar.date(from: DateComponents(year: y, month: m, day: d)).map { calendar.startOfDay(for: $0) } ?? yearStart
        }
        func time(_ day: Date, _ h: Int, _ m: Int) -> Date {
            calendar.date(bySettingHour: h, minute: m, second: 0, of: day) ?? day
        }

        var result: [CalendarEntry] = []
        var holidayRanges: [(Date, Date)] = []
        for y in [year - 1, year, year + 1] {
            for (title, m1, d1, m2, d2) in holidays {
                let start = date(y, m1, d1), end = date(y, m2, d2)
                guard end > first && start < last else { continue }
                holidayRanges.append((start, end))
                result.append(CalendarEntry(id: "holiday-\(y)-\(m1)-\(d1)", title: title, source: .holidays,
                                                  start: start, end: end, allDay: true,
                                                  details: "Ferienzeitraum frei erfunden. Eine echte Ferienquelle ist noch nicht festgelegt."))
            }
        }
        func inHolidays(_ day: Date) -> Bool { holidayRanges.contains { day >= $0.0 && day < $0.1 } }

        let thisWeek = CalendarDates.startOfWeek(today, calendar: calendar)
        var day = first
        while day < last {
            let weekday = CalendarDates.weekdayIndex(day, calendar: calendar)
            let weekOffset = CalendarDates.days(from: thisWeek, to: CalendarDates.startOfWeek(day, calendar: calendar), calendar: calendar) / 7
            let key = CalendarText.numericDate(day, calendar: calendar)
            if weekday < 5 && !inHolidays(day) {
                for (slot, lesson) in timetable[weekday].enumerated() {
                    guard let lesson else { continue }
                    let (h1, m1, h2, m2) = slots[slot]
                    var event = CalendarEntry(id: "lesson-\(key)-\(slot)", title: lesson.subject, subject: lesson.subject,
                                                    source: .timetable, start: time(day, h1, m1), end: time(day, h2, m2),
                                                    room: lesson.room, teacher: lesson.teacher)
                    special(&event, weekday: weekday, slot: slot, weekOffset: weekOffset)
                    result.append(event)
                }
            }
            // Own weekly series: Thursday evening, outside the holidays too.
            if weekday == 3 {
                result.append(CalendarEntry(id: "own-volleyball-\(key)", title: "Volleyball", source: .personal,
                                                  start: time(day, 18, 30), end: time(day, 20, 0), room: "Sporthalle Nord",
                                                  details: "Training im Verein (Beispiel).", seriesID: "own-volleyball",
                                                  repeatText: "Wöchentlich am Donnerstag"))
            }
            if weekOffset == 0 { result += ownEvents(weekday: weekday, day: day, key: key, time: time) }
            if weekOffset == 1 && weekday == 3 {
                result.append(CalendarEntry(id: "own-messe-\(key)", title: "Messebesuch Wirtschaft", source: .personal,
                                                  start: day, end: CalendarDates.day(2, after: day, calendar: calendar), allDay: true,
                                                  room: "Messegelände", details: "Zweitägiger Ausflug (Beispiel)."))
            }
            day = CalendarDates.day(1, after: day, calendar: calendar)
        }
        return result.map { var sample = $0; sample.isSample = true; return sample }
    }

    /// Design cases of the current (and the next) week.
    private static func special(_ event: inout CalendarEntry, weekday: Int, slot: Int, weekOffset: Int) {
        switch (weekOffset, weekday, slot) {
        case (0, 1, 0):
            event.samplePages = [
                "Rechnungswesen – Buchungssätze\n\n• Bank an Kasse 500 €\n• Wareneingang an Verbindlichkeiten 1.200 €\n\nMerke: Soll an Haben.",
                "Hausaufgabe\n\nAufgaben 4–6 bis Freitag. Eigene Beispiele frei erfunden.",
            ]
        case (0, 2, 1):
            event.status = .cancelled
            event.details = "Unterricht entfällt (Beispiel)."
            event.samplePages = ["Ausfall – Selbstlernaufgaben\n\nLehrbuch S. 42, Nr. 3–7 bearbeiten."]
        case (0, 3, 2):
            event.status = .substitution("Hr. Sander statt Fr. Hale, Raum R 210 statt R 108")
            event.room = "R 210"; event.teacher = "Hr. Sander"
        case (0, 4, 1):
            event.status = .exam
            event.title = "Klassenarbeit Rechnungswesen"
            event.details = "Prüfung laut Stundenplan (Beispiel). Hilfsmittel: Taschenrechner."
        case (1, 1, 1):
            event.status = .exam
            event.title = "Englisch-Test"
        case (-1, 1, 0):
            event.samplePages = ["Rechnungswesen – Bilanz\n\nAktiva = Passiva (Beispielnotiz der Vorwoche)."]
        default: break
        }
    }

    private static func ownEvents(weekday: Int, day: Date, key: String, time: (Date, Int, Int) -> Date) -> [CalendarEntry] {
        func own(_ suffix: String, _ title: String, _ h1: Int, _ m1: Int, _ h2: Int, _ m2: Int, room: String? = nil,
                 details: String? = nil, reminder: String? = nil) -> CalendarEntry {
            CalendarEntry(id: "own-\(suffix)-\(key)", title: title, source: .personal, start: time(day, h1, m1),
                                end: time(day, h2, m2), room: room, details: details, reminder: reminder)
        }
        switch weekday {
        case 0: return [own("zahnarzt", "Zahnarzt", 16, 0, 17, 0, room: "Praxis am Markt", reminder: "30 Minuten vorher")]
        case 2: return [own("lerngruppe", "Lerngruppe Statistik", 8, 30, 10, 15, room: "Bibliothek, Gruppenraum 3",
                            details: "Überschneidet sich mit dem Unterricht (Designfall: Termine nebeneinander).")]
        case 3:
            return [CalendarEntry(id: "own-abgabe-\(key)", title: "Abgabe Projektmappe", source: .personal,
                                        start: day, end: time(day, 0, 0), allDay: true, details: "Ganztägiger Termin (Beispiel).")]
        case 4:
            // Crowded Friday for „+ n weitere“ in the month.
            return [own("buecherei", "Bücherei: Rückgabe", 13, 15, 13, 45),
                    own("nachhilfe", "Nachhilfe geben", 15, 0, 16, 0, room: "Zuhause"),
                    own("bewerbung", "Bewerbung abschicken", 17, 0, 17, 30, reminder: "10 Minuten vorher"),
                    own("kino", "Kino", 20, 0, 22, 30, room: "Filmpalast")]
        default: return []
        }
    }
}

/// Draft of the event form: single events and series (B2). Reminders stay
/// in the type for B3 but are not offered in the form.
struct CalendarDraft: Identifiable {
    enum Repeat: String, CaseIterable, Identifiable {
        case never, daily, weekly, monthly
        var id: String { rawValue }
        var title: String {
            switch self {
            case .never: "Nie"
            case .daily: "Täglich"
            case .weekly: "Wöchentlich"
            case .monthly: "Monatlich"
            }
        }
    }
    enum RepeatEnd: String, CaseIterable, Identifiable {
        case never, onDate, afterCount
        var id: String { rawValue }
        var title: String {
            switch self {
            case .never: "Nie"
            case .onDate: "Am Datum"
            case .afterCount: "Nach Anzahl"
            }
        }
    }
    let id = UUID()
    var editing: CalendarEntry?
    var title = ""
    var location = ""
    var details = ""
    var allDay = false
    var start: Date
    var end: Date
    var repeatRule = Repeat.never
    var repeatEnd = RepeatEnd.never
    var repeatUntil: Date
    var repeatCount = 10
    /// Original dates removed from the series (shown, can be taken back).
    var exceptionDates: [CivilDate] = []
    var exceptionsEdited = false
    var reminder = false
    var reminderMinutes = 10
    /// The series rule as it was (an edit of „Nur dieser Termin“ must not change it).
    var originalRule: CalendarRecurrence?

    init(start: Date, calendar: Calendar) {
        self.start = start
        self.end = calendar.date(byAdding: .hour, value: 1, to: start) ?? start
        self.repeatUntil = calendar.date(byAdding: .month, value: 2, to: start) ?? start
    }

    init(editing event: CalendarEntry, rule: CalendarRecurrence?, base: LocalCalendarEvent?, calendar: Calendar) {
        self.init(start: event.start, calendar: calendar)
        editing = event
        title = event.title; location = event.room ?? ""; details = event.details ?? ""
        allDay = event.allDay
        // All-day entries end exclusively; the form shows the last day.
        end = event.allDay ? max(event.start, CalendarDates.day(-1, after: event.end, calendar: calendar)) : event.end
        originalRule = rule
        if let rule {
            switch rule.frequency {
            case .daily: repeatRule = .daily
            case .weekly: repeatRule = .weekly
            case .monthly: repeatRule = .monthly
            }
            switch rule.end {
            case .never: repeatEnd = .never
            case .afterCount(let count): repeatEnd = .afterCount; repeatCount = count
            case .until(let date): repeatEnd = .onDate; repeatUntil = date.start(in: calendar)
            }
            exceptionDates = rule.exceptions.sorted()
        }
        reminder = base?.reminderMinutes != nil
        reminderMinutes = base?.reminderMinutes ?? 10
    }

    var isSeriesOccurrence: Bool { editing?.originalDate != nil && originalRule != nil }

    /// The timing to store; nil with an explanation when invalid.
    func timing(calendar: Calendar) -> (CalendarEventTiming?, String?) {
        let timing: CalendarEventTiming
        if allDay {
            let first = CivilDate(start, calendar: calendar), last = CivilDate(end, calendar: calendar)
            timing = .allDay(start: first, end: last.adding(days: 1))
        } else {
            timing = .timed(start: start, end: end, timeZone: calendar.timeZone.identifier)
        }
        if let problem = timing.problem { return (nil, problem) }
        return (timing, nil)
    }

    func exceptions(calendar: Calendar) -> [CivilDate] { exceptionDates }

    /// The repetition to store (nil: single event), or why it is invalid.
    func recurrence(calendar: Calendar) -> (CalendarRecurrence?, String?) {
        let frequency: CalendarRecurrence.Frequency
        switch repeatRule {
        case .never: return (nil, nil)
        case .daily: frequency = .daily
        case .weekly: frequency = .weekly
        case .monthly: frequency = .monthly
        }
        let end: CalendarRecurrence.End
        switch repeatEnd {
        case .never: end = .never
        case .afterCount:
            guard (1...CalendarRecurrence.maximumCount).contains(repeatCount) else {
                return (nil, "Eine Serie hat 1 bis \(CalendarRecurrence.maximumCount) Termine.")
            }
            end = .afterCount(repeatCount)
        case .onDate:
            let last = CivilDate(repeatUntil, calendar: calendar)
            guard last >= CivilDate(start, calendar: calendar) else { return (nil, "Das Ende der Wiederholung liegt vor dem ersten Termin.") }
            end = .until(last)
        }
        return (CalendarRecurrence(frequency: frequency, interval: originalRule?.frequency == frequency ? originalRule?.interval ?? 1 : 1,
                                   end: end, exceptions: exceptionDates), nil)
    }

    /// The series part changed (frequency, end, exceptions): only „Alle“ fits.
    func changesSeries(calendar: Calendar) -> Bool {
        guard let originalRule else { return repeatRule != .never }
        guard let rule = recurrence(calendar: calendar).0 else { return true }
        return rule.frequency != originalRule.frequency || rule.end != originalRule.end || exceptionsEdited
    }
}

extension CalendarEntry {
    /// Only own, stored events; samples and WebUntis never.
    var writable: Bool { localID != nil && !isSample }

    /// Where the entry comes from (details, VoiceOver).
    var originText: String {
        if isSample { return source == .holidays ? "Beispiel, keine echte Ferienquelle" : "Beispieldaten" }
        switch source {
        case .timetable: return "WebUntis, inoffiziell über Untis-Mobile-Freigabe"
        case .holidays: return "WebUntis-Ferien"
        case .personal: return "noty, nur auf diesem iPad"
        case .system: return "Kalender des iPads"
        }
    }

    /// „Rechnungswesen · 03.11.2026“: the later name in „Kalendernotizen“.
    func noteTitle(_ calendar: Calendar) -> String {
        "\(subject ?? title) · \(CalendarText.numericDate(start, calendar: calendar))"
    }

    func timeText(_ calendar: Calendar) -> String {
        if allDay {
            let days = CalendarDates.days(from: start, to: end, calendar: calendar)
            return days > 1 ? "ganztägig, \(days) Tage" : "ganztägig"
        }
        return CalendarText.timeRange(start, end, calendar: calendar)
    }

    func accessibilityText(_ calendar: Calendar, notes: Bool) -> String {
        var parts = [title, allDay ? timeText(calendar) : "\(CalendarText.clock(start, calendar: calendar)) bis \(CalendarText.clock(end, calendar: calendar))"]
        if let room { parts.append("Raum \(room)") }
        if let label = status.label { parts.append(label) }
        if notes { parts.append("mit Notizen") }
        parts.append(source.readOnly ? "\(source.title), schreibgeschützt" : source.title)
        return parts.joined(separator: ", ")
    }
}
