import UIKit
import SwiftUI
import NotebookCore

/// One page-local image plane below ink/text. Gestures and controls are excluded
/// from every export; undo is notebook-wide (EditorModel). All object
/// coordinates stay in canonical points.
@MainActor
final class ImageObjectLayer: UIView, UIGestureRecognizerDelegate {
    private var objects: [ImageObject] = []
    private var pageID: UUID?
    private var contentGeneration = -1
    private var generation = 0
    private var pageLayout = PageLayout(source: .testPaper, legacyA4: true)
    private var active = false
    private var selectedID: UUID?
    private var onChange: (([ImageObject]) -> Void)?
    private var onError: ((String) -> Void)?
    private let outline = CAShapeLayer()
    private let resize = UIButton(type: .system)
    private let rotate = UIButton(type: .system)
    private let toolbar = UIScrollView()
    private let actions = UIStackView()
    private var buttons: [String: UIButton] = [:]
    private var dragStart: (objects: [ImageObject], object: ImageObject, point: CGPoint, generation: Int)?
    private var rotationSnap: Double?
    private let rotationFeedback = UISelectionFeedbackGenerator()
    private weak var cropController: UIViewController?
    private lazy var moveGesture = UIPanGestureRecognizer(target: self, action: #selector(moveImage(_:)))

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear; isOpaque = false; contentMode = .redraw; clipsToBounds = true
        outline.fillColor = UIColor.clear.cgColor; outline.strokeColor = UIColor.systemBlue.cgColor
        outline.lineWidth = 1.5; layer.addSublayer(outline)
        moveGesture.delegate = self; moveGesture.maximumNumberOfTouches = 1
        addGestureRecognizer(moveGesture)
        let tap = UITapGestureRecognizer(target: self, action: #selector(selectImage(_:)))
        tap.delegate = self; addGestureRecognizer(tap)
        for (handle, symbol, title, selector) in [
            (resize, "arrow.up.left.and.arrow.down.right", "Bild proportional skalieren", #selector(resizeImage(_:))),
            (rotate, "arrow.clockwise", "Bild frei drehen", #selector(rotateImage(_:)))
        ] {
            handle.setImage(UIImage(systemName: symbol), for: .normal)
            handle.backgroundColor = .systemBlue; handle.tintColor = .white; handle.layer.cornerRadius = 22
            handle.accessibilityLabel = title
            let gesture = UIPanGestureRecognizer(target: self, action: selector); gesture.maximumNumberOfTouches = 1
            handle.addGestureRecognizer(gesture); addSubview(handle)
        }
        actions.axis = .horizontal; actions.spacing = 4
        toolbar.backgroundColor = UIColor.secondarySystemBackground.withAlphaComponent(0.96)
        toolbar.layer.cornerRadius = 10; toolbar.showsHorizontalScrollIndicator = true
        toolbar.addSubview(actions); addSubview(toolbar)
        action("crop", title: "Zuschneiden", symbol: "crop") { [weak self] in self?.openCrop() }
        action("turn", title: "Auf nächsten 90°-Winkel drehen", symbol: "rotate.right") { [weak self] in
            self?.edit { object in object.rotation = ImageObject.nextRightAngle(after: object.rotation) }
        }
        action("back", title: "Bild nach hinten", symbol: "square.3.layers.3d.bottom.filled") { [weak self] in self?.reorder(front: false) }
        action("front", title: "Bild nach vorne", symbol: "square.3.layers.3d.top.filled") { [weak self] in self?.reorder(front: true) }
        action("lock", title: "Bild sperren oder entsperren", symbol: "lock.open") { [weak self] in self?.edit(allowLocked: true) { $0.locked.toggle() } }
        action("delete", title: "Bild löschen", symbol: "trash") { [weak self] in self?.deleteSelected() }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(objects incoming: [ImageObject], pageID: UUID, layout: PageLayout, contentGeneration: Int,
                   active: Bool, onChange: @escaping ([ImageObject]) -> Void, onError: @escaping (String) -> Void) {
        let reset = self.pageID != pageID || self.contentGeneration != contentGeneration || pageLayout != layout
        if !reset, objects == incoming, self.active == active {
            self.onChange = onChange; self.onError = onError; return
        }
        if reset {
            generation += 1; dragStart = nil; rotationSnap = nil; selectedID = nil
            cropController?.dismiss(animated: false); cropController = nil
        } else if objects != incoming {
            let added = incoming.last { object in !objects.contains { $0.id == object.id } }
            selectedID = added?.id ?? selectedID
        }
        self.pageID = pageID; self.contentGeneration = contentGeneration; pageLayout = layout
        self.active = active; self.onChange = onChange; self.onError = onError; objects = incoming
        isUserInteractionEnabled = active
        if !active { dragStart = nil; rotationSnap = nil; cropController?.dismiss(animated: false); cropController = nil }
        if !objects.contains(where: { $0.id == selectedID }) { selectedID = nil }
        refresh()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        var parent = superview
        while let current = parent {
            if let scroll = current as? UIScrollView {
                scroll.panGestureRecognizer.require(toFail: moveGesture)
                for handle in [resize, rotate] {
                    for gesture in handle.gestureRecognizers ?? [] { scroll.panGestureRecognizer.require(toFail: gesture) }
                }
                break
            }
            parent = current.superview
        }
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        let zoom = 1 / controlScale
        let screenScale = window?.screen.scale ?? 2
        for object in objects {
            guard displayBounds(object).intersects(rect) else { continue }
            autoreleasepool {
                // Load/import validation rejects unreadable originals. A render
                // failure is reported, never silently accepted by PDF export.
                // Quantize resolutions so dragging/zooming does not fill the
                // bounded cache with almost-identical thumbnails.
                let pixels = max(object.width / object.crop.width, object.height / object.crop.height) * zoom * screenScale
                let limit = pixels <= 512 ? 512 : (pixels <= 1024 ? 1024 : 2048)
                do { try ImageRendering.draw(object, context: context, origin: pageLayout.contentOrigin, limit: limit) }
                catch { onError?(error.localizedDescription) }
            }
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        HangProbe.hit("Image.layoutSubviews")
        guard active, let object = selected else { return }
        let rect = displayBounds(object)
        let path = UIBezierPath(rect: CGRect(x: -object.width / 2, y: -object.height / 2, width: object.width, height: object.height))
        path.apply(CGAffineTransform(rotationAngle: object.rotation * .pi / 180))
        path.apply(CGAffineTransform(translationX: object.x + object.width / 2 + pageLayout.contentOrigin.x,
                                   y: object.y + object.height / 2 + pageLayout.contentOrigin.y))
        outline.path = path.cgPath
        let scale = controlScale
        outline.lineWidth = 1.5 * scale
        placeHandle(resize, at: CGPoint(x: rect.maxX, y: rect.maxY), scale: scale)
        placeHandle(rotate, at: CGPoint(x: rect.maxX, y: rect.minY), scale: scale)
        rotate.backgroundColor = rotationSnap == nil ? .systemBlue : .systemTeal
        let width = min(max(44, bounds.width / scale - 8), 316)
        let outerWidth = width * scale, outerHeight = 52 * scale
        let y = rect.maxY + 12 * scale + outerHeight <= bounds.maxY ? rect.maxY + 12 * scale : max(bounds.minY, rect.minY - 12 * scale - outerHeight)
        toolbar.bounds.size = CGSize(width: width, height: 52)
        toolbar.transform = CGAffineTransform(scaleX: scale, y: scale)
        toolbar.center = CGPoint(x: min(max(bounds.minX + outerWidth / 2, rect.midX), max(bounds.minX + outerWidth / 2, bounds.maxX - outerWidth / 2)),
                                 y: y + outerHeight / 2)
        actions.frame = CGRect(x: 4, y: 4, width: 308, height: 44)
        toolbar.contentSize = CGSize(width: 316, height: 52)
    }

    private var controlScale: CGFloat {
        guard let window else { return 1 }
        let start = convert(CGPoint.zero, to: window), end = convert(CGPoint(x: 100, y: 0), to: window)
        return 1 / max(0.01, hypot(end.x - start.x, end.y - start.y) / 100)
    }
    private func placeHandle(_ handle: UIButton, at center: CGPoint, scale: CGFloat) {
        let half = 22 * scale
        handle.bounds = CGRect(x: 0, y: 0, width: 44, height: 44)
        handle.transform = CGAffineTransform(scaleX: scale, y: scale)
        handle.center = CGPoint(x: min(max(bounds.minX + half, center.x), max(bounds.minX + half, bounds.maxX - half)),
                                y: min(max(bounds.minY + half, center.y), max(bounds.minY + half, bounds.maxY - half)))
    }
    private var selected: ImageObject? { objects.first { $0.id == selectedID } }
    private var limits: PageRect { PageRect(pageLayout.canonicalInkBounds) }
    private func displayBounds(_ object: ImageObject) -> CGRect {
        object.rotatedBounds.cgRect.offsetBy(dx: pageLayout.contentOrigin.x, dy: pageLayout.contentOrigin.y)
    }
    private func refresh() {
        isHidden = objects.isEmpty
        let visible = active && selected != nil
        outline.isHidden = !visible; toolbar.isHidden = !visible
        resize.isHidden = !visible || selected?.locked == true; rotate.isHidden = resize.isHidden
        for (key, button) in buttons { button.isEnabled = key == "lock" || selected?.locked == false }
        buttons["lock"]?.setImage(UIImage(systemName: selected?.locked == true ? "lock.fill" : "lock.open"), for: .normal)
        buttons["lock"]?.accessibilityLabel = selected?.locked == true ? "Bild entsperren" : "Bild sperren"
        setNeedsDisplay(); setNeedsLayout()
    }

    private func action(_ key: String, title: String, symbol: String, run: @escaping () -> Void) {
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: symbol), for: .normal)
        button.accessibilityLabel = title; button.toolTip = title
        button.addAction(UIAction { _ in run() }, for: .touchUpInside)
        actions.addArrangedSubview(button); buttons[key] = button
        button.widthAnchor.constraint(equalToConstant: 48).isActive = true
    }

    private func hitObject(_ point: CGPoint) -> ImageObject? {
        objects.reversed().first { object in
            let center = CGPoint(x: object.x + object.width / 2 + pageLayout.contentOrigin.x,
                                 y: object.y + object.height / 2 + pageLayout.contentOrigin.y)
            let local = CGPoint(x: point.x - center.x, y: point.y - center.y)
                .applying(CGAffineTransform(rotationAngle: -object.rotation * .pi / 180))
            return abs(local.x) <= object.width / 2 && abs(local.y) <= object.height / 2
        }
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        touch.view === self && active
    }
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === moveGesture else { return active }
        return active && hitObject(gestureRecognizer.location(in: self))?.locked == false
    }
    @objc private func selectImage(_ tap: UITapGestureRecognizer) {
        selectedID = hitObject(tap.location(in: self))?.id; refresh()
    }

    @objc private func moveImage(_ pan: UIPanGestureRecognizer) { drag(pan, kind: 0) }
    @objc private func resizeImage(_ pan: UIPanGestureRecognizer) { drag(pan, kind: 1) }
    @objc private func rotateImage(_ pan: UIPanGestureRecognizer) { drag(pan, kind: 2) }
    private func drag(_ pan: UIPanGestureRecognizer, kind: Int) {
        guard active else { return }
        let point = pan.location(in: self)
        if pan.state == .began {
            rotationSnap = nil
            if kind == 2 { rotationFeedback.prepare() }
            if kind == 0 { selectedID = hitObject(point)?.id }
            guard let object = selected, !object.locked else { return }
            dragStart = (objects, object, point, generation)
        }
        guard let start = dragStart, start.generation == generation,
              let index = objects.firstIndex(where: { $0.id == start.object.id }) else { return }
        if pan.state == .cancelled || pan.state == .failed {
            objects = start.objects; dragStart = nil; rotationSnap = nil; refresh(); onChange?(objects); return
        }
        var object = start.object
        let delta = pan.translation(in: self)
        if kind == 0 { object.x += delta.x; object.y += delta.y }
        else if kind == 1 {
            let distance = max(1, hypot(start.point.x - displayBounds(object).midX, start.point.y - displayBounds(object).midY))
            let scale = max(1 / min(object.width, object.height), hypot(point.x - displayBounds(object).midX, point.y - displayBounds(object).midY) / distance)
            object.width *= scale; object.height *= scale
            object.x += (start.object.width - object.width) / 2; object.y += (start.object.height - object.height) / 2
        } else {
            let center = displayBounds(object)
            let initial = atan2(start.point.y - center.midY, start.point.x - center.midX)
            let current = atan2(point.y - center.midY, point.x - center.midX)
            let raw = Self.angle(object.rotation + (current - initial) * 180 / .pi)
            let target = ImageObject.rotationSnap(raw, previous: rotationSnap)
            if target != rotationSnap, target != nil { rotationFeedback.selectionChanged(); rotationFeedback.prepare() }
            rotationSnap = target
            object.rotation = target ?? raw
        }
        objects[index] = object.fitted(in: limits)
        if pan.state == .ended { dragStart = nil; rotationSnap = nil }
        refresh(); onChange?(objects)
    }

    private static func angle(_ degrees: Double) -> Double {
        var value = degrees.truncatingRemainder(dividingBy: 360)
        if value > 180 { value -= 360 }; if value < -180 { value += 360 }
        return value
    }
    private func edit(allowLocked: Bool = false, _ change: (inout ImageObject) -> Void) {
        guard active, let index = objects.firstIndex(where: { $0.id == selectedID }), allowLocked || !objects[index].locked else { return }
        change(&objects[index]); objects[index] = objects[index].fitted(in: limits)
        refresh(); onChange?(objects)
    }
    private func reorder(front: Bool) {
        guard active, let index = objects.firstIndex(where: { $0.id == selectedID }), !objects[index].locked else { return }
        let object = objects.remove(at: index)
        objects.insert(object, at: front ? objects.count : 0)
        refresh(); onChange?(objects)
    }
    private func deleteSelected() {
        guard active, selected?.locked == false else { return }
        objects.removeAll { $0.id == selectedID }; selectedID = nil
        refresh(); onChange?(objects)
    }

    private func openCrop() {
        guard active, let object = selected, !object.locked else { return }
        do {
            let image = try ImageRendering.image(object)
            let expectedGeneration = generation
            let controller = UIHostingController(rootView: ImageCropView(image: image, crop: object.crop) { [weak self] crop in
                guard let self, self.active, self.generation == expectedGeneration,
                      self.selectedID == object.id else { return }
                do {
                    let cropped = try object.cropped(to: crop, in: self.limits)
                    self.edit { $0 = cropped }
                } catch { self.onError?(error.localizedDescription) }
            })
            controller.modalPresentationStyle = .formSheet
            var responder: UIResponder? = self
            while let current = responder, !(current is UIViewController) { responder = current.next }
            guard let parent = responder as? UIViewController, parent.presentedViewController == nil else { return }
            cropController = controller; parent.present(controller, animated: true)
        } catch { onError?(error.localizedDescription) }
    }
}
