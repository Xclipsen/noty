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
    let repository: CalendarRepository
    private(set) weak var library: LibraryModel?
    private(set) var defaultAppearance: () -> NotebookAppearance = { NotebookAppearance() }
    private var subscriptions = Set<AnyCancellable>()

    // MARK: View state
    @Published var mode = CalendarMode.week { didSet { if mode != oldValue { persistSettings() } } }
    /// 5 = Monday–Friday, 7 = whole week (stored per area).
    @Published var weekDays = 5 { didSet { if weekDays != oldValue { persistSettings() } } }
    @Published var anchor = Date() { didSet { anchorMoved() } }
    @Published var selection: String? { didSet { if selection != oldValue { selectionChanged() } } }
    @Published var draft: CalendarDraft?
    /// The calendar sidebar is wanted (device preference `noty.calendar.sidebar`,
    /// as before with `@AppStorage`). Held here so the library's toolbar
    /// button (left of „Hefte | Kalender“) and ⌃⌘S in the calendar change
    /// it in one transaction – the button with the panel animation, the key at once.
    @Published var sidebarWanted = UserDefaults.standard.object(forKey: CalendarModel.sidebarKey) as? Bool ?? true {
        didSet { if sidebarWanted != oldValue { UserDefaults.standard.set(sidebarWanted, forKey: Self.sidebarKey) } }
    }
    nonisolated static let sidebarKey = "noty.calendar.sidebar"
    /// Calendars switched off in the view (menu „…“, sidebar, Einstellungen ›
    /// Kalender). A device preference per area (`hiddenSourcesKey`), not in
    /// the calendar package and not in backups.
    @Published var hiddenSources: Set<CalendarSource> = [] {
        didSet {
            if hiddenSources != oldValue {
                UserDefaults.standard.set(hiddenSources.map(\.rawValue).sorted(), forKey: hiddenSourcesKey)
            }
            releaseVanishedSelection()
        }
    }
    /// `noty.v2.calendarHiddenSources.<Bereich>` (`StableSettingsKey`, like
    /// the other per-area preferences; `<Bereich>` = `StableDefaults.scope`,
    /// the area's path inside Documents).
    let hiddenSourcesKey: String
    nonisolated static func hiddenSourcesKey(scope: String) -> String {
        StableSettingsKey.key("calendarHiddenSources", scope: scope)
    }
    /// The first key (08.11.2026, only in builds of `feat/kalender`), moved once.
    nonisolated static func legacyHiddenSourcesKey(scope: String) -> String { "noty.calendar.hiddenSources." + scope }

    /// Once per area: the value of the first key moves to the current one
    /// (a value already there wins); the first key is removed.
    static func migrateHiddenSources(scope: String) {
        let defaults = UserDefaults.standard, old = legacyHiddenSourcesKey(scope: scope), key = hiddenSourcesKey(scope: scope)
        guard let value = defaults.stringArray(forKey: old) else { return }
        if defaults.object(forKey: key) == nil { defaults.set(value, forKey: key) }
        defaults.removeObject(forKey: old)
    }

    /// A removed area (`WorkspaceAppModel.remove`): its choice goes with it.
    static func forgetHiddenSources(scope: String) {
        UserDefaults.standard.removeObject(forKey: hiddenSourcesKey(scope: scope))
        UserDefaults.standard.removeObject(forKey: legacyHiddenSourcesKey(scope: scope))
    }
    /// Demo mode: only fictitious entries, nothing editable or stored. Off by default.
    @Published var showsSamples = false { didSet { if showsSamples != oldValue { selection = nil; sampleYear = nil; rebuild() } } }
    @Published private(set) var today = Date()
    /// The calendar is on screen; WebUntis is only asked while it is.
    var visible = false {
        didSet {
            if visible && !oldValue {
                // Another area's model may have changed the device preference meanwhile.
                let stored = UserDefaults.standard.object(forKey: Self.sidebarKey) as? Bool ?? true
                if stored != sidebarWanted { NotyMotion.instant { sidebarWanted = stored } }
                refreshIfDue()
                // A notification tapped meanwhile opens its entry now (that selection shows its note).
                let shown = selection
                showPending()
                if selection == shown, let entry = selectedEvent { showNote(for: entry) }
            }
            if !visible && oldValue { releaseNote() }
        }
    }

    // MARK: Storage state
    @Published private(set) var loaded = false
    /// The calendar package could not be read safely: writing is locked.
    @Published private(set) var storageError: String?
    /// Last commit failed; the change stays in memory (`unsaved`).
    @Published var saveError: String?
    @Published var unsaved = false
    @Published private(set) var recoveredNotice: String?
    /// A short notice (rejected drag, failed change), dismissible.
    @Published var notice: String?
    /// Confirmed state (set only by `commit`/`transition`/`load`).
    var state = CalendarState()
    private var revision = 0
    /// Every change of `state` (events, links, settings, connection) runs in
    /// turn on the newest state, after the previous one finished writing.
    let mutations = CalendarMutationQueue()
    private var applyingSettings = false

    // MARK: WebUntis
    @Published var snapshot: CalendarSourceSnapshot?
    @Published var syncing = false
    @Published var syncError: String?
    @Published var credentialsMissing = false
    @Published var lastSuccess: Date?
    var lastAutomatic: Date?
    var lastManual: Date?
    /// Bumped by connect/disconnect: late answers of an older session are dropped.
    var generation = 0
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

    // MARK: Reminders (B3; logic in CalendarModel+Notifications.swift)
    /// Notification permission as last seen (asked only when a reminder is switched on).
    @Published var reminderPermission: CalendarReminderCenter.Permission = .notDetermined
    /// „Erinnerungen geplant bis …“; nil when no reminder is on.
    @Published var remindersPlannedUntil: Date?
    @Published var plannedReminderCount = 0
    @Published var reminderError: String?
    @Published var lastUndo: UndoStep?

    // MARK: Mitteilungen (08.11.2026; logic in CalendarModel+Notifications.swift)
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
    /// Older way to ask for the WebUntis sheet (a counter): kept so views that
    /// still bump it work; it only sets `connectionSheetRequested`.
    @Published var connectionRequest = 0 { didSet { connectionSheetRequested = true } }
    /// Wish to open the WebUntis connection sheet („Untis-Zugang prüfen“):
    /// the calendar view opens it once nothing else is presented over it
    /// and sets it back. Set only while no notebook is open (`requestConnectionSheet`).
    @Published var connectionSheetRequested = false {
        didSet { if connectionSheetRequested { connectionSheetSince = Date() } }
    }
    /// When the wish was made: one older than 15 minutes is dropped.
    var connectionSheetSince: Date?
    /// The calendar view shows sheets or popovers of its own (set by
    /// CalendarView through `setPresentingOverlays`; the library keeps its
    /// mode switch and keys off then).
    @Published private(set) var presentingOverlays = false
    /// The calendar view instance that set `presentingOverlays`.
    private var overlayOwner: UUID?
    /// The WebUntis form tests, connects or disconnects (`CalendarWebUntisForm`):
    /// its page must not be left meanwhile – no back, Esc, „Fertig“ or settings
    /// page switch. Set and cleared by the form's task itself, so it never stays on.
    @Published var connectionBusy = false
    /// After connecting WebUntis the push consent is due, but the form was no
    /// longer on screen: offered where the user is now (`calendarPushOffer`:
    /// Einstellungen › Kalender or the calendar), once.
    @Published var pushOfferPending = false
    /// Notification taps that wait until the calendar is on screen (`showPending`).
    var pendingOpen: CalendarPendingOpen?
    var pendingConnectionSheet: Date?
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
    @Published var noteSession: CalendarNoteSession?
    @Published var noteState: CalendarNoteState = .none
    /// A note not yet saved (draft) shown large over the calendar.
    @Published var enlargedDraft: CalendarNoteSession?
    /// Editors that could not commit when they were closed: kept (and retried)
    /// until they did, reused when their note is opened again.
    var lingering: [UUID: EditorModel] = [:]
    /// Sessions of lingering notes that were never committed (no notebook
    /// yet): kept so their creation can be resumed without the event shown
    /// (background, area switch).
    var parked: [UUID: CalendarNoteSession] = [:]
    /// Rule-8 runs per note target (resume after a failed step, same document).
    var creations: [String: CalendarNoteCreation] = [:]
    var noteQueue: Task<Void, Never>?

    // MARK: Index
    private var all: [CalendarEntry] = []
    private var byID: [String: CalendarEntry] = [:]
    private var byDay: [Date: [CalendarEntry]] = [:]
    var linkByEntry: [String: CalendarNoteLink] = [:]
    /// Lernfelder: lesson id → first lesson of its block (`studyBlocks`).
    var studyAnchorByEntry: [String: String] = [:]
    /// Lernfelder: notebooks being created, per field (`CalendarStudyCreation`).
    var studyCreations: [UUID: CalendarStudyCreation] = [:]
    private(set) var candidates: [UUID: [CalendarLesson]] = [:]
    @Published private(set) var truncatedSeries: [String] = []
    private var sampleYear: Int?
    private var window: (start: CivilDate, end: CivilDate)?

    init(root: URL) {
        self.root = root
        repository = CalendarRepository(areaRoot: root)
        notificationNamespace = CalendarNotificationHub.namespace(root: root)
        notificationFile = CalendarNotificationLogFile(namespace: notificationNamespace)
        let scope = StableDefaults.scope(root)
        Self.migrateHiddenSources(scope: scope)
        hiddenSourcesKey = Self.hiddenSourcesKey(scope: scope)
        // Unknown names (a later build's source) are ignored, not kept.
        hiddenSources = Set((UserDefaults.standard.stringArray(forKey: hiddenSourcesKey) ?? []).compactMap(CalendarSource.init(rawValue:)))
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
        // Lernfelder: the editor's page list shows the lesson sections of a Lernfeld notebook.
        StudyOutline.shared.attach { [weak self] notebook in self?.studySections(of: notebook) ?? [] }
        library.$snapshot.dropFirst().receive(on: RunLoop.main).sink { [weak self] _ in
            MainActor.assumeIsolated { self?.libraryChanged() }
        }.store(in: &subscriptions)
        library.$opened.dropFirst().receive(on: RunLoop.main).sink { [weak self] opened in
            let closed = opened == nil
            MainActor.assumeIsolated {
                // Back from the full editor: a notification tapped meanwhile opens its entry,
                // otherwise the note beside the event opens again.
                guard let self, closed, self.visible else { return }
                let shown = self.selection
                self.showPending()
                if self.selection == shown, let entry = self.selectedEvent { self.showNote(for: entry) }
            }
        }.store(in: &subscriptions)
        libraryChanged()
    }

    var connection: CalendarConnectionRecord? { state.connection }
    var canWrite: Bool { loaded && storageError == nil }
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

    func write(_ next: CalendarState) async -> Bool {
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

    /// A calendar view opened or closed its overlays. Only the view that
    /// set them may clear them: a late `onDisappear` of an older view (area
    /// switch, re-creation) leaves a newer view's state alone.
    func setPresentingOverlays(_ open: Bool, owner: UUID) {
        if open {
            overlayOwner = owner
        } else {
            guard overlayOwner == nil || overlayOwner == owner else { return }
            overlayOwner = nil
        }
        if presentingOverlays != open { presentingOverlays = open }
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
        studyAnchorByEntry = [:]
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
            // Lernfelder: every lesson of a block shares the link of its first lesson.
            studyAnchorByEntry = studyBlocks(entries)
            // The first lesson's link, else any member's (the block changed since).
            var blocks: [String: [String]] = [:]
            for (id, anchor) in studyAnchorByEntry { blocks[anchor, default: []].append(id) }
            for (anchor, members) in blocks {
                guard let link = linkByEntry[anchor] ?? members.sorted().lazy.compactMap({ self.linkByEntry[$0] }).first else { continue }
                for id in members where linkByEntry[id] == nil { linkByEntry[id] = link }
            }
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
        StudyOutline.shared.changed()
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

    /// The user asked for something of a switched-off calendar directly (a
    /// notification, the school-day tile, a new connection): switch it back
    /// on – and say so – instead of opening nothing.
    func reveal(_ source: CalendarSource, announce: Bool = true) {
        guard hiddenSources.contains(source) else { return }
        hiddenSources.remove(source)
        if announce { notice = "„\(source.title)“ war ausgeblendet und ist wieder eingeblendet." }
    }

    /// Like `event(_:)`, but also finds an entry of a switched-off calendar
    /// and switches that calendar back on (`reveal`).
    func revealedEvent(_ id: String?) -> CalendarEntry? {
        guard let id, let entry = byID[id] else { return nil }
        reveal(entry.source)
        return entry
    }

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
        // Not over another sheet/popover, the enlarged note or the series dialog:
        // a second presentation would collide and leave the form unreachable.
        guard draft == nil, canWrite, !showsSamples, !presentingOverlays, enlargedDraft == nil, pendingSeriesChange == nil else { return }
        let hour = calendar.component(.hour, from: Date())
        let day = calendar.startOfDay(for: mode == .day || mode == .week ? anchor : today)
        let start = calendar.date(bySettingHour: min(22, hour + 1), minute: 0, second: 0, of: day) ?? day
        draft = CalendarDraft(start: start, calendar: calendar)
    }

    /// New entry from holding and dragging over the grid (docs/CALENDAR-PLAN.md,
    /// „Termin per Halten und Ziehen anlegen“): the form pre-filled with the
    /// span. Timed: `start`/`end` as instants (also over several days);
    /// all-day: the first and the last covered day (the form shows the last
    /// day, the end is stored exclusively). Nothing is saved before the form.
    /// Returns the id of the draft this call opened (nil: none – another form
    /// is open, no write access, samples): only then does a placeholder wait for it.
    @discardableResult
    func requestNewEvent(start: Date, end: Date, allDay: Bool) -> UUID? {
        guard draft == nil, canWrite, !showsSamples else { return nil }
        var prepared = CalendarDraft(start: start, calendar: calendar)
        prepared.allDay = allDay
        prepared.end = allDay ? max(calendar.startOfDay(for: start), calendar.startOfDay(for: end)) : max(end, start)
        draft = prepared
        return prepared.id
    }

    func editDraft(for entry: CalendarEntry) -> CalendarDraft {
        if isSystem(entry) { return systemDraft(for: entry) }
        return CalendarDraft(editing: entry, rule: recurrence(of: entry), base: baseEvent(of: entry), calendar: calendar)
    }
}
