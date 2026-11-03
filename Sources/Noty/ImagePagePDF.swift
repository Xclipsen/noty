import CoreGraphics
import Foundation
import ImageIO
import NotebookCore
import UniformTypeIdentifiers

/// A picture imported like a PDF: a page of its own with writing space beside
/// it (Nutzer zu Build 81). It becomes a one-page PDF and takes the PDF's way
/// through import, storage, preview, backup and export; the format stays as
/// it is. A normal page wide, so that text and ink have normal-page sizes.
enum ImagePagePDF {
    private static let longestSide = 4096
    private static let pageWidth: CGFloat = 595
    /// PDF's own page limit: a very long screenshot gets a narrower page.
    private static let longestPage: CGFloat = 14_400

    nonisolated static func isPDF(_ data: Data) -> Bool {
        data.prefix(1024).range(of: Data("%PDF-".utf8)) != nil
    }

    nonisolated static func pdf(from data: Data) throws -> Data {
        guard let format = ImageFileFormat.detect(data), format != .video,
              let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0 else {
            throw ImageImportError.invalid
        }
        // Upright like in Photos; the size is capped, never enlarged.
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceShouldCacheImmediately: true,
                                        kCGImageSourceThumbnailMaxPixelSize: longestSide]
        guard let decoded = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              decoded.width > 0, decoded.height > 0 else { throw ImageImportError.invalid }
        // Screenshots stay sharp; a photo would grow many times over without JPEG.
        // JPEG has no transparency: what is see-through would turn black.
        let opaque = [.none, .noneSkipFirst, .noneSkipLast].contains(decoded.alphaInfo)
        let image = [.png, .tiff, .bmp, .gif].contains(format) || !opaque ? decoded : (compressed(decoded) ?? decoded)
        let proportion = CGFloat(decoded.height) / CGFloat(decoded.width)
        let width = min(pageWidth, longestPage / proportion)
        var page = CGRect(x: 0, y: 0, width: width, height: min(longestPage, max(1, (width * proportion).rounded())))
        let output = NSMutableData()
        guard let consumer = CGDataConsumer(data: output),
              let context = CGContext(consumer: consumer, mediaBox: &page, nil) else { throw ImageImportError.invalid }
        context.beginPDFPage(nil)
        // Under transparent parts, as on paper.
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(page)
        context.interpolationQuality = .high
        context.draw(image, in: page)
        context.endPDFPage()
        context.closePDF()
        guard output.length <= PDFSource.maximumBytes else { throw ImageImportError.fileTooLarge }
        return output as Data
    }

    /// Kept as JPEG data: the PDF context embeds it without decoding it again.
    private nonisolated static func compressed(_ image: CGImage) -> CGImage? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(destination), let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
