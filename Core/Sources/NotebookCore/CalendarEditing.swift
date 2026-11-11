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
    /// identities (`originalDate`) of changed occurrences keep meaning the
    /// same occurrences (`OccurrenceMove`): a daily or weekly series moves
    /// them by the civil days the first occurrence moved, a monthly series
    /// keeps them on the same occurrence of the series, because a month end
    /// makes the two differ (30 Apr → 1 May: the second occurrence moves from
    /// 30 May to 1 June, not to 31 May). A changed occurrence's own timing
    /// moves the same way the series did: by the civil days its occurrence
    /// moved and the same wall-clock change of start and end (in its time
    /// zone, daylight saving keeps the wall clock). Its own deviation (other
    /// day, other time) is kept relative. When the kind changes (timed ↔
    /// all-day) only the days apply. `newRule` is the rule the series gets
    /// when the same change also replaces it (the form); nil: `rule` stays.
    public static func moved(_ rule: CalendarRecurrence, from old: CalendarEventTiming, to new: CalendarEventTiming,
                             as newRule: CalendarRecurrence? = nil) -> CalendarRecurrence {
        let move = OccurrenceMove(from: old, rule: rule, to: new, rule: newRule ?? rule)
        let delta = Movement(old: old, new: new)
        var next = rule
        // A date that is no occurrence of the old series still moves by the
        // days; where it would land on a moved occurrence, the occurrence wins
        // (dates stay unique, CalendarRecurrence.validate).
        let exceptions = rule.exceptions.map { move.mapped($0) }
        let taken = Set(exceptions.filter(\.sameOccurrence).map(\.date))
        next.exceptions = exceptions.filter { $0.sameOccurrence || !taken.contains($0.date) }.map(\.date)
        let identities = rule.overrides.map { move.mapped($0.originalDate) }
        let changed = Set(identities.filter(\.sameOccurrence).map(\.date))
        next.overrides = zip(rule.overrides, identities).compactMap { item, identity in
            guard identity.sameOccurrence || !changed.contains(identity.date) else { return nil }
            var moved = item
            moved.originalDate = identity.date
            moved.timing = delta.apply(to: item.timing)
            // Its occurrence moved by other days than the first one (month end).
            let extra = item.originalDate.days(to: identity.date) - move.days
            if extra != 0 { moved.timing = Movement(days: extra).apply(to: moved.timing) }
            return moved
        }
        if case .until(let last) = rule.end { next.end = .until(move.until(last)) }
        return next
    }

    /// Where the original dates of a series' occurrences (exceptions,
    /// identities of changed occurrences, note and topic targets, „Gelöschte
    /// Termine“) go when „Alle Termine“ moves the series.
    ///
    /// Daily and weekly series, and any change that also replaces frequency
    /// or interval: by the civil days the first occurrence moved. A monthly
    /// series that stays monthly with the same interval: by occurrence – the
    /// date of the n-th month of the old series becomes the date of the n-th
    /// month of the new one. A month that lacks the day (31st, 29 February)
    /// has no occurrence; its date rests on the last day of that month, where
    /// the series generates nothing, and returns to its occurrence when the
    /// series moves back. So a deleted occurrence never comes back and a
    /// changed one is never lost.
    public struct OccurrenceMove: Sendable {
        /// Civil days the first occurrence moved.
        public let days: Int
        private let oldFirst: CivilDate
        private let newFirst: CivilDate
        /// Months between two occurrences; nil: plain day shift.
        private let interval: Int?

        public init(from old: CalendarEventTiming, rule oldRule: CalendarRecurrence,
                    to new: CalendarEventTiming, rule newRule: CalendarRecurrence) {
            oldFirst = CalendarSeries.firstDate(of: old)
            newFirst = CalendarSeries.firstDate(of: new)
            days = oldFirst.days(to: newFirst)
            let monthly = oldRule.frequency == .monthly && newRule.frequency == .monthly
                && oldRule.interval == newRule.interval && oldRule.interval >= 1 && days != 0
            interval = monthly ? oldRule.interval : nil
        }

        /// The date of the same occurrence after the move.
        public func date(_ date: CivilDate) -> CivilDate { mapped(date).date }

        /// `sameOccurrence`: mapped by occurrence (false: by the days, the
        /// date is no occurrence of the old series).
        func mapped(_ date: CivilDate) -> (date: CivilDate, sameOccurrence: Bool) {
            if let interval, let slot = Self.slot(of: date, first: oldFirst, interval: interval),
               let target = Self.nominal(slot, first: newFirst, interval: interval) {
                return (target, true)
            }
            return (date.adding(days: days), false)
        }

        /// The end date („bis“, inclusive) after the move: moved by the days,
        /// but never before the last occurrence the old series reached and
        /// never into a month the old end did not reach.
        func until(_ last: CivilDate) -> CivilDate {
            let plain = last.adding(days: days)
            guard let interval, last >= oldFirst else { return plain }
            // Last month of the series up to `last`, and the last real occurrence in it or before.
            var reached = ((last.year - oldFirst.year) * 12 + (last.month - oldFirst.month)) / interval
            if let date = Self.nominal(reached, first: oldFirst, interval: interval), date > last { reached -= 1 }
            var occurrence = max(0, reached)
            while occurrence > 0, Self.nominal(occurrence, first: oldFirst, interval: interval)?.day != oldFirst.day { occurrence -= 1 }
            guard let lower = Self.nominal(occurrence, first: newFirst, interval: interval),
                  let next = Self.nominal(max(0, reached) + 1, first: newFirst, interval: interval) else { return plain }
            return min(max(plain, lower), max(lower, next.adding(days: -1)))
        }

        /// The date of the `slot`-th month of a monthly series: the day of
        /// `first`, or the month's last day when it lacks that day.
        private static func nominal(_ slot: Int, first: CivilDate, interval: Int) -> CivilDate? {
            let months = first.year * 12 + (first.month - 1) + slot * interval
            let year = months / 12, month = months % 12 + 1
            var day = first.day
            while day > 28 {
                if let date = CivilDate(year: year, month: month, day: day) { return date }
                day -= 1
            }
            return CivilDate(year: year, month: month, day: day)
        }

        /// The month position of `date` in a monthly series, nil when the
        /// date is neither an occurrence nor the resting place of one.
        private static func slot(of date: CivilDate, first: CivilDate, interval: Int) -> Int? {
            let months = (date.year - first.year) * 12 + (date.month - first.month)
            guard months >= 0, months % interval == 0, nominal(months / interval, first: first, interval: interval) == date else { return nil }
            return months / interval
        }
    }

    /// Change of start and end between two timings of the first occurrence.
    struct Movement {
        enum Kind { case wallClock(start: Int, end: Int), allDay(start: Int, end: Int), days(Int) }
        let kind: Kind

        /// Whole civil days only.
        init(days: Int) { kind = .days(days) }

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
    /// How the occurrences of a series that stays a series move (nil: single event before or after).
    private static func occurrenceMove(old: LocalCalendarEvent, new: LocalCalendarEvent) -> CalendarSeries.OccurrenceMove? {
        guard let oldRule = old.recurrence, let newRule = new.recurrence else { return nil }
        return CalendarSeries.OccurrenceMove(from: old.timing, rule: oldRule, to: new.timing, rule: newRule)
    }

    /// The original date of the occurrence `date` of `old` after the change
    /// to `new` („Alle Termine“): the same occurrence, like its notes.
    public static func movedDate(_ date: CivilDate, old: LocalCalendarEvent, new: LocalCalendarEvent) -> CivilDate {
        occurrenceMove(old: old, new: new)?.date(date)
            ?? date.adding(days: CalendarSeries.firstDate(of: old.timing).days(to: CalendarSeries.firstDate(of: new.timing)))
    }

    /// Single → series gives the old note to the first occurrence, series →
    /// single keeps the first occurrence's note, a moved series moves its
    /// occurrence notes along (with their occurrence, `CalendarSeries.OccurrenceMove`).
    public static func retarget(_ links: inout [CalendarNoteLink], event id: UUID, old: LocalCalendarEvent?, new: LocalCalendarEvent) {
        guard let old else { return }
        let oldFirst = CalendarSeries.firstDate(of: old.timing), newFirst = CalendarSeries.firstDate(of: new.timing)
        let shift = oldFirst.days(to: newFirst)
        let move = occurrenceMove(old: old, new: new)
        for index in links.indices {
            guard case .local(let event, let date) = links[index].target, event == id else { continue }
            switch (old.recurrence != nil, new.recurrence != nil, date) {
            case (false, true, nil): links[index].target = .local(event: id, date: newFirst)
            case (true, false, let day?) where day == oldFirst: links[index].target = .local(event: id, date: nil)
            case (true, true, let day?) where shift != 0: links[index].target = .local(event: id, date: move?.date(day) ?? day.adding(days: shift))
            default: break
            }
        }
    }

    /// The whole state follows a change of an own event: its note links
    /// (above), the lesson topics keyed to its occurrences (format 5, same
    /// rules; a collision keeps the newer topic) and – for a moved series –
    /// the „Gelöschte Termine“ entries of its occurrences, whose date and
    /// series copy move along, so they stay restorable.
    public static func retarget(state: inout CalendarState, event id: UUID, old: LocalCalendarEvent?, new: LocalCalendarEvent) {
        retarget(&state.noteLinks, event: id, old: old, new: new)
        guard let old else { return }
        let oldFirst = CalendarSeries.firstDate(of: old.timing), newFirst = CalendarSeries.firstDate(of: new.timing)
        let shift = oldFirst.days(to: newFirst)
        let move = occurrenceMove(old: old, new: new)
        for index in state.lessonTopics.indices {
            guard case .local(let event, let date) = state.lessonTopics[index].target, event == id else { continue }
            switch (old.recurrence != nil, new.recurrence != nil, date) {
            case (false, true, nil): state.lessonTopics[index].target = .local(event: id, date: newFirst)
            case (true, false, let day?) where day == oldFirst: state.lessonTopics[index].target = .local(event: id, date: nil)
            case (true, true, let day?) where shift != 0: state.lessonTopics[index].target = .local(event: id, date: move?.date(day) ?? day.adding(days: shift))
            default: break
            }
        }
        // One topic per target: of two that now share one, the newer stays.
        var seen: [String: Int] = [:]
        var drop = Set<UUID>()
        for (index, topic) in state.lessonTopics.enumerated() {
            if let other = seen[topic.target.key] {
                let keep = state.lessonTopics[other].modifiedAt >= topic.modifiedAt ? other : index
                drop.insert(state.lessonTopics[keep == other ? index : other].id)
                seen[topic.target.key] = keep
            } else { seen[topic.target.key] = index }
        }
        if !drop.isEmpty { state.lessonTopics.removeAll { drop.contains($0.id) } }
        if old.recurrence != nil, let rule = new.recurrence, shift != 0 {
            for index in state.deletedEvents.indices where state.deletedEvents[index].event.id == id {
                guard let occurrence = state.deletedEvents[index].occurrence else { continue }
                let movedDate = move?.date(occurrence) ?? occurrence.adding(days: shift)
                // Only when the series as it is now still has that occurrence (else the entry keeps its old meaning).
                guard CalendarSeries.generates(movedDate, timing: new.timing, rule: rule) else { continue }
                state.deletedEvents[index].occurrence = movedDate
                state.deletedEvents[index].event = new
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
    /// Topic id → target before the change (format 5), for every topic of this event.
    public let topicTargets: [UUID: CalendarNoteTarget]
    /// „Gelöschte Termine“ entries of this event as they were (a moved series moves them).
    public let deleted: [UUID: CalendarDeletedEvent]
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
        var topics: [UUID: CalendarNoteTarget] = [:]
        for topic in state.lessonTopics {
            if case .local(let owner, _) = topic.target, owner == id { topics[topic.id] = topic.target }
        }
        topicTargets = topics
        deleted = Dictionary(state.deletedEvents.filter { $0.event.id == id }.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
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
        for index in state.lessonTopics.indices {
            if let target = topicTargets[state.lessonTopics[index].id] { state.lessonTopics[index].target = target }
        }
        for index in state.deletedEvents.indices {
            if let entry = deleted[state.deletedEvents[index].id] { state.deletedEvents[index] = entry }
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
