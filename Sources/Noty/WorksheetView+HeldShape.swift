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
        // One width for preview and result: what the drawn ink shows. PencilKit
        // point sizes (learned per tool width from the last stroke) render
        // thinner than they are; the preview layer and shape objects stroke
        // exactly their width. Not re-measured at commit (pressure while
        // holding made the result differ from the preview).
        heldWidth = min(40, max(0.5, heldPointSize / InkWidthCalibration.pointScale(inkType)))
        // A stroke that left the page/canvas is clipped (lines, arrows) or
        // moved onto the page (closed shapes) instead of being dropped.
        guard let shape = fittedHeld(recognized, width: heldWidth, allowShift: true) else { return }
        heldShape = shape
        heldAdjustment = HeldShapeAdjustment(shape: shape, grab: last)
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
    func updateHeldPath() {
        guard let shape = heldShape else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        heldShapeLayer.frame = bounds
        let path: UIBezierPath
        let object = heldObject(shape)
        // The preview is the object itself: same path, width, colour and caps
        // as `ShapeRendering.draw` after lifting.
        if let object { path = ShapeRendering.path(object) }
        else {
            path = UIBezierPath()
            for (index, point) in shape.outline(headLength: heldHeadLength).enumerated() {
                if index == 0 { path.move(to: CGPoint(x: point.x, y: point.y)) } else { path.addLine(to: CGPoint(x: point.x, y: point.y)) }
            }
        }
        path.apply(pageLayout.inkTranslation)
        heldShapeLayer.path = path.cgPath; heldShapeLayer.lineWidth = object.map { CGFloat($0.lineWidth) } ?? heldWidth
        heldShapeLayer.strokeColor = object.map { $0.color.uiColor.cgColor }
            ?? heldColor.uiColor.withAlphaComponent(heldColor.alpha * (tool == .marker && markerTip == .chisel ? 0.35 : tool == .pencil ? 0.8 : 1)).cgColor
        heldShapeLayer.isHidden = false
        CATransaction.commit()
    }
    func clearHeldPreview() {
        heldShape = nil; heldAdjustment = nil; holdBase = nil; holdPoints = []
        holdCompletion = StrokeCompletionGate()
        heldInkImage.isHidden = true; heldInkImage.image = nil
        heldShapeLayer.isHidden = true; heldShapeLayer.path = nil; canvas.layer.opacity = 1
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
        // The shape keeps exactly the preview's width (and so its fit).
        if let object = heldObject(fittedHeld(shape, width: heldWidth, allowShift: true) ?? shape) {
            next.drawing = oldDrawing.dataRepresentation(); next.shapes.append(object)
        } else {
            let ink = source?.ink ?? PKInk(inkType, color: heldColor.uiColor)
            // Drawn point sizes scaled to the size the preview showed: the
            // replacement ink is as wide as its preview, pressure variation kept.
            let drawn = source.map(Self.drawnWidth) ?? 0
            let sizeScale = drawn > 0.01 ? heldPointSize / drawn : 1
            let reach = max(heldWidth, (source.map(Self.maximumDrawnWidth) ?? 0) * sizeScale)
            let fitted = fittedHeld(shape, width: reach, allowShift: true) ?? shape
            let stroke = inkStroke(from: source, ink: ink, path: fitted.outline(spacing: 8, headLength: heldHeadLength), sizeScale: sizeScale)
            guard pageLayout.canonicalInkBounds.insetBy(dx: -0.02, dy: -0.02).contains(stroke.renderBounds) else {
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
