import SwiftUI
import PDFKit
import PencilKit
import NotebookCore

/// Snapshot export uses the same crop/rotation/legacy layout as the editor.
/// Every layer is composed explicitly (`Page.exportLayers`): paper, source PDF
/// (vector, text stays searchable), images, shapes, ink raster, typed text
/// (real PDF text) and links.
///
/// Page content is drawn only inside pages begun by UIKit's own PDF renderer,
/// as up to Build 46. Build 47–49 drew it into a self-made Core Graphics PDF
/// context (`UIGraphicsPushContext` plus a manual flip); on the iPad those
/// exports lost all images and typed text while the paper remained.
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

    /// One finished page: a single-page PDF from UIKit's renderer plus its link
    /// rectangles (UIKit page space; `drawPDFPage` does not carry annotations).
    private struct RenderedPage {
        let document: CGPDFDocument
        let page: CGPDFPage
        let bounds: CGRect
        let links: [(URL, CGRect)]
    }

    /// Page by page: heavy decoding runs off the main actor and the UI gets a
    /// turn between pages. Only the exported pages are decoded. Each page is
    /// rendered on its own by UIKit's PDF renderer; the finished pages are then
    /// placed unchanged (vectors, text, images) into one document. `sourcePage`
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

        var rendered: [RenderedPage] = []
        for (position, (_, page)) in selected.enumerated() {
            try Task.checkCancellation()
            progress(position, selected.count)
            let layout = layouts[position]
            let assets = try await Task.detached(priority: .userInitiated) { try Self.assets(page, layout: layout) }.value
            try Task.checkCancellation()
            rendered.append(try autoreleasepool { try render(page, layout: layout, source: sources[position], assets: assets) })
            await Task.yield()
        }
        try Task.checkCancellation()
        let data = assemble(rendered, title: snapshot.title)
        withExtendedLifetime((documents, catalogue)) {}
        guard let check = CGDataProvider(data: data as CFData).flatMap(CGPDFDocument.init),
              check.numberOfPages == rendered.count else { throw ExportError.writeFailed }
        progress(selected.count, selected.count)
        return data
    }

    /// The page in its own single-page PDF, drawn by UIKit's renderer.
    private static func render(_ page: Page, layout: PageLayout, source: CGPDFPage?, assets: PageAssets) throws -> RenderedPage {
        let bounds = layout.canvas.bounds
        var links: [(URL, CGRect)] = []
        let data = UIGraphicsPDFRenderer(bounds: bounds).pdfData { output in
            links = drawPage(page, layout: layout, source: source, assets: assets, in: output)
        }
        guard let document = CGDataProvider(data: data as CFData).flatMap(CGPDFDocument.init),
              document.numberOfPages == 1, let pdfPage = document.page(at: 1) else { throw ExportError.writeFailed }
        return RenderedPage(document: document, page: pdfPage, bounds: bounds, links: links)
    }

    /// The finished pages, unchanged and in order, in one document (again via
    /// UIKit's renderer). Links are set anew because a placed page has none.
    private static func assemble(_ pages: [RenderedPage], title: String) -> Data {
        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = [kCGPDFContextTitle as String: title, kCGPDFContextCreator as String: "noty"]
        return UIGraphicsPDFRenderer(bounds: pageBounds, format: format).pdfData { output in
            for rendered in pages {
                output.beginPage(withBounds: rendered.bounds, pageInfo: [:])
                let context = output.cgContext
                context.saveGState()
                // From UIKit's y-down page space back to the page's own PDF space.
                context.translateBy(x: 0, y: rendered.bounds.height); context.scaleBy(x: 1, y: -1)
                context.drawPDFPage(rendered.page)
                context.restoreGState()
                for (url, rect) in rendered.links { output.setURL(url, for: rect) }
            }
        }
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

    /// The one place page content is drawn for export: a page begun here in
    /// UIKit's own PDF renderer (y-down page space), then every layer of
    /// `Page.exportLayers` in order. Returns the link rectangles.
    private static func drawPage(_ page: Page, layout: PageLayout, source: CGPDFPage?, assets: PageAssets,
                                 in output: UIGraphicsPDFRendererContext) -> [(URL, CGRect)] {
        let bounds = layout.canvas.bounds
        output.beginPage(withBounds: bounds, pageInfo: [:])
        let context = output.cgContext
        var links: [(URL, CGRect)] = []
        for layer in page.exportLayers(hasSource: source != nil) {
            switch layer {
            case .paper(let style, let color, let scale):
                drawPaper(style: style, bounds: bounds, color: color, coordinateScale: scale)
            case .sourcePDF:
                guard let source else { continue }
                UIColor.white.setFill(); context.fill(layout.sourceFrame.cgRect)
                PageRaster.drawSource(source, layout: layout, context: context)
            case .testPaper:
                drawPaper(style: .legacyTest, bounds: bounds)
            case .images:
                for (object, image) in zip(page.images ?? [], assets.images) {
                    ImageRendering.draw(object, image: image, context: context, origin: layout.contentOrigin)
                }
            case .shapes:
                ShapeRendering.draw(page.shapes ?? [], origin: layout.contentOrigin, context: context)
            case .ink:
                // UIView overlays do not export themselves: the stored drawing as raster.
                assets.ink?.draw(in: bounds)
            case .text:
                for box in page.resolvedTextBoxes {
                    let text = TextObjectLayout(box, on: page)
                    let origin = CGPoint(x: box.x + layout.contentOrigin.x, y: box.y + layout.contentOrigin.y)
                    text.draw(at: origin)
                    links += text.links(at: origin)
                }
            }
        }
        return links
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

    nonisolated static func drawPaper(style: PaperStyle, bounds: CGRect, color: PaperColor = .white, coordinateScale: CGFloat = 1) {
        (color == .dark ? UIColor.black : .white).setFill(); UIRectFill(bounds)
        guard style != .blank else { return }
        if style == .legacyTest { drawTestPaper(); return }
        let path = UIBezierPath()
        let spacing: CGFloat = (style == .lined ? PaperRuling.spacing : 16) * coordinateScale
        let bottomInset: CGFloat = (style == .lined ? 16 : 40) * coordinateScale
        for y in stride(from: CGFloat(PaperRuling.firstBaseline) * coordinateScale, through: bounds.height - bottomInset, by: spacing) {
            path.move(to: CGPoint(x: 32 * coordinateScale, y: y)); path.addLine(to: CGPoint(x: bounds.width - 32 * coordinateScale, y: y))
        }
        if style == .grid {
            for x in stride(from: CGFloat(32) * coordinateScale, through: bounds.width - 32 * coordinateScale, by: spacing) {
                path.move(to: CGPoint(x: x, y: 40 * coordinateScale)); path.addLine(to: CGPoint(x: x, y: bounds.height - 40 * coordinateScale))
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
