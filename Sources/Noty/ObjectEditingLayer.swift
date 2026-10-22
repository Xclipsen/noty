import UIKit
import SwiftUI
import PencilKit
import NotebookCore

struct SelectionFilter: Equatable {
    var ink = true, text = true, images = true, shapes = true
}

private extension CGPath {
    var lassoPoints: [PagePoint] {
        var points: [PagePoint] = []
        applyWithBlock { element in
            let value = element.pointee
            if value.type == .moveToPoint || value.type == .addLineToPoint {
                points.append(.init(x: value.points[0].x, y: value.points[0].y))
            }
        }
        return points
    }
}

@MainActor
private enum ObjectClipboard { static var content: PageContent?; static var bounds: CGRect? }

@MainActor
private final class SelectionHandle: UIView {
    private let dot = UIView()
    init(color: UIColor) {
        super.init(frame: .zero); backgroundColor = .clear
        dot.backgroundColor = color; dot.isUserInteractionEnabled = false
        dot.layer.cornerRadius = 5; addSubview(dot)
        isAccessibilityElement = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layoutSubviews() { super.layoutSubviews(); dot.frame = CGRect(x: 17, y: 17, width: 10, height: 10) }
}

/// Shapes and mixed selections are independent of app chrome. Commits compare
/// the complete captured starting state; a second pane cannot be overwritten.
@MainActor
final class ObjectEditingLayer: UIView, UIGestureRecognizerDelegate {
    private var content = PageContent(page: Page())
    private var pageID: UUID?
    private var layout = PageLayout(source: .testPaper, legacyA4: true)
    private var generation = -1
    private var enabled = false
    private var allowsFingerDrawing = false
    private var tool = EditorTool.pen
    private var options = ShapeToolOptions()
    private var filter = SelectionFilter()
    private var lassoMode = LassoMode.freeform
    private var color = InkColor(0, 0, 0)
    /// Autostift: black/white by the paper below the shape's start (canonical point).
    var automaticColor: ((PagePoint) -> InkColor?)?
    private var lineWidth: Double = 2
    private var ink = Set<Int>(), texts = Set<UUID>(), images = Set<UUID>(), shapes = Set<UUID>()
    private var lasso: [CGPoint] = []
    private var initialPoint = CGPoint.zero
    private var startContent: PageContent?
    private var preview: PageContent?
    private var inkTransform: CGAffineTransform?
    /// Move/scale/rotation of the whole group during a drag; the cached
    /// contour follows it instead of being rebuilt per touch event.
    private var groupTransform: CGAffineTransform?
    private var dragMode = 0 // 0 lasso, 1 move, 2 scale, 3 new shape, 4/5 endpoints
    private var draft: ShapeObject?
    /// Selection dragged off its page (continuous notebook only).
    private var lift: SelectionLift?
    /// Members selected by a cross-page transfer onto this page. Re-applied if a
    /// configure resets the layer while the notebook still publishes exactly
    /// that content, so the moved selection stays visible and can be dragged on.
    private var adopted: (content: PageContent, selection: TransferredSelection)?
    private var onCommit: ((PageContent, PageContent) -> Bool)?
    var onPreview: ((PageContent) -> Void)?
    var onInkPreview: ((Data, Set<Int>, CGAffineTransform?) -> Void)?
    /// Notebook-wide undo (set by the sheet); this layer keeps no own history.
    weak var notebookUndo: UndoManager?
    private let toolbar = UIScrollView()
    private let actions = UIStackView()
    private let corners = (0..<4).map { _ in SelectionHandle(color: .systemBlue) }
    private let first = SelectionHandle(color: .systemBlue), last = SelectionHandle(color: .systemBlue)
    private let rotation = SelectionHandle(color: .white)
    private var activeCorner = 2
    private var cachedDrawing: (Data, PKDrawing)?
    private var cachedOutline: (SelectionContour.Key, CGPath?)?
    private weak var moreButton: UIButton?
    private let contourLayer = CAShapeLayer()
    private var contourAnimationScale: CGFloat?
    private weak var styleController: UIViewController?
    private lazy var pan = UIPanGestureRecognizer(target: self, action: #selector(drag(_:)))
    /// Apple Pencil Pro haptics (iOS 17.5+); older Pencils simply get none.
    private var feedback: UIFeedbackGenerator?
    /// Frequent light ticks while drawing a lasso or dragging a selection.
    private var motionTicks = MotionTicks()
    private var rotationSnap: Double?
    private var hasSelection: Bool { !ink.isEmpty || !texts.isEmpty || !images.isEmpty || !shapes.isEmpty }
    private var active: Bool { enabled && (tool == .shape || tool == .selection || tool == .inkSelection) }
    override var canBecomeFirstResponder: Bool { active }
    override var inputView: UIView? { UIView(frame: .zero) }
    override var undoManager: UndoManager? { notebookUndo }

    override init(frame: CGRect) {
        super.init(frame: frame); backgroundColor = .clear; isOpaque = false; clipsToBounds = true
        overrideUserInterfaceStyle = .dark
        contourLayer.fillColor = UIColor.systemBlue.withAlphaComponent(0.06).cgColor
        contourLayer.strokeColor = UIColor.systemBlue.cgColor
        contourLayer.lineCap = .round; contourLayer.lineJoin = .round
        layer.addSublayer(contourLayer)
        pan.delegate = self; pan.maximumNumberOfTouches = 1; addGestureRecognizer(pan)
        let tap = UITapGestureRecognizer(target: self, action: #selector(tap(_:))); tap.delegate = self
        tap.require(toFail: pan); addGestureRecognizer(tap)
        toolbar.overrideUserInterfaceStyle = .dark
        toolbar.backgroundColor = UIColor(white: 0.13, alpha: 0.98)
        toolbar.layer.cornerRadius = 22; toolbar.layer.borderWidth = 0.5
        toolbar.layer.borderColor = UIColor.white.withAlphaComponent(0.18).cgColor
        toolbar.showsHorizontalScrollIndicator = false
        toolbar.addSubview(actions); addSubview(toolbar)
        actions.axis = .horizontal; actions.spacing = 0
        button("Stil") { [weak self] in self?.openStyle() }
        button("Duplizieren") { [weak self] in self?.copySelection(); self?.pasteSelection() }
        button("Ausschneiden") { [weak self] in self?.copySelection(); self?.deleteSelection() }
        button("Kopieren") { [weak self] in self?.copySelection() }
        let more = button("Weitere Aktionen", icon: "chevron.right") { }
        moreButton = more
        more.showsMenuAsPrimaryAction = true
        more.menu = UIMenu(children: [
            UIAction(title: "Einfügen", image: UIImage(systemName: "doc.on.clipboard")) { [weak self] _ in self?.pasteSelection() },
            UIAction(title: "Löschen", image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in self?.deleteSelection() },
            UIAction(title: "Horizontal spiegeln", image: UIImage(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right")) { [weak self] _ in self?.mirrorInk(horizontal: true) },
            UIAction(title: "Vertikal spiegeln", image: UIImage(systemName: "arrow.up.and.down.righttriangle.up.righttriangle.down")) { [weak self] _ in self?.mirrorInk(horizontal: false) },
            UIAction(title: "Auswahl aufheben", image: UIImage(systemName: "xmark")) { [weak self] _ in self?.adopted = nil; self?.clearSelection(); self?.refresh() }
        ])
        for (index, handle) in (corners + [first, last, rotation]).enumerated() {
            handle.accessibilityLabel = index < 4 ? "Auswahl proportional skalieren" : index == 6 ? "Handschrift drehen" : "Formpunkt verschieben"
            let drag = UIPanGestureRecognizer(target: self, action: #selector(handle(_:)))
            drag.maximumNumberOfTouches = 1; drag.delegate = ScrollPanPriority.shared
            handle.tag = index; handle.addGestureRecognizer(drag); addSubview(handle)
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(_ incoming: PageContent, pageID: UUID, layout: PageLayout, generation: Int, tool: EditorTool,
                   enabled: Bool, fingerDrawing: Bool, options: ShapeToolOptions, filter: SelectionFilter, lassoMode: LassoMode, color: InkColor, width: Double,
                   onCommit: @escaping (PageContent, PageContent) -> Bool) {
        let samePage = self.pageID == pageID
        let reset = !samePage || self.layout != layout || self.generation != generation
        let needsRefresh = reset || incoming.shapes != content.shapes || active || (enabled && (tool == .shape || tool == .selection || tool == .inkSelection))
        if reset || incoming != content {
            clearSelection(); endLift()
            preview = nil; inkTransform = nil; startContent = nil; draft = nil; lasso = []
        }
        if let adopted {
            if samePage, adopted.content == incoming {
                if !hasSelection { select(adopted.selection, in: incoming) }
            } else { self.adopted = nil }
        }
        if self.tool != tool || !enabled { endLift(); preview = nil; inkTransform = nil; startContent = nil; draft = nil; lasso = [] }
        self.content = incoming; self.pageID = pageID; self.layout = layout; self.generation = generation
        let touches = [UITouch.TouchType.pencil, .direct, .indirectPointer].map { NSNumber(value: $0.rawValue) }
        if pan.allowedTouchTypes != touches { pan.allowedTouchTypes = touches }
        self.tool = tool; self.enabled = enabled; self.allowsFingerDrawing = fingerDrawing; self.options = options; self.filter = filter
        self.lassoMode = lassoMode
        self.color = color; self.lineWidth = width; self.onCommit = onCommit
        // Shapes are drawn in every mode; transparent space passes through when inactive.
        isUserInteractionEnabled = active
        isHidden = !active
        if needsRefresh { refresh() }
    }

    func adoptCommit(_ onCommit: @escaping (PageContent, PageContent) -> Bool) { self.onCommit = onCommit }
    /// A drag, lift or new shape is shown instead of the committed content.
    var showsTransientPreview: Bool { preview != nil || draft != nil || lift != nil || startContent != nil }
    /// Memory warning: the decoded drawing and contour are rebuilt when needed.
    func releaseMemory() { if !hasSelection, startContent == nil { cachedDrawing = nil; cachedOutline = nil } }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { contourLayer.removeAllAnimations(); contourAnimationScale = nil; endLift() }
        else { setNeedsLayout() }
    }
    /// Selection/shape drags win over notebook scrolling (handles: `ScrollPanPriority`).
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
        gestureRecognizer === pan && ScrollPanPriority.outranksScrolling(gestureRecognizer, other)
    }

    override func draw(_ rect: CGRect) {
        let visible = preview ?? content
        if active, let rect = selectionBounds(visible, applyingPreview: true) {
            if !rotation.isHidden {
                let r = display(rect).insetBy(dx: -contourGap, dy: -contourGap); let connector = UIBezierPath()
                connector.move(to: CGPoint(x: r.maxX, y: r.midY)); connector.addLine(to: rotation.center)
                UIColor.white.withAlphaComponent(0.8).setStroke(); connector.lineWidth = 1.5 / displayScale; connector.stroke()
            }
        }
        if lasso.count > 1 {
            let path = UIBezierPath(); path.move(to: lasso[0]); lasso.dropFirst().forEach { path.addLine(to: $0) }
            let scale = displayScale
            UIColor.systemBlue.setStroke(); path.lineWidth = 1.5 / scale
            path.lineCapStyle = .round; path.lineJoinStyle = .round
            path.setLineDash([6 / scale, 4 / scale], count: 2, phase: 0); path.stroke()
        }
    }
    private func canonical(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x - layout.contentOrigin.x, y: point.y - layout.contentOrigin.y)
    }
    private func display(_ rect: CGRect) -> CGRect { rect.offsetBy(dx: layout.contentOrigin.x, dy: layout.contentOrigin.y) }
    private func clearSelection() { ink = []; texts = []; images = []; shapes = []; styleController?.dismiss(animated: false) }
    @discardableResult private func button(_ name: String, icon: String? = nil, action: @escaping () -> Void) -> UIButton {
        let button = UIButton(type: .system)
        if let icon { button.setImage(UIImage(systemName: icon), for: .normal) }
        else { button.setTitle(name, for: .normal) }
        button.tintColor = .white; button.setTitleColor(.white, for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
        button.accessibilityLabel = name; button.toolTip = name
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
        button.widthAnchor.constraint(equalToConstant: icon == nil ? max(56, (name as NSString).size(withAttributes: [.font: UIFont.systemFont(ofSize: 15, weight: .semibold)]).width + 28) : 40).isActive = true
        actions.addArrangedSubview(button)
        return button
    }
    func publishPreview(ifTransientOnly: Bool = false) {
        if ifTransientOnly && preview == nil && draft == nil { return }
        var displayed = preview ?? content
        if let draft { displayed.shapes.append(draft) }
        onPreview?(displayed)
        // A lifted selection floats above the notebook; its page shows the remainder.
        if let lift { onInkPreview?(lift.remainder.drawing, [], nil) }
        else { onInkPreview?((startContent ?? content).drawing, ink, inkTransform) }
    }
    private func refresh() {
        let lifted = lift != nil
        toolbar.isHidden = !active || lifted || (!hasSelection && ObjectClipboard.content == nil)
        for corner in corners { corner.isHidden = !active || lifted || !hasSelection }
        rotation.isHidden = !active || lifted || ink.isEmpty || !texts.isEmpty || !images.isEmpty || !shapes.isEmpty
        let editableShape = active && !lifted && shapes.count == 1 && ink.isEmpty && texts.isEmpty && images.isEmpty
        first.isHidden = !editableShape; last.isHidden = !editableShape
        if let menu = moreButton?.menu {
            let onlyInk = !ink.isEmpty && texts.isEmpty && images.isEmpty && shapes.isEmpty
            for action in menu.children.compactMap({ $0 as? UIAction }) where action.title.contains("spiegeln") {
                action.attributes = onlyInk ? [] : .disabled
            }
        }
        if active && (hasSelection || startContent != nil) { becomeFirstResponder() }
        else if !active { resignFirstResponder() }
        setNeedsLayout(); setNeedsDisplay()
        publishPreview()
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        HangProbe.hit("Object.layoutSubviews")
        let controls: [UIView] = [toolbar] + corners + [first, last, rotation]
        for control in controls { control.transform = .identity }
        // Controls frame the contour, which keeps a small gap around the content.
        let group = selectionBounds(preview ?? content, applyingPreview: true).map { display($0).insetBy(dx: -contourGap, dy: -contourGap) }
        let scale = displayScale
        let intersection = window.map { convert($0.bounds, from: $0).intersection(bounds) } ?? bounds
        let visible = intersection.isNull || intersection.isEmpty ? bounds : intersection
        let fullWidth = actions.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize).width + 8
        let width = min(fullWidth, max(44, visible.width * scale - 8))
        toolbar.bounds = CGRect(x: 0, y: 0, width: width, height: 44)
        toolbar.center = CGPoint(x: min(max((group?.midX ?? visible.midX), visible.minX + (width / 2 + 4) / scale),
            visible.maxX - (width / 2 + 4) / scale),
            y: min(max((group?.minY ?? visible.maxY) - 30 / scale, visible.minY + 26 / scale), visible.maxY - 26 / scale))
        actions.frame = CGRect(x: 4, y: 2, width: fullWidth - 8, height: 40); toolbar.contentSize = CGSize(width: fullWidth, height: 44)
        if let group {
            let points = [CGPoint(x: group.minX, y: group.minY), CGPoint(x: group.maxX, y: group.minY),
                          CGPoint(x: group.maxX, y: group.maxY), CGPoint(x: group.minX, y: group.maxY)]
            for (handle, point) in zip(corners, points) { handle.frame = handleFrame(point) }
            rotation.frame = handleFrame(CGPoint(x: group.maxX + 38 / scale, y: group.midY))
        }
        if let id = shapes.first, let shape = (preview ?? content).shapes.first(where: { $0.id == id }) {
            first.frame = handleFrame(CGPoint(x: shape.start.x + layout.contentOrigin.x, y: shape.start.y + layout.contentOrigin.y))
            last.frame = handleFrame(CGPoint(x: shape.end.x + layout.contentOrigin.x, y: shape.end.y + layout.contentOrigin.y))
        }
        for control in controls {
            let center = control.center
            control.transform = CGAffineTransform(scaleX: 1 / scale, y: 1 / scale)
            control.center = center
        }
        updateContour()
    }
    private func updateContour() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard active, let frame = selectionBounds(preview ?? content, applyingPreview: true) else {
            contourLayer.isHidden = true; contourLayer.removeAllAnimations(); contourAnimationScale = nil; return
        }
        let scale = displayScale
        contourLayer.bounds = bounds; contourLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        contourLayer.path = selectionOutline() ?? UIBezierPath(roundedRect: display(frame).insetBy(dx: -contourGap, dy: -contourGap),
                                                               cornerRadius: contourGap).cgPath
        contourLayer.lineWidth = 1.5 / scale; contourLayer.lineDashPattern = [NSNumber(value: 5 / scale), NSNumber(value: 5 / scale)]
        contourLayer.isHidden = false
        if UIAccessibility.isReduceMotionEnabled {
            contourLayer.removeAllAnimations(); contourAnimationScale = nil
        } else if window != nil, contourAnimationScale != scale {
            contourLayer.removeAllAnimations()
            let animation = CABasicAnimation(keyPath: "lineDashPhase")
            animation.fromValue = 0; animation.toValue = -10 / scale
            animation.duration = 0.8; animation.repeatCount = .infinity
            contourLayer.add(animation, forKey: "selection.contour")
            contourAnimationScale = scale
        }
    }
    private func handleFrame(_ point: CGPoint) -> CGRect {
        let radius = 22 / displayScale
        return .init(x: min(max(bounds.minX + radius, point.x), max(bounds.minX + radius, bounds.maxX - radius)) - 22,
                     y: min(max(bounds.minY + radius, point.y), max(bounds.minY + radius, bounds.maxY - radius)) - 22, width: 44, height: 44)
    }
    private var displayScale: CGFloat {
        guard let window else { return 1 }
        let a = convert(CGPoint.zero, to: window), b = convert(CGPoint(x: 100, y: 0), to: window)
        return max(0.001, hypot(b.x - a.x, b.y - a.y) / 100)
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard active, touch.view === self else { return false }
        if gestureRecognizer === pan, touch.type != .pencil, !allowsFingerDrawing {
            return selectionBounds(content).map(display)?.insetBy(dx: -8 / displayScale, dy: -8 / displayScale)
                .contains(touch.location(in: self)) == true
        }
        return true
    }
    @objc private func tap(_ gesture: UITapGestureRecognizer) {
        adopted = nil; clearSelection()
        let point = canonical(gesture.location(in: self))
        if (tool == .shape || filter.shapes), let shape = content.shapes.reversed().first(where: { ShapeRendering.hit($0, at: point) }) { shapes.insert(shape.id) }
        else if tool == .selection || tool == .inkSelection {
            let rect = CGRect(x: point.x - 2, y: point.y - 2, width: 4, height: 4)
            select(path: UIBezierPath(rect: rect), rect: rect, tap: true)
        }
        refresh()
    }
    @objc private func drag(_ gesture: UIPanGestureRecognizer) { self.gesture(gesture, requestedMode: nil) }
    @objc private func handle(_ gesture: UIPanGestureRecognizer) {
        let tag = gesture.view?.tag ?? 2
        if gesture.state == .began { activeCorner = tag }
        self.gesture(gesture, requestedMode: tag < 4 ? 2 : tag == 6 ? 6 : tag == 4 ? 4 : 5)
    }
    private func gesture(_ gesture: UIPanGestureRecognizer, requestedMode: Int?) {
        guard active else { return }
        let point = canonical(gesture.location(in: self))
        if gesture.state == .began {
            adopted = nil; rotationSnap = nil
            if #available(iOS 17.5, *), feedback == nil { feedback = UICanvasFeedbackGenerator(view: self) }
            feedback?.prepare()
            let screen = gesture.location(in: nil)
            motionTicks.begin(at: .init(x: screen.x, y: screen.y), time: CACurrentMediaTime())
            let translation = gesture.translation(in: self)
            initialPoint = CGPoint(x: point.x - translation.x, y: point.y - translation.y)
            startContent = content; preview = nil; inkTransform = nil; groupTransform = nil
            if let requestedMode { dragMode = requestedMode }
            else if selectionBounds(content)?.insetBy(dx: -8 / displayScale, dy: -8 / displayScale).contains(initialPoint) == true { dragMode = 1 }
            else if tool == .shape {
                clearSelection(); dragMode = 3
                let color = automaticColor?(.init(x: initialPoint.x, y: initialPoint.y)) ?? color
                draft = ShapeObject(kind: options.kind, start: .init(x: initialPoint.x, y: initialPoint.y), end: .init(x: point.x, y: point.y),
                    color: color, lineWidth: lineWidth, pattern: options.pattern, fill: options.filled ? InkColor(color.red, color.green, color.blue, 0.2) : nil)
            } else { clearSelection(); dragMode = 0; lasso = [CGPoint(x: initialPoint.x + layout.contentOrigin.x, y: initialPoint.y + layout.contentOrigin.y)] }
        }
        guard let initial = startContent else { return }
        if gesture.state == .cancelled || gesture.state == .failed {
            endLift(); preview = nil; inkTransform = nil; draft = nil; startContent = nil; lasso = []; refresh(); return
        }
        switch dragMode {
        case 0:
            if lassoMode == .rectangle {
                let a = CGPoint(x: initialPoint.x + layout.contentOrigin.x, y: initialPoint.y + layout.contentOrigin.y)
                let b = gesture.location(in: self)
                lasso = [a, CGPoint(x: b.x, y: a.y), b, CGPoint(x: a.x, y: b.y), a]
            } else { lasso.append(gesture.location(in: self)) }
        case 1:
            // Outside its own sheet the selection lifts off and follows the
            // touch above all pages; inside, it keeps the clamped in-page move.
            var lifted = false
            if let host = transferHost, !CGRect(origin: .zero, size: layout.canvas.cgSize).contains(gesture.location(in: self)) {
                if lift == nil { lift = makeLift(initial) }
                if let lift { lifted = true; preview = lift.remainder; inkTransform = nil; host.floatSelection(lift, gesture: gesture) }
            }
            if !lifted {
                if lift != nil { endLift(); preview = initial; inkTransform = nil; groupTransform = nil }
                if let value = transformed(initial, dx: point.x - initialPoint.x, dy: point.y - initialPoint.y, scale: 1) { preview = value }
            }
        case 2:
            if let frame = selectionBounds(initial) {
                let anchors = [PagePoint(x: frame.maxX, y: frame.maxY), .init(x: frame.minX, y: frame.maxY),
                               .init(x: frame.minX, y: frame.minY), .init(x: frame.maxX, y: frame.minY)]
                let anchor = anchors[min(3, activeCorner)]
                let scale = SelectionTransform.projectedScale(start: .init(x: initialPoint.x, y: initialPoint.y),
                    current: .init(x: point.x, y: point.y), anchor: anchor)
                if let value = transformed(initial, dx: 0, dy: 0, scale: scale, anchor: anchor) { preview = value }
            }
        case 6:
            if let frame = selectionBounds(initial) {
                let angle = atan2(point.y - frame.midY, point.x - frame.midX) - atan2(initialPoint.y - frame.midY, initialPoint.x - frame.midX)
                let degrees = ImageObject.snappedRotation(angle * 180 / .pi)
                // Tick once when the handwriting clicks into another right angle.
                let snap: Double? = degrees != 0 && (degrees / 90).rounded() * 90 == degrees ? degrees : nil
                if let snap, snap != rotationSnap { haptic(completed: false, at: gesture.location(in: self)) }
                rotationSnap = snap
                let t = CGAffineTransform(translationX: -frame.midX, y: -frame.midY)
                    .concatenating(CGAffineTransform(rotationAngle: degrees * .pi / 180))
                    .concatenating(CGAffineTransform(translationX: frame.midX, y: frame.midY))
                preview = initial; inkTransform = t; groupTransform = t
            }
        case 3: draft?.end = .init(x: point.x, y: point.y)
        default:
            if let id = shapes.first, let index = initial.shapes.firstIndex(where: { $0.id == id }) {
                var value = initial
                if dragMode == 4 { value.shapes[index].start = .init(x: point.x, y: point.y) }
                else { value.shapes[index].end = .init(x: point.x, y: point.y) }
                if (try? value.shapes[index].validate()) != nil, limits.contains(value.shapes[index].bounds, tolerance: 0.02) { preview = value }
            }
        }
        // Lasso being drawn or selection being dragged (also lifted across
        // pages): a light Pencil Pro tick every ~44 screen points, ≥ 80 ms apart.
        if gesture.state == .changed, dragMode == 0 || dragMode == 1 {
            let screen = gesture.location(in: nil)
            if motionTicks.move(to: .init(x: screen.x, y: screen.y), at: CACurrentMediaTime()) {
                let local = gesture.location(in: self)
                haptic(completed: false, at: CGPoint(x: min(max(local.x, bounds.minX), bounds.maxX), y: min(max(local.y, bounds.minY), bounds.maxY)))
            }
        }
        if gesture.state == .ended {
            if dragMode == 1, let lifted = lift {
                // Dropped off the source sheet: either an atomic transfer to the
                // page below the touch, or a snap back without any change.
                lift = nil
                let host = transferHost
                host?.hideFloatingSelection()
                _ = host?.dropSelection(lifted, gesture: gesture)
            } else if dragMode == 0 {
                let points = lasso.map(canonical)
                if points.count > 2 {
                    let path = UIBezierPath(); path.move(to: points[0]); points.dropFirst().forEach { path.addLine(to: $0) }; path.close()
                    select(path: path, rect: path.bounds, tap: false)
                    // The closed loop selected something: confirm on Apple Pencil Pro.
                    if hasSelection { haptic(completed: true, at: gesture.location(in: self)) }
                }
            } else if dragMode == 3, let draft, (try? draft.validate()) != nil, limits.contains(draft.bounds, tolerance: 0.02) {
                var value = initial; value.shapes.append(draft)
                if commit(value, previous: initial) { shapes = [draft.id] }
            } else if var preview {
                if let inkTransform {
                    if let changed = transformedInk(initial, using: inkTransform, inkOnly: false) { preview.drawing = changed.drawing }
                    else { preview = initial }
                }
                _ = commit(preview, previous: initial)
            }
            preview = nil; inkTransform = nil; draft = nil; startContent = nil; lasso = []
        }
        refresh()
    }
    private var limits: PageRect { PageRect(layout.canonicalInkBounds) }
    private func haptic(completed: Bool, at point: CGPoint) {
        guard #available(iOS 17.5, *), let feedback = feedback as? UICanvasFeedbackGenerator else { return }
        if completed { feedback.pathCompleted(at: point) } else { feedback.alignmentOccurred(at: point) }
        feedback.prepare()
    }
    private var transferHost: SelectionTransferHost? {
        var view = superview
        while let current = view {
            if let host = current as? SelectionTransferHost { return host }
            view = current.superview
        }
        return nil
    }
    var currentContent: PageContent { content }
    private func endLift() {
        guard lift != nil else { return }
        lift = nil; transferHost?.hideFloatingSelection()
    }
    private func makeLift(_ initial: PageContent) -> SelectionLift? {
        guard let pageID, let frame = selectionBounds(initial) else { return nil }
        var strokes: [PKStroke] = []
        var remainder = CrossPageTransfer.removing(texts: texts, images: images, shapes: shapes, from: initial)
        if !ink.isEmpty {
            guard let drawing = drawing(initial.drawing), ink.allSatisfy({ drawing.strokes.indices.contains($0) }) else { return nil }
            strokes = drawing.strokes.enumerated().filter { ink.contains($0.offset) }.map(\.element)
            remainder.drawing = PKDrawing(strokes: drawing.strokes.enumerated().filter { !ink.contains($0.offset) }.map(\.element)).dataRepresentation()
        }
        let objects = MovedObjects(textBoxes: initial.textBoxes.filter { texts.contains($0.id) && $0.allowsObjectSelection },
            images: initial.images.filter { images.contains($0.id) && !$0.locked }, shapes: initial.shapes.filter { shapes.contains($0.id) })
        guard !objects.isEmpty || !strokes.isEmpty else { return nil }
        let snapshot = SelectionTransfer.snapshot(objects: objects, ink: strokes, frame: frame,
            pixelScale: displayScale * (window?.screen.scale ?? 2))
        return SelectionLift(pageID: pageID, content: initial, remainder: remainder, ink: strokes, objects: objects,
            frame: frame, start: initialPoint, snapshot: snapshot)
    }
    /// A cross-page transfer was committed atomically by the notebook (one
    /// notebook-wide undo step for both pages). The source keeps its remainder;
    /// the target selects the moved members so they can be moved on directly.
    func adoptTransfer(_ value: PageContent, selecting selection: TransferredSelection? = nil) {
        endLift()
        preview = nil; inkTransform = nil; startContent = nil; draft = nil; lasso = []
        clearSelection(); content = value
        adopted = selection.map { (value, $0) }
        if let selection { select(selection, in: value) }
        refresh()
    }
    /// Applies only members that exist in `value` (stroke indices, object IDs).
    private func select(_ selection: TransferredSelection, in value: PageContent) {
        let strokes = selection.ink.isEmpty ? 0 : (drawing(value.drawing)?.strokes.count ?? 0)
        ink = selection.ink.filter { $0 < strokes }
        texts = selection.texts.intersection(value.textBoxes.map(\.id))
        images = selection.images.intersection(value.images.map(\.id))
        shapes = selection.shapes.intersection(value.shapes.map(\.id))
    }
    private func select(path: UIBezierPath, rect: CGRect, tap: Bool) {
        let region = LassoRegion(points: path.cgPath.lassoPoints)
        func selected(_ bounds: CGRect) -> Bool {
            guard rect.insetBy(dx: -0.001, dy: -0.001).intersects(bounds) else { return false }
            return tap || region.intersects(PageRect(bounds))
        }
        if filter.text { texts = Set(content.textBoxes.filter { $0.allowsObjectSelection && selected($0.rect.cgRect) }.map(\.id)) }
        if filter.images { images = Set(content.images.filter { !$0.locked && selected($0.rotatedBounds.cgRect) }.map(\.id)) }
        if filter.shapes { shapes = Set(content.shapes.filter { selected($0.bounds.cgRect) }.map(\.id)) }
        if filter.ink, let drawing = try? PKDrawing(data: content.drawing) {
            ink = Set(drawing.strokes.indices.filter { index in
                let stroke = drawing.strokes[index]
                guard rect.insetBy(dx: -0.001, dy: -0.001).intersects(stroke.renderBounds) else { return false }
                var points = stroke.path.interpolatedPoints(by: .distance(3)).map { sample -> PagePoint in
                    let point = sample.location.applying(stroke.transform)
                    return .init(x: point.x, y: point.y)
                }
                if points.isEmpty, let sample = stroke.path.first {
                    let point = sample.location.applying(stroke.transform); points = [.init(x: point.x, y: point.y)]
                }
                let width = stroke.path.map { max($0.size.width, $0.size.height) }.max() ?? 0
                let transformScale = max(hypot(stroke.transform.a, stroke.transform.b), hypot(stroke.transform.c, stroke.transform.d))
                return region.intersectsPolyline(points, radius: width * transformScale / 2)
            })
        }
    }
    private func drawing(_ data: Data) -> PKDrawing? {
        if cachedDrawing?.0 == data { return cachedDrawing?.1 }
        guard let drawing = data.isEmpty ? PKDrawing() : try? PKDrawing(data: data) else { return nil }
        cachedDrawing = (data, drawing); return drawing
    }
    private func selectionBounds(_ value: PageContent, applyingPreview: Bool = false) -> CGRect? {
        guard hasSelection, !(applyingPreview && lift != nil) else { return nil }
        var rects = value.textBoxes.filter { texts.contains($0.id) }.map { $0.rect.cgRect }
        rects += value.images.filter { images.contains($0.id) }.map { $0.rotatedBounds.cgRect }
        rects += value.shapes.filter { shapes.contains($0.id) }.map { $0.bounds.cgRect }
        if !ink.isEmpty, let drawing = drawing(value.drawing) {
            rects += drawing.strokes.enumerated().filter { ink.contains($0.offset) }.map {
                let frame = $0.element.renderBounds
                return applyingPreview ? frame.applying(inkTransform ?? .identity) : frame
            }
        }
        return rects.reduce(nil) { $0?.union($1) ?? $1 }
    }
    /// Contour gap in page points: a constant few screen points at any zoom.
    private var contourGap: CGFloat { SelectionOutline.gap(displayScale: displayScale) }
    /// Native-lasso style contour around every selected member (`SelectionContour`),
    /// in display coordinates. During move/scale/rotate the contour of the
    /// starting state follows the group transform; shape point drags rebuild it.
    private func selectionOutline() -> CGPath? {
        guard lift == nil, hasSelection else { return nil }
        var base = preview ?? content, transform = CGAffineTransform.identity
        if preview != nil, let start = startContent, let groupTransform, [1, 2, 6].contains(dragMode) {
            base = start; transform = groupTransform
        }
        let gap = Double(contourGap)
        let key = SelectionContour.key(base, ink: ink, texts: texts, images: images, shapes: shapes, gap: gap)
        let path: CGPath?
        if let cached = cachedOutline, cached.0 == key { path = cached.1 }
        else {
            path = SelectionContour.path(base, drawing: ink.isEmpty ? nil : drawing(base.drawing), ink: ink, texts: texts,
                                         images: images, shapes: shapes, gap: gap)
            cachedOutline = (key, path)
        }
        guard let path else { return nil }
        var display = transform.concatenating(CGAffineTransform(translationX: layout.contentOrigin.x, y: layout.contentOrigin.y))
        return path.copy(using: &display)
    }
    private func transformedInk(_ initial: PageContent, using transform: CGAffineTransform, inkOnly: Bool = true) -> PageContent? {
        guard (!inkOnly || (texts.isEmpty && images.isEmpty && shapes.isEmpty)), !ink.isEmpty,
              var drawing = drawing(initial.drawing) else { return nil }
        let allowed = limits.cgRect.union(selectionBounds(initial) ?? .zero).insetBy(dx: -0.02, dy: -0.02)
        drawing.strokes = drawing.strokes.enumerated().map { index, stroke in
            ink.contains(index) ? PKDrawing(strokes: [stroke]).transformed(using: transform).strokes[0] : stroke
        }
        guard ink.allSatisfy({ drawing.strokes.indices.contains($0) && allowed.contains(drawing.strokes[$0].renderBounds) }) else { return nil }
        var result = initial; result.drawing = drawing.dataRepresentation(); return result
    }
    private func mirrorInk(horizontal: Bool) {
        guard let frame = selectionBounds(content) else { return }
        let transform = CGAffineTransform(a: horizontal ? -1 : 1, b: 0, c: 0, d: horizontal ? 1 : -1,
            tx: horizontal ? 2 * frame.midX : 0, ty: horizontal ? 0 : 2 * frame.midY)
        if let value = transformedInk(content, using: transform) { _ = commit(value, previous: content); refresh() }
    }
    private func openStyle() {
        guard hasSelection, !ink.isEmpty || !texts.isEmpty || !shapes.isEmpty else { return }
        var responder: UIResponder? = self
        while responder != nil && !(responder is UIViewController) { responder = responder?.next }
        guard let parent = responder as? UIViewController else { return }
        let controller = UIViewController(); controller.overrideUserInterfaceStyle = .dark
        controller.modalPresentationStyle = .popover; controller.preferredContentSize = CGSize(width: 320, height: 250)
        let root = controller.view!; root.backgroundColor = UIColor(white: 0.055, alpha: 1)
        let title = UILabel(frame: CGRect(x: 20, y: 16, width: 280, height: 24))
        title.text = "Strich"; title.font = .systemFont(ofSize: 17, weight: .semibold); title.textColor = .white; root.addSubview(title)
        let slider = UISlider(frame: CGRect(x: 20, y: 48, width: 280, height: 44))
        if let index = ink.first, let drawing = drawing(content.drawing), drawing.strokes.indices.contains(index) {
            let stroke = drawing.strokes[index]
            lineWidth = (stroke.path.map { max($0.size.width, $0.size.height) }.max() ?? lineWidth)
                * max(hypot(stroke.transform.a, stroke.transform.b), hypot(stroke.transform.c, stroke.transform.d))
        } else if let id = shapes.first, let shape = content.shapes.first(where: { $0.id == id }) { lineWidth = shape.lineWidth }
        slider.minimumValue = 0.5; slider.maximumValue = 20; slider.value = Float(lineWidth)
        slider.accessibilityLabel = "Strichstärke der Auswahl"
        slider.addAction(UIAction { [weak self, weak slider] _ in
            guard let self, let slider, self.active else { return }
            self.lineWidth = Double(slider.value); self.applyStyle(changeWidth: true)
        }, for: [.touchUpInside, .touchUpOutside]); root.addSubview(slider)
        let label = UILabel(frame: CGRect(x: 20, y: 98, width: 280, height: 24))
        label.text = "Farben"; label.font = .systemFont(ofSize: 17, weight: .semibold); label.textColor = .white; root.addSubview(label)
        let colors: [(UIColor, String)] = [(.systemYellow, "Gelb"), (.systemOrange, "Orange"), (.systemRed, "Rot"), (.systemPink, "Pink"),
            (.systemGreen, "Grün"), (.systemMint, "Mint"), (.systemBlue, "Blau"), (.systemPurple, "Lila"),
            (.black, "Schwarz"), (.darkGray, "Dunkelgrau"), (.white, "Weiß"), (.brown, "Braun")]
        for (index, (color, name)) in colors.enumerated() {
            let button = UIButton(type: .system)
            button.frame = CGRect(x: 20 + (index % 6) * 48, y: 136 + (index / 6) * 48, width: 34, height: 34)
            button.backgroundColor = color; button.layer.cornerRadius = 17
            button.layer.borderWidth = 1; button.layer.borderColor = UIColor.white.withAlphaComponent(0.3).cgColor
            button.accessibilityLabel = name; button.accessibilityHint = "Färbt die Auswahl"
            button.addAction(UIAction { [weak self] _ in
                guard let self, self.active else { return }; self.color = InkColor(SwiftUI.Color(color)); self.applyStyle()
            }, for: .touchUpInside); root.addSubview(button)
        }
        if let popover = controller.popoverPresentationController {
            popover.sourceView = toolbar; popover.sourceRect = toolbar.bounds; popover.permittedArrowDirections = [.up, .down]
            popover.backgroundColor = root.backgroundColor
        }
        styleController = controller; parent.present(controller, animated: true)
    }
    private func transformed(_ initial: PageContent, dx: Double, dy: Double, scale requested: Double, anchor requestedAnchor: PagePoint? = nil) -> PageContent? {
        guard let frame = selectionBounds(initial) else { return nil }
        var minimum = 0.01, maximum = 100.0
        for box in initial.textBoxes where texts.contains(box.id) {
            for size in [box.style.fontSize] + (box.runs ?? []).map({ $0.style.fontSize }) {
                minimum = max(minimum, 8 / size); maximum = min(maximum, 96 / size)
            }
            minimum = max(minimum, 1 / box.width, 1 / box.height)
        }
        for shape in initial.shapes where shapes.contains(shape.id) {
            minimum = max(minimum, 0.5 / shape.lineWidth, 1 / hypot(shape.end.x - shape.start.x, shape.end.y - shape.start.y))
            maximum = min(maximum, 40 / shape.lineWidth)
            if shape.kind == .rectangle || shape.kind == .ellipse { minimum = max(minimum, 1 / shape.frame.width, 1 / shape.frame.height) }
        }
        for image in initial.images where images.contains(image.id) { minimum = max(minimum, 1 / image.width, 1 / image.height) }
        let change = SelectionTransform(frame: PageRect(frame), anchor: requestedAnchor ?? .init(x: frame.minX, y: frame.minY),
            translation: .init(x: dx, y: dy), scale: requested, limits: limits, minimumScale: minimum, maximumScale: maximum)
        let scale = change.scale, dx = change.translation.x, dy = change.translation.y, anchor = change.anchor
        let transform = CGAffineTransform(a: scale, b: 0, c: 0, d: scale,
                                         tx: anchor.x * (1 - scale) + dx, ty: anchor.y * (1 - scale) + dy)
        var value = initial
        func point(_ p: PagePoint) -> PagePoint { let p = CGPoint(x: p.x, y: p.y).applying(transform); return .init(x: p.x, y: p.y) }
        for i in value.textBoxes.indices where texts.contains(value.textBoxes[i].id) {
            guard let box = try? value.textBoxes[i].scaled(by: scale, around: anchor,
                translation: .init(x: dx, y: dy)), limits.contains(box.rect) else { return nil }
            value.textBoxes[i] = box
        }
        for i in value.images.indices where images.contains(value.images[i].id) {
            let p = point(.init(x: value.images[i].x, y: value.images[i].y))
            value.images[i].x = p.x; value.images[i].y = p.y
            value.images[i].width *= scale; value.images[i].height *= scale
            guard (try? value.images[i].validate()) != nil, value.images[i].fits(in: limits) else { return nil }
        }
        for i in value.shapes.indices where shapes.contains(value.shapes[i].id) {
            value.shapes[i].start = point(value.shapes[i].start); value.shapes[i].end = point(value.shapes[i].end)
            value.shapes[i].lineWidth *= scale
            guard (try? value.shapes[i].validate()) != nil, limits.contains(value.shapes[i].bounds, tolerance: 0.02) else { return nil }
        }
        inkTransform = ink.isEmpty ? nil : transform
        groupTransform = transform
        return value
    }
    /// The notebook records the change as one notebook-wide undo step.
    private func commit(_ value: PageContent, previous: PageContent) -> Bool {
        guard value != previous, onCommit?(value, previous) == true else { return false }
        content = value; adopted = nil
        return true
    }
    private func copySelection() {
        guard let frame = selectionBounds(content) else { return }
        var value = content
        value.textBoxes.removeAll { !texts.contains($0.id) }; value.images.removeAll { !images.contains($0.id) }
        value.shapes.removeAll { !shapes.contains($0.id) }
        let drawing = (try? PKDrawing(data: content.drawing)) ?? PKDrawing()
        value.drawing = PKDrawing(strokes: drawing.strokes.enumerated().filter { ink.contains($0.offset) }.map(\.element)).dataRepresentation()
        ObjectClipboard.content = value; ObjectClipboard.bounds = frame
        // Pasting into another notebook stages the originals from this package.
        ImageAssetRegistry.shared.pinClipboard(value.images.map(\.asset))
    }
    private func pasteSelection() {
        guard let copied = ObjectClipboard.content, let frame = ObjectClipboard.bounds else { return }
        clearSelection()
        var value = content
        let bounds = limits.cgRect
        let dx = max(bounds.minX - frame.minX, min(24, bounds.maxX - frame.maxX))
        let dy = max(bounds.minY - frame.minY, min(24, bounds.maxY - frame.maxY))
        guard frame.width <= bounds.width, frame.height <= bounds.height else { return }
        for box in copied.textBoxes { var box = box; box.id = UUID(); box.x += dx; box.y += dy; texts.insert(box.id); value.textBoxes.append(box) }
        for image in copied.images { var image = image; image.id = UUID(); image.x += dx; image.y += dy; images.insert(image.id); value.images.append(image) }
        for shape in copied.shapes { var shape = shape.translated(x: dx, y: dy); shape.id = UUID(); shapes.insert(shape.id); value.shapes.append(shape) }
        let drawing = (try? PKDrawing(data: content.drawing)) ?? PKDrawing()
        let pasted = ((try? PKDrawing(data: copied.drawing)) ?? PKDrawing()).transformed(using: .init(translationX: dx, y: dy))
        ink = Set(drawing.strokes.count..<(drawing.strokes.count + pasted.strokes.count))
        value.drawing = PKDrawing(strokes: drawing.strokes + pasted.strokes).dataRepresentation()
        if !commit(value, previous: content) { clearSelection() }; refresh()
    }
    private func deleteSelection() {
        // Without a selection Backspace/„Löschen“ must not re-encode the ink
        // into an invisible undo step.
        guard hasSelection else { return }
        var value = content
        value.textBoxes.removeAll { texts.contains($0.id) }; value.images.removeAll { images.contains($0.id) }
        value.shapes.removeAll { shapes.contains($0.id) }
        if !ink.isEmpty {
            let drawing = (try? PKDrawing(data: content.drawing)) ?? PKDrawing()
            value.drawing = PKDrawing(strokes: drawing.strokes.enumerated().filter { !ink.contains($0.offset) }.map(\.element)).dataRepresentation()
        }
        _ = commit(value, previous: content); clearSelection(); refresh()
    }
    private func applyStyle(changeWidth: Bool = false) {
        var value = content
        if !ink.isEmpty, var drawing = try? PKDrawing(data: content.drawing) {
            drawing.strokes = drawing.strokes.enumerated().map { index, stroke in
                guard ink.contains(index) else { return stroke }
                let oldWidth = stroke.path.map { max($0.size.width, $0.size.height) }.max() ?? lineWidth
                let transformScale = max(hypot(stroke.transform.a, stroke.transform.b), hypot(stroke.transform.c, stroke.transform.d))
                let factor = changeWidth ? lineWidth / max(0.01, oldWidth * transformScale) : 1
                let points = stroke.path.map { p in PKStrokePoint(location: p.location, timeOffset: p.timeOffset,
                    size: CGSize(width: p.size.width * factor, height: p.size.height * factor), opacity: p.opacity,
                    force: p.force, azimuth: p.azimuth, altitude: p.altitude, secondaryScale: p.secondaryScale) }
                // Highlighter strokes (chisel marker, round monoline) keep their
                // translucency: an opaque round marker would hide the text below.
                let highlighter = stroke.ink.inkType == .marker || stroke.ink.inkType == .monoline
                let inkColor = highlighter ? color.uiColor.withAlphaComponent(stroke.ink.color.cgColor.alpha) : color.uiColor
                return PKStroke(ink: PKInk(stroke.ink.inkType, color: inkColor),
                    path: PKStrokePath(controlPoints: points, creationDate: stroke.path.creationDate), transform: stroke.transform, mask: stroke.mask)
            }
            value.drawing = drawing.dataRepresentation()
        }
        for i in value.textBoxes.indices where texts.contains(value.textBoxes[i].id) {
            value.textBoxes[i].style.ink = color
            value.textBoxes[i].runs = value.textBoxes[i].runs?.map { run in var run = run; run.style.ink = color; return run }
        }
        for i in value.shapes.indices where shapes.contains(value.shapes[i].id) {
            value.shapes[i].color = color
            if changeWidth { value.shapes[i].lineWidth = lineWidth }
            if let fill = value.shapes[i].fill { value.shapes[i].fill = InkColor(color.red, color.green, color.blue, fill.alpha) }
        }
        _ = commit(value, previous: content); refresh()
    }
    override var keyCommands: [UIKeyCommand]? {
        var commands = [UIKeyCommand(input: "c", modifierFlags: .command, action: #selector(copyKey)),
         UIKeyCommand(input: "v", modifierFlags: .command, action: #selector(pasteKey)),
         UIKeyCommand(input: "\u{8}", modifierFlags: [], action: #selector(deleteKey)),
         UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(escapeKey)),
         UIKeyCommand(title: "Alles auswählen", action: #selector(selectAllKey), input: "a", modifierFlags: .command)]
        guard hasSelection, lift == nil, startContent == nil else { return commands }
        commands += [UIKeyCommand(title: "Ausschneiden", action: #selector(cutKey), input: "x", modifierFlags: .command),
                     UIKeyCommand(title: "Duplizieren", action: #selector(duplicateKey), input: "d", modifierFlags: .command)]
        // Arrow keys move the selection by 1 pt, with ⇧ by 10 pt.
        for input in [UIKeyCommand.inputLeftArrow, UIKeyCommand.inputRightArrow, UIKeyCommand.inputUpArrow, UIKeyCommand.inputDownArrow] {
            for flags in [UIKeyModifierFlags(), .shift] {
                let command = UIKeyCommand(input: input, modifierFlags: flags, action: #selector(nudgeKey(_:)))
                command.wantsPriorityOverSystemBehavior = true
                commands.append(command)
            }
        }
        return commands
    }
    @objc private func copyKey() { copySelection() }
    @objc private func pasteKey() { pasteSelection() }
    @objc private func deleteKey() { deleteSelection() }
    @objc private func escapeKey() { adopted = nil; clearSelection(); refresh() }
    @objc private func cutKey() { guard hasSelection else { return }; copySelection(); deleteSelection() }
    @objc private func duplicateKey() { guard hasSelection else { return }; copySelection(); pasteSelection() }
    /// ⌘A: everything selectable on this page (the lasso's filter; shape tool: shapes).
    @objc private func selectAllKey() {
        guard active, lift == nil, startContent == nil else { return }
        adopted = nil; clearSelection()
        if tool == .shape { shapes = Set(content.shapes.map(\.id)) }
        else {
            if filter.text { texts = Set(content.textBoxes.filter(\.allowsObjectSelection).map(\.id)) }
            if filter.images { images = Set(content.images.filter { !$0.locked }.map(\.id)) }
            if filter.shapes { shapes = Set(content.shapes.map(\.id)) }
            if filter.ink, let drawing = drawing(content.drawing) { ink = Set(drawing.strokes.indices) }
        }
        refresh()
    }
    @objc private func nudgeKey(_ command: UIKeyCommand) {
        let step = command.modifierFlags.contains(.shift) ? 10.0 : 1.0
        let (dx, dy): (Double, Double) = switch command.input ?? "" {
        case UIKeyCommand.inputLeftArrow: (-step, 0)
        case UIKeyCommand.inputRightArrow: (step, 0)
        case UIKeyCommand.inputUpArrow: (0, -step)
        default: (0, step)
        }
        // Same clamped move and ink transform as a drag; one model change per key.
        guard active, hasSelection, lift == nil, startContent == nil, var value = transformed(content, dx: dx, dy: dy, scale: 1) else { return }
        if let inkTransform {
            guard let moved = transformedInk(content, using: inkTransform, inkOnly: false) else { self.inkTransform = nil; return }
            value.drawing = moved.drawing
        }
        inkTransform = nil
        _ = commit(value, previous: content); refresh()
    }
}
