import Foundation

/// Which existing pages follow a changed notebook paper default.
public enum PageDefaultsScope: String, CaseIterable, Sendable {
    /// Only new standard pages and the trailing writing draft.
    case newPagesOnly
    /// Additionally the listed empty paper pages.
    case emptyPages
    /// Every active paper page (written ones too) and the writing space beside PDFs.
    case wholeNotebook
}

/// Keeps content legible when the paper colour flips: only neutral ink swaps
/// (black/near-black ↔ white/near-white). Saturated colours (red, blue,
/// yellow marker …) and mid greys stay exactly as they were; alpha is kept.
/// Direction-aware: converting to dark only touches dark neutrals and vice versa.
public enum PaperInkInversion {
    /// Max − min of the RGB components; above this a colour counts as coloured.
    public static let maximumChroma = 0.15
    public static let darkLuminance = 0.2
    public static let lightLuminance = 0.8

    static func clamped(_ value: Double) -> Double { value.isFinite ? min(1, max(0, value)) : 0 }

    public static func luminance(_ color: InkColor) -> Double {
        0.2126 * clamped(color.red) + 0.7152 * clamped(color.green) + 0.0722 * clamped(color.blue)
    }

    public static func isNeutral(_ color: InkColor) -> Bool {
        let values = [color.red, color.green, color.blue].map(clamped)
        return values.max()! - values.min()! <= maximumChroma
    }

    /// The swapped colour, or nil when the colour stays unchanged.
    public static func converted(_ color: InkColor, to target: PaperColor) -> InkColor? {
        guard isNeutral(color) else { return nil }
        let alpha = clamped(color.alpha)
        switch target {
        case .dark: return luminance(color) <= darkLuminance ? InkColor(1, 1, 1, alpha) : nil
        case .white: return luminance(color) >= lightLuminance ? InkColor(0, 0, 0, alpha) : nil
        }
    }

    public static func converted(_ color: TextColor, to target: PaperColor) -> TextColor? {
        switch (color, target) {
        case (.black, .dark): .white
        case (.white, .white): .black
        default: nil
        }
    }

    /// A custom ink decides the visible colour; otherwise the named colour does.
    public static func converted(_ style: TextBoxStyle, to target: PaperColor) -> TextBoxStyle {
        var result = style
        if style.automaticColor == true { result.color = target == .dark ? .white : .black; result.ink = nil; return result }
        if let ink = style.ink {
            guard let next = converted(ink, to: target) else { return style }
            result.ink = next
            result.color = target == .dark ? .white : .black
        } else if let next = converted(style.color, to: target) {
            result.color = next
        }
        return result
    }

    public static func converted(_ box: TextBox, to target: PaperColor) -> TextBox {
        var result = box
        result.style = converted(box.style, to: target)
        result.runs = box.runs?.map { run in var run = run; run.style = converted(run.style, to: target); return run }
        return result
    }

    public static func converted(_ shape: ShapeObject, to target: PaperColor) -> ShapeObject {
        var result = shape
        if let next = converted(shape.color, to: target) { result.color = next }
        if let fill = shape.fill, let next = converted(fill, to: target) { result.fill = next }
        return result
    }
}

extension Page {
    /// The base sheet (PDF or paper) in canonical coordinates; writing margins
    /// lie outside it at negative or beyond-size coordinates.
    public var baseContentRect: PageRect {
        let size = geometry?.displaySize ?? .a4
        return PageRect(x: 0, y: 0, width: size.width, height: size.height)
    }

    /// True when `rect` does not reach into the base sheet, i.e. it lies
    /// completely in the writing margins. A stroke may touch the edge by half
    /// a point (its rendered antialiasing) and still count as margin content.
    public func liesInMargins(_ rect: PageRect, tolerance: Double = 0.5) -> Bool {
        let base = baseContentRect
        return rect.x + rect.width <= base.x + tolerance || rect.x >= base.x + base.width - tolerance
            || rect.y + rect.height <= base.y + tolerance || rect.y >= base.y + base.height - tolerance
    }

    /// Text bound to a margin flow belongs to that margin; free annotations
    /// are judged by their frame. Anything over the PDF scan stays unchanged.
    func textBoxLiesInMargins(_ box: TextBox) -> Bool {
        if let region = box.flowRegion, region != .page { return true }
        return liesInMargins(box.rect)
    }
}
