import UIKit
import UIKit.UIGestureRecognizerSubclass

/// A passive Pencil observer. Moving restarts the hold clock and never cancels
/// PencilKit; the completed stroke is replaced atomically after lifting.
@MainActor
final class PencilHoldGesture: UIGestureRecognizer {
    var onHold: (() -> Void)?
    var onPoint: ((CGPoint) -> Void)?
    var allowFinger = false
    private var timer: Timer?
    private var point = CGPoint.zero
    private weak var tracked: UITouch?
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = touches.first, touch.type == .pencil || allowFinger else { state = .failed; return }
        tracked = touch; point = touch.location(in: view); onPoint?(point); arm()
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = tracked else { return }
        let next = touch.location(in: view)
        onPoint?(next)
        if hypot(next.x - point.x, next.y - point.y) > 3 { point = next; arm() }
    }
    private func arm() {
        timer?.invalidate()
        timer = Timer(timeInterval: 0.75, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.onHold?() }
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) { timer?.invalidate(); state = .failed }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { timer?.invalidate(); state = .failed }
    override func reset() { timer?.invalidate(); timer = nil; tracked = nil; super.reset() }
    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }
}

/// Snapshot attempts wait for touches/gestures to finish, including shape drags
/// and native text selection. This observer never takes ownership of a gesture.
@MainActor
final class PageInteractionObserver: UIGestureRecognizer {
    var onChange: ((Bool) -> Void)?
    private var touches = Set<UITouch>()
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        self.touches.formUnion(touches); onChange?(true)
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) { }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        self.touches.subtract(touches)
        if self.touches.isEmpty { onChange?(false); state = .failed }
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        self.touches.subtract(touches)
        if self.touches.isEmpty { onChange?(false); state = .failed }
    }
    override func reset() { touches.removeAll(); onChange?(false); super.reset() }
    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }
}
