import SwiftUI

/// The one glass surface of noty's dark chrome (polish audit F11): Liquid
/// Glass on iOS 26, a material before, a solid dark fill with Reduce
/// Transparency. Bars, tabs, the Squeeze palette and the status pill all use
/// it; they differ only in shape and in how dark the tint is.
private struct NotyGlass<S: Shape>: ViewModifier {
    let shape: S
    let tint: Double
    let solid: Color
    /// Extra dark layer under the pre-iOS-26 material (palette: as dark as the system's).
    let fallbackShade: Double
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @ViewBuilder func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(solid, in: shape)
        } else if #available(iOS 26.0, *) {
            content.glassEffect(.regular.tint(.black.opacity(tint)), in: shape)
        } else if fallbackShade > 0 {
            content.background(Color.black.opacity(fallbackShade), in: shape).background(.ultraThinMaterial, in: shape)
        } else {
            content.background(.ultraThinMaterial, in: shape)
        }
    }
}

/// Hairline edge for glass surfaces. iOS 26's `glassEffect` draws its own
/// rim, so the stroke only appears on the material and solid fallbacks
/// (otherwise the edge would be doubled).
private struct NotyGlassRim<S: InsettableShape>: ViewModifier {
    let shape: S
    let opacity: Double
    let lineWidth: CGFloat
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    func body(content: Content) -> some View {
        content.overlay {
            if Self.drawsRim(reduceTransparency) {
                shape.strokeBorder(.white.opacity(opacity), lineWidth: lineWidth).allowsHitTesting(false)
            }
        }
    }
    static func drawsRim(_ reduceTransparency: Bool) -> Bool {
        if reduceTransparency { return true }
        if #available(iOS 26.0, *) { return false }
        return true
    }
}

/// Like `NotyGlassRim` for shapes that can only be stroked (the palette arc).
private struct NotyGlassRimStroke<S: Shape>: ViewModifier {
    let shape: S
    let opacity: Double
    let lineWidth: CGFloat
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    func body(content: Content) -> some View {
        content.overlay {
            if NotyGlassRim<Rectangle>.drawsRim(reduceTransparency) {
                shape.stroke(.white.opacity(opacity), lineWidth: lineWidth).allowsHitTesting(false)
            }
        }
    }
}

extension View {
    /// Standard chrome glass: rounded rectangle, radius 16.
    func notyGlass() -> some View {
        notyGlass(in: RoundedRectangle(cornerRadius: 16))
    }

    /// Chrome glass in any shape (bars, tabs, capsules, the palette arc).
    func notyGlass<S: Shape>(in shape: S, tint: Double = 0.3, solid: Color = Color(white: 0.13),
                             fallbackShade: Double = 0) -> some View {
        modifier(NotyGlass(shape: shape, tint: tint, solid: solid, fallbackShade: fallbackShade))
    }

    /// Hairline edge that is left out where the glass already draws one.
    func notyGlassRim<S: InsettableShape>(_ shape: S, opacity: Double = 0.14, lineWidth: CGFloat = 0.6) -> some View {
        modifier(NotyGlassRim(shape: shape, opacity: opacity, lineWidth: lineWidth))
    }

    /// `notyGlassRim` for a shape that is stroked along its path.
    func notyGlassRimStroke<S: Shape>(_ shape: S, opacity: Double = 0.14, lineWidth: CGFloat = 0.6) -> some View {
        modifier(NotyGlassRimStroke(shape: shape, opacity: opacity, lineWidth: lineWidth))
    }
}
