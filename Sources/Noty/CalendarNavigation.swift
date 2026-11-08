import SwiftUI
import NotebookCore

/// What is shown: the view and the first day of the period.
struct CalendarNavKey: Equatable {
    let mode: CalendarMode
    let start: Date

    /// Day < Woche < Monat < Jahr (finer → coarser).
    var depth: Int {
        switch mode {
        case .day: 0
        case .week: 1
        case .month: 2
        case .year: 3
        }
    }
}

/// How the next period change moves. A plain reference (not observed): the
/// keyboard marks the period it opens as `instant`, every change records
/// its time, and the keyframes of the following change read both.
@MainActor final class CalendarNavMotion {
    /// The period a keyboard shortcut just opened: it appears without motion.
    var instantKey: CalendarNavKey?
    /// When the shown period last changed (a quick follow-up does not move).
    var changedAt = Date.distantPast

    /// Whether the change to `key`, being rendered now, moves at all.
    func moves(to key: CalendarNavKey) -> Bool {
        instantKey != key && Date().timeIntervalSince(changedAt) >= CalendarMotion.repeatWindow
    }
}

/// Start values of the period/view change; the keyframes run them to rest.
struct CalendarNavFrame {
    var offset: CGFloat = 0
    var scale: CGFloat = 1
    var opacity: Double = 1

    /// Never invisible or off-screen, whatever the animator holds (Build 133:
    /// after ‹ › the whole grid stayed blank – a non-finite value from the
    /// keyframes must never reach the view).
    var sanitized: CalendarNavFrame {
        CalendarNavFrame(
            offset: offset.isFinite ? min(max(offset, -CalendarMotion.slide), CalendarMotion.slide) : 0,
            scale: scale.isFinite ? min(max(scale, 0.4), 1.25) : 1,
            opacity: opacity.isFinite ? min(max(opacity, 0.2), 1) : 1)
    }

    /// `zoom`: a pinch – stronger, from the opened period (see `CalendarZoomMotion`).
    /// `moves` false (keyboard, quick follow-up): at rest at once.
    static func start(from old: CalendarNavKey?, to new: CalendarNavKey, reduced: Bool, moves: Bool = true,
                      zoom: CalendarZoomMotion? = nil) -> CalendarNavFrame {
        guard let old, old != new, moves else { return CalendarNavFrame() }
        if reduced { return CalendarNavFrame(offset: 0, scale: 1, opacity: CalendarMotion.navStartOpacity) }
        if let zoom, old.mode != new.mode { return CalendarNavFrame(offset: 0, scale: zoom.scale, opacity: 0.3) }
        if old.mode != new.mode {
            // Into a finer view the content grows toward you, out of it it settles back.
            return CalendarNavFrame(offset: 0, scale: new.depth < old.depth ? CalendarMotion.zoomIn : CalendarMotion.zoomOut,
                                    opacity: CalendarMotion.navStartOpacity)
        }
        return CalendarNavFrame(offset: new.start > old.start ? CalendarMotion.slide : -CalendarMotion.slide, scale: 1,
                                opacity: CalendarMotion.navStartOpacity)
    }
}
