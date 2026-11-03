import Foundation

/// Feldstil (Textneubau Stufe 4, docs/TEXT-REBUILD-62.md §2): a free text
/// field may get a light fill and/or a thin frame. As soon as one of them is
/// on, the field shows slightly rounded corners and an inner padding around
/// its text. The stored frame (`x`, `y`, `width`, `height`) stays the text
/// frame; the visible field reaches `fieldPadding` further on every side.
/// Everything that treats the field as an object (page limits, selection,
/// lasso, snapping edges, transfers) uses that visible frame (`corners`,
/// `rotatedBounds`, `contains`); text layout and clipping use the text frame
/// (`textCorners`). Stored in schema 14 (optional `fill`/`border`); flow
/// segments carry no style.
public enum TextFieldFill: String, Codable, CaseIterable, Sendable {
    case yellow, green, blue, pink, gray, purple

    public var title: String {
        switch self {
        case .yellow: "Gelb"; case .green: "Grün"; case .blue: "Blau"
        case .pink: "Rosa"; case .gray: "Grau"; case .purple: "Lila"
        }
    }

    /// Light, opaque sRGB colour (0…1), identical in editor, previews and PDF.
    /// Always light, also on dark paper: automatic text turns dark on it.
    public var rgb: (red: Double, green: Double, blue: Double) {
        switch self {
        case .yellow: (1.00, 0.95, 0.70)
        case .green: (0.84, 0.95, 0.80)
        case .blue: (0.83, 0.91, 1.00)
        case .pink: (1.00, 0.86, 0.91)
        case .gray: (0.91, 0.91, 0.92)
        case .purple: (0.90, 0.86, 1.00)
        }
    }
}

public enum TextFieldBorder: String, Codable, CaseIterable, Sendable {
    /// The field's own (resolved) base text colour.
    case text
    /// The app's accent blue, darkened enough to read on paper and in print.
    case accent

    public var title: String {
        switch self { case .text: "Textfarbe"; case .accent: "Akzentfarbe" }
    }

    public static let accentRGB = (red: 0.12, green: 0.45, blue: 0.90)
}

extension TextBox {
    /// Inner padding (page points) between text and the visible field edge.
    public static let fieldStylePadding = 6.0
    /// Corner radius (page points) of a styled field.
    public static let fieldCornerRadius = 5.0
    /// Frame line width (page points).
    public static let fieldBorderWidth = 1.0

    /// Fill or border is on: rounded corners and padding.
    public var hasFieldStyle: Bool { fill != nil || border != nil }

    /// Padding of the visible field around the text frame; 0 without style.
    public var fieldPadding: Double { hasFieldStyle ? Self.fieldStylePadding : 0 }

    /// The visible field in the field's own unrotated coordinates (origin:
    /// the text frame's top-left corner).
    public var fieldStyleRect: PageRect {
        let p = fieldPadding
        return PageRect(x: -p, y: -p, width: width + 2 * p, height: height + 2 * p)
    }

    /// A tap that means this field because of its style: a filled field is hit
    /// on its whole surface (padding included), a frame-only field on its
    /// frame line like an unfilled shape. Unstyled fields: never (their text
    /// lines decide, `PageObjectHitTest`). `tolerance` in page units.
    public func fieldStyleHit(_ point: PagePoint, tolerance: Double = 0) -> Bool {
        guard hasFieldStyle, point.x.isFinite, point.y.isFinite else { return false }
        let tolerance = tolerance.isFinite ? max(0, tolerance) : 0
        if fill != nil { return contains(point, tolerance: tolerance) }
        let local = localPoint(point), frame = fieldStyleRect
        let reach = Self.fieldBorderWidth / 2 + tolerance
        let outer = local.x >= frame.x - reach && local.x <= frame.x + frame.width + reach
            && local.y >= frame.y - reach && local.y <= frame.y + frame.height + reach
        let inner = local.x > frame.x + reach && local.x < frame.x + frame.width - reach
            && local.y > frame.y + reach && local.y < frame.y + frame.height - reach
        return outer && !inner
    }

    /// The field with this style, completely inside `limits` (page plus
    /// writing space). The text stays where it is if the padding fits;
    /// otherwise the field moves inwards; a field as large as the page gets
    /// a text frame smaller by the padding, so the visible field covers
    /// exactly its former frame (the text rewraps, overflow stays marked,
    /// nothing is cut). Removing the style never moves the text. nil for flow
    /// segments or a field that cannot be placed.
    public func styled(fill: TextFieldFill?, border: TextFieldBorder?, in limits: PageRect) -> TextBox? {
        guard flowID == nil else { return nil }
        var result = self
        result.fill = fill; result.border = border
        if result.fits(in: limits) { return result }
        if let shifted = result.shifted(into: limits) { return shifted }
        let p = result.fieldPadding - fieldPadding
        guard p > 0, width - 2 * p >= 1, height - 2 * p >= 1 else { return nil }
        let origin = pagePoint(.init(x: p, y: p))
        result.x = origin.x; result.y = origin.y
        result.width = width - 2 * p; result.height = height - 2 * p
        return result.fits(in: limits) ? result : result.shifted(into: limits)
    }
}
