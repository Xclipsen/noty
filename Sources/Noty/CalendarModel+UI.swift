import SwiftUI
import NotebookCore

// View helpers of the calendar UI (no stored state): one place that knows
// how system calendar entries (Stufe C) differ from own entries and lessons
// in colour, name, lock and VoiceOver text.

extension CalendarModel {
    /// The calendar colour of a system entry, otherwise the usual palette.
    func entryColor(_ entry: CalendarEntry) -> Color { color(for: entry) ?? CalendarPalette.color(entry) }

    /// Lock shown: lessons, holidays, samples and read-only system calendars.
    func isReadOnly(_ entry: CalendarEntry) -> Bool {
        if entry.isSample { return true }
        if let info = systemInfo(for: entry) { return !info.writable }
        return entry.source.readOnly
    }

    /// „Stundenplan“, „Persönlich“, or the system calendar's own name.
    func sourceTitle(_ entry: CalendarEntry) -> String {
        systemInfo(for: entry)?.calendarTitle ?? entry.source.title
    }

    /// Account of a system entry („iCloud“, „Exchange“), nil otherwise.
    func sourceAccount(_ entry: CalendarEntry) -> String? {
        guard let account = systemInfo(for: entry)?.account, !account.isEmpty else { return nil }
        return account
    }

    /// VoiceOver text of cards and rows with the real calendar name and lock.
    func accessibilityText(_ entry: CalendarEntry, notes: Bool, homework: Bool = false) -> String {
        var parts = [entry.title, entry.allDay ? entry.timeText(calendar)
                     : "\(CalendarText.clock(entry.start, calendar: calendar)) bis \(CalendarText.clock(entry.end, calendar: calendar))"]
        if let room = entry.room { parts.append("Raum \(room)") }
        if let label = entry.status.label { parts.append(label) }
        if homework { parts.append("Hausaufgabe fällig") }
        if notes { parts.append("mit Notizen") }
        let title = sourceTitle(entry)
        parts.append(isReadOnly(entry) ? "\(title), schreibgeschützt" : title)
        return parts.joined(separator: ", ")
    }

    /// Entry ids of lessons in which open homework is due (one pass per render).
    var homeworkDueEntryIDs: Set<String> {
        let due = Set(openHomework.compactMap(\.dueLessonID))
        guard !due.isEmpty, let snapshot else { return [] }
        return Set(snapshot.lessons.filter { due.contains($0.key.sourceID) }.map(\.id))
    }
}
