import UIKit
import UIKit.UIGestureRecognizerSubclass
import PencilKit
import NotebookCore

/// The notebook's own scrolling and zooming (not a canvas's disabled scroll gestures).
@MainActor func isViewportNavigation(_ gesture: UIGestureRecognizer) -> Bool {
    guard let scroll = gesture.view as? UIScrollView, !(scroll is PKCanvasView) else { return false }
    return gesture === scroll.panGestureRecognizer || gesture === scroll.pinchGestureRecognizer
}
/// PencilKit's drawing recognizer of some canvas.
@MainActor func isCanvasDrawing(_ gesture: UIGestureRecognizer) -> Bool {
    var view = gesture.view
    for _ in 0..<3 {
        if let canvas = view as? PKCanvasView { return canvas.drawingGestureRecognizer === gesture }
        view = view?.superview
    }
    return false
}

/// noty's own ruler (`NotebookRuler`) above all pages: in the viewport's
/// coordinates, so the zoom does not change it. One finger moves it, two turn
/// it, after a short way (`RulerHand`). Touches on it are taken by
/// `RulerMoveGesture`, the view itself takes none.
@MainActor
final class RulerOverlayView: UIView {
    /// One stored place for every view, on purpose: a newly opened view (also
    /// the second pane of a split) starts where the ruler was left last; each
    /// open view then keeps its own ruler until it is moved there.
    private static let key = "noty.ruler.position"
    private static let length: CGFloat = 4000
    let move = RulerMoveGesture(target: nil, action: nil)
    private(set) var ruler: NotebookRuler?
    /// A stroke is being drawn on one of the pages: the edge stays where it is.
    var strokeActive: () -> Bool = { false }
    /// The free part of the viewport (not under the toolbar or keyboard).
    var parkingArea: (CGSize) -> PageRect = { PageRect(x: 0, y: 0, width: Double($0.width), height: Double($0.height)) }
    private let band = UIView()
    private let ticks = CAShapeLayer()
    private let label = UILabel()
    private weak var host: UIView?
    private var session: (start: NotebookRuler, points: [CGPoint])?
    /// Size the current place refers to; a new size (turn of the iPad) rescales it.
    private var shownSize = CGSize.zero
    private var snappedAngle: Double?
    private let snapFeedback = UISelectionFeedbackGenerator()
    private lazy var element = RulerAccessibilityElement(accessibilityContainer: self)

    override init(frame: CGRect) {
        super.init(frame: frame)
        element.overlay = self
        isUserInteractionEnabled = false; isHidden = true; backgroundColor = .clear
        isAccessibilityElement = false
        element.accessibilityLabel = "Lineal"
        element.accessibilityHint = "Nach oben oder unten wischen dreht es in Schritten von 15 Grad. Weitere Aktionen verschieben es."
        element.accessibilityTraits = .adjustable
        element.accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: "Nach oben verschieben", target: self, selector: #selector(moveUp(_:))),
            UIAccessibilityCustomAction(name: "Nach unten verschieben", target: self, selector: #selector(moveDown(_:))),
            UIAccessibilityCustomAction(name: "Nach links verschieben", target: self, selector: #selector(moveLeft(_:))),
            UIAccessibilityCustomAction(name: "Nach rechts verschieben", target: self, selector: #selector(moveRight(_:))),
            UIAccessibilityCustomAction(name: "Waagerecht ausrichten", target: self, selector: #selector(level(_:))),
            UIAccessibilityCustomAction(name: "Senkrecht ausrichten", target: self, selector: #selector(upright(_:))),
        ]
        band.bounds = CGRect(x: 0, y: 0, width: Self.length, height: NotebookRuler.width)
        band.backgroundColor = UIColor(white: 0.12, alpha: 0.55)
        band.layer.borderColor = UIColor(white: 1, alpha: 0.9).cgColor; band.layer.borderWidth = 1
        addSubview(band)
        ticks.frame = band.bounds; ticks.fillColor = nil; ticks.lineWidth = 1
        ticks.strokeColor = UIColor(white: 1, alpha: 0.85).cgColor
        ticks.path = Self.tickPath()
        band.layer.addSublayer(ticks)
        label.textColor = .white; label.font = .monospacedDigitSystemFont(ofSize: 15, weight: .semibold); label.textAlignment = .center
        label.frame = CGRect(x: Self.length / 2 - 40, y: NotebookRuler.width / 2 - 12, width: 80, height: 24)
        band.addSubview(label)
        move.isEnabled = false
        move.takes = { [weak self] touch in
            guard let self, let ruler = self.ruler else { return false }
            let point = touch.location(in: self)
            return ruler.contains(PagePoint(x: point.x, y: point.y))
        }
        move.strokeActive = { [weak self] in self?.strokeActive() ?? false }
        move.onChange = { [weak self] points, restart in self?.moved(points, restart: restart) }
        move.onEnd = { [weak self] in self?.session = nil; self?.save() }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private static func tickPath() -> CGPath {
        let path = UIBezierPath(), step: CGFloat = 10
        var x: CGFloat = 0, index = 0
        while x <= length {
            let height: CGFloat = index % 10 == 0 ? 18 : index % 5 == 0 ? 12 : 7
            path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: height))
            path.move(to: CGPoint(x: x, y: NotebookRuler.width)); path.addLine(to: CGPoint(x: x, y: NotebookRuler.width - height))
            x += step; index += 1
        }
        return path.cgPath
    }

    func install(on host: UIView) {
        self.host = host
        host.addSubview(self)
        host.addGestureRecognizer(move)
    }
    func setVisible(_ visible: Bool) {
        guard visible != !isHidden else { return }
        isHidden = !visible; move.isEnabled = visible
        accessibilityElements = visible ? [element] : nil
        if visible { follow() }
    }
    /// The overlay covers what the scroll view shows.
    func follow() {
        guard !isHidden, let host else { return }
        if frame != host.bounds { frame = host.bounds }
        let size = bounds.size
        guard size.width > 0, size.height > 0 else { return }
        // While a stroke is drawn nothing moves (its edge is fixed anyway).
        if strokeActive(), ruler != nil { return }
        var current: NotebookRuler
        if let ruler {
            current = shownSize.width > 0 && shownSize != size
                ? ruler.rescaled(from: PageSize(width: shownSize.width, height: shownSize.height), to: PageSize(width: size.width, height: size.height))
                : ruler
        } else {
            current = Self.stored(in: size) ?? NotebookRuler(x: size.width / 2, y: size.height * 0.45)
        }
        shownSize = size
        if session == nil { current = current.clamped(to: parkingArea(size)) }
        if current != ruler { show(current) }
    }
    private func show(_ next: NotebookRuler) {
        ruler = next
        band.center = CGPoint(x: next.x, y: next.y)
        band.transform = CGAffineTransform(rotationAngle: next.angle * .pi / 180)
        label.text = "\(next.displayDegrees)°"
        element.accessibilityValue = "\(next.displayDegrees) Grad"
        element.accessibilityFrameInContainerSpace = band.frame.intersection(bounds)
    }
    /// `points`: the fingers in window coordinates.
    private func moved(_ windowPoints: [CGPoint], restart: Bool) {
        guard let current = ruler else { return }
        guard !strokeActive() else { session = nil; return }
        let points = windowPoints.map { convert($0, from: nil) }
        guard !points.isEmpty else { return }
        if restart || session == nil {
            session = (current, points)
            snappedAngle = current.isSnapped ? current.angle : nil
            snapFeedback.prepare()
            return
        }
        guard let session else { return }
        func page(_ point: CGPoint) -> PagePoint { PagePoint(x: point.x, y: point.y) }
        var next = session.start
        let turning = points.count == 2 && session.points.count == 2
        if turning {
            next = next.transformed(from: (page(session.points[0]), page(session.points[1])), to: (page(points[0]), page(points[1]))).snapped
        } else {
            next = next.translated(x: points[0].x - session.points[0].x, y: points[0].y - session.points[0].y)
        }
        next = next.clamped(to: parkingArea(bounds.size))
        if turning, next.isSnapped, snappedAngle != next.angle { snapFeedback.selectionChanged(); snapFeedback.prepare() }
        snappedAngle = next.isSnapped ? next.angle : nil
        show(next)
    }
    /// As a share of the screen: the place survives a turn of the iPad.
    private func save() {
        guard let ruler, bounds.width > 0, bounds.height > 0 else { return }
        UserDefaults.standard.set([ruler.x / bounds.width, ruler.y / bounds.height, ruler.angle], forKey: Self.key)
    }
    private static func stored(in size: CGSize) -> NotebookRuler? {
        guard let values = UserDefaults.standard.array(forKey: key) as? [Double], values.count == 3,
              values.allSatisfy(\.isFinite) else { return nil }
        return NotebookRuler(x: values[0] * size.width, y: values[1] * size.height, angle: values[2])
    }

    // MARK: VoiceOver
    /// Turn by `degrees` onto the next multiple of 15°.
    func accessibilityTurn(by degrees: Double) {
        guard let ruler, !strokeActive() else { return }
        show(NotebookRuler(x: ruler.x, y: ruler.y, angle: (ruler.angle / 15).rounded() * 15 + degrees))
        save()
    }
    private func accessibilityMove(_ dx: Double, _ dy: Double) -> Bool {
        guard let ruler, !strokeActive() else { return false }
        show(ruler.translated(x: dx, y: dy).clamped(to: parkingArea(bounds.size)))
        save()
        UIAccessibility.post(notification: .layoutChanged, argument: element)
        return true
    }
    private func accessibilityAngle(_ angle: Double) -> Bool {
        guard let ruler, !strokeActive() else { return false }
        show(NotebookRuler(x: ruler.x, y: ruler.y, angle: angle)); save()
        return true
    }
    @objc private func moveUp(_ action: UIAccessibilityCustomAction) -> Bool { accessibilityMove(0, -40) }
    @objc private func moveDown(_ action: UIAccessibilityCustomAction) -> Bool { accessibilityMove(0, 40) }
    @objc private func moveLeft(_ action: UIAccessibilityCustomAction) -> Bool { accessibilityMove(-40, 0) }
    @objc private func moveRight(_ action: UIAccessibilityCustomAction) -> Bool { accessibilityMove(40, 0) }
    @objc private func level(_ action: UIAccessibilityCustomAction) -> Bool { accessibilityAngle(0) }
    @objc private func upright(_ action: UIAccessibilityCustomAction) -> Bool { accessibilityAngle(90) }
}

/// The ruler for VoiceOver: its angle as value, swiping up/down turns it.
@MainActor
final class RulerAccessibilityElement: UIAccessibilityElement {
    weak var overlay: RulerOverlayView?
    /// Up: the angle a protractor reads grows (counter-clockwise).
    override func accessibilityIncrement() { overlay?.accessibilityTurn(by: -15) }
    override func accessibilityDecrement() { overlay?.accessibilityTurn(by: 15) }
}

/// Moves and turns the ruler. A finger on the band (and a second one
/// anywhere, also when both land together) is only tracked at first: fingers
/// rest on a ruler while the other hand writes, so it moves after a short way
/// (`RulerHand.moveThreshold`) and never for a palm (`majorRadius`) or while a
/// stroke is drawn. The Pencil never waits for it: only scrolling and zooming
/// (and, when the finger draws, the canvas) wait until it fails, which happens
/// at once for a touch beside the ruler.
final class RulerMoveGesture: UIGestureRecognizer {
    var takes: ((UITouch) -> Bool)?
    var strokeActive: (() -> Bool)?
    /// The finger draws (Fingermalmodus): a finger on the ruler moves it instead.
    var fingerDrawing: (() -> Bool)?
    /// The fingers in window coordinates; `restart`: their number changed (or
    /// the move just began), this is the new start.
    var onChange: (([CGPoint], Bool) -> Void)?
    var onEnd: (() -> Void)?
    private var fingers: [UITouch] = []
    private var starts: [CGPoint] = []
    private var moving: Bool { state == .began || state == .changed }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        // Fingers whose end never arrived (`StalledGestures`) no longer hold
        // the ruler, and with it every scroll and zoom of the notebook.
        if !fingers.isEmpty {
            let kept = zip(fingers, starts).filter { event.stillDown($0.0) && !touches.contains($0.0) }
            if kept.count != fingers.count {
                fingers = kept.map { $0.0 }; starts = kept.map { $0.1 }
                if fingers.isEmpty, moving { onEnd?(); state = .cancelled; return }
            }
        }
        for touch in touches where touch.type != .direct { ignore(touch, for: event) }
        let direct = touches.filter { $0.type == .direct }
        guard !direct.isEmpty else { if fingers.isEmpty { state = .failed }; return }
        if fingers.isEmpty {
            let list = Array(direct)
            let candidates = list.map { RulerHand.Touch(onBand: takes?($0) == true, majorRadius: Double($0.majorRadius)) }
            let picked = RulerHand.fingers(candidates, strokeActive: strokeActive?() == true)
            guard !picked.isEmpty else { state = .failed; return }
            fingers = picked.map { list[$0] }
            starts = fingers.map { $0.location(in: nil) }
            for touch in list where !fingers.contains(touch) { ignore(touch, for: event) }
        } else {
            for touch in direct {
                if fingers.count < 2, RulerHand.joins(RulerHand.Touch(onBand: false, majorRadius: Double(touch.majorRadius))) {
                    fingers.append(touch); starts.append(touch.location(in: nil))
                } else { ignore(touch, for: event) }
            }
            if moving { onChange?(fingers.map { $0.location(in: nil) }, true) }
        }
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard !fingers.isEmpty else { return }
        if !moving {
            if strokeActive?() == true { state = .failed; return }
            let moved = zip(fingers, starts).map { touch, start -> Double in
                let point = touch.location(in: nil); return Double(hypot(point.x - start.x, point.y - start.y))
            }
            guard RulerHand.begins(moved: moved) else { return }
            // From where the fingers landed: the first millimetres are not lost.
            onChange?(starts, true)
            onChange?(fingers.map { $0.location(in: nil) }, false)
            state = .began
            return
        }
        onChange?(fingers.map { $0.location(in: nil) }, false)
        state = .changed
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) { lift(touches, final: .ended) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { lift(touches, final: .cancelled) }
    private func lift(_ touches: Set<UITouch>, final: UIGestureRecognizer.State) {
        let kept = zip(fingers, starts).filter { !touches.contains($0.0) }
        fingers = kept.map { $0.0 }; starts = kept.map { $0.1 }
        if fingers.isEmpty {
            if moving { onEnd?(); state = final } else { state = .failed }
        } else if moving {
            onChange?(fingers.map { $0.location(in: nil) }, true)
        } else {
            starts = fingers.map { $0.location(in: nil) }
        }
    }
    override func reset() { fingers = []; starts = []; super.reset() }
    /// A finger on the ruler does not scroll or zoom the notebook (and does
    /// not draw while the finger draws); the Pencil draws, erases and lassos.
    private func waitsForMe(_ other: UIGestureRecognizer) -> Bool {
        isViewportNavigation(other) || (fingerDrawing?() == true && isCanvasDrawing(other))
    }
    override func shouldBeRequiredToFail(by other: UIGestureRecognizer) -> Bool { waitsForMe(other) }
    override func canPrevent(_ other: UIGestureRecognizer) -> Bool { waitsForMe(other) }
}

/// Takes a stroke that starts at the ruler (on the band or in the capture
/// zone, `NotebookRuler.captures`): PencilKit cannot hold a running stroke
/// back at an edge, so the canvas waits for this recognizer, which fails at
/// once for every other start (they stay PencilKit strokes with pressure; see
/// `RulerWatchGesture` for those that reach the ruler later). Waits for a
/// checkbox tap like the canvas does. Every sample since the touch landed is
/// kept until read, also while that wait delays the recognition.
final class RulerStrokeGesture: UIGestureRecognizer {
    var allowFinger = false
    var takes: ((UITouch) -> Bool)?
    /// A second finger landed while a finger drew: navigation, not a stroke.
    private(set) var navigation = false
    private var buffer: [UITouch] = []
    private weak var tracked: UITouch?
    var tracking: Bool { tracked != nil }
    /// The samples since the last call (coalesced, in order).
    func takeSamples() -> [UITouch] { defer { buffer = [] }; return buffer }
    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        delaysTouchesBegan = false; delaysTouchesEnded = false
    }
    private func read(_ touch: UITouch, _ event: UIEvent) { buffer.append(contentsOf: event.coalescedTouches(for: touch) ?? [touch]) }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        if let tracked {
            for touch in touches {
                if tracked.type == .direct, touch.type == .direct {
                    navigation = true
                    state = state == .possible ? .failed : .cancelled
                    return
                }
                ignore(touch, for: event)
            }
            return
        }
        guard state == .possible else { for touch in touches { ignore(touch, for: event) }; return }
        // A resting hand must not end this for the Pencil that lands after it.
        for touch in touches where touch.type == .direct && !allowFinger { ignore(touch, for: event) }
        guard let touch = touches.first(where: { $0.type == .pencil || (allowFinger && $0.type == .direct) }) else { return }
        for other in touches where other !== touch { ignore(other, for: event) }
        guard takes?(touch) == true else { state = .failed; return }
        tracked = touch; navigation = false
        buffer = [touch]
        state = .began
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let tracked, touches.contains(tracked) else { return }
        read(tracked, event)
        if state == .began || state == .changed { state = .changed }
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let tracked, touches.contains(tracked) else { return }
        read(tracked, event)
        state = .ended
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let tracked, touches.contains(tracked) else { return }
        // A cancelled finger is the start of navigation; a Pencil stroke stays.
        if tracked.type == .direct { navigation = true }
        state = state == .possible ? .failed : .cancelled
    }
    override func reset() { tracked = nil; buffer = []; super.reset() }
    /// Two fingers still scroll and zoom while the finger draws at the ruler
    /// (the stroke then ends as navigation).
    override func canPrevent(_ other: UIGestureRecognizer) -> Bool { !isViewportNavigation(other) && super.canPrevent(other) }
}

/// Watches the Pencil (or the drawing finger) of an ordinary PencilKit
/// stroke while the ruler is out, without ever taking it: when it reaches the
/// ruler's capture zone the sheet takes the stroke over (`WorksheetView`
/// hands it from PencilKit to the ruler way), so no stroke runs through the
/// ruler. Never prevents or delays anything.
final class RulerWatchGesture: UIGestureRecognizer, UIGestureRecognizerDelegate {
    enum End { case lifted, cancelled, navigation }
    var allowFinger = false
    var onBegin: ((UITouch) -> Void)?
    /// Coalesced samples of the watched touch.
    var onSamples: (([UITouch]) -> Void)?
    var onEnd: ((End) -> Void)?
    private weak var tracked: UITouch?
    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        delegate = self; cancelsTouchesInView = false
        delaysTouchesBegan = false; delaysTouchesEnded = false
    }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        if let tracked {
            for touch in touches where touch !== tracked {
                if tracked.type == .direct, touch.type == .direct { state = .cancelled; onEnd?(.navigation); return }
                ignore(touch, for: event)
            }
            return
        }
        guard let touch = touches.first(where: { $0.type == .pencil || (allowFinger && $0.type == .direct) }) else {
            for touch in touches { ignore(touch, for: event) }
            return
        }
        for other in touches where other !== touch { ignore(other, for: event) }
        tracked = touch
        state = .began
        onBegin?(touch); onSamples?([touch])
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let tracked, touches.contains(tracked) else { return }
        onSamples?(event.coalescedTouches(for: tracked) ?? [tracked])
        state = .changed
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let tracked, touches.contains(tracked) else { return }
        onSamples?(event.coalescedTouches(for: tracked) ?? [tracked])
        state = .ended; onEnd?(.lifted)
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let tracked, touches.contains(tracked) else { return }
        state = .cancelled; onEnd?(tracked.type == .direct ? .navigation : .cancelled)
    }
    override func reset() { tracked = nil; super.reset() }
    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }
}
