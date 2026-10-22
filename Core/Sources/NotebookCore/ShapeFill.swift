import Foundation

/// Fill of rectangles, ellipses and polygons (22.10.2026): colour independent
/// of the stroke and an adjustable strength (opacity). Stored as before in
/// `ShapeObject.fill` (an `InkColor` with alpha, schema 6), so neither the
/// notebook schema nor older readers change; the tool remembers its choice in
/// the toolbar preferences (`shapeFillColor`, `shapeFillOpacity`, optional).
public enum ShapeFill {
    /// Strength of a new fill until the user picks another (the former fixed value).
    public static let defaultOpacity = 0.2
    /// Strengths the tool and the selection style offer.
    public static let opacityRange = 0.1...1.0
    public static let opacitySteps: [Double] = [0.1, 0.2, 0.35, 0.5, 0.75, 1]

    /// `base`'s colour at `opacity` (clamped to `opacityRange`; non-finite → default).
    public static func color(_ base: InkColor, opacity: Double) -> InkColor {
        let value = opacity.isFinite ? min(opacityRange.upperBound, max(opacityRange.lowerBound, opacity)) : defaultOpacity
        return InkColor(base.red, base.green, base.blue, value)
    }
    /// Opacity rounded to whole percent, so slider values stay stable in JSON.
    public static func rounded(_ opacity: Double) -> Double {
        guard opacity.isFinite else { return defaultOpacity }
        return (min(opacityRange.upperBound, max(opacityRange.lowerBound, opacity)) * 100).rounded() / 100
    }
    public static func sameHue(_ a: InkColor, _ b: InkColor) -> Bool {
        abs(a.red - b.red) < 0.002 && abs(a.green - b.green) < 0.002 && abs(a.blue - b.blue) < 0.002
    }
}

extension ShapeObject {
    /// Only closed outlines show a fill (renderer, hit test, contour).
    public var isFillable: Bool { kind == .rectangle || kind == .ellipse || kind == .polygon }
    /// A fill that is actually drawn: fillable kind and any strength above 0.
    /// Only then the inside counts for taps, the lasso, the eraser and the contour.
    public var hasVisibleFill: Bool { isFillable && (fill?.alpha ?? 0) > 0 }
    /// The fill has the stroke's colour (older shapes, „wie Strich“): it then
    /// keeps following a new stroke colour; an own fill colour stays.
    public var fillFollowsStroke: Bool { fill.map { ShapeFill.sameHue($0, color) } ?? false }
    /// New stroke colour; a fill that followed the stroke follows with its strength.
    public func recolored(_ stroke: InkColor) -> ShapeObject {
        var result = self
        if let fill, fillFollowsStroke { result.fill = InkColor(stroke.red, stroke.green, stroke.blue, fill.alpha) }
        result.color = stroke
        return result
    }
    /// Fill of a fillable shape: `color` nil = the stroke's colour; opacity
    /// `nil` keeps the current strength (or the default). Lines/arrows stay unfilled.
    public func filled(color base: InkColor?, opacity: Double?) -> ShapeObject {
        guard isFillable else { return self }
        var result = self
        result.fill = ShapeFill.color(base ?? color, opacity: opacity ?? fill?.alpha ?? ShapeFill.defaultOpacity)
        return result
    }
    public func unfilled() -> ShapeObject { var result = self; result.fill = nil; return result }
}

extension ToolbarPreferences {
    /// Fill colour/strength of new shapes (nil colour: follows the stroke).
    public func shapeFillColor(stroke: InkColor) -> InkColor {
        ShapeFill.color(shapeFillColor ?? stroke, opacity: shapeFillOpacity ?? ShapeFill.defaultOpacity)
    }
}
