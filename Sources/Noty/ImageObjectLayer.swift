import UIKit
import NotebookCore

/// One page-local image plane below ink/text: it only draws. Selecting,
/// moving, scaling, rotating, cropping, locking, ordering and the action bar
/// of images live in `ObjectEditingLayer` for every tool, the image tool
/// included (Build 64: one image has the same handling everywhere).
/// Undo is notebook-wide (EditorModel). All object coordinates stay in
/// canonical points.
@MainActor
final class ImageObjectLayer: UIView {
    private var objects: [ImageObject] = []
    private var pageID: UUID?
    private var contentGeneration = -1
    private var generation = 0
    private var pageLayout = PageLayout(source: .testPaper, legacyA4: true)
    /// The image tool is active: a newly added image is reported once.
    private var tracking = false
    private var onChange: (([ImageObject]) -> Void)?
    private var onError: ((String) -> Void)?
    /// Failed decodes per image (retry pause), and originals validation rejected.
    private var failures: [UUID: (count: Int, retryAt: CFTimeInterval)] = [:]
    private var broken = Set<UUID>()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear; isOpaque = false; contentMode = .redraw; clipsToBounds = true
        isUserInteractionEnabled = false
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// `active`: the image tool is on (a newly added image is reported once
    /// by `takeInsertedImage`, so the viewport can scroll it into view).
    func configure(objects incoming: [ImageObject], pageID: UUID, layout: PageLayout, contentGeneration: Int,
                   active: Bool, onChange: @escaping ([ImageObject]) -> Void, onError: @escaping (String) -> Void) {
        let reset = self.pageID != pageID || self.contentGeneration != contentGeneration || pageLayout != layout
        if !reset, objects == incoming {
            self.onChange = onChange; self.onError = onError; tracking = active; return
        }
        if reset { generation += 1 }
        else if active, tracking, let added = incoming.last(where: { object in !objects.contains { $0.id == object.id } }) {
            insertedID = added.id
        }
        self.pageID = pageID; self.contentGeneration = contentGeneration; pageLayout = layout
        tracking = active; self.onChange = onChange; self.onError = onError; objects = incoming
        if reset { failures.removeAll(); broken.removeAll() }
        isHidden = objects.isEmpty
        setNeedsDisplay()
    }

    /// An image added while the image tool is active (import, paste, undo of
    /// a deletion), taken once by the viewport to scroll it into view.
    private var insertedID: UUID?
    func takeInsertedImage() -> CGRect? {
        defer { insertedID = nil }
        return insertedID.flatMap { id in objects.first { $0.id == id } }.map(displayBounds)
    }
    /// The plane shows exactly these objects (no local drag pending).
    func shows(_ incoming: [ImageObject]) -> Bool { objects == incoming }
    func adoptCallbacks(onChange: @escaping ([ImageObject]) -> Void, onError: @escaping (String) -> Void) {
        self.onChange = onChange; self.onError = onError
    }
    /// A cross-page transfer was committed atomically by the notebook (one
    /// undo step for both pages) before SwiftUI publishes it.
    func adoptTransfer(_ incoming: [ImageObject]) {
        objects = incoming; isHidden = objects.isEmpty; setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        let zoom = 1 / controlScale
        let screenScale = window?.screen.scale ?? 2
        for object in objects {
            guard displayBounds(object).intersects(rect) else { continue }
            // Decoding a camera original takes long: never while drawing. Until
            // the rendition is ready, a cached one of another size or a neutral
            // placeholder stands in, then only its frame is redrawn.
            let limit = Self.rendition(object, zoom: zoom, screenScale: screenScale)
            let image = ImageRendering.cached(object, limit: limit)
            if image == nil { request(object, limit: limit) }
            autoreleasepool {
                ImageRendering.draw(image ?? ImageRendering.anyCached(object, near: limit), for: object,
                                    context: context, origin: pageLayout.contentOrigin)
            }
        }
    }
    /// Quantized resolutions, so dragging/zooming does not fill the bounded
    /// cache with almost-identical renditions.
    private static func rendition(_ object: ImageObject, zoom: CGFloat, screenScale: CGFloat) -> Int {
        let pixels = max(object.width / object.crop.width, object.height / object.crop.height) * zoom * screenScale
        return pixels <= 512 ? 512 : (pixels <= 1024 ? 1024 : 2048)
    }
    /// Load/import validation rejects unreadable originals. A failed decode is
    /// often transient (memory pressure): it is retried after a pause, and only
    /// an original that validation rejects too is reported and given up.
    private func request(_ object: ImageObject, limit: Int) {
        guard !broken.contains(object.id) else { return }
        if let failure = failures[object.id], CACurrentMediaTime() < failure.retryAt { return }
        let id = object.id, expected = generation
        ImageRendering.prepare(object, limit: limit) { [weak self] error in
            guard let self, self.generation == expected, let current = self.objects.first(where: { $0.id == id }) else { return }
            guard error != nil else { self.failures[id] = nil; self.setNeedsDisplay(self.displayBounds(current)); return }
            let count = (self.failures[id]?.count ?? 0) + 1
            let pause: TimeInterval = count == 1 ? 2 : 10
            self.failures[id] = (count, CACurrentMediaTime() + pause)
            if count == 1 { self.redraw(id, after: pause); return }
            Task.detached(priority: .utility) { [weak self] in
                let rejected: Error?
                do { try ImageRendering.validate(current); rejected = nil } catch { rejected = error }
                await self?.validated(id, generation: expected, rejected: rejected, retry: count < 5 ? pause : nil)
            }
        }
    }
    private func validated(_ id: UUID, generation expected: Int, rejected: Error?, retry: TimeInterval?) {
        guard generation == expected, objects.contains(where: { $0.id == id }) else { return }
        if let rejected { broken.insert(id); onError?(rejected.localizedDescription) }
        else if let retry { redraw(id, after: retry) }
    }
    private func redraw(_ id: UUID, after delay: TimeInterval) {
        let expected = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + delay + 0.05) { [weak self] in
            guard let self, self.generation == expected, let object = self.objects.first(where: { $0.id == id }) else { return }
            self.setNeedsDisplay(self.displayBounds(object))
        }
    }
    private var controlScale: CGFloat {
        guard let window else { return 1 }
        let start = convert(CGPoint.zero, to: window), end = convert(CGPoint(x: 100, y: 0), to: window)
        return 1 / max(0.01, hypot(end.x - start.x, end.y - start.y) / 100)
    }
    private func displayBounds(_ object: ImageObject) -> CGRect {
        object.rotatedBounds.cgRect.offsetBy(dx: pageLayout.contentOrigin.x, dy: pageLayout.contentOrigin.y)
    }
}
