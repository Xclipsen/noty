import UIKit
import PDFKit
import PencilKit
import NotebookCore

/// Snapshot export uses the same crop/rotation/legacy layout as the editor.
@MainActor
enum PDFExporter {
    static let pageBounds = CGRect(x: 0, y: 0, width: 595, height: 842)

    enum ExportError: LocalizedError {
        case invalidSource
        case textOverflow(Int)

        var errorDescription: String? {
            switch self {
            case .invalidSource: "Die PDF-Quelldatei konnte nicht gelesen werden."
            case .textOverflow(let page): "Ein Textfeld auf Seite \(page) hat zu wenig Platz. Bitte verschieben, verbreitern oder kürzen; es wurde keine PDF mit abgeschnittenem Text exportiert."
            }
        }
    }

    static func render(_ snapshot: Notebook, pageIDs: Set<UUID>? = nil) throws -> Data {
        guard pageIDs == nil || snapshot.pages.contains(where: { pageIDs!.contains($0.id) }) else { throw ExportError.invalidSource }
        for page in snapshot.pages {
            for image in page.images ?? [] { try ImageRendering.validate(image) }
        }
        let catalogue = try NotebookPDFCatalog(snapshot)
        let sourcePages = snapshot.pages.map { catalogue.sourcePage(for: $0)?.pageRef }

        // Validate every layer before writing the output snapshot.
        let drawings = try snapshot.pages.map { page in
            page.drawing.isEmpty ? PKDrawing() : try PKDrawing(data: page.drawing)
        }
        let layouts = try snapshot.pages.enumerated().map { index, page in
            try PageLayout(page: page, source: sourcePages[index])
        }
        var textLayouts: [[TextObjectLayout]] = []
        for (index, page) in snapshot.pages.enumerated() {
            if let pageIDs, !pageIDs.contains(page.id) { textLayouts.append([]); continue }
            var boxes: [TextObjectLayout] = []
            let bounds = layouts[index].canonicalInkBounds
            for box in page.effectiveTextBoxes {
                let layout = TextObjectLayout(box)
                if layout.usedHeight > box.height + 0.5 || !bounds.insetBy(dx: -0.01, dy: -0.01).contains(box.rect.cgRect) {
                    throw ExportError.textOverflow(index + 1)
                }
                boxes.append(layout)
            }
            textLayouts.append(boxes)
        }

        let renderer = UIGraphicsPDFRenderer(bounds: pageBounds)
        var imageError: Error?
        let data = renderer.pdfData { output in
            for (index, page) in snapshot.pages.enumerated() {
                if let pageIDs, !pageIDs.contains(page.id) { continue }
                let layout = layouts[index]
                let bounds = layout.canvas.bounds
                output.beginPage(withBounds: bounds, pageInfo: [:])
                let context = output.cgContext
                drawPaper(style: page.margins?.style ?? page.paper ?? .blank, bounds: bounds,
                          color: page.margins?.color ?? page.paperColor ?? .white)
                if let sourcePage = sourcePages[index] {
                    UIColor.white.setFill(); context.fill(layout.sourceFrame.cgRect)
                    context.saveGState()
                    context.clip(to: layout.sourceFrame.cgRect)
                    context.concatenate(layout.pdfToCanvas.cgTransform)
                    context.drawPDFPage(sourcePage)
                    context.restoreGState()
                } else if page.paper == nil { drawPaper(style: .legacyTest, bounds: bounds) }

                for image in page.images ?? [] {
                    autoreleasepool {
                        do { try ImageRendering.draw(image, context: context, origin: layout.contentOrigin, limit: 4096) }
                        catch { imageError = error }
                    }
                }

                // Explicitly compose the drawing layer; UIView overlays do not export themselves.
                if !page.drawing.isEmpty {
                    // Bound the temporary raster for unusually large PDF pages.
                    let scale = min(2, 4096 / max(bounds.width, bounds.height))
                    drawings[index].image(from: layout.canonicalInkBounds, scale: scale).draw(in: bounds)
                }
                for (box, textLayout) in zip(page.effectiveTextBoxes, textLayouts[index]) {
                    let origin = CGPoint(x: box.x + layout.contentOrigin.x, y: box.y + layout.contentOrigin.y)
                    textLayout.draw(at: origin)
                    for (url, rect) in textLayout.links(at: origin) { output.setURL(url, for: rect) }
                }
                ShapeRendering.draw(page.shapes ?? [], origin: layout.contentOrigin, context: context)
            }
        }
        if let imageError { throw imageError }
        return data
    }

    static func testPDF() -> PDFDocument {
        paperPDF(style: .legacyTest, size: .a4)
    }

    static func paperPDF(style: PaperStyle, size: PageSize, color: PaperColor = .white) -> PDFDocument {
        let data = UIGraphicsPDFRenderer(bounds: size.bounds).pdfData { output in
            output.beginPage()
            drawPaper(style: style, bounds: size.bounds, color: color)
        }
        return PDFDocument(data: data)!
    }

    static func drawPaper(style: PaperStyle, bounds: CGRect, color: PaperColor = .white) {
        (color == .dark ? UIColor(white: 0.12, alpha: 1) : .white).setFill(); UIRectFill(bounds)
        guard style != .blank else { return }
        if style == .legacyTest { drawTestPaper(); return }
        let path = UIBezierPath()
        let spacing: CGFloat = style == .lined ? 24 : 16
        for y in stride(from: CGFloat(40), through: bounds.height - 40, by: spacing) {
            path.move(to: CGPoint(x: 32, y: y)); path.addLine(to: CGPoint(x: bounds.width - 32, y: y))
        }
        if style == .grid {
            for x in stride(from: CGFloat(32), through: bounds.width - 32, by: spacing) {
                path.move(to: CGPoint(x: x, y: 40)); path.addLine(to: CGPoint(x: x, y: bounds.height - 40))
            }
        }
        UIColor(white: color == .dark ? 0.3 : 0.8, alpha: 1).setStroke(); path.lineWidth = 0.5; path.stroke()
    }

    private static func drawTestPaper() {
        ("noty · Schreibprobe" as NSString).draw(at: CGPoint(x: 48, y: 40), withAttributes: [
            .font: UIFont.boldSystemFont(ofSize: 24), .foregroundColor: UIColor.black
        ])
        ("Pencil oben ausprobieren · Textfeld unten antippen im Textmodus" as NSString).draw(
            at: CGPoint(x: 48, y: 82), withAttributes: [.font: UIFont.systemFont(ofSize: 13)])
        let path = UIBezierPath()
        for y in stride(from: 130, through: 610, by: 24) {
            path.move(to: CGPoint(x: 48, y: y))
            path.addLine(to: CGPoint(x: 547, y: y))
        }
        UIColor.lightGray.setStroke()
        path.lineWidth = 0.5
        path.stroke()
    }
}
