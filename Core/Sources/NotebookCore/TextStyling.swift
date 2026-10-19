import Foundation

/// Paragraph styles named like Notability. Sizes fit the 24-pt ruling: one
/// line each, the title exactly two (SF line height ≈ 1.193 × size).
public enum TextStylePreset: String, CaseIterable, Sendable {
    case title, heading, subheading, body, caption
    public static let lineHeightFactor = 1.193
    public var title: String {
        switch self {
        case .title: "Titel"; case .heading: "Überschrift"; case .subheading: "Unterüberschrift"
        case .body: "Text"; case .caption: "Beschriftung"
        }
    }
    public var fontSize: Double {
        switch self { case .title: 30; case .heading: 20; case .subheading: 17; case .body: 14; case .caption: 12 }
    }
    public var bold: Bool { self == .title || self == .heading || self == .subheading }
    public func apply(to style: inout TextBoxStyle) { style.fontSize = fontSize; style.bold = bold }
    /// Ruled lines a single line of this size occupies.
    public static func rulingLines(fontSize: Double) -> Int {
        max(1, Int(ceil(fontSize * lineHeightFactor / PaperRuling.spacing - 0.0001)))
    }
    /// Closest preset for the bar label; older Überschrift 1–3 sizes map sensibly.
    public static func matching(_ style: TextBoxStyle) -> TextStylePreset {
        if style.fontSize >= 28 { return .title }
        if style.fontSize >= 19.5 && style.bold { return .heading }
        if style.fontSize >= 16 && style.bold { return .subheading }
        if style.fontSize <= 12 { return .caption }
        return .body
    }
}

extension TextBoxStyle {
    /// „Formatierung entfernen“: plain body text in automatic colour. Paragraph
    /// alignment/indent and links (content, not appearance) stay.
    public func clearingCharacterFormatting(light: Bool) -> TextBoxStyle {
        var result = TextBoxStyle(font: .system, fontSize: TextStylePreset.body.fontSize, color: light ? .white : .black)
        result.automaticColor = true
        result.alignment = alignment; result.indent = indent; result.link = link
        return result
    }
}

/// Counts for the bar. List markers are structure, not words or characters.
public struct TextStatistics: Equatable, Sendable {
    public var words = 0
    public var characters = 0
    public var charactersWithoutSpaces = 0
    public init(_ text: String) {
        for line in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let body = Self.strippingListMarker(line)
            characters += body.count
            charactersWithoutSpaces += body.filter { !$0.isWhitespace }.count
            words += body.split(whereSeparator: \.isWhitespace).filter { $0.contains { $0.isLetter || $0.isNumber } }.count
        }
    }
    static func strippingListMarker(_ line: Substring) -> Substring {
        let body = line.drop { $0 == " " || $0 == "\t" }
        for marker in ["• ", "◦ ", "▪ ", "- ", "☐ ", "☑ "] where body.hasPrefix(marker) { return body.dropFirst(marker.count) }
        let digits = body.prefix { $0.isASCII && $0.isNumber }
        if !digits.isEmpty, digits.count <= 6, body.dropFirst(digits.count).hasPrefix(". ") { return body.dropFirst(digits.count + 2) }
        return line
    }
}

extension NotebookViewportGeometry {
    /// Typewriter mode: while typing, the caret line never sits below `fraction`
    /// of the visible height; above it the ordinary minimal reveal applies.
    public static func typewriterOffset(caret: PageRect, visible: PageRect, fraction: Double = 1.0 / 3) -> PagePoint {
        var result = caretOffset(caret: caret, visible: visible)
        let anchor = visible.y + visible.height * fraction
        if caret.y + caret.height > anchor { result.y = visible.y + caret.y + caret.height - anchor }
        return result
    }
}

/// Why the caret moved: decides how much the outer viewport may follow it.
public enum CaretReveal: Int, Comparable, Sendable {
    /// Tap, selection, arrow keys, keyboard or page change: the view only moves
    /// when the caret is actually hidden (offscreen or under chrome).
    case navigation
    /// Typing/editing at the caret: keep a small margin to the free area's edges.
    case typing
    /// Typing with typewriter mode on: the line stays in the upper third.
    case typewriter
    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

extension NotebookViewportGeometry {
    /// Smallest content-offset change that shows the caret in the free area.
    /// - Parameters:
    ///   - visible: free part of the viewport in content coordinates (already
    ///     excluding the header with the back arrow, a top-docked toolbar and
    ///     the keyboard with its format bar).
    ///   - obstructions: further screen-fixed covered rects at the current
    ///     offset (floating toolbar), content coordinates.
    ///   - kind: nil behaves like `.navigation`.
    /// - Returns: (0, 0) when nothing has to move.
    public static func caretRevealDelta(caret: PageRect, visible: PageRect, obstructions: [PageRect] = [],
                                        kind: CaretReveal?, margin: Double = 20) -> PagePoint {
        let values = [caret.x, caret.y, caret.width, caret.height, visible.x, visible.y, visible.width, visible.height]
        guard values.allSatisfy(\.isFinite), visible.width > 0, visible.height > 0 else { return PagePoint(x: 0, y: 0) }
        let mx = min(margin, max(0, (visible.width - caret.width) / 2)), my = min(margin, max(0, (visible.height - caret.height) / 2))
        let comfortable = PageRect(x: visible.x + mx, y: visible.y + my, width: visible.width - 2 * mx, height: visible.height - 2 * my)
        func shifted(_ d: PagePoint) -> PageRect { PageRect(x: caret.x - d.x, y: caret.y - d.y, width: caret.width, height: caret.height) }
        func inside(_ r: PageRect, _ area: PageRect) -> Bool {
            r.x >= area.x - 0.01 && r.y >= area.y - 0.01
                && r.x + r.width <= area.x + area.width + 0.01 && r.y + r.height <= area.y + area.height + 0.01
        }
        func overlaps(_ a: PageRect, _ b: PageRect) -> Bool {
            a.x < b.x + b.width && b.x < a.x + a.width && a.y < b.y + b.height && b.y < a.y + a.height
        }
        func hidden(_ d: PagePoint, in area: PageRect) -> Bool {
            let r = shifted(d)
            return !inside(r, area) || obstructions.contains { overlaps($0, r) }
        }
        let zero = PagePoint(x: 0, y: 0)
        let kind = kind ?? .navigation
        switch kind {
        case .navigation: if !hidden(zero, in: visible) { return zero }
        case .typing: if !hidden(zero, in: comfortable) { return zero }
        case .typewriter: break
        }
        let target = kind == .typewriter ? typewriterOffset(caret: caret, visible: comfortable)
            : caretOffset(caret: caret, visible: comfortable)
        var d = PagePoint(x: target.x - comfortable.x, y: target.y - comfortable.y)
        // Screen-fixed chrome inside the free area: step just above or below it.
        for _ in obstructions.indices {
            guard let o = obstructions.first(where: { overlaps($0, shifted(d)) }) else { break }
            let gap = min(8, margin)
            let candidates = [caret.y - (o.y + o.height + gap), caret.y + caret.height - (o.y - gap)].filter { dy in
                let r = shifted(PagePoint(x: d.x, y: dy))
                return r.y >= comfortable.y - 0.01 && r.y + r.height <= comfortable.y + comfortable.height + 0.01
            }
            guard let best = candidates.min(by: { abs($0 - d.y) < abs($1 - d.y) }) else { break }
            d.y = best
        }
        return d
    }
}

/// Resolution of the editor's text raster (page point → screen point):
/// rounded up in √2 steps like ink, so small zoom changes reuse the raster and
/// the text is never drawn coarser than shown. Pixel limits apply per field.
public enum TextRasterScale {
    public static func quantized(_ displayScale: Double) -> Double {
        let scale = displayScale.isFinite ? max(0.05, displayScale) : 1
        return min(64, pow(2, ceil(log2(scale) * 2 - 1e-9) / 2))
    }
}
