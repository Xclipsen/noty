import UIKit
import PencilKit
import NotebookCore

/// Finger gestures of one sheet while an ink tool is active (Nutzerfeedback
/// nach Tag 1). The Pencil keeps drawing; the finger
/// - taps an object (text field, image, shape) to select it with frame and
///   handles, without changing the tool; a tap on empty paper clears it,
/// - drags a selection it made, and otherwise still scrolls and zooms,
/// - double-taps for „Textfeld hinzufügen“ at that point. This menu replaces
///   PencilKit's own double-tap menu („Platz einfügen“, `PKSpaceInsertionController`).
///
/// What a tap hits is decided by `PageObjectHitTest` over all object types;
/// showing and editing the selection stays with `ObjectEditingLayer`. Text
/// fields count only on their laid-out text lines (Textneubau): the empty
/// rest of a frame reaches through. A tap on the selected field sets the
/// caret there (`WorksheetView.requestTextEdit`), or – with another field's
/// text at the same place – selects the next field below.
@MainActor
final class FingerObjectGestures: NSObject, UIGestureRecognizerDelegate, @MainActor UIEditMenuInteractionDelegate {
    private weak var sheet: WorksheetView?
    private let tap = UITapGestureRecognizer()
    private let doubleTap = UITapGestureRecognizer()
    private let drag = UIPanGestureRecognizer()
    private var menu: UIEditMenuInteraction?
    /// Page and canonical point of the shown double-tap menu.
    private var menuTarget: (pageID: UUID, point: PagePoint)?
    /// PencilKit double-tap recognizers already waiting for `doubleTap`.
    private let linked = NSHashTable<UIGestureRecognizer>.weakObjects()
    /// Pending flow caret of a single tap in a text document (cancelled by a double tap).
    private var flowTapToken = 0

    func install(on sheet: WorksheetView) {
        self.sheet = sheet
        let fingers = [UITouch.TouchType.direct, .indirectPointer].map { NSNumber(value: $0.rawValue) }
        for gesture in [tap, doubleTap, drag] as [UIGestureRecognizer] {
            gesture.allowedTouchTypes = fingers; gesture.delegate = self
            sheet.addGestureRecognizer(gesture)
        }
        // Taps only observe: PencilKit and the views below get every touch unchanged.
        for gesture in [tap, doubleTap] {
            gesture.cancelsTouchesInView = false; gesture.delaysTouchesEnded = false
        }
        tap.addTarget(self, action: #selector(tapped(_:)))
        doubleTap.numberOfTapsRequired = 2
        doubleTap.addTarget(self, action: #selector(doubleTapped(_:)))
        drag.maximumNumberOfTouches = 1
        drag.addTarget(self, action: #selector(dragged(_:)))
        let menu = UIEditMenuInteraction(delegate: self)
        sheet.addInteraction(menu); self.menu = menu
    }

    /// PencilKit's own finger double tap (its menu offers „Platz einfügen“)
    /// waits for ours, which wins wherever it may begin. Its recognizers
    /// appear lazily, so this runs again on window and tool changes.
    func linkNativeDoubleTaps(in canvas: UIView) {
        let finger = NSNumber(value: UITouch.TouchType.direct.rawValue)
        func visit(_ view: UIView) {
            for case let other as UITapGestureRecognizer in view.gestureRecognizers ?? []
            where other !== doubleTap && other.numberOfTapsRequired >= 2 && other.allowedTouchTypes.contains(finger) && !linked.contains(other) {
                other.require(toFail: doubleTap); linked.add(other)
            }
            view.subviews.forEach(visit)
        }
        visit(canvas)
    }

    // MARK: Hit test

    /// Every selectable object under a finger at `point` (sheet coordinates), topmost first.
    private func objects(at point: CGPoint, in sheet: WorksheetView) -> [PageObjectReference] {
        let canonical = sheet.canonical(point)
        // About 10 screen points of slack at any zoom (8 around text lines).
        let a = sheet.convert(CGPoint.zero, to: nil), b = sheet.convert(CGPoint(x: 100, y: 0), to: nil)
        let scale = max(0.001, hypot(b.x - a.x, b.y - a.y) / 100)
        return PageObjectHitTest.all(at: canonical, in: sheet.objectContent, tolerance: 10 / scale,
            textHit: { box, point in sheet.textLineHit(box, at: point, slack: 8 / scale) },
            shapeHit: { shape, point in ShapeRendering.hit(shape, at: CGPoint(x: point.x, y: point.y)) })
    }

    // MARK: Actions

    @objc private func tapped(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended, let sheet, sheet.acceptsFingerObjectTaps else { return }
        let point = gesture.location(in: sheet)
        sheet.rememberTap(point)
        sheet.syncObjectPlane()
        let hits = objects(at: point, in: sheet)
        // Second tap on the selected field: caret there, or the next field below.
        let texts = hits.compactMap { hit -> UUID? in if case .text(let id) = hit { return id }; return nil }
        if sheet.objectLayer.tapOnSelectedField(textHits: texts, at: sheet.canonical(point)) { return }
        if let hit = hits.first { sheet.objectLayer.selectByTouch(hit) }
        else {
            sheet.objectLayer.endTouchSelection()
            // Text document: a tap beside every object puts the caret into the
            // flow – after the double-tap window, so „Textfeld hinzufügen“ stays reachable.
            if sheet.flowDocument {
                flowTapToken += 1
                let token = flowTapToken, target = sheet.canonical(point), page = sheet.objectPageID
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self, weak sheet] in
                    guard let self, let sheet, self.flowTapToken == token, sheet.objectPageID == page,
                          sheet.acceptsFingerObjectTaps else { return }
                    sheet.requestFlowCaret(at: target)
                }
            }
        }
    }

    @objc private func doubleTapped(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended, let sheet, let pageID = sheet.objectPageID else { return }
        flowTapToken += 1 // the double tap's menu wins over the flow caret of its first tap
        let point = gesture.location(in: sheet)
        dismissForeignMenus(in: sheet.canvas)
        sheet.syncObjectPlane()
        // On an object the first tap already selected it; no menu there.
        guard objects(at: point, in: sheet).isEmpty else { menuTarget = nil; return }
        let origin = sheet.pageLayout.contentOrigin
        menuTarget = (pageID, PagePoint(x: point.x - origin.x, y: point.y - origin.y))
        // A menu PencilKit still presents in this turn is closed before ours.
        DispatchQueue.main.async { [weak self, weak sheet] in
            guard let self, let sheet, let menu = self.menu, self.menuTarget?.pageID == sheet.objectPageID, sheet.window != nil else { return }
            self.dismissForeignMenus(in: sheet.canvas)
            menu.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil, sourcePoint: point))
        }
    }

    @objc private func dragged(_ gesture: UIPanGestureRecognizer) {
        sheet?.objectLayer.dragTouchSelection(gesture)
    }

    private func dismissForeignMenus(in view: UIView) {
        for case let other as UIEditMenuInteraction in view.interactions where other !== menu { other.dismissMenu() }
        view.subviews.forEach { dismissForeignMenus(in: $0) }
    }

    // MARK: UIEditMenuInteractionDelegate

    func editMenuInteraction(_ interaction: UIEditMenuInteraction, menuFor configuration: UIEditMenuConfiguration,
                             suggestedActions: [UIMenuElement]) -> UIMenu? {
        guard let target = menuTarget else { return nil }
        // Only this entry: the responder chain's suggestions (paste, PencilKit's
        // „Platz einfügen“) are deliberately not offered here.
        return UIMenu(children: [UIAction(title: "Textfeld hinzufügen", image: UIImage(systemName: "text.badge.plus")) { [weak self] _ in
            guard let sheet = self?.sheet, sheet.objectPageID == target.pageID else { return }
            sheet.requestTextField(at: target.point)
        }])
    }

    // MARK: UIGestureRecognizerDelegate

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard let sheet else { return false }
        // Selection controls, text views and buttons keep their own touches.
        var view = touch.view
        while let current = view, current !== sheet {
            if current === sheet.objectLayer || current is UIControl || current is UITextView || current is TextFieldContainer { return false }
            view = current.superview
        }
        let point = touch.location(in: sheet)
        if gestureRecognizer === doubleTap { return true } // gated in shouldBegin, so it fails promptly
        guard sheet.acceptsFingerObjectTaps else { return false }
        if gestureRecognizer === drag { return sheet.objectLayer.touchSelectionContains(touch.location(in: sheet.objectLayer)) }
        return !sheet.fingerTapHitsCheckbox(point)
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let sheet else { return false }
        if gestureRecognizer === doubleTap {
            return sheet.acceptsFingerObjectTaps && !sheet.fingerTapHitsCheckbox(gestureRecognizer.location(in: sheet))
        }
        return true
    }

    /// Taps only observe; they never stop scrolling, zooming or PencilKit.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        gestureRecognizer === tap || gestureRecognizer === doubleTap
    }

    /// Dragging a finger selection wins over notebook scrolling (`ScrollPanPriority`).
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
        gestureRecognizer === drag && ScrollPanPriority.outranksScrolling(gestureRecognizer, other)
    }
}
