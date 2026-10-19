import UIKit
import UIKit.UIGestureRecognizerSubclass

/// A simultaneous Pencil observer. Screen-space motion restarts the hold clock
/// without cancelling PencilKit; a held preview is committed after lifting.
@MainActor
final class PencilHoldGesture: UIGestureRecognizer, UIGestureRecognizerDelegate {
    var onHold: (() -> Void)?
    var onPoint: ((CGPoint) -> Void)?
    var onBegin: ((CGPoint) -> Void)?
    var onMove: (() -> Void)?
    var onEnd: ((Bool) -> Void)?
    var allowFinger = false
    private var timer: Timer?
    private var point = CGPoint.zero
    private weak var tracked: UITouch?
    override init(target: Any?, action: Selector?) { super.init(target: target, action: action); delegate = self }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard tracked == nil, let touch = touches.first(where: { $0.type == .pencil || (allowFinger && $0.type == .direct) }) else {
            timer?.invalidate(); onEnd?(true); state = tracked == nil ? .failed : .cancelled; return
        }
        tracked = touch; point = touch.location(in: view?.window ?? view)
        state = .began; onBegin?(touch.location(in: view)); onPoint?(touch.location(in: view)); arm()
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = tracked else { return }
        let next = touch.location(in: view)
        onPoint?(next)
        let screen = touch.location(in: view?.window ?? view)
        if hypot(screen.x - point.x, screen.y - point.y) > 6 { point = screen; onMove?(); arm() }
        state = .changed
    }
    private func arm() {
        timer?.invalidate()
        timer = Timer(timeInterval: 0.75, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.tracked != nil, self.state == .began || self.state == .changed else { return }
                self.onHold?()
            }
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) { timer?.invalidate(); state = .ended; onEnd?(false) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { timer?.invalidate(); state = .cancelled; onEnd?(true) }
    override func reset() { timer?.invalidate(); timer = nil; tracked = nil; super.reset() }
    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }
}

/// Fail immediately away from a checkbox, so ordinary Pencil strokes stay native.
@MainActor
final class CheckboxTapGesture: UITapGestureRecognizer, UIGestureRecognizerDelegate {
    var accepts: ((CGPoint) -> Bool)?
    var onTap: ((CGPoint) -> Void)?
    init() {
        super.init(target: nil, action: nil)
        delegate = self; addTarget(self, action: #selector(tapped))
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        accepts?(touch.location(in: view)) == true
    }
    @objc private func tapped() { if state == .ended { onTap?(location(in: view)) } }
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
