import Foundation

/// „An Linien ausrichten“ (schema 16, docs/TEXT-FIELDS.md): a free field's
/// baselines stand on the paper lines under it, by the same rule as a text
/// document's flow (`TextRuling.lineBaseline`, `PaperRuling.baselineLift`).
/// Everything that lays text out (editor, previews, thumbnails, PDF export,
/// height and overflow) asks `TextLinePaper.grid(for:)`; the field snaps its
/// top with `snappedY(for:firstAscent:within:)`.
extension TextBox {
    /// Lowest notebook schema for `alignsToLines`.
    public static let lineAlignmentSchemaVersion = 16
    public var usesLineAlignmentFormat: Bool { alignsToLines != nil }
}

extension TextRuling {
    /// The same ruling in units `factor` times as large (lines beside a wide
    /// PDF are drawn in its writing-space units, `Page.writingCoordinateScale`).
    public func scaled(by factor: Double) -> TextRuling {
        TextRuling(firstBaseline: firstBaseline * factor, spacing: spacing * factor, lift: lift * factor, tolerance: tolerance * factor)
    }
    /// Ruling y of the drawn line `index` (0: the first one).
    public func line(_ index: Int) -> Double { firstBaseline + Double(index) * spacing }
}

/// The lines a text box's layout stands on, in the box's own container units
/// (page units ÷ `TextLinePaper.coordinateScale(for:)`).
public struct TextLineGrid: Equatable, Sendable {
    public var ruling: TextRuling
    /// Container top in ruling coordinates: canvas y (page y plus the writing
    /// space above the sheet), container units.
    public var origin: Double
    /// Flow segments only: the page top in the same coordinates
    /// (`TextRuling.firstLineBaseline`). Free fields never reach above their top.
    public var pageTop: Double?
    public init(ruling: TextRuling, origin: Double, pageTop: Double? = nil) {
        self.ruling = ruling; self.origin = origin; self.pageTop = pageTop
    }
    /// Baseline in container coordinates of a line starting at `top`.
    public func baseline(top: Double, ascent: Double) -> Double {
        ruling.lineBaseline(top: top, ascent: ascent, origin: origin, pageTop: pageTop)
    }
}

extension DocumentPageRule {
    public init(height: Double, grid: TextLineGrid?) {
        self.init(height: height, ruling: grid?.ruling, origin: grid?.origin, pageTop: grid?.pageTop)
    }
}

/// Whether a field's switch „An Linien ausrichten“ takes effect where it is.
public enum TextLineAlignment: Equatable, Sendable {
    /// Switch off (every older field), or a flow segment.
    case off
    /// The baselines stand on the paper lines.
    case aligned
    /// Switch on, but blank paper, a PDF or writing space without lines there.
    case noLines
    /// Switch on, but the field is turned: paper lines stay horizontal.
    case rotated
}

/// What the line layout of text needs to know about its page. Built from a
/// `Page` (`Page.linePaper`) or from the editor's configured page, so both
/// lay out with the same values.
public struct TextLinePaper: Equatable, Sendable {
    /// Ruling of the sheet itself (lined/grid paper); nil under a PDF or on
    /// legacy pages: they show no lines on the sheet.
    public var sheet: PaperStyle?
    /// Ruling of the writing space beside the sheet (`PageMargins.style`).
    public var margin: PaperStyle?
    /// The sheet's size (page coordinates 0…width, 0…height).
    public var contentSize: PageSize
    /// Writing space above the sheet: canvas y of page y 0.
    public var contentTop: Double
    /// `Page.writingCoordinateScale`: lines of a PDF's writing space and its
    /// migrated page text use normal-page units (1 on paper pages).
    public var scale: Double
    /// Tops of the writing regions (`Page.writingRegionTops`), for fields
    /// migrated from page text.
    public var regionTops: [TextFlowRegion: Double]
    public init(sheet: PaperStyle?, margin: PaperStyle?, contentSize: PageSize, contentTop: Double, scale: Double,
                regionTops: [TextFlowRegion: Double]) {
        self.sheet = sheet; self.margin = margin; self.contentSize = contentSize
        self.contentTop = contentTop; self.scale = scale; self.regionTops = regionTops
    }

    /// Page units per container unit of `box`: margin text keeps normal-page
    /// units (flow segments and the fields migrated from them).
    public func coordinateScale(for box: TextBox) -> Double {
        box.flowRegion != nil && box.flowRegion != .page ? scale : 1
    }

    /// The drawn paper lines at a page point, in page units and ruling
    /// coordinates; nil where none are drawn (blank paper, a PDF, writing
    /// space without lines). Same lines as `PDFExporter.drawPaper`.
    public func lines(at point: PagePoint) -> TextRuling? {
        let onSheet = point.x >= 0 && point.x < contentSize.width && point.y >= 0 && point.y < contentSize.height
        return TextRuling(paper: onSheet ? sheet : margin)?.scaled(by: scale)
    }

    /// The field's first line starts at its top-left corner: that place decides
    /// which lines it stands on (sheet or writing space).
    public func lineAlignment(for box: TextBox) -> TextLineAlignment {
        guard box.alignsToLines == true, box.flowID == nil else { return .off }
        guard box.angle == 0 else { return .rotated }
        return lines(at: PagePoint(x: box.x, y: box.y)) == nil ? .noLines : .aligned
    }

    /// The one line rule of every text box: aligned fields stand on the paper
    /// lines from their own top; flow segments and migrated fields keep the
    /// ruling of their region (`TextBox.rulingAnchorY`); nil: free layout.
    public func grid(for box: TextBox) -> TextLineGrid? {
        let units = coordinateScale(for: box)
        if lineAlignment(for: box) == .aligned, let lines = lines(at: PagePoint(x: box.x, y: box.y)) {
            return TextLineGrid(ruling: lines.scaled(by: 1 / units), origin: (box.y + contentTop) / units)
        }
        guard let region = box.flowRegion, let ruling = TextRuling(paper: region == .page ? sheet : margin),
              let anchor = box.rulingAnchorY(regionTops: regionTops) else { return nil }
        return TextLineGrid(ruling: ruling, origin: (anchor + contentTop) / units, pageTop: box.flowID == nil ? nil : contentTop / units)
    }

    /// The top (page y) at which an aligned field's first baseline stands
    /// exactly on a paper line (`baselineLift` above the stroke): the line
    /// nearest to its natural first baseline, else the nearest one that keeps
    /// the whole field inside `limits`. Snapped fields stay where they are.
    /// `firstAscent`: the first line's natural baseline offset without ruling
    /// (TextKit), container units. nil: not aligned, or no line fits.
    public func snappedY(for box: TextBox, firstAscent: Double, within limits: PageRect? = nil) -> Double? {
        guard lineAlignment(for: box) == .aligned, let lines = lines(at: PagePoint(x: box.x, y: box.y)),
              firstAscent.isFinite, firstAscent >= 0, lines.spacing > 0 else { return nil }
        let ascent = firstAscent * coordinateScale(for: box)
        func top(_ index: Int) -> Double { lines.line(index) - lines.lift - ascent - contentTop }
        let wanted = (box.y + contentTop + ascent + lines.lift - lines.firstBaseline) / lines.spacing
        guard wanted.isFinite else { return nil }
        guard let limits else { return top(max(0, Int(wanted.rounded()))) }
        // Lines down to the bottom of the limits; nearest first, upwards on a tie.
        let last = max(0, Int(((limits.y + limits.height + contentTop - lines.firstBaseline) / lines.spacing).rounded(.down)))
        let nearest = min(max(0, Int(wanted.rounded())), last)
        for distance in 0...last {
            let pair = [nearest - distance, nearest + distance]
            let ordered = abs(Double(pair[0]) - wanted) <= abs(Double(pair[1]) - wanted) ? pair : pair.reversed()
            for index in ordered where (0...last).contains(index) {
                var probe = box; probe.y = top(index)
                if probe.fits(in: limits) { return probe.y }
            }
        }
        return nil
    }
}

extension Page {
    /// The line facts of this page (`TextLinePaper`).
    public var linePaper: TextLinePaper {
        TextLinePaper(sheet: paper, margin: margins?.style, contentSize: geometry?.displaySize ?? .a4,
                      contentTop: margins?.top ?? 0, scale: writingCoordinateScale, regionTops: writingRegionTops)
    }
}
