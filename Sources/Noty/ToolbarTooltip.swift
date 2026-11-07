import SwiftUI
import NotebookCore

/// Name and short description after lingering over a toolbar item with
/// Apple Pencil hover or a trackpad/mouse pointer (feedback 22.10.2026).
/// Display only: the bubble never takes touches, appears after a short delay
/// and disappears as soon as the hover ends, so writing is never blocked.
/// No `.help`: with a pointer it would add the system tooltip as a second
/// bubble (polish audit F1); VoiceOver gets the text as accessibility hint.
/// After a name was shown, neighbours show theirs at once (`NotyTooltipClock`).
struct NotyTooltipValue {
    let text: String
    let anchor: Anchor<CGRect>
    let axis: ToolbarAxis
    /// Shown while warm: switches without fading.
    var instant = false
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

/// Shared warm-up of all hover names, SwiftUI and UIKit bars alike: the
/// first name waits `delay`; while one is shown, or within `warmWindow`
/// after it went away, the next appears at once without fading (audits F2/A1).
@MainActor
enum NotyTooltipClock {
    static let delay: TimeInterval = 0.65
    static let warmWindow: TimeInterval = 0.6
    private static var lastHidden: TimeInterval = -.infinity
    private static var visible = 0

    /// True when a name should appear without waiting.
    static var isWarm: Bool {
        visible > 0 || ProcessInfo.processInfo.systemUptime - lastHidden < warmWindow
    }
    static func didShow() { visible += 1 }
    static func didHide() {
        visible = max(0, visible - 1)
        lastHidden = ProcessInfo.processInfo.systemUptime
    }
}

private struct NotyTooltip: ViewModifier {
    let text: String
    let hint: Bool
    @Environment(\.notyTooltipAxis) private var axis
    @Environment(\.isEnabled) private var enabled
    @State private var shown = false
    @State private var instant = false
    @State private var pending: Task<Void, Never>?

    func body(content: Content) -> some View {
        hinted(content)
            .onContinuousHover { phase in
                switch phase {
                case .active:
                    guard pending == nil, !shown else { return }
                    if NotyTooltipClock.isWarm {
                        withTransaction(Transaction(animation: nil)) { show(instant: true) }
                        return
                    }
                    pending = Task { @MainActor in
                        try? await Task.sleep(for: .seconds(NotyTooltipClock.delay))
                        guard !Task.isCancelled else { return }
                        pending = nil; show(instant: false)
                    }
                case .ended:
                    hide()
                }
            }
            .anchorPreference(key: NotyTooltipKey.self, value: .bounds) { anchor in
                shown && enabled ? NotyTooltipValue(text: text, anchor: anchor, axis: axis, instant: instant) : nil
            }
            .onDisappear { hide() }
    }

    @ViewBuilder private func hinted(_ content: Content) -> some View {
        if hint { content.accessibilityHint(text) } else { content }
    }

    private func show(instant: Bool) {
        self.instant = instant; shown = true; NotyTooltipClock.didShow()
    }

    private func hide() {
        pending?.cancel(); pending = nil
        if shown { shown = false; NotyTooltipClock.didHide() }
    }
}

extension View {
    /// System pointer tooltip (help tag) for a view that reads as plain `text`.
    /// `.help` also sets the accessibility hint ("configures the view's
    /// accessibility hint and its help tag", SwiftUI docs), so a title shown
    /// as help would be read twice, or clash with an explicit hint. Here the
    /// view's accessibility is replaced by a plain `Text(text)` without hint,
    /// so VoiceOver hears it exactly once; use it on the title text itself,
    /// not on a button with its own label and hint.
    func pointerHelp(_ text: String) -> some View {
        help(text).accessibilityRepresentation { Text(text) }
    }

    /// Tooltip with a name or very short description (German), see `NotyTooltip`.
    /// `hint: false` where the text only repeats the accessibility label.
    func notyTooltip(_ text: String, hint: Bool = true) -> some View { modifier(NotyTooltip(text: text, hint: hint)) }

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
            .animation(value.instant ? nil : .easeOut(duration: reduceMotion ? 0.08 : 0.14), value: value.text)
    }
}
