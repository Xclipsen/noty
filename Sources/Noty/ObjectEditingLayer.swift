import UIKit
import PencilKit
import NotebookCore

struct SelectionFilter: Equatable {
    var ink = true, text = true, images = true, shapes = true
}

@MainActor
private enum ObjectClipboard { static var content: PageContent?; static var bounds: CGRect? }

/// Shapes and mixed selections are independent of app chrome. Commits compare
/// the complete captured starting state; a second pane cannot be overwritten.
@MainActor
final class ObjectEditingLayer: UIView, UIGestureRecognizerDelegate {
    private var content = PageContent(page: Page())
    private var pageID: UUID?
    private var layout = PageLayout(source: .testPaper, legacyA4: true)
    private var generation = -1
    private var enabled = false
    private var tool = EditorTool.pen
    private var options = ShapeToolOptions()
    private var filter = SelectionFilter()
    private var color = InkColor(0, 0, 0)
    private var lineWidth: Double = 2
    private var ink = Set<Int>(), texts = Set<UUID>(), images = Set<UUID>(), shapes = Set<UUID>()
    private var lasso: [CGPoint] = []
    private var initialPoint = CGPoint.zero
    private var startContent: PageContent?
    private var preview: PageContent?
    private var dragMode = 0 // 0 lasso, 1 move, 2 scale, 3 new shape, 4/5 endpoints
    private var draft: ShapeObject?
    private var onCommit: ((PageContent, PageContent) -> Bool)?
    private var history = UndoManager()
    private var historyCost = 0
    private let toolbar = UIScrollView()
    private let actions = UIStackView()
    private let resize = UIButton(type: .system)
    private let first = UIButton(type: .system), last = UIButton(type: .system)
    private lazy var pan = UIPanGestureRecognizer(target: self, action: #selector(drag(_:)))
    private var hasSelection: Bool { !ink.isEmpty || !texts.isEmpty || !images.isEmpty || !shapes.isEmpty }
    private var active: Bool { enabled && (tool == .shape || tool == .selection) }
    override var canBecomeFirstResponder: Bool { active }
    override var inputView: UIView? { UIView(frame: .zero) }
    override var undoManager: UndoManager? { history }

    override init(frame: CGRect) {
        super.init(frame: frame); backgroundColor = .clear; isOpaque = false; clipsToBounds = true
        history.levelsOfUndo = 30
        pan.delegate = self; pan.maximumNumberOfTouches = 1; addGestureRecognizer(pan)
        let tap = UITapGestureRecognizer(target: self, action: #selector(tap(_:))); tap.delegate = self
        addGestureRecognizer(tap)
        toolbar.backgroundColor = UIColor.secondarySystemBackground.withAlphaComponent(0.96)
        toolbar.layer.cornerRadius = 10; toolbar.addSubview(actions); addSubview(toolbar)
        actions.axis = .horizontal; actions.spacing = 4
        button("Kopieren", icon: "doc.on.doc") { [weak self] in self?.copySelection() }
        button("Einfügen", icon: "doc.on.clipboard") { [weak self] in self?.pasteSelection() }
        button("Duplizieren", icon: "plus.square.on.square") { [weak self] in self?.copySelection(); self?.pasteSelection() }
        button("Formstil anwenden", icon: "paintbrush") { [weak self] in self?.applyStyle() }
        button("Auswahl löschen", icon: "trash") { [weak self] in self?.deleteSelection() }
        button("Auswahl aufheben", icon: "xmark") { [weak self] in self?.clearSelection(); self?.refresh() }
        for (index, handle) in [resize, first, last].enumerated() {
            handle.backgroundColor = .systemBlue; handle.tintColor = .white; handle.layer.cornerRadius = 14
            handle.setImage(UIImage(systemName: index == 0 ? "arrow.up.left.and.arrow.down.right" : "circle.fill"), for: .normal)
            handle.accessibilityLabel = index == 0 ? "Auswahl proportional skalieren" : "Formpunkt verschieben"
            let drag = UIPanGestureRecognizer(target: self, action: #selector(handle(_:)))
            drag.maximumNumberOfTouches = 1; handle.tag = index; handle.addGestureRecognizer(drag); addSubview(handle)
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(_ incoming: PageContent, pageID: UUID, layout: PageLayout, generation: Int, tool: EditorTool,
                   enabled: Bool, fingerDrawing: Bool, options: ShapeToolOptions, filter: SelectionFilter, color: InkColor, width: Double,
                   onCommit: @escaping (PageContent, PageContent) -> Bool) {
        let reset = self.pageID != pageID || self.layout != layout || self.generation != generation
        let needsRefresh = reset || incoming.shapes != content.shapes || active || (enabled && (tool == .shape || tool == .selection))
        if reset || incoming != content {
            history.removeAllActions(); historyCost = 0; clearSelection()
            preview = nil; startContent = nil; draft = nil; lasso = []
        }
        if self.tool != tool || !enabled { preview = nil; startContent = nil; draft = nil; lasso = [] }
        self.content = incoming; self.pageID = pageID; self.layout = layout; self.generation = generation
        let touches = (fingerDrawing ? [UITouch.TouchType.pencil, .direct] : [.pencil]).map { NSNumber(value: $0.rawValue) }
        if pan.allowedTouchTypes != touches { pan.allowedTouchTypes = touches }
        self.tool = tool; self.enabled = enabled; self.options = options; self.filter = filter
        self.color = color; self.lineWidth = width; self.onCommit = onCommit
        // Shapes are drawn in every mode; transparent space passes through when inactive.
        isUserInteractionEnabled = active
        isHidden = incoming.shapes.isEmpty && !active
        if needsRefresh { refresh() }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        var view = superview
        while let parent = view {
            if let scroll = parent as? UIScrollView {
                scroll.panGestureRecognizer.require(toFail: pan)
                for handle in [resize, first, last] {
                    for gesture in handle.gestureRecognizers ?? [] { scroll.panGestureRecognizer.require(toFail: gesture) }
                }
                break
            }
            view = parent.superview
        }
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        let visible = preview ?? content
        ShapeRendering.draw(visible.shapes, origin: layout.contentOrigin, context: context)
        if let draft { ShapeRendering.draw([draft], origin: layout.contentOrigin, context: context) }
        // Other layers retain their normal views. Show a translucent outline of
        // the transformed mixed group during its gesture; commit all layers once.
        if active, let rect = selectionBounds(visible) {
            UIColor.systemBlue.setStroke(); let outline = UIBezierPath(rect: display(rect)); outline.lineWidth = 1.5
            outline.setLineDash([5, 4], count: 2, phase: 0); outline.stroke()
        }
        if lasso.count > 1 {
            let path = UIBezierPath(); path.move(to: lasso[0]); lasso.dropFirst().forEach { path.addLine(to: $0) }
            UIColor.systemBlue.setStroke(); path.lineWidth = 1.5; path.stroke()
        }
    }
    private func canonical(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x - layout.contentOrigin.x, y: point.y - layout.contentOrigin.y)
    }
    private func display(_ rect: CGRect) -> CGRect { rect.offsetBy(dx: layout.contentOrigin.x, dy: layout.contentOrigin.y) }
    private func clearSelection() { ink = []; texts = []; images = []; shapes = [] }
    private func button(_ name: String, icon: String, action: @escaping () -> Void) {
        let button = UIButton(type: .system); button.setImage(UIImage(systemName: icon), for: .normal)
        button.accessibilityLabel = name; button.toolTip = name
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
        button.widthAnchor.constraint(equalToConstant: 44).isActive = true; actions.addArrangedSubview(button)
    }
    private func refresh() {
        toolbar.isHidden = !active
        resize.isHidden = !active || !hasSelection
        let editableShape = active && shapes.count == 1 && ink.isEmpty && texts.isEmpty && images.isEmpty
        first.isHidden = !editableShape; last.isHidden = !editableShape
        if active { becomeFirstResponder() } else { resignFirstResponder() }
        setNeedsLayout(); setNeedsDisplay()
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        let group = selectionBounds(preview ?? content).map(display)
        let width = min(292, max(44, bounds.width - 8))
        toolbar.frame = CGRect(x: 4, y: max(4, bounds.height - 50), width: width, height: 44)
        actions.frame = CGRect(x: 4, y: 2, width: 284, height: 40); toolbar.contentSize = CGSize(width: 292, height: 44)
        if let group { resize.frame = handleFrame(CGPoint(x: group.maxX, y: group.maxY)) }
        if let id = shapes.first, let shape = (preview ?? content).shapes.first(where: { $0.id == id }) {
            first.frame = handleFrame(CGPoint(x: shape.start.x + layout.contentOrigin.x, y: shape.start.y + layout.contentOrigin.y))
            last.frame = handleFrame(CGPoint(x: shape.end.x + layout.contentOrigin.x, y: shape.end.y + layout.contentOrigin.y))
        }
    }
    private func handleFrame(_ point: CGPoint) -> CGRect {
        .init(x: min(max(0, point.x - 14), max(0, bounds.width - 28)),
              y: min(max(0, point.y - 14), max(0, bounds.height - 28)), width: 28, height: 28)
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool { active && touch.view === self }
    @objc private func tap(_ gesture: UITapGestureRecognizer) {
        clearSelection()
        let point = canonical(gesture.location(in: self))
        if let shape = content.shapes.reversed().first(where: { ShapeRendering.hit($0, at: point) }) { shapes.insert(shape.id) }
        else if tool == .selection {
            let rect = CGRect(x: point.x - 2, y: point.y - 2, width: 4, height: 4)
            select(path: UIBezierPath(rect: rect), rect: rect, tap: true)
        }
        refresh()
    }
    @objc private func drag(_ gesture: UIPanGestureRecognizer) { self.gesture(gesture, requestedMode: nil) }
    @objc private func handle(_ gesture: UIPanGestureRecognizer) {
        self.gesture(gesture, requestedMode: gesture.view?.tag == 0 ? 2 : (gesture.view?.tag == 1 ? 4 : 5))
    }
    private func gesture(_ gesture: UIPanGestureRecognizer, requestedMode: Int?) {
        guard active else { return }
        let point = canonical(gesture.location(in: self))
        if gesture.state == .began {
            initialPoint = point; startContent = content; preview = nil
            if let requestedMode { dragMode = requestedMode }
            else if selectionBounds(content)?.insetBy(dx: -8, dy: -8).contains(point) == true { dragMode = 1 }
            else if tool == .shape {
                clearSelection(); dragMode = 3
                draft = ShapeObject(kind: options.kind, start: .init(x: point.x, y: point.y), end: .init(x: point.x + 1, y: point.y + 1),
                    color: color, lineWidth: lineWidth, pattern: options.pattern, fill: options.filled ? InkColor(color.red, color.green, color.blue, 0.2) : nil)
            } else { clearSelection(); dragMode = 0; lasso = [gesture.location(in: self)] }
        }
        guard let initial = startContent else { return }
        if gesture.state == .cancelled || gesture.state == .failed {
            preview = nil; draft = nil; startContent = nil; lasso = []; refresh(); return
        }
        switch dragMode {
        case 0: lasso.append(gesture.location(in: self))
        case 1:
            preview = transformed(initial, dx: point.x - initialPoint.x, dy: point.y - initialPoint.y, scale: 1)
        case 2:
            if let frame = selectionBounds(initial) {
                let distance = max(1, hypot(initialPoint.x - frame.minX, initialPoint.y - frame.minY))
                let scale = max(0.1, hypot(point.x - frame.minX, point.y - frame.minY) / distance)
                preview = transformed(initial, dx: 0, dy: 0, scale: scale)
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
        if gesture.state == .ended {
            if dragMode == 0 {
                let points = lasso.map(canonical)
                if points.count > 2 {
                    let path = UIBezierPath(); path.move(to: points[0]); points.dropFirst().forEach { path.addLine(to: $0) }; path.close()
                    select(path: path, rect: path.bounds, tap: false)
                }
            } else if dragMode == 3, let draft, (try? draft.validate()) != nil, limits.contains(draft.bounds, tolerance: 0.02) {
                var value = initial; value.shapes.append(draft)
                if commit(value, previous: initial) { shapes = [draft.id] }
            } else if let preview { _ = commit(preview, previous: initial) }
            preview = nil; draft = nil; startContent = nil; lasso = []
        }
        refresh()
    }
    private var limits: PageRect { PageRect(layout.canonicalInkBounds) }
    private func select(path: UIBezierPath, rect: CGRect, tap: Bool) {
        func selected(_ bounds: CGRect) -> Bool {
            guard rect.intersects(bounds) else { return false }
            return tap || [CGPoint(x: bounds.midX, y: bounds.midY), CGPoint(x: bounds.minX, y: bounds.minY),
                CGPoint(x: bounds.maxX, y: bounds.maxY), CGPoint(x: bounds.minX, y: bounds.maxY), CGPoint(x: bounds.maxX, y: bounds.minY)].contains(where: path.contains)
        }
        if filter.text { texts = Set(content.textBoxes.filter { selected($0.rect.cgRect) }.map(\.id)) }
        if filter.images { images = Set(content.images.filter { !$0.locked && selected($0.rotatedBounds.cgRect) }.map(\.id)) }
        if filter.shapes { shapes = Set(content.shapes.filter { selected($0.bounds.cgRect) }.map(\.id)) }
        if filter.ink, let drawing = try? PKDrawing(data: content.drawing) {
            ink = Set(drawing.strokes.indices.filter { selected(drawing.strokes[$0].renderBounds) })
        }
    }
    private func selectionBounds(_ value: PageContent) -> CGRect? {
        guard hasSelection else { return nil }
        var rects = value.textBoxes.filter { texts.contains($0.id) }.map { $0.rect.cgRect }
        rects += value.images.filter { images.contains($0.id) }.map { $0.rotatedBounds.cgRect }
        rects += value.shapes.filter { shapes.contains($0.id) }.map { $0.bounds.cgRect }
        if !ink.isEmpty, let drawing = try? PKDrawing(data: value.drawing) {
            rects += drawing.strokes.enumerated().filter { ink.contains($0.offset) }.map { $0.element.renderBounds }
        }
        return rects.reduce(nil) { $0?.union($1) ?? $1 }
    }
    private func transformed(_ initial: PageContent, dx: Double, dy: Double, scale: Double) -> PageContent? {
        guard let frame = selectionBounds(initial) else { return nil }
        let transform = CGAffineTransform(a: scale, b: 0, c: 0, d: scale,
                                         tx: frame.minX * (1 - scale) + dx, ty: frame.minY * (1 - scale) + dy)
        var value = initial
        func point(_ p: PagePoint) -> PagePoint { let p = CGPoint(x: p.x, y: p.y).applying(transform); return .init(x: p.x, y: p.y) }
        for i in value.textBoxes.indices where texts.contains(value.textBoxes[i].id) {
            let r = value.textBoxes[i].rect.cgRect.applying(transform)
            value.textBoxes[i].x = r.minX; value.textBoxes[i].y = r.minY
            value.textBoxes[i].width = r.width; value.textBoxes[i].height = r.height
            value.textBoxes[i].style.fontSize *= scale
            guard (try? value.textBoxes[i].validate()) != nil, limits.contains(value.textBoxes[i].rect) else { return nil }
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
        if var drawing = try? PKDrawing(data: initial.drawing) {
            drawing.strokes = drawing.strokes.enumerated().map { index, stroke in
                guard ink.contains(index) else { return stroke }
                return PKDrawing(strokes: [stroke]).transformed(using: transform).strokes[0]
            }
            for index in ink where drawing.strokes.indices.contains(index) {
                guard limits.cgRect.insetBy(dx: -0.02, dy: -0.02).contains(drawing.strokes[index].renderBounds) else { return nil }
            }
            value.drawing = drawing.dataRepresentation()
        }
        return value
    }
    private func commit(_ value: PageContent, previous: PageContent) -> Bool {
        guard value != previous, onCommit?(value, previous) == true else { return false }
        content = value
        record(previous); return true
    }
    private func record(_ previous: PageContent) {
        let cost = previous.drawing.count + previous.images.reduce(0) { $0 + $1.data.count }
        if !history.isUndoing && !history.isRedoing && historyCost + cost > 40_000_000 { history.removeAllActions(); historyCost = 0 }
        historyCost += cost
        history.registerUndo(withTarget: self) { owner in _ = owner.commit(previous, previous: owner.content); owner.clearSelection(); owner.refresh() }
        history.setActionName("Objekte bearbeiten")
    }
    func performUndo(redo: Bool) { guard active else { return }; if redo { history.redo() } else { history.undo() } }
    private func copySelection() {
        guard let frame = selectionBounds(content) else { return }
        var value = content
        value.textBoxes.removeAll { !texts.contains($0.id) }; value.images.removeAll { !images.contains($0.id) }
        value.shapes.removeAll { !shapes.contains($0.id) }
        let drawing = (try? PKDrawing(data: content.drawing)) ?? PKDrawing()
        value.drawing = PKDrawing(strokes: drawing.strokes.enumerated().filter { ink.contains($0.offset) }.map(\.element)).dataRepresentation()
        ObjectClipboard.content = value; ObjectClipboard.bounds = frame
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
        var value = content
        value.textBoxes.removeAll { texts.contains($0.id) }; value.images.removeAll { images.contains($0.id) }
        value.shapes.removeAll { shapes.contains($0.id) }
        let drawing = (try? PKDrawing(data: content.drawing)) ?? PKDrawing()
        value.drawing = PKDrawing(strokes: drawing.strokes.enumerated().filter { !ink.contains($0.offset) }.map(\.element)).dataRepresentation()
        _ = commit(value, previous: content); clearSelection(); refresh()
    }
    private func applyStyle() {
        var value = content
        for i in value.shapes.indices where shapes.contains(value.shapes[i].id) {
            value.shapes[i].color = color; value.shapes[i].pattern = options.pattern; value.shapes[i].lineWidth = lineWidth
            value.shapes[i].fill = options.filled ? InkColor(color.red, color.green, color.blue, 0.2) : nil
        }
        _ = commit(value, previous: content); refresh()
    }
    override var keyCommands: [UIKeyCommand]? {
        [UIKeyCommand(input: "c", modifierFlags: .command, action: #selector(copyKey)),
         UIKeyCommand(input: "v", modifierFlags: .command, action: #selector(pasteKey)),
         UIKeyCommand(input: "\u{8}", modifierFlags: [], action: #selector(deleteKey)),
         UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(escapeKey))]
    }
    @objc private func copyKey() { copySelection() }
    @objc private func pasteKey() { pasteSelection() }
    @objc private func deleteKey() { deleteSelection() }
    @objc private func escapeKey() { clearSelection(); refresh() }
}
