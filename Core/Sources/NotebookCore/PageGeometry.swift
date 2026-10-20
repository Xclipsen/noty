import Foundation

public struct PagePoint: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
}

public struct PageSize: Codable, Equatable, Sendable {
    public var width: Double
    public var height: Double
    public init(width: Double, height: Double) { self.width = width; self.height = height }
    public static let a4 = PageSize(width: 595, height: 842)
}

public struct PageRect: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
    public var size: PageSize { PageSize(width: width, height: height) }
}

public struct PageTransform: Equatable, Sendable {
    public let a: Double
    public let b: Double
    public let c: Double
    public let d: Double
    public let tx: Double
    public let ty: Double

    public func apply(_ point: PagePoint) -> PagePoint {
        PagePoint(x: a * point.x + c * point.y + tx,
                  y: b * point.x + d * point.y + ty)
    }

    public var inverse: PageTransform {
        let determinant = a * d - b * c
        return PageTransform(a: d / determinant, b: -b / determinant,
                             c: -c / determinant, d: a / determinant,
                             tx: (c * ty - d * tx) / determinant,
                             ty: (b * tx - a * ty) / determinant)
    }
}

/// PDF coordinates: unrotated, bottom-left origin. Canvas: displayed crop,
/// top-left origin, in PDF points. Rotation is the PDF's clockwise /Rotate.
public struct PDFPageGeometry: Codable, Equatable, Sendable {
    public let mediaBox: PageRect
    public let cropBox: PageRect
    public let rotation: Int

    public init(mediaBox: PageRect, cropBox: PageRect, rotation: Int) throws {
        self.mediaBox = mediaBox
        self.cropBox = cropBox
        self.rotation = ((rotation % 360) + 360) % 360
        try validate()
    }

    public func validate() throws {
        for box in [mediaBox, cropBox] {
            guard [box.x, box.y, box.width, box.height].allSatisfy(\.isFinite),
                  box.width > 0, box.height > 0 else { throw StorageError.invalidDocument }
        }
        let size = effectiveCrop.size
        guard [0, 90, 180, 270].contains(rotation),
              size.width >= 1, size.height >= 1,
              size.width <= 14_400, size.height <= 14_400 else { throw StorageError.invalidDocument }
    }

    public var effectiveCrop: PageRect {
        let x = max(mediaBox.x, cropBox.x)
        let y = max(mediaBox.y, cropBox.y)
        return PageRect(x: x, y: y,
                        width: min(mediaBox.x + mediaBox.width, cropBox.x + cropBox.width) - x,
                        height: min(mediaBox.y + mediaBox.height, cropBox.y + cropBox.height) - y)
    }

    public var displaySize: PageSize {
        let crop = effectiveCrop
        return rotation == 90 || rotation == 270
            ? PageSize(width: crop.height, height: crop.width) : crop.size
    }

    public var pdfToPage: PageTransform {
        let r = effectiveCrop
        return switch rotation {
        case 90: PageTransform(a: 0, b: 1, c: 1, d: 0, tx: -r.y, ty: -r.x)
        case 180: PageTransform(a: -1, b: 0, c: 0, d: 1, tx: r.x + r.width, ty: -r.y)
        case 270: PageTransform(a: 0, b: -1, c: -1, d: 0, tx: r.y + r.height, ty: r.x + r.width)
        default: PageTransform(a: 1, b: 0, c: 0, d: -1, tx: -r.x, ty: r.y + r.height)
        }
    }
}

/// Legacy pages retain A4 canvases. The source is aspect-fitted, never the ink.
/// New imports use the displayed PDF crop size as their canvas size.
public struct PageLayout: Equatable, Sendable {
    public let legacyA4: Bool
    public let canvas: PageSize
    public let contentCanvas: PageSize
    public let contentOrigin: PagePoint
    public let sourceFrame: PageRect
    public let pdfToCanvas: PageTransform
    public let writingCoordinateScale: Double

    /// `extendsPaper`: writing space continuing a paper sheet (`Page.writingSpaceExtendsPaper`).
    public init(source: PDFPageGeometry, legacyA4: Bool, margins: PageMargins? = nil, extendsPaper: Bool = false) {
        self.legacyA4 = legacyA4
        let size = source.displaySize
        contentCanvas = legacyA4 ? .a4 : size
        writingCoordinateScale = margins == nil || extendsPaper ? 1 : contentCanvas.width / PageSize.a4.width
        contentOrigin = PagePoint(x: margins?.left ?? 0, y: margins?.top ?? 0)
        canvas = PageSize(width: contentCanvas.width + contentOrigin.x + (margins?.right ?? 0),
                          height: contentCanvas.height + contentOrigin.y + (margins?.bottom ?? 0))
        let scale = min(contentCanvas.width / size.width, contentCanvas.height / size.height)
        let x = (contentCanvas.width - size.width * scale) / 2 + contentOrigin.x
        let y = (contentCanvas.height - size.height * scale) / 2 + contentOrigin.y
        sourceFrame = PageRect(x: x, y: y, width: size.width * scale, height: size.height * scale)
        let t = source.pdfToPage
        pdfToCanvas = PageTransform(a: scale * t.a, b: scale * t.b,
                                   c: scale * t.c, d: scale * t.d,
                                   tx: scale * t.tx + x, ty: scale * t.ty + y)
    }
}
