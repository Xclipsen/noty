import UIKit
import UIKit.UIGestureRecognizerSubclass
import NotebookCore

/// noty's own ruler (`NotebookRuler`) above all pages: in the viewport's
/// coordinates, so the zoom does not change it. One finger moves it, two turn
/// it. Touches on it are taken by `RulerMoveGesture`, the view itself takes none.
@MainActor
final class RulerOverlayView: UIView {
    private static let key = "noty.ruler.position"
    private static let length: CGFloat = 4000
    let move = RulerMoveGesture(target: nil, action: nil)
    private(set) var ruler: NotebookRuler?
    private let band = UIView()
    private let ticks = CAShapeLayer()
    private let label = UILabel()
    private weak var host: UIView?
    private var session: (start: NotebookRuler, points: [CGPoint])?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false; isHidden = true; backgroundColor = .clear
        isAccessibilityElement = false
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
        move.onChange = { [weak self] touches, restart in self?.moved(touches, restart: restart) }
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
        if visible { follow() }
    }
    /// The overlay covers what the scroll view shows.
    func follow() {
        guard !isHidden, let host else { return }
        if frame != host.bounds { frame = host.bounds }
        let size = bounds.size
        guard size.width > 0, size.height > 0 else { return }
        var current = ruler ?? Self.stored(in: size) ?? NotebookRuler(x: size.width / 2, y: size.height * 0.45)
        current = current.clamped(width: size.width, height: size.height)
        if current != ruler { show(current) }
    }
    private func show(_ next: NotebookRuler) {
        ruler = next
        band.center = CGPoint(x: next.x, y: next.y)
        band.transform = CGAffineTransform(rotationAngle: next.angle * .pi / 180)
        label.text = "\(Int(abs(next.angle).rounded()))°"
    }
    private func moved(_ touches: [UITouch], restart: Bool) {
        guard let current = ruler else { return }
        let points = touches.map { $0.location(in: self) }
        guard !points.isEmpty else { return }
        if restart || session == nil { session = (current, points); return }
        guard let session else { return }
        func page(_ point: CGPoint) -> PagePoint { PagePoint(x: point.x, y: point.y) }
        var next = session.start
        if points.count == 2, session.points.count == 2 {
            next = next.transformed(from: (page(session.points[0]), page(session.points[1])), to: (page(points[0]), page(points[1]))).snapped
        } else {
            next = next.translated(x: points[0].x - session.points[0].x, y: points[0].y - session.points[0].y)
        }
        show(next.clamped(width: bounds.width, height: bounds.height))
    }
    /// As a share of the screen: the place survives a turn of the iPad.
    private func save() {
        guard let ruler, bounds.width > 0, bounds.height > 0 else { return }
        UserDefaults.standard.set([ruler.x / bounds.width, ruler.y / bounds.height, ruler.angle], forKey: Self.key)
    }
    private static func stored(in size: CGSize) -> NotebookRuler? {
        guard let values = UserDefaults.standard.array(forKey: key) as? [Double], values.count == 3 else { return nil }
        return NotebookRuler(x: values[0] * size.width, y: values[1] * size.height, angle: values[2])
    }
}

/// Takes a finger that lands on the ruler at once, before the page can scroll,
/// zoom or draw; a second finger may land anywhere. Everything else fails in
/// the same moment, so that nothing waits for it.
final class RulerMoveGesture: UIGestureRecognizer {
    var takes: ((UITouch) -> Bool)?
    /// The fingers; `restart`: their number changed, this is the new start.
    var onChange: (([UITouch], Bool) -> Void)?
    var onEnd: (() -> Void)?
    private var fingers: [UITouch] = []

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        if fingers.isEmpty {
            guard let touch = touches.first(where: { $0.type == .direct && takes?($0) == true }) else {
                state = .failed; return
            }
            fingers = [touch]
            for other in touches where other !== touch { ignore(other, for: event) }
            state = .began
        } else {
            for touch in touches {
                if touch.type == .direct, fingers.count < 2 { fingers.append(touch) } else { ignore(touch, for: event) }
            }
        }
        onChange?(fingers, true)
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard !fingers.isEmpty else { return }
        onChange?(fingers, false)
        state = .changed
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) { lift(touches, final: .ended) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { lift(touches, final: .cancelled) }
    private func lift(_ touches: Set<UITouch>, final: UIGestureRecognizer.State) {
        fingers.removeAll { touches.contains($0) }
        if fingers.isEmpty {
            onEnd?()
            if state == .possible { state = .failed } else { state = final }
        } else { onChange?(fingers, true) }
    }
    override func reset() { fingers = []; super.reset() }
}

/// While the ruler is out, a stroke goes through here and not through
/// PencilKit: PencilKit cannot hold a running stroke back at an edge. The
/// canvas waits for this recognizer; it is off while the ruler is away.
final class RulerStrokeGesture: UIGestureRecognizer {
    var allowFinger = false
    var takes: ((UITouch) -> Bool)?
    /// What the last event brought of the stroke, with its coalesced samples.
    private(set) var samples: [UITouch] = []
    private func read(_ touches: Set<UITouch>, _ event: UIEvent) {
        samples = touches.first.map { event.coalescedTouches(for: $0) ?? [$0] } ?? []
    }
    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        delaysTouchesBegan = false; delaysTouchesEnded = false
    }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard state == .possible else { for touch in touches { ignore(touch, for: event) }; return }
        // A resting hand must not end this for the Pencil that lands after it.
        for touch in touches where touch.type == .direct && !allowFinger { ignore(touch, for: event) }
        guard let touch = touches.first(where: { $0.type == .pencil || (allowFinger && $0.type == .direct) }) else { return }
        for other in touches where other !== touch { ignore(other, for: event) }
        guard takes?(touch) == true else { state = .failed; return }
        samples = [touch]
        state = .began
    }
    private var drawing: Bool { state == .began || state == .changed }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard drawing else { return }
        read(touches, event); state = .changed
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        guard drawing else { return }
        read(touches, event); state = .ended
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { if drawing { state = .cancelled } }
}
