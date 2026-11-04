import Foundation

// Kalender review fixes (after B3): the pure parts of editing own events –
// how a change of „Alle Termine“ moves the single changed occurrences of a
// series, how note links follow a series, the undo snapshot of one change
// (event and its note links together) and the serial order of all calendar
// mutations of one area. No UI, no I/O.

extension CalendarSeries {
    /// The series after a change of „Alle Termine“ that turned the first
    /// occurrence `old` into `new`.
    ///
    /// Semantics (docs/STORAGE.md, calendar): exceptions, the end date and the
    /// identities (`originalDate`) of changed occurrences move by the civil
    /// days the first occurrence moved, so they keep meaning the same
    /// occurrences. A changed occurrence's own timing moves the same way the
    /// series did: by the same civil days and the same wall-clock change of
    /// start and end (in its time zone, daylight saving keeps the wall
    /// clock). Its own deviation (other day, other time) is kept relative.
    /// When the kind changes (timed ↔ all-day) only the days apply.
    public static func moved(_ rule: CalendarRecurrence, from old: CalendarEventTiming, to new: CalendarEventTiming) -> CalendarRecurrence {
        let days = firstDate(of: old).days(to: firstDate(of: new))
        var next = shifted(rule, byDays: days)
        let delta = Movement(old: old, new: new)
        next.overrides = next.overrides.map { item in
            var moved = item
            moved.timing = delta.apply(to: item.timing)
            return moved
        }
        return next
    }

    /// Change of start and end between two timings of the first occurrence.
    struct Movement {
        enum Kind { case wallClock(start: Int, end: Int), allDay(start: Int, end: Int), days(Int) }
        let kind: Kind

        init(old: CalendarEventTiming, new: CalendarEventTiming) {
            switch (old, new) {
            case (.timed(let a, let b, let oldZone), .timed(let c, let d, let newZone)):
                kind = .wallClock(start: CalendarSeries.wallSeconds(c, zone: newZone) - CalendarSeries.wallSeconds(a, zone: oldZone),
                                  end: CalendarSeries.wallSeconds(d, zone: newZone) - CalendarSeries.wallSeconds(b, zone: oldZone))
            case (.allDay(let a, let b), .allDay(let c, let d)):
                kind = .allDay(start: a.days(to: c), end: b.days(to: d))
            default:
                kind = .days(CalendarSeries.firstDate(of: old).days(to: CalendarSeries.firstDate(of: new)))
            }
        }

        func apply(to timing: CalendarEventTiming) -> CalendarEventTiming {
            switch (kind, timing) {
            case (.wallClock(let startDelta, let endDelta), .timed(let start, let end, let zone)):
                return Self.timed(start: start, end: end, zone: zone, startDelta: startDelta, endDelta: endDelta)
            case (.allDay(let startDays, let endDays), .allDay(let start, let end)):
                let newStart = start.adding(days: startDays)
                var newEnd = end.adding(days: endDays)
                if newEnd <= newStart { newEnd = newStart.adding(days: max(1, start.days(to: end))) }
                return .allDay(start: newStart, end: newEnd)
            case (.wallClock(let startDelta, _), .allDay(let start, let end)):
                // Timed series, all-day occurrence: whole days only.
                let days = Int((Double(startDelta) / 86_400).rounded(.down))
                return .allDay(start: start.adding(days: days), end: end.adding(days: days))
            case (.allDay(let startDays, _), .timed(let start, let end, let zone)),
                 (.days(let startDays), .timed(let start, let end, let zone)):
                return Self.timed(start: start, end: end, zone: zone, startDelta: startDays * 86_400, endDelta: startDays * 86_400)
            case (.days(let days), .allDay(let start, let end)):
                return .allDay(start: start.adding(days: days), end: end.adding(days: days))
            }
        }

        private static func timed(start: Date, end: Date, zone: String, startDelta: Int, endDelta: Int) -> CalendarEventTiming {
            let newStart = CalendarSeries.instant(wallSeconds: CalendarSeries.wallSeconds(start, zone: zone) + startDelta, zone: zone)
            var newEnd = CalendarSeries.instant(wallSeconds: CalendarSeries.wallSeconds(end, zone: zone) + endDelta, zone: zone)
            // Never shorter than nothing: a span that would end before it starts keeps its length.
            if newEnd <= newStart { newEnd = newStart.addingTimeInterval(end.timeIntervalSince(start)) }
            return .timed(start: newStart, end: newEnd, timeZone: zone)
        }
    }

    private static let wallEpoch = CivilDate(year: 2001, month: 1, day: 1)!

    /// Wall-clock position of `date` in `zone`: civil days since 2001-01-01
    /// times 86 400 plus the seconds of the day as the clock shows them.
    static func wallSeconds(_ date: Date, zone: String) -> Int {
        let calendar = zoned(zone)
        let parts = calendar.dateComponents([.hour, .minute, .second], from: date)
        let day = CivilDate(date, calendar: calendar)
        return wallEpoch.days(to: day) * 86_400 + (parts.hour ?? 0) * 3_600 + (parts.minute ?? 0) * 60 + (parts.second ?? 0)
    }

    /// The instant whose wall clock in `zone` reads `wallSeconds` (a time in
    /// a daylight-saving gap resolves as Foundation does).
    static func instant(wallSeconds: Int, zone: String) -> Date {
        let calendar = zoned(zone)
        let days = Int((Double(wallSeconds) / 86_400).rounded(.down))
        let rest = wallSeconds - days * 86_400
        let day = wallEpoch.adding(days: days)
        return calendar.date(from: DateComponents(year: day.year, month: day.month, day: day.day,
                                                  hour: rest / 3_600, minute: rest % 3_600 / 60, second: rest % 60))
            ?? day.start(in: calendar).addingTimeInterval(Double(rest))
    }
}

/// How note links of an own event follow its changes.
public enum CalendarNoteLinks {
    /// Single → series gives the old note to the first occurrence, series →
    /// single keeps the first occurrence's note, a moved series moves its
    /// occurrence notes along (by the civil days the first occurrence moved).
    public static func retarget(_ links: inout [CalendarNoteLink], event id: UUID, old: LocalCalendarEvent?, new: LocalCalendarEvent) {
        guard let old else { return }
        let oldFirst = CalendarSeries.firstDate(of: old.timing), newFirst = CalendarSeries.firstDate(of: new.timing)
        let shift = oldFirst.days(to: newFirst)
        for index in links.indices {
            guard case .local(let event, let date) = links[index].target, event == id else { continue }
            switch (old.recurrence != nil, new.recurrence != nil, date) {
            case (false, true, nil): links[index].target = .local(event: id, date: newFirst)
            case (true, false, let day?) where day == oldFirst: links[index].target = .local(event: id, date: nil)
            case (true, true, let day?) where shift != 0: links[index].target = .local(event: id, date: day.adding(days: shift))
            default: break
            }
        }
    }
}

/// „Rückgängig“ of one change of an own event: the event as it was and the
/// targets of its note links as they were, restored together in one commit.
public struct CalendarUndoSnapshot: Equatable, Sendable {
    public let eventID: UUID
    /// The event before the change (nil: it did not exist).
    public let event: LocalCalendarEvent?
    /// Link id → target before the change, for every link of this event.
    public let linkTargets: [UUID: CalendarNoteTarget]
    /// The „Gelöschte Termine“ entry the change created (removed again).
    public var trashID: UUID?

    public init(capturing state: CalendarState, event id: UUID, trashID: UUID? = nil) {
        eventID = id
        event = state.events.first { $0.id == id }
        var targets: [UUID: CalendarNoteTarget] = [:]
        for link in state.noteLinks {
            if case .local(let owner, _) = link.target, owner == id { targets[link.id] = link.target }
        }
        linkTargets = targets
        self.trashID = trashID
    }

    /// Applies the snapshot to the newest state. Links that exist only since
    /// the change stay as they are; links removed since stay removed (an
    /// undo never deletes or invents a link).
    public func restore(in state: inout CalendarState) {
        if let index = state.events.firstIndex(where: { $0.id == eventID }) {
            if let event { state.events[index] = event } else { state.events.remove(at: index) }
        } else if let event {
            state.events.append(event)
        }
        for index in state.noteLinks.indices {
            if let target = linkTargets[state.noteLinks[index].id] { state.noteLinks[index].target = target }
        }
        if let trashID { state.deletedEvents.removeAll { $0.id == trashID } }
    }
}

/// Serial order of every mutation of one area's calendar state (events,
/// links, settings, connection): each runs on the newest state after the
/// previous one has finished writing, so no transaction can build on a
/// state another one replaces meanwhile. Uncontended, `acquire()` returns
/// without suspending.
@MainActor
public final class CalendarMutationQueue {
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init() {}

    public var isBusy: Bool { busy }

    public func acquire() async {
        guard busy else { busy = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    /// Hands the turn to the next waiter (still busy) or frees the queue.
    public func release() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
    }
}
