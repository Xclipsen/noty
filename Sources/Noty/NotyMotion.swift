import SwiftUI

/// Animate user-driven chrome only. Never animate notebook/ink/autosave values.
enum NotyMotion {
    static func palette(_ reduced: Bool) -> Animation? {
        reduced ? nil : .spring(response: 0.36, dampingFraction: 0.86)
    }
    static func panel(_ reduced: Bool) -> Animation? {
        reduced ? nil : .spring(response: 0.32, dampingFraction: 0.94)
    }
    static func highlight(_ reduced: Bool) -> Animation { .easeOut(duration: reduced ? 0.1 : 0.16) }
}

struct NotyPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduced
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduced ? 0.91 : 1)
            .opacity(configuration.isPressed ? 0.75 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Hover changes presentation only; it never selects a tool or starts drawing.
struct NotyToolStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduced
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.modifier(NotyToolHover())
            .scaleEffect(configuration.isPressed && !reduced ? 0.94 : 1)
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
