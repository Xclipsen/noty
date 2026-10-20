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
        // Shapes: hit along the same swept width as ink.
        let steps = max(1, Int((hypot(point.x - from.x, point.y - from.y) / radius).rounded(.up)))
        let samples = (0...steps).map { CGPoint(x: from.x + (point.x - from.x) * Double($0) / Double(steps), y: from.y + (point.y - from.y) * Double($0) / Double(steps)) }
        for shape in session.base.shapes where !session.shapes.contains(shape.id) {
            let path = ShapeRendering.path(shape)
            let outline = path.cgPath.copy(strokingWithWidth: shape.lineWidth + 2 * radius, lineCap: .round, lineJoin: .round, miterLimit: 4)
            if samples.contains(where: { outline.contains($0) || (shape.fill != nil && path.contains($0)) }) { session.shapes.insert(shape.id); changed = true }
        }
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
        guard let session = eraseSession else { return }
        shapeLayer.configure(session.base.shapes.map { shape in
            guard session.shapes.contains(shape.id) else { return shape }
            var dimmed = shape; dimmed.color.alpha *= 0.28; dimmed.fill?.alpha *= 0.28; return dimmed
        }, origin: pageLayout.contentOrigin)
    }
    /// Restores the visible state; nothing was ever published.
    func cancelErase() {
        guard let session = eraseSession else { return }
        eraseSession = nil; endEraseTrail()
        guard !session.marked.isEmpty || !session.shapes.isEmpty else { return }
        installContent(pageContent)
        shapeLayer.configure(pageContent.shapes, origin: pageLayout.contentOrigin)
    }
    /// One content change (and so one undo step) for every stroke/shape marked.
    func finishErase() {
        guard let session = eraseSession else { return }
        guard !session.marked.isEmpty || !session.shapes.isEmpty, editable, pageContent == session.base else { cancelErase(); return }
        eraseSession = nil; endEraseTrail()
        var next = session.base
        next.drawing = PKDrawing(strokes: session.strokes.enumerated().filter { !session.marked.contains($0.offset) }.map(\.element)).dataRepresentation()
        next.shapes = session.base.shapes.filter { !session.shapes.contains($0.id) }
        if onContent?(next, session.base) == true { installContent(next) } else { installContent(pageContent) }
        shapeLayer.configure(pageContent.shapes, origin: pageLayout.contentOrigin)
    }
    /// "Durchkritzeln löscht": a finished pen scribble over existing ink
    /// removes the strokes it covers together with itself. The scribble was
    /// never published, so the change is one ink step from before it.
    func eraseByScribble(previousCount: Int) {
        let strokes = canonicalCanvasDrawing.strokes
        guard strokes.count == previousCount + 1, let scribble = strokes.last,
              scribble.ink.inkType != .marker else { return }
        let points = Self.polyline(scribble)
        guard ScribbleErase.isScribble(points) else { return }
        let others = Array(strokes.dropLast())
        let hull = CGRect(x: points.map(\.x).min()!, y: points.map(\.y).min()!, width: 0, height: 0)
            .union(CGRect(x: points.map(\.x).max()!, y: points.map(\.y).max()!, width: 0, height: 0)).insetBy(dx: -8, dy: -8)
        let candidates = others.indices.filter { others[$0].renderBounds.intersects(hull) }
        let covered = ScribbleErase.coveredStrokes(scribble: points, strokes: candidates.map { Self.polyline(others[$0]) },
                                                   padding: max(4, Self.drawnWidth(scribble))).map { candidates[$0] }
        guard !covered.isEmpty else { return }
        let removed = Set(covered)
        let wasUpdating = updating; updating = true
        canvas.drawing = PKDrawing(strokes: others.enumerated().filter { !removed.contains($0.offset) }.map(\.element))
            .transformed(using: pageLayout.inkTranslation)
        canvasSource = nil; updating = wasUpdating
    }
}
