import SwiftUI
import UIKit
import Combine
import NotebookCore

/// Calendar of one area (Stufe B2, docs/CALENDAR-PLAN.md). Lives with the
/// library of that area (`WorkspaceLibraryHost`), so an area switch gives a
/// new model and repository. Own events (also series), settings, note links
/// and lesson mappings are committed through `CalendarRepository`
/// (`<Bereich>/Calendar/`); WebUntis lessons and holidays come from the
/// replaceable source cache. Event notes are ordinary notebooks of the
/// library (`CalendarNoteSession`). „Beispieldaten“ is an explicit demo mode
/// that shows only fictitious entries and stores nothing.
@MainActor
final class CalendarModel: ObservableObject {
    let calendar = CalendarDates.german()
    let root: URL
    private let repository: CalendarRepository
    private(set) weak var library: LibraryModel?
    private var defaultAppearance: () -> NotebookAppearance = { NotebookAppearance() }
    private var subscriptions = Set<AnyCancellable>()

    // MARK: View state
    @Published var mode = CalendarMode.week { didSet { if mode != oldValue { persistSettings() } } }
    /// 5 = Monday–Friday, 7 = whole week (stored per area).
    @Published var weekDays = 5 { didSet { if weekDays != oldValue { persistSettings() } } }
    @Published var anchor = Date() { didSet { anchorMoved() } }
    @Published var selection: String? { didSet { if selection != oldValue { selectionChanged() } } }
    @Published var draft: CalendarDraft?
    @Published var hiddenSources: Set<CalendarSource> = [] { didSet { releaseVanishedSelection() } }
    /// Demo mode: only fictitious entries, nothing editable or stored. Off by default.
    @Published var showsSamples = false { didSet { if showsSamples != oldValue { selection = nil; sampleYear = nil; rebuild() } } }
    @Published private(set) var today = Date()
    /// The calendar is on screen; WebUntis is only asked while it is.
    var visible = false {
        didSet {
            if visible && !oldValue { refreshIfDue(); if let entry = selectedEvent { showNote(for: entry) } }
            if !visible && oldValue { releaseNote() }
        }
    }

    // MARK: Storage state
    @Published private(set) var loaded = false
    /// The calendar package could not be read safely: writing is locked.
    @Published private(set) var storageError: String?
    /// Last commit failed; the change stays in memory (`unsaved`).
    @Published private(set) var saveError: String?
    @Published private(set) var unsaved = false
    @Published private(set) var recoveredNotice: String?
    /// A short notice (rejected drag, failed change), dismissible.
    @Published var notice: String?
    /// Confirmed state (set only by `commit`/`transition`/`load`).
    var state = CalendarState()
    private var revision = 0
    /// Every change of `state` (events, links, settings, connection) runs in
    /// turn on the newest state, after the previous one finished writing.
    private let mutations = CalendarMutationQueue()
    private var applyingSettings = false

    // MARK: WebUntis
    @Published private(set) var snapshot: CalendarSourceSnapshot?
    @Published private(set) var syncing = false
    @Published private(set) var syncError: String?
    @Published private(set) var credentialsMissing = false
    @Published private(set) var lastSuccess: Date?
    private var lastAutomatic: Date?
    private var lastManual: Date?
    /// Bumped by connect/disconnect: late answers of an older session are dropped.
    private var generation = 0
    static let automaticInterval: TimeInterval = 15 * 60

    // MARK: System calendars (Stufe C; logic in CalendarModel+System.swift)
    /// Calendar access as last seen (asked only on „Systemkalender verbinden“).
    @Published var systemAccess: SystemCalendarService.Access = .notDetermined
    /// Every calendar of the system store (also hidden ones).
    @Published var systemCalendars: [CalendarSystemCalendar] = []
    @Published var systemReading = false
    /// Last read failed or a write was refused (shown, dismissible).
    @Published var systemError: String?
    /// „Systemkalender zuletzt eingelesen …“.
    @Published var systemLastRead: Date?
    /// Occurrences of all calendars in `systemRead` (also hidden calendars:
    /// notes of their events are matched, not shown).
    var systemEvents: [CalendarSystemEvent] = []
    var systemRead: (start: Date, end: Date)?
    var systemRequested: (start: Date, end: Date)?
    var systemGeneration = 0
    var systemByEntry: [String: CalendarSystemEvent] = [:]
    /// „Ungeklärt“ notes of system events → events the user may choose.
    var systemCandidates: [UUID: [CalendarEntry]] = [:]
    /// EventKit details of entries opened in the form (rule, alarm, last change).
    var systemEditing: [String: SystemCalendarService.Extra] = [:]
    /// Local event id → system event already created for a move noty → system
    /// whose commit was refused (reused by the next „Fertig“, never a second one).
    var pendingSystemMoves: [UUID: CalendarSystemEvent] = [:]
    /// Homework of the offline timetable by period id and by „course|due date“ (built per rebuild).
    var homeworkByPeriod: [String: [CalendarHomework]] = [:]
    var homeworkByDue: [String: [CalendarHomework]] = [:]

    // MARK: Undo of the last change (session; banner)
    struct UndoStep {
        let text: String
        /// The event and the targets of its note links before the change,
        /// plus the „Gelöschte Termine“ entry a deletion created.
        let snapshot: CalendarUndoSnapshot
    }

    // MARK: Reminders (B3)
    /// Notification permission as last seen (asked only when a reminder is switched on).
    @Published private(set) var reminderPermission: CalendarReminderCenter.Permission = .notDetermined
    /// „Erinnerungen geplant bis …“; nil when no reminder is on.
    @Published private(set) var remindersPlannedUntil: Date?
    @Published private(set) var plannedReminderCount = 0
    @Published private(set) var reminderError: String?
    @Published private(set) var lastUndo: UndoStep?

    // MARK: Benachrichtigungen (08.11.2026; logic in CalendarModel+Notifications.swift)
    /// Channel and area in every notification identifier and userInfo.
    let notificationNamespace: String
    /// The user's choices (device preference, `CalendarNotificationPreferences`).
    @Published var notificationSettings = CalendarNotificationPreferences.load()
    /// Bell history of this area (derived data, `CalendarNotificationLogFile`).
    @Published var notificationLog = CalendarNotificationLog()
    let notificationFile: CalendarNotificationLogFile
    var notificationLogVersion = 0
    /// Bumped when a notification or a bell entry opens something: the
    /// library switches to the calendar.
    @Published var openRequest = 0
    /// Bumped by „Untis-Zugang prüfen“ (push): the calendar opens the WebUntis sheet.
    @Published var connectionRequest = 0
    @Published var notificationHintDone = CalendarNotificationPreferences.hintDone
    /// `reminderPermission` was read at least once (no hint before that).
    var permissionChecked = false

    /// A drag of a series occurrence waits for „Nur dieser Termin“ / „Alle“.
    struct SeriesChange: Identifiable {
        let id = UUID()
        let entry: CalendarEntry
        /// The occurrence's new timing („Nur dieser Termin“).
        let timing: CalendarEventTiming
        /// The drag itself („Alle“: the first occurrence moves the same way).
        let days: Int, minutes: Int, resize: Bool
        let text: String
    }
    @Published var pendingSeriesChange: SeriesChange?

    // MARK: Notes
    @Published private(set) var noteSession: CalendarNoteSession?
    @Published private(set) var noteState: CalendarNoteState = .none
    /// A note not yet saved (draft) shown large over the calendar.
    @Published var enlargedDraft: CalendarNoteSession?
    /// Editors that could not commit when they were closed: kept (and retried)
    /// until they did, reused when their note is opened again.
    private var lingering: [UUID: EditorModel] = [:]
    /// Sessions of lingering notes that were never committed (no notebook
    /// yet): kept so their creation can be resumed without the event shown
    /// (background, area switch).
    private var parked: [UUID: CalendarNoteSession] = [:]
    /// Rule-8 runs per note target (resume after a failed step, same document).
    private var creations: [String: CalendarNoteCreation] = [:]
    private var noteQueue: Task<Void, Never>?

    // MARK: Index
    private var all: [CalendarEntry] = []
    private var byID: [String: CalendarEntry] = [:]
    private var byDay: [Date: [CalendarEntry]] = [:]
    var linkByEntry: [String: CalendarNoteLink] = [:]
    private(set) var candidates: [UUID: [CalendarLesson]] = [:]
    @Published private(set) var truncatedSeries: [String] = []
    private var sampleYear: Int?
    private var window: (start: CivilDate, end: CivilDate)?

    init(root: URL) {
        self.root = root
        repository = CalendarRepository(areaRoot: root)
        notificationNamespace = CalendarNotificationHub.namespace(root: root)
        notificationFile = CalendarNotificationLogFile(namespace: notificationNamespace)
        // Only the shown area plans reminders (an area switch replaces them).
        CalendarReminderCenter.shared.activate(root: root)
        CalendarNotificationHub.shared.attach(self)
        Task { await load() }
    }

    deinit {
        let repository = repository
        Task { await repository.close() }
    }

    /// The library of this area (notes are its notebooks) and the default
    /// appearance of new notebooks.
    func attach(library: LibraryModel, defaultAppearance: @escaping () -> NotebookAppearance) {
        guard self.library !== library else { return }
        self.library = library
        self.defaultAppearance = defaultAppearance
        library.releaseCalendarNote = { [weak self] in _ = await self?.closeNote() }
        library.$snapshot.dropFirst().receive(on: RunLoop.main).sink { [weak self] _ in
            MainActor.assumeIsolated { self?.libraryChanged() }
        }.store(in: &subscriptions)
        library.$opened.dropFirst().receive(on: RunLoop.main).sink { [weak self] opened in
            let closed = opened == nil
            MainActor.assumeIsolated {
                // Back from the full editor: the note beside the event opens again.
                guard let self, closed, self.visible, let entry = self.selectedEvent else { return }
                self.showNote(for: entry)
            }
        }.store(in: &subscriptions)
        libraryChanged()
    }

    var connection: CalendarConnectionRecord? { state.connection }
    var canWrite: Bool { loaded && storageError == nil }
    var localEventCount: Int { state.events.count }
    var hasRealData: Bool { !state.events.isEmpty || state.connection != nil || systemEnabled }
    var subjectColors: [String: String] { state.settings.subjectColors }

    // MARK: Loading and committing

    private func load() async {
        do {
            let result = try await repository.load()
            state = result.state
            applyingSettings = true
            weekDays = [5, 7].contains(state.settings.weekDays) ? state.settings.weekDays : 5
            mode = CalendarMode(rawValue: state.settings.mode) ?? .week
            applyingSettings = false
            if result.recovered {
                recoveredNotice = "Der neueste Kalenderstand war nicht lesbar; ein älterer geprüfter Stand wurde geladen. Die beschädigte Datei bleibt erhalten."
            }
            if let connection = state.connection {
                let keychain = WebUntisKeychain.read(connection.id)
                let setup = keychain.setup
                // Still locked (launched in the background before the first unlock): not „missing“.
                credentialsMissing = setup == nil && !keychain.locked
                do { snapshot = try await repository.sourceSnapshot() }
                catch { syncError = error.localizedDescription }
                // A B1 connection gets its account identity before any lesson note exists.
                if connection.sourceIdentity == nil, let setup, !state.noteLinks.contains(where: { if case .lesson = $0.target { true } else { false } }) {
                    let identity = WebUntis.sourceIdentity(setup)
                    loaded = true
                    await commit { $0.connection?.sourceIdentity = identity }
                }
            }
        } catch {
            storageError = error.localizedDescription
        }
        notificationLog = await notificationFile.read()
        loaded = true
        attachSystemService()
        rebuild()
        rescheduleReminders()
        if visible { refreshIfDue() }
        CalendarNotificationHub.shared.modelLoaded(self)
        // Push service (docs/PUSH.md): settings/token to the server, its history into the bell.
        Task { await CalendarPushClient.shared.sync(self) }
    }

    /// Applies `change` in memory and commits it. On failure the change stays
    /// shown but unsaved (with a retry); the committed state on disk is kept.
    @discardableResult
    func commit(_ change: (inout CalendarState) -> Void) async -> Bool {
        await mutations.acquire()
        defer { mutations.release() }
        guard canWrite else {
            saveError = storageError ?? "Der Kalender ist noch nicht geladen."
            return false
        }
        var next = state
        change(&next)
        do { try next.validate() } catch {
            saveError = error.localizedDescription
            return false
        }
        state = next
        rebuild()
        return await write(next)
    }

    private func write(_ next: CalendarState) async -> Bool {
        revision += 1
        let current = revision
        do {
            try await repository.save(next, revision: current)
            if current == revision { unsaved = false; saveError = nil; rescheduleReminders() }
            return true
        } catch {
            if current == revision {
                unsaved = true
                saveError = "Nicht gespeichert: \(error.localizedDescription)"
            }
            return false
        }
    }

    func retrySave() async {
        await mutations.acquire()
        defer { mutations.release() }
        _ = await write(state)
    }

    private func persistSettings() {
        guard !applyingSettings, loaded, canWrite else { return }
        let days = weekDays, mode = mode.rawValue
        guard state.settings.weekDays != days || state.settings.mode != mode else { return }
        Task { await commit { $0.settings.weekDays = days; $0.settings.mode = mode } }
    }

    func dismissNotices() { recoveredNotice = nil; notice = nil; if !unsaved { saveError = nil } }

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

    // MARK: Reminders (B3)

    /// Hands the reminders of this area to iPadOS (rolling window). Called on
    /// load, after every commit, after a WebUntis refresh and on app activation.
    func rescheduleReminders() {
        guard loaded else { return }
        Task { await rescheduleRemindersNow() }
    }

    /// Plans reminders and Morgen-Überblicke (`CalendarNotificationPlanner`)
    /// and takes delivered calendar notifications into the bell history.
    func rescheduleRemindersNow() async {
        guard loaded else { return }
        reminderPermission = await CalendarReminderCenter.shared.permission()
        permissionChecked = true
        // A detached connection (restored area, access data missing) shows its
        // timetable as outdated but never reminds from it.
        let plan = CalendarNotificationPlanner.plan(state: state, snapshot: credentialsMissing ? nil : snapshot,
                                                    systemEvents: systemEnabled ? systemEvents : [], settings: notificationSettings,
                                                    namespace: notificationNamespace, now: Date(), calendar: calendar)
        remindersPlannedUntil = plan.plannedUntil
        plannedReminderCount = plan.requests.count
        reminderError = await CalendarReminderCenter.shared.apply(plan, root: root, namespace: notificationNamespace)
        await collectDelivered()
    }

    /// The user switched a reminder on: asks iPadOS once.
    @discardableResult
    func requestReminderPermission() async -> CalendarReminderCenter.Permission {
        reminderPermission = await CalendarReminderCenter.shared.requestPermission()
        return reminderPermission
    }

    func refreshReminderPermission() async {
        reminderPermission = await CalendarReminderCenter.shared.permission()
    }

    var lessonReminderMinutes: Int? { state.settings.lessonReminderMinutes }

    /// „Unterricht: Erinnerung X Minuten vorher“ (nil = aus).
    func setLessonReminder(_ minutes: Int?) async {
        if minutes != nil { await requestReminderPermission() }
        await commit { $0.settings.lessonReminderMinutes = minutes }
    }
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

    // MARK: Subject colours

    func setSubjectColor(_ key: String, to name: String?) {
        guard canWrite, !showsSamples else { return }
        Task { await commit { if let name { $0.settings.subjectColors[key] = name } else { $0.settings.subjectColors[key] = nil } } }
    }

    /// Subjects of the offline timetable (key, shown name), sorted by name.
    var subjects: [(key: String, name: String)] {
        var seen: [String: String] = [:]
        for lesson in snapshot?.lessons ?? [] {
            let name = lesson.subjectLong ?? lesson.subject ?? lesson.title
            let key = CalendarSubjectColor.key(subjectID: lesson.subjectID, name: name)
            if seen[key] == nil { seen[key] = name }
        }
        return seen.map { (key: $0.key, name: $0.value) }.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
    }

    // MARK: WebUntis connection

    /// Stores the access data in the keychain, commits the connection record
    /// and loads the timetable. A failed commit removes the keychain item again.
    func connect(_ setup: WebUntisSetup, label: String) async throws {
        guard canWrite else { throw CalendarStoreError.locked }
        let record = CalendarConnectionRecord(label: String(label.prefix(200)), timeZone: "Europe/Berlin",
                                              sourceIdentity: WebUntis.sourceIdentity(setup))
        try WebUntisKeychain.save(setup, id: record.id)
        // In turn with every other calendar change: the record is set on the
        // newest state and nothing else can commit (or be replaced) meanwhile.
        let result = await transition { $0.connection = record }
        guard let old = result.before else {
            try? WebUntisKeychain.delete(record.id)
            throw CalendarConnectionCommitError(reason: result.failure)
        }
        generation += 1
        syncing = false
        syncError = nil
        snapshot = nil
        lastSuccess = nil
        credentialsMissing = false
        if let old = old.connection {
            try? await repository.removeSourceCache(connection: old.id)
            try? WebUntisKeychain.delete(old.id)
        }
        showsSamples = false
        snapshot = try? await repository.sourceSnapshot()
        rebuild()
        rescheduleReminders()
        await refresh(manual: true)
        // Push follows a new Freigabe of its area (with the consent given before).
        await CalendarPushClient.shared.connectionChanged(self, from: old.connection?.id, to: record.id)
    }

    /// Removes connection record, offline timetable and access data. Own
    /// events, notes and their links stay (the same „Freigabe“ connected
    /// again finds them).
    func disconnect() async -> String? {
        guard state.connection != nil else { return nil }
        // In turn: no other change can bring the record back after this commit.
        let result = await transition { $0.connection = nil }
        guard let old = result.before else { return "Trennen wurde nicht gespeichert: " + (result.failure ?? "unbekannter Fehler") }
        guard let record = old.connection else { return nil }
        generation += 1
        syncing = false
        syncError = nil
        lastSuccess = nil
        credentialsMissing = false
        snapshot = nil
        var problems: [String] = []
        do { try await repository.removeSourceCache(connection: record.id) } catch { problems.append("Offline-Stundenplan: \(error.localizedDescription)") }
        do { try WebUntisKeychain.delete(record.id) } catch { problems.append("Zugangsdaten: \(error.localizedDescription)") }
        // Only WebUntis entries go away (own and system calendar entries stay).
        if let entry = selectedEvent, entry.source == .timetable || entry.source == .holidays { selection = nil }
        rebuild()
        // Push service: its copy of the Freigabe is deleted as well; „gelöscht“ only after the server confirmed.
        let push = CalendarPushClient.shared
        let wasPush = push.state.connectionID == record.id && push.state.registered
        await push.connectionChanged(self, from: record.id, to: nil)
        if wasPush, push.state.pendingDelete {
            problems.append("Die Freigabe auf dem noty-Server ist noch nicht gelöscht (keine Verbindung); noty wiederholt das beim nächsten Start")
        }
        return problems.isEmpty ? nil : "Getrennt, aber nicht alles entfernt: " + problems.joined(separator: "; ")
    }

    /// Connection change as one transaction in the mutation queue: applied to
    /// the newest state and kept only when committed (a failed write leaves
    /// the state, and an earlier unsaved change, exactly as they were).
    /// `before`: the state before the change, nil when it was not committed
    /// (then `failure` says why).
    private func transition(_ change: (inout CalendarState) -> Void) async -> (before: CalendarState?, failure: String?) {
        await mutations.acquire()
        defer { mutations.release() }
        guard canWrite else { return (nil, storageError ?? "Der Kalender ist noch nicht geladen.") }
        let before = state
        var next = state
        change(&next)
        do { try next.validate() } catch { return (nil, error.localizedDescription) }
        let wasUnsaved = unsaved, previousError = saveError
        guard await write(next) else {
            // Memory still matches what was on disk before this attempt: no
            // retry banner for a state that was never shown.
            let failure = saveError
            unsaved = wasUnsaved
            saveError = wasUnsaved ? previousError : nil
            return (nil, failure)
        }
        state = next
        return (before, nil)
    }

    /// Calendar shown or app active again: refresh when the last automatic
    /// attempt is at least 15 minutes old.
    func refreshIfDue() {
        if visible, loaded { refreshSystemIfDue() }
        guard visible, loaded, state.connection != nil, !syncing, !credentialsMissing else { return }
        if let last = lastAutomatic, Date().timeIntervalSince(last) < Self.automaticInterval { return }
        Task { await refresh(manual: false) }
    }

    /// Background refresh (`CalendarNotificationHub`): the same refresh, the
    /// same repository and the same 15-minute minimum as `refreshIfDue`, only
    /// without the calendar on screen. Too early: just the plan is renewed.
    func backgroundRefresh() async {
        guard loaded, canWrite, state.connection != nil, !syncing, !credentialsMissing,
              notificationSettings.changes || notificationSettings.overview else { await rescheduleRemindersNow(); return }
        if let last = lastAutomatic, Date().timeIntervalSince(last) < Self.automaticInterval { await rescheduleRemindersNow(); return }
        await refresh(manual: false, background: true)
    }

    /// Worth asking iPadOS for background time: a timetable whose changes
    /// or overview the user wants.
    var wantsBackgroundRefresh: Bool {
        loaded && canWrite && state.connection != nil && !credentialsMissing
            && (notificationSettings.changes || notificationSettings.overview)
    }

    /// „Aktualisieren“: the default window plus the shown range (if small).
    func refreshNow() {
        if let last = lastManual, Date().timeIntervalSince(last) < 10 { return }
        lastManual = Date()
        Task { await refresh(manual: true) }
    }

    /// Default window: from the week before this one, six weeks.
    private func defaultWindow() -> (CivilDate, CivilDate) {
        let start = CivilDate(CalendarDates.day(-7, after: CalendarDates.startOfWeek(Date(), calendar: calendar), calendar: calendar), calendar: calendar)
        return (start, start.adding(days: 42))
    }

    private func shownWindow() -> (CivilDate, CivilDate)? {
        guard mode != .year else { return nil }
        let range = CalendarDates.range(mode, anchor: anchor, weekDays: 7, calendar: calendar)
        let start = CivilDate(range.start, calendar: calendar), end = CivilDate(range.end, calendar: calendar)
        guard start < end, start.days(to: end) <= CalendarSourceSnapshot.maximumRequestDays else { return nil }
        return (start, end)
    }

    /// Loads the shown range („Zeitraum laden“).
    func loadShownRange() {
        guard let window = shownWindow() else { return }
        Task { await refresh(manual: true, windows: [window]) }
    }

    /// `background`: run by the background refresh – missing or still locked
    /// access data and a cancelled request change nothing that is shown.
    func refresh(manual: Bool, windows: [(CivilDate, CivilDate)]? = nil, background: Bool = false) async {
        guard let connection = state.connection, !syncing else { return }
        let keychain = WebUntisKeychain.read(connection.id)
        guard let setup = keychain.setup else {
            if background || keychain.locked { return }
            credentialsMissing = true
            syncError = "Zugang auf diesem Gerät neu verbinden (Zugangsdaten fehlen auf diesem iPad, zum Beispiel nach einer Wiederherstellung)."
            return
        }
        var ranges = windows ?? [defaultWindow()]
        if windows == nil, manual, let shown = shownWindow(),
           !(shown.0 >= ranges[0].0 && shown.1 <= ranges[0].1) { ranges.append(shown) }
        let session = generation
        // Baseline of the change detection: the timetable as it was before this refresh.
        let before = snapshot
        syncing = true
        if !manual || windows == nil { lastAutomatic = Date() }
        let client = WebUntisClient(setup: setup)
        defer { client.finish(); if session == generation { syncing = false } }
        let zone = TimeZone(identifier: connection.timeZone) ?? .current
        do {
            let started = Date()
            let user = try await client.user()
            guard session == generation, state.connection?.id == connection.id else { return }
            snapshot = try await repository.replaceHolidays(user.holidays, fetchedAt: started, connection: connection.id)
            for range in ranges {
                let requested = Date()
                let answer = try await client.timetable(user: user, start: range.0, end: range.1, connection: connection.id, timeZone: zone)
                guard session == generation, state.connection?.id == connection.id else { return }
                snapshot = try await repository.merge(CalendarTimetableFetch(connection: connection.id, start: range.0, end: range.1,
                                                                             fetchedAt: requested, lessons: answer.lessons,
                                                                             homework: answer.homework))
            }
            syncError = nil
            lastSuccess = Date()
        } catch {
            guard session == generation else { return }
            // iPadOS ended the background time: no error to show.
            let cancelled = error is CancellationError || (error as? URLError)?.code == .cancelled
            if !(background && cancelled) { syncError = WebUntisClient.message(error) }
        }
        // Days merged before a later range failed are complete days as well.
        if session == generation, state.connection?.id == connection.id { await recordChanges(since: before) }
        rebuild()
        await rescheduleRemindersNow()
    }

    // MARK: Index of shown entries

    /// Series are expanded around the anchor's year (Jahr view included).
    private func expansionWindow() -> (start: CivilDate, end: CivilDate) {
        let year = CalendarDates.startOfYear(anchor, calendar: calendar)
        let start = CivilDate(year, calendar: calendar).adding(days: -42)
        return (start, start.adding(days: 366 + 42 + 49))
    }

    private func anchorMoved() {
        if showsSamples { prepareSamples(); return }
        let needed = CivilDate(anchor, calendar: calendar)
        if let window, needed >= window.start.adding(days: 42), needed < window.end.adding(days: -49) { return }
        rebuild()
    }

    func rebuild() {
        var entries: [CalendarEntry] = []
        linkByEntry = [:]
        candidates = [:]
        systemCandidates = [:]
        var truncated: [String] = []
        if showsSamples {
            let year = calendar.component(.year, from: anchor)
            sampleYear = year
            entries = CalendarSamples.events(year: anchor, today: today, calendar: calendar)
        } else {
            let range = expansionWindow()
            window = range
            let expansion = CalendarSeries.expand(state.events, from: range.start, to: range.end)
            let byEvent = Dictionary(state.events.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            entries = expansion.occurrences.compactMap { occurrence in byEvent[occurrence.eventID].map { entry(occurrence, of: $0) } }
            truncated = expansion.truncated.compactMap { byEvent[$0]?.title }
            var webUntisHolidays: [CalendarHoliday] = []
            buildHomeworkIndex()
            if let snapshot, snapshot.connection == state.connection?.id {
                entries += snapshot.lessons.map(entry)
                webUntisHolidays = snapshot.holidays
            }
            entries += holidayEntries(from: range.start, to: range.end, webUntis: webUntisHolidays)
            systemByEntry = [:]
            for event in CalendarSystemMatching.visible(systemEvents, settings: state.settings.systemCalendars) {
                systemByEntry[event.id] = event
                entries.append(systemEntry(event))
            }
            entries += indexLinks(entries)
            scheduleSystemReadIfNeeded()
        }
        truncatedSeries = truncated
        all = entries
        byID = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var index: [Date: [CalendarEntry]] = [:]
        for entry in entries {
            var day = calendar.startOfDay(for: entry.start)
            let stop = entry.allDay ? max(entry.end, CalendarDates.day(1, after: day, calendar: calendar)) : entry.end
            var guardCount = 0
            repeat {
                index[day, default: []].append(entry)
                day = CalendarDates.day(1, after: day, calendar: calendar)
                guardCount += 1
            } while day < stop && guardCount < 400
        }
        byDay = index
        objectWillChange.send()
        releaseVanishedSelection()
    }

    /// The selected entry is gone (source hidden, refresh, a system event
    /// with a new identifier): end the selection through the normal path,
    /// so the note is committed and released instead of lingering hidden.
    private func releaseVanishedSelection() {
        if selection != nil, selectedEvent == nil { selection = nil }
    }

    /// Days the index holds entries for (series expansion, samples); outside,
    /// `events(on:)` knows nothing – which is not „keine Termine“.
    var indexedRange: (start: Date, end: Date)? {
        if showsSamples {
            let year = CalendarDates.startOfYear(anchor, calendar: calendar)
            return (CalendarDates.day(-14, after: year, calendar: calendar), CalendarDates.day(380, after: year, calendar: calendar))
        }
        guard let window else { return nil }
        return (window.start.start(in: calendar), window.end.start(in: calendar))
    }

    /// Links → shown entries; lesson notes whose lesson is gone or not
    /// loaded become a read-only „Notiz“ entry at their last known time, so
    /// they stay reachable („ungeklärt“ with candidates of the same course).
    private func indexLinks(_ entries: [CalendarEntry]) -> [CalendarEntry] {
        let byKey = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var ghosts: [CalendarEntry] = []
        var lessonLinks: [CalendarNoteLink] = []
        for link in state.noteLinks {
            switch link.target {
            case .local:
                if byKey[link.target.key] != nil, linkByEntry[link.target.key] == nil { linkByEntry[link.target.key] = link }
            case .lesson(let anchor):
                if anchor.source == state.connection?.source { lessonLinks.append(link) }
            case .system:
                break
            }
        }
        ghosts += indexSystemLinks()
        var taken = Set<String>()
        var open: [(CalendarNoteLink, CalendarLessonAnchor)] = []
        for link in lessonLinks {
            guard case .lesson(let anchor) = link.target else { continue }
            if case .found(let lesson) = CalendarLessonMatching.resolve(anchor, mappings: state.lessonMappings, snapshot: snapshot) {
                taken.insert(lesson.key.sourceID)
                if linkByEntry[lesson.id] == nil { linkByEntry[lesson.id] = link }
            } else {
                open.append((link, anchor))
            }
        }
        for (link, anchor) in open {
            let resolution = CalendarLessonMatching.resolve(anchor, mappings: state.lessonMappings, snapshot: snapshot, taken: taken)
            var ghost = CalendarEntry(id: "note/\(link.id.uuidString)", title: link.contextTitle, subject: link.contextTitle,
                                      source: .timetable, start: link.contextStart, end: link.contextEnd)
            ghost.ghostLinkID = link.id
            switch resolution {
            case .unresolved(let found):
                ghost.status = .other("Ungeklärt: Die Stunde steht so nicht mehr im Stundenplan. Die Notiz bleibt erhalten.")
                candidates[link.id] = found
            default:
                ghost.status = .other("Stunde nicht im Offline-Stundenplan. Die Notiz bleibt erhalten.")
            }
            ghost.colorName = CalendarSubjectColor.name(for: CalendarSubjectColor.key(subjectID: nil, name: link.contextTitle),
                                                        chosen: state.settings.subjectColors)
            linkByEntry[ghost.id] = link
            ghosts.append(ghost)
        }
        return ghosts
    }

    /// The note of an „ungeklärt“ lesson belongs to `lesson` (user choice):
    /// stored as a mapping, never guessed from titles.
    func assign(_ entry: CalendarEntry, to lesson: CalendarLesson) async {
        guard let linkID = entry.ghostLinkID, let link = state.noteLinks.first(where: { $0.id == linkID }),
              case .lesson(let anchor) = link.target else { return }
        let current = CalendarLessonMatching.currentPeriod(anchor, mappings: state.lessonMappings)
        let mapping = CalendarLessonMapping(source: anchor.source, fromPeriodID: current.period, fromDate: current.date,
                                            toPeriodID: lesson.key.sourceID, toDate: lesson.date)
        if await commit({ $0.lessonMappings.append(mapping) }) || unsaved { selection = lesson.id }
    }

    private func prepareSamples() {
        guard calendar.component(.year, from: anchor) != sampleYear else { return }
        rebuild()
    }

    private func entry(_ occurrence: CalendarOccurrence, of event: LocalCalendarEvent) -> CalendarEntry {
        let interval = occurrence.timing.interval(in: calendar)
        var entry = CalendarEntry(id: CalendarEntry.localID(event.id, occurrence.originalDate), title: occurrence.title, source: .personal,
                                  start: interval.start, end: interval.end, allDay: occurrence.timing.isAllDay,
                                  room: occurrence.location.isEmpty ? nil : occurrence.location,
                                  details: occurrence.details.isEmpty ? nil : occurrence.details)
        entry.localID = event.id
        entry.originalDate = occurrence.originalDate
        entry.noteTarget = occurrence.noteTarget
        entry.repeatText = event.recurrence.map { $0.text + (occurrence.isOverride ? " · dieser Termin geändert" : "") }
        entry.reminder = event.reminderMinutes.map(CalendarReminder.text)
            ?? (notificationSettings.eventReminders && !occurrence.timing.isAllDay
                ? CalendarReminder.text(notificationSettings.eventMinutes) + " (allgemein)" : nil)
        entry.colorName = CalendarSubjectColor.personal
        return entry
    }

    private func entry(_ lesson: CalendarLesson) -> CalendarEntry {
        var notes: [String] = []
        let changedRoom = lesson.originalRooms.isEmpty ? "Raum geändert" : "Raum \(lesson.rooms.joined(separator: ", ")) statt \(lesson.originalRooms.joined(separator: ", "))"
        let changedTeacher = lesson.originalTeachers.isEmpty ? "Änderung laut WebUntis"
            : "\(lesson.teachers.joined(separator: ", ")) statt \(lesson.originalTeachers.joined(separator: ", "))"
        var statuses: [CalendarEventStatus] = []
        for status in lesson.statuses {
            switch status {
            case .cancelled: statuses.append(.cancelled)
            case .exam: statuses.append(.exam)
            case .substitution: statuses.append(.substitution(changedTeacher))
            case .roomChanged: statuses.append(.roomChanged(changedRoom))
            case .other(let raw): statuses.append(.other("Unbekannter WebUntis-Status „\(raw)“"))
            }
        }
        // One main status (cancelled > exam > change > room > other), the rest as notes.
        let order: (CalendarEventStatus) -> Int = {
            switch $0 { case .cancelled: 0; case .exam: 1; case .substitution: 2; case .roomChanged: 3; case .other: 4; case .normal: 5 }
        }
        statuses.sort { order($0) < order($1) }
        let main = statuses.first ?? .normal
        for status in statuses.dropFirst() {
            if let label = status.label { notes.append([label, status.note].compactMap { $0 }.joined(separator: ": ")) }
        }
        let subject = lesson.subjectLong ?? lesson.subject ?? lesson.title
        var entry = CalendarEntry(id: lesson.id, title: lesson.title, subject: subject,
                                  source: .timetable, start: lesson.start, end: lesson.end,
                                  room: lesson.rooms.isEmpty ? nil : lesson.rooms.joined(separator: ", "),
                                  teacher: lesson.teachers.isEmpty ? nil : lesson.teachers.joined(separator: ", "),
                                  status: main, details: lesson.text)
        entry.statusNotes = notes + homeworkNotes(for: lesson)
        let key = CalendarSubjectColor.key(subjectID: lesson.subjectID, name: subject)
        entry.subjectKey = key
        entry.colorName = CalendarSubjectColor.name(for: key, chosen: state.settings.subjectColors)
        if let source = state.connection?.source { entry.noteTarget = .lesson(CalendarLessonAnchor(lesson: lesson, source: source)) }
        if let minutes = state.settings.lessonReminderMinutes, !lesson.isCancelled { entry.reminder = "Unterricht: \(minutes) Minuten vorher" }
        return entry
    }

    /// WebUntis holidays, the NRW table where WebUntis has none, and the
    /// statutory public holidays of NRW (`CalendarHolidaysNRW`).
    private func holidayEntries(from start: CivilDate, to end: CivilDate, webUntis: [CalendarHoliday]) -> [CalendarEntry] {
        let connection = snapshot?.connection.uuidString ?? "none"
        return CalendarHolidaysNRW.holidays(from: start, to: end, webUntis: webUntis).map { day in
            let holiday = day.holiday
            let id: String, details: String
            switch day.origin {
            case .webUntis:
                id = "holiday/\(connection)/\(holiday.id)/\(holiday.start)"; details = "Ferien laut WebUntis."
            case .schoolTable:
                id = "holiday/nrw/\(holiday.id)"
                details = "Schulferien NRW aus der in noty eingebauten Tabelle (ohne WebUntis-Ferien; ohne Gewähr, bewegliche Ferientage der Schule fehlen)."
            case .publicHoliday:
                id = "holiday/feiertag/\(holiday.start)"; details = "Gesetzlicher Feiertag in Nordrhein-Westfalen."
            }
            return CalendarEntry(id: id, title: holiday.name, source: .holidays, start: holiday.start.start(in: calendar),
                                 end: holiday.end.start(in: calendar), allDay: true, details: details)
        }
    }

    private func visible(_ entry: CalendarEntry) -> Bool { !hiddenSources.contains(entry.source) }

    func refreshToday() {
        let now = Date()
        if !calendar.isDate(now, inSameDayAs: today) {
            today = now
            if showsSamples { sampleYear = nil; rebuild() }
        }
    }

    /// All-day entries first, then by start; nothing is filtered by space.
    func events(on day: Date) -> [CalendarEntry] {
        (byDay[calendar.startOfDay(for: day)] ?? []).filter(visible).sorted {
            if $0.allDay != $1.allDay { return $0.allDay }
            if $0.start != $1.start { return $0.start < $1.start }
            return $0.end > $1.end
        }
    }

    func event(_ id: String?) -> CalendarEntry? {
        guard let id, let event = byID[id], visible(event) else { return nil }
        return event
    }

    var selectedEvent: CalendarEntry? { event(selection) }

    func search(_ query: String) -> [CalendarEntry] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        return all.filter { event in
            visible(event) && [event.title, event.room, event.teacher, event.details].contains { $0?.localizedCaseInsensitiveContains(text) == true }
        }.sorted { $0.start < $1.start }
    }

    var hasVisibleEntries: Bool { !all.isEmpty && !listedSources.allSatisfy { hiddenSources.contains($0) } }

    /// The calendars that can have entries now: „Kalender“ (system) only
    /// while Apple Kalender/Outlook is connected in this area.
    var listedSources: [CalendarSource] { CalendarSource.allCases.filter { $0 != .system || systemEnabled } }

    /// How far the shown range is loaded from WebUntis (nil: no connection or demo).
    func coverage(_ start: Date, _ end: Date) -> CalendarCoverage? {
        guard !showsSamples, state.connection != nil, !hiddenSources.contains(.timetable) else { return nil }
        guard let snapshot else { return .notLoaded }
        return snapshot.coverage(from: CivilDate(start, calendar: calendar), to: CivilDate(end, calendar: calendar))
    }

    /// „Stand: heute 07:12“ for a fetch time.
    func standText(_ date: Date) -> String {
        let clock = CalendarText.clock(date, calendar: calendar)
        if calendar.isDateInToday(date) { return "Stand: heute \(clock)" }
        if calendar.isDateInYesterday(date) { return "Stand: gestern \(clock)" }
        return "Stand: \(CalendarText.numericDate(date, calendar: calendar)) \(clock)"
    }

    /// The series of an own entry (form, details).
    func recurrence(of entry: CalendarEntry) -> CalendarRecurrence? {
        entry.localID.flatMap { id in state.events.first { $0.id == id }?.recurrence }
    }
    func baseEvent(of entry: CalendarEntry) -> LocalCalendarEvent? {
        entry.localID.flatMap { id in state.events.first { $0.id == id } }
    }

    // MARK: Navigation

    func step(_ steps: Int) {
        anchor = CalendarDates.shift(anchor, mode: mode, by: steps, calendar: calendar)
    }
    func goToToday() { refreshToday(); anchor = today }
    func open(_ day: Date, in mode: CalendarMode) { anchor = day; self.mode = mode }
    func show(_ event: CalendarEntry) {
        anchor = calendar.startOfDay(for: event.start)
        if mode == .year { mode = .day }
        selection = event.id
    }

    /// New entry: next full hour on the shown day.
    func requestNewEvent() {
        guard draft == nil, canWrite, !showsSamples else { return }
        let hour = calendar.component(.hour, from: Date())
        let day = calendar.startOfDay(for: mode == .day || mode == .week ? anchor : today)
        let start = calendar.date(bySettingHour: min(22, hour + 1), minute: 0, second: 0, of: day) ?? day
        draft = CalendarDraft(start: start, calendar: calendar)
    }

    func editDraft(for entry: CalendarEntry) -> CalendarDraft {
        if isSystem(entry) { return systemDraft(for: entry) }
        return CalendarDraft(editing: entry, rule: recurrence(of: entry), base: baseEvent(of: entry), calendar: calendar)
    }

    // MARK: Notes beside the event

    /// Indicator: a linked notebook with real content that is still in the
    /// library. An opened empty page shows nothing.
    func hasNotes(_ event: CalendarEntry) -> Bool {
        if event.isSample { return !event.samplePages.isEmpty }
        guard let link = linkByEntry[event.id], link.hasContent else { return false }
        guard let library else { return true }
        return library.snapshot.items.contains { $0.id == link.documentID } && !library.snapshot.isTrashed(link.documentID)
    }

    func link(for entry: CalendarEntry) -> CalendarNoteLink? { linkByEntry[entry.id] }

    private func selectionChanged() {
        guard visible else { return }
        if let entry = selectedEvent { showNote(for: entry) } else { releaseNote() }
    }

    /// Opens the note area of `entry` (after the previous one is committed
    /// and closed). Serialized: a late close never overlaps a new open.
    func showNote(for entry: CalendarEntry) {
        let previous = noteQueue
        noteQueue = Task { [weak self] in
            await previous?.value
            await self?.prepareNote(for: entry)
        }
    }

    /// Calendar hidden, nothing selected or the library opens a notebook.
    func releaseNote() {
        let previous = noteQueue
        noteQueue = Task { [weak self] in
            await previous?.value
            await self?.closeNoteSession()
        }
    }

    /// For the library: commits and closes the note before it opens a notebook.
    /// False while a note's changes are still only in memory (kept and
    /// retried; the caller must not drop this model then).
    @discardableResult
    func closeNote() async -> Bool {
        releaseNote()
        await noteQueue?.value
        return lingering.isEmpty
    }

    /// Area switch (the switch disposes this model and everything it keeps
    /// in memory): commits and closes the note, resumes notes not created
    /// yet, retries notes not saved yet and an unsaved calendar change. Nil:
    /// nothing is only in memory any more; otherwise what would be lost
    /// (the switch then needs `discardUnsavedForAreaSwitch()` explicitly).
    func prepareAreaSwitch() async -> String? {
        await closeNote()
        await retryLingering(resumingCreations: true)
        // A commit still running finishes first.
        await mutations.acquire(); mutations.release()
        if unsaved { await retrySave() }
        var parts: [String] = []
        let titles = lingering.values.map { $0.notebook.title.isEmpty ? "Notiz" : "„\($0.notebook.title)“" }.sorted()
        if !titles.isEmpty {
            parts.append((titles.count == 1 ? "Die Kalendernotiz \(titles[0]) ist" : "Die Kalendernotizen \(titles.joined(separator: ", ")) sind")
                         + " noch nicht gespeichert (zum Beispiel weil ein Import noch läuft oder das Speichern fehlschlägt).")
        }
        if unsaved {
            parts.append("Die letzte Kalenderänderung ist noch nicht gespeichert. \(saveError ?? "")")
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }

    /// The user chose to switch the area anyway: the notes and calendar
    /// changes that exist only in memory are let go explicitly.
    func discardUnsavedForAreaSwitch() {
        for model in lingering.values { model.abandonUnsavedChanges() }
        lingering = [:]
        parked = [:]
        creations = [:]
        unsaved = false
        saveError = nil
    }

    /// The app leaves the foreground: a note that has content but no
    /// notebook yet (its 400 ms input pause has not passed, or input kept
    /// resetting it) is created and committed now, and every running
    /// creation is protected by background time until it finished. Saved
    /// notes save themselves (`EditorModel.save`, own background time).
    func sceneLeftForeground() {
        var runs: [CalendarNoteSession] = []
        if let session = noteSession, session.phase != .saved {
            if session.phase != .creating, EditorModel.hasContent(session.model.notebook) || !session.model.deferredCommit {
                continueCreation(session)
            }
            if session.phase == .creating { runs.append(session) }
        }
        for (id, session) in parked where lingering[id] != nil && session.model.deferredCommit && session.phase != .saved {
            if session.phase != .creating { continueCreation(session) }
            if session.phase == .creating { runs.append(session) }
        }
        guard !runs.isEmpty else { return }
        let background = CalendarBackgroundTask(name: "noty-calendar-note")
        Task {
            for session in runs { await session.creation?.value }
            // A note created from the parked list commits its newest state and lets go.
            await retryLingering()
            background.end()
        }
    }

    private func prepareNote(for entry: CalendarEntry) async {
        if let session = noteSession, session.entryID == entry.id { return }
        await closeNoteSession()
        guard selection == entry.id else { return }
        guard !entry.isSample else { noteState = .sample; return }
        guard let target = entry.noteTarget ?? linkByEntry[entry.id]?.target else {
            noteState = .unavailable("Für diesen Eintrag gibt es keine Notizen.")
            return
        }
        guard let library, library.ready else { noteState = .unavailable("Die Bibliothek wird noch geladen."); return }
        guard library.opened == nil else { noteState = .unavailable("Die Notiz ist im Editor geöffnet."); return }
        guard canWrite else { noteState = .unavailable(storageError ?? "Der Kalender ist noch nicht geladen."); return }
        let restores = root.appendingPathComponent("Restores", isDirectory: true)
        if let link = linkByEntry[entry.id] {
            guard let item = library.snapshot.items.first(where: { $0.id == link.documentID }) else {
                noteState = .missing(.deleted, link); return
            }
            if library.snapshot.isTrashed(item.id) { noteState = .missing(.trashed(item.title), link); return }
            guard let document = await library.openDocument(item.id) else { noteState = .missing(.deleted, link); return }
            parked[item.id] = nil
            let model = lingering.removeValue(forKey: item.id)
                ?? EditorModel(storageRoot: document.directory, restoreDirectory: restores, libraryTitle: item.title)
            start(CalendarNoteSession(entry: entry, target: link.target, documentID: item.id, title: item.title, model: model, phase: .saved))
            return
        }
        // A note whose creation stopped: the same document again, never a second one.
        if let creation = creations[target.key] {
            let committed = await creation.stage >= .notebookCommitted
            parked[creation.documentID] = nil
            if let model = lingering.removeValue(forKey: creation.documentID)
                ?? (committed ? EditorModel(storageRoot: library.newDocumentDirectory(creation.documentID), restoreDirectory: restores) : nil) {
                let session = CalendarNoteSession(entry: entry, target: target, documentID: creation.documentID,
                                                  title: model.notebook.title.isEmpty ? noteTitle(for: entry) : model.notebook.title,
                                                  model: model, phase: .failed("Noch nicht fertig angelegt."))
                start(session)
                continueCreation(session)
                return
            }
            // Nothing of it exists anywhere: start afresh.
            creations[target.key] = nil
        }
        let id = UUID()
        let title = noteTitle(for: entry)
        var notebook = (try? Notebook.blank(title: title, appearance: defaultAppearance())) ?? Notebook.blank(title: title)
        notebook.id = id
        let model = EditorModel(storageRoot: library.newDocumentDirectory(id), restoreDirectory: restores, deferred: notebook)
        start(CalendarNoteSession(entry: entry, target: target, documentID: id, title: title, model: model, phase: .draft))
    }

    private func noteTitle(for entry: CalendarEntry) -> String {
        let day = entry.originalDate ?? CivilDate(entry.start, calendar: calendar)
        let taken = library?.snapshot.activeNotebookTitles() ?? []
        return CalendarNotesFolder.noteTitle(subject: entry.subject ?? entry.title, date: day, taken: taken)
    }

    private func start(_ session: CalendarNoteSession) {
        noteSession = session
        noteState = .session(session)
        session.observe { [weak self, weak session] notebook in
            guard let self, let session else { return }
            self.noteChanged(session, notebook: notebook)
        }
    }

    private func noteChanged(_ session: CalendarNoteSession, notebook: Notebook) {
        let content = EditorModel.hasContent(notebook)
        switch session.phase {
        case .draft:
            // First real input: create the notebook, then link it (rule 8).
            if content { continueCreation(session) }
        case .saved:
            if let index = state.noteLinks.firstIndex(where: { $0.documentID == session.documentID && $0.target == session.target }),
               state.noteLinks[index].hasContent != content {
                Task { await commit { if let i = $0.noteLinks.firstIndex(where: { $0.documentID == session.documentID && $0.target == session.target }) { $0.noteLinks[i].hasContent = content } } }
            }
        case .creating, .failed: break
        }
    }

    /// Runs (or resumes) rule 8 for the session's note. Input meanwhile goes
    /// into the same model and its next autosave; nothing is created twice.
    func continueCreation(_ session: CalendarNoteSession) {
        guard session.phase != .creating, session.phase != .saved, let library else { return }
        let key = session.target.key
        let creation = creations[key] ?? CalendarNoteCreation(documentID: session.documentID, target: session.target)
        guard creation.documentID == session.documentID else { return }
        creations[key] = creation
        session.phase = .creating
        let model = session.model, entry = session.entry
        let documentID = session.documentID, title = session.title, target = session.target
        let pageID = model.notebook.pages.first?.id
        let folder = CalendarFolderBox()
        session.creation = Task { [weak self] in
            do {
                try await creation.run(commitNotebook: { @MainActor in
                    guard await model.beginCommitting() else {
                        throw CalendarNoteError.notSaved(model.saveBlocked ?? "Die Notiz wurde noch nicht gespeichert; noty versucht es weiter.")
                    }
                }, addToLibrary: { @MainActor [weak self] in
                    folder.id = try await library.adoptCalendarNote(documentID, title: title, folder: self?.state.settings.notesFolderID)
                }, link: { @MainActor [weak self] in
                    guard let self else { throw CalendarNoteError.closed }
                    let link = CalendarNoteLink(target: target, documentID: documentID, pageID: pageID, hasContent: true,
                                                contextTitle: String(entry.title.prefix(300)), contextStart: entry.start, contextEnd: entry.end)
                    let usedFolder = folder.id ?? CalendarNotesFolder.usable(self.state.settings.notesFolderID, in: library.snapshot)
                    let ok = await self.commit { state in
                        if !state.noteLinks.contains(where: { $0.target == target && $0.documentID == documentID }) { state.noteLinks.append(link) }
                        if let usedFolder { state.settings.notesFolderID = usedFolder }
                    }
                    guard ok else { throw CalendarNoteError.linkNotSaved(self.saveError ?? "") }
                })
                session.phase = .saved
                self?.creations[key] = nil
            } catch {
                session.phase = .failed(CalendarNoteError.message(error))
            }
        }
    }

    private func closeNoteSession() async {
        noteState = .none
        enlargedDraft = nil
        guard let session = noteSession else { await retryLingering(); return }
        noteSession = nil
        session.stopObserving()
        let model = session.model
        // Written just before switching (the debounce had not fired yet): create it now.
        if session.phase == .draft, EditorModel.hasContent(model.notebook) { continueCreation(session) }
        await session.creation?.value
        if model.deferredCommit {
            // Never committed: an empty page leaves nothing behind. Written
            // content that could not be committed stays in memory and is
            // shown again with this event (same document, no second one).
            if EditorModel.hasContent(model.notebook) {
                lingering[session.documentID] = model
                parked[session.documentID] = session
                notice = "Die Notiz zu „\(session.entry.title)“ ist noch nicht gespeichert. Bitte den Termin erneut öffnen."
            }
        } else {
            if case .failed = session.phase {
                notice = "Die Notiz zu „\(session.entry.title)“ liegt in „Kalendernotizen“, ist aber noch nicht fertig mit dem Termin verknüpft. Beim nächsten Öffnen des Termins wird es erneut versucht."
            }
            if !(await model.flushBeforeClosing()) {
                lingering[session.documentID] = model
                notice = "Die Notiz zu „\(session.entry.title)“ konnte noch nicht gespeichert werden; noty versucht es weiter."
            }
        }
        await retryLingering()
    }

    /// `resumingCreations`: notes without a notebook yet run their creation
    /// again first (area switch; not on every note change, where a blocked
    /// package would make each switch wait).
    private func retryLingering(resumingCreations: Bool = false) async {
        if resumingCreations {
            for (id, session) in parked where lingering[id] != nil && session.model.deferredCommit && session.phase != .creating {
                continueCreation(session)
                await session.creation?.value
            }
        }
        for (id, model) in lingering where !model.deferredCommit {
            if await model.flushBeforeClosing() { lingering[id] = nil; parked[id] = nil }
        }
    }

    /// The library changed (trash, restore, rename): the note follows.
    private func libraryChanged() {
        objectWillChange.send()
        guard let session = noteSession, let library else { return }
        let gone = session.phase == .saved && (!library.snapshot.items.contains { $0.id == session.documentID } || library.snapshot.isTrashed(session.documentID))
        if gone, let entry = selectedEvent {
            releaseNote()
            showNote(for: entry)
        }
    }

    /// „Vergrößern“: a saved note opens in the normal editor (the library's
    /// full-screen path) with „Zurück zu <Termin> · <Datum>“; a note that
    /// has no notebook yet is shown large over the calendar.
    func enlarge(_ entry: CalendarEntry) {
        guard let session = noteSession, session.entryID == entry.id else { return }
        if session.model.deferredCommit || session.phase == .creating { enlargedDraft = session; return }
        let id = session.documentID, page = session.model.page.id
        let back = "\(entry.title) · \(CalendarText.shortDate(entry.start, calendar: calendar))"
        Task {
            await closeNote()
            guard let library, let item = library.snapshot.items.first(where: { $0.id == id }), !library.snapshot.isTrashed(id) else { return }
            await library.open(item, pageID: page, returnTitle: back)
        }
    }

    /// Restores a trashed note from the library's trash.
    func restoreNote(_ link: CalendarNoteLink) async {
        await library?.restore(link.documentID)
        if let entry = selectedEvent { showNote(for: entry) }
    }

    /// Removes only the link; the notebook stays in the library.
    func unlink(_ link: CalendarNoteLink) async {
        await commit { $0.noteLinks.removeAll { $0.id == link.id } }
        if let entry = selectedEvent { noteState = .none; showNote(for: entry) }
    }

    /// Links an existing notebook of „Kalendernotizen“ again (after a failed
    /// link or a removed one). The notebook itself is not changed.
    func relink(_ entry: CalendarEntry, to item: NotebookCore.LibraryItem) async {
        guard let target = entry.noteTarget, linkByEntry[entry.id] == nil else { return }
        if let session = noteSession, session.entryID == entry.id, session.phase != .draft || EditorModel.hasContent(session.model.notebook) { return }
        await closeNote()
        let link = CalendarNoteLink(target: target, documentID: item.id, hasContent: true, contextTitle: String(entry.title.prefix(300)),
                                    contextStart: entry.start, contextEnd: entry.end)
        await commit { $0.noteLinks.append(link) }
        showNote(for: entry)
    }

    /// Notebooks of the notes folder that no link of this calendar uses.
    var unlinkedNotebooks: [NotebookCore.LibraryItem] {
        guard let library else { return [] }
        let used = Set(state.noteLinks.map(\.documentID))
        return library.calendarNotebooks(in: state.settings.notesFolderID).filter { !used.contains($0.id) }
    }

    /// Page flip and „Seite hinzufügen“ beside the event (the editor's own model).
    func addNotePage() {
        guard let model = noteSession?.model, model.writable, let last = model.notebook.pages.last else { return }
        let defaults = model.notebook.pageDefaults
        model.insertPaper(defaults.paper, color: defaults.color, relativeTo: last.id)
        model.pageIndex = model.notebook.pages.count - 1
    }
}

/// Background execution time for a note's creation (as the editor's own
/// `BackgroundSaveTask`): iOS may otherwise suspend the app in between.
@MainActor private final class CalendarBackgroundTask {
    private var identifier = UIBackgroundTaskIdentifier.invalid
    init(name: String) {
        identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            MainActor.assumeIsolated { self?.end() }
        }
    }
    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}

/// A connection change that was not committed (the access data are removed again).
struct CalendarConnectionCommitError: Error, LocalizedError {
    let reason: String?
    var errorDescription: String? { "Die Verbindung wurde nicht gespeichert. " + (reason ?? "") }
}

/// The folder the library step used, handed to the link step.
@MainActor private final class CalendarFolderBox { var id: UUID? }

extension CalendarEventTiming {
    var timeZoneID: String? { if case .timed(_, _, let zone) = self { zone } else { nil } }
}

enum CalendarNoteError: Error, LocalizedError {
    case notSaved(String)
    case linkNotSaved(String)
    case closed
    var errorDescription: String? {
        switch self {
        case .notSaved(let reason): "Die Notiz ist noch nicht gespeichert: \(reason)"
        case .linkNotSaved(let reason): "Die Notiz liegt in „Kalendernotizen“, die Verknüpfung mit dem Termin ist aber noch nicht gespeichert. \(reason)"
        case .closed: "Der Kalender wurde geschlossen."
        }
    }
    static func message(_ error: Error) -> String {
        if let error = error as? LocalizedError, let text = error.errorDescription { return text }
        return error.localizedDescription
    }
}

/// What the note area beside an event shows.
enum CalendarNoteState {
    enum Missing: Equatable { case trashed(String), deleted }
    case none
    case sample
    case unavailable(String)
    case missing(Missing, CalendarNoteLink)
    case session(CalendarNoteSession)
}

/// The note of one event while it is shown: the normal editor model of its
/// notebook (or of the not yet created one). One at a time; a new event gets
/// a new session and a new editor view, so late callbacks of the previous
/// canvas can only reach the previous notebook's model.
@MainActor
final class CalendarNoteSession: ObservableObject, Identifiable {
    enum Phase: Equatable {
        /// Only in memory: nothing written yet.
        case draft
        case creating
        case saved
        case failed(String)
    }
    let id = UUID()
    let entry: CalendarEntry
    var entryID: String { entry.id }
    let target: CalendarNoteTarget
    let documentID: UUID
    let title: String
    let model: EditorModel
    @Published var phase: Phase
    var creation: Task<Void, Never>?
    private var observer: AnyCancellable?

    init(entry: CalendarEntry, target: CalendarNoteTarget, documentID: UUID, title: String, model: EditorModel, phase: Phase) {
        self.entry = entry; self.target = target; self.documentID = documentID; self.title = title; self.model = model; self.phase = phase
    }

    func observe(_ changed: @escaping @MainActor (Notebook) -> Void) {
        observer = model.$notebook.dropFirst()
            .debounce(for: .milliseconds(400), scheduler: RunLoop.main)
            .sink { notebook in MainActor.assumeIsolated { changed(notebook) } }
    }
    func stopObserving() { observer = nil }
}
