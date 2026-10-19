import SwiftUI
import PDFKit
import PencilKit
import NotebookCore

/// Shared by the sidebar and the optional large overview. Cached content is tied
/// to a page snapshot, never to its current position in the notebook.
@MainActor
final class PageThumbnailCache: ObservableObject {
    private final class Entry {
        let page: Page
        let image: UIImage
        init(page: Page, image: UIImage) { self.page = page; self.image = image }
    }
    private let images = NSCache<NSString, Entry>()
    init() { images.countLimit = 24; images.totalCostLimit = 8 * 1024 * 1024 }

    func image(page: Page, source: PDFPage?) throws -> UIImage {
        let key = page.id.uuidString as NSString
        if let entry = images.object(forKey: key), entry.page == page { return entry.image }
        let layout = try PageLayout(page: page, source: source?.pageRef)
        let bounds = layout.canvas.bounds
        let scale = 224 / max(bounds.width, bounds.height)
        let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        let drawing = page.drawing.isEmpty ? PKDrawing() : try PKDrawing(data: page.drawing)
        var imageFailure: Error?
        let image = UIGraphicsImageRenderer(size: size, format: format).image { renderer in
            let context = renderer.cgContext
            context.scaleBy(x: scale, y: scale)
            PDFExporter.drawPaper(style: page.margins?.style ?? page.paper ?? (source == nil ? .legacyTest : .blank),
                                  bounds: bounds, color: page.margins?.color ?? page.paperColor ?? .white, coordinateScale: page.writingCoordinateScale)
            if let pdf = source?.pageRef {
                // Transparent PDFs retain white paper against dark note margins.
                UIColor.white.setFill(); context.fill(layout.sourceFrame.cgRect)
                context.saveGState(); context.clip(to: layout.sourceFrame.cgRect)
                context.concatenate(layout.pdfToCanvas.cgTransform); context.drawPDFPage(pdf); context.restoreGState()
            }
            for object in page.images ?? [] {
                // Failure leaves the existing preview and surfaces a failed
                // thumbnail; exports perform their own throwing validation.
                do { try ImageRendering.draw(object, context: context, origin: layout.contentOrigin, limit: 256) }
                catch { imageFailure = error }
            }
            ShapeRendering.draw(page.shapes ?? [], origin: layout.contentOrigin, context: context)
            if !page.drawing.isEmpty { PDFExporter.inkImage(drawing, from: layout.canonicalInkBounds, scale: scale).draw(in: bounds) }
            for box in page.resolvedTextBoxes {
                let frame = CGRect(x: box.x + layout.contentOrigin.x, y: box.y + layout.contentOrigin.y,
                                   width: box.width, height: box.height)
                context.saveGState(); context.clip(to: frame)
                TextObjectLayout(box, on: page).draw(at: frame.origin)
                context.restoreGState()
            }
        }
        if let imageFailure { throw imageFailure }
        images.setObject(Entry(page: page, image: image), forKey: key,
                         cost: Int(size.width * size.height * 4) + page.drawing.count + page.searchableText.utf8.count
                            + (page.images ?? []).reduce(0, { $0 + $1.data.count }))
        return image
    }
}

struct PageOverviewView: View {
    @ObservedObject var model: EditorModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var cache = PageThumbnailCache()
    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 145, maximum: 220))], spacing: 20) {
                    ForEach(Array(model.notebook.pages.enumerated()), id: \.element.id) { index, page in
                        Button {
                            model.selectPage(page.id)
                            dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                PageThumbnail(page: page, source: model.sourcePage(for: page), cache: cache, selected: index == model.pageIndex)
                                    .aspectRatio(page.previewAspectRatio, contentMode: .fit)
                                    .frame(maxHeight: 224)
                                    .frame(maxWidth: .infinity)
                                Text("Seite \(index + 1)").font(.headline)
                                Text(page.searchableText.isEmpty ? (page.drawing.isEmpty ? "Keine eigenen Einträge" : "Handschrift") : String(page.searchableText.prefix(80)))
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }.buttonStyle(.plain)
                    }
                }.padding()
            }
            .navigationTitle("\(model.notebook.pages.count) Seiten · \(model.notebook.title)")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Schließen") { dismiss() } } }
        }
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
            if image != nil {
                do { try await Task.sleep(for: .milliseconds(600)) }
                catch { return }
            } else { await Task.yield() }
            guard !Task.isCancelled else { return }
            do { image = try cache.image(page: page, source: source); failed = false }
            catch { failed = true }
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
