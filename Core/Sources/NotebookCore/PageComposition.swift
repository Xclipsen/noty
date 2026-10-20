import Foundation

/// One layer of an exported page, bottom to top. The PDF export draws exactly
/// the list from `Page.exportLayers(hasSource:)` with an exhaustive switch, so
/// no page kind can leave out a layer without failing here or in the compiler.
public enum PageLayer: Equatable, Sendable {
    /// The whole canvas including writing space: margin paper if present,
    /// otherwise the page's own paper (blank under PDFs).
    case paper(PaperStyle, PaperColor, coordinateScale: Double)
    /// White sheet in `sourceFrame`, then the source PDF page as vectors.
    case sourcePDF
    /// Prototype pages without stored paper and without a source PDF.
    case testPaper
    case images
    case shapes
    case ink
    /// Typed text as real (searchable) text, including its links.
    case text
}

extension Page {
    /// Content layers every page composes, whatever its background.
    public static let contentLayers: [PageLayer] = [.images, .shapes, .ink, .text]

    /// `hasSource`: the page's PDF source page was resolved (PDF imports and
    /// legacy single-PDF notebooks).
    public func exportLayers(hasSource: Bool) -> [PageLayer] {
        let sheet = PageLayer.paper(margins?.style ?? paper ?? .blank, margins?.color ?? paperColor ?? .white,
                                    coordinateScale: writingCoordinateScale)
        let background: [PageLayer] = hasSource ? [sheet, .sourcePDF] : paper == nil ? [sheet, .testPaper] : [sheet]
        return background + Self.contentLayers
    }
}
