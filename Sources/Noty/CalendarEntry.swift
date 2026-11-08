import Foundation
import NotebookCore

// Core view types of the calendar (moved out of CalendarSampleData.swift):
// the sources, the state of an occurrence, the shown entry and the draft of
// the event form. Colours and spacing: CalendarStyle.swift.

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
        // One name everywhere (Einstellungen, Seitenleiste, Menü „…“, VoiceOver);
        // the narrow sidebar falls back to `shortTitle` only when it does not fit.
        case .system: "Apple Kalender und Outlook"
        }
    }
    /// Only where the full title does not fit in one line (calendar sidebar
    /// with large text): the same words, shortened.
    var shortTitle: String { self == .system ? "Apple Kalender/Outlook" : title }
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

/// Draft of the event form: single events and series (B2) with an optional
/// reminder (B3, „Erinnerung“ in the form).
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
        case .timetable: return "WebUntis (Untis-Mobile-Freigabe)"
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
