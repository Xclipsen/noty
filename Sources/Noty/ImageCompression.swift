import Foundation
import ImageIO
import UniformTypeIdentifiers
import NotebookCore

/// Nutzer zu Build 51/52: Bilder über 5 MB werden verkleinert statt
/// abgelehnt. An image that fits is kept byte for byte (HEIC stays HEIC). A
/// larger one (or one beyond the pixel limit, or one that no longer fits the
/// notebook's image budget) is re-encoded from an oriented ImageIO thumbnail:
/// opaque images as JPEG, images with transparency as PNG, shrinking quality
/// first and then size until it fits `limit`.
enum ImageCompression {
    /// Largest file read for import before compressing; beyond this nothing is decoded.
    static let maximumSourceBytes = 250_000_000
    /// Longest side of a compressed image: sharp on the page, bounded decode memory.
    static let maximumSide = 4096
    /// Below this budget an image is not worth squeezing in.
    static let minimumBudget = 300_000
    /// Nutzer zu Build 52: every imported image at most 5 MB (large originals
    /// made dragging and saving lag). Validation still accepts 20 MB per image.
    static let importTargetBytes = 5_000_000

    struct Result: Sendable {
        let data: Data
        /// Original size when the image was re-encoded; nil when kept unchanged.
        let originalBytes: Int?
    }

    static func fitting(_ data: Data, limit: Int) throws -> Result {
        guard !data.isEmpty else { throw ImageImportError.invalid }
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int, width > 0, height > 0 else {
            throw ImageFileFormat.detect(data) == .video ? ImageImportError.video : ImageImportError.invalid
        }
        let pixelsFit = width <= ImageLimits.maximumSide && height <= ImageLimits.maximumSide
            && Double(width) * Double(height) <= ImageLimits.maximumPixels
        if data.count <= limit && pixelsFit { return Result(data: data, originalBytes: nil) }
        guard limit >= minimumBudget else { throw ImageImportError.fileTooLarge }

        let alpha = properties[kCGImagePropertyHasAlpha] as? Bool ?? false
        var side = min(max(width, height), maximumSide)
        var quality = 0.85
        for _ in 0..<12 {
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: side,
                kCGImageSourceShouldCacheImmediately: true
            ] as CFDictionary) else { throw ImageImportError.invalid }
            let encoded = try encode(image, png: alpha, quality: quality)
            if encoded.count <= limit { return Result(data: encoded, originalBytes: data.count) }
            if !alpha && quality > 0.6 { quality -= 0.1; continue }
            // Bytes grow roughly with the pixel count: shrink the side accordingly, at least by 10 %.
            let factor = min(0.9, max(0.5, (Double(limit) / Double(encoded.count)).squareRoot() * 0.95))
            side = Int(Double(side) * factor)
            guard side >= 256 else { break }
        }
        throw ImageImportError.fileTooLarge
    }

    private static func encode(_ image: CGImage, png: Bool, quality: Double) throws -> Data {
        let output = NSMutableData()
        let type = (png ? UTType.png : UTType.jpeg).identifier as CFString
        guard let destination = CGImageDestinationCreateWithData(output, type, 1, nil) else { throw ImageImportError.invalid }
        let options: [CFString: Any] = png ? [:] : [kCGImageDestinationLossyCompressionQuality: quality]
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ImageImportError.invalid }
        return output as Data
    }
}
