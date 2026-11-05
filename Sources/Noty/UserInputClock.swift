import UIKit
import UIKit.UIGestureRecognizerSubclass

/// When the user last touched the app's window or pressed a key. Lets the
/// viewport tell a caret move by the user from one UIKit makes itself after
/// the app comes back (`CaretRevealGate`). Only a time, nothing about where.
@MainActor
enum UserInputClock {
    private(set) static var last: CFTimeInterval?
    static func note() { last = CACurrentMediaTime() }

    /// One passive observer per window; it fails at the first touch and so
    /// never delays, cancels or competes with any other recognizer.
    static func install(on window: UIWindow) {
        guard !(window.gestureRecognizers ?? []).contains(where: { $0 is Observer }) else { return }
        window.addGestureRecognizer(Observer(target: nil, action: nil))
    }

    private final class Observer: UIGestureRecognizer {
        override init(target: Any?, action: Selector?) {
            super.init(target: target, action: action)
            cancelsTouchesInView = false; delaysTouchesBegan = false; delaysTouchesEnded = false
            requiresExclusiveTouchType = false
        }
        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
            UserInputClock.note()
            if let window = view as? UIWindow { InputProbe.began(touches, event: event, in: window) }
            state = .failed
        }
        // Back to possible once every touch of the window has ended.
        override func reset() { super.reset(); InputProbe.observerReset() }
        override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
        override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    }
}
