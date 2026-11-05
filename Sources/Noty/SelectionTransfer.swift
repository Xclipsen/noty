import UIKit
import PencilKit
import NotebookCore

/// A lasso selection lifted off its page while it is dragged over the
/// continuous notebook. All coordinates are canonical source-page coordinates.
struct SelectionLift {
    let pageID: UUID
    /// Complete source content when the drag began (expected state for the commit).
    let content: PageContent
    /// Source content without the selected members.
    let remainder: PageContent
    let ink: [PKStroke]
    let objects: MovedObjects
    /// Selection bounds including ink render bounds.
    let frame: CGRect
    /// Canonical point where the drag began.
    let start: CGPoint
    let snapshot: UIImage?

    /// A single image (image-specific messages).
    var isSingleImage: Bool {
        ink.isEmpty && objects.textBoxes.isEmpty && objects.shapes.isEmpty && objects.images.count == 1
    }
}

/// Selection of the moved members on the target page after a transfer.
struct TransferredSelection {
    var ink = Set<Int>()
    var texts = Set<UUID>(), images = Set<UUID>(), shapes = Set<UUID>()
}

/// Implemented by the continuous notebook viewport. Without a host (single
/// page editor) a selection stays clamped to its own page.
@MainActor
protocol SelectionTransferHost: AnyObject {
    func floatSelection(_ lift: SelectionLift, gesture: UIGestureRecognizer)
    func hideFloatingSelection()
    /// Returns true when the selection was moved to another page atomically.
    func dropSelection(_ lift: SelectionLift, gesture: UIGestureRecognizer) -> Bool
    /// Page below the touch that would accept a drop (nil: gap, beside the
    /// pages, editor locked or zooming).
    func transferTarget(for gesture: UIGestureRecognizer) -> UUID?
    /// The touch is in the autoscroll band at the top/bottom of the viewport
    /// and the notebook can scroll that way: a selection from `pageID` lifts
    /// there, so a page out of sight can be reached (Review: zoomed in with no
    /// neighbour in view it was only clamped). Over its own sheet only where
    /// that sheet goes on beyond the screen edge; beside it the selection may
    /// be in the band anywhere. Only after the touch moved towards that edge
    /// from `start` (where the drag began, window coordinates): grabbing
    /// something that already lies in the band does not scroll at once.
    func liftsForAutoScroll(_ gesture: UIGestureRecognizer, from pageID: UUID, start: CGPoint) -> Bool
    /// Someone works on `sheet` (stroke, tap, lasso, field editing): every
    /// other page drops its selection, so only one selection, one action bar
    /// and one target for key commands exist at a time.
    func sheetBecameActive(_ sheet: WorksheetView)
}

@MainActor
enum SelectionTransfer {
    struct Result {
        let source: PageContent
        let target: PageContent
        let selection: TransferredSelection
    }

    /// Transparent preview of only the selected members, composed with the
    /// export renderers like the page itself: text with its automatic colours
    /// resolved and its ruled layout (`page`: paper, margins and PDF of the
    /// source page), images from their decoded renditions or – never left
    /// out – as the neutral placeholder. Bounded to `maximumPixels`.
    /// `placeholders: false` (system pasteboard): no picture at all (nil)
    /// when an image has no decoded rendition yet.
    static func snapshot(objects: MovedObjects, ink: [PKStroke], frame: CGRect, pixelScale: CGFloat, page: Page? = nil,
                         maximumPixels: CGFloat = 4_000_000, placeholders: Bool = true) -> UIImage? {
        guard frame.width.isFinite, frame.height.isFinite, frame.width > 0, frame.height > 0 else { return nil }
        let renditions = objects.images.map { ImageRendering.cached($0, limit: 1024) ?? ImageRendering.anyCached($0, near: 1024) }
        if !placeholders, renditions.contains(where: { $0 == nil }) { return nil }
        let scale = max(0.05, min(pixelScale, 4, (maximumPixels / (frame.width * frame.height)).squareRoot()))
        let format = UIGraphicsImageRendererFormat()
        format.opaque = false; format.scale = scale
        var inkImage: UIImage?
        if !ink.isEmpty {
            // Sheets render ink in light appearance; keep the preview identical.
            UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
                inkImage = PKDrawing(strokes: ink).image(from: frame, scale: scale)
            }
        }
        return UIGraphicsImageRenderer(bounds: frame, format: format).image { context in
            let cg = context.cgContext
            // Never decodes an original here: the rendition the page shows.
            for (image, rendition) in zip(objects.images, renditions) {
                ImageRendering.draw(rendition, for: image, context: cg, origin: .init(x: 0, y: 0))
            }
            ShapeRendering.draw(objects.shapes, origin: .init(x: 0, y: 0), context: cg)
            inkImage?.draw(in: frame)
            var context = page ?? Page()
            context.textBoxes = objects.textBoxes
            for box in context.resolvedTextBoxes {
                TextFieldStyleRendering.draw(box, at: CGPoint(x: box.x, y: box.y), context: cg)
                TextObjectLayout(box, on: context).draw(at: CGPoint(x: box.x, y: box.y))
            }
        }
    }

    /// Maps the lifted members onto the target page (uniform scale plus
    /// translation), shifts them completely into `limits` and appends them.
    /// Throws `CrossPageTransferError` instead of clipping anything.
    static func build(_ lift: SelectionLift, move: CrossPageMove, target: PageContent, limits: PageRect) throws -> Result {
        let mapping = CGAffineTransform(a: move.scale, b: 0, c: 0, d: move.scale, tx: move.translation.x, ty: move.translation.y)
        var strokes = lift.ink.isEmpty ? [] : PKDrawing(strokes: lift.ink).transformed(using: mapping).strokes
        let inkFrame = strokes.dropFirst().reduce(strokes.first?.renderBounds) { $0?.union($1.renderBounds) }
        let placed = try CrossPageTransfer.place(lift.objects, by: move, alongside: inkFrame.map { PageRect($0) },
                                                 into: target, limits: limits)
        let offset = placed.offset
        if !strokes.isEmpty, offset.x != 0 || offset.y != 0 {
            strokes = PKDrawing(strokes: strokes).transformed(using: CGAffineTransform(translationX: offset.x, y: offset.y)).strokes
        }
        let allowed = limits.cgRect.insetBy(dx: -0.05, dy: -0.05)
        guard strokes.allSatisfy({ allowed.contains($0.renderBounds) }) else { throw CrossPageTransferError.doesNotFit }
        var content = placed.content
        var selection = TransferredSelection(texts: Set(placed.objects.textBoxes.map(\.id)),
            images: Set(placed.objects.images.map(\.id)), shapes: Set(placed.objects.shapes.map(\.id)))
        if !strokes.isEmpty {
            guard let existing = target.drawing.isEmpty ? PKDrawing() : try? PKDrawing(data: target.drawing) else {
                throw CrossPageTransferError.invalidObject
            }
            // Moved strokes are appended after the existing ones.
            content.drawing = PKDrawing(strokes: existing.strokes + strokes).dataRepresentation()
            selection.ink = Set(existing.strokes.count..<(existing.strokes.count + strokes.count))
        }
        return Result(source: lift.remainder, target: content, selection: selection)
    }
}
