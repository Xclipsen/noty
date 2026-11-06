import SwiftUI
import UIKit

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
// and the page (`WorksheetView.hitTest`) refuses touches whose start lies in
// a registered frame grown by its margin. Checked once per touch-down against
// the few registered views, never per stroke point; a stroke that started on
// the page and moves under a bar goes on. Refused touches land on the
// notebook viewport, so a finger still scrolls and pinches there; the Pencil
// does nothing (its pan is finger-only except with the text tool). Hover
// (Pencil hover, laser, citation hover) is not affected.

/// Registry of chrome views over the pages, in any window of the scene.
@MainActor
final class PencilGuard {
    static let shared = PencilGuard()

    private final class Entry {
        weak var view: UIView?
        var margin: CGFloat
        init(view: UIView, margin: CGFloat) { self.view = view; self.margin = margin }
    }
    private var entries: [Entry] = []

    /// `margin`: near-miss zone around the view in points (swallowed, no action).
    func register(_ view: UIView, margin: CGFloat) {
        entries.removeAll { $0.view == nil }
        if let entry = entries.first(where: { $0.view === view }) { entry.margin = margin; return }
        entries.append(Entry(view: view, margin: margin))
    }
    func unregister(_ view: UIView) {
        entries.removeAll { $0.view == nil || $0.view === view }
    }

    /// The touch went to a registered UIKit bar itself (selection bar on a
    /// sheet): it keeps working.
    func isChrome(_ hit: UIView) -> Bool {
        entries.contains { entry in entry.view.map { hit.isDescendant(of: $0) } ?? false }
    }

    /// Whether a touch starting at `point` (in `view`) lies on or beside chrome
    /// that is in front of `view`. Hidden or transparent chrome, chrome of a
    /// presentation behind `view` (the editor under a sheet) and empty views
    /// do not count.
    func covers(_ point: CGPoint, in view: UIView) -> Bool {
        guard !entries.isEmpty, let window = view.window else { return false }
        let location = view.convert(point, to: window)
        let root = Self.root(of: view, in: window)
        let rootIndex = root.flatMap { window.subviews.firstIndex(of: $0) }
        for entry in entries {
            guard let chrome = entry.view, let chromeWindow = chrome.window, !chromeWindow.isHidden,
                  chrome.bounds.width > 0, chrome.bounds.height > 0,
                  let chromeRoot = Self.visibleRoot(of: chrome, in: chromeWindow) else { continue }
            var frame = chrome.convert(chrome.bounds, to: chromeWindow)
            if chromeWindow === window {
                if chromeRoot !== root, let rootIndex, let index = window.subviews.firstIndex(of: chromeRoot), index < rootIndex { continue }
            } else {
                // Keyboard window (format bar above the keyboard).
                frame = chromeWindow.convert(frame, to: window)
            }
            if frame.insetBy(dx: -entry.margin, dy: -entry.margin).contains(location) { return true }
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
    /// The window's child holding `view`; nil while `view` or an ancestor is
    /// hidden or fully transparent.
    private static func visibleRoot(of view: UIView, in window: UIWindow) -> UIView? {
        var current = view
        while true {
            if current.isHidden || current.alpha < 0.01 { return nil }
            guard let parent = current.superview else { return nil }
            if parent === window { return current }
            current = parent
        }
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
