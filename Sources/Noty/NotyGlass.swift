import SwiftUI

private struct NotyGlass: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @ViewBuilder func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(Color(white: 0.13), in: RoundedRectangle(cornerRadius: 16))
        } else if #available(iOS 26.0, *) {
            content.glassEffect(.regular.tint(.black.opacity(0.3)), in: RoundedRectangle(cornerRadius: 16))
        } else {
            content.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
    }
}

extension View {
    func notyGlass() -> some View { modifier(NotyGlass()) }
}
