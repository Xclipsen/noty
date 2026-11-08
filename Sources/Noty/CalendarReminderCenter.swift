import Foundation
import UIKit
import UserNotifications
import NotebookCore

/// Kalender B3 / Benachrichtigungen (08.11.2026): hands the plan of the shown area
/// (`CalendarReminderPlanner`, Core) to iPadOS as one-shot local
/// notifications (reminders and Morgen-Überblicke; identifiers carry the
/// channel/area namespace). iPadOS keeps about 64 pending requests per app, so the plan
/// is a rolling window (≤ 50) that is replaced as a whole: requests with the
/// calendar prefix that the plan no longer contains are removed, the others
/// are added again under their deterministic identifier (the same identifier
/// replaces a pending request – no duplicates). Only the active area plans;
/// a late plan of an area that is no longer shown is dropped. Permission is
/// requested only when the user switches a reminder on.
@MainActor
final class CalendarReminderCenter {
    static let shared = CalendarReminderCenter()

    enum Permission: Equatable { case notDetermined, denied, allowed }

    /// Data root of the shown area; only its calendar may plan.
    private(set) var activeRoot: URL?
    private var queue: Task<String?, Never>?
    private var center: UNUserNotificationCenter { .current() }

    func activate(root: URL) { activeRoot = root }

    func permission() async -> Permission {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        default: return .allowed
        }
    }

    /// Asks iPadOS once (the system shows its dialog only the first time).
    func requestPermission() async -> Permission {
        let current = await permission()
        guard current == .notDetermined else { return current }
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        return granted ? .allowed : .denied
    }

    /// Replaces the pending calendar requests by `plan` – serially, so an
    /// older plan never lands after a newer one. Returns an error text, if any.
    @discardableResult
    func apply(_ plan: CalendarReminderPlan, root: URL, namespace: String) async -> String? {
        let previous = queue
        let task = Task { @MainActor () -> String? in
            _ = await previous?.value
            guard root == self.activeRoot else { return nil }
            return await self.replace(with: plan, namespace: namespace)
        }
        queue = task
        return await task.value
    }

    /// Content shared by planned and immediate calendar notifications: the
    /// area/channel namespace and the target in userInfo (tap routing,
    /// history), one thread per area, no time-sensitive level.
    static func content(title: String, body: String, kind: CalendarNotificationRecord.Kind, namespace: String,
                        day: CivilDate?, entryID: String?) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.threadIdentifier = "noty.calendar.\(namespace)"
        content.categoryIdentifier = "noty.calendar.\(kind.rawValue)"
        content.interruptionLevel = .active
        var info: [String: String] = [CalendarNotificationHub.areaKey: namespace, CalendarNotificationHub.kindKey: kind.rawValue]
        if let day { info[CalendarNotificationHub.dayKey] = day.description }
        if let entryID { info[CalendarNotificationHub.entryKey] = entryID }
        content.userInfo = info
        return content
    }

    /// Delivers one notification now (a timetable change). Its identifier
    /// is outside `CalendarReminder.prefix`, so a plan replacement never
    /// removes it. Nothing without permission. `passive`: the tile
    /// „Schultag“ already woke the screen with the same change – into the
    /// Mitteilungszentrale without sound or lighting up; with noty in the
    /// foreground the usual banner (`willPresent`) applies.
    func post(id: String, title: String, body: String, namespace: String, day: CivilDate?, entryID: String?, passive: Bool = false) async {
        guard await permission() == .allowed else { return }
        let content = Self.content(title: title, body: body, kind: .change, namespace: namespace, day: day, entryID: entryID)
        if passive && UIApplication.shared.applicationState != .active {
            content.interruptionLevel = .passive
            content.sound = nil
        }
        try? await center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    /// Calendar notifications of `namespace` still in the Mitteilungszentrale
    /// (reminders and overviews delivered while noty was not running).
    func delivered(namespace: String) async -> [CalendarNotificationRecord] {
        await center.deliveredNotifications().compactMap { notification in
            // Push notifications (docs/PUSH.md) name their area through their connection.
            guard CalendarNotificationHub.route(notification.request).area == namespace else { return nil }
            return CalendarNotificationHub.record(notification)
        }
    }

    /// Read in the bell: gone from the Mitteilungszentrale as well. Push
    /// notifications have identifiers of their own (from APNs) and are
    /// found by their change id.
    func removeDelivered(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        center.removeDeliveredNotifications(withIdentifiers: ids)
        let raw = Set(ids.compactMap(CalendarNotificationLog.pushRawChangeID))
        guard !raw.isEmpty else { return }
        Task {
            let delivered = await center.deliveredNotifications()
            let matching = delivered.filter { notification in
                guard let push = notification.request.content.userInfo[CalendarNotificationHub.pushKey] as? [String: Any],
                      let id = push[CalendarPushPayload.Key.changeID.rawValue] as? String else { return false }
                return raw.contains(id)
            }.map(\.request.identifier)
            if !matching.isEmpty { center.removeDeliveredNotifications(withIdentifiers: matching) }
        }
    }

    private func replace(with plan: CalendarReminderPlan, namespace: String) async -> String? {
        let pending = await center.pendingNotificationRequests()
        let wanted = Set(plan.requests.map(\.id))
        let stale = pending.map(\.identifier).filter { $0.hasPrefix(CalendarReminder.prefix) && !wanted.contains($0) }
        if !stale.isEmpty { center.removePendingNotificationRequests(withIdentifiers: stale) }
        guard !plan.requests.isEmpty else { return nil }
        guard await permission() == .allowed else {
            center.removePendingNotificationRequests(withIdentifiers: Array(wanted))
            return nil
        }
        var failed = 0
        for request in plan.requests {
            let kind: CalendarNotificationRecord.Kind = switch request.kind {
            case .event: .event
            case .lesson: .lesson
            case .overview: .overview
            }
            let content = Self.content(title: request.title, body: request.body, kind: kind, namespace: namespace,
                                       day: request.day, entryID: request.entryID)
            let interval = request.fireDate.timeIntervalSinceNow
            guard interval > 1 else { continue }
            // Absolute interval: fires at the planned instant also after a time-zone change.
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
            do { try await center.add(UNNotificationRequest(identifier: request.id, content: content, trigger: trigger)) }
            catch { failed += 1 }
        }
        return failed == 0 ? nil : "\(failed) Mitteilungen konnten nicht geplant werden."
    }
}
