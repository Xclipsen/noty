import SwiftUI
import NotebookCore

/// Spacing scale of the calendar: 4 · 8 · 12 · 16 · 24.
enum CalendarSpace {
    static let xs: CGFloat = 4
    static let s: CGFloat = 8
    static let m: CGFloat = 12
    static let l: CGFloat = 16
    static let xl: CGFloat = 24
}

enum CalendarPalette {
    /// Subject colours: `CalendarSubjectColor` (by name). Blue stays reserved
    /// for selection and actions, red for today and the current time, green
    /// for own entries.
    static let personal = Color.green
    static let holidays = Color.gray
    /// Fallback of system calendars (EventKit) until their own colour is known.
    static let system = Color(red: 0.55, green: 0.6, blue: 0.95)
    static let selection = Color(uiColor: .systemBlue)
    static let today = Color(uiColor: .systemRed)
    /// Hairlines of grids and cells: quieter than the system separator.
    static let hairline = Color(uiColor: .separator).opacity(0.45)
    /// Hour labels, week numbers and other quiet captions.
    static let quiet = Color(uiColor: .tertiaryLabel)
    /// Event background: a faint tint of the subject colour, stronger when selected.
    static func tint(_ color: Color, selected: Bool = false, cancelled: Bool = false) -> Color {
        color.opacity(selected ? 0.32 : cancelled ? 0.07 : 0.18)
    }

    static func color(_ event: CalendarEntry) -> Color {
        if let name = event.colorName { return color(named: name) }
        switch event.source {
        case .personal: return personal
        case .holidays: return holidays
        case .system: return system
        case .timetable:
            let key = CalendarSubjectColor.key(subjectID: nil, name: event.subject ?? event.title)
            return color(named: CalendarSubjectColor.name(for: key, chosen: [:]))
        }
    }

    /// The named colours of `CalendarSubjectColor` (stored by name).
    static func color(named name: String) -> Color {
        switch name {
        case "orange": .orange
        case "purple": .purple
        case "teal": .teal
        case "pink": .pink
        case "yellow": .yellow
        case "brown": .brown
        case "cyan": .cyan
        case "olive": Color(red: 0.62, green: 0.68, blue: 0.2)
        case "indigo": .indigo
        case "mint": .mint
        case "gray": .gray
        case "green": personal
        default: .gray
        }
    }
}

/// A wait indicator that appears only after 300 ms – short waits do not
/// flash – and always says what is running.
struct CalendarDelayedProgress: View {
    let text: String
    var large = false
    @State private var shown = false

    var body: some View {
        ZStack {
            Color.clear.frame(width: 1, height: 1)
            if shown {
                Group {
                    if large {
                        VStack(spacing: CalendarSpace.m) {
                            ProgressView().controlSize(.large)
                            Text(text).font(.subheadline).foregroundStyle(.secondary)
                        }
                    } else {
                        HStack(spacing: CalendarSpace.s) {
                            ProgressView()
                            Text(text).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
                .accessibilityElement(children: .combine)
                .transition(.opacity.animation(NotyMotion.fade))
            }
        }
        .task {
            try? await Task.sleep(for: .milliseconds(300))
            if !Task.isCancelled { shown = true }
        }
    }
}
