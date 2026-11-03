import SwiftUI
import PencilKit
import NotebookCore

/// A stroke while the ruler is out, in sheet coordinates. `start` and
/// `outward` are the edge on the stroke's side, half a stroke further out:
/// the ink lies along the ruler, not under it.
struct RulerLine {
    struct Sample {
        var location: CGPoint
        var time: TimeInterval
        var azimuth: CGFloat
        var altitude: CGFloat
    }
    var start: CGPoint
    var outward: CGPoint
    var samples: [Sample] = []
    let path = UIBezierPath()
}

extension WorksheetView {
    func configureRulerStroke() {
        rulerStroke.addTarget(self, action: #selector(rulerStroked(_:)))
        rulerStroke.isEnabled = false
        rulerStroke.takes = { [weak self] touch in
            guard let self, let overlay = self.rulerView, let ruler = overlay.ruler else { return false }
            guard touch.type != .pencil else { return true }
            // A drawing finger on the ruler moves it.
            let point = touch.location(in: overlay)
            return !ruler.contains(PagePoint(x: point.x, y: point.y))
        }
        addGestureRecognizer(rulerStroke)
        canvas.drawingGestureRecognizer.require(toFail: rulerStroke)
    }
    @objc func rulerStroked(_ gesture: RulerStrokeGesture) {
        switch gesture.state {
        case .began: beginRulerLine(gesture)
        case .changed: addRulerSamples(gesture)
        case .ended: addRulerSamples(gesture); finishRulerLine(commit: true)
        default: finishRulerLine(commit: false)
        }
    }
    private func beginRulerLine(_ gesture: RulerStrokeGesture) {
        guard let overlay = rulerView, let ruler = overlay.ruler, let touch = gesture.samples.first else { return }
        let point = touch.location(in: overlay)
        let edge = ruler.edgeLine(side: ruler.side(of: PagePoint(x: point.x, y: point.y)))
        func sheet(_ point: PagePoint) -> CGPoint { overlay.convert(CGPoint(x: point.x, y: point.y), to: self) }
        let a = sheet(edge.start), beside = sheet(PagePoint(x: edge.start.x + edge.outward.x, y: edge.start.y + edge.outward.y))
        let length = max(0.0001, hypot(beside.x - a.x, beside.y - a.y))
        let outward = CGPoint(x: (beside.x - a.x) / length, y: (beside.y - a.y) / length)
        heldColor = InkColor(Color(lastColor ?? .black))
        heldWidth = min(40, max(0.5, heldPointSize / InkWidthCalibration.pointScale(inkType)))
        rulerLine = RulerLine(start: CGPoint(x: a.x + outward.x * heldPointSize / 2, y: a.y + outward.y * heldPointSize / 2), outward: outward)
        inkActive = true; holdBase = nil
        objectLayer.endTouchSelection()
        claimSelectionFocus()
        onInkSession?()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        heldShapeLayer.frame = bounds; heldShapeLayer.lineDashPattern = nil
        heldShapeLayer.lineWidth = heldWidth
        heldShapeLayer.strokeColor = (lastColor ?? .black).withAlphaComponent(tool == .marker ? 0.4 : 1).cgColor
        heldShapeLayer.isHidden = false
        CATransaction.commit()
        addRulerSamples(gesture)
    }
    private func addRulerSamples(_ gesture: RulerStrokeGesture) {
        guard var line = rulerLine else { return }
        for touch in gesture.samples {
            let raw = touch.location(in: self)
            let kept = NotebookRuler.kept(PagePoint(x: raw.x, y: raw.y), start: PagePoint(x: line.start.x, y: line.start.y),
                                          outward: PagePoint(x: line.outward.x, y: line.outward.y))
            let point = CGPoint(x: kept.x, y: kept.y)
            if line.samples.isEmpty { line.path.move(to: point) } else { line.path.addLine(to: point) }
            let pencil = touch.type == .pencil
            line.samples.append(.init(location: point, time: touch.timestamp, azimuth: pencil ? touch.azimuthAngle(in: self) : 0,
                                      altitude: pencil ? touch.altitudeAngle : .pi / 2))
        }
        rulerLine = line
        CATransaction.begin(); CATransaction.setDisableActions(true)
        heldShapeLayer.path = line.path.cgPath
        CATransaction.commit()
    }
    private func finishRulerLine(commit: Bool) {
        let line = rulerLine
        rulerLine = nil; inkActive = false
        defer {
            CATransaction.begin(); CATransaction.setDisableActions(true)
            heldShapeLayer.isHidden = true; heldShapeLayer.path = nil
            CATransaction.commit()
        }
        guard commit, editable, let line, let stroke = rulerInkStroke(line) else { return }
        let previous = pageContent
        var next = previous
        let old = previous.drawing.isEmpty ? PKDrawing() : (try? PKDrawing(data: previous.drawing)) ?? PKDrawing()
        next.drawing = PKDrawing(strokes: old.strokes + [stroke]).dataRepresentation()
        if onContent?(next, previous) == true { installContent(next) }
    }
    /// The PencilKit stroke of the pen's real way, with the tool's point size
    /// and the look of its last drawn stroke. A way off the page runs along
    /// the page edge: ink stays on its page.
    private func rulerInkStroke(_ line: RulerLine) -> PKStroke? {
        guard let first = line.samples.first else { return nil }
        let ink = (canvas.tool as? PKInkingTool)?.ink ?? PKInk(inkType, color: heldColor.uiColor)
        let page = pageLayout.inkTranslation.inverted()
        let size = CGSize(width: heldPointSize, height: heldPointSize), template = drawnPointTemplate[ink.inkType]
        // PencilKit's curve through the points can reach a little further.
        for margin: CGFloat in [1.5, 4, 8] {
            let limits = pageLayout.canonicalInkBounds.insetBy(dx: heldPointSize / 2 + margin, dy: heldPointSize / 2 + margin)
            guard limits.width > 0, limits.height > 0 else { return nil }
            var points: [PKStrokePoint] = [], last: CGPoint?, time = -0.001
            for (index, sample) in line.samples.enumerated() {
                let raw = sample.location.applying(page)
                let location = CGPoint(x: min(max(raw.x, limits.minX), limits.maxX), y: min(max(raw.y, limits.minY), limits.maxY))
                if let last, index < line.samples.count - 1, hypot(location.x - last.x, location.y - last.y) < 0.3 { continue }
                time = max(sample.time - first.time, time + 0.001)
                points.append(PKStrokePoint(location: location, timeOffset: time, size: size, opacity: template?.opacity ?? 1,
                                            force: template?.force ?? 1, azimuth: sample.azimuth, altitude: sample.altitude))
                last = location
            }
            // A dot needs a way, too.
            if points.count == 1, let dot = points.first {
                points.append(PKStrokePoint(location: CGPoint(x: dot.location.x + 0.2, y: dot.location.y), timeOffset: time + 0.001, size: size,
                                            opacity: dot.opacity, force: dot.force, azimuth: dot.azimuth, altitude: dot.altitude))
            }
            let stroke = PKStroke(ink: ink, path: PKStrokePath(controlPoints: points, creationDate: Date()))
            if pageLayout.canonicalInkBounds.insetBy(dx: -0.02, dy: -0.02).contains(stroke.renderBounds) { return stroke }
        }
        return nil
    }
}
