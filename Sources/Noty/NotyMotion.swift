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
    /// Library ⇄ calendar: one calm glide; with Reduce Motion only a cross-fade.
    static func modeSwitch(_ reduced: Bool) -> Animation {
        reduced ? .easeInOut(duration: 0.2) : .spring(response: 0.46, dampingFraction: 0.9)
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
