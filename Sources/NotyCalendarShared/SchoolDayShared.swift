import Foundation
import ActivityKit
import NotebookCore

// Live Activity „Schultag“ and widget „Heute“ (docs/LIVE-ACTIVITY-PLAN.md):
// what app and widget extension must agree on. ActivityKit finds an activity's
// UI by the attributes type, so both binaries use this one conformance; the
// data types and the logic are in NotebookCore (`CalendarSchoolDay.swift`).

/// `attributes-type` of push-to-start is the type name: „SchoolDayAttributes“.
extension SchoolDayAttributes: @retroactive ActivityAttributes {
    public typealias ContentState = SchoolDayContentState
}

/// Deep link of the tile and the widget:
/// `<schema>://schultag?connection=<UUID>&day=YYYY-MM-DD&entry=<Eintrags-ID>`.
/// One scheme per app (`noty` for the normal noty, `notycalendar` for noty
/// calendar; registered by publish_ota.sh): two apps with the same scheme
/// would make iPadOS pick one of them at random.
public enum SchoolDayLink {
    /// Apps that embed the widget extension, allow the tile and get push.
    public static let calendarChannels: Set<String> = ["stable", "calendar"]
    public static func scheme(channel: String) -> String { channel == "stable" ? "noty" : "noty" + channel }
    public static var scheme: String { scheme(channel: SchoolDayWidgetStore.channel) }
    public static let host = "schultag"

    public struct Target: Equatable, Sendable {
        public var connectionID: String?
        public var day: CivilDate?
        public var entryID: String?
    }

    public static func url(connectionID: String?, day: String?, entryID: String?) -> URL {
        var parts = URLComponents()
        parts.scheme = scheme
        parts.host = host
        var items: [URLQueryItem] = []
        if let connectionID { items.append(URLQueryItem(name: "connection", value: connectionID)) }
        if let day { items.append(URLQueryItem(name: "day", value: day)) }
        if let entryID { items.append(URLQueryItem(name: "entry", value: entryID)) }
        parts.queryItems = items.isEmpty ? nil : items
        return parts.url ?? URL(string: "\(scheme)://\(host)")!
    }

    /// Nil for every other URL (files, backups keep their way).
    public static func target(_ url: URL) -> Target? {
        guard url.scheme?.lowercased() == scheme, url.host?.lowercased() == host,
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        func value(_ name: String) -> String? {
            parts.queryItems?.first { $0.name == name }?.value.flatMap { $0.isEmpty || $0.count > 300 ? nil : $0 }
        }
        return Target(connectionID: value("connection"), day: value("day").flatMap(CivilDate.init), entryID: value("entry"))
    }
}

/// The derived widget file in the App Group (`SchoolDayWidgetFile`):
/// `<Gruppe>/NotyWidgets/<Kanal>/schoolday.json`. One per app (the group is
/// shared by noty, noty dev, noty AI and noty calendar), written by the app
/// of the shown area, read by its widget.
public enum SchoolDayWidgetStore {
    public static let groupName = "de.la.noty.shared"
    /// `kind` of the widget „Heute“ (WidgetCenter.reloadTimelines).
    public static let widgetKind = "NotyCalendarToday"

    /// Info.plist `NotyChannel` (app and extension carry it).
    public static var channel: String {
        let value = Bundle.main.object(forInfoDictionaryKey: "NotyChannel") as? String ?? "stable"
        return value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) } && !value.isEmpty ? value : "stable"
    }

    public static var fileURL: URL? {
        let bundleID = Bundle.main.bundleIdentifier
        guard let root = ProvisionedIdentifier.groupCandidates(groupName, bundleID: bundleID).lazy
            .compactMap({ FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0) }).first else { return nil }
        return root.appendingPathComponent("NotyWidgets", isDirectory: true)
            .appendingPathComponent(channel, isDirectory: true)
            .appendingPathComponent("schoolday.json")
    }

    public static func read() -> SchoolDayWidgetFile? {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return nil }
        return SchoolDayWidgetFile.decode(data)
    }

    /// Replaces the file atomically; nil removes it. True when something changed.
    @discardableResult
    public static func write(_ file: SchoolDayWidgetFile?) -> Bool {
        guard let url = fileURL else { return false }
        guard let file else {
            guard FileManager.default.fileExists(atPath: url.path) else { return false }
            try? FileManager.default.removeItem(at: url)
            return true
        }
        guard let data = try? file.encoded() else { return false }
        if let old = try? Data(contentsOf: url), old == data { return false }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            return true
        } catch { return false }
    }
}

/// German texts shared by tile and widget.
public enum SchoolDayText {
    /// Calendar of a school day in the extension: `SchoolDayAttributes.day`
    /// is a civil day in the zone of the WebUntis connection, which is
    /// created with `CalendarDefaults.timeZone` (Europe/Berlin). The widget
    /// file names no zone of its own (its format stays as it is), so the
    /// extension reads it in that one.
    public static let calendar = CalendarDates.german(timeZone: CalendarDefaults.timeZone)

    /// „08:05“ for Unix seconds (Core's 24-hour clock).
    public static func clock(_ seconds: Int, calendar: Calendar = SchoolDayText.calendar) -> String {
        CalendarText.clock(date(seconds), calendar: calendar)
    }

    /// „Mathematik · R 112“.
    public static func line(_ lesson: SchoolDayLesson) -> String {
        [lesson.title, lesson.room].compactMap { $0 }.joined(separator: " · ")
    }

    /// „Stunde 3/6“.
    public static func progress(_ state: SchoolDayContentState) -> String { "Stunde \(state.number)/\(state.count)" }

    /// The first line of tile and widget, without the countdown. `detailed`
    /// (the app's line „Läuft: …“, which has no countdown) adds „Stunde 3/6“
    /// to a lesson and the end of a pause.
    public static func headline(_ state: SchoolDayContentState, calendar: Calendar = SchoolDayText.calendar,
                                detailed: Bool = false) -> String {
        switch state.phase {
        case .before: "Gleich: " + (state.next.map(line) ?? "Unterricht")
        case .lesson: (state.current.map(line) ?? "Unterricht") + (detailed ? " · " + progress(state) : "")
        case .pause: detailed ? "Pause bis \(clock(state.phaseEnd, calendar: calendar))" : "Pause"
        case .free: "Freistunde bis \(clock(state.phaseEnd, calendar: calendar))"
        case .done: "Schultag vorbei"
        }
    }

    public static func date(_ seconds: Int) -> Date { Date(timeIntervalSince1970: TimeInterval(seconds)) }
}
