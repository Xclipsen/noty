import SwiftUI

// Kalender, „Bewegung und Animationen“ (docs/CALENDAR-PLAN.md), seit dem
// Emil-Feinschliff (08.11.2026) auf den gemeinsamen Tokens von
// `NotyMotion` (docs/DESIGN.md, „Bewegung: Regeln nach Häufigkeit“):
// Tastatur sofort, Taps kurz und ohne Überschwingen (`NotyMotion.palette`,
// `.panel`), Austritte schneller, Feder mit Überschwingen nur nach einer
// Geste mit Geschwindigkeitsübergabe (`settle`). „Bewegung reduzieren“:
// Layout sofort, Ein-/Ausblenden nur als `.opacity.animation(NotyMotion.fade)`.
// Only user-driven chrome animates; data values (saving, the note, the ink,
// a sync) never get an animation of their own.

enum CalendarMotion {
    /// Period change by tap or swipe (‹ ›, Heute, view switcher): the new
    /// period slides in from 16 pt (`slide`) or settles from a slight scale,
    /// critically damped in 0.24 s; its opacity starts at 0.6 and is full
    /// after 0.15 s. Keyboard changes and a change within `repeatWindow`
    /// of the previous one do not move at all.
    static let slide: CGFloat = 16
    static let zoomIn: CGFloat = 0.96
    static let zoomOut: CGFloat = 1.04
    static let navDuration: TimeInterval = 0.24
    static let navSpring = Spring(duration: 0.24, bounce: 0)
    static let navFade: TimeInterval = 0.15
    static let navStartOpacity: Double = 0.6
    /// A pinch commit grows out of the period's frame: a little longer.
    static let zoomDuration: TimeInterval = 0.28
    static let repeatWindow: TimeInterval = 0.3

    /// The event window opens critically damped; Reduce Motion: a fade.
    static func windowOpen(_ reduced: Bool) -> Animation {
        reduced ? NotyMotion.fade : .spring(duration: 0.3, bounce: 0)
    }
    /// Closing is faster than opening (0.12 s would be abrupt for a window
    /// of nearly the whole calendar).
    static func windowClose(_ reduced: Bool) -> Animation {
        reduced ? NotyMotion.fade : .easeOut(duration: 0.18)
    }

    /// Only after a gesture (pull, pinch, swipe, drop): returns from
    /// `current` to `target`, continuing the finger's `velocity` (points per
    /// second) with a small overshoot. Reduce Motion: at once.
    static func settle(_ reduced: Bool, from current: CGFloat, to target: CGFloat, velocity: CGFloat = 0) -> Animation? {
        guard !reduced else { return nil }
        let distance = target - current
        let relative = abs(distance) > 0.5 && velocity.isFinite ? min(12, max(-12, velocity / distance)) : 0
        return .interpolatingSpring(duration: 0.3, bounce: 0.15, initialVelocity: Double(relative))
    }
}

/// Where the event window grows from: cards and rows report their frame in
/// the calendar's coordinate space, a tap names the one it came from. A
/// plain reference (not observed): writing a frame never re-renders a view.
@MainActor final class CalendarOriginTracker {
    nonisolated static let space = "noty.calendar.root"
    /// Frame plus the reporting view instance: one entry can be on screen
    /// twice (moved card, spanning rows); a vanishing view only removes its own.
    private var frames: [String: (frame: CGRect, owner: UUID)] = [:]
    private var tapped: (id: String, key: String)?

    func report(_ key: String, _ frame: CGRect, owner: UUID) { frames[key] = (frame, owner) }
    func forget(_ key: String, owner: UUID) { if frames[key]?.owner == owner { frames[key] = nil } }
    func tap(_ id: String, key: String) { tapped = (id, key) }

    /// The frame of the view the entry `id` was opened from, if it is known.
    func origin(for id: String?) -> CGRect? {
        guard let id, let tapped, tapped.id == id else { return nil }
        return frames[tapped.key]?.frame
    }
}

/// A change of the entries the user made here (save, delete, undo, drop,
/// restore): only then do cards animate in and out. Data from WebUntis,
/// the system calendars or another device appears without motion. A plain
/// reference like `CalendarOriginTracker`; nothing about it is stored.
@MainActor final class CalendarLocalChange {
    private var at = Date.distantPast
    func mark() { at = Date() }
    /// The model commits asynchronously: a short window covers the write.
    var recent: Bool { Date().timeIntervalSince(at) < 2 }
}

/// Removal of a calendar card: it fades – with the faster exit timing only
/// after the user's own change, read when the card goes (not at its last
/// render, which may predate the mark); a sync or another device removes it
/// at once. The animation of the change itself comes from the day column.
struct CalendarCardRemoval: Transition {
    let change: CalendarLocalChange?
    let reduced: Bool

    func body(content: Content, phase: TransitionPhase) -> some View {
        let animation: Animation? = change?.recent == true ? (reduced ? NotyMotion.fade : NotyMotion.exit) : nil
        content
            .opacity(phase == .didDisappear ? 0 : 1)
            .transaction { transaction in
                if phase == .didDisappear { transaction.animation = animation }
            }
    }
}

/// Sideways swipe in progress (two fingers on the trackpad; the finger swipe
/// of the month gave way to its vertical pages): the content follows with a rubber band and hands over to the
/// period change once it triggers. Held, not observed, by the calendar:
/// a swipe frame re-renders only `CalendarSwipeShifted`.
@MainActor final class CalendarSwipeShift: ObservableObject {
    @Published private(set) var offset: CGFloat = 0
    /// The content follows at most this far (and less and less on the way).
    static let reach: CGFloat = 80

    /// Apple's rubber band: the further, the less the content follows.
    static func rubber(_ x: CGFloat) -> CGFloat {
        let c: CGFloat = 0.55
        return x * reach * c / (reach + c * abs(x))
    }
    /// Slope of `rubber` at `x` (finger speed → content speed).
    static func slope(_ x: CGFloat) -> CGFloat {
        let c: CGFloat = 0.55, d = reach + c * abs(x)
        return c * reach * reach / (d * d)
    }

    /// Follows the swipe; Reduce Motion: the content stays still.
    func follow(_ translation: CGFloat, reduced: Bool) {
        let value = reduced ? 0 : Self.rubber(translation)
        if abs(value - offset) > 0.25 { offset = value }
    }
    /// The period changes: the new content takes over from rest.
    func handOff() {
        guard offset != 0 else { return }
        NotyMotion.instant { offset = 0 }
    }
    /// Let go below the threshold: back with the finger's velocity.
    func settle(translation: CGFloat, velocity: CGFloat, reduced: Bool) {
        guard offset != 0 else { return }
        let speed = velocity * Self.slope(translation)
        if let animation = CalendarMotion.settle(reduced, from: offset, to: 0, velocity: speed) {
            withAnimation(animation) { offset = 0 }
        } else {
            NotyMotion.instant { offset = 0 }
        }
    }
}

/// The calendar content shifted by a sideways swipe.
struct CalendarSwipeShifted<Content: View>: View {
    @ObservedObject var shift: CalendarSwipeShift
    let content: Content

    init(shift: CalendarSwipeShift, @ViewBuilder content: () -> Content) {
        self.shift = shift
        self.content = content()
    }

    var body: some View {
        content.offset(x: shift.offset)
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
private struct CalendarLocalChangeKey: EnvironmentKey {
    static var defaultValue: CalendarLocalChange? { nil }
}
private struct CalendarSwipeKey: EnvironmentKey {
    static var defaultValue: CalendarSwipeShift? { nil }
}
/// „Heute“ was chosen (`count`) at `at`.
struct CalendarPulse: Equatable {
    var count = 0
    var at = Date.distantPast
}

private struct CalendarTodayPulseKey: EnvironmentKey {
    static let defaultValue = CalendarPulse()
}

extension EnvironmentValues {
    var calendarOrigin: CalendarOriginTracker? {
        get { self[CalendarOriginKey.self] }
        set { self[CalendarOriginKey.self] = newValue }
    }
    /// Marked by the views that change entries on the user's request.
    var calendarLocalChange: CalendarLocalChange? {
        get { self[CalendarLocalChangeKey.self] }
        set { self[CalendarLocalChangeKey.self] = newValue }
    }
    /// The sideways shift of the content (trackpad swipe).
    var calendarSwipe: CalendarSwipeShift? {
        get { self[CalendarSwipeKey.self] }
        set { self[CalendarSwipeKey.self] = newValue }
    }
    /// Bumped by tapping „Heute“: today's marker pulses once.
    var calendarTodayPulse: CalendarPulse {
        get { self[CalendarTodayPulseKey.self] }
        set { self[CalendarTodayPulseKey.self] = newValue }
    }
}

extension View {
    /// Reports this view's frame as a possible origin of the event window.
    func calendarOrigin(_ key: String) -> some View { modifier(CalendarOriginReporter(key: key)) }
    /// Today's marker: one short pulse when „Heute“ is tapped.
    func calendarTodayPulse(_ isToday: Bool) -> some View { modifier(CalendarTodayPulseEffect(active: isToday)) }
}

private struct CalendarOriginReporter: ViewModifier {
    let key: String
    @Environment(\.calendarOrigin) private var tracker
    @State private var owner = UUID()

    func body(content: Content) -> some View {
        if let tracker {
            content
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(CalendarOriginTracker.space)) } action: { tracker.report(key, $0, owner: owner) }
                .onDisappear { tracker.forget(key, owner: owner) }
        } else {
            content
        }
    }
}

/// 1 → 1.12 → 1, ease-out 0.12 s up and 0.18 s back: answers the tap
/// without bouncing. Only tapping „Heute“ pulses (⌘T jumps silently).
private struct CalendarTodayPulseEffect: ViewModifier {
    let active: Bool
    @Environment(\.calendarTodayPulse) private var pulse
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Local trigger: also pulses when „Heute“ jumped to another period and
    /// this marker just appeared (a phase animator does not run on appear).
    @State private var tick = 0

    func body(content: Content) -> some View {
        if active && !reduceMotion {
            content.phaseAnimator([1.0, 1.12, 1.0], trigger: tick) { view, scale in
                view.scaleEffect(scale)
            } animation: { scale in
                scale > 1 ? .easeOut(duration: 0.12) : .easeOut(duration: 0.18)
            }
            .onChange(of: pulse.count) { _, _ in tick += 1 }
            .onAppear {
                guard pulse.count > 0, Date().timeIntervalSince(pulse.at) < 0.6 else { return }
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(120))
                    tick += 1
                }
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
        // Never out of nothing: from the card at least 0.3, else from 0.95.
        let start: CGFloat = known ? min(1, max(0.3, (origin?.width ?? 0) / (container.width * 0.9))) : 0.95
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
