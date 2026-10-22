import UIKit
import UIKit.UIGestureRecognizerSubclass
import NotebookCore

// MARK: Weiches Einrasten (Textneubau Stufe 2) – UI side
//
// The geometry (targets, reach, speed, hysteresis) is `SoftSnapper` in
// NotebookCore. Here: the setting, the second-finger check, the drag helper
// every object layer uses, the blue guides above the page (never in previews
// or the PDF) and the sheet that collects the targets.

enum SnapSettings {
    /// „Einrasten“ in Einstellungen › Editor (app-wide, on by default).
    static var enabled: Bool { UserDefaults.standard.object(forKey: AppSettingsKey.snapping) as? Bool ?? true }
}

/// A pan that notices another touch anywhere on the screen (a second finger
/// while dragging, also beside the Pencil): snapping pauses meanwhile. Only
/// reads the event; recognition is unchanged.
class SnapPanGestureRecognizer: UIPanGestureRecognizer {
    private(set) var otherTouchDown = false
    private func track(_ event: UIEvent) {
        otherTouchDown = (event.allTouches ?? []).filter { $0.phase != .ended && $0.phase != .cancelled }.count > 1
    }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) { super.touchesBegan(touches, with: event); track(event) }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) { super.touchesMoved(touches, with: event); track(event) }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) { super.touchesEnded(touches, with: event); track(event) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { super.touchesCancelled(touches, with: event); track(event) }
    override func reset() { super.reset(); otherTouchDown = false }
}

/// The sheet: targets of the page and where guides are shown.
@MainActor
protocol SnapHost: AnyObject {
    /// Everything on the page except `excluded` (nil: snapping is off).
    func snapScene(excluding excluded: Set<UUID>) -> SnapScene?
    /// Page y of the first baseline of an unrotated field.
    func snapBaseline(of box: TextBox) -> Double?
    func showSnapFeedback(_ feedback: SnapFeedback?)
}

/// One object layer's snapping for the current drag.
@MainActor
final class DragSnapping {
    weak var host: SnapHost?
    private var session: MoveSnapSession?
    private var speed = DragSpeed()
    private var impact: UIImpactFeedbackGenerator?
    private var pencilFeedback: UIFeedbackGenerator?

    /// Starts a drag. `snapFrame`: what aligns instead of the clamped frame;
    /// `baselineOffset`: first baseline below the frame's top (one unrotated field).
    func begin(excluding excluded: Set<UUID>, snapFrame: PageRect? = nil, baselineOffset: Double? = nil, in view: UIView) {
        end()
        speed = DragSpeed()
        guard let scene = host?.snapScene(excluding: excluded) else { return }
        let session = MoveSnapSession(scene: scene)
        session.snapFrame = snapFrame; session.baselineOffset = baselineOffset
        self.session = session
        if impact == nil { impact = UIImpactFeedbackGenerator(style: .light) }
        impact?.prepare()
        if #available(iOS 17.5, *), pencilFeedback == nil { pencilFeedback = UICanvasFeedbackGenerator(view: view) }
    }
    var isActive: Bool { session != nil }

    /// Per touch event, before the move path: zoom, speed, second finger.
    func track(_ gesture: UIGestureRecognizer, in view: UIView) -> MoveSnapSession? {
        guard let session else { return nil }
        let screen = gesture.location(in: nil)
        session.speed = speed.add(PagePoint(x: screen.x, y: screen.y), at: CACurrentMediaTime())
        session.scale = Double(Self.screenScale(of: view))
        session.suppressed = (gesture as? SnapPanGestureRecognizer)?.otherTouchDown ?? false
        return session
    }
    /// After the move path: guides for the translation finally used.
    func show(translation: PagePoint, frame: PageRect, gesture: UIGestureRecognizer, in view: UIView) {
        guard let session else { return }
        let feedback = session.feedback(for: translation, moving: frame)
        if session.newlyEngaged, !feedback.isEmpty { tick(at: gesture.location(in: view)) }
        host?.showSnapFeedback(feedback)
    }
    /// A single point (width point, shape anchor) along `axes`.
    func point(_ point: PagePoint, axes: Set<SnapAxis> = [.x, .y], gesture: UIGestureRecognizer, in view: UIView) -> PagePoint {
        guard let session = track(gesture, in: view) else { return point }
        let snapped = session.adjusted(point: point, axes: axes)
        let feedback = session.feedback(point: snapped, axes: axes)
        if session.newlyEngaged, !feedback.isEmpty { tick(at: gesture.location(in: view)) }
        host?.showSnapFeedback(feedback)
        return snapped
    }
    /// Lifted off the page: no guides, snapping resumes on return.
    func hide() { host?.showSnapFeedback(nil) }
    func end() {
        if session != nil { hide() }
        session = nil
    }
    private func tick(at point: CGPoint) {
        impact?.impactOccurred(intensity: 0.6); impact?.prepare()
        if #available(iOS 17.5, *), let feedback = pencilFeedback as? UICanvasFeedbackGenerator {
            feedback.alignmentOccurred(at: point); feedback.prepare()
        }
    }
    static func screenScale(of view: UIView) -> CGFloat {
        guard view.window != nil else { return 1 }
        let a = view.convert(CGPoint.zero, to: nil), b = view.convert(CGPoint(x: 100, y: 0), to: nil)
        return max(0.001, hypot(b.x - a.x, b.y - a.y) / 100)
    }
}

/// Thin blue guides above the page content; equal gaps get small marks.
final class SnapGuideView: UIView {
    private let lines = CAShapeLayer()
    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false; backgroundColor = .clear; isOpaque = false; isHidden = true
        lines.fillColor = nil; lines.strokeColor = UIColor.systemBlue.withAlphaComponent(0.85).cgColor
        lines.lineCap = .round
        layer.addSublayer(lines)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// `origin`: canonical → sheet coordinates; `scale`: screen points per page point.
    func show(_ feedback: SnapFeedback?, origin: PagePoint, scale: CGFloat) {
        CATransaction.begin(); CATransaction.setDisableActions(true); defer { CATransaction.commit() }
        guard let feedback, !feedback.isEmpty else { isHidden = true; lines.path = nil; return }
        let path = CGMutablePath(), reach = 6 / scale, tick = 4 / scale
        func point(_ axis: SnapAxis, along: Double, across: Double) -> CGPoint {
            // `.x`: vertical guide (x = across, y = along); `.y`: horizontal.
            axis == .x ? CGPoint(x: across + origin.x, y: along + origin.y) : CGPoint(x: along + origin.x, y: across + origin.y)
        }
        for guide in feedback.guides {
            path.move(to: point(guide.axis, along: guide.span.lowerBound - reach, across: guide.value))
            path.addLine(to: point(guide.axis, along: guide.span.upperBound + reach, across: guide.value))
        }
        for mark in feedback.marks where mark.to > mark.from {
            // A gap along x is a horizontal segment: positions along x, drawn at y = cross.
            let across: SnapAxis = mark.axis == .x ? .y : .x
            path.move(to: point(across, along: mark.from, across: mark.cross))
            path.addLine(to: point(across, along: mark.to, across: mark.cross))
            for end in [mark.from, mark.to] {
                path.move(to: point(mark.axis, along: mark.cross - tick, across: end))
                path.addLine(to: point(mark.axis, along: mark.cross + tick, across: end))
            }
        }
        lines.frame = bounds; lines.lineWidth = 1 / scale; lines.path = path
        isHidden = false
    }
}

extension TextObjectLayout {
    /// First baseline below the top in the layout's own (unscaled) units.
    var firstBaseline: CGFloat? {
        guard manager.numberOfGlyphs > 0 else { return nil }
        let line = manager.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil)
        return line.minY + manager.location(forGlyphAt: 0).y
    }
}

extension WorksheetView: SnapHost {
    func installSnapping() {
        for snapping in [objectLayer.snapping, textLayer.snapping] { snapping.host = self }
        addSubview(snapGuides)
    }
    func snapScene(excluding excluded: Set<UUID>) -> SnapScene? {
        guard SnapSettings.enabled, configuration != nil else { return nil }
        let content = pageContent
        var objects: [SnapObject] = []
        for box in content.textBoxes where !excluded.contains(box.id) && box.flowID == nil && !box.text.isEmpty {
            let fitted = textLayer.fitted(box)
            objects.append(SnapObject(frame: fitted.rotatedBounds, baseline: snapBaseline(of: fitted)))
        }
        objects += content.images.filter { !excluded.contains($0.id) }.map { SnapObject(frame: $0.rotatedBounds) }
        objects += content.shapes.filter { !excluded.contains($0.id) }.map { SnapObject(frame: $0.snapFrame) }
        let layout = pageLayout
        // Paper lines and grid squares are no targets (Feedback zu Build 62).
        return SnapScene(objects: objects, page: PageRect(x: 0, y: 0, width: layout.contentCanvas.width, height: layout.contentCanvas.height),
                         limits: PageRect(layout.canonicalInkBounds))
    }
    func snapBaseline(of box: TextBox) -> Double? {
        guard box.angle == 0, box.flowID == nil, !box.text.isEmpty, let editor = configuration else { return nil }
        var page = Page(); page.paper = editor.paper; page.margins = editor.margins
        let scale = textLayer.coordinateScale(for: box)
        let ruling = page.textRuling(for: box)
        let anchor = ruling == nil ? nil : box.rulingAnchorY(regionTops: editor.writingRegionTops)
        let origin: CGFloat? = anchor.map { CGFloat($0 + pageLayout.contentOrigin.y) / scale }
        guard let first = TextObjectLayout(box, ruledOrigin: origin, ruling: ruling ?? .lined, coordinateScale: scale).firstBaseline else { return nil }
        return box.y + Double(first * scale)
    }
    func showSnapFeedback(_ feedback: SnapFeedback?) {
        if feedback?.isEmpty == false {
            if snapGuides.frame != bounds { snapGuides.frame = bounds }
            if subviews.last !== snapGuides { bringSubviewToFront(snapGuides) }
        }
        snapGuides.show(feedback, origin: pageLayout.contentOrigin, scale: screenScale)
    }
}
