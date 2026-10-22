import SwiftUI
import NotebookCore

/// Name and short description after lingering over a toolbar item with
/// Apple Pencil hover or a trackpad/mouse pointer (feedback 22.10.2026).
/// Display only: the bubble never takes touches, appears after a short delay
/// and disappears as soon as the hover ends, so writing is never blocked.
/// `.help` carries the same text for the system pointer tooltip and VoiceOver.
struct NotyTooltipValue {
    let text: String
    let anchor: Anchor<CGRect>
    let axis: ToolbarAxis
}

struct NotyTooltipKey: PreferenceKey {
    static let defaultValue: NotyTooltipValue? = nil
    static func reduce(value: inout NotyTooltipValue?, nextValue: () -> NotyTooltipValue?) {
        if let next = nextValue() { value = next }
    }
}

private struct NotyTooltipAxisKey: EnvironmentKey {
    static let defaultValue = ToolbarAxis.horizontal
}

extension EnvironmentValues {
    /// Orientation of the bar the item sits in: horizontal bars show the
    /// bubble above/below, vertical bars beside it, towards the page.
    var notyTooltipAxis: ToolbarAxis {
        get { self[NotyTooltipAxisKey.self] }
        set { self[NotyTooltipAxisKey.self] = newValue }
    }
}

private struct NotyTooltip: ViewModifier {
    let text: String
    @Environment(\.notyTooltipAxis) private var axis
    @Environment(\.isEnabled) private var enabled
    @State private var shown = false
    @State private var pending: Task<Void, Never>?
    static let delay = Duration.milliseconds(650)

    func body(content: Content) -> some View {
        content
            .help(text)
            .onContinuousHover { phase in
                switch phase {
                case .active:
                    guard pending == nil, !shown else { return }
                    pending = Task { @MainActor in
                        try? await Task.sleep(for: Self.delay)
                        guard !Task.isCancelled else { return }
                        pending = nil; shown = true
                    }
                case .ended:
                    hide()
                }
            }
            .anchorPreference(key: NotyTooltipKey.self, value: .bounds) { anchor in
                shown && enabled ? NotyTooltipValue(text: text, anchor: anchor, axis: axis) : nil
            }
            .onDisappear { hide() }
    }

    private func hide() {
        pending?.cancel(); pending = nil
        if shown { shown = false }
    }
}

extension View {
    /// Tooltip with a name or very short description (German), see `NotyTooltip`.
    func notyTooltip(_ text: String) -> some View { modifier(NotyTooltip(text: text)) }

    /// Draws the tooltip of any item inside this view, above everything else.
    func notyTooltipHost() -> some View {
        overlayPreferenceValue(NotyTooltipKey.self) { value in
            GeometryReader { proxy in
                if let value {
                    NotyTooltipBubble(value: value, rect: proxy[value.anchor], size: proxy.size)
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}

private struct NotyTooltipBubble: View {
    let value: NotyTooltipValue
    let rect: CGRect
    let size: CGSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // Towards the free page area: below a bar in the upper half, above one
        // in the lower half; right of a bar on the left, left of one on the right.
        let gap: CGFloat = 10
        let point: CGPoint, alignment: Alignment
        if value.axis == .horizontal {
            let below = rect.midY < size.height / 2
            point = CGPoint(x: min(max(rect.midX, min(150, size.width / 2)), max(size.width / 2, size.width - 150)),
                            y: below ? rect.maxY + gap : rect.minY - gap)
            alignment = below ? .top : .bottom
        } else {
            let right = rect.midX < size.width / 2
            point = CGPoint(x: right ? rect.maxX + gap : rect.minX - gap, y: rect.midY)
            alignment = right ? .leading : .trailing
        }
        return Color.clear.frame(width: 1, height: 1)
            .overlay(alignment: alignment) {
                Text(value.text)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Color(white: 0.11).opacity(0.96), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(.white.opacity(0.16), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
                    .environment(\.colorScheme, .dark)
                    .transition(.opacity)
                    .id(value.text)
            }
            .position(point)
            .animation(.easeOut(duration: reduceMotion ? 0.08 : 0.14), value: value.text)
    }
}
