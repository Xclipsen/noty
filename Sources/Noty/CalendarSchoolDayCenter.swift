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
///    that only while noty runs in the foreground), updated at changes, a
///    real timetable change with an alert outside the quiet hours, restarted
///    before the 8-h limit and ended right after the last lesson.
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

    private var lastLessons: [String: [SchoolDayLesson]] = [:]
    private var lastWidget: SchoolDayWidgetFile?
    private var tick: Task<Void, Never>?
    private var observed = Set<String>()
    private var startTokenObserved = false

    private init() {}

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
        Task { await self.apply(attributes: attributes, school: target?.school, settings: settings, calendar: calendar, now: now) }
    }

    private func apply(attributes: SchoolDayAttributes?, school: CalendarSchoolDay?, settings: CalendarNotificationSettings,
                       calendar: Calendar, now: Date) async {
        let time = Int(now.timeIntervalSince1970)
        let activities = Activity<SchoolDayAttributes>.activities.filter { activity in
            switch activity.activityState {
            case .ended, .dismissed: false
            default: true
            }
        }
        // Another day, another connection, switched off: gone at once.
        for activity in activities where activity.attributes != attributes {
            await Self.end(activity.id, nil)
            forget(activity.id)
        }
        guard let attributes, let school else { running = nil; scheduleTick(nil); return }
        let plan = school.plan
        let mine = activities.filter { $0.attributes == attributes }
        let segment = plan.restarts.filter { $0 <= time }.count

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
        let content = ActivityContent(state: state, staleDate: school.nextTransition(after: time).map { SchoolDayText.date($0 + 60) },
                                      relevanceScore: 100)
        let change = changeText(old: lastLessons[attributes.day], new: school.visible, calendar: calendar)
        var current: Activity<SchoolDayAttributes>?
        for activity in mine {
            // Restart before the 8-h limit: the old one goes, a new one follows below.
            if (segments[activity.id] ?? 0) < segment || current != nil {
                await Self.end(activity.id, ActivityContent(state: state, staleDate: nil))
                forget(activity.id)
            } else {
                current = activity
            }
        }
        if let current {
            if current.content.state != state || change != nil {
                let alert = change.flatMap { text in
                    settings.isQuiet(now, calendar: calendar) ? nil
                        : AlertConfiguration(title: "Stundenplanänderung", body: LocalizedStringResource(stringLiteral: text), sound: .default)
                }
                await Self.update(current.id, content, alert: alert)
            }
        } else {
            do {
                let activity = try Activity.request(attributes: attributes, content: content, pushType: .token)
                remember(activity.id, segment: segment)
                observe(activity)
                lastError = nil
            } catch {
                // Typically: noty is not in the foreground (iPadOS starts activities only then) or they are switched off.
                lastError = "Kachel nicht gestartet: \(error.localizedDescription)"
            }
        }
        lastLessons = [attributes.day: school.visible]
        running = SchoolDayHeadlineText.text(state, calendar: calendar)
        scheduleTick(school.nextTransition(after: time))
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

    /// While noty runs, the next phase change updates the tile on time.
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

    /// A real change of the day's lessons (not a phase change): text of the
    /// first changed lesson, nil when nothing changed or nothing is known yet.
    private func changeText(old: [SchoolDayLesson]?, new: [SchoolDayLesson], calendar: Calendar) -> String? {
        guard let old else { return nil }
        func key(_ lesson: SchoolDayLesson) -> String {
            "\(lesson.start)|\(lesson.end)|\(lesson.title)|\(lesson.room ?? "")|\(lesson.note ?? "")|\(lesson.cancelled)"
        }
        let before = Set(old.map(key))
        guard let lesson = new.first(where: { !before.contains(key($0)) }) ?? (Set(new.map(key)) == before ? nil : new.first) else { return nil }
        return "\(SchoolDayText.clock(lesson.start, calendar: calendar)) \(SchoolDayText.line(lesson))" + (lesson.note.map { ": \($0)" } ?? "")
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

/// The sheet's „Läuft: …“ line (the extension has its own copy of the headline).
enum SchoolDayHeadlineText {
    static func text(_ state: SchoolDayContentState, calendar: Calendar) -> String {
        switch state.phase {
        case .before: "Gleich: " + (state.next.map(SchoolDayText.line) ?? "Unterricht")
        case .lesson: (state.current.map(SchoolDayText.line) ?? "Unterricht") + " · " + SchoolDayText.progress(state)
        case .pause: "Pause bis \(SchoolDayText.clock(state.phaseEnd, calendar: calendar))"
        case .free: "Freistunde bis \(SchoolDayText.clock(state.phaseEnd, calendar: calendar))"
        case .done: "Schultag vorbei"
        }
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
                if center.enabled, let error = center.lastError {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
            } footer: {
                Text("An Tagen mit Unterricht zeigt eine Kachel auf dem Sperrbildschirm ab 30 Minuten vor der ersten Stunde die aktuelle Stunde mit Raum und Restzeit, Pausen und Freistunden, den Tagesfortschritt und die nächste Stunde mit Ausfall, Vertretung oder Raumwechsel. Nach der letzten Stunde verschwindet sie. Eine Änderung weckt den Bildschirm, außer in den Ruhezeiten. Vorerst aktualisiert sich die Kachel nur, wenn noty calendar läuft oder im Hintergrund abrufen darf; dazwischen läuft der Countdown weiter und die Kachel zeigt beim nächsten Stundenwechsel „Stand veraltet“. Vor iPadOS 26 startet sie erst, wenn du noty calendar an dem Morgen öffnest.")
            }
        }
    }
}
