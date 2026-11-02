import SwiftUI
import PDFKit
import PencilKit
import NotebookCore

/// Shared by the page sidebar, page trash and margin previews. Cached content is tied
/// to a page snapshot (validated by full content equality, not by position).
/// Paper, PDF, images and ink are rasterised off the main actor; shapes and
/// typed text (TextKit on the main actor) are composed on top here.
@MainActor
final class PageThumbnailCache: ObservableObject {
    private final class Entry {
        let page: Page
        let image: UIImage
        init(page: Page, image: UIImage) { self.page = page; self.image = image }
    }
    private let images = NSCache<NSString, Entry>()
    /// Entries share their page data with the open notebook; cost counts pixels,
    /// ink and text (image originals are the notebook's immutable bytes).
    init() { images.countLimit = 160; images.totalCostLimit = 40 * 1024 * 1024 }

    func cached(_ page: Page) -> UIImage? {
        guard let entry = images.object(forKey: page.id.uuidString as NSString), entry.page == page else { return nil }
        return entry.image
    }

    /// `keepAlive`: owner of `source` (its PDF document) while it is drawn off-main.
    func image(page: Page, source: CGPDFPage?, keepAlive: AnyObject? = nil) async throws -> UIImage {
        if let hit = cached(page) { return hit }
        let image = try await Self.render(page, source: source.map { .page($0) } ?? .none)
        withExtendedLifetime(keepAlive) {}
        images.setObject(Entry(page: page, image: image), forKey: page.id.uuidString as NSString,
                         cost: Int(image.size.width * image.size.height * 4) + page.drawing.count + page.searchableText.utf8.count)
        return image
    }

    enum Source: @unchecked Sendable {
        case none
        case page(CGPDFPage)
        /// Parsed off the main actor (library tiles): bytes plus zero-based page index.
        case data(Data, Int)
    }
    private struct Parts: Sendable {
        let layout: PageLayout
        let scale: CGFloat
        let base: UIImage
        let ink: UIImage?
    }
    /// At most two background renders: a scrolled grid must not flood the CPU.
    private static let gate = RenderGate(limit: 2)

    /// `longestSide`: pixel size of the longer edge (sidebar 224; larger for
    /// the „Seite anpassen“ preview).
    /// `assets`: where image originals are read (nil: the registry of open packages).
    static func render(_ page: Page, source: Source, longestSide: CGFloat = 224,
                       assets: ImageAssetProviding? = nil) async throws -> UIImage {
        await gate.acquire()
        let parts: Parts
        do {
            try Task.checkCancellation()
            parts = try await Task.detached(priority: .utility) { try Self.parts(page, source: source, longestSide: longestSide, assets: assets) }.value
        } catch { await gate.release(); throw error }
        await gate.release()
        try Task.checkCancellation()
        return compose(page, parts)
    }

    nonisolated private static func parts(_ page: Page, source: Source, longestSide: CGFloat,
                                          assets: ImageAssetProviding?) throws -> Parts {
        var document: CGPDFDocument?
        let pdf: CGPDFPage?
        switch source {
        case .none: pdf = nil
        case .page(let value): pdf = value
        case .data(let data, let index):
            document = CGDataProvider(data: data as CFData).flatMap(CGPDFDocument.init)
            pdf = document?.page(at: index + 1)
        }
        defer { withExtendedLifetime(document) {} }
        let layout = try PageLayout(page: page, source: pdf)
        let bounds = layout.canvas.bounds
        let scale = longestSide / max(bounds.width, bounds.height)
        let decoded = try (page.images ?? []).map { try ImageRendering.decoded($0, limit: Int(max(256, longestSide)), assets: assets) }
        guard let base = PageRaster.bitmap(size: bounds.size, scale: scale, opaque: true, { context in
            PDFExporter.drawPaper(style: page.margins?.style ?? page.paper ?? (pdf == nil ? .legacyTest : .blank),
                                  bounds: bounds, color: page.margins?.color ?? page.paperColor ?? .white, coordinateScale: page.writingCoordinateScale,
                                  columns: pdf == nil ? nil : layout.ruledColumnsBesidePDF)
            if let pdf {
                // Transparent PDFs retain white paper against dark note margins.
                UIColor.white.setFill(); context.fill(layout.sourceFrame.cgRect)
                PageRaster.drawSource(pdf, layout: layout, context: context)
            }
            for (object, image) in zip(page.images ?? [], decoded) {
                ImageRendering.draw(object, image: image, context: context, origin: layout.contentOrigin)
            }
        }) else { throw ImageImportError.invalid }
        let ink = page.drawing.isEmpty ? nil
            : PDFExporter.inkImage(try PKDrawing(data: page.drawing), from: layout.canonicalInkBounds, scale: scale)
        return Parts(layout: layout, scale: scale, base: UIImage(cgImage: base), ink: ink)
    }

    private static func compose(_ page: Page, _ parts: Parts) -> UIImage {
        let layout = parts.layout, bounds = layout.canvas.bounds
        let size = CGSize(width: bounds.width * parts.scale, height: bounds.height * parts.scale)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { renderer in
            let context = renderer.cgContext
            parts.base.draw(in: CGRect(origin: .zero, size: size))
            context.scaleBy(x: parts.scale, y: parts.scale)
            ShapeRendering.draw(page.shapes ?? [], origin: layout.contentOrigin, context: context)
            parts.ink?.draw(in: bounds)
            for box in page.resolvedTextBoxes {
                let origin = layout.contentOrigin
                func shown(_ point: PagePoint) -> CGPoint { CGPoint(x: point.x + origin.x, y: point.y + origin.y) }
                TextFieldStyleRendering.draw(box, at: CGPoint(x: box.x + origin.x, y: box.y + origin.y), context: context)
                // Clipped like the editor: the (possibly rotated) text frame
                // plus the same glyph overhang, so italics and first letters
                // keep their edges; text beyond it stays stored, marked below.
                let text = TextObjectLayout(box, on: page)
                let reach = Double(TextObjectLayout.glyphOverhang(box)) * page.writingCoordinateScale(for: box)
                let outline = CGMutablePath()
                outline.addLines(between: [PagePoint(x: -reach, y: -reach), PagePoint(x: box.width + reach, y: -reach),
                                           PagePoint(x: box.width + reach, y: box.height + reach), PagePoint(x: -reach, y: box.height + reach)]
                    .map { shown(box.pagePoint($0)) })
                outline.closeSubpath()
                context.saveGState(); context.addPath(outline); context.clip()
                text.draw(at: CGPoint(x: box.x + origin.x, y: box.y + origin.y))
                context.restoreGState()
                // Overflowing text: the red frame of the editor (`TextBox.overflows`).
                if box.overflows(textHeight: Double(text.contentHeight(box))) {
                    let frame = CGMutablePath()
                    frame.addLines(between: box.selectionCorners.map(shown)); frame.closeSubpath()
                    context.saveGState()
                    context.addPath(frame); context.setStrokeColor(UIColor.systemRed.cgColor)
                    context.setLineWidth(1.5 / parts.scale); context.strokePath()
                    context.restoreGState()
                }
            }
        }
    }
}

/// Small async semaphore; waiters resume in order.
actor RenderGate {
    private var available: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []
    init(limit: Int) { available = limit }
    func acquire() async {
        if available > 0 { available -= 1; return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
        if waiters.isEmpty { available += 1 } else { waiters.removeFirst().resume() }
    }
}

/// Keep the last preview during writing and update only after a short idle gap.
/// No drawing-data hashes or PDF renders are computed from the view's body.
struct PageThumbnail: View {
    let page: Page
    let source: PDFPage?
    let cache: PageThumbnailCache
    var selected: Bool? = nil
    @State private var image: UIImage?
    @State private var failed = false
    @State private var request = UUID()
    var body: some View {
        // One concrete root for the full lifecycle. A conditional Group applies
        // task/disappear to its changing children: replacing a spinner with an
        // image could clear that image again and restart the loading/layout loop.
        ThumbnailSurface(image: image, failed: failed, aspectRatio: page.previewAspectRatio, selected: selected)
        .clipped()
        .allowsHitTesting(false)
        .task(id: request) {
            // Scrolled back into view: a cached preview appears without a spinner frame.
            if image == nil, let hit = cache.cached(page) { image = hit; failed = false; return }
            if image != nil {
                do { try await Task.sleep(for: .milliseconds(600)) }
                catch { return }
            } else { await Task.yield() }
            guard !Task.isCancelled else { return }
            do { image = try await cache.image(page: page, source: source?.pageRef, keepAlive: source?.document); failed = false }
            catch is CancellationError { }
            catch { if !Task.isCancelled { failed = true } }
        }
        .onChange(of: page) { _, _ in request = UUID() }
        .onDisappear { image = nil }
    }
}

/// The image has no intrinsic size and never participates in hit testing. Its
/// UIKit surface stays alive as loading/error/image state changes, so a Form or
/// scroll cell keeps precisely the bounds its parent assigned.
private struct ThumbnailSurface: UIViewRepresentable {
    let image: UIImage?
    let failed: Bool
    let aspectRatio: CGFloat
    let selected: Bool?
    func makeUIView(context: Context) -> ThumbnailSurfaceView { ThumbnailSurfaceView() }
    func updateUIView(_ view: ThumbnailSurfaceView, context: Context) {
        view.configure(image: image, failed: failed, aspectRatio: aspectRatio, selected: selected)
    }
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: ThumbnailSurfaceView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions(by: CGSize(width: 224, height: 224))
    }
}

private final class ThumbnailSurfaceView: UIView {
    private let picture = UIImageView()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let failure = UILabel()
    private var aspectRatio: CGFloat = 595.0 / 842

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false; clipsToBounds = true
        picture.contentMode = .scaleAspectFit; picture.clipsToBounds = true
        picture.layer.cornerRadius = 4
        picture.isUserInteractionEnabled = false
        spinner.hidesWhenStopped = true
        failure.text = "Vorschau nicht verfügbar"
        failure.textColor = .secondaryLabel; failure.font = .preferredFont(forTextStyle: .caption1)
        failure.numberOfLines = 0; failure.textAlignment = .center
        [picture, spinner, failure].forEach { addSubview($0) }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var intrinsicContentSize: CGSize { CGSize(width: UIView.noIntrinsicMetric, height: UIView.noIntrinsicMetric) }
    override func layoutSubviews() {
        super.layoutSubviews()
        let width = min(bounds.width, bounds.height * aspectRatio)
        let height = width / aspectRatio
        picture.frame = CGRect(x: bounds.midX - width / 2, y: bounds.midY - height / 2, width: width, height: height)
        failure.frame = bounds.insetBy(dx: 8, dy: 8)
        spinner.center = CGPoint(x: bounds.midX, y: bounds.midY)
    }
    func configure(image: UIImage?, failed: Bool, aspectRatio: CGFloat, selected: Bool?) {
        self.aspectRatio = aspectRatio
        picture.image = image
        picture.layer.borderWidth = selected.map { $0 ? 3 : 1 } ?? 0
        picture.layer.borderColor = selected == true ? tintColor.cgColor : UIColor.secondaryLabel.withAlphaComponent(0.3).cgColor
        failure.isHidden = !failed || image != nil
        if image == nil && !failed { spinner.startAnimating() } else { spinner.stopAnimating() }
        setNeedsLayout()
    }
}
