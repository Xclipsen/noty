import UIKit
import SwiftUI
import PencilKit
import NotebookCore

struct SelectionFilter: Equatable {
    var ink = true, text = true, images = true, shapes = true
    /// Stored form (`AppSettingsKey.lassoFilter`): ink 1, text 2, images 4, shapes 8.
    var bits: Int { (ink ? 1 : 0) | (text ? 2 : 0) | (images ? 4 : 0) | (shapes ? 8 : 0) }
    init() {}
    init(bits: Int) {
        ink = bits & 1 != 0; text = bits & 2 != 0; images = bits & 4 != 0; shapes = bits & 8 != 0
    }
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

/// App-internal copy of objects (⌘C, „Kopieren“). Pasting takes whatever was
/// copied last: these objects while the system pasteboard is unchanged
/// since the copy (`isNewest`), otherwise its text or image.
@MainActor
enum ObjectClipboard {
    static var content: PageContent?
    static var bounds: CGRect?
    /// `UIPasteboard.general.changeCount` right after the copy.
    static var changeCount: Int?
    static var isNewest: Bool { content != nil && changeCount == UIPasteboard.general.changeCount }
}

/// The one look of every selection (Build 64): system blue, one line width
/// for single objects, dashed only for groups and lasso selections, the
/// same screen-constant gap and corner radius around everything.
enum SelectionStyle {
    static let color = UIColor.systemBlue
    /// Frame of one field, image or shape (screen points, solid).
    static let lineWidth: CGFloat = 1
    /// Contour of groups and lasso selections (screen points, dashed, light fill).
    static let groupLineWidth: CGFloat = 1.5
    static let groupDash: [CGFloat] = [5, 5]
    static let groupFill = UIColor.systemBlue.withAlphaComponent(0.06)
    /// Handle dot (screen points) inside its 44-pt target.
    static let handleDiameter: CGFloat = 12
}

/// The one handle of every selection: blue dot with a white ring and a
/// light shadow (visible on white and dark paper and on PDFs), 12 pt, in a
/// 44 × 44-pt target. Image corners, field corners (selected and while
/// editing), lasso corners, shape anchors and every rotation handle.
@MainActor
final class SelectionHandle: UIView {
    private let dot = UIView()
    override init(frame: CGRect) {
        super.init(frame: frame); backgroundColor = .clear
        let diameter = SelectionStyle.handleDiameter
        dot.backgroundColor = SelectionStyle.color; dot.isUserInteractionEnabled = false
        dot.layer.cornerRadius = diameter / 2; addSubview(dot)
        dot.layer.borderColor = UIColor.white.cgColor; dot.layer.borderWidth = 1.5
        dot.layer.shadowColor = UIColor.black.cgColor; dot.layer.shadowOpacity = 0.3
        dot.layer.shadowRadius = 1.5; dot.layer.shadowOffset = CGSize(width: 0, height: 0.5)
        isAccessibilityElement = true
    }
    convenience init() { self.init(frame: CGRect(x: 0, y: 0, width: 44, height: 44)) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layoutSubviews() {
        super.layoutSubviews()
        let diameter = SelectionStyle.handleDiameter
        dot.frame = CGRect(x: bounds.midX - diameter / 2, y: bounds.midY - diameter / 2, width: diameter, height: diameter)
    }
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
    private var dragMode = 0 // 0 lasso, 1 move, 2 scale, 3 new shape, 6 rotate, 7 shape anchor, 9/10 field width
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
    /// One action bar for every kind of selection (`SelectionActionBar`).
    private let bar = SelectionActionBar()
    /// Name and description of a hovered bar button.
    private let hoverBubble = UILabel()
    private weak var cropController: UIViewController?
    private let corners = (0..<4).map { _ in SelectionHandle() }
    /// One handle per anchor of a single selected shape (`ShapeObject.anchors`):
    /// line ends, polyline/polygon corners, rectangle corners, ellipse sides.
    private var anchorHandles: [SelectionHandle] = []
    private let rotation = SelectionHandle()
    private var activeCorner = 2
    private var activeAnchor = 0
    /// The current pan began with a finger (not the Pencil).
    private var fingerPan = false
    private var cachedDrawing: (Data, PKDrawing)?
    private var cachedOutline: (SelectionContour.Key, CGPath?)?
    private let contourLayer = CAShapeLayer()
    private var contourAnimationScale: CGFloat?
    private weak var styleController: UIViewController?
    private lazy var pan = TouchDownPanGestureRecognizer(target: self, action: #selector(drag(_:)))
    /// A shape begun on touch-down that has not moved yet: lifting it is a tap.
    private var shapeTapCandidate = false
    /// Apple Pencil Pro haptics (iOS 17.5+); older Pencils simply get none.
    private var feedback: UIFeedbackGenerator?
    /// Frequent light ticks while drawing a lasso or dragging a selection.
    private var motionTicks = MotionTicks()
    private var rotationSnap: Double?
    /// The rotation in progress: pivot (canonical), angle of the frame when it
    /// began (a single field or image: its own angle, otherwise 0), frame size
    /// with the gap, and the turn applied so far (degrees).
    private struct RotationDrag { var pivot: CGPoint; var base: Double; var size: CGSize; var turn = 0.0 }
    private var rotationDrag: RotationDrag?
    /// Light tick on devices without Pencil Pro haptics (rotation snapping).
    private let rotationImpact = UIImpactFeedbackGenerator(style: .light)
    /// Weiches Einrasten for moves, field width points and shape anchors.
    let snapping = DragSnapping()
    private var hasSelection: Bool { !ink.isEmpty || !texts.isEmpty || !images.isEmpty || !shapes.isEmpty }
    // MARK: Textneubau – a single text field selected by a tap
    /// The selection is one text field picked by a tap (finger with any ink
    /// tool, or the lasso tool's tap): thin frame, a width point left and
    /// right, rotation handle above the middle, its own action bar. Lasso
    /// selections keep the corner scaling (font size scales along).
    private var fieldMode = false
    private var isFieldSelection: Bool { fieldMode && texts.count == 1 && ink.isEmpty && images.isEmpty && shapes.isEmpty }
    /// Every selectable object at a point (layer coordinates), topmost first:
    /// the sheet's finger hit test (`PageObjectHitTest`, screen tolerance).
    var objectHits: ((CGPoint) -> [PageObjectReference])?
    /// A checkbox glyph at a point (layer coordinates): its own tap toggles it.
    var hitsCheckbox: ((CGPoint) -> Bool)?
    /// The configured page (paper, margins, PDF): lifted text is drawn with
    /// its automatic colours and ruled layout like in the editor.
    var pageContext: (() -> Page?)?
    /// Laid-out text lines of a field (own unrotated page units): what a lasso must touch.
    var textLines: ((TextBox) -> [PageRect])?
    /// The field with its height (and automatic width) from the content.
    var fittedText: ((TextBox) -> TextBox)?
    /// Errors of image actions (crop).
    var onError: ((String) -> Void)?
    /// „Bearbeiten“ or a second tap on the selected field: caret at the point (nil: end).
    var onEditText: ((UUID, PagePoint?) -> Void)?
    /// Four corner points of a selected field (top-left, top-right,
    /// bottom-right, bottom-left): they change only the width, left corners
    /// the left edge, right corners the right edge (Feedback zu Build 62).
    private let fieldWidthHandles = (0..<4).map { _ in SelectionHandle() }
    private let angleLabel = UILabel()
    private var active: Bool { enabled && (toolActive || touchSelection) }
    /// The tool works on this plane itself (shapes, lasso, images).
    private var toolActive: Bool { Self.planeTool(tool) }
    private static func planeTool(_ tool: EditorTool) -> Bool { [.shape, .selection, .inkSelection, .image].contains(tool) }
    /// Finger and Pencil taps select through this plane's own tap.
    var handlesTapsItself: Bool { enabled && toolActive }
    /// Object selected by a finger tap while an ink tool stays active
    /// (`selectByTouch`). Lives exactly as long as that selection.
    private var touchSelection = false
    /// The finger selection ended (the sheet gives the canvas its focus back).
    var onTouchSelectionEnded: (() -> Void)?
    /// A drag or tap began on this layer (selections on other pages end).
    var onInteractionBegan: (() -> Void)?
    override var canBecomeFirstResponder: Bool { active }
    override var inputView: UIView? { UIView(frame: .zero) }
    override var undoManager: UndoManager? { notebookUndo }

    override init(frame: CGRect) {
        super.init(frame: frame); backgroundColor = .clear; isOpaque = false; clipsToBounds = true
        overrideUserInterfaceStyle = .dark
        contourLayer.fillColor = SelectionStyle.groupFill.cgColor
        contourLayer.strokeColor = SelectionStyle.color.cgColor
        contourLayer.lineCap = .round; contourLayer.lineJoin = .round
        layer.addSublayer(contourLayer)
        pan.delegate = self; pan.maximumNumberOfTouches = 1; addGestureRecognizer(pan)
        pan.beginsImmediately = { [weak self] touch in self?.drawsShapeOnTouchDown(touch) ?? false }
        let tap = UITapGestureRecognizer(target: self, action: #selector(tap(_:))); tap.delegate = self
        tap.require(toFail: pan); addGestureRecognizer(tap)
        addSubview(bar)
        bar.onAction = { [weak self] action in self?.perform(action) }
        bar.onHover = { [weak self] button, text in self?.showHover(button, text: text) }
        bar.setMenu(UIMenu(children: [
            UIAction(title: "Einfügen", image: UIImage(systemName: "doc.on.clipboard")) { [weak self] _ in self?.pasteKey() },
            UIAction(title: "Auswahl aufheben", image: UIImage(systemName: "xmark")) { [weak self] _ in self?.adopted = nil; self?.clearSelection(); self?.refresh() }
        ]), for: .more)
        bar.setMenu(UIMenu(children: [
            UIAction(title: "Waagerecht spiegeln", image: UIImage(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right")) { [weak self] _ in self?.mirrorInk(horizontal: true) },
            UIAction(title: "Senkrecht spiegeln", image: UIImage(systemName: "arrow.up.and.down.righttriangle.up.righttriangle.down")) { [weak self] _ in self?.mirrorInk(horizontal: false) }
        ]), for: .mirror)
        hoverBubble.font = .systemFont(ofSize: 13, weight: .medium); hoverBubble.textColor = .white
        hoverBubble.backgroundColor = UIColor(white: 0.08, alpha: 0.94); hoverBubble.textAlignment = .center
        hoverBubble.numberOfLines = 2; hoverBubble.layer.cornerRadius = 8; hoverBubble.clipsToBounds = true
        hoverBubble.isUserInteractionEnabled = false; hoverBubble.isHidden = true; hoverBubble.isAccessibilityElement = false
        addSubview(hoverBubble)
        for (index, handle) in (corners + [rotation]).enumerated() {
            handle.accessibilityLabel = index < 4 ? "Auswahl proportional skalieren" : "Auswahl drehen"
            let drag = SnapPanGestureRecognizer(target: self, action: #selector(handle(_:)))
            drag.maximumNumberOfTouches = 1; drag.delegate = ScrollPanPriority.shared
            handle.tag = index < 4 ? index : 6; handle.addGestureRecognizer(drag); addSubview(handle)
        }
        // Field selection: corner points (tags 9 left edge, 10 right edge);
        // it turns with the one rotation handle like every selection.
        for (handle, tag, label) in [(fieldWidthHandles[0], 9, "Textfeldbreite oben links ändern"), (fieldWidthHandles[1], 10, "Textfeldbreite oben rechts ändern"),
                                     (fieldWidthHandles[2], 10, "Textfeldbreite unten rechts ändern"), (fieldWidthHandles[3], 9, "Textfeldbreite unten links ändern")] {
            handle.accessibilityLabel = label; handle.tag = tag; handle.isHidden = true
            let drag = SnapPanGestureRecognizer(target: self, action: #selector(self.handle(_:)))
            drag.maximumNumberOfTouches = 1; drag.delegate = ScrollPanPriority.shared
            handle.addGestureRecognizer(drag); addSubview(handle)
        }
        angleLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold); angleLabel.textColor = .white
        angleLabel.backgroundColor = UIColor(white: 0.13, alpha: 0.92); angleLabel.textAlignment = .center
        angleLabel.layer.cornerRadius = 8; angleLabel.clipsToBounds = true; angleLabel.isHidden = true
        angleLabel.isUserInteractionEnabled = false; addSubview(angleLabel)
    }

    // MARK: Action bar (one for every selection)

    private func perform(_ action: SelectionAction) {
        guard active else { return }
        hideHover()
        switch action {
        case .edit: if let id = texts.first { onEditText?(id, nil) }
        case .style: openStyle()
        case .cut: copySelection(); deleteSelection()
        case .copy: copySelection()
        case .duplicate: duplicateSelection()
        case .front: reorderSelection(toFront: true)
        case .back: reorderSelection(toFront: false)
        case .crop: openCrop()
        case .turn: editImage { $0.rotation = ImageObject.nextRightAngle(after: $0.rotation) }
        case .lock: editImage(allowLocked: true) { $0.locked.toggle() }
        case .fieldStyle: openFieldStyle()
        case .delete: deleteSelection()
        case .paste: pasteKey()
        case .more, .mirror: break // menus
        }
    }
    /// A selected image is locked (only the image tool selects those): it
    /// can only be unlocked, never moved, changed, duplicated or deleted.
    private var selectionLocked: Bool {
        !images.isEmpty && content.images.contains { images.contains($0.id) && $0.locked }
    }
    /// The one selected image (nothing else selected).
    private var selectedImage: ImageObject? {
        guard images.count == 1, ink.isEmpty, texts.isEmpty, shapes.isEmpty, let id = images.first else { return nil }
        return content.images.first { $0.id == id }
    }
    /// Fixed order for every kind of selection: Bearbeiten/Stil · Ausschneiden,
    /// Kopieren, Duplizieren · Nach vorne, Nach hinten · what only this kind
    /// has (Feldstil; Zuschneiden, 90°, Sperren; Spiegeln) · Weitere · Löschen.
    /// „Stil“ only where it changes something (not for images alone); a
    /// locked image offers only „Entsperren“.
    private func updateBar() {
        guard hasSelection else {
            bar.show(toolActive && ObjectClipboard.content != nil ? [[.paste]] : [])
            return
        }
        let onlyImages = !images.isEmpty && ink.isEmpty && texts.isEmpty && shapes.isEmpty
        let onlyInk = !ink.isEmpty && texts.isEmpty && images.isEmpty && shapes.isEmpty
        let lead: [SelectionAction] = isFieldSelection ? [.edit] : onlyImages ? [] : [.style]
        var specific: [SelectionAction] = []
        if isFieldSelection { specific = [.fieldStyle] }
        else if selectedImage != nil { specific = [.crop, .turn, .lock] }
        else if onlyInk { specific = [.mirror] }
        let locked = selectedImage?.locked == true
        bar.show([lead, [.cut, .copy, .duplicate], [.front, .back], specific, [.more, .delete]],
                 disabled: locked ? Set(SelectionAction.allCases).subtracting([.lock, .more]) : [],
                 on: locked ? [.lock] : [], titles: [.lock: locked ? "Entsperren" : "Sperren"],
                 symbols: [.lock: locked ? "lock.fill" : "lock.open"])
    }
    private func showHover(_ button: UIButton?, text: String?) {
        guard let button, let text, active, !bar.isHidden else { hideHover(); return }
        let scale = displayScale
        hoverBubble.text = text
        let size = hoverBubble.sizeThatFits(CGSize(width: 260, height: 80))
        hoverBubble.transform = .identity
        hoverBubble.bounds = CGRect(x: 0, y: 0, width: min(280, size.width + 20), height: size.height + 12)
        let anchor = button.convert(CGPoint(x: button.bounds.midX, y: button.bounds.midY), to: self)
        let half = (SelectionActionBar.height / 2 + 8 + hoverBubble.bounds.height / 2) / scale
        let above = CGPoint(x: anchor.x, y: anchor.y - half), below = CGPoint(x: anchor.x, y: anchor.y + half)
        hoverBubble.center = above.y - hoverBubble.bounds.height / 2 / scale >= bounds.minY ? above : below
        hoverBubble.transform = CGAffineTransform(scaleX: 1 / scale, y: 1 / scale)
        hoverBubble.isHidden = false; bringSubviewToFront(hoverBubble)
    }
    private func hideHover() { hoverBubble.isHidden = true }
    /// „Nach vorne“/„Nach hinten“ for any selection: the selected members of
    /// each kind move to the top/bottom of their kind's drawing order
    /// (fields among fields, strokes among strokes …); kinds keep their
    /// layer order (text over ink over shapes over images).
    private func reorderSelection(toFront: Bool) {
        guard hasSelection, !selectionLocked else { return }
        func order<T: Identifiable>(_ items: [T], _ selected: Set<T.ID>) -> [T] {
            let picked = items.filter { selected.contains($0.id) }, rest = items.filter { !selected.contains($0.id) }
            return toFront ? rest + picked : picked + rest
        }
        var value = content
        value.textBoxes = order(content.textBoxes, texts)
        value.images = order(content.images, images)
        value.shapes = order(content.shapes, shapes)
        var movedInk = ink
        if !ink.isEmpty, let drawing = drawing(content.drawing) {
            let picked = drawing.strokes.indices.filter { ink.contains($0) }, rest = drawing.strokes.indices.filter { !ink.contains($0) }
            let indices = toFront ? rest + picked : picked + rest
            value.drawing = PKDrawing(strokes: indices.map { drawing.strokes[$0] }).dataRepresentation()
            movedInk = Set(toFront ? (rest.count..<indices.count) : (0..<picked.count))
        }
        guard value != content else { return }
        if commit(value, previous: content) { ink = movedInk }
        refresh()
    }
    /// One change of the single selected image (fitted onto the page).
    private func editImage(allowLocked: Bool = false, _ change: (inout ImageObject) -> Void) {
        guard active, let image = selectedImage, allowLocked || !image.locked,
              let index = content.images.firstIndex(where: { $0.id == image.id }) else { return }
        var value = content
        change(&value.images[index]); value.images[index] = value.images[index].fitted(in: limits)
        guard value != content, (try? value.images[index].validate()) != nil else { return }
        _ = commit(value, previous: content); refresh()
    }
    /// „Zuschneiden“ of the selected image (`ImageCropView`).
    private func openCrop() {
        guard let object = selectedImage, !object.locked else { return }
        var responder: UIResponder? = self
        while let current = responder, !(current is UIViewController) { responder = current.next }
        guard let parent = responder as? UIViewController, parent.presentedViewController == nil else { return }
        do {
            let image = try ImageRendering.image(object)
            let page = pageID, expected = generation
            let controller = UIHostingController(rootView: ImageCropView(image: image, crop: object.crop) { [weak self] crop in
                guard let self, self.active, self.pageID == page, self.generation == expected, self.selectedImage?.id == object.id else { return }
                do {
                    let cropped = try object.cropped(to: crop, in: self.limits)
                    self.editImage { $0 = cropped }
                } catch { self.onError?(error.localizedDescription) }
            })
            controller.modalPresentationStyle = .formSheet
            cropController = controller; parent.present(controller, animated: true)
        } catch { onError?(error.localizedDescription) }
    }
    /// The selected field with its height from the content („Höhe immer aus
    /// dem Inhalt“): page text migrated to a field still has the height of its
    /// former writing area until it is changed; frame, handles and every drag
    /// use (and commit) the fitted frame.
    private func selectedField(_ value: PageContent) -> TextBox? {
        guard isFieldSelection, let id = texts.first, let box = value.textBoxes.first(where: { $0.id == id }) else { return nil }
        return fitted(box)
    }
    private func fitted(_ box: TextBox) -> TextBox { fittedText?(box) ?? box }
    private func replacing(_ value: PageContent, with box: TextBox) -> PageContent {
        var result = value
        if let index = result.textBoxes.firstIndex(where: { $0.id == box.id }) { result.textBoxes[index] = box }
        return result
    }
    /// Display point of a canonical page point.
    private func display(_ point: PagePoint) -> CGPoint { CGPoint(x: point.x + layout.contentOrigin.x, y: point.y + layout.contentOrigin.y) }
    // MARK: Rotation (one handle, one snapping for fields, images, shapes, ink and groups)

    /// The frame the rotation handle belongs to (canonical centre, angle in
    /// degrees, size with the selection gap): a single field or image in its
    /// own orientation, everything else the selection's bounds (turning with
    /// the group while it is rotated).
    private func rotationFrame(_ value: PageContent) -> (center: CGPoint, angle: Double, size: CGSize)? {
        let gap = contourGap
        if let box = selectedField(value) {
            let rect = box.fieldStyleRect, middle = box.center
            return (CGPoint(x: middle.x, y: middle.y), box.angle, CGSize(width: rect.width + 2 * gap, height: rect.height + 2 * gap))
        }
        if images.count == 1, ink.isEmpty, texts.isEmpty, shapes.isEmpty, let id = images.first,
           let image = value.images.first(where: { $0.id == id }) {
            return (CGPoint(x: image.x + image.width / 2, y: image.y + image.height / 2), image.rotation,
                    CGSize(width: image.width + 2 * gap, height: image.height + 2 * gap))
        }
        if dragMode == 6, startContent != nil, let drag = rotationDrag { return (drag.pivot, drag.turn, drag.size) }
        guard let frame = selectionBounds(value, applyingPreview: true) else { return nil }
        return (CGPoint(x: frame.midX, y: frame.midY), 0, CGSize(width: frame.width + 2 * gap, height: frame.height + 2 * gap))
    }
    /// Rotation handle: on a short line above the middle of the selection
    /// frame (turned with it); below it when there is no room above.
    private func rotationHandle(_ value: PageContent) -> (base: CGPoint, center: CGPoint)? {
        guard let frame = rotationFrame(value) else { return nil }
        let scale = displayScale, radians = frame.angle * .pi / 180, reach = 30 / scale
        let up = CGPoint(x: sin(radians), y: -cos(radians)), half = frame.size.height / 2
        let middle = CGPoint(x: frame.center.x + layout.contentOrigin.x, y: frame.center.y + layout.contentOrigin.y)
        let top = CGPoint(x: middle.x + up.x * half, y: middle.y + up.y * half)
        let above = CGPoint(x: top.x + up.x * reach, y: top.y + up.y * reach)
        let room = bounds.insetBy(dx: 22 / scale, dy: 22 / scale)
        if room.contains(above) { return (top, above) }
        let bottom = CGPoint(x: middle.x - up.x * half, y: middle.y - up.y * half)
        let below = CGPoint(x: bottom.x - up.x * reach, y: bottom.y - up.y * reach)
        return room.contains(below) ? (bottom, below) : (top, above)
    }
    /// Every member can turn: fields, images (unlocked), handwriting and
    /// shapes made of points (lines, arrows, polylines, polygons). Rectangles
    /// and ellipses have no rotation in the format and would have to become
    /// polygons, so a selection with one of them does not turn.
    private var canRotate: Bool {
        guard hasSelection, !selectionLocked else { return false }
        return content.shapes.allSatisfy { !shapes.contains($0.id) || ($0.kind != .rectangle && $0.kind != .ellipse) }
    }
    /// The selection turned by `degrees` about `pivot` (canonical). nil when
    /// a member would leave the page; a single field or image is moved back
    /// onto it instead. Handwriting follows through `inkTransform`.
    private func rotated(_ initial: PageContent, by degrees: Double, around pivot: CGPoint) -> PageContent? {
        let transform = CGAffineTransform(translationX: pivot.x, y: pivot.y).rotated(by: degrees * .pi / 180)
            .translatedBy(x: -pivot.x, y: -pivot.y)
        func turn(_ point: PagePoint) -> PagePoint { let p = CGPoint(x: point.x, y: point.y).applying(transform); return .init(x: p.x, y: p.y) }
        let single = ink.isEmpty && texts.count + images.count + shapes.count == 1
        var value = initial
        for i in value.textBoxes.indices where texts.contains(value.textBoxes[i].id) {
            let box = isFieldSelection ? fitted(value.textBoxes[i]) : value.textBoxes[i]
            var turned = box.rotated(to: box.angle + degrees)
            let target = turn(box.center), now = turned.center
            turned.x += target.x - now.x; turned.y += target.y - now.y
            if !turned.fits(in: limits) { guard single, let shifted = turned.shifted(into: limits) else { return nil }; turned = shifted }
            guard (try? turned.validate()) != nil else { return nil }
            value.textBoxes[i] = turned
        }
        for i in value.images.indices where images.contains(value.images[i].id) {
            var image = value.images[i]
            let center = turn(PagePoint(x: image.x + image.width / 2, y: image.y + image.height / 2))
            var angle = (image.rotation + degrees).truncatingRemainder(dividingBy: 360)
            if angle > 180 { angle -= 360 }; if angle < -180 { angle += 360 }
            image.rotation = abs(angle) < 0.01 ? 0 : angle
            image.x = center.x - image.width / 2; image.y = center.y - image.height / 2
            if !image.fits(in: limits) { guard single else { return nil }; image = image.fitted(in: limits) }
            guard (try? image.validate()) != nil else { return nil }
            value.images[i] = image
        }
        for i in value.shapes.indices where shapes.contains(value.shapes[i].id) {
            let shape = value.shapes[i].mapped(turn)
            guard (try? shape.validate()) != nil, limits.contains(shape.bounds, tolerance: 0.02) else { return nil }
            value.shapes[i] = shape
        }
        inkTransform = ink.isEmpty ? nil : transform
        // Objects only: the contour follows the preview itself.
        groupTransform = ink.isEmpty ? nil : transform
        return value
    }
    /// A rotation clicked into a snap angle: Pencil Pro haptics where
    /// available, otherwise a light tick.
    private func rotationTick(at point: CGPoint) {
        haptic(completed: false, at: point)
        rotationImpact.impactOccurred(intensity: 0.6); rotationImpact.prepare()
    }

    /// A tap on the text of the selected field: with another field's line at
    /// the same place the next one below is selected, otherwise the caret is
    /// set there. Returns false when the tap is not on the selected field.
    /// `textHits`: fields whose text is at the point, topmost first.
    func tapOnSelectedField(textHits: [UUID], at point: PagePoint) -> Bool {
        guard isFieldSelection, lift == nil, startContent == nil, let current = texts.first, textHits.contains(current) else { return false }
        if let next = PageObjectHitTest.next(after: .text(current), in: textHits.map { .text($0) }), case .text(let id) = next {
            adopted = nil; clearSelection(); texts = [id]; fieldMode = true; refresh()
        } else {
            onEditText?(current, point)
        }
        return true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(_ incoming: PageContent, pageID: UUID, layout: PageLayout, generation: Int, tool: EditorTool,
                   enabled: Bool, fingerDrawing: Bool, options: ShapeToolOptions, filter: SelectionFilter, lassoMode: LassoMode, color: InkColor, width: Double,
                   onCommit: @escaping (PageContent, PageContent) -> Bool) {
        let samePage = self.pageID == pageID
        let reset = !samePage || self.layout != layout || self.generation != generation
        let needsRefresh = reset || incoming.shapes != content.shapes || active || (enabled && Self.planeTool(tool))
        // Image tool: an image added from outside (import, paste) is selected at once.
        let added = !reset && enabled && tool == .image && self.tool == .image
            ? incoming.images.last(where: { image in !content.images.contains { $0.id == image.id } }) : nil
        if reset || incoming != content {
            clearSelection(); endLift()
            preview = nil; inkTransform = nil; startContent = nil; draft = nil; lasso = []
        }
        if let added { images = [added.id] }
        if let adopted {
            if samePage, adopted.content == incoming {
                if !hasSelection { select(adopted.selection, in: incoming) }
            } else { self.adopted = nil }
        }
        if self.tool != tool || !enabled { endLift(); preview = nil; inkTransform = nil; startContent = nil; draft = nil; lasso = [] }
        if touchSelection, self.tool != tool || !enabled { clearSelection(); endTouchSelectionMode() }
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
        // The rotation handle's short line above the middle of the frame.
        if active, lift == nil, !rotation.isHidden, let handle = rotationHandle(visible) {
            let line = UIBezierPath(); line.move(to: handle.base); line.addLine(to: handle.center)
            SelectionStyle.color.setStroke(); line.lineWidth = 1.5 / displayScale; line.stroke()
        }
        if lasso.count > 1 {
            let path = UIBezierPath(); path.move(to: lasso[0]); lasso.dropFirst().forEach { path.addLine(to: $0) }
            let scale = displayScale
            UIColor.systemBlue.setStroke(); path.lineWidth = 1.5 / scale
            path.lineCapStyle = .round; path.lineJoinStyle = .round
            path.setLineDash([6 / scale, 4 / scale], count: 2, phase: 0); path.stroke()
        }
        // Visible from touch-down: a new shape too small to show yet marks its
        // start point in its colour and width (at least 5 screen points wide).
        if dragMode == 3, startContent != nil, let draft, (try? draft.validate()) == nil {
            let radius = max(draft.lineWidth / 2, 2.5 / displayScale)
            let center = CGPoint(x: draft.start.x + layout.contentOrigin.x, y: draft.start.y + layout.contentOrigin.y)
            draft.color.uiColor.withAlphaComponent(1).setFill()
            UIBezierPath(ovalIn: CGRect(x: center.x - radius, y: center.y - radius, width: 2 * radius, height: 2 * radius)).fill()
        }
    }
    private func canonical(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x - layout.contentOrigin.x, y: point.y - layout.contentOrigin.y)
    }
    private func display(_ rect: CGRect) -> CGRect { rect.offsetBy(dx: layout.contentOrigin.x, dy: layout.contentOrigin.y) }
    private func clearSelection() {
        ink = []; texts = []; images = []; shapes = []; fieldMode = false
        styleController?.dismiss(animated: false); cropController?.dismiss(animated: false); hideHover()
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
        if touchSelection, !hasSelection, startContent == nil {
            endTouchSelectionMode(); isUserInteractionEnabled = active; isHidden = !active
        }
        let lifted = lift != nil
        updateBar()
        bar.isHidden = !active || lifted || bar.isEmpty
        if bar.isHidden { hideHover() }
        for corner in corners { corner.isHidden = !active || lifted || !hasSelection || isFieldSelection || selectionLocked }
        let field = active && !lifted && isFieldSelection
        fieldWidthHandles.forEach { $0.isHidden = !field }
        if dragMode != 6 || startContent == nil { angleLabel.isHidden = true }
        rotation.isHidden = !active || lifted || !canRotate
        // A single shape is edited by its own anchors, not the scale corners.
        let editableShape = active && !lifted && shapes.count == 1 && ink.isEmpty && texts.isEmpty && images.isEmpty
        if editableShape { for corner in corners { corner.isHidden = true } }
        updateAnchorHandles(count: editableShape ? (selectedShape(preview ?? content)?.anchors.count ?? 0) : 0)
        if active && (hasSelection || startContent != nil) { becomeFirstResponder() }
        else if !active { resignFirstResponder() }
        setNeedsLayout(); setNeedsDisplay()
        publishPreview()
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        HangProbe.hit("Object.layoutSubviews")
        let controls: [UIView] = [bar] + corners + anchorHandles + [rotation] + fieldWidthHandles + [angleLabel]
        for control in controls { control.transform = .identity }
        // Controls frame the contour, which keeps a small gap around the content.
        let group = selectionBounds(preview ?? content, applyingPreview: true).map { display($0).insetBy(dx: -contourGap, dy: -contourGap) }
        let scale = displayScale
        let intersection = window.map { convert($0.bounds, from: $0).intersection(bounds) } ?? bounds
        let visible = intersection.isNull || intersection.isEmpty ? bounds : intersection
        if let box = selectedField(preview ?? content) {
            for (handle, corner) in zip(fieldWidthHandles, box.frameCorners(outset: contourGap)) { handle.frame = handleFrame(display(corner)) }
        }
        if let group {
            let points = [CGPoint(x: group.minX, y: group.minY), CGPoint(x: group.maxX, y: group.minY),
                          CGPoint(x: group.maxX, y: group.maxY), CGPoint(x: group.minX, y: group.maxY)]
            for (handle, point) in zip(corners, points) { handle.frame = handleFrame(point) }
        }
        if let handle = rotationHandle(preview ?? content)?.center {
            rotation.frame = handleFrame(handle)
            angleLabel.bounds = CGRect(x: 0, y: 0, width: 48, height: 22)
            angleLabel.center = CGPoint(x: handle.x + 40 / scale, y: handle.y - 4 / scale)
        }
        if let shape = selectedShape(preview ?? content) {
            for (handle, anchor) in zip(anchorHandles, shape.anchors) {
                handle.frame = handleFrame(CGPoint(x: anchor.x + layout.contentOrigin.x, y: anchor.y + layout.contentOrigin.y))
            }
        }
        placeBar(around: group, visible: visible, scale: scale)
        for control in controls {
            let center = control.center
            control.transform = CGAffineTransform(scaleX: 1 / scale, y: 1 / scale)
            control.center = center
        }
        updateContour()
    }
    /// The bar sits above the selection and its handles; below them only
    /// when there is no room above; inside the visible part in any case.
    private func placeBar(around group: CGRect?, visible: CGRect, scale: CGFloat) {
        let width = min(bar.contentWidth, max(44, visible.width * scale - 8))
        bar.bounds = CGRect(x: 0, y: 0, width: width, height: SelectionActionBar.height)
        let half = SelectionActionBar.height / 2 / scale, margin = 10 / scale, reach = 22 / scale
        var top = (group?.minY ?? visible.maxY) - reach, bottom = (group?.maxY ?? visible.maxY) + reach
        for handle in [rotation] + fieldWidthHandles + anchorHandles where !handle.isHidden {
            top = min(top, handle.center.y - reach); bottom = max(bottom, handle.center.y + reach)
        }
        let low = visible.minY + half + 4 / scale, high = visible.maxY - half - 4 / scale
        let above = top - margin - half, below = bottom + margin + half
        let y = group == nil ? high : above >= low ? above : below <= high ? below : min(max(above, low), high)
        let sideways = (width / 2 + 4) / scale
        bar.center = CGPoint(x: min(max(group?.midX ?? visible.midX, visible.minX + sideways), visible.maxX - sideways), y: y)
    }
    private func updateContour() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard active, let frame = selectionBounds(preview ?? content, applyingPreview: true) else {
            contourLayer.isHidden = true; contourLayer.removeAllAnimations(); contourAnimationScale = nil; return
        }
        let scale = displayScale
        contourLayer.bounds = bounds; contourLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        // One field, image or shape: thin solid frame at the selection gap.
        // Groups and lasso selections (and any handwriting): dashed contour.
        let single = ink.isEmpty && texts.count + images.count + shapes.count == 1
        if let box = selectedField(preview ?? content) {
            // A selected field (fitted height, rotated about its top-left corner).
            let gap = contourGap, frame = box.fieldStyleRect
            var turn = CGAffineTransform(translationX: box.x + layout.contentOrigin.x, y: box.y + layout.contentOrigin.y)
                .rotated(by: box.angle * .pi / 180)
            contourLayer.path = CGPath(roundedRect: CGRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height).insetBy(dx: -gap, dy: -gap),
                                       cornerWidth: gap, cornerHeight: gap, transform: &turn)
        } else {
            contourLayer.path = selectionOutline() ?? UIBezierPath(roundedRect: display(frame).insetBy(dx: -contourGap, dy: -contourGap),
                                                                   cornerRadius: contourGap).cgPath
        }
        contourLayer.isHidden = false
        if single {
            contourLayer.lineWidth = SelectionStyle.lineWidth / scale; contourLayer.lineDashPattern = nil
            contourLayer.fillColor = UIColor.clear.cgColor
            contourLayer.removeAllAnimations(); contourAnimationScale = nil
            return
        }
        contourLayer.fillColor = SelectionStyle.groupFill.cgColor
        contourLayer.lineWidth = SelectionStyle.groupLineWidth / scale
        contourLayer.lineDashPattern = SelectionStyle.groupDash.map { NSNumber(value: Double($0 / scale)) }
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
        if gestureRecognizer === pan { fingerPan = touch.type != .pencil }
        if gestureRecognizer === pan, tool == .image || (touch.type != .pencil && !allowsFingerDrawing) {
            // A finger (any touch in the image tool) grabs the selection or an
            // object below it; elsewhere it scrolls.
            return grabsObject(at: touch.location(in: self))
        }
        return true
    }
    /// A drag at `location` moves the (unlocked) selection or picks up a
    /// shape, in the image tool also an unlocked image.
    private func grabsObject(at location: CGPoint) -> Bool {
        let point = canonical(location)
        if !selectionLocked, selectionBounds(content).map(display)?.insetBy(dx: -8 / displayScale, dy: -8 / displayScale).contains(location) == true { return true }
        return shapeHit(at: point) != nil || (tool == .image && imageHit(at: point) != nil)
    }
    /// Topmost unlocked image under `point` (canonical), with the touch tolerance.
    private func imageHit(at point: CGPoint) -> ImageObject? {
        content.images.reversed().first { !$0.locked && PageObjectHitTest.hits($0, at: PagePoint(x: point.x, y: point.y), tolerance: 10 / displayScale) }
    }
    /// Topmost shape under `point` (canonical), when shapes may be picked.
    private func shapeHit(at point: CGPoint) -> ShapeObject? {
        guard tool == .shape || filter.shapes else { return nil }
        return content.shapes.reversed().first { ShapeRendering.hit($0, at: point, tolerance: 10 / displayScale) }
    }
    private func selectedShape(_ value: PageContent) -> ShapeObject? {
        guard shapes.count == 1, let id = shapes.first else { return nil }
        return value.shapes.first { $0.id == id }
    }
    /// Shows `count` anchor handles (created on demand, extra ones hidden).
    private func updateAnchorHandles(count: Int) {
        while anchorHandles.count < count {
            let anchor = SelectionHandle()
            let drag = SnapPanGestureRecognizer(target: self, action: #selector(handle(_:)))
            drag.maximumNumberOfTouches = 1; drag.delegate = ScrollPanPriority.shared
            anchor.tag = 100 + anchorHandles.count; anchor.addGestureRecognizer(drag)
            insertSubview(anchor, belowSubview: rotation)
            anchorHandles.append(anchor)
        }
        for (index, handle) in anchorHandles.enumerated() {
            handle.isHidden = index >= count
            handle.accessibilityLabel = "Formpunkt \(index + 1) verschieben"
        }
    }
    /// The Pencil starts a new shape where it touches, without a movement
    /// threshold: shape tool, outside the current selection (that one is
    /// dragged as before). Fingers keep scrolling/zooming/grabbing first.
    private func drawsShapeOnTouchDown(_ touch: UITouch) -> Bool {
        guard active, tool == .shape, !touchSelection, touch.type == .pencil else { return false }
        // On a checkbox the Pencil taps it; a real drag still draws after the threshold.
        if hitsCheckbox?(touch.location(in: self)) == true { return false }
        let inset = -8 / displayScale
        return selectionBounds(content).map(display)?.insetBy(dx: inset, dy: inset).contains(touch.location(in: self)) != true
    }
    @objc private func tap(_ gesture: UITapGestureRecognizer) { selectAtTap(gesture.location(in: self)) }
    private var lassoTool: Bool { tool == .selection || tool == .inkSelection }
    /// A tap picks the topmost single object like a finger tap with an ink
    /// tool (`PageObjectHitTest` through the sheet, screen-constant
    /// tolerance): a field's text lines (an empty frame reaches through, a
    /// field above a shape wins), with the lasso next a stroke, then a shape
    /// or an image. The lasso keeps its filter. A second tap on the selected
    /// field sets the caret or picks the next field below. `location`: layer
    /// coordinates (the sheet's).
    private func selectAtTap(_ location: CGPoint) {
        if hitsCheckbox?(location) == true { return } // the sheet's checkbox tap toggles it
        onInteractionBegan?()
        let point = canonical(location), page = PagePoint(x: point.x, y: point.y)
        var hits = objectHits?(location) ?? []
        if lassoTool { hits = hits.filter(filterAllows) }
        let texts = hits.compactMap { hit -> UUID? in if case .text(let id) = hit { return id }; return nil }
        if tapOnSelectedField(textHits: texts, at: page) { return }
        adopted = nil; clearSelection()
        if let first = hits.first, case .text = first { select(first) }
        else if lassoTool, filter.ink, let stroke = strokeHit(at: point) { ink = [stroke] }
        else if let first = hits.first { select(first) }
        // Only the image tool reaches locked images (background), to unlock them.
        else if tool == .image, let locked = content.images.reversed().first(where: {
            $0.locked && PageObjectHitTest.hits($0, at: page, tolerance: 10 / displayScale) }) { images = [locked.id] }
        refresh()
    }
    private func filterAllows(_ object: PageObjectReference) -> Bool {
        switch object {
        case .text: filter.text
        case .image: filter.images
        case .shape: filter.shapes
        }
    }
    private func select(_ object: PageObjectReference) {
        switch object {
        case .text(let id): texts = [id]; fieldMode = true
        case .image(let id): images = [id]
        case .shape(let id): shapes = [id]
        }
    }
    /// Topmost stroke under `point` (canonical), within about 10 screen points.
    private func strokeHit(at point: CGPoint) -> Int? {
        guard let drawing = drawing(content.drawing) else { return nil }
        let tolerance = 10 / displayScale, target = PagePoint(x: point.x, y: point.y)
        for index in drawing.strokes.indices.reversed() {
            let stroke = drawing.strokes[index]
            guard stroke.renderBounds.insetBy(dx: -tolerance, dy: -tolerance).contains(point) else { continue }
            var points = stroke.path.interpolatedPoints(by: .distance(3)).map { sample -> PagePoint in
                let location = sample.location.applying(stroke.transform); return PagePoint(x: location.x, y: location.y)
            }
            if points.isEmpty, let sample = stroke.path.first {
                let location = sample.location.applying(stroke.transform); points = [PagePoint(x: location.x, y: location.y)]
            }
            let width = stroke.path.map { max($0.size.width, $0.size.height) }.max() ?? 0
            let transformScale = max(hypot(stroke.transform.a, stroke.transform.b), hypot(stroke.transform.c, stroke.transform.d))
            if StrokeHitTest.hits(sweep: target, target, radius: width * transformScale / 2 + tolerance, stroke: points) { return index }
        }
        return nil
    }
    @objc private func drag(_ gesture: UIPanGestureRecognizer) { self.gesture(gesture, requestedMode: nil) }
    @objc private func handle(_ gesture: UIPanGestureRecognizer) {
        let tag = gesture.view?.tag ?? 2
        if gesture.state == .began { if tag >= 100 { activeAnchor = tag - 100 } else { activeCorner = tag } }
        self.gesture(gesture, requestedMode: tag >= 100 ? 7 : tag < 4 ? 2 : tag)
    }
    private func gesture(_ gesture: UIPanGestureRecognizer, requestedMode: Int?) {
        guard active else { return }
        let point = canonical(gesture.location(in: self))
        if gesture.state == .began {
            onInteractionBegan?()
            adopted = nil; rotationSnap = nil
            if #available(iOS 17.5, *), feedback == nil { feedback = UICanvasFeedbackGenerator(view: self) }
            feedback?.prepare()
            let screen = gesture.location(in: nil)
            motionTicks.begin(at: .init(x: screen.x, y: screen.y), time: CACurrentMediaTime())
            // The exact first contact, not where the movement threshold was crossed.
            if gesture === pan, let down = pan.touchDownLocation { initialPoint = canonical(down) }
            else {
                let translation = gesture.translation(in: self)
                initialPoint = CGPoint(x: point.x - translation.x, y: point.y - translation.y)
            }
            shapeTapCandidate = false
            startContent = content; preview = nil; inkTransform = nil; groupTransform = nil; rotationDrag = nil
            if let requestedMode { dragMode = requestedMode }
            else if !selectionLocked, selectionBounds(content)?.insetBy(dx: -8 / displayScale, dy: -8 / displayScale).contains(initialPoint) == true { dragMode = 1 }
            else if (fingerPan && !allowsFingerDrawing) || tool == .image, let hit = shapeHit(at: initialPoint) {
                // A finger on a shape picks it up and moves it at once.
                clearSelection(); shapes = [hit.id]; dragMode = 1
            }
            else if tool == .image, let hit = imageHit(at: initialPoint) {
                // Image tool: finger or Pencil on an image picks it up.
                clearSelection(); images = [hit.id]; dragMode = 1
            }
            else if tool == .shape {
                clearSelection(); dragMode = 3
                let color = automaticColor?(.init(x: initialPoint.x, y: initialPoint.y)) ?? color
                draft = ShapeObject(kind: ShapeKind.toolKinds.contains(options.kind) ? options.kind : .line,
                    start: .init(x: initialPoint.x, y: initialPoint.y), end: .init(x: point.x, y: point.y),
                    color: color, lineWidth: lineWidth, pattern: options.pattern, fill: options.fill(stroke: color))
                shapeTapCandidate = gesture === pan && pan.beganOnTouchDown
            } else { clearSelection(); dragMode = 0; lasso = [CGPoint(x: initialPoint.x + layout.contentOrigin.x, y: initialPoint.y + layout.contentOrigin.y)] }
            beginSnapping(content)
        }
        guard let initial = startContent else { return }
        if gesture.state == .cancelled || gesture.state == .failed {
            angleLabel.isHidden = true; snapping.end(); rotationDrag = nil; groupTransform = nil
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
                if let lift { lifted = true; preview = lift.remainder; inkTransform = nil; host.floatSelection(lift, gesture: gesture); snapping.hide() }
            }
            if !lifted {
                if lift != nil { endLift(); preview = initial; inkTransform = nil; groupTransform = nil }
                // The one move path (`ObjectMovement`) with weiches Einrasten.
                let proposed = PagePoint(x: point.x - initialPoint.x, y: point.y - initialPoint.y)
                let snap = snapping.track(gesture, in: self)
                let shift = selectionBounds(initial).map { bounds -> PagePoint in
                    let frame = PageRect(bounds)
                    let shift = ObjectMovement.translation(moving: frame, by: proposed, within: limits, snapping: snap)
                    snapping.show(translation: shift, frame: frame, gesture: gesture, in: self)
                    return shift
                } ?? proposed
                if let value = transformed(initial, dx: shift.x, dy: shift.y, scale: 1) { preview = value }
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
            // One rotation for every selection: about the middle of a single
            // field/image or of the group's frame; weich einrasten at
            // 0/90/180/270° (and weaker at 45°) of the absolute angle of a
            // single field/image, of the turn otherwise; small degree label.
            if rotationDrag == nil, let frame = rotationFrame(initial) {
                rotationDrag = RotationDrag(pivot: frame.center, base: frame.angle, size: frame.size)
                rotationImpact.prepare()
            }
            if var drag = rotationDrag {
                let pivot = drag.pivot
                let turn = (atan2(point.y - pivot.y, point.x - pivot.x) - atan2(initialPoint.y - pivot.y, initialPoint.x - pivot.x)) * 180 / .pi
                let snap = TextFieldRotation.snapped(drag.base + turn)
                if let target = snap.target, target != rotationSnap { rotationTick(at: gesture.location(in: self)) }
                rotationSnap = snap.target
                let delta = snap.angle - drag.base
                if let value = rotated(initial, by: delta, around: pivot) {
                    preview = value; drag.turn = delta; rotationDrag = drag
                }
                angleLabel.text = TextFieldRotation.label(drag.base + drag.turn); angleLabel.isHidden = false
            }
        case 3:
            // Lines and arrows snap their angle like held lines (`LineSnapping`).
            if let current = draft, current.kind == .line || current.kind == .arrow {
                draft?.end = LineSnapping.end(from: current.start, to: .init(x: point.x, y: point.y))
            } else { draft?.end = .init(x: point.x, y: point.y) }
            // About 4 screen points of travel make it a drawn shape, not a tap.
            if shapeTapCandidate, let down = pan.touchDownLocation,
               hypot(gesture.location(in: self).x - down.x, gesture.location(in: self).y - down.y) * displayScale > 4 { shapeTapCandidate = false }
        case 9, 10:
            // Corner points: only the width changes (fixed from now on), the
            // movement across the field is ignored; the height follows the text.
            if let box = selectedField(initial) {
                let radians = box.angle * .pi / 180
                var along = (point.x - initialPoint.x) * cos(radians) + (point.y - initialPoint.y) * sin(radians)
                if box.angle == 0 {
                    // The dragged edge snaps to vertical targets (edges, centres, grid, margins).
                    let pad = box.fieldPadding // the visible edge of a styled field snaps
                    let edge = dragMode == 10 ? box.x + box.width + pad + along : box.x - pad + along
                    along += snapping.point(PagePoint(x: edge, y: box.y + box.height / 2), axes: [.x], gesture: gesture, in: self).x - edge
                }
                let minimum = max(16, box.style.fontSize)
                var next = box; next.autoWidth = nil
                if dragMode == 10 { next.width = max(minimum, box.width + along) }
                else {
                    let width = max(minimum, box.width - along), moved = box.width - width
                    next.width = width; next.x += moved * cos(radians); next.y += moved * sin(radians)
                }
                next = fittedText?(next) ?? next
                if next.fits(in: limits), (try? next.validate()) != nil { preview = replacing(initial, with: next) }
            }
        default:
            // One anchor follows the touch; the rest of the shape stays.
            let target = snapping.point(PagePoint(x: point.x, y: point.y), gesture: gesture, in: self)
            if let id = shapes.first, let index = initial.shapes.firstIndex(where: { $0.id == id }),
               let moved = initial.shapes[index].movingAnchor(activeAnchor, to: target),
               limits.contains(moved.bounds, tolerance: 0.02) {
                var value = initial; value.shapes[index] = moved; preview = value
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
                    select(path: path, rect: path.bounds)
                    // The closed loop selected something: confirm on Apple Pencil Pro.
                    if hasSelection { haptic(completed: true, at: gesture.location(in: self)) }
                }
            } else if dragMode == 3, shapeTapCandidate {
                // A Pencil tap in the shape tool selects as before (the tap
                // recognizer waits for this pan, which began on touch-down).
                preview = nil; inkTransform = nil; draft = nil; startContent = nil; lasso = []; shapeTapCandidate = false
                selectAtTap(CGPoint(x: initialPoint.x + layout.contentOrigin.x, y: initialPoint.y + layout.contentOrigin.y)); return
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
            angleLabel.isHidden = true; snapping.end(); rotationDrag = nil; groupTransform = nil
        }
        refresh()
    }
    /// Weiches Einrasten for this drag: moves (the selection as a whole,
    /// other objects as targets), a field's width points and shape anchors.
    private func beginSnapping(_ initial: PageContent) {
        snapping.end()
        let members = texts.union(images).union(shapes)
        switch dragMode {
        case 1:
            let field = selectedField(initial)
            // Below the top of the moved (visible, padded) frame.
            let offset = field.flatMap { box in snapping.host?.snapBaseline(of: box).map { $0 - box.rotatedBounds.y } }
            snapping.begin(excluding: members, snapFrame: selectionBounds(initial, forSnapping: true).map { PageRect($0) },
                           baselineOffset: offset, in: self)
        case 7, 9, 10: snapping.begin(excluding: members, in: self)
        default: break
        }
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
            pixelScale: displayScale * (window?.screen.scale ?? 2), page: pageContext?())
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
    // MARK: Finger selection with an ink tool (Nutzerfeedback Tag 1)
    // The sheet decides what a finger tap hits (`PageObjectHitTest`) and owns
    // the finger gestures; this layer only shows and edits the selection.
    // Meanwhile only its controls (action bar, handles) take touches: Pencil
    // and finger elsewhere reach the canvas and the notebook as before.

    var hasTouchSelection: Bool { touchSelection && hasSelection }
    /// Ink tools change ink and held shapes without a full configuration
    /// (`WorksheetView.matches`), so this layer's copy can be older. Finger
    /// selection takes the sheet's current content first; otherwise its
    /// previews would show (and its commits expect) a stale page.
    func adoptCurrentContent(_ value: PageContent) {
        guard value != content, lift == nil, startContent == nil, preview == nil, draft == nil else { return }
        content = value; adopted = nil; ink = []
        texts.formIntersection(value.textBoxes.map(\.id)); images.formIntersection(value.images.map(\.id))
        shapes.formIntersection(value.shapes.map(\.id))
    }
    /// Selects exactly `object` (nil: clears a finger selection).
    func selectByTouch(_ object: PageObjectReference?) {
        guard enabled, lift == nil, startContent == nil, !toolActive else { return }
        adopted = nil; clearSelection()
        switch object {
        case .text(let id)?: if content.textBoxes.contains(where: { $0.id == id && $0.allowsObjectSelection }) { texts = [id]; fieldMode = true }
        case .image(let id)?: if content.images.contains(where: { $0.id == id && !$0.locked }) { images = [id] }
        case .shape(let id)?: if content.shapes.contains(where: { $0.id == id }) { shapes = [id] }
        case nil: break
        }
        touchSelection = touchSelection || hasSelection
        isUserInteractionEnabled = active; isHidden = !active
        refresh()
    }
    /// `point` in this layer's coordinates (same as the sheet's).
    func touchSelectionContains(_ point: CGPoint) -> Bool {
        guard hasTouchSelection, lift == nil, let frame = selectionBounds(content).map(display) else { return false }
        let margin = 8 / displayScale
        // A selected field moves when dragged anywhere inside its (rotated) frame.
        if let box = selectedField(content) { return box.contains(PagePoint(x: canonical(point).x, y: canonical(point).y), tolerance: margin) }
        return frame.insetBy(dx: -margin, dy: -margin).contains(point)
    }
    /// A finger drag that began on the finger selection moves it (also across pages).
    func dragTouchSelection(_ gesture: UIPanGestureRecognizer) {
        guard touchSelection else { return }
        self.gesture(gesture, requestedMode: 1)
    }
    func endTouchSelection() {
        guard touchSelection, lift == nil, startContent == nil else { return }
        adopted = nil; clearSelection(); refresh()
    }
    /// Another page is being worked on: no selection (and no key commands) here.
    func dropSelection() {
        guard lift == nil, startContent == nil else { return }
        if hasSelection || adopted != nil { adopted = nil; clearSelection(); refresh() }
        if isFirstResponder { resignFirstResponder() }
    }
    private func endTouchSelectionMode() {
        guard touchSelection else { return }
        touchSelection = false; onTouchSelectionEnded?()
    }
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        // Finger selection: the layer's own surface passes everything through.
        return touchSelection && hit === self ? nil : hit
    }

    /// Applies only members that exist in `value` (stroke indices, object IDs).
    private func select(_ selection: TransferredSelection, in value: PageContent) {
        let strokes = selection.ink.isEmpty ? 0 : (drawing(value.drawing)?.strokes.count ?? 0)
        ink = selection.ink.filter { $0 < strokes }
        texts = selection.texts.intersection(value.textBoxes.map(\.id))
        images = selection.images.intersection(value.images.map(\.id))
        shapes = selection.shapes.intersection(value.shapes.map(\.id))
    }
    private func select(path: UIBezierPath, rect: CGRect) {
        let region = LassoRegion(points: path.cgPath.lassoPoints)
        func selected(_ bounds: CGRect) -> Bool {
            guard rect.insetBy(dx: -0.001, dy: -0.001).intersects(bounds) else { return false }
            return region.intersects(PageRect(bounds))
        }
        func selectedField(_ box: TextBox) -> Bool {
            guard rect.insetBy(dx: -0.001, dy: -0.001).intersects(box.rotatedBounds.cgRect) else { return false }
            // Only the text (or a field style's surface/frame line), not the empty frame.
            return region.selects(box, lines: textLines?(box) ?? [])
        }
        if filter.text { texts = Set(content.textBoxes.filter { $0.allowsObjectSelection && selectedField($0) }.map(\.id)) }
        if filter.images { images = Set(content.images.filter { !$0.locked && selected($0.rotatedBounds.cgRect) }.map(\.id)) }
        // Shapes count by their stroke (and a visible fill), not their bounds:
        // a lasso or tap inside an unfilled outline leaves the shape alone.
        if filter.shapes {
            shapes = Set(content.shapes.filter { shape in
                rect.insetBy(dx: -0.001, dy: -0.001).intersects(shape.bounds.cgRect) && region.selects(shape)
            }.map(\.id))
        }
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
    /// `forSnapping`: shapes by their drawn outline instead of their touch padding.
    private func selectionBounds(_ value: PageContent, applyingPreview: Bool = false, forSnapping: Bool = false) -> CGRect? {
        guard hasSelection, !(applyingPreview && lift != nil) else { return nil }
        var rects = value.textBoxes.filter { texts.contains($0.id) }.map { (isFieldSelection ? fitted($0) : $0).rotatedBounds.cgRect }
        rects += value.images.filter { images.contains($0.id) }.map { $0.rotatedBounds.cgRect }
        rects += value.shapes.filter { shapes.contains($0.id) }.map { (forSnapping ? $0.snapFrame : $0.bounds).cgRect }
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
        if let fill = fillStyleSection() {
            controller.addChild(fill); fill.view.backgroundColor = .clear
            fill.view.frame = CGRect(x: 20, y: 240, width: 280, height: 170); root.addSubview(fill.view); fill.didMove(toParent: controller)
            controller.preferredContentSize.height = 426
        }
        if let popover = controller.popoverPresentationController {
            popover.sourceView = bar; popover.sourceRect = bar.bounds; popover.permittedArrowDirections = [.up, .down]
            popover.backgroundColor = root.backgroundColor
        }
        styleController = controller; parent.present(controller, animated: true)
    }
    /// „Feldstil“ of the selected field (Stufe 4): small popover with fill
    /// and frame (`FieldStyleOptions`); each choice is one undo step.
    private func openFieldStyle() {
        guard isFieldSelection, let id = texts.first, let box = content.textBoxes.first(where: { $0.id == id }) else { return }
        var responder: UIResponder? = self
        while responder != nil && !(responder is UIViewController) { responder = responder?.next }
        guard let parent = responder as? UIViewController else { return }
        styleController?.dismiss(animated: false)
        let controller = UIHostingController(rootView: FieldStyleOptions(choice: .init(fill: box.fill, border: box.border)) { [weak self] choice in
            self?.applyFieldStyle(choice)
        })
        controller.overrideUserInterfaceStyle = .dark
        controller.view.backgroundColor = UIColor(white: 0.055, alpha: 1)
        controller.modalPresentationStyle = .popover
        controller.preferredContentSize = CGSize(width: 384, height: 196)
        if let popover = controller.popoverPresentationController {
            popover.sourceView = bar; popover.sourceRect = bar.bounds; popover.permittedArrowDirections = [.up, .down]
            popover.backgroundColor = controller.view.backgroundColor
        }
        styleController = controller; parent.present(controller, animated: true)
    }
    /// The selected field with fill/frame; it stays completely on the page
    /// (`TextBox.styled`: padding outwards, else moved inwards, else narrower).
    private func applyFieldStyle(_ choice: FieldStyleOptions.Choice) {
        guard active, isFieldSelection, let id = texts.first,
              let index = content.textBoxes.firstIndex(where: { $0.id == id }) else { return }
        let box = fitted(content.textBoxes[index])
        guard box.fill != choice.fill || box.border != choice.border else { return }
        guard var styled = box.styled(fill: choice.fill, border: choice.border, in: limits) else { return }
        styled = fitted(styled)
        if !styled.fits(in: limits), let shifted = styled.shifted(into: limits) { styled = shifted }
        guard styled.fits(in: limits), (try? styled.validate()) != nil else { return }
        var value = content; value.textBoxes[index] = styled
        _ = commit(value, previous: content); refresh()
    }
    /// „Füllung“ of selected rectangles, ellipses and polygons (`ShapeFillStyleSection`).
    private func fillStyleSection() -> UIViewController? {
        guard let first = content.shapes.first(where: { shapes.contains($0.id) && $0.isFillable }) else { return nil }
        let choice = ShapeFillStyleSection.Choice(filled: first.hasVisibleFill,
            color: first.fill.flatMap { first.fillFollowsStroke ? nil : $0.opaque },
            opacity: first.fill.map { ShapeFill.rounded($0.alpha) } ?? options.fillOpacity)
        return UIHostingController(rootView: ShapeFillStyleSection(choice: choice) { [weak self] choice in
            guard let self, self.active else { return }
            var value = self.content
            for i in value.shapes.indices where self.shapes.contains(value.shapes[i].id) {
                value.shapes[i] = choice.filled ? value.shapes[i].filled(color: choice.color, opacity: choice.opacity) : value.shapes[i].unfilled()
            }
            _ = self.commit(value, previous: self.content); self.refresh()
        })
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
            minimum = max(minimum, 0.5 / shape.lineWidth, 1 / max(1e-6, shape.frame.width, shape.frame.height))
            maximum = min(maximum, 40 / shape.lineWidth)
            if shape.kind == .rectangle || shape.kind == .ellipse || shape.kind == .polygon {
                minimum = max(minimum, 1 / shape.frame.width, 1 / shape.frame.height)
            }
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
            if isFieldSelection { value.textBoxes[i] = fitted(value.textBoxes[i]) }
            guard let box = try? value.textBoxes[i].scaled(by: scale, around: anchor,
                translation: .init(x: dx, y: dy)), box.fits(in: limits) else { return nil }
            value.textBoxes[i] = box
        }
        for i in value.images.indices where images.contains(value.images[i].id) {
            let p = point(.init(x: value.images[i].x, y: value.images[i].y))
            value.images[i].x = p.x; value.images[i].y = p.y
            value.images[i].width *= scale; value.images[i].height *= scale
            guard (try? value.images[i].validate()) != nil, value.images[i].fits(in: limits) else { return nil }
        }
        for i in value.shapes.indices where shapes.contains(value.shapes[i].id) {
            value.shapes[i] = value.shapes[i].mapped(point)
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
    /// Only the selected members (and their bounds), as copied or duplicated.
    private func selectedMembers() -> (content: PageContent, bounds: CGRect)? {
        guard let frame = selectionBounds(content) else { return nil }
        var value = content
        value.textBoxes.removeAll { !texts.contains($0.id) }; value.images.removeAll { !images.contains($0.id) }
        value.shapes.removeAll { !shapes.contains($0.id) }
        let drawing = (try? PKDrawing(data: content.drawing)) ?? PKDrawing()
        value.drawing = PKDrawing(strokes: drawing.strokes.enumerated().filter { ink.contains($0.offset) }.map(\.element)).dataRepresentation()
        return (value, frame)
    }
    /// „Duplizieren“/⌘D: a copy beside the selection; the clipboards stay untouched.
    private func duplicateSelection() {
        guard !selectionLocked, let members = selectedMembers() else { return }
        let field = isFieldSelection
        paste(members.content, from: members.bounds)
        if field, texts.count == 1, ink.isEmpty, images.isEmpty, shapes.isEmpty { fieldMode = true; refresh() }
    }
    private func copySelection() {
        guard let (value, frame) = selectedMembers() else { return }
        ObjectClipboard.content = value; ObjectClipboard.bounds = frame
        // Pasting into another notebook stages the originals from this package.
        ImageAssetRegistry.shared.pinClipboard(value.images.map(\.asset))
        // Field text also goes to the system pasteboard (other apps, text
        // fields), in reading order; the copy stays the newest source.
        let text = value.textBoxes.sorted { ($0.y, $0.x) < ($1.y, $1.x) }.map(\.text).filter { !$0.isEmpty }
        if !text.isEmpty { UIPasteboard.general.string = text.joined(separator: "\n\n") }
        ObjectClipboard.changeCount = UIPasteboard.general.changeCount
    }
    /// The one paste path of the sheet (`WorksheetView.pasteFromClipboard`)
    /// for every tool: ⌘V and „Einfügen“ here end up there.
    var onPaste: (() -> Void)?
    /// Pastes the copied objects (also when this layer is not the tool's own
    /// plane: the result becomes a finger selection, so it can be moved at once).
    func pasteCopiedObjects() {
        guard enabled, lift == nil, startContent == nil, ObjectClipboard.content != nil else { return }
        pasteSelection()
        if !toolActive, hasSelection {
            touchSelection = true; isUserInteractionEnabled = active; isHidden = !active; refresh()
        }
    }
    private func pasteSelection() {
        guard let copied = ObjectClipboard.content, let frame = ObjectClipboard.bounds else { return }
        paste(copied, from: frame)
    }
    /// New copies (new IDs) of `copied`, 24 pt beside `frame` and on the page; selected.
    private func paste(_ copied: PageContent, from frame: CGRect) {
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
        guard hasSelection, !selectionLocked else { return }
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
            value.shapes[i] = value.shapes[i].recolored(color)
            if changeWidth { value.shapes[i].lineWidth = lineWidth }
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
    @objc private func pasteKey() { if let onPaste { onPaste() } else { pasteSelection() } }
    @objc private func deleteKey() { deleteSelection() }
    @objc private func escapeKey() { adopted = nil; clearSelection(); refresh() }
    @objc private func cutKey() { guard hasSelection, !selectionLocked else { return }; copySelection(); deleteSelection() }
    @objc private func duplicateKey() { guard hasSelection else { return }; duplicateSelection() }
    /// ⌘A: everything selectable on this page (the lasso's filter; shape tool: shapes).
    @objc private func selectAllKey() {
        guard active, lift == nil, startContent == nil else { return }
        adopted = nil; clearSelection()
        if tool == .shape { shapes = Set(content.shapes.map(\.id)) }
        else if tool == .image { images = Set(content.images.filter { !$0.locked }.map(\.id)) }
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
        guard active, hasSelection, !selectionLocked, lift == nil, startContent == nil,
              var value = transformed(content, dx: dx, dy: dy, scale: 1) else { return }
        if let inkTransform {
            guard let moved = transformedInk(content, using: inkTransform, inkOnly: false) else { self.inkTransform = nil; return }
            value.drawing = moved.drawing
        }
        inkTransform = nil
        _ = commit(value, previous: content); refresh()
    }
}
