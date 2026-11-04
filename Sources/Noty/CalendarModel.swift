import SwiftUI
import PencilKit
import NotebookCore

/// Calendar of one area (Stufe B1, docs/CALENDAR-PLAN.md). Lives with the
/// library of that area (`LibraryView`), so an area switch gives a new model
/// and repository. Own events and settings are committed through
/// `CalendarRepository` (`<Bereich>/Calendar/`); WebUntis lessons and
/// holidays come from the replaceable source cache. „Beispieldaten“ is an
/// explicit demo mode that shows only fictitious entries and stores nothing.
@MainActor
final class CalendarModel: ObservableObject {
    let calendar = CalendarDates.german()
    let root: URL
    private let repository: CalendarRepository

    // MARK: View state
    @Published var mode = CalendarMode.week { didSet { if mode != oldValue { persistSettings() } } }
    /// 5 = Monday–Friday, 7 = whole week (stored per area).
    @Published var weekDays = 5 { didSet { if weekDays != oldValue { persistSettings() } } }
    @Published var anchor = Date() { didSet { if showsSamples { prepareSamples() } } }
    @Published var selection: String?
    @Published var draft: CalendarDraft?
    @Published var hiddenSources: Set<CalendarSource> = []
    /// Demo mode: only fictitious entries, nothing editable or stored. Off by default.
    @Published var showsSamples = false { didSet { if showsSamples != oldValue { selection = nil; sampleYear = nil; rebuild() } } }
    @Published private(set) var today = Date()
    /// The calendar is on screen; WebUntis is only asked while it is.
    var visible = false {
        didSet { if visible && !oldValue { refreshIfDue() } }
    }

    // MARK: Storage state
    @Published private(set) var loaded = false
    /// The calendar package could not be read safely: writing is locked.
    @Published private(set) var storageError: String?
    /// Last commit failed; the change stays in memory (`unsaved`).
    @Published private(set) var saveError: String?
    @Published private(set) var unsaved = false
    @Published private(set) var recoveredNotice: String?
    private var state = CalendarState()
    private var revision = 0
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

    // MARK: Removal with a way back (session)
    @Published private(set) var lastRemoval: (title: String, event: LocalCalendarEvent)?

    // MARK: Notes (memory only in B1)
    @Published private var notes: [String: [CalendarNotePage]] = [:]

    // MARK: Index
    private var all: [CalendarEntry] = []
    private var byID: [String: CalendarEntry] = [:]
    private var byDay: [Date: [CalendarEntry]] = [:]
    private var sampleYear: Int?

    init(root: URL) {
        self.root = root
        repository = CalendarRepository(areaRoot: root)
        Task { await load() }
    }

    deinit {
        let repository = repository
        Task { await repository.close() }
    }

    var connection: CalendarConnectionRecord? { state.connection }
    var canWrite: Bool { loaded && storageError == nil }
    var localEventCount: Int { state.events.count }
    var hasRealData: Bool { !state.events.isEmpty || state.connection != nil }

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
                credentialsMissing = WebUntisKeychain.load(connection.id) == nil
                do { snapshot = try await repository.sourceSnapshot() }
                catch { syncError = error.localizedDescription }
            }
        } catch {
            storageError = error.localizedDescription
        }
        loaded = true
        rebuild()
        if visible { refreshIfDue() }
    }

    /// Applies `change` in memory and commits it. On failure the change stays
    /// shown but unsaved (with a retry); the committed state on disk is kept.
    @discardableResult
    private func commit(_ change: (inout CalendarState) -> Void) async -> Bool {
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
            if current == revision { unsaved = false; saveError = nil }
            return true
        } catch {
            if current == revision {
                unsaved = true
                saveError = "Nicht gespeichert: \(error.localizedDescription)"
            }
            return false
        }
    }

    func retrySave() async { _ = await write(state) }

    private func persistSettings() {
        guard !applyingSettings, loaded, canWrite else { return }
        let days = weekDays, mode = mode.rawValue
        guard state.settings.weekDays != days || state.settings.mode != mode else { return }
        Task { await commit { $0.settings.weekDays = days; $0.settings.mode = mode } }
    }

    func dismissNotices() { recoveredNotice = nil; if !unsaved { saveError = nil } }

    // MARK: Own events

    /// New or changed own event from the form. Single events only in B1.
    /// Nil: applied (committed, or unsaved with the retry banner); otherwise
    /// the reason it was rejected and not applied.
    func save(_ draft: CalendarDraft) async -> String? {
        guard !showsSamples else { return "Im Beispielmodus werden keine Termine gespeichert." }
        guard let title = CalendarState.validTitle(draft.title) else { return "Bitte einen Titel mit höchstens 200 Zeichen eingeben." }
        let (timing, problem) = draft.timing(calendar: calendar)
        guard let timing else { return problem }
        let location = draft.location.trimmingCharacters(in: .whitespacesAndNewlines)
        let details = draft.details.trimmingCharacters(in: .whitespacesAndNewlines)
        let now = Date()
        var savedID: UUID?
        let ok = await commit { state in
            if let id = draft.editing?.localID, let index = state.events.firstIndex(where: { $0.id == id }) {
                state.events[index].title = title
                state.events[index].location = location
                state.events[index].details = details
                state.events[index].timing = timing
                state.events[index].modifiedAt = now
                savedID = id
            } else {
                let event = LocalCalendarEvent(title: title, location: location, details: details, timing: timing, createdAt: now)
                state.events.append(event)
                savedID = event.id
            }
        }
        if let savedID { selection = Self.entryID(savedID) }
        // A failed write keeps the change in memory (banner with retry); only a
        // rejected change keeps the form open – a second tap must not duplicate.
        return ok || unsaved ? nil : saveError
    }

    func remove(_ entry: CalendarEntry) async {
        guard let id = entry.localID, let event = state.events.first(where: { $0.id == id }) else { return }
        if selection == entry.id { selection = nil }
        if await commit({ $0.events.removeAll { $0.id == id } }) || unsaved {
            lastRemoval = ("„\(event.title)“", event)
        }
    }

    /// Restores the removed event with its identity (later note links stay valid).
    func undoRemoval() async {
        guard let removal = lastRemoval else { return }
        lastRemoval = nil
        guard !state.events.contains(where: { $0.id == removal.event.id }) else { return }
        await commit { $0.events.append(removal.event) }
    }
    func dismissRemoval() { lastRemoval = nil }

    // MARK: WebUntis connection

    /// Stores the access data in the keychain, commits the connection record
    /// and loads the timetable. A failed commit removes the keychain item again.
    func connect(_ setup: WebUntisSetup, label: String) async throws {
        guard canWrite else { throw CalendarStoreError.locked }
        let old = state.connection
        let record = CalendarConnectionRecord(label: String(label.prefix(200)), timeZone: "Europe/Berlin")
        try WebUntisKeychain.save(setup, id: record.id)
        var next = state
        next.connection = record
        guard await write(next) else {
            try? WebUntisKeychain.delete(record.id)
            throw CalendarStoreError.invalidState
        }
        state = next
        generation += 1
        syncing = false
        syncError = nil
        snapshot = nil
        lastSuccess = nil
        credentialsMissing = false
        if let old {
            try? await repository.removeSourceCache(connection: old.id)
            try? WebUntisKeychain.delete(old.id)
        }
        showsSamples = false
        snapshot = try? await repository.sourceSnapshot()
        rebuild()
        await refresh(manual: true)
    }

    /// Removes connection record, offline timetable and access data. Own
    /// events and notes stay.
    func disconnect() async -> String? {
        guard let record = state.connection else { return nil }
        var next = state
        next.connection = nil
        guard await write(next) else { return saveError ?? "Trennen wurde nicht gespeichert." }
        state = next
        generation += 1
        syncing = false
        syncError = nil
        lastSuccess = nil
        credentialsMissing = false
        snapshot = nil
        var problems: [String] = []
        do { try await repository.removeSourceCache(connection: record.id) } catch { problems.append("Offline-Stundenplan: \(error.localizedDescription)") }
        do { try WebUntisKeychain.delete(record.id) } catch { problems.append("Zugangsdaten: \(error.localizedDescription)") }
        if selection?.hasPrefix("webuntis/") == true || selection?.hasPrefix("holiday/") == true { selection = nil }
        rebuild()
        return problems.isEmpty ? nil : "Getrennt, aber nicht alles entfernt: " + problems.joined(separator: "; ")
    }

    /// Calendar shown or app active again: refresh when the last automatic
    /// attempt is at least 15 minutes old.
    func refreshIfDue() {
        guard visible, loaded, state.connection != nil, !syncing, !credentialsMissing else { return }
        if let last = lastAutomatic, Date().timeIntervalSince(last) < Self.automaticInterval { return }
        Task { await refresh(manual: false) }
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

    private func refresh(manual: Bool, windows: [(CivilDate, CivilDate)]? = nil) async {
        guard let connection = state.connection, !syncing else { return }
        guard let setup = WebUntisKeychain.load(connection.id) else {
            credentialsMissing = true
            syncError = "Zugangsdaten fehlen auf diesem iPad. Bitte WebUntis neu verbinden."
            return
        }
        var ranges = windows ?? [defaultWindow()]
        if windows == nil, manual, let shown = shownWindow(),
           !(shown.0 >= ranges[0].0 && shown.1 <= ranges[0].1) { ranges.append(shown) }
        let session = generation
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
                let lessons = try await client.timetable(user: user, start: range.0, end: range.1, connection: connection.id, timeZone: zone)
                guard session == generation, state.connection?.id == connection.id else { return }
                snapshot = try await repository.merge(CalendarTimetableFetch(connection: connection.id, start: range.0, end: range.1,
                                                                             fetchedAt: requested, lessons: lessons))
            }
            syncError = nil
            lastSuccess = Date()
        } catch {
            guard session == generation else { return }
            syncError = WebUntisClient.message(error)
        }
        rebuild()
    }

    // MARK: Index of shown entries

    static func entryID(_ id: UUID) -> String { "local/\(id.uuidString)" }

    private func rebuild() {
        var entries: [CalendarEntry] = []
        if showsSamples {
            let year = calendar.component(.year, from: anchor)
            sampleYear = year
            entries = CalendarSamples.events(year: anchor, today: today, calendar: calendar)
        } else {
            entries = state.events.map(entry)
            if let snapshot, snapshot.connection == state.connection?.id {
                entries += snapshot.lessons.map(entry)
                entries += snapshot.holidays.map { entry($0, connection: snapshot.connection) }
            }
        }
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
    }

    private func prepareSamples() {
        guard calendar.component(.year, from: anchor) != sampleYear else { return }
        rebuild()
    }

    private func entry(_ event: LocalCalendarEvent) -> CalendarEntry {
        let interval = event.timing.interval(in: calendar)
        var entry = CalendarEntry(id: Self.entryID(event.id), title: event.title, source: .personal,
                                  start: interval.start, end: interval.end, allDay: event.timing.isAllDay,
                                  room: event.location.isEmpty ? nil : event.location,
                                  details: event.details.isEmpty ? nil : event.details)
        entry.localID = event.id
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
        var entry = CalendarEntry(id: lesson.id, title: lesson.title, subject: lesson.subjectLong ?? lesson.subject ?? lesson.title,
                                  source: .timetable, start: lesson.start, end: lesson.end,
                                  room: lesson.rooms.isEmpty ? nil : lesson.rooms.joined(separator: ", "),
                                  teacher: lesson.teachers.isEmpty ? nil : lesson.teachers.joined(separator: ", "),
                                  status: main, details: lesson.text)
        entry.statusNotes = notes
        return entry
    }

    private func entry(_ holiday: CalendarHoliday, connection: UUID) -> CalendarEntry {
        CalendarEntry(id: "holiday/\(connection.uuidString)/\(holiday.id)/\(holiday.start)", title: holiday.name, source: .holidays,
                      start: holiday.start.start(in: calendar), end: holiday.end.start(in: calendar), allDay: true,
                      details: "Ferien laut WebUntis.")
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

    var hasVisibleEntries: Bool { !all.isEmpty && hiddenSources.count < CalendarSource.allCases.count }

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

    // MARK: Notes (memory only in B1; real notebooks follow in B2)

    func pages(for event: CalendarEntry) -> [CalendarNotePage] {
        if let pages = notes[event.id] { return pages }
        if !event.samplePages.isEmpty { return event.samplePages.map { CalendarNotePage(text: $0) } }
        return [CalendarNotePage()]
    }

    /// Indicator: only real content counts, an opened empty page does not.
    func hasNotes(_ event: CalendarEntry) -> Bool {
        if let pages = notes[event.id] { return pages.contains { !$0.isEmpty } }
        return !event.samplePages.isEmpty
    }

    func setText(_ text: String, page: Int, of event: CalendarEntry) {
        var pages = pages(for: event)
        guard pages.indices.contains(page), pages[page].text != text else { return }
        pages[page].text = text
        notes[event.id] = pages
    }

    /// Returns the new revision for the canvas that wrote it.
    func setDrawing(_ drawing: PKDrawing, page: Int, of event: CalendarEntry) -> Int {
        var pages = pages(for: event)
        guard pages.indices.contains(page) else { return 0 }
        pages[page].drawing = drawing
        pages[page].revision += 1
        notes[event.id] = pages
        return pages[page].revision
    }

    func addPage(to event: CalendarEntry) -> Int {
        var pages = pages(for: event)
        pages.append(CalendarNotePage())
        notes[event.id] = pages
        return pages.count - 1
    }
}
