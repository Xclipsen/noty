import SwiftUI
import PDFKit
import PencilKit
import NotebookCore
import OSLog

/// Configuration of one native page (`WorksheetView`), built per page by the
/// editor and applied by `NotebookViewport`.
struct PageEditor {
    var sourcePage: PDFPage?
    var layout: PageLayout
    var pageID: UUID
    var drawing: Data
    var textBoxes: [TextBox]
    var images: [ImageObject]
    var shapes: [ShapeObject]
    var searchHighlight: PageRect? = nil
    var paper: PaperStyle = .blank
    var paperColor: PaperColor = .white
    var margins: PageMargins?
    var tool: EditorTool
    var color: UIColor
    var width: CGFloat
    var enabled: Bool
    var focused = true
    var autoPen = false
    var onRevealCaret: () -> Void = {}
    var fingerDrawing = false
    var ruler = false
    var shapeOptions = ShapeToolOptions()
    var selectionFilter = SelectionFilter()
    var lassoMode = LassoMode.freeform
    var recognizeShapes = true
    var markerStraight = false
    /// Round tip: PencilKit monoline ink (colour already at highlighter opacity).
    var markerTip = MarkerTip.round
    var scribbleErase = true
    var onPencilAction: () -> Void
    /// Apple Pencil Pro squeeze phases (palette / double squeeze); nil keeps the plain toggle.
    var onPencilSqueeze: ((PencilSqueezeEvent) -> Void)? = nil
    var onInteraction: (UUID, Bool) -> Void
    /// Notebook-wide undo/redo, also for the system undo gesture/shortcut.
    var onUndo: (Bool) -> Void = { _ in }
    var undoState = UndoAvailability()
    /// A PencilKit tool use began on this page: one undo step per stroke/eraser gesture.
    var onInkSession: () -> Void = {}
    /// Unused by the sheet (the viewport fits and inserts text itself); kept
    /// with defaults so existing call sites compile.
    var fitRequest = 0
    var contentGeneration: Int
    var textInsertRequest = 0
    var onFlowEdit: ((TextBox, TextBox, NSRange) -> TextFlowFocus?)? = nil
    var onFlowUndo: ((Bool) -> Void)? = nil
    var onFlowBackspace: ((TextBox) -> Void)? = nil
    var onUndoBoundary: (() -> Void)? = nil
    var readTextBoxes: (() -> [TextBox])? = nil
    var readFlowText: ((UUID) -> String)? = nil
    var onDrawing: (Data) -> Void
    var onTextBoxes: ([TextBox]) -> Void
    var onImages: ([ImageObject]) -> Void
    var onError: (String) -> Void
    var onContent: (PageContent, PageContent) -> Bool
    /// Shapes removed by the precision eraser, merged into that gesture's ink undo step.
    var onEraseShapes: (PageContent, PageContent) -> Bool = { _, _ in false }
}

extension PageEditor {
    /// Every input a sheet configuration reads, except page content, callbacks
    /// and undo availability. Content is compared against what the sheet shows.
    func hasSameSettings(as other: PageEditor) -> Bool {
        guard sourcePage === other.sourcePage, layout == other.layout, pageID == other.pageID,
              contentGeneration == other.contentGeneration, searchHighlight == other.searchHighlight else { return false }
        guard paper == other.paper, paperColor == other.paperColor, margins == other.margins else { return false }
        guard tool == other.tool, width == other.width, Self.sameColor(color, other.color), enabled == other.enabled,
              focused == other.focused, autoPen == other.autoPen, fingerDrawing == other.fingerDrawing, ruler == other.ruler else { return false }
        return shapeOptions == other.shapeOptions && selectionFilter == other.selectionFilter && lassoMode == other.lassoMode
            && recognizeShapes == other.recognizeShapes && markerStraight == other.markerStraight && markerTip == other.markerTip
            && scribbleErase == other.scribbleErase
    }
    private static func sameColor(_ a: UIColor, _ b: UIColor) -> Bool {
        if a === b || a.isEqual(b) { return true }
        var x: (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0), y = x
        guard a.getRed(&x.0, green: &x.1, blue: &x.2, alpha: &x.3), b.getRed(&y.0, green: &y.1, blue: &y.2, alpha: &y.3) else { return false }
        return x == y
    }
}

struct UndoAvailability: Equatable { var undo = false, redo = false }

/// Responder undo manager of a sheet. The system undo gesture/shortcut runs the
/// notebook-wide history in `EditorModel` (stable page IDs, expected states).
/// Registration stays disabled: PencilKit and the object layers keep no second,
/// page-local history that could replay against a deleted or replaced page, and
/// a preloaded neighbour can no longer clear anyone's history.
final class NotebookUndoForwarder: UndoManager {
    var perform: ((Bool) -> Void)?
    var state = UndoAvailability()
    override init() { super.init(); disableUndoRegistration() }
    override var canUndo: Bool { perform != nil && state.undo }
    override var canRedo: Bool { perform != nil && state.redo }
    override func undo() { perform?(false) }
    override func undoNestedGroup() { perform?(false) }
    override func redo() { perform?(true) }
}

extension UIResponder {
    /// The current first responder (UIKit has no public getter): an action
    /// sent to nil starts there. Without one it lands on the window or app.
    @MainActor static var currentFirstResponder: UIResponder? {
        FirstResponderProbe.found = nil
        UIApplication.shared.sendAction(#selector(UIResponder.noty_reportFirstResponder), to: nil, from: nil, for: nil)
        let found = FirstResponderProbe.found
        FirstResponderProbe.found = nil
        return found is UIWindow || found is UIApplication ? nil : found
    }
    @objc fileprivate func noty_reportFirstResponder() { FirstResponderProbe.found = self }
}
@MainActor private enum FirstResponderProbe { static weak var found: UIResponder? }

// Ink needs first-responder status (Pencil interactions, system undo), but must
// never summon a software keyboard through the responder chain when selecting strokes.
final class DrawingCanvasView: PKCanvasView {
    private let emptyInputView = UIView(frame: .zero)
    weak var notebookUndo: UndoManager?
    override var undoManager: UndoManager? { notebookUndo }
    override var inputView: UIView? { emptyInputView }
    override var inputAccessoryView: UIView? { nil }
    // Native canvas viewport changes must never scroll the containing notebook.
    override func scrollRectToVisible(_ rect: CGRect, animated: Bool) { }
}

final class WorksheetView: UIView, PKCanvasViewDelegate, UIPencilInteractionDelegate {
    private static let renderLog = Logger(subsystem: "de.la.noty", category: "editor-performance")
    private let paperBackground = PaperBackgroundView()
    /// Only for the read tool (PDF text selection/links), created on first use.
    /// Normal display uses `pdfRaster`: PDFKit stalled the main thread for
    /// seconds when zoomed.
    private var pdfView: PDFView?
    private let pdfRaster = PDFSourceRasterView()
    private var pdfDocument: PDFDocument?
    let canvas = DrawingCanvasView()
    private let imageLayer = ImageObjectLayer()
    let shapeLayer = ShapeObjectLayer()
    private let objectLayer = ObjectEditingLayer()
    private let textLayer = TextObjectLayer()
    private let hitHighlight = UIView()
    private var sourceDark = false
    private var sourceDarkCalculated = false
    private var automaticPen = false
    private var darkMargin = false
    var configuredWidth: CGFloat = 2
    private var markerStraight = false
    var markerTip = MarkerTip.round
    private var scribbleErase = true
    /// Whole-stroke eraser gesture: marked strokes are only dimmed (never
    /// published, saved or recorded) and removed together on lift.
    struct EraseSession {
        var base: PageContent
        var strokes: [PKStroke]
        var polylines: [Int: [PagePoint]] = [:]
        var marked = Set<Int>()
        var shapes = Set<UUID>()
        var last: PagePoint?
    }
    var eraseSession: EraseSession?
    /// Precision eraser gesture: shapes it touched (dimmed, removed on lift).
    struct ShapeEraseSession {
        var shapes: [ShapeObject]
        var hit = Set<UUID>()
        var last: PagePoint?
    }
    var shapeErase: ShapeEraseSession?
    /// Soft trail of the "Ganz" eraser: exactly the hit width, recent part only.
    let eraseTrail = CAShapeLayer()
    var trailPoints: [(point: CGPoint, time: CFTimeInterval)] = []
    var trailLink: CADisplayLink?
    private var automaticInkPoint: CGPoint?
    private var worksheetFocused = true
    private var touching = false
    private var textEditing = false
    var hasLiveInput: Bool { touching || textEditing }
    var editingCaret: CGRect? { textLayer.editingCaret.map { textLayer.convert($0, to: self) } }
    /// Why the caret last moved (typing, typewriter, navigation); read once per reveal.
    func takeCaretReveal() -> CaretReveal? { textLayer.takeCaretReveal() }
    private var onRevealCaret: (() -> Void)?
    private var pageID: UUID?
    var pageLayout = PageLayout(source: .testPaper, legacyA4: true)
    private var lastDrawing = Data()
    /// Stroke count of the published drawing bytes, so a finished stroke needs
    /// no decode of the previous state. Keyed by the bytes: any external
    /// configure, undo or page change invalidates it by itself.
    private var strokeCountCache: (data: Data, count: Int)?
    /// Canonical bytes the canvas shows when it was last set from data; nil
    /// after native strokes and derived previews (erase dimming, selection
    /// remainder). Object previews compare against it instead of decoding the
    /// drawing on every pan event.
    var canvasSource: Data?
    var updating = false
    var tool = EditorTool.pen
    var editable = false
    private var lastTool: EditorTool?
    var lastColor: UIColor?
    private var lastWidth: CGFloat = 0
    private var contentGeneration = 0
    private let undoForwarder = NotebookUndoForwarder()
    var onInkSession: (() -> Void)?
    private var onDrawing: ((Data) -> Void)?
    var pageContent = PageContent(page: Page())
    var onContent: ((PageContent, PageContent) -> Bool)?
    var onEraseShapes: ((PageContent, PageContent) -> Bool)?
    private var onPencilAction: (() -> Void)?
    private var onPencilSqueeze: ((PencilSqueezeEvent) -> Void)?
    var holdEnabled = true
    var holdPoints: [PagePoint] = []
    var holdBase: PageContent?
    var heldShape: RecognizedShape?
    /// Live resize of the recognised shape until the Pencil lifts.
    var heldAdjustment: HeldShapeAdjustment?
    var heldColor = InkColor(0, 0, 0)
    /// Drawn width (from PencilKit's own points) for the preview and shape objects.
    var heldWidth: CGFloat = 2
    /// Ratio of PencilKit's drawn point size to the tool width, per ink type.
    var drawnWidthRatio: [PKInk.InkType: CGFloat] = [:]
    var holdSerial = 0
    var holdCompletion = StrokeCompletionGate()
    let heldInkImage = UIImageView()
    let heldShapeLayer = CAShapeLayer()
    var holdFeedback: UIFeedbackGenerator?
    private let holdGesture = PencilHoldGesture()
    private let checkboxTap = CheckboxTapGesture()
    private let interactionObserver = PageInteractionObserver()
    private let interactionID = UUID()
    private let textInteractionID = UUID()
    private var onInteraction: ((UUID, Bool) -> Void)?
    var inkActive = false
    var renderViewport: InkRenderViewport?
    private var configuration: PageEditor?
    private var lastObjectPreview: PageContent?
    private let selectionInkImage = UIImageView()
    private var selectionInkSource: Data?
    private var selectionInkIndices = Set<Int>()
    private var selectionInkFrame = CGRect.zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .white
        layer.allowsEdgeAntialiasing = false; layer.edgeAntialiasingMask = []
        overrideUserInterfaceStyle = .light
        clipsToBounds = true
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.drawingPolicy = .pencilOnly
        canvas.isScrollEnabled = false
        canvas.pinchGestureRecognizer?.isEnabled = false
        canvas.bounces = false; canvas.bouncesZoom = false
        canvas.delegate = self
        canvas.notebookUndo = undoForwarder; objectLayer.notebookUndo = undoForwarder; textLayer.notebookUndo = undoForwarder
        holdGesture.cancelsTouchesInView = false
        holdGesture.delaysTouchesBegan = false; holdGesture.delaysTouchesEnded = false
        holdGesture.onHold = { [weak self] in
            self?.previewHeldStroke()
        }
        holdGesture.onPoint = { [weak self] point in
            guard let self else { return }
            let location = self.canvas.convert(point, to: self)
            let canonical = location.applying(self.pageLayout.inkTranslation.inverted())
            self.holdPoints.append(.init(x: canonical.x, y: canonical.y))
            // Pencil still down after recognition: the held shape follows the tip
            // (line end; arrows/closed shapes scale, `HeldShapeAdjustment`).
            // A line/arrow end follows the tip up to the page edge, also beyond it.
            if let adjustment = self.heldAdjustment, self.heldShape != nil {
                let shape = adjustment.shape(at: .init(x: canonical.x, y: canonical.y))
                if let fitted = self.fittedHeld(shape, width: self.heldWidth, allowShift: false), fitted != self.heldShape {
                    self.heldShape = fitted; self.updateHeldPath()
                }
            }
            if self.eraseSession != nil { self.eraseSweep(to: .init(x: canonical.x, y: canonical.y)) }
            if self.shapeErase != nil { self.precisionShapeSweep(to: .init(x: canonical.x, y: canonical.y)) }
        }
        holdGesture.onBegin = { [weak self] point in
            guard let self else { return }
            self.commitPendingHeldStroke()
            self.cancelErase(); self.cancelShapeErase()
            if self.editable, self.tool == .strokeEraser { self.beginErase() }
            if self.editable, self.tool == .precisionEraser { self.beginShapeErase() }
            let base = self.inkActive ? (self.holdBase ?? self.pageContent) : self.pageContent
            self.clearHeldPreview(); self.holdSerial += 1; self.holdPoints = []
            self.holdBase = base
            self.automaticInkPoint = self.canvas.convert(point, to: self)
            self.updateInkTool(at: self.automaticInkPoint!)
            if #available(iOS 17.5, *) {
                if self.holdFeedback == nil { self.holdFeedback = UICanvasFeedbackGenerator(view: self) }
                self.holdFeedback?.prepare()
            }
        }
        holdGesture.onEnd = { [weak self] cancelled in
            guard let self else { return }
            if self.eraseSession != nil { if cancelled { self.cancelErase() } else { self.finishErase() } }
            if self.shapeErase != nil { if cancelled { self.cancelShapeErase() } else { self.finishShapeErase() } }
            if cancelled { self.clearHeldPreview(); return }
            self.holdCompletion.lift()
            let serial = self.holdSerial
            self.finishHeldStroke(serial: serial)
            // PencilKit may report its final drawing before the tool-end
            // callback; then no further change arrives. Commit the held line
            // once the finished stroke is on the canvas; a cancelled native
            // interaction without a stroke keeps its freehand ink instead.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) { [weak self] in
                guard let self, self.holdSerial == serial, self.heldShape != nil,
                      self.holdCompletion.lifted, !self.inkActive else { return }
                self.commitPendingHeldStroke()
                if self.heldShape != nil { self.clearHeldPreview(); self.canvasViewDrawingDidChange(self.canvas) }
            }
        }
        canvas.addGestureRecognizer(holdGesture)
        checkboxTap.accepts = { [weak self] point in
            guard let self, self.editable, [.pen, .pencil, .marker, .text, .read].contains(self.tool) else { return false }
            return self.textLayer.hasCheckbox(at: self.convert(point, to: self.textLayer))
        }
        checkboxTap.onTap = { [weak self] point in
            guard let self else { return }
            self.textLayer.tapCheckbox(at: self.convert(point, to: self.textLayer))
        }
        addGestureRecognizer(checkboxTap)
        canvas.drawingGestureRecognizer.require(toFail: checkboxTap)
        interactionObserver.cancelsTouchesInView = false
        interactionObserver.delaysTouchesBegan = false; interactionObserver.delaysTouchesEnded = false
        interactionObserver.onChange = { [weak self] active in
            guard let self else { return }; self.touching = active; self.onInteraction?(self.interactionID, active)
        }
        addGestureRecognizer(interactionObserver)
        textLayer.onEditingActive = { [weak self] active in
            guard let self else { return }; self.textEditing = active; self.onInteraction?(self.textInteractionID, active)
            // A field that stopped editing leaves no first responder; ⌘Z keeps working.
            if !active { DispatchQueue.main.async { [weak self] in self?.claimUndoResponder() } }
        }
        textLayer.onCaretChanged = { [weak self] in self?.onRevealCaret?() }
        objectLayer.onPreview = { [weak self] content in self?.showObjectPreview(content) }
        objectLayer.onInkPreview = { [weak self] data, indices, transform in
            self?.showSelectionInk(data, indices: indices, transform: transform)
        }
        let interaction = UIPencilInteraction(); interaction.delegate = self; addInteraction(interaction)
        PencilLocationTracker.shared.observe(self)
        [paperBackground, pdfRaster, imageLayer, shapeLayer, canvas, textLayer, objectLayer, hitHighlight].forEach { addSubview($0) }
        selectionInkImage.isUserInteractionEnabled = false; selectionInkImage.isHidden = true
        insertSubview(selectionInkImage, aboveSubview: canvas)
        heldInkImage.isUserInteractionEnabled = false; heldInkImage.isHidden = true
        insertSubview(heldInkImage, aboveSubview: canvas)
        layer.insertSublayer(heldShapeLayer, above: heldInkImage.layer)
        heldShapeLayer.fillColor = UIColor.clear.cgColor; heldShapeLayer.lineCap = .round; heldShapeLayer.lineJoin = .round
        heldShapeLayer.isHidden = true
        layer.addSublayer(eraseTrail)
        eraseTrail.fillColor = UIColor.clear.cgColor; eraseTrail.lineCap = .round; eraseTrail.lineJoin = .round
        eraseTrail.strokeColor = UIColor(white: 0.55, alpha: 0.35).cgColor; eraseTrail.isHidden = true
        hitHighlight.isUserInteractionEnabled = false; hitHighlight.backgroundColor = UIColor.systemYellow.withAlphaComponent(0.22)
        hitHighlight.layer.borderColor = UIColor.systemOrange.cgColor; hitHighlight.layer.borderWidth = 2
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Latest committed object content (may be newer than the last SwiftUI configuration).
    var objectContent: PageContent { objectLayer.currentContent }
    var objectLayout: PageLayout { pageLayout }
    var objectPageID: UUID? { pageID }
    /// Installs the result of an atomic cross-page transfer before SwiftUI
    /// publishes it, so the next configure keeps the object history.
    func adoptTransfer(_ value: PageContent, selecting selection: TransferredSelection? = nil) {
        pageContent = value
        objectLayer.adoptTransfer(value, selecting: selection)
    }
    func insertText(at point: CGPoint) { textLayer.insertText(at: point) }
    /// Frame (sheet coordinates) of an image just added with the image tool.
    func takeInsertedImage() -> CGRect? { imageLayer.takeInsertedImage().map { imageLayer.convert($0, to: self) } }
    func focusText(_ focus: TextFlowFocus) { textLayer.applyTextFocus(focus) }
    func finishTextEditing() { textLayer.endTextEditing() }
    /// PencilKit's private ruler recognizers (moved/rotated with two fingers).
    /// The notebook's own pan/pinch must wait for them, otherwise the outer
    /// scroll view swallows every ruler gesture.
    var rulerGestureRecognizers: [UIGestureRecognizer] {
        guard canvas.isRulerActive else { return [] }
        var result: [UIGestureRecognizer] = []
        func collect(_ view: UIView) {
            for gesture in view.gestureRecognizers ?? [] where NSStringFromClass(type(of: gesture)).localizedCaseInsensitiveContains("ruler") {
                result.append(gesture)
            }
            view.subviews.forEach(collect)
        }
        collect(canvas)
        return result
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        HangProbe.hit("Sheet.layoutSubviews")
        paperBackground.paperBounds = bounds
        if let viewport = renderViewport {
            paperBackground.frame = viewport.frame.cgRect
            paperBackground.bounds = viewport.frame.cgRect
        } else { paperBackground.frame = bounds }
        if pdfRaster.frame != bounds { pdfRaster.frame = bounds }
        if let pdfView, !pdfView.isHidden {
            let frame = pageLayout.sourceFrame.cgRect
            if pdfView.frame != frame {
                pdfView.frame = frame; pdfView.layoutIfNeeded(); lockPDFScrolling(in: pdfView)
            }
        }
        if renderViewport == nil {
            canvas.transform = .identity
            if canvas.frame != bounds { canvas.frame = bounds }
            if canvas.contentSize != bounds.size { canvas.contentSize = bounds.size }
        }
        if textLayer.frame != bounds { textLayer.frame = bounds }
        // A full-page transparent bitmap grows quadratically at high zoom.
        // Non-text planes use the same bounded page-coordinate viewport as ink.
        let planeBounds = renderViewport?.frame.cgRect ?? bounds
        for plane in [imageLayer, shapeLayer, objectLayer] {
            if plane.frame != planeBounds || plane.bounds != planeBounds {
                plane.bounds = planeBounds; plane.center = CGPoint(x: planeBounds.midX, y: planeBounds.midY)
                plane.setNeedsDisplay()
            }
        }
    }

    /// `live`: a pinch or snap animation is running. Re-tiling PencilKit at every
    /// resolution step mid-gesture showed stale, shifted ink; keep the raster
    /// (magnified) unless the visible area is no longer covered at all.
    func updateRendering(visible: CGRect, scale: CGFloat, live: Bool = false) {
        guard !inkActive, bounds.intersects(visible), bounds.width > 0, bounds.height > 0 else { return }
        // Text keeps its own zoom-resolution viewport (not capped like ink).
        textLayer.updateDisplay(visible: visible, scale: scale, screenScale: window?.screen.scale ?? 2, live: live)
        let page = PageSize(width: bounds.width, height: bounds.height)
        let resolution = EditorRenderGeometry.inkScale(displayScale: scale)
        if renderViewport?.covers(PageRect(visible), page: page, scale: resolution, ignoringScale: live) == true { return }
        let viewport = InkRenderViewport(page: page, visible: PageRect(visible), scale: resolution)
        guard viewport != renderViewport else { return }
        HangProbe.hit("Sheet.inkViewport")
        let started = HangProbe.isInstalled ? CACurrentMediaTime() : nil
        defer {
            if let started, CACurrentMediaTime() - started > 0.016 {
                let elapsed = CACurrentMediaTime() - started
                Self.renderLog.notice("Ink viewport update \(Int(elapsed * 1000), privacy: .public) ms; scale=\(viewport.scale, privacy: .public) native=\(Int(viewport.nativeSize.width), privacy: .public)x\(Int(viewport.nativeSize.height), privacy: .public) live=\(live, privacy: .public)")
            }
        }
        let scaleChanged = renderViewport?.scale != viewport.scale
        renderViewport = viewport
        let wasUpdating = updating; updating = true
        UIView.performWithoutAnimation {
            let s = viewport.scale
            self.canvas.bounds.size = viewport.nativeSize.cgSize
            self.canvas.maximumZoomScale = max(s, self.canvas.minimumZoomScale)
            self.canvas.minimumZoomScale = s; self.canvas.maximumZoomScale = s
            if self.canvas.zoomScale != s { self.canvas.setZoomScale(s, animated: false) }
            // The transient max > min above may create/enable PencilKit's own pinch;
            // it must never compete with the notebook's two-finger zoom.
            self.canvas.pinchGestureRecognizer?.isEnabled = false
            self.canvas.contentSize = CGSize(width: self.bounds.width * s, height: self.bounds.height * s)
            self.canvas.contentOffset = CGPoint(x: viewport.nativeOffset.x, y: viewport.nativeOffset.y)
            self.canvas.transform = CGAffineTransform(scaleX: 1 / s, y: 1 / s)
            self.canvas.center = CGPoint(x: viewport.frame.x + viewport.frame.width / 2, y: viewport.frame.y + viewport.frame.height / 2)
            let retina = self.window?.screen.scale ?? 2
            if !self.pdfRaster.isHidden {
                self.pdfRaster.updateDetail(region: viewport.frame.cgRect, pixelScale: s * retina)
            }
            if scaleChanged { self.paperBackground.contentScaleFactor = s * retina }
            for plane in [self.imageLayer, self.shapeLayer, self.objectLayer] {
                let factor = EditorRenderGeometry.viewportScale(size: viewport.frame.size, displayScale: s, screenScale: retina)
                if abs(plane.contentScaleFactor - factor) > 0.01 { plane.contentScaleFactor = factor; plane.setNeedsDisplay() }
            }
            self.setNeedsLayout()
        }
        updating = wasUpdating
    }

    /// Memory warning: drop what is rebuilt on demand (hidden read-tool
    /// PDFView and its PDF copy, decoded selection ink, unused text views).
    func releaseMemory() {
        if let pdfView, pdfView.isHidden { pdfView.document = nil; pdfView.removeFromSuperview(); self.pdfView = nil }
        if tool != .read, configuration?.sourcePage != nil { pdfDocument = nil }
        objectLayer.releaseMemory()
        textLayer.releaseMemory()
    }
    /// The read tool's PDFView, built when first needed (most sheets never are).
    private func reader() -> PDFView {
        if let pdfView { return pdfView }
        let view = PDFView()
        view.displayMode = .singlePage; view.autoScales = true; view.backgroundColor = .white
        view.displaysPageBreaks = false; view.pageBreakMargins = .zero; view.pageShadowsEnabled = false
        view.displayBox = .cropBox; view.isHidden = true
        insertSubview(view, aboveSubview: pdfRaster)
        pdfView = view
        return view
    }
    private func lockPDFScrolling(in view: UIView) {
        for child in view.subviews {
            if let scroll = child as? UIScrollView {
                scroll.isScrollEnabled = false
                scroll.pinchGestureRecognizer?.isEnabled = false
            }
            lockPDFScrolling(in: child)
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        interactionObserver.isEnabled = window != nil
        if window == nil { cancelErase(); cancelShapeErase() }
        if window == nil { onInteraction?(textInteractionID, false) }
        updateInputMode()
    }

    /// The sheet already shows exactly `editor` (callbacks and undo availability
    /// aside), including local edits the model accepted. Rejected local edits
    /// differ and are reset by a full `configure`, as before.
    func matches(_ editor: PageEditor) -> Bool {
        guard let current = configuration, current.hasSameSettings(as: editor),
              lastDrawing == editor.drawing, pageContent.drawing == editor.drawing, pageContent.shapes == editor.shapes,
              pageContent.textBoxes == editor.textBoxes, pageContent.images == editor.images else { return false }
        return textLayer.shows(editor.textBoxes) && imageLayer.shows(editor.images)
    }
    /// A configuration that `matches`: only its callbacks and undo state are
    /// new (save status, undo availability), so no page work is done.
    func adoptCallbacks(_ editor: PageEditor) {
        configuration = editor
        undoForwarder.perform = editor.onUndo; undoForwarder.state = editor.undoState
        onInkSession = editor.onInkSession; onDrawing = editor.onDrawing; onRevealCaret = editor.onRevealCaret
        onInteraction = editor.onInteraction; onContent = editor.onContent; onEraseShapes = editor.onEraseShapes
        onPencilAction = editor.onPencilAction; onPencilSqueeze = editor.onPencilSqueeze
        textLayer.onFlowChange = editor.onFlowEdit; textLayer.onFlowUndo = editor.onFlowUndo
        textLayer.onFlowBackspace = editor.onFlowBackspace; textLayer.onUndoBoundary = editor.onUndoBoundary
        textLayer.readCurrentBoxes = editor.readTextBoxes; textLayer.readFlowText = editor.readFlowText
        textLayer.adoptCallback(editor.onTextBoxes)
        imageLayer.adoptCallbacks(onChange: editor.onImages, onError: editor.onError)
        objectLayer.adoptCommit(editor.onContent)
    }

    func configure(_ editor: PageEditor) {
        HangProbe.hit("Sheet.configure")
        updating = true
        configuration = editor
        lastObjectPreview = nil
        let first = pageID != editor.pageID
        undoForwarder.perform = editor.onUndo; undoForwarder.state = editor.undoState
        onInkSession = editor.onInkSession
        let focusChanged = worksheetFocused != editor.focused
        worksheetFocused = editor.focused
        let policy: PKCanvasViewDrawingPolicy = editor.fingerDrawing ? .anyInput : .pencilOnly
        if canvas.drawingPolicy != policy { canvas.drawingPolicy = policy }
        holdGesture.allowFinger = editor.fingerDrawing
        // One ruler: only on the focused sheet; it follows the active page.
        let rulerActive = editor.ruler && editor.focused
        if canvas.isRulerActive != rulerActive { canvas.isRulerActive = rulerActive }
        defer { updating = false; objectLayer.publishPreview(ifTransientOnly: true) }
        // Search/task jump marker: shown on arrival, fades when the editor clears
        // it (after 3 s, Feedback 44) instead of staying on the page.
        if let rect = editor.searchHighlight {
            hitHighlight.layer.removeAllAnimations(); hitHighlight.alpha = 1; hitHighlight.isHidden = false
            hitHighlight.frame = rect.cgRect.offsetBy(dx: editor.layout.contentOrigin.x, dy: editor.layout.contentOrigin.y)
        } else if !hitHighlight.isHidden, hitHighlight.alpha > 0.99 {
            UIView.animate(withDuration: UIAccessibility.isReduceMotionEnabled ? 0 : 0.6, delay: 0,
                           options: [.beginFromCurrentState, .allowUserInteraction]) {
                self.hitHighlight.alpha = 0
            } completion: { [weak self] _ in
                guard let self, self.configuration?.searchHighlight == nil else { return }
                self.hitHighlight.isHidden = true; self.hitHighlight.alpha = 1
            }
        }
        onDrawing = editor.onDrawing
        onRevealCaret = editor.onRevealCaret
        onInteraction = editor.onInteraction
        onContent = editor.onContent; onEraseShapes = editor.onEraseShapes; onPencilAction = editor.onPencilAction; onPencilSqueeze = editor.onPencilSqueeze; holdEnabled = editor.recognizeShapes; markerStraight = editor.markerStraight
        scribbleErase = editor.scribbleErase
        let originChanged = pageLayout.contentOrigin != editor.layout.contentOrigin
        let layoutChanged = pageLayout != editor.layout
        let contentReplaced = contentGeneration != editor.contentGeneration
        if let session = eraseSession, first || contentReplaced || layoutChanged || !editor.enabled || editor.tool != .strokeEraser
            || editor.drawing != session.base.drawing || editor.shapes != session.base.shapes { cancelErase() }
        if let session = shapeErase, first || contentReplaced || layoutChanged || !editor.enabled || editor.tool != .precisionEraser
            || editor.shapes != session.shapes { cancelShapeErase() }
        if first || contentReplaced || layoutChanged || !editor.enabled || editor.tool != tool {
            holdSerial += 1; clearHeldPreview()
        }
        contentGeneration = editor.contentGeneration
        pageLayout = editor.layout
        if layoutChanged { renderViewport = nil }
        backgroundColor = (editor.margins?.color ?? editor.paperColor) == .dark ? .black : .white
        let hasSource = editor.sourcePage != nil || editor.paper == .legacyTest
        let readMode = hasSource && editor.tool == .read
        if readMode { reader().isHidden = false } else { pdfView?.isHidden = true }
        pdfRaster.isHidden = !hasSource || readMode
        paperBackground.configure(style: editor.margins?.style ?? (editor.sourcePage == nil ? editor.paper : .blank),
                                  color: editor.margins?.color ?? editor.paperColor, coordinateScale: pageLayout.writingCoordinateScale,
                                  columns: editor.sourcePage == nil ? nil : pageLayout.ruledColumnsBesidePDF)
        if pageID != editor.pageID {
            pageID = editor.pageID
            sourceDark = editor.paperColor == .dark; sourceDarkCalculated = false
            // Source PDF pages are rastered from their CGPDFPage directly; the
            // PDFKit copy is only needed for the read tool and built on demand.
            pdfDocument = nil
            if editor.sourcePage == nil, hasSource,
               let page = PDFExporter.paperPDF(style: editor.paper, size: editor.layout.contentCanvas, color: editor.paperColor).page(at: 0) {
                let document = PDFDocument(); document.insert(page, at: 0); pdfDocument = document
            }
        }
        if readMode, pdfDocument == nil, let page = editor.sourcePage?.copy() as? PDFPage {
            if let ref = page.pageRef, let geometry = try? PDFPageGeometry(ref) {
                page.setBounds(geometry.effectiveCrop.cgRect, for: .cropBox)
            }
            let document = PDFDocument(); document.insert(page, at: 0); pdfDocument = document
        }
        if pdfRaster.configure(page: hasSource ? (editor.sourcePage?.pageRef ?? pdfDocument?.page(at: 0)?.pageRef) : nil,
                               layout: pageLayout) { renderViewport = nil }
        // A detached document keeps PDFKit from tiling while it is not shown.
        let shownDocument = readMode ? pdfDocument : nil
        if let pdfView, pdfView.document !== shownDocument {
            pdfView.document = shownDocument
            if readMode {
                pdfView.frame = pageLayout.sourceFrame.cgRect; pdfView.layoutIfNeeded(); lockPDFScrolling(in: pdfView)
            }
        }
        if lastDrawing != editor.drawing || originChanged || contentReplaced {
            if editor.drawing.isEmpty { canvas.drawing = PKDrawing(); canvasSource = editor.drawing; strokeCountCache = (editor.drawing, 0) }
            else if let drawing = try? PKDrawing(data: editor.drawing) {
                strokeCountCache = (editor.drawing, drawing.strokes.count)
                canvas.drawing = drawing.transformed(using: pageLayout.inkTranslation); canvasSource = editor.drawing
            }
            lastDrawing = editor.drawing
        }
        let modeChanged = tool != editor.tool || editable != editor.enabled
        tool = editor.tool
        editable = editor.enabled
        // Paper pages: automatic ink follows the current paper colour. It was
        // only read on a page change, so after "Ganzes Notizbuch umstellen"
        // (same page, new colour) the pen kept writing invisible ink.
        if editor.sourcePage == nil, sourceDark != (editor.paperColor == .dark) { sourceDark = editor.paperColor == .dark }
        if editor.autoPen, tool == .pen || tool == .pencil || tool == .shape, !sourceDarkCalculated {
            sourceDarkCalculated = true
            if editor.sourcePage == nil { sourceDark = editor.paperColor == .dark }
            else {
                // Measured off the main thread; the colour follows when known.
                let page = pageID
                pdfRaster.measureDarkness { [weak self] dark in
                    guard let self, self.pageID == page, self.sourceDarkCalculated, self.sourceDark != dark else { return }
                    self.sourceDark = dark; self.refreshAutomaticInk()
                }
            }
        }
        automaticPen = editor.autoPen; darkMargin = editor.margins?.color == .dark
        configuredWidth = editor.width
        let lightInk = automaticInkPoint.map(automaticInkIsLight) ?? sourceDark
        let inkColor = automaticPen && (tool == .pen || tool == .pencil) ? (lightInk ? UIColor.white : UIColor.black) : editor.color
        let tipChanged = markerTip != editor.markerTip
        markerTip = editor.markerTip
        if lastTool != tool || lastColor != inkColor || lastWidth != editor.width || (tool == .marker && tipChanged) {
            switch tool {
            case .pen: canvas.tool = PKInkingTool(.pen, color: inkColor, width: editor.width)
            // Round tip: monoline (iOS 17, round caps, constant width); chisel: native marker.
            case .marker: canvas.tool = inkingTool(color: inkColor, width: editor.width)
            // Real pencil: PencilKit's textured graphite with pressure and broad tilt shading.
            case .pencil: canvas.tool = inkingTool(color: inkColor, width: editor.width)
            case .strokeEraser: canvas.tool = PKEraserTool(.vector)
            case .precisionEraser: canvas.tool = PKEraserTool(.fixedWidthBitmap, width: editor.width)
            case .inkSelection: break
            case .text, .image, .shape, .selection, .read, .laser: break
            }
            lastTool = tool
            lastColor = inkColor
            lastWidth = editor.width
        }
        textLayer.onFlowChange = editor.onFlowEdit
        textLayer.onFlowUndo = editor.onFlowUndo
        textLayer.onFlowBackspace = editor.onFlowBackspace
        textLayer.onUndoBoundary = editor.onUndoBoundary
        textLayer.readCurrentBoxes = editor.readTextBoxes
        textLayer.readFlowText = editor.readFlowText
        textLayer.configure(boxes: editor.textBoxes, pageID: editor.pageID, layout: editor.layout,
                            contentGeneration: editor.contentGeneration, active: editable && tool == .text, readOnly: editable && tool == .read,
                            darkPaper: editor.paperColor == .dark, darkMargins: editor.margins?.color == .dark,
                            hasPDF: editor.sourcePage != nil, paperStyle: editor.paper, marginStyle: editor.margins?.style ?? .blank,
                            onChange: editor.onTextBoxes)
        imageLayer.configure(objects: editor.images, pageID: editor.pageID, layout: editor.layout,
                             contentGeneration: editor.contentGeneration, active: editable && tool == .image,
                             onChange: editor.onImages, onError: editor.onError)
        var page = Page(); page.drawing = editor.drawing; page.textBoxes = editor.textBoxes
        page.images = editor.images; page.shapes = editor.shapes
        pageContent = PageContent(page: page)
        shapeLayer.configure(editor.shapes, origin: pageLayout.contentOrigin)
        objectLayer.configure(PageContent(page: page), pageID: editor.pageID, layout: editor.layout,
            generation: editor.contentGeneration, tool: tool, enabled: editable, fingerDrawing: editor.fingerDrawing, options: editor.shapeOptions,
            filter: editor.selectionFilter, lassoMode: editor.lassoMode, color: InkColor(Color(editor.color)), width: editor.width, onCommit: editor.onContent)
        // Every aborted lift or object drag (tool change, lost editing right)
        // ends here: the canvas shows the model's ink before the next stroke.
        syncCanvas(to: pageContent.drawing)
        if automaticPen {
            objectLayer.automaticColor = { [weak self] point -> InkColor? in
                guard let self else { return nil }
                let origin = self.pageLayout.contentOrigin
                return self.automaticInkIsLight(at: CGPoint(x: point.x + origin.x, y: point.y + origin.y)) ? InkColor(1, 1, 1) : InkColor(0, 0, 0)
            }
        } else { objectLayer.automaticColor = nil }
        canvas.isUserInteractionEnabled = editable && [.pen, .pencil, .marker, .strokeEraser, .precisionEraser].contains(tool)
        // "Ganz": PencilKit's vector eraser deletes instantly without preview;
        // the app-owned sweep (hold observer) dims first and removes on lift.
        let nativeDrawing = tool != .strokeEraser
        if canvas.drawingGestureRecognizer.isEnabled != nativeDrawing { canvas.drawingGestureRecognizer.isEnabled = nativeDrawing }
        if eraseSession != nil || shapeErase != nil { dimErasedShapes() }
        pdfView?.isUserInteractionEnabled = tool == .read
        if modeChanged || focusChanged || first { updateInputMode() }
        setNeedsLayout()
    }

    private func showObjectPreview(_ content: PageContent) {
        guard !updating, let editor = configuration, tool == .selection || tool == .inkSelection || tool == .shape,
              lastObjectPreview != content else { return }
        lastObjectPreview = content
        shapeLayer.configure(content.shapes, origin: pageLayout.contentOrigin)
        updating = true
        defer { updating = false }
        // Shape/object drags publish the same ink bytes on every pan event.
        if selectionInkSource == nil, canvasSource != content.drawing, let drawing = try? PKDrawing(data: content.drawing) {
            canvas.drawing = drawing.transformed(using: pageLayout.inkTranslation); canvasSource = content.drawing
        }
        textLayer.configure(boxes: content.textBoxes, pageID: editor.pageID, layout: editor.layout,
            contentGeneration: editor.contentGeneration, active: false,
            darkPaper: editor.paperColor == .dark, darkMargins: editor.margins?.color == .dark,
            hasPDF: editor.sourcePage != nil, paperStyle: editor.paper, marginStyle: editor.margins?.style ?? .blank,
            onChange: editor.onTextBoxes)
        imageLayer.configure(objects: content.images, pageID: editor.pageID, layout: editor.layout,
            contentGeneration: editor.contentGeneration, active: false, onChange: editor.onImages, onError: editor.onError)
    }

    private func showSelectionInk(_ data: Data, indices: Set<Int>, transform: CGAffineTransform?) {
        let previous = updating; updating = true
        defer { updating = previous }
        guard let transform, !indices.isEmpty else {
            if selectionInkSource != nil {
                canvas.drawing = ((try? PKDrawing(data: data)) ?? PKDrawing()).transformed(using: pageLayout.inkTranslation)
                canvasSource = data
            }
            selectionInkSource = nil; selectionInkIndices = []
            selectionInkImage.isHidden = true; selectionInkImage.image = nil
            // A lift ended without a drop (tool change during it) still shows
            // only the remainder; `data` is the committed ink again.
            syncCanvas(to: data)
            return
        }
        if selectionInkSource != data || selectionInkIndices != indices {
            guard let drawing = try? PKDrawing(data: data) else { return }
            let selected = PKDrawing(strokes: drawing.strokes.enumerated().filter { indices.contains($0.offset) }.map(\.element))
            let frame = selected.bounds
            guard !frame.isEmpty, !frame.isNull else { return }
            // Capture native ink once; pan/resize changes only this view's affine
            // transform. No PKDrawing serialization or decoding per move event.
            let scale = min(window?.screen.scale ?? 2, 2048 / max(frame.width, frame.height))
            // The callback originates on the dark selection menu. Use the
            // canvas appearance rather than that ambient trait environment.
            canvas.traitCollection.performAsCurrent {
                selectionInkImage.image = selected.image(from: frame, scale: scale).withRenderingMode(.alwaysOriginal)
            }
            selectionInkFrame = frame
            selectionInkSource = data; selectionInkIndices = indices
            let remainder = PKDrawing(strokes: drawing.strokes.enumerated().filter { !indices.contains($0.offset) }.map(\.element))
            canvas.drawing = remainder.transformed(using: pageLayout.inkTranslation); canvasSource = nil
        }
        let center = CGPoint(x: selectionInkFrame.midX, y: selectionInkFrame.midY).applying(transform)
        selectionInkImage.transform = .identity
        selectionInkImage.bounds = CGRect(origin: .zero, size: selectionInkFrame.size)
        selectionInkImage.center = CGPoint(x: center.x + pageLayout.contentOrigin.x, y: center.y + pageLayout.contentOrigin.y)
        selectionInkImage.transform = CGAffineTransform(a: transform.a, b: transform.b, c: transform.c, d: transform.d, tx: 0, ty: 0)
        selectionInkImage.isHidden = false
    }

    /// Puts `data` (canonical; normally the model's ink) back on the canvas
    /// when it shows anything else while nothing transient is on screen.
    private func syncCanvas(to data: Data) {
        let transient = heldShape != nil || eraseSession != nil || selectionInkSource != nil || objectLayer.showsTransientPreview
        guard EditorInteractionPolicy.canvasNeedsReset(shown: canvasSource, model: data, stroke: inkActive, transient: transient),
              let drawing = data.isEmpty ? PKDrawing() : try? PKDrawing(data: data) else { return }
        let wasUpdating = updating; updating = true
        canvas.drawing = drawing.transformed(using: pageLayout.inkTranslation); canvasSource = data
        updating = wasUpdating
    }

    private func updateInputMode() {
        guard window != nil else { return }
        HangProbe.hit("Sheet.updateInputMode")
        if editable && worksheetFocused && [.pen, .pencil, .marker, .strokeEraser, .precisionEraser].contains(tool) {
            textLayer.endTextEditing()
            canvas.becomeFirstResponder()
            canvas.reloadInputViews()
        } else {
            canvas.resignFirstResponder()
            if tool != .text { textLayer.endTextEditing() }
            claimUndoResponder()
        }
    }
    // Undo in every mode: the responder chain of all page layers (PDFView,
    // image plane, text fields) ends here, in the notebook history.
    override var undoManager: UndoManager? { undoForwarder }
    override var canBecomeFirstResponder: Bool { editable && worksheetFocused && window != nil }
    /// ⌘Z/⇧⌘Z and the undo gestures need a first responder. Ink tools use the
    /// canvas and active selections the object layer (its key commands); in
    /// the other modes (image, laser, read, text tool between fields) the
    /// focused sheet itself. Text input anywhere and this page's own layers
    /// keep their focus.
    private func claimUndoResponder() {
        guard window != nil else { return }
        guard editable, worksheetFocused else { if isFirstResponder { resignFirstResponder() }; return }
        let target: UIResponder = [.pen, .pencil, .marker, .strokeEraser, .precisionEraser].contains(tool) ? canvas
            : objectLayer.canBecomeFirstResponder ? objectLayer : self
        guard !target.isFirstResponder else { return }
        if let current = UIResponder.currentFirstResponder {
            if current is UIKeyInput { return }
            if let view = current as? UIView, view.isDescendant(of: self), view !== self { return }
        }
        target.becomeFirstResponder()
    }
    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        HangProbe.hit("Sheet.drawingDidChange")
        if !updating { canvasSource = nil } // native change
        guard !updating, [.pen, .pencil, .marker, .strokeEraser, .precisionEraser].contains(tool) else { return }
        if heldShape != nil {
            holdCompletion.drawingChanged(); finishHeldStroke(serial: holdSerial); return
        }
        // Per stroke: no decode of the published drawing (count cached by its
        // bytes) and exactly one encode of the result.
        let previousCount = publishedStrokeCount
        if tool == .marker, markerStraight { straightenLastMarkerStroke(previousCount: previousCount) }
        if tool == .pen, scribbleErase { eraseByScribble(previousCount: previousCount) }
        let drawing = canvas.drawing, strokes = drawing.strokes
        // A precision eraser that splits a stroke also adds one: no pen width.
        if tool == .pen || tool == .pencil || tool == .marker { recordDrawnWidth(strokes, previousCount: previousCount) }
        lastDrawing = canonicalDrawingData(drawing)
        if eraseSession == nil { strokeCountCache = (lastDrawing, strokes.count); canvasSource = lastDrawing }
        pageContent.drawing = lastDrawing
        onDrawing?(lastDrawing)
    }
    /// Stroke count of `pageContent.drawing`; decoded at most once per distinct value.
    private var publishedStrokeCount: Int {
        let data = pageContent.drawing
        if let cache = strokeCountCache, cache.data == data { return cache.count }
        let count = (try? PKDrawing(data: data))?.strokes.count ?? 0
        strokeCountCache = (data, count)
        return count
    }
    /// The canvas drawing in canonical page coordinates (without paper margins).
    var canonicalCanvasDrawing: PKDrawing {
        let translation = pageLayout.inkTranslation
        return translation.isIdentity ? canvas.drawing : canvas.drawing.transformed(using: translation.inverted())
    }
    /// Straight-highlighter option: replace the stroke just finished with one
    /// snapped straight segment (`MarkerStraightening`), keeping its ink and
    /// the drawn point attributes so it stays exactly as wide and opaque.
    private func straightenLastMarkerStroke(previousCount: Int) {
        let strokes = canonicalCanvasDrawing.strokes
        guard strokes.count == previousCount + 1, let stroke = strokes.last,
              stroke.ink.inkType == .marker || stroke.ink.inkType == .monoline else { return }
        let points = stroke.path.map { $0.location.applying(stroke.transform) }.map { PagePoint(x: $0.x, y: $0.y) }
        guard let line = MarkerStraightening.line(points) else { return }
        // A stroke that ran off the page is straightened up to the edge.
        guard let fitted = HeldShapeFitting.fit(.line(start: line.start, end: line.end), in: PageRect(pageLayout.canonicalInkBounds),
                                                padding: Self.maximumDrawnWidth(stroke) / 2 + 0.05, allowShift: false) else { return }
        let straight = inkStroke(from: stroke, ink: stroke.ink, path: fitted.outline(spacing: 12))
        guard pageLayout.canonicalInkBounds.insetBy(dx: -0.02, dy: -0.02).contains(straight.renderBounds) else { return }
        let wasUpdating = updating; updating = true
        canvas.drawing = PKDrawing(strokes: Array(strokes.dropLast()) + [straight]).transformed(using: pageLayout.inkTranslation)
        canvasSource = nil; updating = wasUpdating
    }
    func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
        inkActive = true
        onInkSession?()
        if heldShape == nil { holdBase = pageContent }
    }
    func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
        inkActive = false
        holdCompletion.endNative()
    }
    func installContent(_ content: PageContent) {
        updating = true
        pageContent = content; lastDrawing = content.drawing
        let drawing = (try? PKDrawing(data: content.drawing)) ?? PKDrawing()
        strokeCountCache = (content.drawing, drawing.strokes.count)
        canvas.drawing = drawing.transformed(using: pageLayout.inkTranslation); canvasSource = content.drawing
        updating = false
    }
    /// Every preloaded sheet owns an interaction; only the focused one may act,
    /// otherwise an even number of sheets toggles the tool back and forth.
    private func pencilAction() { if worksheetFocused, window != nil { onPencilAction?() } }
    /// Double tap follows the system setting (Einstellungen › Apple Pencil):
    /// eraser or previous tool → the app's eraser toggle; colour palette or
    /// ink attributes → the app's own tool palette at the Pencil; off → nothing.
    private func pencilTap(palette: () -> PencilSqueezeEvent) {
        guard worksheetFocused, window != nil else { return }
        switch UIPencilInteraction.preferredTapAction {
        case .ignore: return
        case .switchEraser, .switchPrevious: onPencilAction?()
        case .showColorPalette, .showInkAttributes:
            if let onPencilSqueeze { onPencilSqueeze(palette()) } else { onPencilAction?() }
        default: return // system shortcuts and future actions are handled by iPadOS
        }
    }
    func pencilInteractionDidTap(_ interaction: UIPencilInteraction) { pencilTap { PencilSqueezeEvent(tapIn: self) } }
    @available(iOS 17.5, *)
    func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveTap tap: UIPencilInteraction.Tap) {
        pencilTap { PencilSqueezeEvent(tap: tap, in: self) }
    }
    @available(iOS 17.5, *)
    func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveSqueeze squeeze: UIPencilInteraction.Squeeze) {
        guard let onPencilSqueeze else { if squeeze.phase == .ended { pencilAction() }; return }
        if worksheetFocused, window != nil { onPencilSqueeze(PencilSqueezeEvent(squeeze, in: self)) }
    }
    /// Automatic pen colour after a late PDF darkness result (same rule as configure).
    private func refreshAutomaticInk() {
        guard automaticPen, tool == .pen || tool == .pencil, !inkActive else { return }
        let color: UIColor = (automaticInkPoint.map(automaticInkIsLight) ?? sourceDark) ? .white : .black
        guard lastColor != color else { return }
        canvas.tool = inkingTool(color: color, width: configuredWidth)
        lastColor = color
    }
    private func automaticInkIsLight(at point: CGPoint) -> Bool {
        EditorInteractionPolicy.lightAutomaticInk(at: .init(x: point.x, y: point.y),
            source: PageRect(pageLayout.sourceFrame.cgRect), sourceDark: sourceDark, marginDark: darkMargin)
    }
    /// Automatic pen colour must be on the canvas before PencilKit starts the
    /// stroke: it captures the tool on touch-down. The hold observer's began
    /// callback can arrive after PencilKit's own recognizer, which left the
    /// first stroke in a new page/region (PDF ↔ writing space) in the previous
    /// region's colour. Hit-testing (also for Pencil hover) precedes delivery.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        if let hit, !inkActive, hit === canvas || hit.isDescendant(of: canvas), event?.type == .touches || event?.type == .hover {
            if event?.type == .touches { commitPendingHeldStroke() }
            automaticInkPoint = point; updateInkTool(at: point)
        }
        return hit
    }
    private func updateInkTool(at point: CGPoint) {
        guard automaticPen, tool == .pen || tool == .pencil, !inkActive else { return }
        let color: UIColor = automaticInkIsLight(at: point) ? .white : .black
        guard lastColor != color else { return }
        canvas.tool = inkingTool(color: color, width: configuredWidth)
        lastColor = color
    }
    var inkType: PKInk.InkType {
        tool == .marker ? (markerTip == .round ? .monoline : .marker) : tool == .pencil ? .pencil : .pen
    }
    private func inkingTool(color: UIColor, width: CGFloat) -> PKInkingTool { PKInkingTool(inkType, color: color, width: width) }
    /// `drawing`: the current canvas drawing (display coordinates).
    private func canonicalDrawingData(_ drawing: PKDrawing) -> Data {
        // The dimmed erase preview is display-only and must never be saved.
        if let session = eraseSession { return session.base.drawing }
        let translation = pageLayout.inkTranslation
        if translation.isIdentity { return drawing.dataRepresentation() }
        return drawing.transformed(using: translation.inverted()).dataRepresentation()
    }
}
