import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass

// Chrome over the pages never lets a touch start on the page below it.
//
// Feedback 06.11.2026: a Pencil stroke that started just beside a bar button,
// in the gap between two buttons, or just below the law window's grip drew
// on the page underneath. SwiftUI hands a touch to the hosted notebook
// (`NotebookEditor`, a UIKit view) wherever no SwiftUI view claims the point:
// gaps and padding of a glass bar (the glass itself is not hit-testable on
// every system), decorations with `allowsHitTesting(false)`, the corners of
// rounded shapes, and anything a few points beside the surface. PencilKit and
// the sheet's own recognizers then start ink, eraser, lasso or a shape.
//
// The fix does not depend on how SwiftUI hit-tests: every chrome surface
// registers a small UIView (`pencilGuard(margin:)`, or the UIKit bar itself),
// and only the recognizers that start ink refuse a touch whose start lies in
// a registered frame grown by its margin: PencilKit's drawing recognizer and
// the ruler stroke wait for `PencilGuardGate`, the hold observer (held
// shapes, eraser sweeps) and the lasso/new-shape pan of `ObjectEditingLayer`
// ask `WorksheetView.inkGuarded` directly. Decided in
// `gestureRecognizer(_:shouldReceive:)`, where UIKit hands over the real
// `UITouch` (type and first location); hit-testing knows neither reliably.
// Pencil always, a finger only while it draws. Text views, text fields,
// checkboxes, object/selection drags, handles and finger selection keep
// every touch; finger scrolling and pinching start there as before. Checked
// once per touch-down against the few registered views, never per stroke
// point; a stroke that started on the page and moves under a bar goes on.

/// Registry of chrome views over the pages, in any window of the scene.
@MainActor
final class PencilGuard {
    static let shared = PencilGuard()
    /// Off in the safe mode after interrupted launches (LaunchGuard): no
    /// gate is installed and nothing counts as covered, so ink always starts.
    static var enabled: Bool { !LaunchGuard.safeMode }

    private final class Entry {
        weak var view: UIView?
        var margin: CGFloat
        /// Chrome inside a notebook viewport (selection bar): guards only
        /// pages of that viewport.
        var local: Bool
        init(view: UIView, margin: CGFloat, local: Bool) { self.view = view; self.margin = margin; self.local = local }
    }
    private var entries: [Entry] = []

    /// `margin`: near-miss zone around the view in points (no ink starts there).
    func register(_ view: UIView, margin: CGFloat, local: Bool = false) {
        entries.removeAll { $0.view == nil }
        if let entry = entries.first(where: { $0.view === view }) { entry.margin = margin; entry.local = local; return }
        entries.append(Entry(view: view, margin: margin, local: local))
    }
    func unregister(_ view: UIView) {
        entries.removeAll { $0.view == nil || $0.view === view }
    }

    /// Whether a touch starting at `point` (in `view`) lies on or beside chrome
    /// that is shown in front of `view`. Chrome that is hidden, transparent,
    /// non-interactive (an ancestor), clipped away by an ancestor, of a
    /// presentation behind `view` (the editor under a sheet) or empty does
    /// not count.
    func covers(_ point: CGPoint, in view: UIView) -> Bool {
        guard Self.enabled, !entries.isEmpty, let window = view.window else { return false }
        let location = view.convert(point, to: window)
        let root = Self.root(of: view, in: window)
        let rootIndex = root.flatMap { window.subviews.firstIndex(of: $0) }
        var viewport: UIView?? = nil
        for entry in entries {
            guard let chrome = entry.view, let chromeWindow = chrome.window, !chromeWindow.isHidden,
                  chrome.bounds.width > 0, chrome.bounds.height > 0,
                  let (chromeRoot, visible) = Self.visibleFrame(of: chrome, margin: entry.margin, in: chromeWindow, interactive: entry.local) else { continue }
            var frame = visible
            if entry.local {
                if viewport == nil { viewport = .some(Self.viewport(of: view)) }
                guard let own = viewport ?? nil, chrome.isDescendant(of: own) else { continue }
            }
            if chromeWindow === window {
                if chromeRoot !== root, let rootIndex, let index = window.subviews.firstIndex(of: chromeRoot), index < rootIndex { continue }
            } else {
                // Keyboard window (format bar above the keyboard).
                frame = chromeWindow.convert(frame, to: window)
            }
            if frame.contains(location) { return true }
        }
        return false
    }

    private static func root(of view: UIView, in window: UIWindow) -> UIView? {
        var current = view
        while let parent = current.superview {
            if parent === window { return current }
            current = parent
        }
        return nil
    }
    private static func viewport(of view: UIView) -> UIView? {
        var current: UIView? = view
        while let next = current {
            if next is NotebookViewport { return next }
            current = next.superview
        }
        return nil
    }
    /// The window's child holding `view` and the guarded frame (margin
    /// included) in window coordinates, cut to every clipping ancestor and
    /// the window; nil while `view` or an ancestor is hidden or fully
    /// transparent, nothing is left, or (`interactive`, UIKit chrome) an
    /// ancestor takes no touches. SwiftUI probes skip that last test: their
    /// own hosts may be non-interactive; hidden SwiftUI chrome turns its
    /// probe off instead (`pencilGuardEnabled`).
    private static func visibleFrame(of view: UIView, margin: CGFloat, in window: UIWindow, interactive: Bool) -> (UIView, CGRect)? {
        var frame = view.convert(view.bounds, to: window).insetBy(dx: -margin, dy: -margin)
        var current = view
        while true {
            if current.isHidden || current.alpha < 0.01 { return nil }
            // A UIKit bar and its ancestors take touches while shown.
            if interactive, !current.isUserInteractionEnabled { return nil }
            guard let parent = current.superview else { return nil }
            if parent === window {
                frame = frame.intersection(window.bounds)
                return frame.isNull || frame.isEmpty ? nil : (current, frame)
            }
            if parent.clipsToBounds {
                frame = frame.intersection(parent.convert(parent.bounds, to: window))
                if frame.isNull || frame.isEmpty { return nil }
            }
            current = parent
        }
    }
}

/// Passive gate the ink recognizers wait for (`require(toFail:)`): it
/// receives only touches `blocks` refuses and then recognizes at once, so
/// the waiting recognizers fail; it never prevents, delays or cancels any
/// other recognizer. Touches it does not receive never hold anything up
/// (same pattern as the checkbox tap).
@MainActor
final class PencilGuardGate: UIGestureRecognizer, UIGestureRecognizerDelegate {
    var blocks: ((UITouch) -> Bool)?
    private var tracked = Set<UITouch>()
    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        delegate = self
        cancelsTouchesInView = false; delaysTouchesBegan = false; delaysTouchesEnded = false
    }
    /// Fail-safe: with the guard off, without a decision or outside a
    /// window the gate takes no touch, so the ink recognizers never wait.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard PencilGuard.enabled, isEnabled, view?.window != nil, let blocks else { return false }
        return blocks(touch)
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        // Touches whose end UIKit never delivered do not keep the gate going.
        tracked = tracked.filter { $0.phase != .ended && $0.phase != .cancelled }
        tracked.formUnion(touches)
        if state == .possible { state = .began }
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        if state == .began || state == .changed { state = .changed }
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        tracked.subtract(touches)
        guard tracked.isEmpty else { return }
        // Only from a recognised state; `.possible` → `.failed` releases the waiting recognizers.
        state = state == .began || state == .changed ? .ended : .failed
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        tracked.subtract(touches)
        guard tracked.isEmpty else { return }
        state = state == .began || state == .changed ? .cancelled : .failed
    }
    override func reset() { tracked.removeAll(); super.reset() }
    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }
}

/// A plain UIKit chrome view (format bar root) that guards while it is in a
/// window and unregisters when it leaves.
final class PencilGuardedView: UIView {
    var guardMargin: CGFloat = 2
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { PencilGuard.shared.register(self, margin: guardMargin) } else { PencilGuard.shared.unregister(self) }
    }
}

private struct PencilGuardEnabledKey: EnvironmentKey { static let defaultValue = true }
extension EnvironmentValues {
    /// False for chrome that is laid out but not shown (hidden second view).
    var pencilGuardEnabled: Bool {
        get { self[PencilGuardEnabledKey.self] }
        set { self[PencilGuardEnabledKey.self] = newValue }
    }
}

extension View {
    /// This surface (its full frame, gaps and padding included) plus `margin`
    /// points around it keeps touches from starting on the pages below.
    func pencilGuard(margin: CGFloat = 10, active: Bool = true) -> some View {
        modifier(PencilGuardModifier(margin: margin, active: active))
    }
}

private struct PencilGuardModifier: ViewModifier {
    let margin: CGFloat
    let active: Bool
    @Environment(\.pencilGuardEnabled) private var enabled
    func body(content: Content) -> some View {
        content.background {
            PencilGuardProbe(margin: margin, active: active && enabled)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

/// An empty, non-interactive UIView in the surface's frame: UIKit gives its
/// exact window position at touch-down (offsets, transforms, animations).
private struct PencilGuardProbe: UIViewRepresentable {
    let margin: CGFloat
    let active: Bool
    func makeUIView(context: Context) -> PencilGuardProbeView { PencilGuardProbeView() }
    func updateUIView(_ view: PencilGuardProbeView, context: Context) {
        view.margin = margin; view.active = active
    }
}

private final class PencilGuardProbeView: UIView {
    var margin: CGFloat = 10 { didSet { if oldValue != margin { sync() } } }
    var active = true { didSet { if oldValue != active { sync() } } }
    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false; backgroundColor = .clear
        isAccessibilityElement = false; accessibilityElementsHidden = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        sync()
    }
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }
    private func sync() {
        if window != nil && active { PencilGuard.shared.register(self, margin: margin) }
        else { PencilGuard.shared.unregister(self) }
    }
}
