import SwiftUI
import UIKit
import NotebookCore

// Kalender, „Termin per Halten und Ziehen anlegen (08.11.2026)“
// (docs/CALENDAR-PLAN.md): hold on free space of the hour grid, the all-day
// row or a month cell, then drag – a placeholder shows the span, letting go
// opens the event form pre-filled. The rastering and normalisation are
// `CalendarCreation` in NotebookCore; this file holds the recognizer, the
// placeholder's state and its views.
//
// SwiftUI's `LongPressGesture` reports no position when it fires, and
// inside a scroll view the position of a resting finger changes while the
// grid scrolls by itself. So a `UILongPressGestureRecognizer` (0.35 s like
// moving an own event, 10 pt) sits on the hosting view – like
// `CalendarTrackpadSwipe` – and only takes touches inside an invisible
// marker that `canBegin` declares free (cards and chips stay theirs). The
// marker takes no touches itself: SwiftUI's hit testing, taps, scrolling and
// the pinch are unchanged. Finger, Pencil and pointer (click and hold, then
// drag) fire it; once it has begun the grid does not scroll (the views set
// `scrollDisabled`), and with `autoScroll` the enclosing vertical scroll view
// moves while the finger rests near its top or bottom edge.

struct CalendarHoldDrag: UIViewRepresentable {
    enum Phase { case began, changed, ended, cancelled }

    /// Off: a press does nothing (no write access, samples, window or form open).
    let enabled: Bool
    /// Whether a press at this point (marker coordinates) may create: free space only.
    let canBegin: (CGPoint) -> Bool
    /// Scroll the enclosing vertical scroll view near its top/bottom edge.
    var autoScroll = false
    /// A pinch started meanwhile: the creation ends without a result.
    let interrupted: () -> Bool
    /// Every phase with the finger in marker coordinates (`.cancelled`: `.zero`).
    let update: (Phase, CGPoint) -> Void

    func makeUIView(context: Context) -> MarkerView {
        let view = MarkerView()
        apply(view)
        return view
    }

    func updateUIView(_ view: MarkerView, context: Context) { apply(view) }

    static func dismantleUIView(_ view: MarkerView, coordinator: ()) { view.detach() }

    private func apply(_ view: MarkerView) {
        view.enabled = enabled
        view.canBegin = canBegin
        view.autoScroll = autoScroll
        view.interrupted = interrupted
        view.update = update
        if !enabled { view.cancel() }
    }

    final class MarkerView: UIView, UIGestureRecognizerDelegate {
        var enabled = false
        var canBegin: (CGPoint) -> Bool = { _ in false }
        var autoScroll = false
        var interrupted: () -> Bool = { false }
        var update: (Phase, CGPoint) -> Void = { _, _ in }

        private lazy var press: UILongPressGestureRecognizer = {
            let press = UILongPressGestureRecognizer(target: self, action: #selector(pressed(_:)))
            press.minimumPressDuration = 0.35
            press.allowableMovement = 10
            press.numberOfTouchesRequired = 1
            // Finger, Pencil and the pointer's click (UIApplicationSupportsIndirectInputEvents).
            press.allowedTouchTypes = [UITouch.TouchType.direct, .pencil, .indirectPointer].map { NSNumber(value: $0.rawValue) }
            press.delegate = self
            return press
        }()
        private weak var host: UIView?
        private weak var scroller: UIScrollView?
        private var link: CADisplayLink?
        private var lastTick: CFTimeInterval = 0
        /// A creation is running (between `.began` and its end).
        private var running = false

        /// Auto-scroll: the edge zone and the speed at its outer end (points per second).
        static let edge: CGFloat = 64
        static let maximumSpeed: CGFloat = 420

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            backgroundColor = .clear
            isAccessibilityElement = false
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil { detach() } else { attach() }
        }

        /// The nearest view controller's root view above the marker (the
        /// calendar's hosting view) gets the recognizer; the nearest scroll
        /// view above it is the one that scrolls by itself.
        private func attach() {
            var candidate = superview
            while let view = candidate, !(view.next is UIViewController) { candidate = view.superview }
            var up = superview
            while let view = up, !(view is UIScrollView) { up = view.superview }
            scroller = up as? UIScrollView
            guard let target = candidate ?? superview, target !== host else { return }
            detach()
            target.addGestureRecognizer(press)
            host = target
        }

        func detach() {
            if running {
                finish()
                // Called during a SwiftUI update (dismantle): report afterwards.
                let update = update
                DispatchQueue.main.async { update(.cancelled, .zero) }
            }
            host?.removeGestureRecognizer(press)
            host = nil
        }

        /// Ends a running creation (disabled meanwhile). Called from
        /// `updateUIView`: the callback changes published state, so it
        /// happens after the update.
        func cancel() {
            guard press.state == .began || press.state == .changed else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.press.state == .began || self.press.state == .changed else { return }
                self.press.isEnabled = false
                self.press.isEnabled = true
            }
        }

        // MARK: Gesture

        @objc private func pressed(_ press: UILongPressGestureRecognizer) {
            switch press.state {
            case .began:
                guard enabled, !interrupted() else { stop(); return }
                running = true
                update(.began, press.location(in: self))
                startScrolling()
            case .changed:
                guard running else { return }
                // A second finger or a pinch: no event from this.
                if press.numberOfTouches > 1 || interrupted() || !enabled { abort(); return }
                update(.changed, press.location(in: self))
            case .ended:
                guard running else { return }
                let point = press.location(in: self)
                finish()
                update(.ended, point)
            case .cancelled, .failed:
                guard running else { return }
                finish()
                update(.cancelled, .zero)
            default:
                break
            }
        }

        private func finish() {
            running = false
            link?.invalidate()
            link = nil
        }

        /// Ends the creation now; the recognizer's own `.cancelled` that
        /// follows finds nothing running.
        private func abort() {
            finish()
            update(.cancelled, .zero)
            stop()
        }

        private func stop() {
            press.isEnabled = false
            press.isEnabled = true
        }

        /// Only touches inside the marker on free space; a further finger
        /// of a running press is taken so the press fails (two fingers = pinch).
        func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard recognizer === press else { return true }
            guard enabled, window != nil, !isHidden else { return false }
            if press.numberOfTouches > 0 { return true }
            let point = touch.location(in: self)
            return bounds.contains(point) && visible(touch) && canBegin(point)
        }

        /// The marker reaches beyond what is on screen (the scrolled-away
        /// hours above and below, columns hidden in a narrow week): a touch
        /// on the header, the all-day row or the sidebar can map into its
        /// bounds. Every scroll view between marker and host must show the
        /// touch's point too (its bounds are the visible part of its content).
        private func visible(_ touch: UITouch) -> Bool {
            var view = superview
            while let current = view, current !== host {
                if let scroll = current as? UIScrollView, !scroll.bounds.contains(touch.location(in: scroll)) { return false }
                view = current.superview
            }
            return true
        }

        override func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard recognizer === press else { return super.gestureRecognizerShouldBegin(recognizer) }
            return enabled && press.numberOfTouches == 1 && !interrupted()
        }

        // MARK: Auto-scroll

        private func startScrolling() {
            guard autoScroll, scroller != nil, link == nil else { return }
            let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
            link.add(to: .main, forMode: .common)
            self.link = link
            lastTick = 0
        }

        /// Near the top or bottom edge the grid scrolls (faster the closer
        /// the finger is to the edge); the span follows the resting finger.
        @objc private func tick(_ link: CADisplayLink) {
            guard running, let scroll = scroller else { return }
            let now = link.timestamp
            let elapsed = lastTick == 0 ? 0 : min(0.05, now - lastTick)
            lastTick = now
            let height = scroll.bounds.height
            guard height > 1, elapsed > 0 else { return }
            let y = press.location(in: scroll).y - scroll.bounds.minY
            let zone = min(Self.edge, height / 4)
            var speed: CGFloat = 0
            if y < zone {
                let depth = min(1, (zone - y) / zone)
                speed = -Self.maximumSpeed * depth * depth
            } else if y > height - zone {
                let depth = min(1, (y - (height - zone)) / zone)
                speed = Self.maximumSpeed * depth * depth
            }
            guard speed != 0 else { return }
            let top = -scroll.adjustedContentInset.top
            let bottom = max(top, scroll.contentSize.height - height + scroll.adjustedContentInset.bottom)
            let next = min(bottom, max(top, scroll.contentOffset.y + speed * CGFloat(elapsed)))
            guard abs(next - scroll.contentOffset.y) > 0.01 else { return }
            scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: next), animated: false)
            update(.changed, press.location(in: self))
        }
    }
}

/// The placeholder of a creation in progress. Its own small object, held
/// (not observed) by the grid, the all-day row and the month: a finger step
/// re-renders only the placeholder. It stays behind the form it opened
/// (`draftID`) until that closes; „Abbrechen“ leaves no trace.
@MainActor final class CalendarCreateState: ObservableObject {
    /// Hour grid: the span over the shown days.
    @Published private(set) var span: CalendarCreation.Span?
    /// All-day row and month: inclusive day indices.
    @Published private(set) var range: ClosedRange<Int>?
    /// Where the press was (cell or day index) and the current day column.
    var anchorCell: CalendarCreation.Cell?
    var anchorIndex: Int?
    var column: Int?
    /// The form this placeholder opened.
    var draftID: UUID?
    /// Month: which page the creation belongs to.
    var page: Date?

    var active: Bool { span != nil || range != nil }

    /// Appears with 0.95 → 1 and opacity in 0.18 s ease-out (Reduce Motion:
    /// opacity only, `NotyMotion.fade`); every raster step after that is instant.
    func show(span: CalendarCreation.Span, reduced: Bool) {
        guard span != self.span else { return }
        if self.span == nil {
            withAnimation(reduced ? NotyMotion.fade : .easeOut(duration: 0.18)) { self.span = span }
        } else {
            NotyMotion.instant { self.span = span }
        }
    }

    func show(range: ClosedRange<Int>, reduced: Bool) {
        guard range != self.range else { return }
        if self.range == nil {
            withAnimation(reduced ? NotyMotion.fade : .easeOut(duration: 0.18)) { self.range = range }
        } else {
            NotyMotion.instant { self.range = range }
        }
    }

    /// Gone: quickly (`NotyMotion.exit`) after the user's own end, at once
    /// when the shown days changed beneath it.
    func clear(animated: Bool) {
        anchorCell = nil; anchorIndex = nil; column = nil; draftID = nil; page = nil
        guard active else { return }
        if animated {
            withAnimation(NotyMotion.exit) { span = nil; range = nil }
        } else {
            NotyMotion.instant { span = nil; range = nil }
        }
    }

    /// The form closed (saved or cancelled) or another one replaced it.
    func formChanged(to id: UUID?) {
        guard let draftID, draftID != id else { return }
        clear(animated: true)
    }
}

/// Appearance of every placeholder: the selection blue, a little stronger
/// than a selected card, with a thin outline; nothing for VoiceOver (the
/// „+“ button is its way to a new event).
private struct CalendarCreateBlock: View {
    var title: String?
    var detail: String?
    var radius: CGFloat = 6
    /// Month cells keep their entries readable beneath a fainter fill.
    var fill: Double = 0.28

    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(CalendarPalette.selection.opacity(fill))
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(CalendarPalette.selection, lineWidth: 1.5)
            }
            .overlay(alignment: .topLeading) {
                if title != nil || detail != nil {
                    VStack(alignment: .leading, spacing: 1) {
                        if let title { Text(title).font(.caption.weight(.semibold)) }
                        if let detail { Text(detail).font(.caption2.weight(.semibold)).monospacedDigit() }
                    }
                    .lineLimit(1).minimumScaleFactor(0.8)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6).padding(.vertical, 3)
                }
            }
    }
}

extension AnyTransition {
    /// Placeholder in and out: scale 0.95 around the placeholder itself
    /// (`anchor`: its centre in the container) with opacity; Reduce Motion: opacity.
    static func calendarCreate(reduced: Bool, anchor: UnitPoint) -> AnyTransition {
        reduced ? .opacity : .scale(scale: 0.95, anchor: anchor).combined(with: .opacity)
    }
}

/// The centre of `rect` as a unit point of a container of `size`.
private func unitCenter(_ rect: CGRect, in size: CGSize) -> UnitPoint {
    guard size.width > 1, size.height > 1 else { return .center }
    return UnitPoint(x: min(1, max(0, rect.midX / size.width)), y: min(1, max(0, rect.midY / size.height)))
}

/// Hour grid: one block per touched day column (a span over several days
/// is drawn like a multi-day event, day by day); the text in the first.
/// The blocks sit in a container of the grid's size, so the entrance scales
/// around the first block, not around a corner of the grid.
struct CalendarCreateTimedPlaceholder: View {
    @ObservedObject var state: CalendarCreateState
    let days: [Date]
    let calendar: Calendar
    let gutter: CGFloat
    let column: CGFloat
    let hourHeight: CGFloat
    let topInset: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduced

    private func y(_ minutes: Int) -> CGFloat { topInset + CGFloat(minutes) / 60 * hourHeight }

    private func rect(_ day: Int, _ segment: (start: Int, end: Int)) -> CGRect {
        CGRect(x: gutter + CGFloat(day) * column + 4, y: y(segment.start) + 1.5,
               width: max(20, column - 8), height: max(22, CGFloat(segment.end - segment.start) / 60 * hourHeight - 3))
    }

    var body: some View {
        let size = CGSize(width: gutter + column * CGFloat(days.count), height: y(24 * 60) + topInset)
        ZStack(alignment: .topLeading) {
            if let span = state.span, let dates = CalendarCreation.dates(span, days: days, calendar: calendar),
               let first = span.segment(on: span.startDay) {
                let text = CalendarCreation.label(start: dates.start, end: dates.end, calendar: calendar)
                ZStack(alignment: .topLeading) {
                    ForEach(Array(span.startDay...span.endDay), id: \.self) { day in
                        if let segment = span.segment(on: day) {
                            let frame = rect(day, segment)
                            let lead = day == span.startDay
                            CalendarCreateBlock(title: lead && frame.height >= 40 ? "Neuer Termin" : nil, detail: lead ? text : nil)
                                .frame(width: frame.width, height: frame.height)
                                .offset(x: frame.minX, y: frame.minY)
                        }
                    }
                }
                .frame(width: size.width, height: size.height, alignment: .topLeading)
                .transition(.calendarCreate(reduced: reduced, anchor: unitCenter(rect(span.startDay, first), in: size)))
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// All-day row of week and day: the covered day columns, full row height.
struct CalendarCreateAllDayPlaceholder: View {
    @ObservedObject var state: CalendarCreateState
    let gutter: CGFloat
    let column: CGFloat
    let days: Int
    let height: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduced

    var body: some View {
        let size = CGSize(width: gutter + column * CGFloat(days), height: height)
        ZStack(alignment: .topLeading) {
            if let range = state.range {
                let frame = CGRect(x: gutter + CGFloat(range.lowerBound) * column + 2, y: 3,
                                   width: max(20, CGFloat(range.count) * column - 4), height: max(18, height - 6))
                CalendarCreateBlock(detail: CalendarCreation.allDayLabel(days: range.count), radius: 5)
                    .frame(width: frame.width, height: frame.height)
                    .offset(x: frame.minX, y: frame.minY)
                    .frame(width: size.width, height: size.height, alignment: .topLeading)
                    .transition(.calendarCreate(reduced: reduced, anchor: unitCenter(frame, in: size)))
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Month page: the covered days highlighted, row by row like a text selection.
struct CalendarCreateMonthPlaceholder: View {
    @ObservedObject var state: CalendarCreateState
    let page: Date
    let left: CGFloat
    let column: CGFloat
    /// Row pitch (row plus its hairline) and the number of rows.
    let row: CGFloat
    let rows: Int
    @Environment(\.accessibilityReduceMotion) private var reduced

    private func rect(line: Int, from: Int, to: Int) -> CGRect {
        CGRect(x: left + CGFloat(from) * column + 2, y: CGFloat(line) * row + 2,
               width: max(20, CGFloat(to - from + 1) * column - 4), height: max(20, row - 4))
    }

    var body: some View {
        let size = CGSize(width: left + 7 * column, height: CGFloat(rows) * row)
        ZStack(alignment: .topLeading) {
            if state.page == page, let range = state.range {
                let firstRow = range.lowerBound / 7, lastRow = range.upperBound / 7
                ZStack(alignment: .topLeading) {
                    ForEach(Array(firstRow...lastRow), id: \.self) { line in
                        let frame = rect(line: line, from: line == firstRow ? range.lowerBound % 7 : 0,
                                         to: line == lastRow ? range.upperBound % 7 : 6)
                        CalendarCreateBlock(radius: 6, fill: 0.16)
                            .frame(width: frame.width, height: frame.height)
                            .offset(x: frame.minX, y: frame.minY)
                    }
                }
                .frame(width: size.width, height: size.height, alignment: .topLeading)
                .transition(.calendarCreate(reduced: reduced, anchor: unitCenter(
                    rect(line: firstRow, from: range.lowerBound % 7, to: range.lowerBound % 7), in: size)))
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
