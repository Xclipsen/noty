import SwiftUI
import UIKit

// Kalender, Trackpad-Wischen (08.11.2026): two fingers sideways on the
// trackpad (indirect pointer, continuous scroll events) turn to the previous
// or next period like ‹ ›, in every view. Natural direction: fingers to the
// left = the content moves left = the next period. One period per gesture.
//
// SwiftUI has no gesture for scroll events, so a `UIPanGestureRecognizer`
// that takes no touches at all (`allowedTouchTypes = []`) and only
// continuous scrolling (`allowedScrollTypesMask = .continuous`; a mouse
// wheel is discrete and stays out) sits on the hosting view of the calendar
// – an ancestor of the grid's scroll views, so it sees the events they see.
// Fingers, the Pencil, the long press on cards, the month swipe and the
// pinch never reach it; vertical trackpad scrolling of the hour grid starts
// vertical and is declined at once.

/// Invisible marker behind the calendar content: its frame is the area
/// that reacts; the recognizer itself goes to the enclosing hosting view.
struct CalendarTrackpadSwipe: UIViewRepresentable {
    /// Off while anything is presented over the grid (the event window with
    /// its note would otherwise page the calendar behind it).
    let enabled: Bool
    let reduced: Bool
    let shift: CalendarSwipeShift
    /// −1: previous period, +1: next.
    let step: (Int) -> Void

    func makeUIView(context: Context) -> MarkerView {
        let view = MarkerView()
        update(view)
        return view
    }

    func updateUIView(_ view: MarkerView, context: Context) { update(view) }

    static func dismantleUIView(_ view: MarkerView, coordinator: ()) { view.detach() }

    private func update(_ view: MarkerView) {
        view.enabled = enabled
        view.reduced = reduced
        view.shift = shift
        view.step = step
        if !enabled { view.cancel() }
    }

    final class MarkerView: UIView, UIGestureRecognizerDelegate {
        var enabled = true
        var reduced = false
        var shift: CalendarSwipeShift?
        var step: ((Int) -> Void)?
        private lazy var pan: UIPanGestureRecognizer = {
            let pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
            pan.allowedTouchTypes = []
            pan.allowedScrollTypesMask = .continuous
            pan.cancelsTouchesInView = false
            pan.delaysTouchesBegan = false
            pan.delaysTouchesEnded = false
            pan.delegate = self
            return pan
        }()
        private weak var host: UIView?
        /// The gesture already turned a period: the rest of it does nothing.
        private var fired = false

        /// Translation that turns the period, and how clearly sideways it must be.
        static let threshold: CGFloat = 96
        static let dominance: CGFloat = 1.5

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

        /// The nearest view controller's root view above the marker: the
        /// calendar's hosting view (not the window – sheets and the library
        /// sidebar have their own and stay out).
        private func attach() {
            var candidate = superview
            while let view = candidate, !(view.next is UIViewController) { candidate = view.superview }
            guard let target = candidate ?? superview, target !== host else { return }
            detach()
            target.addGestureRecognizer(pan)
            host = target
        }

        func detach() {
            cancel()
            host?.removeGestureRecognizer(pan)
            host = nil
        }

        /// Ends a running swipe (disabled while the window opened, removed).
        func cancel() {
            guard pan.state == .began || pan.state == .changed else { return }
            pan.isEnabled = false
            pan.isEnabled = true
        }

        // MARK: Gesture

        @objc private func panned(_ pan: UIPanGestureRecognizer) {
            let translation = pan.translation(in: host)
            switch pan.state {
            case .began:
                fired = false
            case .changed:
                guard !fired else { return }
                let sideways = abs(translation.x) > Self.dominance * abs(translation.y)
                if sideways && abs(translation.x) >= Self.threshold {
                    fired = true
                    shift?.handOff()
                    // Natural scrolling: fingers (and content) to the left = next period.
                    step?(translation.x < 0 ? 1 : -1)
                } else {
                    shift?.follow(translation.x, reduced: reduced)
                }
            case .ended, .cancelled, .failed:
                if !fired {
                    shift?.settle(translation: translation.x, velocity: pan.velocity(in: host).x, reduced: reduced)
                }
                fired = false
            default:
                break
            }
        }

        /// Only over the calendar content, only while nothing covers it, and
        /// only when the scroll starts sideways (vertical scrolling of the
        /// hour grid or the year declines it at once).
        override func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard recognizer === pan else { return super.gestureRecognizerShouldBegin(recognizer) }
            guard enabled, window != nil, !isHidden else { return false }
            guard bounds.contains(pan.location(in: self)) else { return false }
            let velocity = pan.velocity(in: host)
            let translation = pan.translation(in: host)
            let x = abs(velocity.x) + abs(translation.x), y = abs(velocity.y) + abs(translation.y)
            return x > Self.dominance * y
        }

        /// Beside the vertical scroll views (they decline sideways scrolls themselves).
        func gestureRecognizer(_ recognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            !Self.scrollsSideways(other)
        }

        /// A view that scrolls sideways itself (narrow week columns) keeps the
        /// sideways scroll: the swipe waits for it and so never turns there.
        func gestureRecognizer(_ recognizer: UIGestureRecognizer,
                               shouldRequireFailureOf other: UIGestureRecognizer) -> Bool {
            Self.scrollsSideways(other)
        }

        private static func scrollsSideways(_ recognizer: UIGestureRecognizer) -> Bool {
            guard let scroll = recognizer.view as? UIScrollView, recognizer === scroll.panGestureRecognizer else { return false }
            return scroll.isScrollEnabled && scroll.contentSize.width > scroll.bounds.width + 1
        }
    }
}
