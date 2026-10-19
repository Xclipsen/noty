import Foundation

/// Baseline grid for page-bound text. Lined paper keeps `PaperRuling` exactly;
/// grid paper uses its 16-pt rows. Same values in editor, preview and PDF.
public struct TextRuling: Equatable, Sendable {
    public let firstBaseline: Double
    public let spacing: Double
    public let lift: Double
    /// Lines may move up by at most this much, so body text (14–15 pt) uses one
    /// grid row; ascenders may then touch the previous row's descenders.
    public let tolerance: Double
    public init(firstBaseline: Double, spacing: Double, lift: Double, tolerance: Double) {
        self.firstBaseline = firstBaseline; self.spacing = spacing; self.lift = lift; self.tolerance = tolerance
    }
    public static let lined = TextRuling(firstBaseline: PaperRuling.firstBaseline, spacing: PaperRuling.spacing,
        lift: PaperRuling.baselineLift, tolerance: 0)
    public static let grid = TextRuling(firstBaseline: PaperRuling.firstBaseline, spacing: 16, lift: 1.5, tolerance: 2)
    public init?(paper: PaperStyle?) {
        switch paper { case .lined: self = .lined; case .grid: self = .grid; default: return nil }
    }
    public func nextBaseline(atOrAfter baseline: Double) -> Double {
        firstBaseline + max(0, ceil((baseline - firstBaseline - 0.001) / spacing)) * spacing
    }
    public func baseline(forNatural natural: Double) -> Double {
        let earliest = natural - tolerance
        return max(earliest, nextBaseline(atOrAfter: earliest) - lift)
    }
}

/// Click-and-type below existing text: the empty lines a tap needs and the
/// baseline of the new caret. Nothing is inserted until typing. The new line
/// always starts at the left edge (no indent/centre/right placement by tap).
public struct TextPlacement: Equatable, Sendable {
    public var newlines: Int
    /// Container coordinates of the new line's baseline (caret display).
    public var baseline: Double
    public init(newlines: Int, baseline: Double) {
        self.newlines = newlines; self.baseline = baseline
    }

    public static let indentStep = 20.0
    public static let maximumIndent = 240.0
    public static let maximumNewlines = 400
    /// Free fields opened by a tap start this wide (less at the right edge, never below `minimumFieldWidth`).
    public static let freeFieldWidth = 260.0
    public static let minimumFieldWidth = 120.0

    /// - Parameters:
    ///   - top: top of the first line after the existing text (bottom of the last
    ///     laid-out line; 0 for empty text), container coordinates.
    ///   - endsWithBreak: the text is empty or ends in a paragraph break, so
    ///     the first candidate line already exists and needs no new break.
    ///   - lineHeight/ascent/descent: native metrics of the typing font.
    ///   - origin: page y of the container top (ruling coordinates).
    public static func below(tap: PagePoint, top: Double, endsWithBreak: Bool, width: Double, height: Double,
                             lineHeight: Double, ascent: Double, descent: Double,
                             ruling: TextRuling?, origin: Double = 0) -> TextPlacement? {
        guard [tap.x, tap.y, top, width, height, lineHeight, ascent, descent, origin].allSatisfy(\.isFinite),
              lineHeight > 0, ascent > 0, width > 0, tap.y >= top - 0.5 else { return nil }
        var lineTop = top, chosen: (Int, Double)?
        for line in 0...maximumNewlines {
            let natural = origin + lineTop + ascent
            let adjusted = ruling?.baseline(forNatural: natural) ?? natural
            let baseline = adjusted - origin
            guard baseline + max(0, descent) <= height + 0.5 else { break }
            chosen = (line, baseline)
            if baseline + max(0, descent) >= tap.y { break }
            lineTop += lineHeight + adjusted - natural
        }
        guard let (line, baseline) = chosen else { return nil }
        return TextPlacement(newlines: line + (endsWithBreak ? 0 : 1), baseline: baseline)
    }

    /// Text tool on a writing region (paper page or writing margin): the left
    /// half always offers the flowing lines; from the middle rightwards a tap
    /// that does not hit existing text opens a separate free text field.
    public static func opensFreeField(tapX: Double, regionX: Double = 0, regionWidth: Double, hitsText: Bool) -> Bool {
        guard tapX.isFinite, regionX.isFinite, regionWidth.isFinite, regionWidth > 0 else { return false }
        return !hitsText && tapX >= regionX + regionWidth / 2
    }

    /// Frame of a free field opened by a tap: the caret starts at the tap and
    /// the first line is vertically centred on it; always inside `limits`.
    public static func freeFieldFrame(tap: PagePoint, limits: PageRect, fontSize: Double) -> PageRect? {
        guard [tap.x, tap.y, limits.x, limits.y, limits.width, limits.height, fontSize].allSatisfy(\.isFinite),
              limits.width >= 40, limits.height >= 24, fontSize > 0 else { return nil }
        let right = limits.x + limits.width, bottom = limits.y + limits.height
        let x = max(limits.x, min(tap.x, right - min(minimumFieldWidth, limits.width)))
        let width = max(min(40, right - x), min(freeFieldWidth, right - x))
        let line = fontSize * TextStylePreset.lineHeightFactor
        let height = max(24, ceil(line))
        let y = max(limits.y, min(tap.y - line / 2, bottom - height))
        return PageRect(x: x, y: y, width: width, height: min(height, limits.height))
    }
}
