import UIKit
import SwiftUI
import NotebookCore

private extension UIColor {
    /// noty accent (#7DD3FC), same as `Color.notyAccent`.
    static let notyAccent = UIColor(red: 125 / 255, green: 211 / 255, blue: 252 / 255, alpha: 1)
    /// Dark glyph colour of the tool-icon design (#0B1220).
    static let notyShade = UIColor(red: 11 / 255, green: 18 / 255, blue: 32 / 255, alpha: 1)
}

/// Image handle: a compact accent disc with a white ring and soft shadow,
/// readable on light paper and on PDFs, inside an unchanged 44-pt target.
@MainActor
private final class ImageHandle: UIView {
    private let disc = UIView()
    private let symbol = UIImageView()
    /// Rotation snapped to a right angle: inverted disc as feedback.
    var snapped = false { didSet { if snapped != oldValue { updateColors() } } }
    init(symbol name: String, title: String) {
        super.init(frame: CGRect(x: 0, y: 0, width: 44, height: 44))
        backgroundColor = .clear
        disc.isUserInteractionEnabled = false
        disc.layer.cornerRadius = 13; disc.layer.borderWidth = 2
        disc.layer.shadowColor = UIColor.black.cgColor; disc.layer.shadowOpacity = 0.28
        disc.layer.shadowRadius = 2.5; disc.layer.shadowOffset = CGSize(width: 0, height: 1)
        disc.layer.shadowPath = UIBezierPath(ovalIn: CGRect(x: 0, y: 0, width: 26, height: 26)).cgPath
        symbol.image = UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .bold))
        symbol.contentMode = .center; symbol.isUserInteractionEnabled = false
        addSubview(disc); disc.addSubview(symbol)
        isAccessibilityElement = true; accessibilityTraits = .button; accessibilityLabel = title
        updateColors()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layoutSubviews() {
        super.layoutSubviews()
        disc.frame = CGRect(x: 9, y: 9, width: 26, height: 26); symbol.frame = disc.bounds
    }
    private func updateColors() {
        disc.backgroundColor = snapped ? .white : .notyAccent
        disc.layer.borderColor = (snapped ? UIColor.notyAccent : .white).cgColor
        symbol.tintColor = .notyShade
    }
}

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
    /// Soft dark halo under the accent outline, so it reads on white paper.
    private let outlineHalo = CAShapeLayer()
    private let resize = ImageHandle(symbol: "arrow.up.left.and.arrow.down.right", title: "Bild proportional skalieren")
    private let rotate = ImageHandle(symbol: "arrow.clockwise", title: "Bild frei drehen")
    private let toolbar = UIScrollView()
    private let actions = UIStackView()
    private var buttons: [String: UIButton] = [:]
    /// Actions shown as switched on (accent symbol instead of a backing).
    private var activeActions = Set<String>()
    /// Full width of the action bar (content of the scrollable bar).
    private var barWidth: CGFloat = 316
    private typealias DragStart = (objects: [ImageObject], object: ImageObject, point: CGPoint, generation: Int)
    private var dragStart: DragStart?
    private var rotationSnap: Double?
    private let rotationFeedback = UISelectionFeedbackGenerator()
    private weak var cropController: UIViewController?
    private lazy var moveGesture = SnapPanGestureRecognizer(target: self, action: #selector(moveImage(_:)))
    /// Weiches Einrasten while moving an image.
    let snapping = DragSnapping()
    private let liveLayer = CALayer()
    private var liveID: UUID?
    /// Failed decodes per image (retry pause), and originals validation rejected.
    private var failures: [UUID: (count: Int, retryAt: CFTimeInterval)] = [:]
    private var broken = Set<UUID>()
    /// Image dragged off its sheet onto another page of the continuous
    /// notebook; the viewport shows it floating (`SelectionTransferHost`).
    private var lift: SelectionLift?
    private var liftedID: UUID? { lift?.objects.images.first?.id }
    /// Complete committed content of this page (expected state of a transfer).
    var pageContent: (() -> PageContent?)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear; isOpaque = false; contentMode = .redraw; clipsToBounds = true
        liveLayer.contentsGravity = .resize; liveLayer.isHidden = true; layer.addSublayer(liveLayer)
        for (line, color) in [(outlineHalo, UIColor.notyShade.withAlphaComponent(0.28)), (outline, .notyAccent)] {
            line.fillColor = UIColor.clear.cgColor; line.strokeColor = color.cgColor
            line.lineJoin = .round; layer.addSublayer(line)
        }
        moveGesture.delegate = self; moveGesture.maximumNumberOfTouches = 1
        addGestureRecognizer(moveGesture)
        let tap = UITapGestureRecognizer(target: self, action: #selector(selectImage(_:)))
        tap.delegate = self; addGestureRecognizer(tap)
        for (handle, selector) in [(resize, #selector(resizeImage(_:))), (rotate, #selector(rotateImage(_:)))] {
            let gesture = UIPanGestureRecognizer(target: self, action: selector); gesture.maximumNumberOfTouches = 1
            gesture.delegate = ScrollPanPriority.shared
            handle.addGestureRecognizer(gesture); addSubview(handle)
        }
        // Dark noty bar like the lasso action bar and the text format bar:
        // explicitly dark (the worksheet forces light), hairline contour,
        // white symbols in 44-pt targets, subtle group dividers, delete in red,
        // a switched-on action in the accent (no backing box).
        actions.axis = .horizontal; actions.spacing = 4; actions.alignment = .center
        actions.accessibilityContainerType = .semanticGroup; actions.accessibilityLabel = "Bildaktionen"
        toolbar.overrideUserInterfaceStyle = .dark
        toolbar.backgroundColor = UIColor(white: 0.13, alpha: 0.98)
        toolbar.layer.cornerRadius = 26; toolbar.layer.cornerCurve = .continuous
        toolbar.layer.borderWidth = 0.5; toolbar.layer.borderColor = UIColor.white.withAlphaComponent(0.18).cgColor
        toolbar.showsHorizontalScrollIndicator = true; toolbar.indicatorStyle = .white
        toolbar.addSubview(actions); addSubview(toolbar)
        action("crop", title: "Zuschneiden", symbol: "crop") { [weak self] in self?.openCrop() }
        action("turn", title: "Um 90° drehen", symbol: "rotate.right") { [weak self] in
            self?.edit { object in object.rotation = ImageObject.nextRightAngle(after: object.rotation) }
        }
        divider()
        action("back", title: "Bild nach hinten", symbol: "square.3.layers.3d.bottom.filled") { [weak self] in self?.reorder(front: false) }
        action("front", title: "Bild nach vorne", symbol: "square.3.layers.3d.top.filled") { [weak self] in self?.reorder(front: true) }
        divider()
        action("lock", title: "Bild sperren", symbol: "lock.open") { [weak self] in self?.edit(allowLocked: true) { $0.locked.toggle() } }
        divider()
        action("delete", title: "Bild löschen", symbol: "trash", color: .systemRed) { [weak self] in self?.deleteSelected() }
        let items = actions.arrangedSubviews
        barWidth = items.reduce(8) { $0 + ($1 is UIButton ? 44 : 1) } + CGFloat(items.count - 1) * actions.spacing
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(objects incoming: [ImageObject], pageID: UUID, layout: PageLayout, contentGeneration: Int,
                   active: Bool, onChange: @escaping ([ImageObject]) -> Void, onError: @escaping (String) -> Void) {
        let reset = self.pageID != pageID || self.contentGeneration != contentGeneration || pageLayout != layout
        // A drag shows its live frame locally and commits once when it ends;
        // the unchanged model state meanwhile is no conflicting update.
        var incoming = incoming
        if !reset, active, self.active, let start = dragStart, start.generation == generation, start.objects == incoming { incoming = objects }
        if !reset, objects == incoming, self.active == active {
            self.onChange = onChange; self.onError = onError; return
        }
        if reset {
            generation += 1; dragStart = nil; rotationSnap = nil; selectedID = nil
            cropController?.dismiss(animated: false); cropController = nil
        } else if objects != incoming {
            // Another change (undo, other pane) replaces a drag in progress.
            dragStart = nil; rotationSnap = nil
            let added = incoming.last { object in !objects.contains { $0.id == object.id } }
            selectedID = added?.id ?? selectedID
            if active, let added { insertedID = added.id }
        }
        self.pageID = pageID; self.contentGeneration = contentGeneration; pageLayout = layout
        self.active = active; self.onChange = onChange; self.onError = onError; objects = incoming
        isUserInteractionEnabled = active
        if !active { dragStart = nil; rotationSnap = nil; cropController?.dismiss(animated: false); cropController = nil }
        if !objects.contains(where: { $0.id == selectedID }) { selectedID = nil }
        if dragStart == nil { endLive(); endLift() }
        if reset { failures.removeAll(); broken.removeAll() }
        refresh()
    }

    /// An image added while the image tool is active (import, paste, undo of
    /// a deletion), taken once by the viewport to scroll it into view.
    private var insertedID: UUID?
    func takeInsertedImage() -> CGRect? {
        defer { insertedID = nil }
        return insertedID.flatMap { id in objects.first { $0.id == id } }.map(displayBounds)
    }
    /// The plane shows exactly these objects (no local drag pending).
    func shows(_ incoming: [ImageObject]) -> Bool { objects == incoming }
    func adoptCallbacks(onChange: @escaping ([ImageObject]) -> Void, onError: @escaping (String) -> Void) {
        self.onChange = onChange; self.onError = onError
    }
    /// A cross-page transfer was committed atomically by the notebook (one
    /// undo step for both pages) before SwiftUI publishes it. `id`: the moved
    /// image on the target page, selected so it can be dragged on at once.
    func adoptTransfer(_ incoming: [ImageObject], selecting id: UUID?) {
        endLift(); dragStart = nil; rotationSnap = nil; endLive()
        objects = incoming
        if let id { selectedID = id }
        if !objects.contains(where: { $0.id == selectedID }) { selectedID = nil }
        refresh()
    }

    /// Image drags win over notebook scrolling (handles: `ScrollPanPriority`).
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
        gestureRecognizer === moveGesture && ScrollPanPriority.outranksScrolling(gestureRecognizer, other)
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        let zoom = 1 / controlScale
        let screenScale = window?.screen.scale ?? 2
        for object in objects where object.id != liveID && object.id != liftedID {
            guard displayBounds(object).intersects(rect) else { continue }
            // Decoding a camera original takes long: never while drawing. Until
            // the rendition is ready, a cached one of another size or a neutral
            // placeholder stands in, then only its frame is redrawn.
            let limit = Self.rendition(object, zoom: zoom, screenScale: screenScale)
            let image = ImageRendering.cached(object, limit: limit)
            if image == nil { request(object, limit: limit) }
            autoreleasepool {
                ImageRendering.draw(image ?? ImageRendering.anyCached(object, near: limit), for: object,
                                    context: context, origin: pageLayout.contentOrigin)
            }
        }
    }
    /// Quantized resolutions, so dragging/zooming does not fill the bounded
    /// cache with almost-identical renditions.
    private static func rendition(_ object: ImageObject, zoom: CGFloat, screenScale: CGFloat) -> Int {
        let pixels = max(object.width / object.crop.width, object.height / object.crop.height) * zoom * screenScale
        return pixels <= 512 ? 512 : (pixels <= 1024 ? 1024 : 2048)
    }
    /// Load/import validation rejects unreadable originals. A failed decode is
    /// often transient (memory pressure): it is retried after a pause, and only
    /// an original that validation rejects too is reported and given up.
    private func request(_ object: ImageObject, limit: Int) {
        guard !broken.contains(object.id) else { return }
        if let failure = failures[object.id], CACurrentMediaTime() < failure.retryAt { return }
        let id = object.id, expected = generation
        ImageRendering.prepare(object, limit: limit) { [weak self] error in
            guard let self, self.generation == expected, let current = self.objects.first(where: { $0.id == id }) else { return }
            guard error != nil else { self.failures[id] = nil; self.setNeedsDisplay(self.displayBounds(current)); return }
            let count = (self.failures[id]?.count ?? 0) + 1
            let pause: TimeInterval = count == 1 ? 2 : 10
            self.failures[id] = (count, CACurrentMediaTime() + pause)
            if count == 1 { self.redraw(id, after: pause); return }
            Task.detached(priority: .utility) { [weak self] in
                let rejected: Error?
                do { try ImageRendering.validate(current); rejected = nil } catch { rejected = error }
                await self?.validated(id, generation: expected, rejected: rejected, retry: count < 5 ? pause : nil)
            }
        }
    }
    private func validated(_ id: UUID, generation expected: Int, rejected: Error?, retry: TimeInterval?) {
        guard generation == expected, objects.contains(where: { $0.id == id }) else { return }
        if let rejected { broken.insert(id); onError?(rejected.localizedDescription) }
        else if let retry { redraw(id, after: retry) }
    }
    private func redraw(_ id: UUID, after delay: TimeInterval) {
        let expected = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + delay + 0.05) { [weak self] in
            guard let self, self.generation == expected, let object = self.objects.first(where: { $0.id == id }) else { return }
            self.setNeedsDisplay(self.displayBounds(object))
        }
    }
    /// The image being dragged is shown by `liveLayer` and moved per frame by
    /// its transform; the plane itself is redrawn only when the drag starts and
    /// ends. `liveLayer` lies above the whole plane, so while the image overlaps
    /// one in front of it the plane draws it in order instead (true: redraw).
    private func showLive(_ object: ImageObject) -> Bool {
        let frame = displayBounds(object)
        if let index = objects.firstIndex(where: { $0.id == object.id }),
           objects[(index + 1)...].contains(where: { displayBounds($0).intersects(frame) }) {
            if liveID != nil { endLive() }
            return true
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if liveID != object.id {
            liveID = object.id
            let limit = Self.rendition(object, zoom: 1 / controlScale, screenScale: window?.screen.scale ?? 2)
            let image = ImageRendering.cached(object, limit: limit) ?? ImageRendering.anyCached(object, near: limit)
            liveLayer.contents = image?.cgImage
            liveLayer.backgroundColor = image == nil ? UIColor(white: 0.86, alpha: 0.6).cgColor : nil
            liveLayer.contentsRect = object.crop.cgRect
            liveLayer.isHidden = false
            setNeedsDisplay()
        }
        liveLayer.setAffineTransform(.identity)
        liveLayer.bounds = CGRect(x: 0, y: 0, width: object.width, height: object.height)
        liveLayer.position = CGPoint(x: object.x + object.width / 2 + pageLayout.contentOrigin.x,
                                     y: object.y + object.height / 2 + pageLayout.contentOrigin.y)
        liveLayer.setAffineTransform(CGAffineTransform(rotationAngle: object.rotation * .pi / 180))
        CATransaction.commit()
        return false
    }
    private func endLive() {
        guard liveID != nil else { return }
        liveID = nil
        CATransaction.begin(); CATransaction.setDisableActions(true)
        liveLayer.isHidden = true; liveLayer.contents = nil
        CATransaction.commit()
        setNeedsDisplay()
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
        let scale = controlScale
        CATransaction.begin(); CATransaction.setDisableActions(true)
        outline.path = path.cgPath; outlineHalo.path = outline.path
        outline.lineWidth = 2 * scale; outlineHalo.lineWidth = 4 * scale
        CATransaction.commit()
        placeHandle(resize, at: CGPoint(x: rect.maxX, y: rect.maxY), scale: scale)
        placeHandle(rotate, at: CGPoint(x: rect.maxX, y: rect.minY), scale: scale)
        rotate.snapped = rotationSnap != nil
        let width = min(max(44, bounds.width / scale - 8), barWidth)
        let outerWidth = width * scale, outerHeight = 52 * scale
        let y = rect.maxY + 12 * scale + outerHeight <= bounds.maxY ? rect.maxY + 12 * scale : max(bounds.minY, rect.minY - 12 * scale - outerHeight)
        toolbar.bounds.size = CGSize(width: width, height: 52)
        toolbar.transform = CGAffineTransform(scaleX: scale, y: scale)
        toolbar.center = CGPoint(x: min(max(bounds.minX + outerWidth / 2, rect.midX), max(bounds.minX + outerWidth / 2, bounds.maxX - outerWidth / 2)),
                                 y: y + outerHeight / 2)
        actions.frame = CGRect(x: 4, y: 4, width: barWidth - 8, height: 44)
        toolbar.contentSize = CGSize(width: barWidth, height: 52)
    }

    private var controlScale: CGFloat {
        guard let window else { return 1 }
        let start = convert(CGPoint.zero, to: window), end = convert(CGPoint(x: 100, y: 0), to: window)
        return 1 / max(0.01, hypot(end.x - start.x, end.y - start.y) / 100)
    }
    private func placeHandle(_ handle: UIView, at center: CGPoint, scale: CGFloat) {
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
    /// `redraw`: false while `liveLayer` shows a drag (controls only).
    private func refresh(redraw: Bool = true) {
        isHidden = objects.isEmpty
        let visible = active && selected != nil && lift == nil
        outline.isHidden = !visible; outlineHalo.isHidden = !visible; toolbar.isHidden = !visible
        resize.isHidden = !visible || selected?.locked == true; rotate.isHidden = resize.isHidden
        for (key, button) in buttons { button.isEnabled = key == "lock" || selected?.locked == false }
        if let lock = buttons["lock"] {
            let locked = selected?.locked == true
            lock.configuration?.image = UIImage(systemName: locked ? "lock.fill" : "lock.open")
            if locked { activeActions.insert("lock") } else { activeActions.remove("lock") }
            lock.setNeedsUpdateConfiguration()
            lock.accessibilityLabel = locked ? "Bild entsperren" : "Bild sperren"; lock.toolTip = lock.accessibilityLabel
            lock.accessibilityValue = locked ? "Gesperrt" : nil
        }
        if redraw { setNeedsDisplay() }
        setNeedsLayout()
    }

    private func action(_ key: String, title: String, symbol: String, color: UIColor = .white, run: @escaping () -> Void) {
        let button = UIButton(type: .system)
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: symbol)
        config.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 18, weight: .regular)
        config.baseForegroundColor = color
        button.configuration = config
        // Disabled (locked image): clearly dimmed on the dark bar. Switched on
        // (locked): the symbol takes the accent like a selected tool.
        button.configurationUpdateHandler = { [weak self] button in
            let on = self?.activeActions.contains(key) == true
            button.configuration?.baseForegroundColor = !button.isEnabled ? UIColor.white.withAlphaComponent(0.28) : on ? .notyAccent : color
        }
        button.accessibilityLabel = title; button.toolTip = title
        button.addAction(UIAction { _ in run() }, for: .touchUpInside)
        actions.addArrangedSubview(button); buttons[key] = button
        button.widthAnchor.constraint(equalToConstant: 44).isActive = true
        button.heightAnchor.constraint(equalToConstant: 44).isActive = true
    }
    private func divider() {
        let line = UIView(); line.backgroundColor = UIColor.white.withAlphaComponent(0.14)
        line.isUserInteractionEnabled = false; line.isAccessibilityElement = false
        line.widthAnchor.constraint(equalToConstant: 1).isActive = true
        line.heightAnchor.constraint(equalToConstant: 26).isActive = true
        actions.addArrangedSubview(line)
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
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { endLift() }
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
            if kind == 0 { snapping.begin(excluding: [object.id], in: self) }
        }
        guard let start = dragStart, start.generation == generation,
              let index = objects.firstIndex(where: { $0.id == start.object.id }) else { snapping.end(); return }
        if pan.state == .cancelled || pan.state == .failed {
            snapping.end()
            objects = start.objects; dragStart = nil; rotationSnap = nil; endLive(); endLift(); refresh(); onChange?(objects); return
        }
        var object = start.object
        let delta = pan.translation(in: self)
        if kind == 0, updateLift(pan, start: start) {
            snapping.hide()
            if pan.state == .ended { snapping.end(); drop(pan, start: start, index: index) }
            return
        }
        if kind == 0 {
            // The one move path (`ObjectMovement`) with weiches Einrasten.
            let frame = start.object.rotatedBounds
            let shift = ObjectMovement.translation(moving: frame, by: PagePoint(x: delta.x, y: delta.y), within: limits,
                                                   snapping: snapping.track(pan, in: self))
            snapping.show(translation: shift, frame: frame, gesture: pan, in: self)
            object.x += shift.x; object.y += shift.y
        }
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
        // Live feedback stays local; the model gets one change (one undo step)
        // when the gesture ends instead of an autosave round trip per frame.
        let ended = pan.state == .ended
        var redraw = ended
        if ended { dragStart = nil; rotationSnap = nil; snapping.end(); endLive() } else { redraw = showLive(objects[index]) }
        refresh(redraw: redraw)
        if ended { onChange?(objects) }
    }

    /// Over another page the dragged image lifts off its sheet and follows
    /// the touch above all pages (like a lasso selection); back over its own
    /// sheet it returns to the clamped in-page move. True while lifted.
    private func updateLift(_ pan: UIPanGestureRecognizer, start: DragStart) -> Bool {
        guard let host = transferHost, let pageID else { return false }
        if CGRect(origin: .zero, size: pageLayout.canvas.cgSize).contains(pan.location(in: self)) {
            if lift != nil { endLift(); refresh() }
            return false
        }
        if lift == nil {
            // Only over another page: beside the pages the image stays clamped as before.
            guard let target = host.transferTarget(for: pan), target != pageID,
                  let made = makeLift(start, touch: pan) else { return false }
            lift = made; endLive()
            objects = start.objects
            refresh()
        }
        guard let lift else { return false }
        host.floatSelection(lift, gesture: pan)
        return true
    }
    private func makeLift(_ start: DragStart,
                          touch pan: UIPanGestureRecognizer) -> SelectionLift? {
        // The expected state must be exactly the committed page; otherwise
        // the model would reject the transfer as a conflict anyway.
        guard let pageID, let content = pageContent?(), content.images == start.objects, !start.object.locked else { return nil }
        let object = start.object
        var remainder = content; remainder.images.removeAll { $0.id == object.id }
        // Touch-down point (the pan began after a short movement).
        let location = pan.location(in: self), translation = pan.translation(in: self)
        let grab = CGPoint(x: location.x - translation.x - pageLayout.contentOrigin.x,
                           y: location.y - translation.y - pageLayout.contentOrigin.y)
        let zoom = 1 / controlScale, screenScale = window?.screen.scale ?? 2
        let limit = Self.rendition(object, zoom: zoom, screenScale: screenScale)
        let rendition = ImageRendering.cached(object, limit: limit) ?? ImageRendering.anyCached(object, near: limit)
        let snapshot = SelectionTransfer.snapshot(image: object, rendition: rendition, pixelScale: zoom * screenScale)
        return SelectionLift(pageID: pageID, content: content, remainder: remainder, ink: [],
            objects: MovedObjects(images: [object]), frame: object.rotatedBounds.cgRect, start: grab, snapshot: snapshot)
    }
    /// Released while lifted: over another page an atomic transfer (or, if it
    /// is refused, the image stays where it was with a message); in a gap or
    /// beside the pages the clamped in-page move is committed as before.
    private func drop(_ pan: UIPanGestureRecognizer, start: DragStart, index: Int) {
        guard let lifted = lift else { return }
        let host = transferHost
        lift = nil; dragStart = nil; rotationSnap = nil
        host?.hideFloatingSelection()
        if let host, let target = host.transferTarget(for: pan), target != lifted.pageID {
            // Success: the sheet already installed the new state (`adoptTransfer`).
            if !host.dropSelection(lifted, gesture: pan), generation == start.generation { objects = start.objects }
        } else if generation == start.generation, objects.indices.contains(index) {
            var object = start.object
            let delta = pan.translation(in: self)
            object.x += delta.x; object.y += delta.y
            objects[index] = object.fitted(in: limits)
            if objects != start.objects { onChange?(objects) }
        }
        setNeedsDisplay(); refresh()
    }
    private func endLift() {
        guard lift != nil else { return }
        lift = nil; transferHost?.hideFloatingSelection()
        setNeedsDisplay()
    }
    private var transferHost: SelectionTransferHost? {
        var view = superview
        while let current = view {
            if let host = current as? SelectionTransferHost { return host }
            view = current.superview
        }
        return nil
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
