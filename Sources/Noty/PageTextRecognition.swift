// Vision-Texterkennung einer Seite, geteilt von der Inhaltssuche
// (ContentSearchView: Handschrift, Scan/Bild) und den Gesetzesverweisen in
// Handschrift (docs/PARAGRAPH-LINKS.md, P3). Nur abgeleitete Daten: gespeicherte
// Striche bleiben unverändert, nichts davon kommt ins Heft.
import UIKit
import PencilKit
import Vision
import NotebookCore

enum PageTextRecognition {
    /// One recognised line; `bounds` in Vision's normalised image space (origin bottom left).
    struct Line: Sendable { let text: String; let bounds: PageRect }

    /// Raster scale for OCR: at most 2400 pixels on the long side, at most 2×.
    nonisolated static func scale(_ layout: PageLayout) -> CGFloat {
        min(2, 2400 / max(layout.canvas.width, layout.canvas.height))
    }
    /// Normalised Vision rect of a page raster → canonical page coordinates.
    nonisolated static func canonical(_ rect: PageRect, _ layout: PageLayout) -> PageRect {
        .init(x: rect.x * layout.canvas.width - layout.contentOrigin.x,
              y: (1 - rect.y - rect.height) * layout.canvas.height - layout.contentOrigin.y,
              width: rect.width * layout.canvas.width, height: rect.height * layout.canvas.height)
    }

    /// The page's ink normalised to black on white, at `scale(layout)`. Stored
    /// strokes stay untouched. Runs off the main thread.
    nonisolated static func inkImage(_ data: Data, layout: PageLayout) throws -> CGImage {
        let drawing = try PKDrawing(data: data)
        let strokes = drawing.strokes.map { stroke in
            PKStroke(ink: PKInk(.pen, color: .black), path: stroke.path, transform: stroke.transform, mask: stroke.mask)
        }
        let pixelScale = scale(layout)
        let ink = PDFExporter.inkImage(PKDrawing(strokes: strokes), from: layout.canonicalInkBounds, scale: pixelScale)
        guard let image = PageRaster.bitmap(size: layout.canvas.cgSize, scale: pixelScale, opaque: true, { context in
            UIColor.white.setFill(); context.fill(layout.canvas.bounds)
            ink.draw(in: layout.canvas.bounds)
        }) else { throw ImageImportError.invalid }
        return image
    }

    /// The text request every caller uses (German/English, accurate, language correction).
    nonisolated static func observations(_ image: CGImage) throws -> [VNRecognizedTextObservation] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate; request.recognitionLanguages = ["de-DE", "en-US"]
        request.usesLanguageCorrection = true
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        return request.results ?? []
    }

    /// Top candidate of each recognised line.
    nonisolated static func recognize(_ image: CGImage) throws -> [Line] {
        try observations(image).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            return Line(text: candidate.string, bounds: PageRect(observation.boundingBox))
        }
    }
}
