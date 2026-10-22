import UIKit
import PencilKit
import NotebookCore

/// "Ganz" eraser sweep with dimmed preview, and scribble erasing.
extension WorksheetView {
    private static func polyline(_ stroke: PKStroke) -> [PagePoint] {
        stroke.path.interpolatedPoints(by: .distance(3)).map {
            let point = $0.location.applying(stroke.transform); return PagePoint(x: point.x, y: point.y)
        }
    }
    func beginErase() {
        let drawing = (try? PKDrawing(data: pageContent.drawing)) ?? PKDrawing()
        eraseSession = EraseSession(base: pageContent, strokes: drawing.strokes)
        trailPoints = []; trailLink?.invalidate()
        eraseTrail.removeAllAnimations(); eraseTrail.opacity = 1; eraseTrail.path = nil; eraseTrail.isHidden = false
        let link = CADisplayLink(target: self, selector: #selector(updateEraseTrail)); link.add(to: .main, forMode: .common); trailLink = link
    }
    @objc private func updateEraseTrail() {
        let now = CACurrentMediaTime()
        trailPoints.removeAll { now - $0.time > 0.3 }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        eraseTrail.frame = bounds; eraseTrail.lineWidth = max(configuredWidth, 6)
        let path = UIBezierPath()
        for (index, entry) in trailPoints.enumerated() {
            if index == 0 { path.move(to: entry.point) } else { path.addLine(to: entry.point) }
        }
        if trailPoints.count == 1, let point = trailPoints.first?.point { path.addLine(to: point) }
        eraseTrail.path = trailPoints.isEmpty ? nil : path.cgPath
        CATransaction.commit()
    }
    private func endEraseTrail() {
        trailLink?.invalidate(); trailLink = nil; trailPoints = []
        guard !eraseTrail.isHidden, eraseTrail.path != nil else { eraseTrail.isHidden = true; return }
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            guard let self, self.trailLink == nil else { return }
            self.eraseTrail.isHidden = true; self.eraseTrail.path = nil
        }
        let fade = CABasicAnimation(keyPath: "opacity"); fade.fromValue = 1; fade.toValue = 0; fade.duration = 0.22
        eraseTrail.opacity = 0; eraseTrail.add(fade, forKey: "fade")
        CATransaction.commit()
    }
    /// Sweeps a capsule as wide as the pen (minimum 6 pt) from the last point.
    func eraseSweep(to point: PagePoint) {
        guard var session = eraseSession else { return }
        let from = session.last ?? point
        let radius = max(configuredWidth, 6) / 2
        let sweep = CGRect(x: min(from.x, point.x), y: min(from.y, point.y), width: abs(point.x - from.x), height: abs(point.y - from.y))
        var changed = false
        for index in session.strokes.indices where !session.marked.contains(index) {
            let stroke = session.strokes[index]
            guard stroke.renderBounds.insetBy(dx: -radius - 1, dy: -radius - 1).intersects(sweep) else { continue }
            let reach = radius + Self.drawnWidth(stroke) / 2 + 1
            let points = session.polylines[index] ?? Self.polyline(stroke)
            session.polylines[index] = points
            if StrokeHitTest.hits(sweep: from, point, radius: reach, stroke: points) { session.marked.insert(index); changed = true }
        }
        // Shapes: hit along the same swept width as ink; inside a fill only the fill goes.
        let targets = Self.shapeTargets(session.base.shapes.filter { !session.shapes.contains($0.id) }, from: from, to: point, radius: radius)
        if !targets.stroke.isEmpty { session.shapes.formUnion(targets.stroke); session.unfilled.subtract(targets.stroke); changed = true }
        let fills = targets.fill.subtracting(session.unfilled)
        if !fills.isEmpty { session.unfilled.formUnion(fills); changed = true }
        trailPoints.append((CGPoint(x: point.x + pageLayout.contentOrigin.x, y: point.y + pageLayout.contentOrigin.y), CACurrentMediaTime()))
        session.last = point
        eraseSession = session
        if changed { showErasePreview() }
    }
    private func showErasePreview() {
        guard let session = eraseSession else { return }
        let strokes = session.strokes.enumerated().map { index, stroke -> PKStroke in
            guard session.marked.contains(index) else { return stroke }
            let color = stroke.ink.color
            return PKStroke(ink: PKInk(stroke.ink.inkType, color: color.withAlphaComponent(color.cgColor.alpha * 0.28)),
                            path: stroke.path, transform: stroke.transform, mask: stroke.mask)
        }
        let wasUpdating = updating; updating = true
        canvas.drawing = PKDrawing(strokes: strokes).transformed(using: pageLayout.inkTranslation)
        canvasSource = nil; updating = wasUpdating
        dimErasedShapes()
    }
    func dimErasedShapes() {
        if let session = eraseSession { dimShapes(session.base.shapes, hit: session.shapes, unfilled: session.unfilled) }
        if let session = shapeErase { dimShapes(session.shapes, hit: session.hit, unfilled: session.unfilled, masks: session.masks) }
    }
    private func dimShapes(_ shapes: [ShapeObject], hit: Set<UUID>, unfilled: Set<UUID>, masks: [UUID: ShapeEraseMask] = [:]) {
        // Cut shapes show what will remain as ink; others dim until the lift.
        let pieces = masks.values.flatMap { mask in
            mask.runs.map { ShapeInkPiece(points: $0, color: mask.shape.color, width: mask.shape.lineWidth) }
        }
        shapeLayer.configure(shapes.compactMap { shape in
            // Only the fill goes: the fill dims, the outline stays.
            if !hit.contains(shape.id), unfilled.contains(shape.id) { var dimmed = shape; dimmed.fill?.alpha *= 0.28; return dimmed }
            guard hit.contains(shape.id) else { return shape }
            guard masks[shape.id] == nil else { return nil }
            var dimmed = shape; dimmed.color.alpha *= 0.28; dimmed.fill?.alpha *= 0.28; return dimmed
        }, origin: pageLayout.contentOrigin, pieces: pieces)
    }
    /// Shapes whose outline (`stroke`) or only whose visible fill (`fill`)
    /// the eraser capsule `from→to` with `radius` touches
    /// (`ShapeObject.eraseTarget`). Shared by both erasers.
    static func shapeTargets(_ shapes: [ShapeObject], from: PagePoint, to point: PagePoint, radius: Double) -> (stroke: Set<UUID>, fill: Set<UUID>) {
        var stroke = Set<UUID>(), fill = Set<UUID>()
        for shape in shapes {
            switch shape.eraseTarget(from: from, to: point, radius: radius) {
            case .stroke: stroke.insert(shape.id)
            case .fill: fill.insert(shape.id)
            case .none: break
            }
        }
        return (stroke, fill)
    }

    // MARK: Precision eraser and shapes
    // PencilKit's bitmap eraser only cuts ink. A solid, unfilled shape it
    // touches is cut along the eraser (`ShapeEraseMask`) and its remaining
    // pieces become native ink on lift, so they can be erased further like
    // any stroke; filled or dashed shapes are removed whole when the eraser
    // touches their outline, a filled one swept only inside loses just its
    // fill. All of it is merged into the gesture's ink undo step (`onEraseShapes`).

    func beginShapeErase() {
        guard !pageContent.shapes.isEmpty else { return }
        shapeErase = ShapeEraseSession(shapes: pageContent.shapes)
        // A fresh ink session, so the removal never merges into the previous
        // stroke's undo step even if PencilKit reports no tool use for a tap.
        onInkSession?()
    }
    /// The precision eraser's own width (`PKEraserTool(.fixedWidthBitmap)`).
    func precisionShapeSweep(to point: PagePoint) {
        guard var session = shapeErase, !session.lifted else { return }
        let from = session.last ?? point, radius = max(configuredWidth, 1) / 2
        var changed = false
        let whole = session.shapes.filter { !ShapeEraseMask.canErasePartially($0) && !session.hit.contains($0.id) }
        let targets = Self.shapeTargets(whole, from: from, to: point, radius: radius)
        if !targets.stroke.isEmpty { session.hit.formUnion(targets.stroke); session.unfilled.subtract(targets.stroke); changed = true }
        let fills = targets.fill.subtracting(session.unfilled)
        if !fills.isEmpty { session.unfilled.formUnion(fills); changed = true }
        for shape in session.shapes where ShapeEraseMask.canErasePartially(shape) {
            let reach = radius + shape.lineWidth / 2 + 1, box = shape.bounds
            guard min(from.x, point.x) - reach <= box.x + box.width, max(from.x, point.x) + reach >= box.x,
                  min(from.y, point.y) - reach <= box.y + box.height, max(from.y, point.y) + reach >= box.y else { continue }
            var mask = session.masks[shape.id] ?? ShapeEraseMask(shape)
            guard mask.erase(from: from, to: point, radius: radius) else { continue }
            session.masks[shape.id] = mask; session.hit.insert(shape.id); changed = true
        }
        session.last = point
        shapeErase = session
        if changed { dimErasedShapes() }
    }
    /// Shows the shapes again; nothing was published.
    func cancelShapeErase() {
        guard let session = shapeErase else { return }
        shapeErase = nil
        if !session.hit.isEmpty || !session.unfilled.isEmpty { shapeLayer.configure(pageContent.shapes, origin: pageLayout.contentOrigin) }
    }
    /// Removes the touched shapes and adds the remaining pieces of cut ones as
    /// ink, in one content change. While PencilKit still uses its eraser the
    /// lift waits for its tool end (`force` skips that wait), so the ink taken
    /// from the canvas already contains the eraser's last cut.
    func finishShapeErase(force: Bool = false) {
        guard var session = shapeErase else { return }
        guard !session.hit.isEmpty || !session.unfilled.isEmpty, editable, pageContent.shapes == session.shapes else { cancelShapeErase(); return }
        if inkActive && !force { session.lifted = true; shapeErase = session; return }
        shapeErase = nil
        var next = pageContent
        next.shapes = next.shapes.filter { !session.hit.contains($0.id) }.map { session.unfilled.contains($0.id) ? $0.removingFill : $0 }
        let pieces = session.masks.values.flatMap { mask in mask.runs.map { Self.inkPiece($0, of: mask.shape) } }
        if !pieces.isEmpty {
            next.drawing = PKDrawing(strokes: canonicalCanvasDrawing.strokes + pieces).dataRepresentation()
        }
        if onEraseShapes?(next, pageContent) == true {
            if pieces.isEmpty { pageContent.shapes = next.shapes } else { installContent(next) }
        }
        shapeLayer.configure(pageContent.shapes, origin: pageLayout.contentOrigin)
    }
    /// A remaining shape piece as native pen ink in the shape's colour and
    /// visible width, control points about every 2 pt.
    static func inkPiece(_ points: [PagePoint], of shape: ShapeObject) -> PKStroke {
        let thinned = points.enumerated().filter { $0.offset % 2 == 0 || $0.offset == points.count - 1 }.map(\.element)
        // Point size per visible width of pen ink (`InkWidthCalibration`).
        let side = shape.lineWidth * InkWidthCalibration.pointScale(.pen)
        return InkWidthCalibration.stroke(thinned.map { CGPoint(x: $0.x, y: $0.y) }, side: side, ink: PKInk(.pen, color: shape.color.uiColor))
    }
    /// Restores the visible state; nothing was ever published.
    func cancelErase() {
        guard let session = eraseSession else { return }
        eraseSession = nil; endEraseTrail()
        guard !session.marked.isEmpty || !session.shapes.isEmpty || !session.unfilled.isEmpty else { return }
        installContent(pageContent)
        shapeLayer.configure(pageContent.shapes, origin: pageLayout.contentOrigin)
    }
    /// One content change (and so one undo step) for every stroke/shape marked.
    func finishErase() {
        guard let session = eraseSession else { return }
        guard !session.marked.isEmpty || !session.shapes.isEmpty || !session.unfilled.isEmpty, editable, pageContent == session.base else { cancelErase(); return }
        eraseSession = nil; endEraseTrail()
        var next = session.base
        next.drawing = PKDrawing(strokes: session.strokes.enumerated().filter { !session.marked.contains($0.offset) }.map(\.element)).dataRepresentation()
        next.shapes = session.base.shapes.filter { !session.shapes.contains($0.id) }
            .map { session.unfilled.contains($0.id) ? $0.removingFill : $0 }
        if onContent?(next, session.base) == true { installContent(next) } else { installContent(pageContent) }
        shapeLayer.configure(pageContent.shapes, origin: pageLayout.contentOrigin)
    }
    /// "Durchkritzeln löscht": a finished pen scribble over existing ink and
    /// shapes removes the strokes it covers together with itself; the shapes
    /// it covers are returned and removed by the caller after the ink is
    /// published, in the same ink undo step (`onEraseShapes`, like the
    /// eraser). The scribble was never published, so the change is one ink
    /// step from before it.
    @discardableResult
    func eraseByScribble(previousCount: Int) -> Set<UUID> {
        let strokes = canonicalCanvasDrawing.strokes
        guard strokes.count == previousCount + 1, let scribble = strokes.last,
              scribble.ink.inkType != .marker else { return [] }
        let points = Self.polyline(scribble)
        guard ScribbleErase.isScribble(points) else { return [] }
        let others = Array(strokes.dropLast())
        let hull = CGRect(x: points.map(\.x).min()!, y: points.map(\.y).min()!, width: 0, height: 0)
            .union(CGRect(x: points.map(\.x).max()!, y: points.map(\.y).max()!, width: 0, height: 0)).insetBy(dx: -8, dy: -8)
        let candidates = others.indices.filter { others[$0].renderBounds.intersects(hull) }
        let padding = max(4, Self.drawnWidth(scribble))
        let covered = ScribbleErase.coveredStrokes(scribble: points, strokes: candidates.map { Self.polyline(others[$0]) },
                                                   padding: padding).map { candidates[$0] }
        let shapes = pageContent.shapes.filter { $0.bounds.cgRect.intersects(hull) }
        let coveredShapes = Set(ScribbleErase.coveredShapes(scribble: points, shapes: shapes, padding: padding))
        guard !covered.isEmpty || !coveredShapes.isEmpty else { return [] }
        let removed = Set(covered)
        let wasUpdating = updating; updating = true
        canvas.drawing = PKDrawing(strokes: others.enumerated().filter { !removed.contains($0.offset) }.map(\.element))
            .transformed(using: pageLayout.inkTranslation)
        canvasSource = nil; updating = wasUpdating
        return coveredShapes
    }
    /// Shapes covered by a scribble, after its ink change was published: one
    /// content change merged into the same ink undo step.
    func removeScribbledShapes(_ ids: Set<UUID>) {
        guard !ids.isEmpty, editable else { return }
        var next = pageContent
        next.shapes.removeAll { ids.contains($0.id) }
        guard next.shapes != pageContent.shapes, onEraseShapes?(next, pageContent) == true else { return }
        pageContent.shapes = next.shapes
        shapeLayer.configure(pageContent.shapes, origin: pageLayout.contentOrigin)
    }
}
