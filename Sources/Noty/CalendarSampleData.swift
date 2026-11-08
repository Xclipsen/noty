import SwiftUI
import NotebookCore

// BEISPIELDATEN of the design review (docs/CALENDAR-PLAN.md). The samples
// are frei erfunden (Stundenplan, Lehrkräfte, Räume, Termine, Ferien), shown
// only with „Beispieldaten anzeigen“, never stored and never mixed with real
// entries. The shared view types live in CalendarEntry.swift and
// CalendarStyle.swift.

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
        case (0, 0, 1):
            event.status = .roomChanged("R 301 statt R 204")
            event.room = "R 301"
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
        case (1, 0, 2):
            event.status = .cancelled
            event.details = "Unterricht entfällt (Beispiel)."
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
