import Foundation
import NotebookCore

// Benachrichtigungen (docs/CALENDAR-PLAN.md, 08.11.2026): timetable
// changes, bell history, tap routing and the settings of the shown area.
extension CalendarModel {
    var unreadNotifications: Int { notificationLog.unreadCount }

    /// The one-time offer „Benachrichtigungen einschalten“: only with real
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

    // MARK: Timetable changes

    /// Compares the timetable before a refresh with the merged one
    /// (`CalendarChangeDetector`: only days both cover, only the future),
    /// keeps new changes in the bell and – outside the quiet hours –
    /// announces them: one notification, or one summary for several.
    /// While the push service is in charge of this connection (docs/PUSH.md)
    /// the changes go into the bell only: the server notifies.
    func recordChanges(since before: CalendarSourceSnapshot?) async {
        guard notificationSettings.changes, let before, let after = snapshot, before != after else { return }
        let now = Date()
        let changes = CalendarChangeDetector.changes(old: before, new: after, now: now, calendar: calendar)
        guard !changes.isEmpty else { return }
        let records = changes.map { CalendarNotificationRecord(change: $0, date: now, calendar: calendar, namespace: notificationNamespace) }
        let added = Set(addRecords(records).map(\.id))
        let fresh = zip(changes, records).filter { added.contains($0.1.id) }
        guard !fresh.isEmpty, !notificationSettings.isQuiet(now, calendar: calendar),
              !CalendarPushClient.shared.isActive(for: state.connection?.id) else { return }
        if fresh.count == 1, let pair = fresh.first {
            let (change, record) = pair
            await CalendarReminderCenter.shared.post(id: record.id, title: record.title, body: record.body, namespace: notificationNamespace,
                                                     day: change.lesson.date, entryID: change.lesson.id)
        } else {
            let summary = CalendarLessonChange.summary(fresh.map(\.0), calendar: calendar)
            let first = fresh[0].0
            // The summary is no history entry of its own (each change is one).
            let id = CalendarNotificationLog.changePrefix + notificationNamespace + ".summary.\(Int(now.timeIntervalSinceReferenceDate))"
            await CalendarReminderCenter.shared.post(id: id, title: summary.title, body: summary.body, namespace: notificationNamespace,
                                                     day: first.lesson.date, entryID: nil)
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

    /// A bell entry was tapped.
    func open(_ record: CalendarNotificationRecord) {
        markNotificationRead(record.id)
        openNotification(id: record.id, day: record.day, entryID: record.entryID)
    }

    /// Opens the day/entry of a notification through the normal path
    /// (`show`), as a tap on the calendar would. Nothing while a form, an
    /// enlarged note or a series question is open (they own the screen).
    func openNotification(id: String, day: CivilDate?, entryID: String?) {
        markNotificationRead(id)
        guard draft == nil, enlargedDraft == nil, pendingSeriesChange == nil else {
            notice = "Erst das geöffnete Fenster schließen, dann die Mitteilung erneut antippen."
            return
        }
        if showsSamples { showsSamples = false }
        if let day { anchor = day.start(in: calendar) }
        if let entryID, let entry = event(entryID) {
            show(entry)
        } else if day != nil {
            selection = nil
            if mode == .year || mode == .month { mode = .day }
        }
        openRequest += 1
    }
}
