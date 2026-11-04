import Foundation
import UserNotifications
import NotebookCore

/// Kalender B3: hands the reminder plan of the shown area
/// (`CalendarReminderPlanner`, Core) to iPadOS as one-shot local
/// notifications. iPadOS keeps about 64 pending requests per app, so the plan
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
    func apply(_ plan: CalendarReminderPlan, root: URL) async -> String? {
        let previous = queue
        let task = Task { @MainActor () -> String? in
            _ = await previous?.value
            guard root == self.activeRoot else { return nil }
            return await self.replace(with: plan)
        }
        queue = task
        return await task.value
    }

    private func replace(with plan: CalendarReminderPlan) async -> String? {
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
            let content = UNMutableNotificationContent()
            content.title = request.title
            content.body = request.body
            content.sound = .default
            content.threadIdentifier = "noty.calendar"
            let interval = request.fireDate.timeIntervalSinceNow
            guard interval > 1 else { continue }
            // Absolute interval: fires at the planned instant also after a time-zone change.
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
            do { try await center.add(UNNotificationRequest(identifier: request.id, content: content, trigger: trigger)) }
            catch { failed += 1 }
        }
        return failed == 0 ? nil : "\(failed) Erinnerungen konnten nicht geplant werden."
    }
}
