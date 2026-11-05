import SwiftUI
import UIKit
import NotebookCore

// Moving the law window by its bar without moving the app window.
//
// Since iPadOS 26 an app window that is not full screen moves when its top
// ~30 pt are dragged. A floating or docked law window puts its bar exactly
// there, so one drag moved both. Three public measures, nothing private:
// 1. The bar is dragged by a UIKit pan (`LawPanRecognizer`, iOS 18+), a real
//    `UIGestureRecognizer` that failure relationships can name. Its delegate
//    makes recognizers outside the hosting controller (the window and the
//    system containers above it, where a window-level drag lives) and every
//    `UIWindowSceneDragInteraction` above the bar wait until the pan failed.
// 2. In a window (not full screen) the bar keeps the part of that top band
//    it would cover free: a glass strip carrying the app's own
//    `UIWindowSceneDragInteraction`, whose gesture also requires the pan to
//    fail. Grabbing the strip moves the app window, grabbing below it the
//    law window. UIKit offers no public switch for the system's own band.
// 3. Full screen nothing changes visibly.

/// One step of moving the law window by its bar, in workspace points.
struct LawMoveSample {
    var translation: CGSize
    var location: CGPoint
    /// Only on release: where a flick would carry the window.
    var predictedTranslation: CGSize?
    var predictedLocation: CGPoint?
}

/// What the workspace does while the bar is dragged.
struct LawMoveActions {
    var changed: (LawMoveSample) -> Void
    var ended: (LawMoveSample) -> Void
    /// Interrupted (another gesture, a call …): the window springs back.
    var cancelled: () -> Void
}

/// Ties the bar's pan to the app-window strip above it (one per law window).
@MainActor
final class LawWindowDragLink {
    weak var pan: UIGestureRecognizer? { didSet { wire() } }
    weak var windowDrag: UIWindowSceneDragInteraction? { didSet { wire() } }
    private var wired: (ObjectIdentifier, ObjectIdentifier)?

    private func wire() {
        guard let pan, let windowDrag else { return }
        let gesture = windowDrag.gestureForFailureRelationships
        let pair = (ObjectIdentifier(gesture), ObjectIdentifier(pan))
        guard wired.map({ $0 != pair }) ?? true else { return }
        gesture.require(toFail: pan)
        wired = pair
    }

    /// Recognizers that move the app window or otherwise sit above the app's
    /// own content: on the window or on a container above the hosting
    /// controller's view, or belonging to a `UIWindowSceneDragInteraction`
    /// on any view above the bar. SwiftUI's own gestures (inside the hosting
    /// view) are left alone; only touches starting on the bar are affected.
    static func movesAppWindow(_ other: UIGestureRecognizer, whileDragging pan: UIGestureRecognizer) -> Bool {
        guard let view = pan.view, let otherView = other.view, other !== pan else { return false }
        var ancestor: UIView? = view
        while let current = ancestor {
            for case let drag as UIWindowSceneDragInteraction in current.interactions
            where drag.gestureForFailureRelationships === other { return true }
            ancestor = current.superview
        }
        if otherView is UIWindow { return view.isDescendant(of: otherView) }
        var responder: UIResponder? = view
        while let current = responder, !(current is UIViewController) { responder = current.next }
        guard let root = (responder as? UIViewController)?.view else { return false }
        return otherView !== root && root.isDescendant(of: otherView)
    }
}

extension View {
    /// Drags the law window by this view (its bar), measured in the named
    /// workspace space. iOS 18+: UIKit pan with window-drag failure
    /// relationships; iOS 17: the SwiftUI drag as before.
    func lawWindowMove(space: String, link: LawWindowDragLink, actions: LawMoveActions) -> some View {
        modifier(LawWindowMove(space: space, link: link, actions: actions))
    }
}

private struct LawWindowMove: ViewModifier {
    let space: String
    let link: LawWindowDragLink
    let actions: LawMoveActions
    @GestureState private var active = false

    @ViewBuilder func body(content: Content) -> some View {
        // Build 107 used a UIKit pan here (`LawPanRecognizer`); on iPadOS 27 it
        // never moved the window. The SwiftUI drag works; the glass strip above
        // the bar (`AppWindowDragStrip`) keeps it out of the system's top band.
        do {
            content
                .gesture(DragGesture(minimumDistance: 6, coordinateSpace: .named(space))
                    .updating($active) { _, state, _ in state = true }
                    .onChanged { actions.changed(LawMoveSample(translation: $0.translation, location: $0.location)) }
                    .onEnded {
                        actions.ended(LawMoveSample(translation: $0.translation, location: $0.location,
                                                    predictedTranslation: $0.predictedEndTranslation, predictedLocation: $0.predictedEndLocation))
                    })
                // A cancelled gesture never reaches onEnded.
                .onChange(of: active) { _, active in if !active { actions.cancelled() } }
        }
    }
}

@available(iOS 18.0, *)
private struct LawPanRecognizer: UIGestureRecognizerRepresentable {
    let space: String
    let link: LawWindowDragLink
    let actions: LawMoveActions

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var actions: LawMoveActions?
        /// The system's and the app's window drags wait for the law window's pan.
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            LawWindowDragLink.movesAppWindow(otherGestureRecognizer, whileDragging: gestureRecognizer)
        }
    }

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.maximumNumberOfTouches = 1
        pan.delegate = context.coordinator
        context.coordinator.actions = actions
        link.pan = pan
        return pan
    }

    func updateUIGestureRecognizer(_ pan: UIPanGestureRecognizer, context: Context) {
        context.coordinator.actions = actions
        if link.pan !== pan { link.pan = pan }
    }

    func handleUIGestureRecognizerAction(_ pan: UIPanGestureRecognizer, context: Context) {
        guard let actions = context.coordinator.actions else { return }
        let converter = context.converter, workspace = NamedCoordinateSpace.named(space)
        let t = converter.translation(in: workspace) ?? .zero
        let location = converter.location(in: workspace)
        let translation = CGSize(width: t.x, height: t.y)
        switch pan.state {
        case .began, .changed:
            actions.changed(LawMoveSample(translation: translation, location: location))
        case .ended:
            let v = converter.velocity(in: workspace) ?? .zero
            let ahead = LawPanelLayout.predictedTranslation(PagePoint(x: t.x, y: t.y), velocity: PagePoint(x: v.x, y: v.y))
            actions.ended(LawMoveSample(translation: translation, location: location,
                                        predictedTranslation: CGSize(width: ahead.x, height: ahead.y),
                                        predictedLocation: CGPoint(x: location.x + ahead.x - t.x, y: location.y + ahead.y - t.y)))
        case .cancelled, .failed:
            actions.cancelled()
        default:
            break
        }
    }
}

/// The strip at the top of the law window's bar that moves the app window
/// (only in a window, see `LawPanelLayout.windowDragClearance`).
struct AppWindowDragStrip: UIViewRepresentable {
    let link: LawWindowDragLink

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        let drag = UIWindowSceneDragInteraction()
        view.addInteraction(drag)
        link.windowDrag = drag
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        if let drag = view.interactions.lazy.compactMap({ $0 as? UIWindowSceneDragInteraction }).first, link.windowDrag !== drag {
            link.windowDrag = drag
        }
    }
}

/// Reports the top of the view it backs in app-window points while the scene
/// is a window smaller than its screen, `nil` full screen. Never takes touches.
struct AppWindowPlacementReader: UIViewRepresentable {
    let onChange: (CGFloat?) -> Void

    func makeUIView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.onChange = onChange
        return view
    }

    func updateUIView(_ view: ReaderView, context: Context) {
        view.onChange = onChange
        view.report()
    }

    final class ReaderView: UIView {
        var onChange: ((CGFloat?) -> Void)?
        private var reported: CGFloat??

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            backgroundColor = .clear
            isAccessibilityElement = false
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            report()
            // A presentation may still be sliding the editor in; moving
            // without resizing lays nothing out, so look once more after it.
            guard window != nil else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.report() }
        }
        override func layoutSubviews() { super.layoutSubviews(); report() }

        func report() {
            guard let window else { return }
            var top: CGFloat?
            if let screen = window.windowScene?.screen {
                let own = window.bounds.size, full = screen.bounds.size
                if abs(own.width - full.width) > 0.5 || abs(own.height - full.height) > 0.5 {
                    top = convert(CGPoint.zero, to: window).y.rounded()
                }
            }
            if let reported, reported == top { return }
            reported = .some(top)
            // Never change SwiftUI state while it lays out.
            DispatchQueue.main.async { [weak self] in self?.onChange?(top) }
        }
    }
}
