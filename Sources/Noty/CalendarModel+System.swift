import SwiftUI
import EventKit
import NotebookCore

// Kalender Stufe C (docs/CALENDAR-PLAN.md): Apple Kalender and Outlook
// through the system calendar store (`SystemCalendarService`) and the shared
// helpers for the views (origin text, colour, editability); homework and
// „Schnell anlegen“ are in CalendarModel+Homework/+QuickEntry.swift.
// System events are read anew on app activation, on system store changes
// and by hand; they are never stored in the calendar package and never
// reported as „synchronisiert“.

extension CalendarEntry {
    /// Source of system calendar entries („Kalender“, read-only unless the
    /// single system calendar is writable – see `CalendarModel.canEdit`).
    static let systemSource: CalendarSource = .system
    static let systemPrefix = "system/"
}

/// What the views show about a system calendar entry.
struct CalendarSystemEntryInfo: Equatable {
    let event: CalendarSystemEvent
    /// Nil when the calendar is no longer in the store.
    let calendar: CalendarSystemCalendar?
    var calendarTitle: String { calendar?.title ?? "Unbekannter Kalender" }
    /// Account, e.g. „iCloud“, „Exchange“, „Outlook“.
    var account: String { calendar?.account ?? "" }
    var colorHex: String { calendar?.colorHex ?? "#8E8E93" }
    var writable: Bool { calendar?.writable ?? false }
    var recurring: Bool { event.recurring || event.detached }
}

extension CalendarModel {
    // MARK: State for the views

    /// The user connected the system calendars in this area.
    var systemEnabled: Bool { state.settings.systemCalendars?.enabled == true }
    var hiddenSystemCalendars: Set<String> { Set(state.settings.systemCalendars?.hiddenCalendars ?? []) }
    /// Shown, writable system calendars (targets of the form).
    var writableSystemCalendars: [CalendarSystemCalendar] {
        guard systemEnabled, systemAccess == .granted else { return [] }
        return systemCalendars.filter { $0.writable && !hiddenSystemCalendars.contains($0.id) }
    }
    /// Preselected target of new events.
    var systemDefaultTarget: CalendarWriteTarget {
        guard systemAccess == .granted,
              let id = CalendarSystemMatching.defaultTarget(state.settings.systemCalendars, calendars: systemCalendars) else { return .local }
        return .system(calendarID: id)
    }
    /// One line for the status popover; nil when system calendars are off.
    /// Never „synchronisiert“: the store was read, nothing more is known.
    var systemStatusText: String? {
        guard systemEnabled else { return nil }
        if let problem = systemAccess.problem { return "Apple Kalender/Outlook: " + problem }
        if let systemError { return "Apple Kalender/Outlook: " + systemError }
        if systemReading && systemLastRead == nil { return "Systemkalender werden eingelesen …" }
        guard let read = systemLastRead else { return "Systemkalender noch nicht eingelesen." }
        return "Systemkalender zuletzt eingelesen: " + standText(read).replacingOccurrences(of: "Stand: ", with: "")
    }

    /// Where the shown holidays come from (status popover, year view).
    var holidaySourceText: String {
        let fromWebUntis = !(snapshot?.holidays.isEmpty ?? true) && snapshot?.connection == state.connection?.id
        return fromWebUntis
            ? "Ferien laut WebUntis; außerhalb des WebUntis-Zeitraums Schulferien NRW aus eingebauter Tabelle; gesetzliche Feiertage NRW."
            : "Schulferien NRW aus eingebauter Tabelle (\(Self.holidayTableSpan), ohne Gewähr) und gesetzliche Feiertage NRW. Mit WebUntis-Ferien gelten die der Schule."
    }

    /// School years of the built-in NRW table, „2025/26–2027/28“ for `tableYears` 2025...2028.
    static var holidayTableSpan: String {
        let years = CalendarHolidaysNRW.tableYears
        func schoolYear(_ first: Int) -> String { "\(first)/" + String(format: "%02d", (first + 1) % 100) }
        return schoolYear(years.lowerBound) + "–" + schoolYear(years.upperBound - 1)
    }

    func isSystem(_ entry: CalendarEntry) -> Bool { entry.id.hasPrefix(CalendarEntry.systemPrefix) && systemByEntry[entry.id] != nil }

    func systemInfo(for entry: CalendarEntry) -> CalendarSystemEntryInfo? {
        guard let event = systemByEntry[entry.id] else { return nil }
        return CalendarSystemEntryInfo(event: event, calendar: systemCalendars.first { $0.id == event.calendarID })
    }

    /// Bearbeiten/Löschen offered: own events and events of writable system calendars.
    func canEdit(_ entry: CalendarEntry) -> Bool {
        guard canWrite, !showsSamples, !entry.isSample else { return false }
        if entry.writable { return true }
        guard let info = systemInfo(for: entry) else { return false }
        return info.writable && systemAccess == .granted
    }

    /// The calendar an entry is written to (nil: not writable).
    func writeTarget(of entry: CalendarEntry) -> CalendarWriteTarget? {
        if entry.writable { return .local }
        if let info = systemInfo(for: entry), info.writable { return .system(calendarID: info.event.calendarID) }
        return nil
    }

    /// Origin line of the details (replaces `entry.originText` for system
    /// events and the holiday fallback).
    func originText(for entry: CalendarEntry) -> String {
        if let info = systemInfo(for: entry) {
            let name = info.account.isEmpty ? info.calendarTitle : "\(info.calendarTitle) (\(info.account))"
            return "Systemkalender „\(name)“" + (info.writable ? "" : ", schreibgeschützt")
        }
        if entry.ghostLinkID != nil, case .system? = link(for: entry)?.target { return "Systemkalender, Termin derzeit nicht gefunden" }
        if entry.source == .holidays, !entry.isSample {
            if entry.id.hasPrefix("holiday/nrw/") { return "Schulferien NRW (eingebaute Tabelle, ohne Gewähr)" }
            if entry.id.hasPrefix("holiday/feiertag/") { return "Gesetzlicher Feiertag NRW" }
        }
        return entry.originText
    }

    /// Calendar colour of a system entry (nil: use the usual palette).
    func color(for entry: CalendarEntry) -> Color? {
        guard let info = systemInfo(for: entry), let c = CalendarColorHex.components(info.colorHex) else { return nil }
        return Color(red: c.red, green: c.green, blue: c.blue)
    }

    // MARK: Connecting

    /// Called once the package is loaded: observes the system store.
    func attachSystemService() {
        let service = SystemCalendarService.shared
        service.onChange = { [weak self] in self?.reloadSystemCalendars() }
        systemAccess = service.access
        if systemEnabled { reloadSystemCalendars() }
    }

    /// „Apple Kalender und Outlook verbinden“: asks iPadOS for full access
    /// (once) and switches the system calendars on for this area. Nil on
    /// success, otherwise why not.
    func connectSystemCalendars() async -> String? {
        guard canWrite else { return storageError ?? "Der Kalender ist noch nicht geladen." }
        var access = SystemCalendarService.shared.access
        if access == .notDetermined { access = await SystemCalendarService.shared.requestAccess() }
        systemAccess = access
        if let problem = access.problem { return problem }
        let ok = await commit { state in
            var settings = state.settings.systemCalendars ?? CalendarSystemSettings()
            settings.enabled = true
            state.settings.systemCalendars = settings
        }
        // Just connected: its events are shown even if the calendar was switched off before.
        if ok || unsaved { reveal(.system, announce: false) }
        reloadSystemCalendars()
        return ok || unsaved ? nil : saveError
    }

    /// Switches the system calendars off for this area. The system
    /// calendars, notes and their links stay untouched (connected again,
    /// the notes are found again).
    func disconnectSystemCalendars() async -> String? {
        guard systemEnabled else { return nil }
        let ok = await commit { $0.settings.systemCalendars?.enabled = false }
        systemGeneration += 1
        systemEvents = []; systemRead = nil; systemRequested = nil; systemLastRead = nil; systemError = nil
        if let entry = selectedEvent, isSystem(entry) { selection = nil }
        rebuild()
        return ok || unsaved ? nil : saveError
    }

    func setSystemCalendar(_ id: String, shown: Bool) async {
        await commit { state in
            var settings = state.settings.systemCalendars ?? CalendarSystemSettings()
            settings.hiddenCalendars.removeAll { $0 == id }
            if !shown { settings.hiddenCalendars.append(id) }
            if settings.hiddenCalendars.count > CalendarSystemSettings.maximumHidden {
                settings.hiddenCalendars.removeFirst(settings.hiddenCalendars.count - CalendarSystemSettings.maximumHidden)
            }
            state.settings.systemCalendars = settings
        }
    }

    /// Preselected target of new events („Persönlich“ or a system calendar).
    func setDefaultWriteTarget(_ target: CalendarWriteTarget) async {
        await commit { state in
            guard var settings = state.settings.systemCalendars else { return }
            settings.defaultTarget = target.calendarID
            state.settings.systemCalendars = settings
        }
    }

    // MARK: Reading

    /// Reads the calendars and the occurrences of the expansion window
    /// anew (off the main actor). Late answers of an older read are dropped.
    func reloadSystemCalendars() {
        let service = SystemCalendarService.shared
        systemAccess = service.access
        guard systemEnabled, loaded else { return }
        guard systemAccess == .granted else {
            // Access withdrawn: no external details any more; notes stay (shown as not available).
            systemGeneration += 1
            systemCalendars = []; systemEvents = []; systemRead = nil; systemRequested = nil; systemReading = false
            rebuild()
            return
        }
        systemCalendars = service.calendars()
        let range = expansionWindowDates()
        systemRequested = range
        systemGeneration += 1
        let generation = systemGeneration
        systemReading = true
        let ids = Set(systemCalendars.map(\.id))
        let calendar = calendar
        Task {
            let events = await service.events(from: range.start, to: range.end, calendarIDs: ids, calendar: calendar)
            guard generation == systemGeneration else { return }
            systemReading = false
            if let events {
                systemEvents = events
                systemRead = range
                systemLastRead = Date()
                systemError = nil
            } else {
                systemAccess = service.access
                systemEvents = []; systemRead = nil
            }
            rebuild()
            await upgradeSystemAnchors()
        }
    }

    /// App active again / calendar shown: the store is local, a read is cheap.
    func refreshSystemIfDue() {
        guard systemEnabled, !systemReading else { return }
        if let last = systemLastRead, Date().timeIntervalSince(last) < 30, SystemCalendarService.shared.access == systemAccess { return }
        reloadSystemCalendars()
    }

    func expansionWindowDates() -> (start: Date, end: Date) {
        let year = CalendarDates.startOfYear(anchor, calendar: calendar)
        let start = CivilDate(year, calendar: calendar).adding(days: -42)
        return (start.start(in: calendar), start.adding(days: 366 + 42 + 49).start(in: calendar))
    }

    /// The anchor left the read window: read the new one.
    func scheduleSystemReadIfNeeded() {
        guard systemEnabled, systemAccess == .granted, !systemReading else { return }
        let range = expansionWindowDates()
        if let requested = systemRequested, requested.start == range.start, requested.end == range.end { return }
        Task { @MainActor [weak self] in self?.reloadSystemCalendars() }
    }

    /// A note written while the event had no (or only a provisional)
    /// server identity – new Exchange events get their final one after the
    /// upload – takes over the identity the store reports now, when the
    /// event is the unique match of the note's device-local item id.
    private func upgradeSystemAnchors() async {
        var updates: [UUID: CalendarSystemAnchor] = [:]
        for link in state.noteLinks {
            guard case .system(let anchor) = link.target,
                  case .found(let event) = CalendarSystemMatching.resolve(anchor, events: systemEvents, read: systemRead,
                                                                         contextStart: link.contextStart),
                  event.itemID == anchor.itemID, let external = event.externalID, external != anchor.externalID else { continue }
            updates[link.id] = CalendarSystemAnchor(externalID: external, itemID: anchor.itemID, calendarID: anchor.calendarID,
                                                    occurrence: anchor.occurrence, occurrenceLocal: anchor.occurrenceLocal)
        }
        guard !updates.isEmpty, canWrite else { return }
        await commit { state in
            for index in state.noteLinks.indices {
                guard let anchor = updates[state.noteLinks[index].id] else { continue }
                // The event's topic follows its note to the new identity.
                if case .system(let old) = state.noteLinks[index].target {
                    CalendarSourceMove.retarget(topics: &state.lessonTopics, from: old, to: anchor)
                }
                state.noteLinks[index].target = .system(anchor)
            }
        }
    }

    // MARK: Index

    func systemEntry(_ event: CalendarSystemEvent) -> CalendarEntry {
        let info = systemCalendars.first { $0.id == event.calendarID }
        var entry = CalendarEntry(id: event.id, title: event.title, subject: event.title, source: CalendarEntry.systemSource,
                                  start: event.start, end: event.end, allDay: event.allDay,
                                  room: event.location.isEmpty ? nil : event.location,
                                  status: event.cancelled ? .cancelled : .normal,
                                  details: event.notes.isEmpty ? nil : String(event.notes.prefix(5_000)))
        entry.noteTarget = .system(event.anchor)
        entry.seriesID = event.itemID
        if let occurrence = event.anchor.occurrence { entry.originalDate = CivilDate(occurrence, calendar: calendar) }
        else if let local = event.anchor.occurrenceLocal { entry.originalDate = CivilDate(String(local.prefix(10))) }
        entry.repeatText = event.recurring || event.detached ? "Serie im Systemkalender" + (event.detached ? " · dieser Termin geändert" : "") : nil
        entry.colorName = info.map { CalendarColorHex.nearestName($0.colorHex) }
        let name = info.map { $0.account.isEmpty ? $0.title : "\($0.title) (\($0.account))" } ?? "Systemkalender"
        entry.statusNotes = ["Aus „\(name)“" + ((info?.writable ?? false) ? "" : ", schreibgeschützt")]
        return entry
    }

    /// Notes of system events: found → indicator at the event; otherwise a
    /// read-only stand-in at the last known time („ungeklärt“ with
    /// candidates of the same calendar, or „nicht verfügbar“). Only while
    /// the system calendars are on in this area.
    func indexSystemLinks() -> [CalendarEntry] {
        guard systemEnabled else { return [] }
        var ghosts: [CalendarEntry] = []
        let hidden = hiddenSystemCalendars
        for link in state.noteLinks {
            guard case .system(let anchor) = link.target else { continue }
            let resolution = CalendarSystemMatching.resolve(anchor, events: systemEvents, read: systemRead, contextStart: link.contextStart)
            if case .found(let event) = resolution {
                if !hidden.contains(event.calendarID), linkByEntry[event.id] == nil { linkByEntry[event.id] = link }
                continue
            }
            if hidden.contains(anchor.calendarID) { continue }
            var ghost = CalendarEntry(id: "note/\(link.id.uuidString)", title: link.contextTitle, subject: link.contextTitle,
                                      source: CalendarEntry.systemSource, start: link.contextStart, end: link.contextEnd)
            ghost.ghostLinkID = link.id
            switch resolution {
            case .unresolved(let found):
                ghost.status = .other("Ungeklärt: Der Termin steht so nicht mehr im Systemkalender (gelöscht, verschoben oder geändert). Die Notiz bleibt erhalten.")
                systemCandidates[link.id] = found.filter { !hidden.contains($0.calendarID) }.map(systemEntry)
            default:
                ghost.status = .other(systemAccess == .granted
                    ? "Termin nicht im eingelesenen Zeitraum des Systemkalenders. Die Notiz bleibt erhalten."
                    : "Systemkalender nicht verfügbar (kein Zugriff). Die Notiz bleibt erhalten.")
            }
            ghost.colorName = "gray"
            linkByEntry[ghost.id] = link
            ghosts.append(ghost)
        }
        return ghosts
    }

    /// The note of an „ungeklärt“ system event belongs to `chosen` (user
    /// choice from `systemCandidates`); never guessed from titles.
    func assign(_ ghost: CalendarEntry, toSystem chosen: CalendarEntry) async {
        guard let linkID = ghost.ghostLinkID, let event = systemByEntry[chosen.id],
              state.noteLinks.contains(where: { $0.id == linkID }) else { return }
        let anchor = event.anchor
        if await commit({ state in
            if let index = state.noteLinks.firstIndex(where: { $0.id == linkID }) { state.noteLinks[index].target = .system(anchor) }
        }) || unsaved { selection = chosen.id }
    }

    // MARK: Form

    func systemDraft(for entry: CalendarEntry) -> CalendarDraft {
        let extra = systemByEntry[entry.id].flatMap { SystemCalendarService.shared.extra(for: $0) }
        systemEditing[entry.id] = extra
        var draft = CalendarDraft(editing: entry, rule: extra?.complexRule == true ? nil : extra?.rule, base: nil, calendar: calendar)
        draft.reminder = extra?.alarmMinutes != nil
        draft.reminderMinutes = extra?.alarmMinutes ?? 10
        return draft
    }

    /// The entry is an occurrence of a system series (the form asks
    /// „Nur dieser Termin“ / „Alle“ also when noty cannot show the rule).
    func isSystemSeries(_ entry: CalendarEntry?) -> Bool {
        guard let entry, let event = systemByEntry[entry.id] else { return false }
        return event.recurring || event.detached
    }

    /// The system series has a rule noty does not show or change.
    func hasComplexSystemRule(_ entry: CalendarEntry?) -> Bool {
        guard let entry else { return false }
        return systemEditing[entry.id]?.complexRule == true
    }

    struct RoutedSave { let problem: String? }

    /// Nil: a plain local save (the caller continues). Otherwise the save
    /// went to (or between) the system calendars; `problem` nil on success.
    func saveRouted(_ draft: CalendarDraft, scope: SeriesScope, target: CalendarWriteTarget?) async -> RoutedSave? {
        let systemValue = draft.editing.flatMap { systemByEntry[$0.id] }
        let editingSystem = draft.editing.map { $0.id.hasPrefix(CalendarEntry.systemPrefix) } ?? false
        if editingSystem && systemValue == nil {
            return RoutedSave(problem: "Der Termin ist im Systemkalender nicht mehr eingelesen. Bitte den Kalender aktualisieren und erneut öffnen.")
        }
        let destination = target ?? (systemValue.map { .system(calendarID: $0.calendarID) } ?? .local)
        do {
            switch (systemValue, destination) {
            case (nil, .local):
                return nil
            case (nil, .system(let id)):
                if let editing = draft.editing, let localID = editing.localID {
                    return RoutedSave(problem: try await moveLocal(draft, event: localID, to: id))
                }
                _ = try writeNewSystem(draft, calendarID: id)
                reloadSystemCalendars()
                return RoutedSave(problem: nil)
            case (let value?, .system(let id)) where id == value.calendarID:
                try await updateSystem(draft, value: value, scope: scope)
                reloadSystemCalendars()
                return RoutedSave(problem: nil)
            case (let value?, .system(let id)):
                return RoutedSave(problem: try await moveSystem(draft, value: value, toCalendar: id))
            case (let value?, .local):
                return RoutedSave(problem: try await moveSystemToLocal(draft, value: value))
            }
        } catch {
            reloadSystemCalendars()
            return RoutedSave(problem: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    /// Checked fields of the form for EventKit.
    private func fields(_ draft: CalendarDraft) throws -> (title: String, timing: CalendarEventTiming, rule: CalendarRecurrence?) {
        guard let title = CalendarState.validTitle(draft.title) else {
            throw SystemCalendarError.unsupported("Bitte einen Titel mit höchstens 200 Zeichen eingeben.")
        }
        let (timing, problem) = draft.timing(calendar: calendar)
        guard let timing else { throw SystemCalendarError.unsupported(problem ?? "Ungültige Zeitspanne.") }
        let (rule, ruleProblem) = draft.recurrence(calendar: calendar)
        if let ruleProblem { throw SystemCalendarError.unsupported(ruleProblem) }
        return (title, timing, rule)
    }

    private func apply(_ timing: CalendarEventTiming, to event: EKEvent) {
        switch timing {
        case .timed(let start, let end, let zone):
            event.isAllDay = false
            event.timeZone = TimeZone(identifier: zone)
            event.startDate = start; event.endDate = end
        case .allDay(let start, let end):
            event.isAllDay = true
            event.startDate = start.start(in: calendar)
            // EventKit: the last day (inclusive) for all-day events.
            event.endDate = end.adding(days: -1).start(in: calendar)
        }
    }

    private func alarms(_ draft: CalendarDraft) -> [EKAlarm]? {
        draft.reminder ? [EKAlarm(relativeOffset: -Double(draft.reminderMinutes) * 60)] : nil
    }

    @discardableResult
    private func writeNewSystem(_ draft: CalendarDraft, calendarID: String) throws -> CalendarSystemEvent {
        let service = SystemCalendarService.shared
        let target = try service.writableCalendar(calendarID)
        let checked = try fields(draft)
        if checked.rule?.exceptions.isEmpty == false {
            throw SystemCalendarError.unsupported("Ausnahmen lassen sich für Termine in Apple Kalender/Outlook hier nicht eintragen. Bitte die Serie ohne Ausnahmen speichern und einzelne Termine danach löschen.")
        }
        let event = service.newEvent()
        event.calendar = target
        event.title = checked.title
        event.location = draft.location.nilIfBlank
        event.notes = draft.details.nilIfBlank
        apply(checked.timing, to: event)
        if let rule = checked.rule { event.recurrenceRules = [SystemCalendarService.ekRule(rule, calendar: calendar)] }
        event.alarms = alarms(draft)
        try service.save(event, span: .thisEvent)
        guard let value = SystemCalendarService.map(event, calendar: calendar) else { throw SystemCalendarError.eventMissing }
        return value
    }

    /// Changes an existing system event. „Nur dieser Termin“ changes the
    /// occurrence (`EKSpan.thisEvent`); „Alle“ moves the series by the change
    /// of this occurrence – whole civil days plus the wall-clock change, so
    /// it stays at its time over daylight saving – and saves it with
    /// `.futureEvents` from its first occurrence; the notes of its
    /// occurrences move the same way. A change made meanwhile in the
    /// calendar is not overwritten. Single ↔ series and all-day ↔ timed of a
    /// whole series are refused: note anchors would lose their occurrences.
    private func updateSystem(_ draft: CalendarDraft, value: CalendarSystemEvent, scope: SeriesScope) async throws {
        let service = SystemCalendarService.shared
        _ = try service.writableCalendar(value.calendarID)
        guard let occurrence = service.find(value) else { throw SystemCalendarError.eventMissing }
        let known = draft.editing.flatMap { systemEditing[$0.id] }
        if let before = known?.modified, let now = occurrence.lastModifiedDate, now.timeIntervalSince(before) > 1 {
            throw SystemCalendarError.changedMeanwhile
        }
        let checked = try fields(draft)
        let series = value.recurring || value.detached
        let location = draft.location.nilIfBlank
        let notes = draft.details.nilIfBlank
        let newAlarm = draft.reminder ? draft.reminderMinutes : nil
        let alarmChanged = newAlarm != known?.alarmMinutes
        if !series, checked.rule != nil {
            throw SystemCalendarError.unsupported("Aus einem einzelnen Termin im Systemkalender wird hier keine Serie. Bitte die Wiederholung in Apple Kalender bzw. Outlook einstellen.")
        }
        if !series || scope == .single {
            occurrence.title = checked.title; occurrence.location = location; occurrence.notes = notes
            apply(checked.timing, to: occurrence)
            if alarmChanged { occurrence.alarms = alarms(draft) }
            try service.save(occurrence, span: .thisEvent)
            return
        }
        // „Alle Termine der Serie“.
        guard let master = service.series(value), let masterStart = master.startDate, let masterEnd = master.endDate,
              let shown = draft.editing else { throw SystemCalendarError.eventMissing }
        guard let known else {
            throw SystemCalendarError.unsupported("Die Serie konnte nicht vollständig gelesen werden. Damit ihre Wiederholung nicht verloren geht, wurde nichts geändert. Bitte den Termin erneut öffnen.")
        }
        let complex = hasComplexSystemRule(shown)
        guard checked.rule != nil || complex || known.rule == nil else {
            throw SystemCalendarError.unsupported("Aus einer Serie im Systemkalender wird hier kein einzelner Termin (Notizen hängen an den einzelnen Terminen). Bitte die Wiederholung in Apple Kalender bzw. Outlook ändern.")
        }
        guard draft.allDay == master.isAllDay else {
            throw SystemCalendarError.unsupported("Ganztägig oder mit Uhrzeit lässt sich für eine ganze Serie im Systemkalender hier nicht umstellen.")
        }
        let days = CivilDate(shown.start, calendar: calendar).days(to: CivilDate(draft.start, calendar: calendar))
        let minutes = draft.allDay ? 0
            : CalendarText.minuteOfDay(draft.start, calendar: calendar) - CalendarText.minuteOfDay(shown.start, calendar: calendar)
        let zone = master.timeZone ?? calendar.timeZone
        master.title = checked.title; master.location = location; master.notes = notes
        let start = CalendarSystemNotes.wallClockShift(masterStart, days: days, minutes: minutes, timeZone: zone)
        master.startDate = start
        master.endDate = draft.allDay ? CalendarSystemNotes.wallClockShift(masterEnd, days: days, minutes: 0, timeZone: zone)
                                      : start.addingTimeInterval(max(0, draft.end.timeIntervalSince(draft.start)))
        if alarmChanged { master.alarms = alarms(draft) }
        // The rule is only touched when it was read completely and changed.
        if !complex, let old = known.rule, let rule = checked.rule {
            if !rule.exceptions.isEmpty {
                throw SystemCalendarError.unsupported("Ausnahmen lassen sich für Termine in Apple Kalender/Outlook hier nicht eintragen.")
            }
            if rule.frequency != old.frequency || rule.end != old.end || rule.interval != old.interval {
                master.recurrenceRules = [SystemCalendarService.ekRule(rule, calendar: calendar)]
            }
        }
        try service.save(master, span: .futureEvents)
        // The occurrences' original starts moved: their notes follow (same mapping).
        let identity = value.anchor.identity
        guard days != 0 || minutes != 0,
              state.noteLinks.contains(where: { if case .system(let a) = $0.target { a.identity == identity } else { false } }) else { return }
        let ok = await commit { CalendarSystemNotes.shift(&$0.noteLinks, identity: identity, days: days, minutes: minutes, timeZone: zone) }
        if !ok {
            notice = "Die Serie wurde im Kalender geändert, die Notizen ihrer Termine sind aber noch nicht umgehängt"
                + (unsaved ? " („Erneut speichern“)." : ": \(saveError ?? "unbekannter Fehler"). Sie erscheinen bis dahin als „ungeklärt“.")
        }
    }

    /// A local single event goes to a system calendar: written there first,
    /// then (one commit) moved to „Gelöschte Termine“ with its notes now
    /// belonging to the new event. A failure before leaves everything as it
    /// was; a refused commit keeps the created system event for the next
    /// „Fertig“ (never a second one).
    private func moveLocal(_ draft: CalendarDraft, event id: UUID, to calendarID: String) async throws -> String? {
        guard let local = state.events.first(where: { $0.id == id }) else { return "Der Termin ist nicht mehr vorhanden." }
        guard local.recurrence == nil, draft.repeatRule == .never else {
            return "Serien lassen sich nicht zwischen noty und einem Systemkalender verschieben. Bitte die Serie im Zielkalender neu anlegen."
        }
        let created: CalendarSystemEvent
        if let pending = pendingSystemMoves[id], pending.calendarID == calendarID, SystemCalendarService.shared.find(pending) != nil {
            created = pending
        } else {
            created = try writeNewSystem(draft, calendarID: calendarID)
            pendingSystemMoves[id] = created
        }
        let anchor = created.anchor
        let ok = await commit { state in
            guard let index = state.events.firstIndex(where: { $0.id == id }) else { return }
            let trash = CalendarDeletedEvent(event: state.events[index])
            state.events.remove(at: index)
            state.deletedEvents.append(trash)
            if state.deletedEvents.count > CalendarState.maximumDeleted {
                state.deletedEvents.sort { $0.deletedAt < $1.deletedAt }
                state.deletedEvents.removeFirst(state.deletedEvents.count - CalendarState.maximumDeleted)
            }
            CalendarSourceMove.retargetLocal(&state.noteLinks, event: id, to: anchor)
            CalendarSourceMove.retargetLocal(topics: &state.lessonTopics, event: id, to: anchor)
        }
        reloadSystemCalendars()
        if ok {
            pendingSystemMoves[id] = nil
            notice = "„\(created.title)“ steht jetzt im Systemkalender; der noty-Termin liegt in „Gelöschte Termine“."
            return nil
        }
        if unsaved {
            notice = "„\(created.title)“ steht jetzt im Systemkalender; das Entfernen aus noty ist noch nicht gespeichert („Erneut speichern“)."
            return nil
        }
        return (saveError ?? "Nicht gespeichert.") + " Der Termin steht bereits im Systemkalender; erneutes „Fertig“ legt ihn nicht noch einmal an."
    }

    /// A system single event becomes a local one: the local event and its
    /// notes are committed first, the system event is removed only after
    /// that commit is confirmed. Otherwise (or if the removal fails) both
    /// exist, said so – never none.
    private func moveSystemToLocal(_ draft: CalendarDraft, value: CalendarSystemEvent) async throws -> String? {
        guard !(value.recurring || value.detached), draft.repeatRule == .never else {
            return "Serien lassen sich nicht zwischen einem Systemkalender und noty verschieben."
        }
        let service = SystemCalendarService.shared
        _ = try service.writableCalendar(value.calendarID)
        guard let original = service.find(value) else { throw SystemCalendarError.eventMissing }
        let checked = try fields(draft)
        let event = LocalCalendarEvent(title: checked.title, location: draft.location.trimmingCharacters(in: .whitespacesAndNewlines),
                                       details: draft.details.trimmingCharacters(in: .whitespacesAndNewlines), timing: checked.timing,
                                       reminderMinutes: draft.reminder ? draft.reminderMinutes : nil)
        let anchor = value.anchor
        let ok = await commit { state in
            state.events.append(event)
            CalendarSourceMove.retargetSystem(&state.noteLinks, from: anchor, to: event.id)
            CalendarSourceMove.retargetSystem(topics: &state.lessonTopics, from: anchor, to: event.id)
        }
        guard ok else {
            reloadSystemCalendars()
            if unsaved {
                notice = "„\(event.title)“ ist in noty noch nicht gespeichert; der Termin bleibt deshalb auch im Systemkalender. Beide bestehen, bis „Erneut speichern“ gelingt; danach bitte den Systemtermin löschen."
                return nil
            }
            return (saveError ?? "Nicht gespeichert.") + " Der Termin bleibt im Systemkalender."
        }
        do { try service.remove(original, span: .thisEvent) }
        catch {
            notice = "„\(event.title)“ steht jetzt in noty, ist aber noch im Systemkalender vorhanden (\((error as? LocalizedError)?.errorDescription ?? "")). Bitte dort löschen."
        }
        selection = CalendarEntry.localID(event.id, nil)
        reloadSystemCalendars()
        return nil
    }

    /// A system single event goes to another system calendar.
    private func moveSystem(_ draft: CalendarDraft, value: CalendarSystemEvent, toCalendar id: String) async throws -> String? {
        guard !(value.recurring || value.detached) else {
            return "Serien lassen sich hier nicht in einen anderen Kalender verschieben. Bitte in Apple Kalender bzw. Outlook verschieben."
        }
        let service = SystemCalendarService.shared
        _ = try service.writableCalendar(value.calendarID)
        let destination = try service.writableCalendar(id)
        try await updateSystem(draft, value: value, scope: .single)
        guard let event = service.store.calendarItem(withIdentifier: value.itemID) as? EKEvent else { throw SystemCalendarError.eventMissing }
        event.calendar = destination
        try service.save(event, span: .thisEvent)
        if let moved = SystemCalendarService.map(event, calendar: calendar), moved.anchor != value.anchor {
            let old = value.anchor, new = moved.anchor
            await commit {
                CalendarSourceMove.retarget(&$0.noteLinks, from: old, to: new)
                CalendarSourceMove.retarget(topics: &$0.lessonTopics, from: old, to: new)
            }
        }
        reloadSystemCalendars()
        return nil
    }

    /// Deletes in the system calendar („Nur dieser Termin“: `.thisEvent`,
    /// „Alle“: the series from its first occurrence). Notes and their links
    /// stay; the note shows as „ungeklärt“ until it is unlinked. There is
    /// no noty „Gelöschte Termine“ entry for system events.
    func removeSystem(_ entry: CalendarEntry, scope: SeriesScope) async {
        guard let value = systemByEntry[entry.id] else { return }
        let service = SystemCalendarService.shared
        do {
            let calendarTitle = try service.writableCalendar(value.calendarID).title
            let series = value.recurring || value.detached
            if series && scope == .all {
                guard let master = service.series(value) else { throw SystemCalendarError.eventMissing }
                try service.remove(master, span: .futureEvents)
            } else {
                guard let occurrence = service.find(value) else { throw SystemCalendarError.eventMissing }
                try service.remove(occurrence, span: .thisEvent)
            }
            if selection == entry.id { selection = nil }
            notice = "„\(value.title)“ wurde im Kalender „\(calendarTitle)“ gelöscht. Notizen bleiben in „Kalendernotizen“."
        } catch {
            notice = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        reloadSystemCalendars()
    }
}
