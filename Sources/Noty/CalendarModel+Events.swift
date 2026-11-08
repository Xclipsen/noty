import Foundation
import NotebookCore

// Own events of the calendar (Stufe B2/B3): form saves, deletion,
// „Gelöschte Termine“, undo of the last change and drag/resize in
// week and day. Moved out of CalendarModel.swift unchanged.

extension CalendarModel {
    // MARK: Own events

    enum SeriesScope { case single, all }

    /// New or changed own event from the form. `scope`: for an occurrence of
    /// a series, „Nur dieser Termin“ or „Alle Termine der Serie“. Nil:
    /// applied (committed, or unsaved with the retry banner); otherwise the
    /// reason it was rejected and not applied.
    func save(_ draft: CalendarDraft, scope: SeriesScope = .all, target: CalendarWriteTarget? = nil) async -> String? {
        guard !showsSamples else { return "Im Beispielmodus werden keine Termine gespeichert." }
        // Apple Kalender/Outlook (Stufe C): written through EventKit, never
        // into the local state; moves between sources only for single events.
        if let routed = await saveRouted(draft, scope: scope, target: target) { return routed.problem }
        guard let title = CalendarState.validTitle(draft.title) else { return "Bitte einen Titel mit höchstens 200 Zeichen eingeben." }
        let (timing, problem) = draft.timing(calendar: calendar)
        guard let timing else { return problem }
        let location = draft.location.trimmingCharacters(in: .whitespacesAndNewlines)
        let details = draft.details.trimmingCharacters(in: .whitespacesAndNewlines)
        let (rule, ruleProblem) = draft.recurrence(calendar: calendar)
        if let ruleProblem { return ruleProblem }
        let reminder = draft.reminder ? draft.reminderMinutes : nil
        let now = Date()
        var savedEntryID: String?
        var undo: CalendarUndoSnapshot?
        var problemText: String?
        let ok = await commit { state in
            guard let id = draft.editing?.localID, let index = state.events.firstIndex(where: { $0.id == id }) else {
                let event = LocalCalendarEvent(title: title, location: location, details: details, timing: timing, recurrence: rule,
                                               reminderMinutes: reminder, createdAt: now)
                state.events.append(event)
                savedEntryID = rule == nil ? CalendarEntry.localID(event.id, nil) : CalendarEntry.localID(event.id, CalendarSeries.firstDate(of: timing))
                return
            }
            var event = state.events[index]
            let before = event
            let snapshot = CalendarUndoSnapshot(capturing: state, event: id)
            // The reminder belongs to the event (every occurrence of a series).
            event.reminderMinutes = reminder
            if let occurrence = draft.editing?.originalDate, event.recurrence != nil, scope == .single {
                // „Nur dieser Termin“: a changed occurrence with its own data.
                var series = event.recurrence!
                series.overrides.removeAll { $0.originalDate == occurrence }
                series.overrides.append(CalendarOccurrenceOverride(originalDate: occurrence, title: title, location: location,
                                                                   details: details, timing: timing))
                event.recurrence = series
                savedEntryID = CalendarEntry.localID(id, occurrence)
            } else {
                let oldFirst = CalendarSeries.firstDate(of: event.timing)
                var newTiming = timing
                var shift = 0
                if let shown = draft.editing, shown.originalDate != nil, event.recurrence != nil {
                    // „Alle Termine“ from one occurrence: the series moves by the days
                    // this occurrence moved (also when it was changed on its own before).
                    shift = CivilDate(shown.start, calendar: calendar).days(to: CivilDate(draft.start, calendar: calendar))
                    newTiming = Self.timing(timing, movedToDate: oldFirst.adding(days: shift), calendar: calendar)
                }
                event.title = title; event.location = location; event.details = details
                event.timing = newTiming
                if var newRule = rule {
                    // Keep exceptions/changes of the old series, moved along like
                    // the series (days and wall clock, CalendarSeries.moved). The
                    // occurrence the form was opened from takes the series' new
                    // values: its own change (if any) is dropped.
                    if var old = event.recurrence {
                        if let occurrence = draft.editing?.originalDate { old.overrides.removeAll { $0.originalDate == occurrence } }
                        let moved = CalendarSeries.moved(old, from: before.timing, to: newTiming)
                        newRule.exceptions = draft.exceptionsEdited ? draft.exceptions(calendar: calendar) : moved.exceptions
                        newRule.overrides = moved.overrides
                    }
                    event.recurrence = newRule
                } else {
                    event.recurrence = nil
                }
                CalendarNoteLinks.retarget(&state.noteLinks, event: id, old: before, new: event)
                savedEntryID = CalendarEntry.localID(id, event.recurrence == nil ? nil : (draft.editing?.originalDate?.adding(days: shift) ?? CalendarSeries.firstDate(of: newTiming)))
            }
            event.modifiedAt = now
            if let problem = event.timing.problem { problemText = problem; snapshot.restore(in: &state); return }
            state.events[index] = event
            undo = snapshot
        }
        if let problemText { return problemText }
        if let undo, let before = undo.event, ok || unsaved { lastUndo = UndoStep(text: "„\(before.title)“ geändert", snapshot: undo) }
        if let savedEntryID { selection = savedEntryID }
        // A failed write keeps the change in memory (banner with retry); only a
        // rejected change keeps the form open – a second tap must not duplicate.
        return ok || unsaved ? nil : saveError
    }

    /// `timing` (as entered for one occurrence) with its civil start date
    /// replaced by `date`, wall clock and length kept.
    private static func timing(_ timing: CalendarEventTiming, movedToDate date: CivilDate, calendar: Calendar) -> CalendarEventTiming {
        CalendarSeries.timing(on: date, base: timing)
    }

    /// Deletes an own event, or – `scope == .single` – one occurrence of a
    /// series (an exception). The event goes to „Gelöschte Termine“ (B3) and
    /// can be restored there with its identity; notes stay in the library and
    /// their links stay, so a restored event has its notes again.
    func remove(_ entry: CalendarEntry, scope: SeriesScope = .all) async {
        if isSystem(entry) { await removeSystem(entry, scope: scope); return }
        guard let id = entry.localID, state.events.contains(where: { $0.id == id }) else { return }
        if selection == entry.id { selection = nil }
        var undo: CalendarUndoSnapshot?
        var single = false
        var title = entry.title
        let ok = await commit { state in
            // The newest state (an earlier change may have finished meanwhile).
            guard let index = state.events.firstIndex(where: { $0.id == id }) else { return }
            let event = state.events[index]
            title = event.title
            single = scope == .single && event.recurrence != nil && entry.originalDate != nil
            let trash = CalendarDeletedEvent(event: event, occurrence: single ? entry.originalDate : nil)
            undo = CalendarUndoSnapshot(capturing: state, event: id, trashID: trash.id)
            if single, let date = entry.originalDate {
                if !state.events[index].recurrence!.exceptions.contains(date) { state.events[index].recurrence!.exceptions.append(date) }
                state.events[index].modifiedAt = Date()
            } else {
                state.events.remove(at: index)
            }
            Self.addToTrash(trash, in: &state)
        }
        if let undo, ok || unsaved {
            lastUndo = UndoStep(text: single ? "Termin „\(entry.title)“ am \(CalendarText.numericDate(entry.start, calendar: calendar)) gelöscht"
                                             : "„\(title)“ gelöscht", snapshot: undo)
        }
    }

    /// Newest first; beyond the limit the oldest entries make room (never an active event).
    private static func addToTrash(_ entry: CalendarDeletedEvent, in state: inout CalendarState) {
        state.deletedEvents.append(entry)
        if state.deletedEvents.count > CalendarState.maximumDeleted {
            state.deletedEvents.sort { $0.deletedAt < $1.deletedAt }
            state.deletedEvents.removeFirst(state.deletedEvents.count - CalendarState.maximumDeleted)
        }
    }

    /// Restores the event as it was before the last change, with its
    /// identity, and the targets of its note links in the same commit (a
    /// moved series takes its occurrence notes back).
    func undoLast() async {
        guard let step = lastUndo else { return }
        lastUndo = nil
        await commit { step.snapshot.restore(in: &$0) }
    }

    // MARK: Gelöschte Termine (B3)

    /// Newest first.
    var deletedEvents: [CalendarDeletedEvent] { state.deletedEvents.sorted { $0.deletedAt > $1.deletedAt } }

    /// Brings a deleted event (with its identity, so its notes appear again)
    /// or a deleted occurrence of a series back. Nil on success, otherwise why not.
    func restoreDeleted(_ id: UUID) async -> String? {
        guard canWrite else { return storageError ?? "Der Kalender ist noch nicht geladen." }
        guard let entry = state.deletedEvents.first(where: { $0.id == id }) else { return nil }
        var problem: String?
        let ok = await commit { state in
            if let date = entry.occurrence {
                guard let index = state.events.firstIndex(where: { $0.id == entry.event.id }) else {
                    problem = "Die Serie „\(entry.event.title)“ ist selbst gelöscht. Bitte zuerst die Serie wiederherstellen."; return
                }
                guard state.events[index].recurrence?.exceptions.contains(date) == true else {
                    problem = "Dieser Termin ist in der Serie nicht mehr gelöscht (die Serie wurde inzwischen geändert)."; return
                }
                state.events[index].recurrence!.exceptions.removeAll { $0 == date }
                state.events[index].modifiedAt = Date()
            } else {
                guard !state.events.contains(where: { $0.id == entry.event.id }) else {
                    problem = "Der Termin ist bereits vorhanden."; return
                }
                state.events.append(entry.event)
            }
            state.deletedEvents.removeAll { $0.id == id }
        }
        if let problem { return problem }
        return ok || unsaved ? nil : saveError
    }

    /// Removes an entry from „Gelöschte Termine“ for good. Notes and their
    /// links are never removed with it.
    func purgeDeleted(_ ids: Set<UUID>) async {
        guard canWrite, !ids.isEmpty else { return }
        await commit { $0.deletedEvents.removeAll { ids.contains($0.id) } }
    }

    // MARK: Undo

    func dismissUndo() { lastUndo = nil }

    // MARK: Drag and resize (own events, week/day)

    /// Snaps a drag to whole `snap` minutes and moves or stretches the event.
    /// Rejected spans are explained (`notice`); series ask first.
    func drag(_ entry: CalendarEntry, days: Int, minutes: Int, resize: Bool) {
        guard entry.writable, !entry.allDay, canWrite, !showsSamples, days != 0 || minutes != 0 else { return }
        guard let event = state.events.first(where: { $0.id == entry.localID }) else { return }
        let zone = event.timing.timeZoneID ?? calendar.timeZone.identifier
        var zoned = calendar; zoned.timeZone = TimeZone(identifier: zone) ?? calendar.timeZone
        func moved(_ date: Date) -> Date {
            let day = zoned.date(byAdding: .day, value: days, to: date) ?? date
            return zoned.date(byAdding: .minute, value: minutes, to: day) ?? day
        }
        let start = resize ? entry.start : moved(entry.start)
        let end = moved(entry.end)
        guard end.timeIntervalSince(start) >= 5 * 60 else {
            notice = "Ein Termin muss mindestens 5 Minuten dauern. Die Dauer wurde nicht geändert."
            return
        }
        let timing = CalendarEventTiming.timed(start: start, end: end, timeZone: zone)
        if let problem = timing.problem { notice = problem + " Der Termin wurde nicht verschoben."; return }
        let text = resize ? "Dauer von „\(entry.title)“ geändert" : "„\(entry.title)“ verschoben"
        let change = SeriesChange(entry: entry, timing: timing, days: days, minutes: minutes, resize: resize, text: text)
        if event.recurrence != nil, entry.originalDate != nil {
            pendingSeriesChange = change
            return
        }
        Task { await apply(change, scope: .all) }
    }

    func applyPendingSeriesChange(_ scope: SeriesScope) {
        guard let change = pendingSeriesChange else { return }
        pendingSeriesChange = nil
        Task { await apply(change, scope: scope) }
    }

    /// The first occurrence moved/stretched like the dragged one (wall clock
    /// in the series' time zone), or nil when that is no valid span.
    private func moved(_ timing: CalendarEventTiming, by change: SeriesChange) -> CalendarEventTiming? {
        guard case .timed(let start, let end, let zone) = timing else { return nil }
        var zoned = calendar; zoned.timeZone = TimeZone(identifier: zone) ?? calendar.timeZone
        func shift(_ date: Date) -> Date {
            let day = zoned.date(byAdding: .day, value: change.days, to: date) ?? date
            return zoned.date(byAdding: .minute, value: change.minutes, to: day) ?? day
        }
        let result = CalendarEventTiming.timed(start: change.resize ? start : shift(start), end: shift(end), timeZone: zone)
        return result.problem == nil ? result : nil
    }

    private func apply(_ change: SeriesChange, scope: SeriesScope) async {
        let timing = change.timing, entry = change.entry, text = change.text
        guard let id = entry.localID else { return }
        var undo: CalendarUndoSnapshot?
        let ok = await commit { state in
            guard let index = state.events.firstIndex(where: { $0.id == id }) else { return }
            let before = state.events[index]
            let snapshot = CalendarUndoSnapshot(capturing: state, event: id)
            var event = before
            if let occurrence = entry.originalDate, var series = event.recurrence {
                if scope == .single {
                    let existing = series.overrides.first { $0.originalDate == occurrence }
                    series.overrides.removeAll { $0.originalDate == occurrence }
                    series.overrides.append(CalendarOccurrenceOverride(originalDate: occurrence, title: existing?.title ?? event.title,
                        location: existing?.location ?? event.location, details: existing?.details ?? event.details, timing: timing))
                    event.recurrence = series
                } else {
                    guard let first = moved(event.timing, by: change) else { return }
                    // Changed occurrences move the same way (days and wall clock).
                    event.timing = first
                    event.recurrence = CalendarSeries.moved(series, from: before.timing, to: first)
                    CalendarNoteLinks.retarget(&state.noteLinks, event: id, old: before, new: event)
                }
            } else {
                event.timing = timing
            }
            event.modifiedAt = Date()
            state.events[index] = event
            undo = snapshot
        }
        if let undo, ok || unsaved { lastUndo = UndoStep(text: text, snapshot: undo) }
    }
}

extension CalendarEventTiming {
    var timeZoneID: String? { if case .timed(_, _, let zone) = self { zone } else { nil } }
}
