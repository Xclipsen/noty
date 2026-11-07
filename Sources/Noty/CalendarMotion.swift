import SwiftUI

// Kalender, „Bewegung und Animationen“ (docs/CALENDAR-PLAN.md): one small
// motion vocabulary for the whole calendar. Every curve has a reduced form:
// with „Bewegung reduzieren“ nothing moves or scales – it only cross-fades
// briefly. Only user-driven chrome animates; data values (saving, the note,
// the ink) never get an animation of their own.

enum CalendarMotion {
    /// Taps, toggles, snapping to the grid: quick, no overshoot.
    static func snappy(_ reduced: Bool) -> Animation {
        reduced ? fade : .spring(response: 0.28, dampingFraction: 0.9)
    }
    /// Navigation, panels, lists: calm and soft.
    static func smooth(_ reduced: Bool) -> Animation {
        reduced ? fade : .spring(response: 0.42, dampingFraction: 1.0)
    }
    /// The event window and the „Heute“ pulse: a little life, small overshoot.
    static func bouncy(_ reduced: Bool) -> Animation {
        reduced ? fade : .spring(response: 0.4, dampingFraction: 0.8)
    }
    /// The only motion with „Bewegung reduzieren“.
    static let fade = Animation.easeInOut(duration: 0.16)

    /// Slide distance of the period change and the start scale of the zoom.
    static let slide: CGFloat = 36
    static let zoomIn: CGFloat = 0.94
    static let zoomOut: CGFloat = 1.05
}

/// Where the event window grows from: cards and rows report their frame in
/// the calendar's coordinate space, a tap names the one it came from. A
/// plain reference (not observed): writing a frame never re-renders a view.
@MainActor final class CalendarOriginTracker {
    nonisolated static let space = "noty.calendar.root"
    private var frames: [String: CGRect] = [:]
    private var tapped: (id: String, key: String)?

    func report(_ key: String, _ frame: CGRect) { frames[key] = frame }
    func forget(_ key: String) { frames[key] = nil }
    func tap(_ id: String, key: String) { tapped = (id, key) }

    /// The frame of the view the entry `id` was opened from, if it is known.
    func origin(for id: String?) -> CGRect? {
        guard let id, let tapped, tapped.id == id else { return nil }
        return frames[tapped.key]
    }
}

/// Pull-down of the event window's head. Its own small object: while the
/// finger moves only the backdrop and the window re-render, not the grid.
final class CalendarWindowPull: ObservableObject {
    @Published var value: CGFloat = 0
}

/// The dimmed calendar behind the window; lighter while the head is pulled.
struct CalendarWindowBackdrop: View {
    @ObservedObject var pull: CalendarWindowPull

    var body: some View {
        Color.black.opacity(0.45 * (1 - min(0.7, max(0, pull.value) / 420)))
    }
}

private struct CalendarOriginKey: EnvironmentKey {
    static var defaultValue: CalendarOriginTracker? { nil }
}
private struct CalendarTodayPulseKey: EnvironmentKey {
    static let defaultValue = 0
}

extension EnvironmentValues {
    var calendarOrigin: CalendarOriginTracker? {
        get { self[CalendarOriginKey.self] }
        set { self[CalendarOriginKey.self] = newValue }
    }
    /// Bumped by „Heute“: today's marker pulses once.
    var calendarTodayPulse: Int {
        get { self[CalendarTodayPulseKey.self] }
        set { self[CalendarTodayPulseKey.self] = newValue }
    }
}

extension View {
    /// Reports this view's frame as a possible origin of the event window.
    func calendarOrigin(_ key: String) -> some View { modifier(CalendarOriginReporter(key: key)) }
    /// Today's marker: one short pulse when „Heute“ is chosen.
    func calendarTodayPulse(_ isToday: Bool) -> some View { modifier(CalendarTodayPulseEffect(active: isToday)) }
}

private struct CalendarOriginReporter: ViewModifier {
    let key: String
    @Environment(\.calendarOrigin) private var tracker

    func body(content: Content) -> some View {
        if let tracker {
            content
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(CalendarOriginTracker.space)) } action: { tracker.report(key, $0) }
                .onDisappear { tracker.forget(key) }
        } else {
            content
        }
    }
}

private struct CalendarTodayPulseEffect: ViewModifier {
    let active: Bool
    @Environment(\.calendarTodayPulse) private var pulse
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if active && !reduceMotion {
            content.phaseAnimator([1.0, 1.28, 1.0], trigger: pulse) { view, scale in
                view.scaleEffect(scale)
            } animation: { scale in
                scale > 1 ? .spring(response: 0.22, dampingFraction: 0.6) : .spring(response: 0.34, dampingFraction: 0.7)
            }
        } else {
            content
        }
    }
}

/// The event window grows out of the tapped card and shrinks back into it:
/// a uniform scale toward the card's centre plus a fade (no distortion of
/// the page inside). Without a known card: a small scale from the centre.
struct CalendarGrowEffect: ViewModifier {
    /// 0 = at the card (or slightly scaled), 1 = the full window.
    let progress: CGFloat
    let origin: CGRect?
    let container: CGSize

    /// One code path for every case: the window's subtree (with the note
    /// editor) never changes structure because of this effect.
    func body(content: Content) -> some View {
        let center = CGPoint(x: container.width / 2, y: container.height / 2)
        let known = origin.map { $0.width > 1 && container.width > 1 } ?? false
        let start: CGFloat = known ? min(1, max(0.12, (origin?.width ?? 0) / (container.width * 0.9))) : 0.92
        let dx = known ? ((origin?.midX ?? center.x) - center.x) : 0
        let dy = known ? ((origin?.midY ?? center.y) - center.y) : 0
        content
            .scaleEffect(start + (1 - start) * progress)
            .offset(x: dx * (1 - progress), y: dy * (1 - progress))
            .opacity(Double(known ? min(1, 0.2 + progress * 1.4) : progress))
    }
}

extension AnyTransition {
    static func calendarGrow(from origin: CGRect?, in container: CGSize, reduced: Bool) -> AnyTransition {
        reduced ? .opacity
            : .modifier(active: CalendarGrowEffect(progress: 0, origin: origin, container: container),
                        identity: CalendarGrowEffect(progress: 1, origin: origin, container: container))
    }
}
