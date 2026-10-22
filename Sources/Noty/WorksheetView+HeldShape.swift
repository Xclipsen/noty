import SwiftUI
import PencilKit
import NotebookCore

/// Held strokes: shape recognition while the Pencil rests, live resize, commit.
extension WorksheetView {
    func previewHeldStroke() {
        guard editable, holdEnabled, heldShape == nil, holdBase != nil, tool.isInk,
              let first = holdPoints.first, let last = holdPoints.last else { return }
        let recognized = ShapeRecognition.shape(holdPoints)
            ?? (ShapeRecognition.lineAfterHold(holdPoints) ? .line(start: first, end: LineSnapping.end(from: first, to: last)) : nil)
        guard let recognized, let base = holdBase else { return }
        if tool == .marker { guard case .line = recognized else { return } }
        heldColor = InkColor(Color(lastColor ?? .black))
        // Width of a pen shape: what the drawn ink shows (PencilKit point sizes,
        // learned per tool width from the last stroke, render thinner than
        // they are). Ink results use the learned point size itself and are
        // previewed by PencilKit; neither is re-measured at commit.
        heldWidth = min(40, max(0.5, heldPointSize / InkWidthCalibration.pointScale(inkType)))
        // A stroke that left the page/canvas is clipped (lines, arrows) or
        // moved onto the page (closed shapes) instead of being dropped.
        guard let shape = fittedHeld(recognized, width: heldWidth, allowShift: true) else { return }
        heldShape = shape
        heldAdjustment = HeldShapeAdjustment(shape: shape, grab: last)
        heldInk = (canvas.tool as? PKInkingTool)?.ink ?? PKInk(inkType, color: heldColor.uiColor)
        let frame = renderViewport?.frame.cgRect ?? bounds
        let scale = min(4, 2048 / max(1, frame.width, frame.height))
        let drawing = ((try? PKDrawing(data: base.drawing)) ?? PKDrawing()).transformed(using: pageLayout.inkTranslation)
        heldInkImage.frame = frame
        canvas.traitCollection.performAsCurrent {
            heldInkImage.image = drawing.image(from: frame, scale: scale).withRenderingMode(.alwaysOriginal)
        }
        heldInkImage.isHidden = false; canvas.layer.opacity = 0
        updateHeldPath()
        if #available(iOS 17.5, *), let feedback = holdFeedback as? UICanvasFeedbackGenerator, let end = shape.outline().last {
            feedback.pathCompleted(at: CGPoint(x: end.x + pageLayout.contentOrigin.x, y: end.y + pageLayout.contentOrigin.y))
        }
    }
    /// `shape` on the page for a stroke of `width`: unchanged when it fits,
    /// otherwise clipped/moved (`HeldShapeFitting`); nil keeps the freehand
    /// ink. The padding is what the model validates for an object (its
    /// bounds) or the stroke's half width, plus a margin against rounding.
    func fittedHeld(_ shape: RecognizedShape, width: CGFloat, allowShift: Bool) -> RecognizedShape? {
        if case let .line(start, end) = shape, hypot(end.x - start.x, end.y - start.y) < 1 { return nil }
        let pad = max(width / 2, shape.object(color: heldColor, lineWidth: min(40, max(0.5, width)))?.padding ?? 0) + 0.05
        return HeldShapeFitting.fit(shape, in: PageRect(pageLayout.canonicalInkBounds), padding: pad, allowShift: allowShift)
    }
    /// PencilKit point size the current tool draws (learned ratio × tool width).
    var heldPointSize: CGFloat { configuredWidth * (drawnWidthRatio[inkType] ?? 1) }
    /// Pen results become editable shapes (lines, arrows, polylines, polygons,
    /// rectangles, circles) of the held width; the rest native ink. Pencil
    /// results always stay native ink, keeping the graphite texture.
    private func heldObject(_ shape: RecognizedShape?) -> ShapeObject? {
        guard tool == .pen, let shape = shape?.object(color: heldColor, lineWidth: min(40, max(0.5, heldWidth))),
              (try? shape.validate()) != nil else { return nil }
        return shape
    }
    /// Head length of an ink arrow, as `ShapeObject.arrowHead` draws it.
    private var heldHeadLength: Double { max(10, heldWidth * 3) }
    /// The shape object a held pen stroke commits (nil: native ink result).
    private func heldResultObject(_ shape: RecognizedShape) -> ShapeObject? {
        heldObject(fittedHeld(shape, width: heldWidth, allowShift: true) ?? shape)
    }
    /// The PencilKit stroke a held ink result commits: along the recognised
    /// shape with the learned point size of the tool (what its strokes draw)
    /// and the opacity/force/tilt of a typical drawn point. Nil when it would
    /// leave the page (the freehand ink stays).
    private func heldInkStroke(_ shape: RecognizedShape) -> PKStroke? {
        let ink = heldInk ?? PKInk(inkType, color: heldColor.uiColor)
        let fitted = fittedHeld(shape, width: max(heldWidth, heldPointSize), allowShift: true) ?? shape
        let size = CGSize(width: heldPointSize, height: heldPointSize)
        let template = drawnPointTemplate[ink.inkType]
        let path = fitted.outline(spacing: 8, headLength: heldHeadLength)
        let points = path.indices.map { index in
            PKStrokePoint(location: CGPoint(x: path[index].x, y: path[index].y), timeOffset: Double(index) * 0.01, size: size,
                          opacity: template?.opacity ?? 1, force: template?.force ?? 1,
                          azimuth: template?.azimuth ?? 0, altitude: template?.altitude ?? .pi / 2)
        }
        let stroke = PKStroke(ink: ink, path: PKStrokePath(controlPoints: points, creationDate: Date()))
        guard pageLayout.canonicalInkBounds.insetBy(dx: -0.02, dy: -0.02).contains(stroke.renderBounds) else { return nil }
        return stroke
    }
    /// Preview = result: a pen shape is drawn exactly like `ShapeRendering`
    /// (same path, width, colour, caps, dashes); an ink result is the very
    /// PencilKit stroke that will be committed, rendered by PencilKit at the
    /// current zoom (no width calibration in between).
    func updateHeldPath() {
        guard let shape = heldShape else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true); defer { CATransaction.commit() }
        if let object = heldResultObject(shape) {
            heldStroke = nil; heldStrokeImage.isHidden = true; heldStrokeImage.image = nil
            let path = ShapeRendering.path(object)
            path.apply(pageLayout.inkTranslation)
            heldShapeLayer.frame = bounds
            heldShapeLayer.path = path.cgPath; heldShapeLayer.lineWidth = object.lineWidth
            heldShapeLayer.strokeColor = object.color.uiColor.cgColor
            heldShapeLayer.lineDashPattern = ShapeRendering.dashes(object).map { NSNumber(value: Double($0)) }
            heldShapeLayer.isHidden = false
            heldInkImage.isHidden = heldInkImage.image == nil; canvas.layer.opacity = 0
            return
        }
        heldShapeLayer.isHidden = true; heldShapeLayer.path = nil
        guard let stroke = heldInkStroke(shape) else {
            // No result fits the page: the freehand ink stays, so it is shown.
            heldStroke = nil; heldStrokeImage.isHidden = true; heldStrokeImage.image = nil
            heldInkImage.isHidden = true; canvas.layer.opacity = 1
            return
        }
        heldStroke = stroke
        let translated = PKDrawing(strokes: [stroke]).transformed(using: pageLayout.inkTranslation)
        let rect = translated.bounds.insetBy(dx: -2, dy: -2).integral
        guard rect.width > 0, rect.height > 0 else { return }
        let scale = min(screenScale * (window?.screen.scale ?? 2), 4096 / max(1, rect.width, rect.height))
        canvas.traitCollection.performAsCurrent {
            heldStrokeImage.image = translated.image(from: rect, scale: max(0.5, scale)).withRenderingMode(.alwaysOriginal)
        }
        heldStrokeImage.frame = rect
        heldStrokeImage.isHidden = false
        heldInkImage.isHidden = heldInkImage.image == nil; canvas.layer.opacity = 0
    }
    func clearHeldPreview() {
        resetHeldState()
        hideHeldVisuals()
    }
    private func resetHeldState() {
        heldShape = nil; heldAdjustment = nil; holdBase = nil; holdPoints = []
        heldStroke = nil; heldInk = nil
        holdCompletion = StrokeCompletionGate()
    }
    func hideHeldVisuals() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        heldInkImage.isHidden = true; heldInkImage.image = nil
        heldStrokeImage.isHidden = true; heldStrokeImage.image = nil
        heldShapeLayer.isHidden = true; heldShapeLayer.path = nil; canvas.layer.opacity = 1
        CATransaction.commit()
    }
    /// A held line whose lift is done but whose final PencilKit callback never
    /// came: commit it before the next touch (or after the fallback delay)
    /// instead of silently keeping the freehand stroke.
    func commitPendingHeldStroke() {
        guard heldShape != nil, holdCompletion.lifted, !inkActive else { return }
        finishHeldStroke(serial: holdSerial, force: true)
    }
    func finishHeldStroke(serial: Int, force: Bool = false) {
        guard serial == holdSerial, force || holdCompletion.canCommit, !inkActive, editable, let shape = heldShape, let base = holdBase else { return }
        let canonical = canvas.drawing.transformed(using: pageLayout.inkTranslation.inverted())
        let oldDrawing = (try? PKDrawing(data: base.drawing)) ?? PKDrawing()
        let source = canonical.strokes.count > oldDrawing.strokes.count ? canonical.strokes.last : nil
        if force && source == nil { return }
        let previous = pageContent
        let currentData = canonical.dataRepresentation()
        // Keep the expected published state. Replace the finalized live stroke
        // once: same ink and drawn point attributes (never the bare tool width,
        // which rendered as a hairline), or an editable shape of the drawn width.
        var next = previous
        // Exactly what the preview shows: the same shape object, or the very
        // PencilKit stroke the preview rendered.
        if let object = heldResultObject(shape) {
            next.drawing = oldDrawing.dataRepresentation(); next.shapes.append(object)
        } else {
            guard let stroke = heldStroke ?? heldInkStroke(shape) else {
                clearHeldPreview(); canvasViewDrawingDidChange(canvas); return
            }
            next.drawing = PKDrawing(strokes: oldDrawing.strokes + [stroke]).dataRepresentation()
        }
        // The model records stroke → shape/line as one notebook-wide undo step.
        if onContent?(next, previous) == true {
            installContent(next)
            shapeLayer.configure(next.shapes, origin: pageLayout.contentOrigin)
            clearHeldPreview()
        } else {
            clearHeldPreview()
            if currentData != previous.drawing { canvasViewDrawingDidChange(canvas) }
        }
    }
    /// Median drawn point width in page units (the visible stroke width).
    static func drawnWidth(_ stroke: PKStroke) -> CGFloat {
        let t = stroke.transform, scale = sqrt(abs(t.a * t.d - t.b * t.c))
        let widths = stroke.path.map { min($0.size.width, $0.size.height) * scale }.sorted()
        return widths.isEmpty ? 0 : widths[widths.count / 2]
    }
    /// Widest drawn point in page units (how far the stroke renders).
    static func maximumDrawnWidth(_ stroke: PKStroke) -> CGFloat {
        let t = stroke.transform, scale = sqrt(abs(t.a * t.d - t.b * t.c))
        return stroke.path.map { max($0.size.width, $0.size.height) * scale }.max() ?? 0
    }
    /// Learns PencilKit's drawn width per tool width, so the next held preview
    /// shows the width the replacement will actually have.
    func recordDrawnWidth(_ strokes: [PKStroke], previousCount: Int) {
        guard let stroke = strokes.last, configuredWidth > 0, strokes.count == previousCount + 1 else { return }
        let width = Self.drawnWidth(stroke)
        if width > 0 { drawnWidthRatio[stroke.ink.inkType] = width / configuredWidth }
        let points = stroke.path.sorted { min($0.size.width, $0.size.height) < min($1.size.width, $1.size.height) }
        if !points.isEmpty { drawnPointTemplate[stroke.ink.inkType] = points[points.count / 2] }
    }
    /// Rebuilds a finished stroke along `path` (page units). Size, opacity,
    /// force and tilt come from the drawn points at the same arc-length
    /// fraction: PencilKit's own point sizes differ from the tool width (marker
    /// tip, pressure, zoom), so a constant tool width rendered far thinner.
    func inkStroke(from source: PKStroke?, ink: PKInk, path: [PagePoint], sizeScale: CGFloat = 1) -> PKStroke {
        let drawn = source.map { Array($0.path) } ?? []
        let transform = source?.transform ?? .identity
        let scale = sqrt(abs(transform.a * transform.d - transform.b * transform.c)) * sizeScale
        let fractions = StraightStroke.arcFractions(path)
        let indices = StraightStroke.sampleIndices(along: drawn.map {
            let point = $0.location.applying(transform); return PagePoint(x: point.x, y: point.y)
        }, fractions: fractions)
        var time = -1.0
        let points = path.indices.map { index -> PKStrokePoint in
            let location = CGPoint(x: path[index].x, y: path[index].y)
            guard index < indices.count else {
                time = max(fractions[index], time + 0.001)
                return PKStrokePoint(location: location, timeOffset: time, size: CGSize(width: heldPointSize, height: heldPointSize),
                    opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
            }
            let sample = drawn[indices[index]]
            time = max(sample.timeOffset, time + 0.001)
            let size = CGSize(width: sample.size.width * scale, height: sample.size.height * scale)
            if #available(iOS 26.0, *) {
                return PKStrokePoint(location: location, timeOffset: time, size: size, opacity: sample.opacity, force: sample.force,
                    azimuth: sample.azimuth, altitude: sample.altitude, secondaryScale: sample.secondaryScale, threshold: sample.threshold)
            }
            return PKStrokePoint(location: location, timeOffset: time, size: size, opacity: sample.opacity, force: sample.force,
                azimuth: sample.azimuth, altitude: sample.altitude, secondaryScale: sample.secondaryScale)
        }
        return PKStroke(ink: ink, path: PKStrokePath(controlPoints: points, creationDate: source?.path.creationDate ?? Date()))
    }
}
