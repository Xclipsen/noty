import Foundation

public enum EditorInteractionPolicy {
    public static func formattingRange(selection: NSRange, textLength: Int, floating: Bool, wholeField: Bool) -> NSRange {
        if wholeField && floating && selection.length == 0 { return NSRange(location: 0, length: textLength) }
        return selection
    }

    public static func lightAutomaticInk(at point: PagePoint, source: PageRect, sourceDark: Bool, marginDark: Bool) -> Bool {
        let inside = point.x >= source.x && point.x < source.x + source.width
            && point.y >= source.y && point.y < source.y + source.height
        return inside ? sourceDark : marginDark
    }

    /// Whether the canvas must be set back to the model's ink. `shown`: the
    /// canonical bytes the canvas was last set from; nil after a native change
    /// (drawn ink not yet published, e.g. a held stroke ending) which is never
    /// discarded here. Whenever nothing transient is on screen (no stroke,
    /// held shape, erase sweep, lift or object drag) known bytes must match:
    /// an aborted lift (tool change, pane deactivated) left only the remainder
    /// there, and the next stroke would have published it without the lifted ink.
    public static func canvasNeedsReset(shown: Data?, model: Data, stroke: Bool, transient: Bool) -> Bool {
        guard let shown, !stroke, !transient else { return false }
        return shown != model
    }
}

extension EditorInteractionPolicy {
    /// Background behind a text object, like the automatic pen: paper colour,
    /// or the writing margin beside a PDF. The PDF itself renders light.
    public static func automaticTextIsLight(box: TextBox, pageSize: PageSize, hasPDF: Bool, darkPaper: Bool, darkMargins: Bool) -> Bool {
        guard hasPDF else { return darkPaper }
        // Flow segments follow their region; free fields (also migrated page
        // text, which may have been moved) their position.
        if box.flowID != nil, let region = box.flowRegion { return region != .page && darkMargins }
        let onSource = box.x >= 0 && box.x < pageSize.width && box.y >= 0 && box.y < pageSize.height
        return !onSource && darkMargins
    }
}

extension Page {
    public func automaticTextIsLight(_ box: TextBox) -> Bool {
        EditorInteractionPolicy.automaticTextIsLight(box: box, pageSize: geometry?.displaySize ?? .a4, hasPDF: pdfReference != nil,
            darkPaper: paperColor == .dark, darkMargins: margins?.color == .dark)
    }
    /// Text as displayed and exported: automatic colours resolved for this page.
    public var resolvedTextBoxes: [TextBox] { effectiveTextBoxes.map { $0.resolvingAutomaticColor(light: automaticTextIsLight($0)) } }
}

extension TextBoxStyle {
    public func resolvingAutomaticColor(light: Bool) -> TextBoxStyle {
        guard automaticColor == true else { return self }
        var result = self; result.color = light ? .white : .black; result.ink = nil
        return result
    }
}

extension TextBox {
    /// Display-only resolution; the automatic flag itself is preserved.
    public func resolvingAutomaticColor(light: Bool) -> TextBox {
        guard usesColorFormat else { return self }
        var result = self
        result.style = style.resolvingAutomaticColor(light: light)
        result.runs = runs?.map { run in var run = run; run.style = run.style.resolvingAutomaticColor(light: light); return run }
        return result
    }

    /// Flow segments belong to the page. Free fields (also migrated page text
    /// with its layout region) are objects.
    public var allowsObjectSelection: Bool { flowID == nil }

    public func scaled(by scale: Double, around origin: PagePoint, translation: PagePoint) throws -> TextBox {
        guard allowsObjectSelection, scale.isFinite, scale > 0 else { throw StorageError.invalidDocument }
        var result = self
        result.x = origin.x + (x - origin.x) * scale + translation.x
        result.y = origin.y + (y - origin.y) * scale + translation.y
        result.width *= scale; result.height *= scale
        result.style.fontSize *= scale
        result.runs = runs?.map { run in
            var run = run; run.style.fontSize *= scale; return run
        }
        try result.validate()
        return result
    }
}

/// Lines use the same display coordinates in editor, thumbnail and PDF.
public enum PaperRuling {
    public static let firstBaseline = 40.0
    public static let spacing = 24.0
    /// Glyphs stand slightly above the ruled stroke; descenders still cross it.
    public static let baselineLift = 2.5
    public static func nextBaseline(atOrAfter baseline: Double) -> Double {
        firstBaseline + max(0, ceil((baseline - firstBaseline - 0.001) / spacing)) * spacing
    }
    /// Never moves text up from its natural position and never needs more lines
    /// than snapping exactly onto the stroke; only the lift may shrink.
    public static func baseline(forNatural natural: Double) -> Double {
        max(natural, nextBaseline(atOrAfter: natural) - baselineLift)
    }
}
