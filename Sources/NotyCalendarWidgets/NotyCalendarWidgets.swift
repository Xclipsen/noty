import WidgetKit
import SwiftUI
import ActivityKit
import NotebookCore
import NotyCalendarShared

// Widget extension of noty calendar (docs/LIVE-ACTIVITY-PLAN.md):
//  - Live Activity „Schultag“ on the lock screen (ActivityKit; started,
//    updated and ended by the app, later also by the push service),
//  - widget „Heute“ (home and lock screen) from the derived App-Group file.
// No images, no buttons; a tap opens the calendar at the lesson.

@main
struct NotyCalendarWidgetBundle: WidgetBundle {
    var body: some Widget {
        SchoolDayLiveActivity()
        SchoolDayTodayWidget()
    }
}

private let berlin = CalendarDates.german(timeZone: TimeZone(identifier: "Europe/Berlin") ?? .current)

/// A countdown range that is never reversed (ClosedRange traps otherwise).
private func range(_ start: Int, _ end: Int) -> ClosedRange<Date> {
    let a = SchoolDayText.date(start), b = SchoolDayText.date(max(start, end))
    return a...b
}

// MARK: Live Activity

struct SchoolDayLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: SchoolDayAttributes.self) { context in
            SchoolDayLockView(state: context.state, stale: context.isStale)
                .widgetURL(SchoolDayLink.url(connectionID: context.attributes.connectionID, day: context.attributes.day,
                                             entryID: (context.state.current ?? context.state.next)?.entryID))
        } dynamicIsland: { context in
            // Required by the API; iPad has no Dynamic Island.
            DynamicIsland {
                DynamicIslandExpandedRegion(.center) {
                    Text(SchoolDayHeadline.text(context.state)).font(.headline).lineLimit(1)
                }
            } compactLeading: {
                Text(SchoolDayText.progress(context.state)).font(.caption2)
            } compactTrailing: {
                Text(timerInterval: range(context.state.phaseStart, context.state.phaseEnd), countsDown: true)
                    .monospacedDigit().frame(maxWidth: 48)
            } minimal: {
                Text("\(context.state.number)").font(.caption2)
            }
        }
    }
}

enum SchoolDayHeadline {
    /// The first line without the countdown.
    static func text(_ state: SchoolDayContentState) -> String {
        switch state.phase {
        case .before: "Gleich: " + (state.next.map(SchoolDayText.line) ?? "Unterricht")
        case .lesson: state.current.map(SchoolDayText.line) ?? "Unterricht"
        case .pause: "Pause"
        case .free: "Freistunde bis \(SchoolDayText.clock(state.phaseEnd, calendar: berlin))"
        case .done: "Schultag vorbei"
        }
    }
}

/// „● Mathematik · R 112      noch 23:41“, day progress with „Stunde 3/6“,
/// „Danach: Deutsch · R 204  fällt aus“. At most about 120 pt high.
struct SchoolDayLockView: View {
    let state: SchoolDayContentState
    let stale: Bool

    private var dotColor: Color {
        if state.current?.changed == true { return .red }
        switch state.phase {
        case .lesson: return .green
        case .before: return .blue
        case .pause, .free: return .orange
        case .done: return .secondary
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Circle().fill(dotColor).frame(width: 9, height: 9).accessibilityHidden(true)
                Text(SchoolDayHeadline.text(state)).font(.headline).lineLimit(1)
                if let note = state.current?.note {
                    Text(note).font(.caption.weight(.semibold)).foregroundStyle(state.current?.changed == true ? .red : .secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if state.phase != .done {
                    HStack(spacing: 3) {
                        Text(state.phase == .before ? "in" : "noch").foregroundStyle(.secondary)
                        Text(timerInterval: range(state.phaseStart, state.phaseEnd), countsDown: true)
                            .monospacedDigit().multilineTextAlignment(.trailing).frame(minWidth: 44, alignment: .trailing)
                    }
                    .font(.subheadline.weight(.semibold))
                }
            }
            HStack(spacing: 8) {
                ProgressView(timerInterval: range(state.dayStart, state.dayEnd), countsDown: false) { EmptyView() } currentValueLabel: { EmptyView() }
                    .progressViewStyle(.linear)
                    .tint(.green)
                Text(SchoolDayText.progress(state)).font(.caption.weight(.semibold)).monospacedDigit().foregroundStyle(.secondary)
            }
            if stale {
                Label("Stand veraltet – noty calendar öffnen", systemImage: "exclamationmark.arrow.circlepath")
                    .font(.caption).foregroundStyle(.orange).lineLimit(1)
            } else if let next = state.next, state.phase != .before {
                NextLine(lesson: next)
            } else if state.phase == .before, let next = state.next {
                Text("Beginn \(SchoolDayText.clock(next.start, calendar: berlin)) · 1. Stunde von \(state.count)")
                    .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            } else if state.phase != .done {
                Text("Danach: Schluss").font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .dynamicTypeSize(...DynamicTypeSize.xLarge)
        .activitySystemActionForegroundColor(.primary)
    }
}

/// „Danach: Deutsch · R 204  fällt aus“ (change in red).
struct NextLine: View {
    let lesson: SchoolDayLesson
    var body: some View {
        HStack(spacing: 6) {
            Text("Danach:").foregroundStyle(.secondary)
            Text(SchoolDayText.line(lesson)).strikethrough(lesson.cancelled).lineLimit(1)
            if let note = lesson.note {
                Text(note).font(.caption.weight(.bold)).foregroundStyle(lesson.changed ? .red : .secondary).lineLimit(1)
            }
        }
        .font(.subheadline)
    }
}

// MARK: Widget „Heute“

struct SchoolDayTodayEntry: TimelineEntry {
    let date: Date
    let content: SchoolDayWidgetContent
    let file: SchoolDayWidgetFile?
}

struct SchoolDayTodayProvider: TimelineProvider {
    func placeholder(in context: Context) -> SchoolDayTodayEntry {
        let start = Int(Date().timeIntervalSince1970) - 600
        let lesson = SchoolDayLesson(title: "Mathematik", room: "R 112", start: start, end: start + 2700)
        let next = SchoolDayLesson(title: "Deutsch", room: "R 204", start: start + 2700, end: start + 5400)
        let state = SchoolDayContentState(phase: .lesson, phaseStart: start, phaseEnd: start + 2700, current: lesson, next: next,
                                          number: 3, count: 6, dayStart: start - 7200, dayEnd: start + 14_400)
        return SchoolDayTodayEntry(date: Date(), content: .today(state), file: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (SchoolDayTodayEntry) -> Void) {
        if context.isPreview { completion(placeholder(in: context)); return }
        let file = SchoolDayWidgetStore.read()
        completion(SchoolDayTodayEntry(date: Date(), content: .at(Date(), file: file, calendar: berlin), file: file))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SchoolDayTodayEntry>) -> Void) {
        let file = SchoolDayWidgetStore.read()
        let entries = SchoolDayWidgetContent.timeline(from: Date(), file: file, calendar: berlin).map { date in
            SchoolDayTodayEntry(date: date, content: .at(date, file: file, calendar: berlin), file: file)
        }
        completion(Timeline(entries: entries, policy: .atEnd))
    }
}

struct SchoolDayTodayWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: SchoolDayWidgetStore.widgetKind, provider: SchoolDayTodayProvider()) { entry in
            SchoolDayTodayView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Heute")
        .description("Aktuelle und nächste Stunde aus dem Stundenplan von noty calendar.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular])
    }
}

struct SchoolDayTodayView: View {
    let entry: SchoolDayTodayEntry
    @Environment(\.widgetFamily) private var family

    private var link: URL {
        var day: String?, entryID: String?
        if case .today(let state) = entry.content {
            day = CivilDate(entry.date, calendar: berlin).description
            entryID = (state.current ?? state.next)?.entryID
        }
        return SchoolDayLink.url(connectionID: entry.file?.connectionID, day: day, entryID: entryID)
    }

    var body: some View {
        Group {
            switch entry.content {
            case .notLoaded:
                message("Stundenplan nicht geladen", "noty calendar öffnen")
            case .noLessonsToday(let tomorrow):
                message("Heute kein Unterricht", tomorrow.map { "Morgen \(SchoolDayText.clock($0.start, calendar: berlin)): \($0.title)" })
            case .doneToday(let tomorrow):
                message("Schultag vorbei", tomorrow.map { "Morgen \(SchoolDayText.clock($0.start, calendar: berlin)): \($0.title)" })
            case .today(let state):
                today(state)
            }
        }
        .dynamicTypeSize(...DynamicTypeSize.xLarge)
        .widgetURL(link)
    }

    private func message(_ title: String, _ detail: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if family != .accessoryRectangular { Text("Heute").font(.caption.weight(.semibold)).foregroundStyle(.secondary) }
            Text(title).font(.headline).lineLimit(2)
            if let detail { Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
            if family != .accessoryRectangular { Spacer(minLength: 0) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func today(_ state: SchoolDayContentState) -> some View {
        switch family {
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 1) {
                Text(SchoolDayHeadline.text(state)).font(.headline).lineLimit(1)
                HStack(spacing: 3) {
                    Text(state.phase == .before ? "in" : "noch")
                    Text(timerInterval: range(state.phaseStart, state.phaseEnd), countsDown: true).monospacedDigit()
                    Text("· " + SchoolDayText.progress(state))
                }
                .font(.caption).lineLimit(1)
                if let next = state.next, state.phase != .before {
                    Text("Danach: " + next.title + (next.note.map { " – " + $0 } ?? "")).font(.caption).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        default:
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(SchoolDayText.progress(state)).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Spacer()
                    Text(timerInterval: range(state.phaseStart, state.phaseEnd), countsDown: true)
                        .font(.caption.weight(.semibold)).monospacedDigit().multilineTextAlignment(.trailing)
                }
                Text(SchoolDayHeadline.text(state)).font(.headline).lineLimit(family == .systemSmall ? 2 : 1)
                if let note = state.current?.note {
                    Text(note).font(.caption.weight(.bold)).foregroundStyle(state.current?.changed == true ? .red : .secondary)
                }
                ProgressView(timerInterval: range(state.dayStart, state.dayEnd), countsDown: false) { EmptyView() } currentValueLabel: { EmptyView() }
                    .tint(.green)
                Spacer(minLength: 0)
                if let next = state.next {
                    if family == .systemSmall {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Danach").font(.caption2).foregroundStyle(.secondary)
                            Text(next.title).font(.caption.weight(.semibold)).strikethrough(next.cancelled).lineLimit(1)
                            if let note = next.note { Text(note).font(.caption2.weight(.bold)).foregroundStyle(next.changed ? .red : .secondary) }
                        }
                    } else {
                        NextLine(lesson: next)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
