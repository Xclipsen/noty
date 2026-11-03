import SwiftUI
import PencilKit
import NotebookCore

// BEISPIELDATEN – Kalender Stufe A (docs/CALENDAR-PLAN.md).
// Frei erfundener Stundenplan, erfundene Lehrkräfte, Räume und Termine,
// erfundene Ferienzeiträume. Keine echten oder privaten Stundenplandaten,
// keine WebUntis-Anbindung und keine Speicherung: alles lebt nur im
// Speicher dieser Sitzung und wird beim Bereichswechsel/Neustart verworfen.

/// Calendars of the design stage. Only „Persönlich“ is writable.
enum CalendarSource: String, CaseIterable, Identifiable, Hashable {
    case timetable, personal, holidays
    var id: String { rawValue }
    var title: String {
        switch self {
        case .timetable: "Stundenplan"
        case .personal: "Persönlich"
        case .holidays: "Ferien"
        }
    }
    /// Where the entries come from; every source here is fictitious.
    var origin: String {
        switch self {
        case .timetable: "WebUntis (Beispiel)"
        case .personal: "noty, lokal (Beispiel)"
        case .holidays: "Beispiel, keine echte Ferienquelle"
        }
    }
    var readOnly: Bool { self != .personal }
}

enum CalendarEventStatus: Hashable {
    case normal, cancelled, exam
    case substitution(String)

    var label: String? {
        switch self {
        case .normal: nil
        case .cancelled: "Ausfall"
        case .exam: "Prüfung"
        case .substitution: "Vertretung"
        }
    }
    var symbol: String? {
        switch self {
        case .normal: nil
        case .cancelled: "xmark.circle"
        case .exam: "pencil.and.list.clipboard"
        case .substitution: "arrow.triangle.swap"
        }
    }
}

/// One shown occurrence. All-day entries use day starts with an exclusive end.
struct CalendarSampleEvent: Identifiable, Hashable {
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
}

enum CalendarPalette {
    /// Automatic subject colours. Blue stays reserved for selection and
    /// actions, red for today and the current time, green for own entries.
    static let subjects: [Color] = [.orange, .purple, .teal, .pink, .yellow, .brown, .cyan, Color(red: 0.62, green: 0.68, blue: 0.2)]
    static let personal = Color.green
    static let holidays = Color.gray
    static let selection = Color(uiColor: .systemBlue)
    static let today = Color(uiColor: .systemRed)

    static func color(_ event: CalendarSampleEvent) -> Color {
        switch event.source {
        case .personal: return personal
        case .holidays: return holidays
        case .timetable:
            return subjects[CalendarSubjectColor.index(for: event.subject ?? event.title, paletteCount: subjects.count)]
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

    static func events(year anchor: Date, today: Date, calendar: Calendar) -> [CalendarSampleEvent] {
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

        var result: [CalendarSampleEvent] = []
        var holidayRanges: [(Date, Date)] = []
        for y in [year - 1, year, year + 1] {
            for (title, m1, d1, m2, d2) in holidays {
                let start = date(y, m1, d1), end = date(y, m2, d2)
                guard end > first && start < last else { continue }
                holidayRanges.append((start, end))
                result.append(CalendarSampleEvent(id: "holiday-\(y)-\(m1)-\(d1)", title: title, source: .holidays,
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
                    var event = CalendarSampleEvent(id: "lesson-\(key)-\(slot)", title: lesson.subject, subject: lesson.subject,
                                                    source: .timetable, start: time(day, h1, m1), end: time(day, h2, m2),
                                                    room: lesson.room, teacher: lesson.teacher)
                    special(&event, weekday: weekday, slot: slot, weekOffset: weekOffset)
                    result.append(event)
                }
            }
            // Own weekly series: Thursday evening, outside the holidays too.
            if weekday == 3 {
                result.append(CalendarSampleEvent(id: "own-volleyball-\(key)", title: "Volleyball", source: .personal,
                                                  start: time(day, 18, 30), end: time(day, 20, 0), room: "Sporthalle Nord",
                                                  details: "Training im Verein (Beispiel).", seriesID: "own-volleyball",
                                                  repeatText: "Wöchentlich am Donnerstag"))
            }
            if weekOffset == 0 { result += ownEvents(weekday: weekday, day: day, key: key, time: time) }
            if weekOffset == 1 && weekday == 3 {
                result.append(CalendarSampleEvent(id: "own-messe-\(key)", title: "Messebesuch Wirtschaft", source: .personal,
                                                  start: day, end: CalendarDates.day(2, after: day, calendar: calendar), allDay: true,
                                                  room: "Messegelände", details: "Zweitägiger Ausflug (Beispiel)."))
            }
            day = CalendarDates.day(1, after: day, calendar: calendar)
        }
        return result
    }

    /// Design cases of the current (and the next) week.
    private static func special(_ event: inout CalendarSampleEvent, weekday: Int, slot: Int, weekOffset: Int) {
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

    private static func ownEvents(weekday: Int, day: Date, key: String, time: (Date, Int, Int) -> Date) -> [CalendarSampleEvent] {
        func own(_ suffix: String, _ title: String, _ h1: Int, _ m1: Int, _ h2: Int, _ m2: Int, room: String? = nil,
                 details: String? = nil, reminder: String? = nil) -> CalendarSampleEvent {
            CalendarSampleEvent(id: "own-\(suffix)-\(key)", title: title, source: .personal, start: time(day, h1, m1),
                                end: time(day, h2, m2), room: room, details: details, reminder: reminder)
        }
        switch weekday {
        case 0: return [own("zahnarzt", "Zahnarzt", 16, 0, 17, 0, room: "Praxis am Markt", reminder: "30 Minuten vorher")]
        case 2: return [own("lerngruppe", "Lerngruppe Statistik", 8, 30, 10, 15, room: "Bibliothek, Gruppenraum 3",
                            details: "Überschneidet sich mit dem Unterricht (Designfall: Termine nebeneinander).")]
        case 3:
            return [CalendarSampleEvent(id: "own-abgabe-\(key)", title: "Abgabe Projektmappe", source: .personal,
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

/// One note page of the design stage: handwriting and typed text, memory only.
struct CalendarNotePage: Identifiable {
    let id = UUID()
    var drawing = PKDrawing()
    var text = ""
    /// Bumped on every handwriting change; canvases reload only on a revision they have not written.
    var revision = 0
    var isEmpty: Bool { drawing.strokes.isEmpty && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

/// Draft of the event form (no saving in Stufe A).
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
    var editing: CalendarSampleEvent?
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
    var exceptions: [Date] = []
    var reminder = false
    var reminderMinutes = 10

    init(start: Date, calendar: Calendar) {
        self.start = start
        self.end = calendar.date(byAdding: .hour, value: 1, to: start) ?? start
        self.repeatUntil = calendar.date(byAdding: .month, value: 2, to: start) ?? start
    }

    init(editing event: CalendarSampleEvent, calendar: Calendar) {
        self.init(start: event.start, calendar: calendar)
        editing = event
        title = event.title; location = event.room ?? ""; details = event.details ?? ""
        allDay = event.allDay; end = event.end
        if event.seriesID != nil { repeatRule = .weekly }
        reminder = event.reminder != nil
    }
}

/// State of the calendar design stage, kept by the library while it lives
/// (switching between library and calendar keeps view, date and drafts).
@MainActor
final class CalendarDesignModel: ObservableObject {
    let calendar = CalendarDates.german()
    @Published var mode = CalendarMode.week
    /// Every change of the shown date makes sure its sample year exists.
    @Published var anchor = Date() { didSet { prepare() } }
    @Published var selection: String?
    @Published var draft: CalendarDraft?
    @Published var hiddenSources: Set<CalendarSource> = []
    @Published var showsSamples = true
    @Published private(set) var removed: Set<String> = []
    @Published private(set) var lastRemoval: (title: String, ids: Set<String>)?
    /// Note pages written in this session, per event.
    @Published private var notes: [String: [CalendarNotePage]] = [:]
    @Published private(set) var today = Date()
    private var generatedYear: Int?
    private var all: [CalendarSampleEvent] = []
    private var byID: [String: CalendarSampleEvent] = [:]
    private var byDay: [Date: [CalendarSampleEvent]] = [:]

    func refreshToday() {
        let now = Date()
        if !calendar.isDate(now, inSameDayAs: today) { today = now; generatedYear = nil }
        prepare()
    }

    /// Generates the sample year around the anchor once per year.
    func prepare() {
        let year = calendar.component(.year, from: anchor)
        guard generatedYear != year else { return }
        generatedYear = year
        all = CalendarSamples.events(year: anchor, today: today, calendar: calendar)
        byID = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var index: [Date: [CalendarSampleEvent]] = [:]
        for event in all {
            var day = calendar.startOfDay(for: event.start)
            let stop = event.allDay ? max(event.end, CalendarDates.day(1, after: day, calendar: calendar)) : event.end
            repeat {
                index[day, default: []].append(event)
                day = CalendarDates.day(1, after: day, calendar: calendar)
            } while day < stop
        }
        byDay = index
        objectWillChange.send()
    }

    private func visible(_ event: CalendarSampleEvent) -> Bool {
        showsSamples && !hiddenSources.contains(event.source) && !removed.contains(event.id)
    }

    /// All-day entries first, then by start; nothing is filtered by space.
    func events(on day: Date) -> [CalendarSampleEvent] {
        (byDay[calendar.startOfDay(for: day)] ?? []).filter(visible).sorted {
            if $0.allDay != $1.allDay { return $0.allDay }
            if $0.start != $1.start { return $0.start < $1.start }
            return $0.end > $1.end
        }
    }

    func event(_ id: String?) -> CalendarSampleEvent? {
        guard let id, let event = byID[id], visible(event) else { return nil }
        return event
    }

    var selectedEvent: CalendarSampleEvent? { event(selection) }

    func search(_ query: String) -> [CalendarSampleEvent] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        return all.filter { event in
            visible(event) && [event.title, event.room, event.teacher, event.details].contains { $0?.localizedCaseInsensitiveContains(text) == true }
        }.sorted { $0.start < $1.start }
    }

    var hasVisibleSamples: Bool { showsSamples && hiddenSources.count < CalendarSource.allCases.count }

    // MARK: Navigation

    func step(_ steps: Int) {
        anchor = CalendarDates.shift(anchor, mode: mode, by: steps, calendar: calendar)
    }
    func goToToday() { refreshToday(); anchor = today }
    func open(_ day: Date, in mode: CalendarMode) { anchor = day; self.mode = mode }
    func show(_ event: CalendarSampleEvent) {
        anchor = calendar.startOfDay(for: event.start)
        if mode == .year { mode = .day }
        selection = event.id
    }

    /// New entry: next full hour on the shown day.
    func requestNewEvent() {
        guard draft == nil else { return }
        let hour = calendar.component(.hour, from: Date())
        let day = calendar.startOfDay(for: mode == .day || mode == .week ? anchor : today)
        let start = calendar.date(bySettingHour: min(22, hour + 1), minute: 0, second: 0, of: day) ?? day
        draft = CalendarDraft(start: start, calendar: calendar)
    }

    // MARK: Removal (session only, with a way back)

    func remove(_ event: CalendarSampleEvent, wholeSeries: Bool) {
        let ids: Set<String>
        if wholeSeries, let series = event.seriesID {
            ids = Set(all.filter { $0.seriesID == series }.map(\.id))
        } else {
            ids = [event.id]
        }
        removed.formUnion(ids)
        lastRemoval = (wholeSeries ? "Serie „\(event.title)“" : "„\(event.title)“", ids)
        if let selection, ids.contains(selection) { self.selection = nil }
    }
    func undoRemoval() {
        guard let last = lastRemoval else { return }
        removed.subtract(last.ids)
        lastRemoval = nil
    }
    func dismissRemoval() { lastRemoval = nil }

    // MARK: Notes (memory only)

    func pages(for event: CalendarSampleEvent) -> [CalendarNotePage] {
        if let pages = notes[event.id] { return pages }
        if !event.samplePages.isEmpty { return event.samplePages.map { CalendarNotePage(text: $0) } }
        return [CalendarNotePage()]
    }

    /// Indicator: only real content counts, an opened empty page does not.
    func hasNotes(_ event: CalendarSampleEvent) -> Bool {
        if let pages = notes[event.id] { return pages.contains { !$0.isEmpty } }
        return !event.samplePages.isEmpty
    }

    func setText(_ text: String, page: Int, of event: CalendarSampleEvent) {
        var pages = pages(for: event)
        guard pages.indices.contains(page), pages[page].text != text else { return }
        pages[page].text = text
        notes[event.id] = pages
    }

    /// Returns the new revision for the canvas that wrote it.
    func setDrawing(_ drawing: PKDrawing, page: Int, of event: CalendarSampleEvent) -> Int {
        var pages = pages(for: event)
        guard pages.indices.contains(page) else { return 0 }
        pages[page].drawing = drawing
        pages[page].revision += 1
        notes[event.id] = pages
        return pages[page].revision
    }

    func addPage(to event: CalendarSampleEvent) -> Int {
        var pages = pages(for: event)
        pages.append(CalendarNotePage())
        notes[event.id] = pages
        return pages.count - 1
    }
}

extension CalendarSampleEvent {
    var writable: Bool { !source.readOnly }

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
