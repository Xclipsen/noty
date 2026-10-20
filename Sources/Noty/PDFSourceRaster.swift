import UIKit
import NotebookCore

/// Editor display of the source PDF without PDFKit's PDFView. Device traces
/// (Feedback 33) showed PDFKit building tile layers on the main thread for
/// seconds once the notebook was zoomed in. Here a small whole-page image is
/// always present and only the visible region is rendered sharply, with a
/// bounded pixel budget, on a background queue. Geometry is identical to the
/// export: clip to `sourceFrame`, then `pdfToCanvas`.
final class PDFSourceRasterView: UIView {
    private struct Source: @unchecked Sendable {
        let page: CGPDFPage
        let transform: CGAffineTransform
        let frame: CGRect
    }
    private struct Image: @unchecked Sendable { let image: CGImage?; let milliseconds: Int }

    private static let baseBudget = 2_500_000.0
    private static let detailBudget = 12_000_000.0
    /// A freshly shown, mostly visible page renders its base once at display
    /// resolution instead of base plus detail (bounded like a detail region).
    private static let sharpBaseBudget = 6_500_000.0
    private let baseLayer = CALayer()
    private let detailLayer = CALayer()
    private var source: Source?
    private var baseGeneration = 0
    private var detailGeneration = 0
    private var basePixelScale: CGFloat = 0
    /// Base render deferred by one main-queue turn so the first layout's
    /// display scale can still upgrade it (opening, page jumps, paging).
    private var basePending = false
    private var requestedDetail: (region: CGRect, scale: CGFloat)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        for layer in [baseLayer, detailLayer] {
            layer.contentsGravity = .resize
            layer.backgroundColor = UIColor.white.cgColor
            layer.isOpaque = true
            self.layer.addSublayer(layer)
        }
        detailLayer.isHidden = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Returns true when the source changed and a new detail region is needed.
    @discardableResult
    func configure(page: CGPDFPage?, layout: PageLayout) -> Bool {
        let frame = layout.sourceFrame.cgRect, transform = layout.pdfToCanvas.cgTransform
        if let source, let page, source.page === page, source.frame == frame, source.transform == transform { return false }
        if source == nil && page == nil { return false }
        source = page.map { Source(page: $0, transform: transform, frame: frame) }
        requestedDetail = nil; detailGeneration += 1; baseGeneration += 1; basePending = false
        CATransaction.begin(); CATransaction.setDisableActions(true)
        baseLayer.frame = frame; baseLayer.contents = nil
        detailLayer.isHidden = true; detailLayer.contents = nil
        CATransaction.commit()
        guard source != nil else { return true }
        basePixelScale = min(2, sqrt(Self.baseBudget / max(1, frame.width * frame.height)))
        basePending = true
        let generation = baseGeneration
        DispatchQueue.main.async { [weak self] in self?.submitPendingBase(generation: generation) }
        return true
    }

    private func submitPendingBase(generation: Int) {
        guard basePending, generation == baseGeneration, let source else { return }
        basePending = false
        render(source, region: source.frame, scale: basePixelScale, generation: generation, detail: false)
    }

    /// `region` in page canvas points; `pixelScale` in pixels per point.
    func updateDetail(region: CGRect, pixelScale: CGFloat) {
        guard let source else { return }
        let visible = region.intersection(source.frame)
        guard !visible.isNull, visible.width >= 1, visible.height >= 1 else { return }
        if basePending {
            // Mostly visible at a known display scale: one sharp whole-page
            // render replaces the blurry base plus a second detail pass.
            let frame = source.frame, area = max(1, frame.width * frame.height)
            let sharp = min(pixelScale, sqrt(Self.sharpBaseBudget / area))
            if (visible.width * visible.height) / area >= 0.7, sharp >= pixelScale * 0.98, sharp > basePixelScale {
                basePixelScale = sharp
            }
            submitPendingBase(generation: baseGeneration)
        }
        let scale = min(pixelScale, sqrt(Self.detailBudget / (visible.width * visible.height)))
        guard scale > basePixelScale * 1.05 else {
            detailGeneration += 1; requestedDetail = nil; detailLayer.isHidden = true; return
        }
        if let requested = requestedDetail, requested.region == visible, abs(requested.scale - scale) < 0.01 { return }
        requestedDetail = (visible, scale); detailGeneration += 1
        render(source, region: visible, scale: scale, generation: detailGeneration, detail: true)
    }

    private func render(_ source: Source, region: CGRect, scale: CGFloat, generation: Int, detail: Bool) {
        let owner = ObjectIdentifier(detail ? detailLayer : baseLayer)
        PDFRasterQueue.shared.submit(owner: owner, generation: generation) {
            let started = CACurrentMediaTime()
            let image = Self.rasterize(source, region: region, scale: scale)
            return Image(image: image, milliseconds: Int((CACurrentMediaTime() - started) * 1000))
        } done: { [weak self] result in
            Task { @MainActor [weak self] in self?.apply(result, region: region, generation: generation, detail: detail) }
        }
    }

    private var darknessGeneration = 0
    /// Autostift on PDF pages: is the source mostly dark (mean luminance of a
    /// 32×32 rendering below 0.5)? Rendered on the raster queue: PDFKit's
    /// thumbnail on the main thread stalled like the Feedback 33 zoom hang.
    /// `done` runs on the main thread for the latest request only.
    func measureDarkness(_ done: @escaping @MainActor @Sendable (Bool) -> Void) {
        guard let source else { return }
        darknessGeneration += 1
        let generation = darknessGeneration
        PDFRasterQueue.shared.submit(owner: ObjectIdentifier(self), generation: generation) {
            Self.isDark(source)
        } done: { [weak self] dark in
            Task { @MainActor [weak self] in
                guard let self, self.darknessGeneration == generation, self.source?.page === source.page else { return }
                done(dark)
            }
        }
    }

    nonisolated private static func isDark(_ source: Source) -> Bool {
        let size = 32, frame = source.frame
        guard frame.width > 0, frame.height > 0 else { return false }
        var pixels = [UInt8](repeating: 255, count: size * size * 4)
        let luminance: Double = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 1 }
            context.setFillColor(gray: 1, alpha: 1); context.fill(CGRect(x: 0, y: 0, width: size, height: size))
            // The crop region stretched onto the bitmap, as the former thumbnail.
            context.translateBy(x: 0, y: CGFloat(size))
            context.scaleBy(x: CGFloat(size) / frame.width, y: -CGFloat(size) / frame.height)
            context.translateBy(x: -frame.minX, y: -frame.minY)
            context.clip(to: frame)
            context.concatenate(source.transform)
            context.drawPDFPage(source.page)
            let data = buffer.bindMemory(to: UInt8.self)
            var sum = 0.0
            for i in stride(from: 0, to: data.count, by: 4) { sum += 0.2126 * Double(data[i]) + 0.7152 * Double(data[i+1]) + 0.0722 * Double(data[i+2]) }
            return sum / (Double(size * size) * 255)
        }
        return luminance < 0.5
    }

    private func apply(_ result: Image, region: CGRect, generation: Int, detail: Bool) {
        guard let image = result.image, generation == (detail ? detailGeneration : baseGeneration) else { return }
        EditorOpenTrace.mark(detail ? "PDF detail raster ready" : "PDF base raster ready",
            "render=\(result.milliseconds) ms px=\(image.width)x\(image.height)")
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let target = detail ? detailLayer : baseLayer
        target.frame = region; target.contents = image
        if detail { detailLayer.isHidden = false }
        CATransaction.commit()
    }

    nonisolated private static func rasterize(_ source: Source, region: CGRect, scale: CGFloat) -> CGImage? {
        let width = max(1, Int(ceil(region.width * scale))), height = max(1, Int(ceil(region.height * scale)))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        // Same y-down canvas space as the editor and the PDF export.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)
        context.translateBy(x: -region.minX, y: -region.minY)
        context.setFillColor(gray: 1, alpha: 1); context.fill(region)
        context.clip(to: source.frame)
        context.concatenate(source.transform)
        context.interpolationQuality = .high
        context.drawPDFPage(source.page)
        return context.makeImage()
    }
}

/// One serial rasterizer; stale requests of the same owner are skipped.
private final class PDFRasterQueue: @unchecked Sendable {
    static let shared = PDFRasterQueue()
    private let queue = DispatchQueue(label: "de.la.noty.pdf-raster", qos: .userInitiated)
    private let lock = NSLock()
    /// Pending owners only: an entry is dropped once its latest job ran, so
    /// released sheets leave nothing behind.
    private var latest: [ObjectIdentifier: Int] = [:]

    func submit<T: Sendable>(owner: ObjectIdentifier, generation: Int,
                             job: @escaping @Sendable () -> T, done: @escaping @Sendable (T) -> Void) {
        lock.withLock { latest[owner] = generation }
        queue.async {
            let current = self.lock.withLock { () -> Bool in
                guard self.latest[owner] == generation else { return false }
                self.latest[owner] = nil; return true
            }
            guard current else { return }
            done(autoreleasepool { job() })
        }
    }
}
