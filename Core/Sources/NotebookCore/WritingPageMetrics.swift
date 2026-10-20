import Foundation

extension Page {
    /// PDF source coordinates stay untouched. Body text in its writing margin
    /// uses normal-page units, independently of the source scan's point size.
    /// Writing space beside paper continues the sheet itself: its own units.
    public var writingCoordinateScale: Double {
        margins == nil || writingSpaceExtendsPaper ? 1 : (geometry?.displaySize.width ?? PageSize.a4.width) / PageSize.a4.width
    }
    /// Paper pages (schema 11) take writing space only right and below, in the
    /// page's own paper and colour, so existing coordinates and lines never move.
    public var writingSpaceExtendsPaper: Bool { pdfReference == nil && paper != nil && paper != .legacyTest }
    /// The stored form of `margins` on this page: paper pages keep their own
    /// style/colour; left/top writing space exists only beside PDFs.
    public func writingSpace(_ margins: PageMargins) throws -> PageMargins {
        try margins.validate()
        guard writingSpaceExtendsPaper else { return margins }
        guard let style = paper, margins.left == 0, margins.top == 0 else { throw StorageError.invalidDocument }
        var result = margins; result.style = style; result.color = paperColor ?? .white
        return result
    }
    /// Pen/marker/eraser widths are canonical page units. Scaling them with the
    /// base width keeps strokes equally thick relative to the sheet on wide PDFs
    /// and their writing margins as on a normal page.
    public var inkWidthScale: Double {
        max(0.1, (geometry?.displaySize.width ?? PageSize.a4.width) / PageSize.a4.width)
    }
    public func writingCoordinateScale(for box: TextBox) -> Double {
        box.flowID != nil && box.flowRegion != .page ? writingCoordinateScale : 1
    }
}

extension PageMargins {
    public static func normalPageBesidePDF(_ size: PageSize, style: PaperStyle = .blank, color: PaperColor = .dark) -> PageMargins {
        PageMargins(right: size.width, style: style, color: color)
    }
}
