import Foundation
import NotebookCore

// WebUntis connection of the calendar (Stufe B1/B2): connect, disconnect
// and the refresh of the offline timetable. Moved out of
// CalendarModel.swift unchanged.

extension CalendarModel {
    // MARK: WebUntis connection

    /// Stores the access data in the keychain, commits the connection record
    /// and loads the timetable. A failed commit removes the keychain item again.
    func connect(_ setup: WebUntisSetup, label: String) async throws {
        guard canWrite else { throw CalendarStoreError.locked }
        let record = CalendarConnectionRecord(label: String(label.prefix(200)), timeZone: CalendarDefaults.timeZoneIdentifier,
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
}

/// A connection change that was not committed (the access data are removed again).
struct CalendarConnectionCommitError: Error, LocalizedError {
    let reason: String?
    var errorDescription: String? { "Die Verbindung wurde nicht gespeichert. " + (reason ?? "") }
}
