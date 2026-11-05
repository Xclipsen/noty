import SwiftUI
import PencilKit
import NotebookCore

/// A stroke at noty's ruler, in page (canonical) coordinates. Its edge
/// (`RulerStroke.guide`) is fixed when it begins.
struct RulerLine {
    struct Sample {
        var location: PagePoint
        var time: TimeInterval
        var azimuth: CGFloat
        var altitude: CGFloat
    }
    /// PencilKit drew the beginning until the stroke reached the capture
    /// zone; the ruler way took it over there (`WorksheetView.handOver`).
    struct Handoff {
        /// Strokes on the canvas before PencilKit's part.
        var baseCount: Int
        var at: CFTimeInterval
        /// PencilKit kept its part (cancelling its recognizer ends a stroke);
        /// false: it dropped it, the ruler stroke then draws it, too.
        var kept: Bool?
        /// Samples of PencilKit's part.
        var prefix: [Sample]
    }
    let id = UUID()
    var stroke: RulerStroke
    var samples: [Sample] = []
    var ink: PKInk
    /// PencilKit point size (learned, `InkPointMemory`) and the visible width.
    var size: CGFloat
    var visibleWidth: CGFloat
    var template: InkPointTemplate?
    var handoff: Handoff?
    /// Lifted, waiting a moment to learn whether PencilKit kept its part.
    var finishing = false
    /// Drawn with a finger (Fingermalmodus): two fingers scrolling or zooming end it.
    var finger = false
    /// PencilKit's part is not on the canvas: the ruler stroke covers it.
    var drawsPrefix: Bool { handoff.map { $0.kept != true } ?? false }
}

/// An ordinary PencilKit stroke watched while the ruler is out.
struct RulerWatch {
    var guide: RulerGuide
    var samples: [RulerLine.Sample] = []
    var length = 0.0
}

/// noty's ruler on a sheet. Only strokes at the ruler use the ruler way: one
/// that starts on the band or in the capture zone (`RulerStrokeGesture`,
/// PencilKit waits for it), or an ordinary PencilKit stroke as soon as it
/// reaches the zone (`RulerWatchGesture`, `handOver`). Everything else, also
/// handwriting right beside the ruler, stays a PencilKit stroke with pressure.
/// The way (`RulerStroke`) runs straight along the edge or stays free, never
/// across it; it is cut at the page edge. The result is PencilKit ink with the
/// learned point size and look of the tool (`InkPointMemory`), appended to the
/// canvas and published like a PencilKit stroke (`onDrawing`): one undo step,
/// held during a backup commit instead of dropped.
extension WorksheetView {
    func configureRulerStroke() {
        rulerStroke.addTarget(self, action: #selector(rulerStroked(_:)))
        rulerStroke.isEnabled = false
        rulerStroke.takes = { [weak self] touch in self?.rulerTakes(touch) ?? false }
        addGestureRecognizer(rulerStroke)
        canvas.drawingGestureRecognizer.require(toFail: rulerStroke)
        rulerWatch.isEnabled = false
        rulerWatch.onBegin = { [weak self] touch in self?.watchBegan(touch) }
        rulerWatch.onSamples = { [weak self] touches in self?.watchSamples(touches) }
        rulerWatch.onEnd = { [weak self] end in self?.watchEnded(end) }
        addGestureRecognizer(rulerWatch)
    }
    /// The preview lies where the result lies: above the ink (on the canvas
    /// it is drawn over what is there), below text and objects being edited.
    func installRulerPreview(above below: CALayer) {
        layer.insertSublayer(rulerPreview, above: below)
        rulerPreview.fillColor = UIColor.clear.cgColor; rulerPreview.lineCap = .round; rulerPreview.lineJoin = .round
        rulerPreview.isHidden = true
    }
    /// Ruler way on or off: on every visible, editable page while the ruler is
    /// out, and never off in the middle of a stroke (a backup commit locks the
    /// page for a moment).
    func updateRulerGestures() {
        let running = rulerLine != nil || rulerStroke.tracking
        let on = EditorInteractionPolicy.rulerStrokeEnabled(ruler: configuration?.ruler == true, editable: editable,
                                                            inkTool: tool.isInk, running: running)
        if rulerStroke.isEnabled != on { rulerStroke.isEnabled = on }
        let watching = on || rulerWatching != nil
        if rulerWatch.isEnabled != watching { rulerWatch.isEnabled = watching }
        let finger = configuration?.fingerDrawing == true
        rulerStroke.allowFinger = finger; rulerWatch.allowFinger = finger
    }

    /// A stroke starting here follows the ruler from its start. A finger on
    /// the band moves the ruler instead.
    private func rulerTakes(_ touch: UITouch) -> Bool {
        guard let overlay = rulerView, !overlay.isHidden, let ruler = overlay.ruler else { return false }
        let point = touch.location(in: overlay), page = PagePoint(x: point.x, y: point.y)
        if touch.type == .direct, ruler.contains(page) { return false }
        return ruler.captures(page)
    }
    /// The edge of `side` in page coordinates, with the capture zone and the
    /// ink's visible half width (not the larger PencilKit point size, which
    /// left a gap).
    private func rulerGuide(side: Double) -> RulerGuide? {
        guard let overlay = rulerView, let ruler = overlay.ruler else { return nil }
        let edge = ruler.edgeLine(side: side), page = pageLayout.inkTranslation.inverted()
        func canonical(_ point: PagePoint) -> CGPoint { overlay.convert(CGPoint(x: point.x, y: point.y), to: self).applying(page) }
        let a = canonical(edge.start), beside = canonical(PagePoint(x: edge.start.x + edge.outward.x, y: edge.start.y + edge.outward.y))
        // Page points per screen point: the zone is about 10 pt on the screen at any zoom.
        let unit = hypot(beside.x - a.x, beside.y - a.y)
        guard unit > 0.0001, unit.isFinite else { return nil }
        return RulerGuide(edge: PagePoint(x: a.x, y: a.y), outward: PagePoint(x: (beside.x - a.x) / unit, y: (beside.y - a.y) / unit),
                          inkOffset: rulerVisibleWidth / 2, capture: NotebookRuler.captureDistance * unit)
    }
    private var rulerVisibleWidth: CGFloat { min(40, max(0.5, heldPointSize / InkWidthCalibration.pointScale(inkType))) }
    private func rulerSample(_ touch: UITouch) -> RulerLine.Sample {
        let point = touch.location(in: self).applying(pageLayout.inkTranslation.inverted())
        let pencil = touch.type == .pencil
        return .init(location: PagePoint(x: point.x, y: point.y), time: touch.timestamp,
                     azimuth: pencil ? touch.azimuthAngle(in: self) : 0, altitude: pencil ? touch.altitudeAngle : .pi / 2)
    }

    // MARK: Strokes that start at the ruler

    @objc func rulerStroked(_ gesture: RulerStrokeGesture) {
        switch gesture.state {
        case .began: beginRulerLine(gesture)
        case .changed: addRulerSamples(gesture.takeSamples())
        case .ended: addRulerSamples(gesture.takeSamples()); finishRulerLine(commit: true)
        // Cancelled by the system: what was drawn stays; a second finger is navigation.
        case .cancelled: addRulerSamples(gesture.takeSamples()); finishRulerLine(commit: !gesture.navigation)
        default: finishRulerLine(commit: false)
        }
    }
    private func beginRulerLine(_ gesture: RulerStrokeGesture) {
        settlePendingRulerLine()
        let touches = gesture.takeSamples()
        guard let first = touches.first, let overlay = rulerView, let ruler = overlay.ruler else { return }
        let point = first.location(in: overlay)
        guard let guide = rulerGuide(side: ruler.side(of: PagePoint(x: point.x, y: point.y))) else { return }
        startRulerLine(RulerStroke(guide: guide), handoff: nil, finger: first.type == .direct)
        onInkSession?() // one undo step, like a PencilKit stroke
        addRulerSamples(touches)
    }
    private func startRulerLine(_ stroke: RulerStroke, handoff: RulerLine.Handoff?, finger: Bool) {
        if heldVisualsPending != nil { hideHeldVisuals() }
        hideRulerPreview()
        let ink = (canvas.tool as? PKInkingTool)?.ink ?? PKInk(inkType, color: lastColor ?? .black)
        let template = InkPointMemory.shared.template(ink.inkType)
        let visible = rulerVisibleWidth
        rulerLine = RulerLine(stroke: stroke, ink: ink, size: heldPointSize, visibleWidth: visible, template: template, handoff: handoff, finger: finger)
        inkActive = true; holdBase = nil
        objectLayer.endTouchSelection()
        claimSelectionFocus()
        // The colour as set (a highlighter keeps its transparency) and the
        // drawn points' opacity, like the ink that follows.
        let alpha = ink.color.cgColor.alpha
        CATransaction.begin(); CATransaction.setDisableActions(true)
        rulerPreview.frame = bounds
        rulerPreview.lineWidth = visible
        rulerPreview.strokeColor = ink.color.withAlphaComponent(alpha * (template?.opacity ?? 1)).cgColor
        rulerPreview.path = nil; rulerPreview.isHidden = false
        CATransaction.commit()
    }
    private func addRulerSamples(_ touches: [UITouch]) {
        guard var line = rulerLine, !line.finishing, !touches.isEmpty else { return }
        // A second finger elsewhere started scrolling or zooming: navigation, no stroke.
        if line.finger, viewportNavigating { finishRulerLine(commit: false); return }
        for touch in touches {
            let sample = rulerSample(touch)
            line.samples.append(sample); line.stroke.add(sample.location)
        }
        rulerLine = line
        updateRulerPreview()
    }

    /// The notebook scrolls or zooms by two fingers (`isViewportNavigation`).
    private var viewportNavigating: Bool {
        var view = superview
        while let current = view {
            if let scroll = current as? UIScrollView, !(scroll is PKCanvasView) {
                return [scroll.panGestureRecognizer.state, scroll.pinchGestureRecognizer?.state].contains { $0 == .began || $0 == .changed }
            }
            view = current.superview
        }
        return false
    }

    // MARK: Ordinary strokes that reach the ruler

    private func watchBegan(_ touch: UITouch) {
        rulerWatching = nil
        settlePendingRulerLine()
        guard rulerLine == nil, tool.isInk, let overlay = rulerView, !overlay.isHidden, let ruler = overlay.ruler else { return }
        let point = touch.location(in: overlay), page = PagePoint(x: point.x, y: point.y)
        // Taken from its start (`RulerStrokeGesture`), or a finger moving the ruler.
        if ruler.captures(page) || (touch.type == .direct && ruler.contains(page)) { return }
        guard let guide = rulerGuide(side: ruler.side(of: page)) else { return }
        rulerWatching = RulerWatch(guide: guide)
    }
    private func watchSamples(_ touches: [UITouch]) {
        if rulerLine?.handoff != nil { addRulerSamples(touches); return }
        guard var watch = rulerWatching else { return }
        for (index, touch) in touches.enumerated() {
            let sample = rulerSample(touch)
            if let last = watch.samples.last { watch.length += hypot(sample.location.x - last.location.x, sample.location.y - last.location.y) }
            watch.samples.append(sample)
            // Only a running PencilKit ink stroke is handed over (not a held shape).
            if watch.guide.captures(sample.location), inkActive, rulerLine == nil, heldShape == nil, tool.isInk {
                rulerWatching = nil
                handOver(watch, rest: Array(touches[index...]))
                return
            }
        }
        rulerWatching = watch
    }
    /// PencilKit's stroke reached the capture zone: its recognizer is
    /// cancelled (the part drawn so far stays a PencilKit stroke with its
    /// pressure), the ruler way goes on from here. Should PencilKit drop that
    /// part instead, the ruler stroke draws it, too: nothing lost, nothing twice.
    private func handOver(_ watch: RulerWatch, rest: [UITouch]) {
        let base = canvas.drawing.strokes.count
        let drawing = canvas.drawingGestureRecognizer
        drawing.isEnabled = false; drawing.isEnabled = true
        let handoff = RulerLine.Handoff(baseCount: base, at: CACurrentMediaTime(), kept: nil, prefix: Array(watch.samples.dropLast()))
        startRulerLine(RulerStroke(guide: watch.guide, handedOver: true, priorLength: watch.length), handoff: handoff,
                       finger: rest.first?.type == .direct)
        noteRulerHandoff()
        DispatchQueue.main.async { [weak self] in self?.noteRulerHandoff() }
        addRulerSamples(rest)
    }
    /// PencilKit's part of a handed-over stroke arrived on the canvas.
    func noteRulerHandoff() {
        guard let handoff = rulerLine?.handoff, handoff.kept != true, canvas.drawing.strokes.count > handoff.baseCount else { return }
        rulerLine?.handoff?.kept = true
        updateRulerPreview()
    }
    private func watchEnded(_ end: RulerWatchGesture.End) {
        rulerWatching = nil
        if rulerLine?.handoff != nil { finishRulerLine(commit: end != .navigation) } else { updateRulerGestures() }
    }

    // MARK: Preview and result

    /// The parts of the way on the page, `margin` inside its edge (PencilKit's
    /// curve through the points reaches a little further), and every sample
    /// they refer to.
    private func rulerPieces(_ line: RulerLine, margin: CGFloat) -> (pieces: [[RulerStroke.Point]], samples: [RulerLine.Sample]) {
        let prefix = line.drawsPrefix ? line.handoff?.prefix ?? [] : []
        var path = prefix.enumerated().map { RulerStroke.Point(location: line.stroke.guide.kept($1.location), sample: $0) }
        path += line.stroke.path.map { RulerStroke.Point(location: $0.location, sample: $0.sample + prefix.count) }
        let limits = pageLayout.canonicalInkBounds.insetBy(dx: line.size / 2 + margin, dy: line.size / 2 + margin)
        guard limits.width > 0, limits.height > 0 else { return ([], prefix + line.samples) }
        return (RulerStroke.pieces(path, inside: PageRect(limits)), prefix + line.samples)
    }
    /// Preview = result: the same clipped way (`RulerStroke.pieces`), drawn at the ink's visible width.
    private func updateRulerPreview() {
        guard let line = rulerLine else { return }
        let display = pageLayout.inkTranslation
        let path = UIBezierPath()
        for piece in rulerPieces(line, margin: 1.5).pieces {
            guard let first = piece.first else { continue }
            path.move(to: CGPoint(x: first.location.x, y: first.location.y).applying(display))
            if piece.count == 1 { path.addLine(to: CGPoint(x: first.location.x, y: first.location.y).applying(display)) }
            for point in piece.dropFirst() { path.addLine(to: CGPoint(x: point.location.x, y: point.location.y).applying(display)) }
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        rulerPreview.path = path.cgPath
        CATransaction.commit()
    }
    func hideRulerPreview() {
        rulerPreviewPending = nil
        guard !rulerPreview.isHidden || rulerPreview.path != nil else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        rulerPreview.isHidden = true; rulerPreview.path = nil
        CATransaction.commit()
    }
    /// The result is on the canvas; PencilKit draws it asynchronously: the
    /// preview stays until it reports the rendering (`canvasViewDidFinishRendering`),
    /// at most a short fallback time, so the stroke never flickers.
    private func hideRulerPreviewAfterRendering() {
        let token = UUID(); rulerPreviewPending = token
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self, self.rulerPreviewPending == token else { return }
            self.hideRulerPreview()
        }
    }
    /// A lifted handed-over stroke still waiting for PencilKit: settled now,
    /// before the next stroke begins.
    private func settlePendingRulerLine() {
        if rulerLine?.finishing == true { finishRulerLine(commit: true, settle: true) }
    }
    func cancelRulerLine() {
        rulerWatching = nil
        if rulerLine != nil { finishRulerLine(commit: false) }
    }
    private func finishRulerLine(commit: Bool, settle: Bool = false) {
        guard var line = rulerLine else { updateRulerGestures(); return }
        if commit, let handoff = line.handoff, handoff.kept == nil {
            if canvas.drawing.strokes.count > handoff.baseCount {
                line.handoff?.kept = true
            } else {
                let wait = 0.3 - (CACurrentMediaTime() - handoff.at)
                if wait > 0, !settle, !line.finishing {
                    line.finishing = true; rulerLine = line
                    let id = line.id
                    DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
                        guard let self, self.rulerLine?.id == id else { return }
                        self.finishRulerLine(commit: true, settle: true)
                    }
                    return
                }
                if wait > 0, !settle { return } // already waiting
                line.handoff?.kept = false
            }
        }
        rulerLine = nil; inkActive = false
        updateRulerGestures()
        guard commit else { hideRulerPreview(); return }
        let (strokes, lost) = rulerInkStrokes(line)
        let drawn = (line.drawsPrefix ? line.handoff?.prefix.count ?? 0 : 0) + line.samples.count
        if lost, drawn > 1 {
            configuration?.onError(strokes.isEmpty ? "Der Strich am Lineal lag außerhalb der Seite und wurde nicht übernommen."
                                                   : "Ein Teil des Strichs am Lineal lag außerhalb der Seite.")
        }
        guard !strokes.isEmpty else { hideRulerPreview(); return }
        appendInkStrokes(strokes)
        hideRulerPreviewAfterRendering()
        // The first stroke on a neighbouring page selects it.
        if configuration?.focused == false { configuration?.onSelectPage() }
    }
    /// The PencilKit strokes of the way (one per part on the page), with the
    /// tool's learned point size and look, the real times and tilt. `lost`: a
    /// part had to be left out (it would not fit on the page).
    private func rulerInkStrokes(_ line: RulerLine) -> (strokes: [PKStroke], lost: Bool) {
        let bounds = pageLayout.canonicalInkBounds.insetBy(dx: -0.02, dy: -0.02)
        var best: [PKStroke] = [], expected = 0
        for margin: CGFloat in [1.5, 4, 8] {
            let (pieces, samples) = rulerPieces(line, margin: margin)
            guard !pieces.isEmpty, !samples.isEmpty else { return ([], true) }
            let strokes = pieces.map { rulerInkStroke($0, samples: samples, line: line) }
            let fitting = strokes.filter { bounds.contains($0.renderBounds) }
            if fitting.count == strokes.count { return (strokes, false) }
            if fitting.count >= best.count { best = fitting; expected = strokes.count }
        }
        return (best, best.count < expected)
    }
    private func rulerInkStroke(_ piece: [RulerStroke.Point], samples: [RulerLine.Sample], line: RulerLine) -> PKStroke {
        let start = samples[0].time, size = CGSize(width: line.size, height: line.size)
        var points: [PKStrokePoint] = [], last: CGPoint?, time = -0.001
        for (index, point) in piece.enumerated() {
            let sample = samples[min(max(0, point.sample), samples.count - 1)]
            let location = CGPoint(x: point.location.x, y: point.location.y)
            if let last, index < piece.count - 1, hypot(location.x - last.x, location.y - last.y) < 0.3 { continue }
            time = max(sample.time - start, time + 0.001)
            points.append(PKStrokePoint(location: location, timeOffset: time, size: size, opacity: line.template?.opacity ?? 1,
                                        force: line.template?.force ?? 1, azimuth: sample.azimuth, altitude: sample.altitude))
            last = location
        }
        // A dot needs a way, too.
        if points.count == 1, let dot = points.first {
            points.append(PKStrokePoint(location: CGPoint(x: dot.location.x + 0.2, y: dot.location.y), timeOffset: time + 0.001, size: size,
                                        opacity: dot.opacity, force: dot.force, azimuth: dot.azimuth, altitude: dot.altitude))
        }
        return PKStroke(ink: line.ink, path: PKStrokePath(controlPoints: points, creationDate: Date()))
    }
}
