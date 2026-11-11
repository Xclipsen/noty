import Foundation
import NotebookCore

// Mitteilungen (docs/CALENDAR-PLAN.md, 08.11.2026): timetable
// changes, bell history, tap routing and the settings of the shown area.
extension CalendarModel {
    var unreadNotifications: Int { notificationLog.unreadCount }

    /// The one-time offer „Mitteilungen einschalten“: only with real
    /// data, before iPadOS was ever asked, and until answered.
    var showsNotificationHint: Bool {
        loaded && permissionChecked && !showsSamples && !notificationHintDone && reminderPermission == .notDetermined
            && (state.connection != nil || !state.events.isEmpty)
            && (notificationSettings.changes || notificationSettings.overview || notificationSettings.eventReminders)
    }

    /// „Einschalten“ of the hint and of the sheet: asks iPadOS (its dialog
    /// appears only the first time) and plans.
    func enableNotifications() async {
        notificationHintDone = true
        CalendarNotificationPreferences.hintDone = true
        await requestReminderPermission()
        await rescheduleRemindersNow()
        CalendarNotificationHub.shared.scheduleBackgroundRefresh()
    }

    func dismissNotificationHint() {
        notificationHintDone = true
        CalendarNotificationPreferences.hintDone = true
    }

    /// Changes a setting; switching something on asks for permission the
    /// first time (never at launch).
    func updateNotificationSettings(_ change: (inout CalendarNotificationSettings) -> Void) {
        var next = notificationSettings
        change(&next)
        guard next != notificationSettings, next.isValid else { return }
        let before = notificationSettings
        notificationSettings = next
        CalendarNotificationPreferences.save(next)
        // The general reminder shows in the entries („15 Minuten vorher (allgemein)“).
        if next.eventReminders != before.eventReminders || next.eventMinutes != before.eventMinutes { rebuild() }
        let switchedOn = (next.changes && !before.changes) || (next.overview && !before.overview)
            || (next.eventReminders && !before.eventReminders)
        Task {
            if switchedOn { await requestReminderPermission() }
            await rescheduleRemindersNow()
            CalendarNotificationHub.shared.scheduleBackgroundRefresh()
            // Push service: new settings to the server; changes off signs off (docs/PUSH.md).
            await CalendarPushClient.shared.sync(self)
        }
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
        // No plan from a state that was not loaded (`derivesData`): what iPadOS has planned, the
        // widget file and the tile stay as they are. A model let go for an area switch does nothing.
        guard derivesData else {
            if !released { await collectDelivered() }
            return
        }
        // A detached connection (restored area, access data missing) shows its
        // timetable as outdated but never reminds from it.
        let plan = CalendarNotificationPlanner.plan(state: state, snapshot: credentialsMissing ? nil : snapshot,
                                                    systemEvents: systemEnabled ? systemEvents : [], settings: notificationSettings,
                                                    namespace: notificationNamespace, now: Date(), calendar: calendar)
        remindersPlannedUntil = plan.plannedUntil
        plannedReminderCount = plan.requests.count
        reminderError = await CalendarReminderCenter.shared.apply(plan, root: root, namespace: notificationNamespace)
        await collectDelivered()
        // Live Activity „Schultag“ and widget „Heute“ follow the same moments (noty calendar only).
        CalendarSchoolDayCenter.shared.update(self)
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

    // MARK: Timetable changes

    /// Compares the timetable before a refresh with the merged one
    /// (`CalendarChangeDetector`: only days both cover, only the future),
    /// keeps new changes in the bell and – outside the quiet hours –
    /// announces them: one notification, or one summary for several.
    /// While the push service is in charge of this connection (docs/PUSH.md)
    /// the changes go into the bell only: the server notifies. Changes of the
    /// day the tile „Schultag“ runs for are announced by the tile itself
    /// (alert, `CalendarSchoolDayCenter.announce`); the notification then
    /// still goes into the Mitteilungszentrale, silently.
    /// Called after the new timetable is shown (`refresh`): nothing here
    /// holds up the display; asking the push service waits at most 5 s.
    func recordChanges(since before: CalendarSourceSnapshot?) async {
        guard notificationSettings.changes, let before, let after = snapshot, before != after else { return }
        let session = generation, connection = state.connection?.id
        // The comparison first: no change, nothing to ask anyone.
        let changes = CalendarChangeDetector.changes(old: before, new: after, now: Date(), calendar: calendar)
        guard !changes.isEmpty else { return }
        // Then what the server already announced: push notifications still in the Mitteilungszentrale, and its
        // history when the last contact is old (at most 5 s). The bell then knows those changes (`addChanges`)
        // and they are not announced again.
        await collectDelivered()
        await CalendarPushClient.shared.refreshBeforeLocalChanges(self)
        // Meanwhile the connection may have been replaced or removed, or the changes switched off.
        guard session == generation, state.connection?.id == connection, notificationSettings.changes else { return }
        let now = Date()
        // A change that repeats after a different one of the same lesson keeps its own entry (`identifyingRepeats`).
        let records = notificationLog.identifyingRepeats(changes.map {
            CalendarNotificationRecord(change: $0, date: now, calendar: calendar, namespace: notificationNamespace)
        })
        let added = Set(addRecords(records).map(\.id))
        let fresh = zip(changes, records).filter { added.contains($0.1.id) }
        guard !fresh.isEmpty, !notificationSettings.isQuiet(now, calendar: calendar),
              !CalendarPushClient.shared.isActive(for: state.connection?.id) else { return }
        // The running tile of their day wakes the screen with an alert of its own; when it covers
        // every change, the notification goes into the Mitteilungszentrale without sound and banner.
        let announced = await CalendarSchoolDayCenter.shared.announce(fresh.map(\.0), model: self)
        let passive = fresh.allSatisfy { announced.contains($0.0.id) }
        if fresh.count == 1, let pair = fresh.first {
            let (change, record) = pair
            await CalendarReminderCenter.shared.post(id: record.id, title: record.title, body: record.body, namespace: notificationNamespace,
                                                     day: change.lesson.date, entryID: change.lesson.id, passive: passive)
        } else {
            let summary = CalendarLessonChange.summary(fresh.map(\.0), calendar: calendar)
            let first = fresh[0].0
            // The summary is no history entry of its own (each change is one).
            let id = CalendarNotificationLog.changePrefix + notificationNamespace + ".summary.\(Int(now.timeIntervalSinceReferenceDate))"
            await CalendarReminderCenter.shared.post(id: id, title: summary.title, body: summary.body, namespace: notificationNamespace,
                                                     day: first.lesson.date, entryID: nil, passive: passive)
        }
    }

    // MARK: History

    /// Changes found by the app and by the push service are kept once
    /// (`CalendarNotificationLog.addChanges`).
    @discardableResult
    func addRecords(_ records: [CalendarNotificationRecord]) -> [CalendarNotificationRecord] {
        var log = notificationLog
        let added = log.addChanges(records, now: Date())
        guard !added.isEmpty else { return [] }
        notificationLog = log
        persistNotificationLog()
        return added
    }

    /// A calendar notification of this area was shown or tapped.
    func addDelivered(_ records: [CalendarNotificationRecord]) { addRecords(records) }

    /// Reminders and overviews delivered while noty was not running.
    func collectDelivered() async {
        let delivered = await CalendarReminderCenter.shared.delivered(namespace: notificationNamespace)
        // A summary is shown in the Mitteilungszentrale only; its changes are already in the bell.
        addRecords(delivered.filter { !$0.id.contains(".summary.") })
    }

    /// The server's change history (`GET /v1/changes`) into the bell, under
    /// the push ids of this area.
    func mergePushChanges(_ changes: [CalendarPushAPI.Change]) {
        let records = changes.compactMap { change -> CalendarNotificationRecord? in
            guard let day = CivilDate(change.day), change.detected.isFinite else { return nil }
            return CalendarNotificationRecord(id: CalendarNotificationLog.pushChangeID(namespace: notificationNamespace, changeID: change.id),
                                              kind: .change, title: change.title, body: change.body,
                                              date: Date(timeIntervalSince1970: change.detected), day: day, entryID: change.entryID)
        }
        addRecords(records)
    }

    /// Entries a tapped push notification stands for, and the same changes
    /// as found by the app.
    func markChangesRead(_ ids: [String]) {
        let all = Set(ids.flatMap { notificationLog.relatedChangeIDs($0) })
        let unread = notificationLog.records.filter { all.contains($0.id) && !$0.read }.map(\.id)
        guard !unread.isEmpty else { return }
        for id in unread { notificationLog.markRead(id) }
        persistNotificationLog()
        CalendarReminderCenter.shared.removeDelivered(unread)
    }

    func markNotificationRead(_ id: String) {
        guard notificationLog.records.contains(where: { $0.id == id && !$0.read }) else { return }
        notificationLog.markRead(id)
        persistNotificationLog()
        CalendarReminderCenter.shared.removeDelivered([id])
    }

    func markAllNotificationsRead() {
        let ids = notificationLog.records.filter { !$0.read }.map(\.id)
        guard !ids.isEmpty else { return }
        notificationLog.markAllRead()
        persistNotificationLog()
        CalendarReminderCenter.shared.removeDelivered(ids)
    }

    private func persistNotificationLog() {
        notificationLogVersion += 1
        let log = notificationLog, version = notificationLogVersion, file = notificationFile
        Task { await file.write(log, version: version) }
    }

    // MARK: Opening

    /// The calendar is on screen: shown in the library and not covered by
    /// an open notebook (a full-screen cover over it).
    var onScreen: Bool { visible && library?.opened == nil }

    /// A bell entry was tapped.
    func open(_ record: CalendarNotificationRecord) {
        openNotification(id: record.id, day: record.day, entryID: record.entryID)
    }

    /// Opens the day/entry of a notification through the normal path
    /// (`show`), as a tap on the calendar would, and marks it read (with
    /// `readIDs`, the bell entries a push stands for). Not while a form, an
    /// enlarged note or a series question is open (they own the screen).
    /// While the calendar is not on screen (Hefte in front, a notebook open)
    /// the wish is remembered and carried out once it is (`showPending`);
    /// the library shows the calendar right away when no notebook is open.
    /// True when it was opened now.
    @discardableResult
    func openNotification(id: String, day: CivilDate?, entryID: String?, readIDs: [String] = []) -> Bool {
        guard onScreen else {
            pendingOpen = CalendarPendingOpen(id: id, day: day, entryID: entryID, readIDs: readIDs, since: Date())
            openRequest += 1
            return false
        }
        guard draft == nil, enlargedDraft == nil, pendingSeriesChange == nil else {
            notice = "Erst das geöffnete Fenster schließen, dann die Mitteilung erneut antippen."
            return false
        }
        // Read only now: nothing was opened before.
        markNotificationRead(id)
        markChangesRead(readIDs)
        if showsSamples { showsSamples = false }
        if let day { anchor = day.start(in: calendar) }
        // Its calendar may be switched off (`hiddenSources` is kept): then it is switched back on.
        if let entryID, let entry = revealedEvent(entryID) {
            show(entry)
        } else if day != nil {
            // A timetable change or the school-day tile without a (still) known lesson: show the timetable of that day.
            if id.hasPrefix(CalendarNotificationLog.changePrefix) || id == "noty.schoolday" { reveal(.timetable) }
            selection = nil
            if mode == .year || mode == .month { mode = .day }
        }
        openRequest += 1
        return true
    }

    /// „Untis-Zugang prüfen“ (push): the WebUntis sheet over the calendar.
    /// The calendar view opens it as soon as it is shown
    /// (`connectionSheetRequested`); while a notebook is open it waits until
    /// the calendar is on screen again (no sheet beneath the notebook).
    func requestConnectionSheet() {
        if library?.opened == nil {
            connectionSheetRequested = true
        } else {
            pendingConnectionSheet = Date()
        }
        openRequest += 1
    }

    /// A notice about a notification (another area, another connection):
    /// shown in the calendar, which the library brings forward when no
    /// notebook is open; otherwise it stays until the calendar is shown.
    func presentNotice(_ text: String) {
        notice = text
        openRequest += 1
    }

    /// What notifications asked for while the calendar was not on screen,
    /// once it is (calendar shown, notebook closed). A wish older than 15
    /// minutes is dropped: the calendar is then opened for something else.
    func showPending() {
        guard onScreen else { return }
        let limit = Date().addingTimeInterval(-15 * 60)
        if let since = pendingConnectionSheet {
            pendingConnectionSheet = nil
            if since > limit { connectionSheetRequested = true }
        }
        if let pending = pendingOpen {
            pendingOpen = nil
            if pending.since > limit {
                openNotification(id: pending.id, day: pending.day, entryID: pending.entryID, readIDs: pending.readIDs)
            }
        }
    }
}

/// A tapped notification that waits until the calendar is on screen.
struct CalendarPendingOpen {
    let id: String
    let day: CivilDate?
    let entryID: String?
    let readIDs: [String]
    let since: Date
}
