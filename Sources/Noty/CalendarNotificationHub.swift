import Foundation
import UIKit
import UserNotifications
import BackgroundTasks
import CryptoKit
import NotebookCore
import NotyCalendarShared

/// Benachrichtigungen (docs/CALENDAR-PLAN.md, 08.11.2026): the app-wide
/// side of the calendar notifications.
///
///  - Delegate of `UNUserNotificationCenter`: a tap on a calendar
///    notification opens its day/entry through the calendar model of the
///    area it belongs to (`model.openNotification`, the normal `show` path);
///    a notification of another area only says so. Push notifications of
///    the server noty-push (docs/PUSH.md) carry `userInfo["noty"]` instead:
///    their connection names the area, `auth` opens the WebUntis sheet.
///    While the calendar is not on screen (Hefte in front, a notebook open)
///    the model keeps the wish and the notice until it is
///    (`CalendarModel.showPending`); nothing is selected beneath a notebook.
///  - Background refresh (`BGAppRefreshTask`, scheduled when the app leaves
///    the foreground; iPadOS decides if and when it runs): it uses the
///    calendar model of the shown area – the same repository and write claim
///    as in the foreground, never a second writer. Without a loaded model
///    (app launched in the background without its scene) it does nothing.
@MainActor
final class CalendarNotificationHub: NSObject, UNUserNotificationCenterDelegate {
    static let shared = CalendarNotificationHub()
    /// Listed in Info.plist `BGTaskSchedulerPermittedIdentifiers`.
    nonisolated static let refreshIdentifier = "de.la.noty.calendar.refresh"
    /// userInfo keys of every calendar notification.
    nonisolated static let areaKey = "noty.area"
    nonisolated static let dayKey = "noty.day"
    nonisolated static let entryKey = "noty.entry"
    nonisolated static let kindKey = "noty.kind"
    /// userInfo key of push notifications (`CalendarPushPayload`: kind, connectionID, changeID, changeIDs, day, entryID, …).
    nonisolated static let pushKey = CalendarPushPayload.rootKey

    /// The calendar of the shown area (weak: an area switch replaces it).
    private(set) weak var model: CalendarModel?
    /// A tapped notification that arrived before its model was loaded.
    private var pendingRoute: Route?

    struct Route: Sendable {
        let id: String
        let area: String?
        let day: CivilDate?
        let entry: String?
        /// Kind of a push notification (change, summary, auth, test); nil for local ones.
        var push: String? = nil
        /// Bell entries a push notification stands for (read on tap).
        var readIDs: [String] = []
    }

    func install() { UNUserNotificationCenter.current().delegate = self }

    func attach(_ model: CalendarModel) { self.model = model }

    /// The model finished loading: a tap that waited for it is handled now.
    func modelLoaded(_ model: CalendarModel) {
        guard self.model === model else { return }
        if let target = pendingSchoolDay { pendingSchoolDay = nil; openSchoolDay(target) }
        guard let route = pendingRoute else { return }
        pendingRoute = nil
        handle(route)
    }

    /// A deep link that arrived before its model was loaded.
    private var pendingSchoolDay: SchoolDayLink.Target?

    /// Tap on the tile „Schultag“ or the widget „Heute“: the day/lesson of the
    /// shown area through the normal path; another connection only says so.
    func openSchoolDay(_ target: SchoolDayLink.Target) {
        guard let model, model.loaded else { pendingSchoolDay = target; return }
        if let connection = target.connectionID, model.connection?.id.uuidString != connection {
            model.presentNotice("Diese Kachel gehört zu einem anderen Bereich oder einer früheren WebUntis-Verbindung.")
            return
        }
        model.openNotification(id: "noty.schoolday", day: target.day, entryID: target.entryID)
    }

    // MARK: Namespace

    /// „<Kanal>.<Bereich>“: channel of this app and a short stable token of
    /// the area (its path inside Documents, not the container path, which
    /// iPadOS may change on updates). In every identifier and userInfo.
    static func namespace(root: URL) -> String {
        let channel = (Bundle.main.object(forInfoDictionaryKey: "NotyChannel") as? String) ?? "stable"
        let documents = URL.documentsDirectory.resolvingSymlinksInPath().standardizedFileURL.path
        var path = root.resolvingSymlinksInPath().standardizedFileURL.path
        if path.hasPrefix(documents) { path = String(path.dropFirst(documents.count)) }
        let token = CryptoKit.SHA256.hash(data: Data(path.utf8)).prefix(5).map { String(format: "%02x", $0) }.joined()
        return "\(channel).\(token)"
    }

    // MARK: Delegate

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        let route = Self.route(notification.request)
        guard route.area != nil else { return [.banner, .list, .sound] }
        let record = Self.record(notification)
        await MainActor.run {
            guard let model = self.model, model.notificationNamespace == route.area else { return }
            if let record { model.addDelivered([record]) }
            // A push in the foreground: banner, and the server's history into the bell (a summary's entries too).
            if route.push != nil { Task { await CalendarPushClient.shared.sync(model, force: true) } }
        }
        return [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier else { return }
        let route = Self.route(response.notification.request)
        guard route.area != nil else { return }
        let record = Self.record(response.notification)
        await MainActor.run {
            if let record, let model = self.model, model.notificationNamespace == route.area { model.addDelivered([record]) }
            self.handle(route)
        }
    }

    private func handle(_ route: Route) {
        guard let model, model.loaded else { pendingRoute = route; return }
        guard model.notificationNamespace == route.area else {
            model.presentNotice("Diese Mitteilung gehört zu einem anderen Bereich. Wechsle dorthin, um den Termin zu sehen.")
            return
        }
        guard let kind = route.push else {
            model.openNotification(id: route.id, day: route.day, entryID: route.entry)
            return
        }
        if kind == CalendarPushPayload.Kind.auth.rawValue {
            // „Untis-Zugang prüfen“: straight to the WebUntis sheet (not beneath an open notebook).
            model.requestConnectionSheet()
            return
        }
        // The entries the push stands for are read once it is really opened.
        let opened = model.openNotification(id: route.id, day: route.day, entryID: route.entry, readIDs: route.readIDs)
        let ids = route.readIDs
        Task {
            await CalendarPushClient.shared.sync(model, force: true)
            // A summary's entries arrive with the server's history: read as well.
            if opened { model.markChangesRead(ids) }
        }
    }

    nonisolated static func route(_ request: UNNotificationRequest) -> Route {
        let info = request.content.userInfo
        if let push = info[pushKey] as? [String: Any] {
            typealias Key = CalendarPushPayload.Key
            typealias Kind = CalendarPushPayload.Kind
            func value<T>(_ key: Key) -> T? { push[key.rawValue] as? T }
            let kind = value(.kind) ?? Kind.change.rawValue
            let area = CalendarPushClient.namespace(forConnection: value(.connectionID))
            var ids: [String] = value(.changeIDs) ?? []
            if let id: String = value(.changeID), !ids.contains(id) { ids.insert(id, at: 0) }
            let readIDs = area.map { area in ids.map { CalendarNotificationLog.pushChangeID(namespace: area, changeID: $0) } } ?? []
            // A single change is its own bell entry; the others keep the request id.
            let id = kind == Kind.change.rawValue ? readIDs.first ?? request.identifier : request.identifier
            return Route(id: id, area: kind == Kind.test.rawValue ? nil : area, day: (value(.day) as String?).flatMap(CivilDate.init),
                         entry: value(.entryID), push: kind, readIDs: readIDs)
        }
        return Route(id: request.identifier, area: info[areaKey] as? String, day: (info[dayKey] as? String).flatMap(CivilDate.init),
                     entry: info[entryKey] as? String)
    }

    /// The history entry of a delivered calendar notification (nil for others).
    nonisolated static func record(_ notification: UNNotification) -> CalendarNotificationRecord? {
        let request = notification.request
        let info = request.content.userInfo
        if info[pushKey] is [String: Any] {
            // Push: a single change is a bell entry (the same id as from `GET /v1/changes`).
            let route = Self.route(request)
            guard route.push == CalendarPushPayload.Kind.change.rawValue, route.area != nil, route.readIDs.first == route.id else { return nil }
            return CalendarNotificationRecord(id: route.id, kind: .change, title: request.content.title, body: request.content.body,
                                              date: notification.date, day: route.day, entryID: route.entry)
        }
        guard info[areaKey] is String, let raw = info[kindKey] as? String,
              let kind = CalendarNotificationRecord.Kind(rawValue: raw) else { return nil }
        return CalendarNotificationRecord(id: request.identifier, kind: kind, title: request.content.title, body: request.content.body,
                                          date: notification.date, day: (info[dayKey] as? String).flatMap(CivilDate.init),
                                          entryID: info[entryKey] as? String)
    }

    // MARK: Background refresh

    /// Asks iPadOS for a refresh in 15 minutes at the earliest (the same
    /// minimum as in the foreground; iPadOS decides when, or whether, it
    /// runs). Only when there is something to refresh for.
    func scheduleBackgroundRefresh() {
        guard let model, model.wantsBackgroundRefresh else {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.refreshIdentifier)
            return
        }
        let request = BGAppRefreshTaskRequest(identifier: Self.refreshIdentifier)
        request.earliestBeginDate = Date().addingTimeInterval(CalendarModel.automaticInterval)
        // Fails e.g. when Hintergrundaktualisierung is off; nothing else to do then.
        try? BGTaskScheduler.shared.submit(request)
    }

    /// Runs the refresh through the shown area's model, or nothing.
    static func runBackgroundRefresh() async {
        let hub = shared
        defer { hub.scheduleBackgroundRefresh() }
        // Files and keychain may be unreadable before the first unlock.
        guard UIApplication.shared.isProtectedDataAvailable else { return }
        // Beside the refresh: the push registration's daily contact, whichever area is shown (docs/PUSH.md).
        let contact = Task { await CalendarPushClient.shared.keepAlive() }
        // A model that is still loading gets a moment; none at all: nothing.
        for _ in 0..<10 {
            if hub.model?.loaded == true { break }
            try? await Task.sleep(for: .milliseconds(500))
        }
        if let model = hub.model, model.loaded { await model.backgroundRefresh() }
        await contact.value
    }
}

/// The user's notification choices: a device preference of this app (not
/// calendar data; not in the calendar package or any backup).
enum CalendarNotificationPreferences {
    private static let key = "noty.calendar.notifications"
    private static let hintKey = "noty.calendar.notifications.hintDone"

    static func load() -> CalendarNotificationSettings {
        guard let data = UserDefaults.standard.data(forKey: key),
              let settings = try? JSONDecoder().decode(CalendarNotificationSettings.self, from: data) else { return CalendarNotificationSettings() }
        return settings
    }

    static func save(_ settings: CalendarNotificationSettings) {
        if let data = try? JSONEncoder().encode(settings) { UserDefaults.standard.set(data, forKey: key) }
    }

    /// The one-time hint „Benachrichtigungen einschalten“ was answered.
    static var hintDone: Bool {
        get { UserDefaults.standard.bool(forKey: hintKey) }
        set { UserDefaults.standard.set(newValue, forKey: hintKey) }
    }
}

/// The bell history file of one area: derived data in Application Support
/// (`CalendarNotifications/<Kanal>.<Bereich>.json`), outside the calendar
/// package (whose `Cache/` the device-store check keeps to timetables) and
/// outside every backup. Written atomically and in order (a stale write
/// never replaces a newer one); a newer format is left untouched.
actor CalendarNotificationLogFile {
    let url: URL
    private var written = 0
    private var locked = false

    init(namespace: String) {
        let base = URL.applicationSupportDirectory.appendingPathComponent("CalendarNotifications", isDirectory: true)
        url = base.appendingPathComponent(namespace + ".json")
    }

    func read() -> CalendarNotificationLog {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), values.isRegularFile == true,
              (values.fileSize ?? 0) <= 4_000_000, let data = try? Data(contentsOf: url) else { return CalendarNotificationLog() }
        guard let log = CalendarNotificationLog.decode(data) else { locked = true; return CalendarNotificationLog() }
        return log
    }

    func write(_ log: CalendarNotificationLog, version: Int) {
        guard !locked, version > written else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try log.encoded().write(to: url, options: .atomic)
            written = version
        } catch {
            // Derived data: the history stays in memory and is written with the next change.
        }
    }
}
