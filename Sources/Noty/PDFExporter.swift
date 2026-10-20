import SwiftUI
import PDFKit
import PencilKit
import NotebookCore

/// Snapshot export uses the same crop/rotation/legacy layout as the editor.
/// Every layer is composed explicitly: paper, source PDF (vector, text stays
/// searchable), images, shapes, ink raster, typed text (real PDF text) and links.
@MainActor
enum PDFExporter {
    static let pageBounds = CGRect(x: 0, y: 0, width: 595, height: 842)

    enum ExportError: LocalizedError {
        case invalidSource
        case textOverflow([Int])
        case writeFailed

        var errorDescription: String? {
            switch self {
            case .invalidSource: return "Die PDF-Quelldatei konnte nicht gelesen werden."
            case .textOverflow(let pages):
                let list = pages.prefix(12).map(String.init).joined(separator: ", ") + (pages.count > 12 ? " …" : "")
                return "\(pages.count == 1 ? "Ein Textfeld auf Seite" : "Textfelder auf den Seiten") \(list) \(pages.count == 1 ? "hat" : "haben") zu wenig Platz. Bitte verschieben, verbreitern oder kürzen; es wurde keine PDF mit abgeschnittenem Text exportiert."
            case .writeFailed: return "Die PDF-Datei konnte nicht erstellt werden."
            }
        }
    }

    /// Decoded off the main actor, drawn on it.
    private struct PageAssets: Sendable {
        let images: [UIImage]
        let ink: UIImage?
    }

    /// Page by page: heavy decoding runs off the main actor and the UI gets a
    /// turn between pages. Only the exported pages are decoded. `sourcePage`
    /// reuses the editor's PDF catalogue; without it the PDFs are parsed here.
    /// Nothing is returned unless every selected page was validated and written.
    static func export(_ snapshot: Notebook, pageIDs: Set<UUID>? = nil, sourcePage: ((Page) -> PDFPage?)? = nil,
                       progress: (Int, Int) -> Void = { _, _ in }) async throws -> Data {
        let selected = snapshot.pages.enumerated().filter { pageIDs?.contains($0.element.id) ?? true }
        guard !selected.isEmpty else { throw ExportError.invalidSource }
        let catalogue = sourcePage == nil ? try NotebookPDFCatalog(snapshot) : nil
        // Resolved once: a later catalogue swap in the editor cannot change them.
        let sources: [CGPDFPage?] = try selected.map { _, page in
            let pdf = sourcePage?(page) ?? catalogue?.sourcePage(for: page)
            if page.pdfReference != nil || snapshot.pdf != nil { guard let ref = pdf?.pageRef else { throw ExportError.invalidSource }; return ref }
            return nil
        }
        let documents = selected.map { sourcePage?($0.element)?.document ?? catalogue?.sourcePage(for: $0.element)?.document }

        // Validate every selected page before writing anything; overflow is never cut.
        var layouts: [PageLayout] = [], overflow: [Int] = []
        for (position, (index, page)) in selected.enumerated() {
            for image in page.images ?? [] { try ImageRendering.validate(image) }
            let layout = try PageLayout(page: page, source: sources[position])
            let bounds = layout.canonicalInkBounds.insetBy(dx: -0.01, dy: -0.01)
            if page.resolvedTextBoxes.contains(where: { box in
                TextObjectLayout(box, on: page).usedHeight > box.height + 0.5 || !bounds.contains(box.rect.cgRect)
            }) { overflow.append(index + 1) }
            layouts.append(layout)
            if position % 16 == 15 { await Task.yield(); try Task.checkCancellation() }
        }
        guard overflow.isEmpty else { throw ExportError.textOverflow(overflow) }

        let data = NSMutableData()
        var media = pageBounds
        let info = [kCGPDFContextTitle as String: snapshot.title, kCGPDFContextCreator as String: "noty"] as CFDictionary
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &media, info) else { throw ExportError.writeFailed }
        var closed = false
        defer { if !closed { context.closePDF() } }
        for (position, (_, page)) in selected.enumerated() {
            try Task.checkCancellation()
            progress(position, selected.count)
            let layout = layouts[position]
            let assets = try await Task.detached(priority: .userInitiated) { try Self.assets(page, layout: layout) }.value
            try Task.checkCancellation()
            var box = layout.canvas.bounds
            context.beginPDFPage([kCGPDFContextMediaBox as String: Data(bytes: &box, count: MemoryLayout<CGRect>.size)] as CFDictionary)
            // UIKit's y-down page space, as UIGraphicsPDFRenderer sets it up.
            context.saveGState()
            context.translateBy(x: 0, y: box.height); context.scaleBy(x: 1, y: -1)
            UIGraphicsPushContext(context)
            autoreleasepool { draw(page, layout: layout, source: sources[position], assets: assets, context: context) }
            UIGraphicsPopContext()
            context.restoreGState()
            context.endPDFPage()
            withExtendedLifetime(documents[position]) {}
            await Task.yield()
        }
        context.closePDF(); closed = true
        withExtendedLifetime(catalogue) {}
        progress(selected.count, selected.count)
        return data as Data
    }

    nonisolated private static func assets(_ page: Page, layout: PageLayout) throws -> PageAssets {
        let images = try (page.images ?? []).map { try ImageRendering.decoded($0, limit: 4096) }
        guard !page.drawing.isEmpty else { return PageAssets(images: images, ink: nil) }
        let drawing = try PKDrawing(data: page.drawing)
        // Bound the temporary raster for unusually large PDF pages.
        let bounds = layout.canvas.bounds
        let scale = min(2, 4096 / max(bounds.width, bounds.height))
        // Stored ink colours as written (light style), never adapted to the dark app UI.
        return PageAssets(images: images, ink: inkImage(drawing, from: layout.canonicalInkBounds, scale: scale))
    }

    private static func draw(_ page: Page, layout: PageLayout, source: CGPDFPage?, assets: PageAssets, context: CGContext) {
        let bounds = layout.canvas.bounds
        drawPaper(style: page.margins?.style ?? page.paper ?? .blank, bounds: bounds,
                  color: page.margins?.color ?? page.paperColor ?? .white, coordinateScale: page.writingCoordinateScale,
                  columns: source == nil ? nil : layout.ruledColumnsBesidePDF)
        if let source {
            UIColor.white.setFill(); context.fill(layout.sourceFrame.cgRect)
            PageRaster.drawSource(source, layout: layout, context: context)
        } else if page.paper == nil { drawPaper(style: .legacyTest, bounds: bounds) }
        for (object, image) in zip(page.images ?? [], assets.images) {
            ImageRendering.draw(object, image: image, context: context, origin: layout.contentOrigin)
        }
        ShapeRendering.draw(page.shapes ?? [], origin: layout.contentOrigin, context: context)
        // Explicitly compose the drawing layer; UIView overlays do not export themselves.
        assets.ink?.draw(in: bounds)
        for box in page.resolvedTextBoxes {
            let text = TextObjectLayout(box, on: page)
            let origin = CGPoint(x: box.x + layout.contentOrigin.x, y: box.y + layout.contentOrigin.y)
            text.draw(at: origin)
            for (url, rect) in text.links(at: origin) { UIGraphicsSetPDFContextURLForRect(url, rect) }
        }
    }

    /// PencilKit adapts ink to the current trait collection: under the app's
    /// dark UI black ink would render white. The editor canvas is light, so
    /// previews and exports render light as well (what you see is exported).
    /// Off-main safe: the trait collection is thread-local (PencilKit's own
    /// thumbnail sample renders drawings on a background queue).
    nonisolated static func inkImage(_ drawing: PKDrawing, from rect: CGRect, scale: CGFloat) -> UIImage {
        var image = UIImage()
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            image = drawing.image(from: rect, scale: scale)
        }
        return image
    }

    static func paperPDF(style: PaperStyle, size: PageSize, color: PaperColor = .white) -> PDFDocument {
        let data = UIGraphicsPDFRenderer(bounds: size.bounds).pdfData { output in
            output.beginPage()
            drawPaper(style: style, bounds: size.bounds, color: color)
        }
        return PDFDocument(data: data)!
    }

    /// `columns`: x bands ruled separately, each with the 32-pt side inset
    /// (`PageLayout.ruledColumnsBesidePDF`); nil rules the whole width.
    nonisolated static func drawPaper(style: PaperStyle, bounds: CGRect, color: PaperColor = .white, coordinateScale: CGFloat = 1,
                                      columns: [ClosedRange<Double>]? = nil) {
        (color == .dark ? UIColor.black : .white).setFill(); UIRectFill(bounds)
        guard style != .blank else { return }
        if style == .legacyTest { drawTestPaper(); return }
        let path = UIBezierPath()
        let spacing: CGFloat = (style == .lined ? PaperRuling.spacing : 16) * coordinateScale
        let bottomInset: CGFloat = (style == .lined ? 16 : 40) * coordinateScale
        let inset = 32 * coordinateScale
        for column in columns ?? [0...Double(bounds.width)] {
            let from = CGFloat(column.lowerBound) + inset, to = CGFloat(column.upperBound) - inset
            guard to - from >= 8 * coordinateScale else { continue }
            for y in stride(from: CGFloat(PaperRuling.firstBaseline) * coordinateScale, through: bounds.height - bottomInset, by: spacing) {
                path.move(to: CGPoint(x: from, y: y)); path.addLine(to: CGPoint(x: to, y: y))
            }
            if style == .grid {
                for x in stride(from: from, through: to, by: spacing) {
                    path.move(to: CGPoint(x: x, y: 40 * coordinateScale)); path.addLine(to: CGPoint(x: x, y: bounds.height - 40 * coordinateScale))
                }
            }
        }
        UIColor(white: color == .dark ? 0.3 : 0.8, alpha: 1).setStroke(); path.lineWidth = 0.5 * coordinateScale; path.stroke()
    }

    nonisolated private static func drawTestPaper() {
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

/// One running PDF export per editor: a small non-modal progress badge with
/// cancel. The notebook snapshot is fixed when the export starts.
@MainActor
final class PDFExportJob: ObservableObject {
    struct Progress: Equatable { var done: Int; var total: Int }
    @Published private(set) var progress: Progress?
    /// Only touched on the main actor; read once more when the owning editor goes away.
    nonisolated(unsafe) private var task: Task<Void, Never>?
    var running: Bool { task != nil }
    deinit { task?.cancel() }

    func start(_ snapshot: Notebook, pageIDs: Set<UUID>? = nil, sourcePage: ((Page) -> PDFPage?)? = nil,
               completion: @escaping (Result<Data, Error>) -> Void) {
        guard task == nil else { return }
        progress = Progress(done: 0, total: pageIDs.map { ids in snapshot.pages.filter { ids.contains($0.id) }.count } ?? snapshot.pages.count)
        // Weak: a closed editor releases the job, whose deinit cancels the export.
        task = Task { [weak self] in
            let result: Result<Data, Error>
            do {
                result = .success(try await PDFExporter.export(snapshot, pageIDs: pageIDs, sourcePage: sourcePage) { done, total in
                    self?.progress = Progress(done: done, total: total)
                })
            } catch { result = .failure(error) }
            guard let self else { return }
            self.task = nil; self.progress = nil
            completion(result)
        }
    }
    func cancel() { task?.cancel() }
}

struct PDFExportProgressBadge: View {
    @ObservedObject var job: PDFExportJob
    var body: some View {
        if let progress = job.progress {
            HStack(spacing: 12) {
                ProgressView(value: Double(progress.done), total: Double(max(1, progress.total))).frame(width: 110)
                Text("PDF wird erstellt · \(min(progress.done + 1, progress.total)) von \(progress.total)")
                    .font(.caption).monospacedDigit()
                Button("Abbrechen") { job.cancel() }.font(.caption.weight(.semibold))
            }
            .padding(.horizontal, 14).padding(.vertical, 8).notyGlass()
            .transition(.opacity)
        }
    }
}
