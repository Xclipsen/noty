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

    /// A single image dragged with the image tool (image-specific messages).
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
}

@MainActor
enum SelectionTransfer {
    struct Result {
        let source: PageContent
        let target: PageContent
        let selection: TransferredSelection
    }

    /// Transparent preview of only the selected members, composed with the
    /// export renderers. Bounded to about 4 megapixels.
    static func snapshot(objects: MovedObjects, ink: [PKStroke], frame: CGRect, pixelScale: CGFloat) -> UIImage? {
        guard frame.width.isFinite, frame.height.isFinite, frame.width > 0, frame.height > 0 else { return nil }
        let scale = max(0.05, min(pixelScale, 4, (4_000_000 / (frame.width * frame.height)).squareRoot()))
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
            for image in objects.images {
                try? ImageRendering.draw(image, context: cg, origin: .init(x: 0, y: 0))
            }
            ShapeRendering.draw(objects.shapes, origin: .init(x: 0, y: 0), context: cg)
            inkImage?.draw(in: frame)
            for box in objects.textBoxes {
                TextFieldStyleRendering.draw(box, at: CGPoint(x: box.x, y: box.y), context: cg)
                TextObjectLayout(box).draw(at: CGPoint(x: box.x, y: box.y))
            }
        }
    }

    /// Preview of one image dragged with the image tool. Uses an already
    /// decoded rendition (`rendition`, nil: neutral placeholder), so starting
    /// the lift never decodes a camera original on the main thread.
    static func snapshot(image object: ImageObject, rendition: UIImage?, pixelScale: CGFloat) -> UIImage? {
        let frame = object.rotatedBounds.cgRect
        guard frame.width.isFinite, frame.height.isFinite, frame.width > 0, frame.height > 0 else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.opaque = false
        format.scale = max(0.05, min(pixelScale, 4, (4_000_000 / (frame.width * frame.height)).squareRoot()))
        return UIGraphicsImageRenderer(bounds: frame, format: format).image { context in
            ImageRendering.draw(rendition, for: object, context: context.cgContext, origin: .init(x: 0, y: 0))
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
