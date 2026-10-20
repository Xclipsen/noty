import UIKit
import NotebookCore

/// A CGPDFPage handed to a background task. The caller keeps its owning
/// PDFDocument/CGPDFDocument alive until the task has finished (same pattern as
/// `PDFSourceRasterView`).
struct SendablePDFPage: @unchecked Sendable { let page: CGPDFPage }

/// Off-main rasterisation in the canonical y-down canvas space shared with the
/// editor, previews and export (`sourceFrame`, `pdfToCanvas`, `contentOrigin`).
/// UIKit string/image/path drawing is thread-safe in a context pushed on the
/// current thread; PDFKit objects themselves stay on the main actor.
enum PageRaster {
    /// Bitmap of `size` points at `scale` pixels per point; `draw` runs with the
    /// context pushed as the current UIKit context.
    static func bitmap(size: CGSize, scale: CGFloat, opaque: Bool, _ draw: (CGContext) throws -> Void) rethrows -> CGImage? {
        let width = max(1, Int(ceil(size.width * scale))), height = max(1, Int(ceil(size.height * scale)))
        let alpha = opaque ? CGImageAlphaInfo.noneSkipFirst : .premultipliedFirst
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: alpha.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)
        context.interpolationQuality = .high
        UIGraphicsPushContext(context)
        defer { UIGraphicsPopContext() }
        try draw(context)
        return context.makeImage()
    }

    /// The PDF source exactly as in the export: clipped to `sourceFrame`, then `pdfToCanvas`.
    static func drawSource(_ page: CGPDFPage, layout: PageLayout, context: CGContext) {
        context.saveGState()
        context.clip(to: layout.sourceFrame.cgRect)
        context.concatenate(layout.pdfToCanvas.cgTransform)
        context.drawPDFPage(page)
        context.restoreGState()
    }
}
