import SwiftUI
import NotebookCore

// Kalender, „Zoom zwischen Ansichten (08.11.2026)“ (docs/CALENDAR-PLAN.md):
// pinch apart = finer view (Jahr → Monat → Woche → Tag), together = coarser.
// The period under the fingers decides where a zoom-in lands; a zoom-out
// briefly highlights where it came from. The logic (which view, which
// anchor, thresholds) is `CalendarZoom`/`CalendarPinch` in NotebookCore;
// this file only collects frames, scales live and highlights.

/// Frames of the periods a pinch can open (month tiles of the year, week
/// rows of the month, day heads of the week), in the content's coordinate
/// space. A plain reference like `CalendarOriginTracker`: reporting a frame
/// never re-renders a view.
@MainActor final class CalendarZoomTracker {
    nonisolated static let space = "noty.calendar.zoom"
    /// `kind`: the view the frame opens (`.month` for a year tile, …).
    private struct Key: Hashable {
        let kind: CalendarMode
        let start: Date
    }
    private var frames: [Key: (frame: CGRect, owner: UUID)] = [:]
    private var pinchAt = Date.distantPast

    func report(_ kind: CalendarMode, _ start: Date, _ frame: CGRect, owner: UUID) {
        frames[Key(kind: kind, start: start)] = (frame, owner)
    }
    func forget(_ kind: CalendarMode, _ start: Date, owner: UUID) {
        let key = Key(kind: kind, start: start)
        if frames[key]?.owner == owner { frames[key] = nil }
    }
    func frame(_ kind: CalendarMode, _ start: Date) -> CGRect? { frames[Key(kind: kind, start: start)]?.frame }

    /// The period of `kind` under `point` (or the nearest one).
    func target(_ kind: CalendarMode, at point: CGPoint) -> Date? {
        let list = frames.compactMap { key, value -> CalendarZoom.Frame? in
            guard key.kind == kind else { return nil }
            let f = value.frame
            return CalendarZoom.Frame(start: key.start, minX: f.minX, minY: f.minY, maxX: f.maxX, maxY: f.maxY)
        }
        // Day columns report only their head: any height below counts.
        return CalendarZoom.target(atX: point.x, y: point.y, in: list, horizontalOnly: kind == .day)
    }

    /// A pinch is running or just ended: taps and holding to create that
    /// were part of it do nothing.
    func markPinch() { pinchAt = Date() }
    var recentPinch: Bool { Date().timeIntervalSince(pinchAt) < 0.45 }
}

/// The live pinch. Its own small object (held, not observed by the calendar):
/// while the fingers move only `CalendarPinchScaled` re-renders, not the grid.
@MainActor final class CalendarPinchState: ObservableObject {
    @Published var scale: CGFloat = 1
    @Published var anchor: UnitPoint = .center
    /// Past the threshold in a direction that has a next view (haptic tick).
    @Published var armed: CalendarZoom.Direction?
    /// Bumped per view change by pinch (haptic).
    @Published var commits = 0
    var active = false
    /// One view change per pinch, even if the fingers keep going.
    var committed = false
    var start: CGPoint = .zero
    var size: CGSize = .zero
}

/// The content, scaled softly along the pinch. Once a release would change
/// the view, a blue outline says so (the tick alone is felt nowhere: iPads
/// have no haptics). „Bewegung reduzieren“: no scaling, only the outline.
struct CalendarPinchScaled<Content: View>: View {
    @ObservedObject var pinch: CalendarPinchState
    let reduced: Bool
    let content: Content

    init(pinch: CalendarPinchState, reduced: Bool, @ViewBuilder content: () -> Content) {
        self.pinch = pinch
        self.reduced = reduced
        self.content = content()
    }

    var body: some View {
        content
            .scaleEffect(reduced ? 1 : pinch.scale, anchor: pinch.anchor)
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(CalendarPalette.selection.opacity(0.8), lineWidth: 2)
                    .padding(4)
                    .opacity(pinch.armed != nil ? 1 : 0)
                    .animation(NotyMotion.fade, value: pinch.armed != nil)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .sensoryFeedback(trigger: pinch.armed) { _, new in new != nil ? .selection : nil }
            .sensoryFeedback(.impact(weight: .light), trigger: pinch.commits)
    }
}

/// How the next view zooms in: from `anchor` (the period's centre or the
/// fingers), starting at `scale`. Only for the change from `from` to `key`.
struct CalendarZoomMotion: Equatable {
    let from: CalendarNavKey
    let key: CalendarNavKey
    let anchor: UnitPoint
    let scale: CGFloat
}

/// After zooming out: the period that was shown (`kind` at `start`) lights
/// up once in the coarser view.
struct CalendarZoomFocus: Equatable {
    var count = 0
    var kind = CalendarMode.day
    var start = Date.distantPast
    var at = Date.distantPast
}

private struct CalendarZoomKey: EnvironmentKey {
    static var defaultValue: CalendarZoomTracker? { nil }
}
private struct CalendarZoomFocusKey: EnvironmentKey {
    static let defaultValue = CalendarZoomFocus()
}

extension EnvironmentValues {
    var calendarZoom: CalendarZoomTracker? {
        get { self[CalendarZoomKey.self] }
        set { self[CalendarZoomKey.self] = newValue }
    }
    var calendarZoomFocus: CalendarZoomFocus {
        get { self[CalendarZoomFocusKey.self] }
        set { self[CalendarZoomFocusKey.self] = newValue }
    }
}

extension View {
    /// This view is the period `start` that a pinch opens as `kind`; it lights
    /// up once when a zoom-out came from there. `enabled` false: neither.
    func calendarZoomTarget(_ kind: CalendarMode, start: Date, cornerRadius: CGFloat = 10, enabled: Bool = true) -> some View {
        modifier(CalendarZoomTargetEffect(kind: kind, start: start, radius: cornerRadius, enabled: enabled))
    }
}

/// The last frame of a zoom target (not observed: written on every scroll frame).
private final class CalendarZoomFrameBox {
    var frame: CGRect?
}

private struct CalendarZoomTargetEffect: ViewModifier {
    let kind: CalendarMode
    let start: Date
    let radius: CGFloat
    let enabled: Bool
    @Environment(\.calendarZoom) private var tracker
    @Environment(\.calendarZoomFocus) private var focus
    @State private var owner = UUID()
    @State private var lit = false
    @State private var box = CalendarZoomFrameBox()

    /// One structure whether enabled or not: switching `enabled` (the month's
    /// shown page changes while scrolling) never rebuilds the row it wraps;
    /// it only starts or stops reporting the frame and the highlight.
    func body(content: Content) -> some View {
        content
            .overlay {
                // Opacity only: also the form with „Bewegung reduzieren“.
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(CalendarPalette.selection.opacity(0.12))
                    .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(CalendarPalette.selection, lineWidth: 2))
                    .opacity(lit && enabled ? 1 : 0)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(CalendarZoomTracker.space)) } action: { frame in
                box.frame = frame
                if enabled { tracker?.report(kind, start, frame, owner: owner) }
            }
            .onChange(of: enabled) { _, on in
                guard let tracker else { return }
                if on, let frame = box.frame { tracker.report(kind, start, frame, owner: owner) }
                if !on { tracker.forget(kind, start, owner: owner) }
            }
            .onDisappear { tracker?.forget(kind, start, owner: owner) }
            .onAppear { flash() }
            .onChange(of: focus.count) { _, _ in flash() }
    }

    /// Lights up for half a second, then fades in 0.2 s (opacity only).
    private func flash() {
        guard enabled, tracker != nil, focus.count > 0, focus.kind == kind, focus.start == start, Date().timeIntervalSince(focus.at) < 0.8 else { return }
        withAnimation(NotyMotion.fade) { lit = true }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            withAnimation(.easeOut(duration: 0.2)) { lit = false }
        }
    }
}
