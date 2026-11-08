import SwiftUI

/// Animate user-driven chrome only. Never animate notebook/ink/autosave values.
enum NotyMotion {
    /// Toolbar level, dock, toast. Critically damped: no overshoot without a gesture.
    static func palette(_ reduced: Bool) -> Animation? {
        reduced ? nil : .spring(duration: 0.3, bounce: 0)
    }
    /// Sidebar, law window, split (≈ response 0.32 / damping 0.94).
    static func panel(_ reduced: Bool) -> Animation? {
        reduced ? nil : .spring(duration: 0.32, bounce: 0.04)
    }
    static func highlight(_ reduced: Bool) -> Animation { .easeOut(duration: reduced ? 0.1 : 0.16) }
    /// Hefte ⇄ Kalender by tap (switch, sidebar entry). User request
    /// 08.11.2026 („eine bisschen smoothere Animation“) takes precedence over
    /// the 0.3-s rule for taps: content, library column and the switch's
    /// marker glide with ONE critically damped curve (no overshoot; the
    /// column a frame later, `LibraryView.setCalendar`).
    /// Reduce Motion: only a cross-fade. Keys stay instant (`instant`).
    static func modeSwitch(_ reduced: Bool) -> Animation {
        reduced ? .easeInOut(duration: modeSwitchDuration(reduced)) : .smooth(duration: modeSwitchDuration(reduced))
    }
    static func modeSwitchDuration(_ reduced: Bool) -> TimeInterval { reduced ? 0.2 : 0.45 }
    /// The two sides of `modeSwitch`. Hefte sit left, the calendar right:
    /// each side comes in from / goes out towards its own edge by 20 pt and
    /// settles from 98 %, so the motion follows the switch. The leaving side
    /// is gone after 70 % of the glide's way (≈ 0.18 s), the coming side
    /// fades in along all of it: both never lie on top of each other at full
    /// strength. All of it follows the transaction, so keys (`instant`) stay
    /// without motion. No blur: its modifier would stay on the shown side at
    /// rest – on the calendar above the PencilKit note of the event window.
    /// Reduce Motion: opacity only.
    static func modeTransition(leading: Bool, reduced: Bool) -> AnyTransition {
        if reduced { return .opacity }
        let edge: CGFloat = leading ? -20 : 20
        func side(leaving: Bool) -> AnyTransition {
            .modifier(active: NotyModeShift(amount: 1, edge: edge, leaving: leaving),
                      identity: NotyModeShift(amount: 0, edge: edge, leaving: leaving))
        }
        return .asymmetric(insertion: side(leaving: false), removal: side(leaving: true))
    }
    /// Exits are faster than entrances.
    static let exit: Animation = .easeOut(duration: 0.12)
    /// Reduce Motion substitute for insertions/removals: opacity only, no
    /// movement. Attach it to the inserted view's transition
    /// (`.opacity.animation(NotyMotion.fade)`), never to layout values, which
    /// stay instant (`palette`/`panel` are nil when reduced).
    static let fade: Animation = .easeOut(duration: 0.15)
    /// Keyboard-initiated changes: no implicit or explicit animation applies.
    static func instant(_ body: () -> Void) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction, body)
    }
}

/// One side of `NotyMotion.modeTransition`: `amount` 0 = in place, 1 = away
/// (shifted by `edge`, 98 %, invisible). Animatable, so the leaving side's
/// faster fade is a curve over the glide, not a second animation.
private struct NotyModeShift: ViewModifier, Animatable {
    var amount: Double
    let edge: CGFloat
    let leaving: Bool
    nonisolated var animatableData: Double {
        get { amount }
        set { amount = newValue }
    }
    func body(content: Content) -> some View {
        content
            .opacity(leaving ? max(0, 1 - amount / 0.7) : 1 - amount)
            .scaleEffect(1 - 0.02 * amount)
            .offset(x: edge * amount)
    }
}

struct NotyPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduced
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduced ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.75 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Hover changes presentation only; it never selects a tool or starts drawing.
struct NotyToolStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduced
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.modifier(NotyToolHover())
            .scaleEffect(configuration.isPressed && !reduced ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.75 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private struct NotyToolHover: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduced
    @Environment(\.isEnabled) private var enabled
    @State private var hovering = false
    func body(content: Content) -> some View {
        // Only the symbol itself lights up and lifts: no platter, no visible
        // hit box (user request 20.10.2026), therefore no system lift effect.
        content
            .brightness(hovering ? 0.12 : 0)
            .scaleEffect(hovering && !reduced ? 1.08 : 1)
            .offset(y: hovering && !reduced ? -2 : 0)
            .shadow(color: .black.opacity(hovering ? 0.3 : 0), radius: hovering ? 4 : 0, y: hovering ? 3 : 0)
            .onContinuousHover { phase in
                switch phase {
                case .active: hovering = enabled
                case .ended: hovering = false
                }
            }
            .animation(NotyMotion.highlight(reduced), value: hovering)
            .onDisappear { hovering = false }
    }
}
