import SwiftUI
import EventKit
import NotebookCore

// Kalender Stufe C (docs/CALENDAR-PLAN.md): Apple Kalender and Outlook
// through the system calendar store (`SystemCalendarService`), plus the
// homework of WebUntis and the shared helpers for the views (origin text,
// colour, editability). System events are read anew on app activation, on
// system store changes and by hand; they are never stored in the calendar
// package and never reported as „synchronisiert“.

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
    /// The range read from the system store (nil: nothing read).
    var systemReadRange: (start: Date, end: Date)? { systemRead }

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
            : "Schulferien NRW aus eingebauter Tabelle (2025/26–2027/28, ohne Gewähr) und gesetzliche Feiertage NRW. Mit WebUntis-Ferien gelten die der Schule."
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

    /// A note written while the event had no server identity yet (new
    /// Exchange events get it after their first upload) takes it over once
    /// the store reports it, so the note follows to other devices' reads.
    private func upgradeSystemAnchors() async {
        var updates: [UUID: CalendarSystemAnchor] = [:]
        for link in state.noteLinks {
            guard case .system(let anchor) = link.target, anchor.externalID == nil,
                  case .found(let event) = CalendarSystemMatching.resolve(anchor, events: systemEvents, read: systemRead,
                                                                         contextStart: link.contextStart),
                  let external = event.externalID else { continue }
            updates[link.id] = CalendarSystemAnchor(externalID: external, itemID: anchor.itemID, calendarID: anchor.calendarID,
                                                    occurrence: anchor.occurrence)
        }
        guard !updates.isEmpty, canWrite else { return }
        await commit { state in
            for index in state.noteLinks.indices {
                if let anchor = updates[state.noteLinks[index].id] { state.noteLinks[index].target = .system(anchor) }
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
                try updateSystem(draft, value: value, scope: scope)
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
        event.location = draft.location.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlankText
        event.notes = draft.details.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlankText
        apply(checked.timing, to: event)
        if let rule = checked.rule { event.recurrenceRules = [SystemCalendarService.ekRule(rule, calendar: calendar)] }
        event.alarms = alarms(draft)
        try service.save(event, span: .thisEvent)
        guard let value = SystemCalendarService.map(event, calendar: calendar) else { throw SystemCalendarError.eventMissing }
        return value
    }

    /// Changes an existing system event. „Nur dieser Termin“ changes the
    /// occurrence (`EKSpan.thisEvent`); „Alle“ moves the series by the change
    /// of this occurrence and saves it with `.futureEvents` from its first
    /// occurrence. A change made meanwhile in the calendar is not overwritten.
    private func updateSystem(_ draft: CalendarDraft, value: CalendarSystemEvent, scope: SeriesScope) throws {
        let service = SystemCalendarService.shared
        _ = try service.writableCalendar(value.calendarID)
        guard let occurrence = service.find(value) else { throw SystemCalendarError.eventMissing }
        let known = draft.editing.flatMap { systemEditing[$0.id] }
        if let before = known?.modified, let now = occurrence.lastModifiedDate, now.timeIntervalSince(before) > 1 {
            throw SystemCalendarError.changedMeanwhile
        }
        let checked = try fields(draft)
        let series = value.recurring || value.detached
        let location = draft.location.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlankText
        let notes = draft.details.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlankText
        let newAlarm = draft.reminder ? draft.reminderMinutes : nil
        let alarmChanged = newAlarm != known?.alarmMinutes
        if !series || scope == .single {
            occurrence.title = checked.title; occurrence.location = location; occurrence.notes = notes
            apply(checked.timing, to: occurrence)
            if alarmChanged { occurrence.alarms = alarms(draft) }
            if !series, checked.rule != nil {
                if checked.rule?.exceptions.isEmpty == false {
                    throw SystemCalendarError.unsupported("Ausnahmen lassen sich für Termine in Apple Kalender/Outlook hier nicht eintragen.")
                }
                occurrence.recurrenceRules = checked.rule.map { [SystemCalendarService.ekRule($0, calendar: calendar)] }
            }
            try service.save(occurrence, span: .thisEvent)
            return
        }
        // „Alle Termine der Serie“.
        guard let master = service.series(value), let masterStart = master.startDate, let masterEnd = master.endDate,
              let shown = draft.editing else { throw SystemCalendarError.eventMissing }
        let delta = draft.allDay
            ? Double(CivilDate(shown.start, calendar: calendar).days(to: CivilDate(draft.start, calendar: calendar))) * 86_400
            : draft.start.timeIntervalSince(shown.start)
        master.title = checked.title; master.location = location; master.notes = notes
        if draft.allDay != master.isAllDay || !draft.allDay {
            let length = draft.allDay ? 0 : draft.end.timeIntervalSince(draft.start)
            let start = draft.allDay ? calendar.startOfDay(for: masterStart) : masterStart.addingTimeInterval(delta)
            master.isAllDay = draft.allDay
            master.startDate = start
            master.endDate = draft.allDay ? max(start, calendar.startOfDay(for: masterEnd)) : start.addingTimeInterval(length)
            if !draft.allDay, case .timed(_, _, let zone) = checked.timing { master.timeZone = TimeZone(identifier: zone) }
        } else if delta != 0 {
            let days = Int((delta / 86_400).rounded())
            master.startDate = calendar.date(byAdding: .day, value: days, to: masterStart)
            master.endDate = calendar.date(byAdding: .day, value: days, to: masterEnd)
        }
        if alarmChanged { master.alarms = alarms(draft) }
        if !hasComplexSystemRule(shown) {
            if let rule = checked.rule {
                if rule.exceptions != (known?.rule?.exceptions ?? []) && !rule.exceptions.isEmpty {
                    throw SystemCalendarError.unsupported("Ausnahmen lassen sich für Termine in Apple Kalender/Outlook hier nicht eintragen.")
                }
                if rule.frequency != known?.rule?.frequency || rule.end != known?.rule?.end || rule.interval != known?.rule?.interval {
                    master.recurrenceRules = [SystemCalendarService.ekRule(rule, calendar: calendar)]
                }
            } else {
                master.recurrenceRules = nil
            }
        }
        try service.save(master, span: .futureEvents)
        // The occurrences' original starts moved: their notes follow.
        let identity = value.anchor.identity
        if delta != 0, state.noteLinks.contains(where: { if case .system(let a) = $0.target { a.identity == identity } else { false } }) {
            Task { await commit { CalendarSystemNotes.shift(&$0.noteLinks, identity: identity, by: delta) } }
        }
    }

    /// A local single event goes to a system calendar: written there first,
    /// then (one commit) moved to „Gelöschte Termine“ with its notes now
    /// belonging to the new event. A failure before leaves everything as it was.
    private func moveLocal(_ draft: CalendarDraft, event id: UUID, to calendarID: String) async throws -> String? {
        guard let local = state.events.first(where: { $0.id == id }) else { return "Der Termin ist nicht mehr vorhanden." }
        guard local.recurrence == nil, draft.repeatRule == .never else {
            return "Serien lassen sich nicht zwischen noty und einem Systemkalender verschieben. Bitte die Serie im Zielkalender neu anlegen."
        }
        let created = try writeNewSystem(draft, calendarID: calendarID)
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
        }
        reloadSystemCalendars()
        notice = "„\(created.title)“ steht jetzt im Systemkalender; der noty-Termin liegt in „Gelöschte Termine“."
        return ok || unsaved ? nil : saveError
    }

    /// A system single event becomes a local one: the local event and its
    /// notes are committed first, then the system event is removed. If the
    /// removal fails, both exist (said so) – never none.
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
        }
        guard ok || unsaved else { return saveError }
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
        try updateSystem(draft, value: value, scope: .single)
        guard let event = service.store.calendarItem(withIdentifier: value.itemID) as? EKEvent else { throw SystemCalendarError.eventMissing }
        event.calendar = destination
        try service.save(event, span: .thisEvent)
        if let moved = SystemCalendarService.map(event, calendar: calendar), moved.anchor != value.anchor {
            let old = value.anchor, new = moved.anchor
            await commit { CalendarSourceMove.retarget(&$0.noteLinks, from: old, to: new) }
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

    // MARK: Homework (WebUntis)

    /// Homework of the offline timetable with the local „erledigt“ marks,
    /// sorted by due date. Empty without WebUntis.
    var homework: [CalendarHomeworkItem] {
        guard let snapshot, snapshot.connection == state.connection?.id else { return [] }
        return CalendarHomeworkItem.items(snapshot: snapshot, marks: state.homeworkDone, source: state.connection?.source)
    }

    /// Open (not done) homework.
    var openHomework: [CalendarHomeworkItem] { homework.filter { !$0.done } }

    func homework(dueOn day: Date) -> [CalendarHomeworkItem] {
        let date = CivilDate(day, calendar: calendar)
        return homework.filter { $0.homework.due == date }
    }

    /// Homework given in or due in this lesson.
    func homework(for entry: CalendarEntry) -> [CalendarHomeworkItem] {
        guard let lesson = snapshot?.lessons.first(where: { $0.id == entry.id }) else { return [] }
        return homework.filter { $0.homework.periodID == lesson.key.sourceID || $0.dueLessonID == lesson.key.sourceID }
    }

    /// „Erledigt“ is stored locally (calendar package, backup); WebUntis is not told.
    func setHomeworkDone(_ id: String, done: Bool) async {
        guard let source = state.connection?.source else { return }
        await commit { state in
            state.homeworkDone.removeAll { $0.source == source && $0.homeworkID == id }
            if done { state.homeworkDone.append(CalendarHomeworkMark(source: source, homeworkID: id)) }
            if state.homeworkDone.count > CalendarState.maximumHomeworkMarks {
                state.homeworkDone.sort { $0.doneAt < $1.doneAt }
                state.homeworkDone.removeFirst(state.homeworkDone.count - CalendarState.maximumHomeworkMarks)
            }
        }
    }

    func buildHomeworkIndex() {
        homeworkByPeriod = [:]; homeworkByDue = [:]
        guard let snapshot, snapshot.connection == state.connection?.id else { return }
        for item in snapshot.homework {
            homeworkByPeriod[item.periodID, default: []].append(item)
            if let course = item.lessonID { homeworkByDue[course + "|" + item.due.description, default: []].append(item) }
        }
    }

    /// Lines for a lesson's details: homework due in it and given in it.
    func homeworkNotes(for lesson: CalendarLesson) -> [String] {
        let due = lesson.key.seriesID.flatMap { homeworkByDue[$0 + "|" + lesson.date.description] } ?? []
        let given = (homeworkByPeriod[lesson.key.sourceID] ?? []).filter { item in !due.contains { $0.id == item.id } }
        guard !due.isEmpty || !given.isEmpty else { return [] }
        let done = Set(state.homeworkDone.filter { $0.source == state.connection?.source }.map(\.homeworkID))
        func line(_ item: CalendarHomework) -> String {
            (item.text.isEmpty ? "ohne Text" : String(item.text.prefix(200))) + (done.contains(item.id) ? " (erledigt)" : "")
        }
        return due.map { "Hausaufgabe fällig: " + line($0) }
            + given.map { "Hausaufgabe bis " + String(format: "%02d.%02d.", $0.due.day, $0.due.month) + ": " + line($0) }
    }
}

private extension String {
    var nilIfBlankText: String? { isEmpty ? nil : self }
}
