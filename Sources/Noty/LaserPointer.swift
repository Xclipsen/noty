import UIKit
import UIKit.UIGestureRecognizerSubclass
import NotebookCore

/// Viewport-level laser pointer above all pages: glowing dot ("Punkt") or a
/// fading glowing trail ("Spur"), continuous across page seams, writing space
/// and PDFs. Display only: nothing reaches notebook data, undo, previews or
/// export. Samples stay in the zooming surface's coordinates (the trail sticks
/// to the content while scrolling); widths stay constant on screen. Pencil
/// hover shows a dimmer dot without trail.
@MainActor
final class LaserPointerView: UIView {
    static let colors: [(name: String, color: InkColor)] = [
        ("Rot", ToolbarPreferences.defaultLaserColor), ("Grün", InkColor(0.15, 0.95, 0.35)), ("Blau", InkColor(0.2, 0.6, 1)),
        ("Gelb", InkColor(1, 0.84, 0.1)), ("Magenta", InkColor(1, 0.25, 0.85))]
    private static let levels = 6
    private var trail = LaserTrail()
    private var style: LaserPointerStyle?
    private weak var surface: UIView?
    private weak var host: UIView?
    /// Per opacity level: wide glow, halo, bright core.
    private let strokes = (0..<LaserPointerView.levels).map { _ in [CAShapeLayer(), CAShapeLayer(), CAShapeLayer()] }
    private let dot = [CAShapeLayer(), CAShapeLayer(), CAShapeLayer()]
    private var hover: CGPoint?
    private var link: CADisplayLink?
    private var feedback: UIFeedbackGenerator?
    private let touches = LaserTouchObserver(target: nil, action: nil)
    private let hoverGesture = UIHoverGestureRecognizer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false; isHidden = true; backgroundColor = .clear
        for layer in strokes.flatMap({ $0 }) + dot {
            layer.fillColor = UIColor.clear.cgColor; layer.lineCap = .round; layer.lineJoin = .round
            self.layer.addSublayer(layer)
        }
        touches.onBegin = { [weak self] touch in self?.begin(touch) }
        touches.onMove = { [weak self] samples in self?.move(samples) }
        touches.onEnd = { [weak self] in self?.end() }
        hoverGesture.addTarget(self, action: #selector(hovered(_:)))
        touches.isEnabled = false; hoverGesture.isEnabled = false
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Observers never cancel, delay or prevent other touches (scrolling, pages).
    func install(on host: UIView, surface: UIView) {
        self.host = host; self.surface = surface
        host.addSubview(self)
        host.addGestureRecognizer(touches); host.addGestureRecognizer(hoverGesture)
        touches.delegate = touches; hoverGesture.delegate = touches
    }

    /// nil: tool inactive; everything visible disappears at once.
    func configure(_ next: LaserPointerStyle?, fingerDrawing: Bool) {
        touches.allowFinger = fingerDrawing
        guard next != style else { return }
        let activated = style == nil && next != nil
        style = next
        touches.isEnabled = next != nil; hoverGesture.isEnabled = next != nil
        guard let next else { reset(); return }
        trail.mode = next.mode; trail.fade = next.fade
        if activated, #available(iOS 17.5, *), let host {
            if feedback == nil { feedback = UICanvasFeedbackGenerator(view: host) }
            feedback?.prepare()
        }
        refresh()
    }
    func reset() {
        trail.clear(); hover = nil
        link?.invalidate(); link = nil
        isHidden = true
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for layer in strokes.flatMap({ $0 }) + dot { layer.path = nil }
        CATransaction.commit()
    }

    private func surfacePoint(_ touch: UITouch) -> PagePoint? {
        guard let surface else { return nil }
        let point = touch.location(in: surface); return PagePoint(x: point.x, y: point.y)
    }
    private func begin(_ touch: UITouch) {
        guard style != nil, let point = surfacePoint(touch) else { return }
        hover = nil
        // Configured before installation (no host yet): create on first use.
        if #available(iOS 17.5, *), feedback == nil, let host { feedback = UICanvasFeedbackGenerator(view: host); feedback?.prepare() }
        // A light tick on Apple Pencil Pro when pointing starts from nothing
        // visible (not for every stroke); nothing on older Pencils or fingers.
        if trail.begin(at: point, time: CACurrentMediaTime()), #available(iOS 17.5, *), let host,
           let feedback = feedback as? UICanvasFeedbackGenerator {
            feedback.alignmentOccurred(at: touch.location(in: host))
        }
        startLink(); refresh()
    }
    private func move(_ samples: [UITouch]) {
        let now = CACurrentMediaTime()
        for touch in samples { if let point = surfacePoint(touch) { trail.move(to: point, time: now) } }
    }
    private func end() { trail.end(time: CACurrentMediaTime()); refresh() }
    @objc private func hovered(_ recognizer: UIHoverGestureRecognizer) {
        guard style != nil, !trail.touching, let surface else { return }
        switch recognizer.state {
        case .began, .changed: hover = recognizer.location(in: surface); feedback?.prepare()
        default: hover = nil
        }
        refresh()
    }

    private func startLink() {
        guard link == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(tick)); link.add(to: .main, forMode: .common)
        self.link = link
    }
    @objc private func tick() {
        refresh()
        if trail.isEmpty(at: CACurrentMediaTime()) { link?.invalidate(); link = nil }
    }

    /// Re-renders for the current time, scroll position and zoom.
    func refresh() {
        guard let style, let surface, let host else { return }
        let now = CACurrentMediaTime()
        trail.prune(at: now)
        let pointer = trail.pointer.map { CGPoint(x: $0.x, y: $0.y) }
        let visible = !trail.samples.isEmpty || pointer != nil || hover != nil
        isHidden = !visible
        guard visible else { return }
        if frame != host.bounds { frame = host.bounds }
        // Surface → overlay is a scale plus offset (the zoom of the notebook).
        let origin = surface.convert(CGPoint.zero, to: self), unit = surface.convert(CGPoint(x: 1, y: 1), to: self)
        let scale = CGPoint(x: unit.x - origin.x, y: unit.y - origin.y)
        func map(_ point: PagePoint) -> CGPoint { CGPoint(x: origin.x + point.x * scale.x, y: origin.y + point.y * scale.y) }
        let color = style.color.uiColor.withAlphaComponent(1)
        let core = UIColor(red: (style.color.red + 2) / 3, green: (style.color.green + 2) / 3, blue: (style.color.blue + 2) / 3, alpha: 1)
        let looks: [(width: CGFloat, color: UIColor)] = [(16, color.withAlphaComponent(0.22)), (8, color.withAlphaComponent(0.6)), (3.2, core)]
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let groups = trail.segments(at: now, levels: Self.levels)
        for (level, segments) in groups.enumerated() {
            let path = CGMutablePath()
            for segment in segments { path.move(to: map(segment.start)); path.addLine(to: map(segment.end)) }
            let opacity = LaserTrail.levelOpacity(level, levels: Self.levels)
            let taper = 0.55 + 0.45 * opacity
            for (index, layer) in strokes[level].enumerated() {
                layer.path = segments.isEmpty ? nil : path
                layer.lineWidth = looks[index].width * taper
                layer.strokeColor = looks[index].color.cgColor
                layer.opacity = Float(opacity)
            }
        }
        let center = pointer ?? hover
        let strength = pointer != nil ? trail.pointerOpacity(at: now) : 0.55
        for (index, layer) in dot.enumerated() {
            guard let center else { layer.path = nil; continue }
            let point = map(PagePoint(x: center.x, y: center.y))
            let radius = [12.0, 6.5, 3.4][index] * (pointer != nil ? 1 : 0.8)
            layer.path = CGPath(ellipseIn: CGRect(x: point.x - radius, y: point.y - radius, width: 2 * radius, height: 2 * radius), transform: nil)
            layer.fillColor = (index == 2 ? core : color.withAlphaComponent([0.25, 0.65, 1][index])).cgColor
            layer.strokeColor = nil
            layer.opacity = Float(strength)
        }
        CATransaction.commit()
    }
}

/// Follows one Pencil (or trackpad, or finger with finger drawing) touch for
/// the laser pointer. Stays possible and never prevents or is prevented, so
/// scrolling, zooming and page selection keep working; a second finger hands
/// over to two-finger navigation.
@MainActor
final class LaserTouchObserver: UIGestureRecognizer, UIGestureRecognizerDelegate {
    var allowFinger = false
    var onBegin: ((UITouch) -> Void)?
    var onMove: (([UITouch]) -> Void)?
    var onEnd: (() -> Void)?
    private weak var tracked: UITouch?
    private var tracking = false
    private var blocked = false
    private var active = Set<UITouch>()

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        cancelsTouchesInView = false; delaysTouchesBegan = false; delaysTouchesEnded = false
    }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        active.formUnion(touches)
        if tracking {
            if tracked?.type == .direct, touches.contains(where: { $0.type == .direct }) { finish(); blocked = true }
            return
        }
        guard !blocked, let touch = touches.first(where: {
            $0.type == .pencil || $0.type == .indirectPointer || (allowFinger && $0.type == .direct)
        }) else { return }
        // Finger drawing: a second finger already down means navigation.
        if touch.type == .direct, active.filter({ $0.type == .direct }).count > 1 { blocked = true; return }
        tracked = touch; tracking = true; onBegin?(touch)
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard tracking, let tracked, touches.contains(tracked) else { return }
        onMove?(event.coalescedTouches(for: tracked) ?? [tracked])
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) { lift(touches) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { lift(touches) }
    private func lift(_ touches: Set<UITouch>) {
        if tracking, tracked.map(touches.contains) ?? true { finish() }
        active.subtract(touches)
        if active.isEmpty { state = .failed }
    }
    private func finish() { tracked = nil; tracking = false; onEnd?() }
    override func reset() {
        if tracking { finish() }
        active.removeAll(); blocked = false
        super.reset()
    }
    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
}
