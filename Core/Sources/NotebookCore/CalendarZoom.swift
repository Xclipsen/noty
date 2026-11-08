import Foundation

// Semantic zoom between the calendar views (docs/CALENDAR-PLAN.md, „Zoom
// zwischen Ansichten (08.11.2026)“): pinch or ⌘+ / ⌘- moves one step along
// Jahr → Monat → Woche → Tag. Platform-independent: which view and which
// anchor follow, which period sits under the fingers, and when a pinch is
// strong enough. The views only report frames and play the motion.

public extension CalendarMode {
    /// The next finer view (Jahr → Monat → Woche → Tag); nil for Tag.
    var finer: CalendarMode? {
        switch self {
        case .year: .month
        case .month: .week
        case .week: .day
        case .day: nil
        }
    }

    /// The next coarser view (Tag → Woche → Monat → Jahr); nil for Jahr.
    var coarser: CalendarMode? {
        switch self {
        case .year: nil
        case .month: .year
        case .week: .month
        case .day: .week
        }
    }
}

public enum CalendarZoom {
    public enum Direction: Sendable, Equatable {
        /// Pinch apart, ⌘+: finer view.
        case zoomIn
        /// Pinch together, ⌘-: coarser view.
        case zoomOut
    }

    public struct Step: Sendable, Equatable {
        public let mode: CalendarMode
        public let anchor: Date
        public init(mode: CalendarMode, anchor: Date) {
            self.mode = mode
            self.anchor = anchor
        }
    }

    /// The view and anchor after one zoom step from `mode` at `anchor`.
    /// `target` is a day inside the finer period under the fingers (a month
    /// tile of the year, a week row of the month, a day column of the week);
    /// nil (keyboard, nothing hit) keeps the anchor's period. Zooming in keeps
    /// the anchor when it lies in the chosen period, else today if it lies
    /// there, else the period's first day. Zooming out keeps the anchor (its
    /// period is then highlighted in the coarser view, see `focus`).
    /// nil: nothing finer than Tag, nothing coarser than Jahr.
    public static func step(_ direction: Direction, from mode: CalendarMode, anchor: Date, target: Date?,
                            today: Date, calendar: Calendar) -> Step? {
        let anchorDay = calendar.startOfDay(for: anchor)
        switch direction {
        case .zoomOut:
            guard let coarser = mode.coarser else { return nil }
            return Step(mode: coarser, anchor: anchorDay)
        case .zoomIn:
            guard let finer = mode.finer else { return nil }
            guard let target else { return Step(mode: finer, anchor: anchorDay) }
            // Whole weeks: the chosen period does not depend on 5/7 shown days.
            let range = CalendarDates.range(finer, anchor: target, weekDays: 7, calendar: calendar)
            func inside(_ date: Date) -> Bool { date >= range.start && date < range.end }
            let todayDay = calendar.startOfDay(for: today)
            if inside(anchorDay) { return Step(mode: finer, anchor: anchorDay) }
            if inside(todayDay) { return Step(mode: finer, anchor: todayDay) }
            return Step(mode: finer, anchor: range.start)
        }
    }

    /// The period of `mode` at `anchor` as the coarser view lists it: the
    /// month tile in the year, the week row (its Monday) in the month, the
    /// day column in the week. Used to highlight where a zoom-out came from
    /// and to key the frames a pinch can hit.
    public static func focus(_ mode: CalendarMode, anchor: Date, calendar: Calendar) -> Date {
        switch mode {
        case .year: CalendarDates.startOfYear(anchor, calendar: calendar)
        case .month: CalendarDates.startOfMonth(anchor, calendar: calendar)
        case .week: CalendarDates.startOfWeek(anchor, calendar: calendar)
        case .day: calendar.startOfDay(for: anchor)
        }
    }

    /// A reported period frame (view coordinates, y downward).
    public struct Frame: Sendable, Equatable {
        public let start: Date
        public let minX, minY, maxX, maxY: Double
        public init(start: Date, minX: Double, minY: Double, maxX: Double, maxY: Double) {
            self.start = start
            self.minX = minX; self.minY = minY; self.maxX = maxX; self.maxY = maxY
        }
    }

    /// The period under the point: the frame containing it, else the nearest
    /// one (fingers between two tiles). `horizontalOnly`: day columns of the
    /// week, whose reported frame is only the column head – any height counts.
    /// Ties go to the earlier period, so the result never depends on order.
    public static func target(atX x: Double, y: Double, in frames: [Frame], horizontalOnly: Bool = false) -> Date? {
        func distance(_ frame: Frame) -> Double {
            let dx = max(frame.minX - x, 0, x - frame.maxX)
            let dy = horizontalOnly ? 0 : max(frame.minY - y, 0, y - frame.maxY)
            return (dx * dx + dy * dy).squareRoot()
        }
        return frames.min { a, b in
            let da = distance(a), db = distance(b)
            return da == db ? a.start < b.start : da < db
        }?.start
    }
}

/// Thresholds and feedback of the pinch (magnification = finger distance
/// now / at the start; > 1 apart, < 1 together).
public enum CalendarPinch {
    /// From here a release changes the view (one haptic tick when reached).
    public static let arm = 1.2
    /// From here the view changes at once, while the fingers still move.
    public static let decisive = 1.6
    /// The live scale stays a hint: at most ±10 %, rubber-banded.
    public static let maximumFeedback = 0.1

    /// The direction a pinch of `magnification` asks for once it is past
    /// `arm` (or `decisive`), else nil. Symmetric: 1.2 apart ⇔ 1/1.2 together.
    public static func direction(_ magnification: Double, decisive: Bool = false) -> CalendarZoom.Direction? {
        guard magnification.isFinite, magnification > 0 else { return nil }
        let limit = decisive ? Self.decisive : arm
        if magnification >= limit { return .zoomIn }
        if magnification <= 1 / limit { return .zoomOut }
        return nil
    }

    /// The scale of the current view while pinching: follows the fingers
    /// softly (log scale, so apart and together feel alike) and never more
    /// than ±`maximumFeedback`. `possible` false (nothing finer/coarser):
    /// only a third of it, like a rubber band at the end.
    public static func feedbackScale(_ magnification: Double, possible: Bool) -> Double {
        guard magnification.isFinite, magnification > 0 else { return 1 }
        let pull = log(magnification) / log(decisive)          // ±1 at the decisive point
        let eased = maximumFeedback * tanh(pull * 1.2)           // soft limit
        return 1 + (possible ? eased : eased / 3)
    }
}
