import Foundation

extension Page {
    /// PDF source coordinates stay untouched. Body text in its writing margin
    /// uses normal-page units, independently of the source scan's point size.
    public var writingCoordinateScale: Double {
        margins == nil ? 1 : (geometry?.displaySize.width ?? PageSize.a4.width) / PageSize.a4.width
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
