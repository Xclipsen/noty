import UIKit
import UIKit.UIGestureRecognizerSubclass

/// Pan that can begin on touch-down (Nutzer 22.10.2026: „Das Formenwerkzeug
/// fängt erst an, wenn man den Stift bewegt, und nicht, wenn man das iPad
/// berührt.“). A plain `UIPanGestureRecognizer` only begins after its movement
/// threshold (~10 pt), so nothing was visible on touch-down. For touches that
/// `beginsImmediately` accepts (Pencil drawing a new shape) this one begins at
/// once; all others (fingers: scrolling, zooming, grabbing shapes) keep the
/// normal threshold. `touchDownLocation` is the exact first contact either way.
final class TouchDownPanGestureRecognizer: UIPanGestureRecognizer {
    var beginsImmediately: ((UITouch) -> Bool)?
    /// First contact of the current gesture, in the recognizer's view.
    private(set) var touchDownLocation: CGPoint?
    /// The current gesture began on touch-down (no movement yet).
    private(set) var beganOnTouchDown = false

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        guard touchDownLocation == nil, let touch = touches.first else { return }
        touchDownLocation = touch.location(in: view)
        if state == .possible, touches.count == 1, beginsImmediately?(touch) == true {
            beganOnTouchDown = true
            state = .began
        }
    }
    override func reset() {
        super.reset()
        touchDownLocation = nil; beganOnTouchDown = false
    }
}
