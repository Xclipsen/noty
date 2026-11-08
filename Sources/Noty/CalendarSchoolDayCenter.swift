import SwiftUI
import UIKit
import ActivityKit
import WidgetKit
import NotebookCore
import NotyCalendarShared

/// Live Activity „Schultag“ and widget „Heute“ (docs/LIVE-ACTIVITY-PLAN.md,
/// Schritte 1 und 3), app side, only in noty calendar:
///
///  - After every plan update of the shown area (`rescheduleRemindersNow`:
///    load, commit, WebUntis refresh, app active, background refresh) the
///    state of today is computed (`CalendarSchoolDay`, Core) and handed to
///    ActivityKit: started from 30 minutes before the first lesson that takes
///    place (iPadOS 26+: scheduled ahead with `request(…, start:)`; before
///    that only while noty runs in the foreground), updated at changes,
///    restarted before the 8-h limit (the new tile first, then the old one
///    goes) and ended right after the last lesson. One run at a time
///    (`serial`): overlapping updates never start a second tile.
///  - Timetable changes of the tile's day (`announce`, from `recordChanges`):
///    when the app itself would post the change notification (push service
///    not in charge, outside the quiet hours, changes switched on), the tile
///    update carries the alert (wakes the screen); the notification still
///    goes into the Mitteilungszentrale, silently (`passive`, no sound), so
///    the change stays there after the tile. While the push service
///    notifies, the tile updates silently.
///  - The derived widget file (today and tomorrow) is written into the App
///    Group and the widget timeline reloaded when its lessons changed.
///  - Push tokens (push-to-start and per activity) are collected for the push
///    service; reporting them is Schritt 2 (`CalendarPushClient.liveActivityTokens`).
///
/// Locally the tile only changes while noty runs (foreground, background
/// refresh when iPadOS grants it); between those moments the countdown runs
/// by itself and `staleDate` marks the tile „Stand veraltet“ at the next
/// phase change. Server updates (Schritt 2) close that gap.
@MainActor
final class CalendarSchoolDayCenter: ObservableObject {
    static let shared = CalendarSchoolDayCenter()

    private static let enabledKey = "noty.calendar.schoolDayActivity"
    private static let segmentsKey = "noty.calendar.schoolDayActivity.segments"

    /// Only noty calendar embeds the widget extension and allows Live Activities.
    let supported: Bool = {
        (Bundle.main.object(forInfoDictionaryKey: "NotyChannel") as? String) == "calendar"
            && (Bundle.main.object(forInfoDictionaryKey: "NSSupportsLiveActivities") as? Bool) == true
    }()

    /// „Schultag auf dem Sperrbildschirm“ (device preference; default on).
    @Published private(set) var enabled = UserDefaults.standard.object(forKey: CalendarSchoolDayCenter.enabledKey) as? Bool ?? true
    /// Settings › noty calendar › Live-Aktivitäten (read on every update).
    @Published private(set) var systemAllowed = true
    /// Last ActivityKit problem (German sentence), shown in the sheet.
    @Published private(set) var lastError: String?
    /// What the tile shows now (sheet: „Läuft: …“), nil without activity.
    @Published private(set) var running: String?

    private var lastWidget: SchoolDayWidgetFile?
    private var tick: Task<Void, Never>?
    private var observed = Set<String>()
    private var startTokenObserved = false
    /// ActivityKit work, one run after the other.
    private var queue: Task<Void, Never>?
    /// Bumped by every `update`: a queued run that a newer one follows is skipped.
    private var requested = 0

    private init() { refreshDemoRunning() }

    func setEnabled(_ value: Bool, model: CalendarModel) {
        enabled = value
        UserDefaults.standard.set(value, forKey: Self.enabledKey)
        update(model)
    }

    // MARK: Update

    /// Recomputes widget file and activity for the shown area's model.
    func update(_ model: CalendarModel) {
        guard supported, model.loaded, CalendarNotificationHub.shared.model === model else { return }
        observeStartToken()
        refreshDemoRunning()
        let now = Date()
        let calendar = model.calendar
        let snapshot = model.credentialsMissing ? nil : model.snapshot
        let connection = model.connection?.id
        writeWidget(namespace: model.notificationNamespace, connection: connection, snapshot: snapshot, now: now, calendar: calendar)
        systemAllowed = ActivityAuthorizationInfo().areActivitiesEnabled

        // The day the tile is about: today until its last lesson, then tomorrow.
        let today = CivilDate(now, calendar: calendar)
        var target: (day: CivilDate, school: CalendarSchoolDay)?
        if connection != nil, enabled, systemAllowed {
            for day in [today, today.adding(days: 1)] {
                guard let lessons = CalendarSchoolDay.lessons(snapshot: snapshot, day: day),
                      let school = CalendarSchoolDay(lessons: lessons) else { continue }
                if Int(now.timeIntervalSince1970) < school.plan.end { target = (day, school); break }
            }
        }
        let attributes = connection.flatMap { id in
            target.map { SchoolDayAttributes(connectionID: id.uuidString, day: $0.day.description) }
        }
        let settings = model.notificationSettings
        let school = target?.school
        requested += 1
        let request = requested
        Task {
            await self.serial {
                // A newer update is queued behind this one: it alone runs.
                guard request == self.requested else { return }
                await self.apply(attributes: attributes, school: school, settings: settings, calendar: calendar)
            }
        }
    }

    /// One ActivityKit run at a time, in call order (`apply`, `announce`,
    /// the test tile): two overlapping runs could each request a tile.
    private func serial<T: Sendable>(_ work: @escaping @MainActor () async -> T) async -> T {
        let previous = queue
        let task = Task { @MainActor () -> T in
            await previous?.value
            return await work()
        }
        queue = Task { @MainActor in _ = await task.value }
        return await task.value
    }

    /// Activities that still run (also scheduled and stale ones).
    private static func live() -> [Activity<SchoolDayAttributes>] {
        Activity<SchoolDayAttributes>.activities.filter { activity in
            switch activity.activityState {
            case .ended, .dismissed: false
            default: true
            }
        }
    }

    private func apply(attributes: SchoolDayAttributes?, school: CalendarSchoolDay?, settings: CalendarNotificationSettings,
                       calendar: Calendar) async {
        let time = Int(Date().timeIntervalSince1970)
        let activities = Self.live()
        // Another day, another connection, switched off: gone at once.
        for activity in activities where activity.attributes != attributes && activity.attributes.connectionID != Self.demoConnection {
            await Self.end(activity.id, nil)
            forget(activity.id)
        }
        guard let attributes, let school else { running = nil; scheduleTick(nil); return }
        let plan = school.plan
        let mine = activities.filter { $0.attributes == attributes }

        if time < plan.start {
            // Before the day: iPadOS 26 can start it on its own; earlier versions wait for noty.
            running = nil
            // A pending tile with an outdated start (first lesson changed) is replaced.
            let expected = school.state(at: plan.start)
            var kept = false
            for activity in mine {
                if !kept && activity.content.state == expected { kept = true; continue }
                await Self.end(activity.id, nil)
                forget(activity.id)
            }
            if !kept { schedule(attributes: attributes, school: school, settings: settings, calendar: calendar) }
            scheduleTick(plan.start)
            return
        }
        let state = school.state(at: time)
        if time >= plan.end {
            for activity in mine {
                await Self.end(activity.id, ActivityContent(state: state, staleDate: nil))
                forget(activity.id)
            }
            running = nil
            scheduleTick(nil)
            return
        }
        let content = Self.content(school, at: time)
        // 8-h limit: from each restart moment on, the tile belongs to the next segment.
        let segment = plan.restarts.filter { $0 <= time }.count
        let known = segments
        var current = mine.last { (known[$0.id] ?? 0) >= segment }
        var started = false
        if current == nil {
            do {
                let activity = try Activity.request(attributes: attributes, content: content, pushType: .token)
                remember(activity.id, segment: segment)
                observe(activity)
                current = activity
                started = true
                lastError = nil
            } catch {
                // Typically: noty is not in the foreground (iPadOS starts activities only then) or they are switched off.
                lastError = "Kachel nicht gestartet: \(error.localizedDescription)"
            }
        }
        // Only now the older tiles go: the new one is already there – or none
        // could be started, then the newest old one stays (and is updated)
        // until the next attempt, instead of no tile at all.
        let kept = current ?? mine.last
        for activity in mine where activity.id != kept?.id {
            await Self.end(activity.id, ActivityContent(state: state, staleDate: nil))
            forget(activity.id)
        }
        if let kept, !started, kept.content.state != state || kept.content.staleDate != content.staleDate {
            await Self.update(kept.id, content, alert: nil)
        }
        running = kept == nil ? nil : SchoolDayText.headline(state, calendar: calendar, detailed: true)
        // While noty runs: on time at the next phase change and at the next restart moment.
        let restart = plan.restarts.first { $0 > time }
        scheduleTick([school.nextTransition(after: time), restart].compactMap { $0 }.min())
    }

    /// The tile's content at `time`, outdated („Stand veraltet“) a minute after the next phase change.
    private static func content(_ school: CalendarSchoolDay, at time: Int) -> ActivityContent<SchoolDayContentState> {
        ActivityContent(state: school.state(at: time), staleDate: school.nextTransition(after: time).map { SchoolDayText.date($0 + 60) },
                        relevanceScore: 100)
    }

    // MARK: Changes of the day

    /// Announces timetable changes through the running tile of their day:
    /// one update with the new state and an alert (title/text as the change
    /// notification would have them, `CalendarLessonChange` from Core). Only
    /// for a tile that runs now (`.active`) for the shown connection; returns
    /// the ids of the changes it announced – the caller posts their
    /// notification silently.
    /// The caller decides whether an alert is due at all (changes on, outside
    /// the quiet hours, push service not in charge: `recordChanges`).
    func announce(_ changes: [CalendarLessonChange], model: CalendarModel) async -> Set<String> {
        guard supported, enabled, !changes.isEmpty, model.loaded, CalendarNotificationHub.shared.model === model,
              let connection = model.connection?.id, !model.credentialsMissing, let snapshot = model.snapshot,
              snapshot.connection == connection else { return [] }
        let calendar = model.calendar
        let ids: [String] = await serial {
            let time = Int(Date().timeIntervalSince1970)
            var announced: [String] = []
            var days = Set<String>()
            for activity in Self.live() where activity.attributes.connectionID == connection.uuidString && activity.activityState == .active {
                guard days.insert(activity.attributes.day).inserted, let day = CivilDate(activity.attributes.day) else { continue }
                let mine = changes.filter { $0.lesson.date == day }
                guard !mine.isEmpty, let lessons = CalendarSchoolDay.lessons(snapshot: snapshot, day: day),
                      let school = CalendarSchoolDay(lessons: lessons), time >= school.plan.start, time < school.plan.end else { continue }
                let text = CalendarLessonChange.summary(mine, calendar: calendar)
                let alert = AlertConfiguration(title: LocalizedStringResource(stringLiteral: text.title),
                                               body: LocalizedStringResource(stringLiteral: text.body), sound: .default)
                await Self.update(activity.id, Self.content(school, at: time), alert: alert)
                announced += mine.map(\.id)
            }
            return announced
        }
        return Set(ids)
    }

    // MARK: Test-Kachel (sample data, independent of the timetable)

    /// Marks the sample tile: `apply` leaves it alone, nothing is stored.
    nonisolated static let demoConnection = "demo"
    /// A test tile runs: read from ActivityKit (also after a restart of noty), not remembered.
    @Published private(set) var demoRunning = false

    /// Sample state around now: Mathematik runs (20 of 45 min), next Deutsch, Stunde 3/6.
    private func demoState(changed: Bool) -> SchoolDayContentState {
        let now = Int(Date().timeIntervalSince1970)
        let start = now - 20 * 60, end = now + 25 * 60
        let current = SchoolDayLesson(title: "Mathematik", room: changed ? "R 112" : "R 101", start: start, end: end,
                                      note: changed ? "Raumwechsel" : nil, changed: changed)
        let next = SchoolDayLesson(title: "Deutsch", room: "R 204", start: end + 15 * 60, end: end + 60 * 60,
                                   note: "fällt aus", changed: true, cancelled: true)
        return SchoolDayContentState(phase: .lesson, phaseStart: start, phaseEnd: end, current: current, next: next,
                                     number: 3, count: 6, dayStart: now - 160 * 60, dayEnd: now + 180 * 60)
    }

    private var demoActivities: [Activity<SchoolDayAttributes>] {
        Self.live().filter { $0.attributes.connectionID == Self.demoConnection }
    }

    private func refreshDemoRunning() {
        let value = supported && !demoActivities.isEmpty
        if demoRunning != value { demoRunning = value }
    }

    func startDemo() {
        Task {
            await serial {
                for activity in self.demoActivities { await Self.end(activity.id, nil) }
                let attributes = SchoolDayAttributes(connectionID: Self.demoConnection, day: "demo")
                let content = ActivityContent(state: self.demoState(changed: false), staleDate: nil, relevanceScore: 100)
                do {
                    _ = try Activity.request(attributes: attributes, content: content, pushType: nil)
                    self.lastError = nil
                } catch {
                    self.lastError = "Test-Kachel nicht gestartet: \(error.localizedDescription)"
                }
                self.refreshDemoRunning()
            }
        }
    }

    /// Like a real change during the day: the tile updates and wakes the screen.
    func demoChange() {
        let content = ActivityContent(state: demoState(changed: true), staleDate: nil, relevanceScore: 100)
        Task {
            await serial {
                guard let id = self.demoActivities.first?.id else { self.refreshDemoRunning(); return }
                let alert = AlertConfiguration(title: "Stundenplanänderung", body: "Mathematik jetzt in R 112 (statt R 101)", sound: .default)
                await Self.update(id, content, alert: alert)
            }
        }
    }

    func endDemo() {
        Task {
            await serial {
                for activity in self.demoActivities { await Self.end(activity.id, nil) }
                self.refreshDemoRunning()
            }
        }
    }

    /// ActivityKit calls outside the main actor (an `Activity` is not
    /// Sendable): looked up again by id.
    nonisolated private static func end(_ id: String, _ content: ActivityContent<SchoolDayContentState>?) async {
        guard let activity = Activity<SchoolDayAttributes>.activities.first(where: { $0.id == id }) else { return }
        await activity.end(content, dismissalPolicy: .immediate)
    }

    nonisolated private static func update(_ id: String, _ content: ActivityContent<SchoolDayContentState>,
                                           alert: AlertConfiguration?) async {
        guard let activity = Activity<SchoolDayAttributes>.activities.first(where: { $0.id == id }) else { return }
        await activity.update(content, alertConfiguration: alert)
    }

    /// iPadOS 26+: the activity of a coming day starts by itself 30 minutes
    /// before the first lesson (the API requires an alert; outside the quiet
    /// hours only). Earlier versions: started by the next update after that moment.
    private func schedule(attributes: SchoolDayAttributes, school: CalendarSchoolDay, settings: CalendarNotificationSettings,
                          calendar: Calendar) {
        guard #available(iOS 26.0, *) else { return }
        let start = SchoolDayText.date(school.plan.start)
        guard !settings.isQuiet(start, calendar: calendar), let first = school.taking.first else { return }
        let state = school.state(at: school.plan.start)
        let content = ActivityContent(state: state, staleDate: SchoolDayText.date(school.dayStart + 60), relevanceScore: 100)
        let body = "1. Stunde \(SchoolDayText.clock(first.start, calendar: calendar)): \(SchoolDayText.line(first))"
        let alert = AlertConfiguration(title: "Schultag", body: LocalizedStringResource(stringLiteral: body), sound: .default)
        do {
            let activity = try Activity.request(attributes: attributes, content: content, pushType: .token, style: .standard,
                                                alertConfiguration: alert, start: start)
            remember(activity.id, segment: 0)
            observe(activity)
            lastError = nil
        } catch {
            lastError = "Kachel für \(attributes.day) nicht vorgemerkt: \(error.localizedDescription)"
        }
    }

    /// While noty runs, the next phase change (or restart moment) updates the tile on time.
    private func scheduleTick(_ time: Int?) {
        tick?.cancel()
        guard let time else { return }
        let delay = max(1, TimeInterval(time) - Date().timeIntervalSince1970 + 1)
        guard delay < 12 * 3600 else { return }
        tick = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self, let model = CalendarNotificationHub.shared.model else { return }
            self.update(model)
        }
    }

    // MARK: Widget file

    private func writeWidget(namespace: String, connection: UUID?, snapshot: CalendarSourceSnapshot?, now: Date, calendar: Calendar) {
        guard let connection, let snapshot, snapshot.connection == connection else {
            if SchoolDayWidgetStore.write(nil) { WidgetCenter.shared.reloadTimelines(ofKind: SchoolDayWidgetStore.widgetKind) }
            lastWidget = nil
            return
        }
        let file = SchoolDayWidgetFile(namespace: namespace, connectionID: connection, snapshot: snapshot, now: now, calendar: calendar)
        if lastWidget == nil { lastWidget = SchoolDayWidgetStore.read() }
        if let last = lastWidget, last.days == file.days, last.connectionID == file.connectionID, last.namespace == file.namespace { return }
        if SchoolDayWidgetStore.write(file) {
            lastWidget = file
            WidgetCenter.shared.reloadTimelines(ofKind: SchoolDayWidgetStore.widgetKind)
        }
    }

    // MARK: Tokens (Schritt 2: to the push service)

    private func observeStartToken() {
        guard !startTokenObserved else { return }
        startTokenObserved = true
        guard #available(iOS 17.2, *) else { return }
        Task {
            for await data in Activity<SchoolDayAttributes>.pushToStartTokenUpdates {
                CalendarPushClient.shared.receivedLiveActivityStartToken(Self.hex(data))
            }
        }
    }

    private func observe(_ activity: Activity<SchoolDayAttributes>) {
        guard observed.insert(activity.id).inserted else { return }
        let id = activity.id, day = activity.attributes.day
        Task {
            for await data in activity.pushTokenUpdates {
                CalendarPushClient.shared.receivedLiveActivityToken(Self.hex(data), activity: id, day: day)
            }
        }
    }

    private static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

    // MARK: Segments (8-h restart)

    private var segments: [String: Int] {
        get { UserDefaults.standard.dictionary(forKey: Self.segmentsKey) as? [String: Int] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: Self.segmentsKey) }
    }

    private func remember(_ id: String, segment: Int) {
        var value = segments
        // Only live activities are kept (ended ones drop out).
        let alive = Set(Activity<SchoolDayAttributes>.activities.map(\.id))
        value = value.filter { alive.contains($0.key) }
        value[id] = segment
        segments = value
    }

    private func forget(_ id: String) {
        var value = segments
        value[id] = nil
        segments = value
        observed.remove(id)
        CalendarPushClient.shared.liveActivityEnded(id)
    }
}

/// Blatt „Benachrichtigungen“: „Schultag auf dem Sperrbildschirm“ (only in noty calendar).
struct CalendarSchoolDaySection: View {
    @ObservedObject var model: CalendarModel
    @ObservedObject private var center = CalendarSchoolDayCenter.shared
    @Environment(\.openURL) private var openURL

    var body: some View {
        if center.supported {
            Section {
                Toggle(isOn: Binding(get: { center.enabled }, set: { center.setEnabled($0, model: model) })) {
                    Label("Schultag auf dem Sperrbildschirm", systemImage: "rectangle.badge.checkmark")
                }
                .disabled(model.connection == nil)
                if !center.systemAllowed {
                    Label("Live-Aktivitäten sind in den iPad-Einstellungen für noty calendar ausgeschaltet.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Button("iPad-Einstellungen öffnen") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    }
                } else if center.enabled, let running = center.running {
                    Label("Läuft: \(running)", systemImage: "clock")
                }
                if let error = center.lastError {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
                Button { center.startDemo() } label: { Label("Test-Kachel starten", systemImage: "play.rectangle") }
                    .disabled(!center.systemAllowed)
                if center.demoRunning {
                    Button { center.demoChange() } label: { Label("Änderung simulieren", systemImage: "bell.badge") }
                    Button(role: .destructive) { center.endDemo() } label: { Label("Test-Kachel beenden", systemImage: "stop.circle") }
                }
            } footer: {
                Text("An Tagen mit Unterricht zeigt eine Kachel auf dem Sperrbildschirm ab 30 Minuten vor der ersten Stunde die aktuelle Stunde mit Raum und Restzeit, Pausen und Freistunden, den Tagesfortschritt und die nächste Stunde mit Ausfall, Vertretung oder Raumwechsel. Nach der letzten Stunde verschwindet sie. Eine Stundenplanänderung des Tages meldet die Kachel selbst und weckt den Bildschirm (dann ohne zweite Mitteilung), außer in den Ruhezeiten oder wenn „Stundenplanänderungen“ aus ist; schickt der Mitteilungsdienst die Änderungen, aktualisiert sich die Kachel still. Vorerst aktualisiert sich die Kachel nur, wenn noty calendar läuft oder im Hintergrund abrufen darf; dazwischen läuft der Countdown weiter und die Kachel zeigt beim nächsten Stundenwechsel „Stand veraltet“. Vor iPadOS 26 startet sie erst, wenn du noty calendar an dem Morgen öffnest.")
            }
        }
    }
}
