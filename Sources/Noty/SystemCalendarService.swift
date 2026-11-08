import EventKit
import UIKit
import NotebookCore

/// Kalender Stufe C: Apple Kalender and Outlook (Exchange/Microsoft 365
/// accounts added under iPad-Einstellungen › Kalender › Accounts) through
/// EventKit. One event store for the app. Reads run off the main actor and
/// hand back plain `CalendarSystemEvent` values; writes run on the main
/// actor with a freshly fetched `EKEvent` (never one kept from an earlier
/// read). Nothing here claims a synchronisation: EventKit hands changes to
/// the system calendar, which delivers them to the account when it can.
@MainActor
final class SystemCalendarService {
    static let shared = SystemCalendarService()

    enum Access: Equatable {
        case notDetermined, denied, restricted, writeOnly, granted
        /// German explanation for the views (nil when granted).
        var problem: String? {
            switch self {
            case .granted: nil
            case .notDetermined: "Noch kein Zugriff auf die Kalender dieses iPads."
            case .denied: "noty darf die Kalender dieses iPads nicht lesen. Bitte unter iPad-Einstellungen › Apps › noty › Kalender „Vollzugriff“ erlauben."
            case .restricted: "Der Zugriff auf Kalender ist auf diesem iPad eingeschränkt (Bildschirmzeit oder Verwaltung)."
            case .writeOnly: "noty darf nur Termine hinzufügen, aber keine lesen. Bitte unter iPad-Einstellungen › Apps › noty › Kalender „Vollzugriff“ erlauben."
            }
        }
    }

    private(set) var store = EKEventStore()
    private var observer: NSObjectProtocol?
    /// Called (on the main actor, debounced) when the system store changed.
    var onChange: (() -> Void)?
    private var changeTask: Task<Void, Never>?

    private init() {
        observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.storeChanged() }
        }
    }

    var access: Access {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: .granted
        case .writeOnly: .writeOnly
        case .denied: .denied
        case .restricted: .restricted
        case .notDetermined: .notDetermined
        case .authorized: .granted
        @unknown default: .denied
        }
    }

    /// Asks iPadOS once (only on a deliberate „Verbinden“).
    func requestAccess() async -> Access {
        do { _ = try await store.requestFullAccessToEvents() } catch {}
        // A store created before the grant does not see the calendars yet.
        store = EKEventStore()
        return access
    }

    private func storeChanged() {
        changeTask?.cancel()
        changeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            self?.onChange?()
        }
    }

    // MARK: Reading

    func calendars() -> [CalendarSystemCalendar] {
        guard access == .granted else { return [] }
        return store.calendars(for: .event).map(Self.map).sorted {
            ($0.account, $0.title) < ($1.account, $1.title)
        }
    }

    static func map(_ calendar: EKCalendar) -> CalendarSystemCalendar {
        let color = UIColor(cgColor: calendar.cgColor)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        return CalendarSystemCalendar(id: calendar.calendarIdentifier, title: calendar.title, account: calendar.source?.title ?? "",
                                      colorHex: CalendarColorHex.hex(red: Double(r), green: Double(g), blue: Double(b)),
                                      writable: calendar.allowsContentModifications && !calendar.isImmutable)
    }

    /// The occurrences of the given calendars in [start, end), read off the
    /// main actor. Nil when there is no access.
    func events(from start: Date, to end: Date, calendarIDs: Set<String>, calendar: Calendar) async -> [CalendarSystemEvent]? {
        guard access == .granted else { return nil }
        let box = StoreBox(store: store)
        return await Task.detached(priority: .userInitiated) {
            let calendars = box.store.calendars(for: .event).filter { calendarIDs.contains($0.calendarIdentifier) }
            guard !calendars.isEmpty else { return [CalendarSystemEvent]() }
            var result: [CalendarSystemEvent] = []
            // EventKit limits one predicate to four years; the window is about 1.3.
            var from = start
            while from < end {
                let to = min(end, calendar.date(byAdding: .year, value: 1, to: from) ?? end)
                let predicate = box.store.predicateForEvents(withStart: from, end: to, calendars: calendars)
                for event in box.store.events(matching: predicate) {
                    if let value = Self.map(event, calendar: calendar), value.start < to || from == start { result.append(value) }
                }
                from = to
            }
            // An event spanning a chunk border comes twice: once is enough.
            var seen = Set<String>()
            return result.filter { seen.insert($0.id).inserted }
        }.value
    }

    nonisolated static func map(_ event: EKEvent, calendar: Calendar) -> CalendarSystemEvent? {
        guard let start = event.startDate, let end = event.endDate, let owner = event.calendar else { return nil }
        var from = start, to = end
        if event.isAllDay {
            // Civil days with an exclusive end (EventKit ends all-day events at 23:59:59 or the next midnight).
            from = calendar.startOfDay(for: start)
            let last = calendar.startOfDay(for: max(start, end.addingTimeInterval(-1)))
            to = calendar.date(byAdding: .day, value: 1, to: last) ?? from.addingTimeInterval(86_400)
        }
        let recurring = event.hasRecurrenceRules
        let original = recurring || event.isDetached ? event.occurrenceDate : nil
        // All-day and floating occurrences are local civil values (a time zone change must not orphan their notes).
        let local = original.flatMap { date in
            event.isAllDay || event.timeZone == nil ? CalendarSystemEvent.localKey(date, allDay: event.isAllDay, calendar: calendar) : nil
        }
        var value = CalendarSystemEvent(itemID: event.calendarItemIdentifier, externalID: event.calendarItemExternalIdentifier,
                                        calendarID: owner.calendarIdentifier, title: (event.title?.isEmpty == false ? event.title! : "Ohne Titel"),
                                        location: event.location ?? "", notes: event.notes ?? "", start: from, end: max(from, to),
                                        allDay: event.isAllDay, timeZone: event.timeZone?.identifier,
                                        occurrence: original,
                                        recurring: recurring, detached: event.isDetached, cancelled: event.status == .canceled,
                                        occurrenceLocal: local)
        value.title = String(value.title.prefix(300))
        return value
    }

    /// Details EventKit knows but the plain value does not carry.
    struct Extra {
        var rule: CalendarRecurrence?
        /// The series has a rule noty cannot show/edit (e.g. „jeden 2. Dienstag“).
        var complexRule: Bool
        var alarmMinutes: Int?
        var modified: Date?
    }

    func extra(for value: CalendarSystemEvent) -> Extra? {
        guard let event = find(value) else { return nil }
        var extra = Extra(rule: nil, complexRule: false, alarmMinutes: nil, modified: event.lastModifiedDate)
        if let rule = event.recurrenceRules?.first {
            extra.rule = Self.rule(rule, start: event.startDate, calendar: Calendar.current)
            extra.complexRule = extra.rule == nil || (event.recurrenceRules?.count ?? 0) > 1
        }
        if let offset = event.alarms?.first(where: { $0.absoluteDate == nil })?.relativeOffset, offset <= 0 {
            let minutes = Int((-offset / 60).rounded())
            extra.alarmMinutes = CalendarReminder.presets.contains(minutes) ? minutes : nil
        }
        return extra
    }

    /// A simple EventKit rule as noty's rule; nil when it has more than
    /// frequency, interval and end (weekdays, set positions, yearly …):
    /// „jeden 1. Montag im Monat“ (monthly with weekdays) or weekly on
    /// another weekday than the first occurrence's are complex, so noty
    /// keeps them unchanged instead of overwriting them with a plain rule.
    static func rule(_ rule: EKRecurrenceRule, start: Date?, calendar: Calendar) -> CalendarRecurrence? {
        let frequency: CalendarRecurrence.Frequency
        switch rule.frequency {
        case .daily: frequency = .daily
        case .weekly: frequency = .weekly
        case .monthly: frequency = .monthly
        default: return nil
        }
        let weekdays = rule.daysOfTheWeek ?? []
        if frequency == .monthly, !weekdays.isEmpty { return nil }
        if frequency == .daily, !weekdays.isEmpty { return nil }
        if frequency == .weekly, let day = weekdays.first {
            guard let start, day.weekNumber == 0, day.dayOfTheWeek.rawValue == calendar.component(.weekday, from: start) else { return nil }
        }
        if weekdays.count > 1 || rule.daysOfTheMonth?.isEmpty == false || rule.setPositions?.isEmpty == false
            || rule.monthsOfTheYear?.isEmpty == false || rule.weeksOfTheYear?.isEmpty == false || rule.daysOfTheYear?.isEmpty == false {
            return nil
        }
        var end = CalendarRecurrence.End.never
        if let recurrenceEnd = rule.recurrenceEnd {
            if recurrenceEnd.occurrenceCount > 0 { end = .afterCount(min(recurrenceEnd.occurrenceCount, CalendarRecurrence.maximumCount)) }
            else if let date = recurrenceEnd.endDate { end = .until(CivilDate(date, calendar: Calendar.current)) }
        }
        return CalendarRecurrence(frequency: frequency, interval: max(1, min(99, rule.interval)), end: end)
    }

    static func ekRule(_ rule: CalendarRecurrence, calendar: Calendar) -> EKRecurrenceRule {
        let frequency: EKRecurrenceFrequency
        switch rule.frequency {
        case .daily: frequency = .daily
        case .weekly: frequency = .weekly
        case .monthly: frequency = .monthly
        }
        var end: EKRecurrenceEnd?
        switch rule.end {
        case .never: end = nil
        case .afterCount(let count): end = EKRecurrenceEnd(occurrenceCount: count)
        case .until(let date):
            // Through the whole last day.
            end = EKRecurrenceEnd(end: calendar.date(byAdding: .second, value: 86_399, to: date.start(in: calendar)) ?? date.start(in: calendar))
        }
        return EKRecurrenceRule(recurrenceWith: frequency, interval: rule.interval, end: end)
    }

    // MARK: Writing

    /// The current `EKEvent` of an occurrence read before (same item and
    /// original occurrence, or same start for a single event).
    func find(_ value: CalendarSystemEvent) -> EKEvent? {
        guard access == .granted, let owner = store.calendar(withIdentifier: value.calendarID) else { return nil }
        let reference = value.occurrence ?? value.start
        let from = reference.addingTimeInterval(-2 * 86_400), to = max(value.end, reference).addingTimeInterval(2 * 86_400)
        let candidates = store.events(matching: store.predicateForEvents(withStart: from, end: to, calendars: [owner]))
            .filter { $0.calendarItemIdentifier == value.itemID }
        if let occurrence = value.occurrence {
            return candidates.first { abs(($0.occurrenceDate ?? $0.startDate).timeIntervalSince(occurrence)) < 1 }
        }
        return candidates.first ?? (store.calendarItem(withIdentifier: value.itemID) as? EKEvent)
    }

    /// The first occurrence (the series itself) of a recurring event.
    func series(_ value: CalendarSystemEvent) -> EKEvent? {
        store.calendarItem(withIdentifier: value.itemID) as? EKEvent
    }

    func writableCalendar(_ id: String) throws -> EKCalendar {
        guard access == .granted else { throw SystemCalendarError.noAccess(access.problem ?? "") }
        guard let calendar = store.calendar(withIdentifier: id) else { throw SystemCalendarError.calendarMissing }
        guard calendar.allowsContentModifications, !calendar.isImmutable else { throw SystemCalendarError.readOnly(calendar.title) }
        return calendar
    }

    func newEvent() -> EKEvent { EKEvent(eventStore: store) }

    func save(_ event: EKEvent, span: EKSpan) throws {
        do { try store.save(event, span: span, commit: true) }
        catch { store.reset(); throw SystemCalendarError.failed(error.localizedDescription) }
    }

    func remove(_ event: EKEvent, span: EKSpan) throws {
        do { try store.remove(event, span: span, commit: true) }
        catch { store.reset(); throw SystemCalendarError.failed(error.localizedDescription) }
    }
}

/// The store for the detached read (EventKit allows reads from a background thread).
private struct StoreBox: @unchecked Sendable { let store: EKEventStore }

enum SystemCalendarError: Error, LocalizedError {
    case noAccess(String)
    case calendarMissing
    case readOnly(String)
    case eventMissing
    case changedMeanwhile
    case failed(String)
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .noAccess(let reason): "Kein Zugriff auf die Kalender. \(reason)"
        case .calendarMissing: "Der Zielkalender ist auf diesem iPad nicht mehr vorhanden. Bitte einen anderen Kalender wählen."
        case .readOnly(let title): "Der Kalender „\(title)“ ist schreibgeschützt. Bitte einen anderen Kalender wählen."
        case .eventMissing: "Der Termin ist im Kalender nicht mehr vorhanden (zum Beispiel inzwischen gelöscht). Nichts wurde geändert."
        case .changedMeanwhile: "Der Termin wurde inzwischen im Kalender geändert. Damit nichts überschrieben wird, wurde nicht gespeichert. Bitte den Termin erneut öffnen."
        case .failed(let reason): "Der Kalender hat die Änderung nicht übernommen: \(reason)"
        case .unsupported(let reason): reason
        }
    }
}
