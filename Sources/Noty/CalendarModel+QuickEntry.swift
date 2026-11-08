import Foundation
import NotebookCore

// „Schnell anlegen“ (Stufe C): one line of text → a pre-filled form.
// Moved out of CalendarModel+System.swift unchanged.

extension CalendarModel {
    // MARK: Schnell anlegen

    /// „Mathe Klausur Fr 10 Uhr“ → a pre-filled form draft (nothing saved;
    /// the user checks and confirms the form). Nil for an empty line or
    /// when nothing can be written now.
    func quickDraft(_ text: String) -> CalendarDraft? {
        guard canWrite, !showsSamples, let parsed = CalendarQuickEntry.parse(text, now: Date(), calendar: calendar) else { return nil }
        var draft = CalendarDraft(start: parsed.start, calendar: calendar)
        draft.title = parsed.title
        draft.allDay = parsed.allDay
        // The form shows the last day of all-day events (end inclusive).
        draft.end = parsed.allDay ? parsed.start : parsed.end
        return draft
    }

    /// Opens the form with `quickDraft(text)`.
    func requestQuickEvent(_ text: String) {
        guard draft == nil, let prepared = quickDraft(text) else { return }
        draft = prepared
    }
}
