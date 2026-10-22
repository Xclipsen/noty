import UIKit
import PencilKit
import NotebookCore

/// Selection contour after the native PencilKit lasso of the early builds
/// (Handschrift-Lasso `PKLassoTool` up to Build 29): every selected stroke,
/// shape, image and free text field is encircled at a small distance, and
/// neighbours closer than twice that distance merge into one outline. No
/// rectangle and no single convex hull around everything.
///
/// Built once per selection in canonical page points (CoreGraphics union of the
/// widened members); drags only transform the cached path.
@MainActor
enum SelectionContour {
    struct Key: Equatable {
        var drawing: Data
        var ink: Set<Int>
        var texts: [[Double]]
        var images: [[Double]]
        var shapes: [ShapeObject]
        var gap: Double
    }

    static func key(_ content: PageContent, ink: Set<Int>, texts: Set<UUID>, images: Set<UUID>, shapes: Set<UUID>, gap: Double) -> Key {
        Key(drawing: ink.isEmpty ? Data() : content.drawing, ink: ink,
            texts: content.textBoxes.filter { texts.contains($0.id) }.map { [$0.x, $0.y, $0.width, $0.height, $0.angle, $0.fieldPadding] },
            images: content.images.filter { images.contains($0.id) }.map { [$0.x, $0.y, $0.width, $0.height, $0.rotation] },
            shapes: content.shapes.filter { shapes.contains($0.id) }, gap: gap)
    }

    /// Outline in canonical page coordinates, or nil if nothing can be outlined.
    static func path(_ content: PageContent, drawing: PKDrawing?, ink: Set<Int>, texts: Set<UUID>,
                     images: Set<UUID>, shapes: Set<UUID>, gap: Double) -> CGPath? {
        let pieces = CGMutablePath()
        let spacing = SelectionOutline.sampleSpacing(gap: gap)
        if let drawing {
            for index in ink.sorted() where drawing.strokes.indices.contains(index) {
                let stroke = drawing.strokes[index]
                let transformScale = max(hypot(stroke.transform.a, stroke.transform.b), hypot(stroke.transform.c, stroke.transform.d))
                let width = (stroke.path.map { max($0.size.width, $0.size.height) }.max() ?? 1) * transformScale
                let samples = Array(stroke.path.interpolatedPoints(by: .distance(spacing)))
                let points = (samples.isEmpty ? stroke.path.map(\.location) : samples.map(\.location)).map { $0.applying(stroke.transform) }
                guard let first = points.first else { continue }
                let radius = width / 2 + gap
                if points.count == 1 || points.allSatisfy({ hypot($0.x - first.x, $0.y - first.y) < 0.01 }) {
                    pieces.addEllipse(in: CGRect(x: first.x - radius, y: first.y - radius, width: 2 * radius, height: 2 * radius))
                    continue
                }
                let line = CGMutablePath(); line.addLines(between: points)
                pieces.addPath(line.copy(strokingWithWidth: 2 * radius, lineCap: .round, lineJoin: .round, miterLimit: 4))
            }
        }
        for shape in content.shapes where shapes.contains(shape.id) {
            let outline = ShapeRendering.path(shape).cgPath
            pieces.addPath(outline.copy(strokingWithWidth: shape.lineWidth + 2 * gap, lineCap: .round, lineJoin: .round, miterLimit: 4))
            if shape.hasVisibleFill { pieces.addPath(outline) }
        }
        for box in content.textBoxes where texts.contains(box.id) {
            // Turned about its top-left corner like in editor, preview and PDF;
            // a styled field (Feldstil) with its padding.
            var turn = CGAffineTransform(translationX: box.x, y: box.y).rotated(by: box.angle * .pi / 180)
            let frame = box.fieldStyleRect
            let local = CGRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height).insetBy(dx: -gap, dy: -gap)
            pieces.addPath(CGPath(roundedRect: local, cornerWidth: gap, cornerHeight: gap, transform: &turn))
        }
        for image in content.images where images.contains(image.id) {
            let frame = CGRect(x: image.x, y: image.y, width: image.width, height: image.height)
            var turn = CGAffineTransform(translationX: frame.midX, y: frame.midY)
                .rotated(by: image.rotation * .pi / 180).translatedBy(x: -frame.midX, y: -frame.midY)
            pieces.addPath(CGPath(roundedRect: frame.insetBy(dx: -gap, dy: -gap), cornerWidth: gap, cornerHeight: gap, transform: &turn))
        }
        guard !pieces.isEmpty else { return nil }
        let union = pieces.normalized(using: .winding)
        return union.isEmpty || union.boundingBoxOfPath.isNull ? nil : union
    }
}
