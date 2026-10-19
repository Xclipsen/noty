import SwiftUI
import PDFKit
import PencilKit
import NotebookCore
import OSLog

struct PageEditor: UIViewRepresentable {
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
    var fitRequest: Int
    var contentGeneration: Int
    var textInsertRequest: Int
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

    func makeUIView(context: Context) -> ZoomingWorksheet { ZoomingWorksheet() }
    func updateUIView(_ view: ZoomingWorksheet, context: Context) { view.configure(self) }
}

final class ZoomingWorksheet: UIScrollView, UIScrollViewDelegate {
    private let sheet = WorksheetView()
    private var pageID: UUID?
    private var previousSize = CGSize.zero
    private var fitWidth: CGFloat = 1
    private var needsInitialFit = true
    private var fitRequest = 0
    private var textInsertRequest = 0
    private var lastSearch: PageRect?
    private var pendingSearch: CGRect?
    private var imageIDs = Set<UUID>()
    private var adjusting = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self
        backgroundColor = .secondarySystemBackground
        contentInsetAdjustmentBehavior = .never
        keyboardDismissMode = .interactive
        delaysContentTouches = false
        panGestureRecognizer.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        addSubview(sheet)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(_ editor: PageEditor) {
        if lastSearch != editor.searchHighlight || pageID != editor.pageID {
            lastSearch = editor.searchHighlight
            pendingSearch = editor.searchHighlight?.cgRect.offsetBy(dx: editor.layout.contentOrigin.x, dy: editor.layout.contentOrigin.y)
        }
        let incomingImages = Set(editor.images.map(\.id))
        let insertedImage = pageID == editor.pageID && editor.tool == .image
            ? editor.images.last(where: { !imageIDs.contains($0.id) }) : nil
        imageIDs = incomingImages
        let touches = editor.fingerDrawing ? 2 : 1
        if panGestureRecognizer.minimumNumberOfTouches != touches { panGestureRecognizer.minimumNumberOfTouches = touches }
        if pageID != editor.pageID || sheet.bounds.size != editor.layout.canvas.cgSize {
            pageID = editor.pageID
            minimumZoomScale = 0.01
            maximumZoomScale = 12
            setZoomScale(1, animated: false)
            sheet.frame = editor.layout.canvas.bounds
            contentSize = editor.layout.canvas.cgSize
            needsInitialFit = true
        }
        sheet.configure(editor)
        if textInsertRequest != editor.textInsertRequest {
            textInsertRequest = editor.textInsertRequest
            let point = convert(CGPoint(x: bounds.midX, y: bounds.midY), to: sheet)
            sheet.insertText(at: point)
        }
        if fitRequest != editor.fitRequest {
            fitRequest = editor.fitRequest
            needsInitialFit = true
        }
        setNeedsLayout()
        if let image = insertedImage {
            layoutIfNeeded()
            let rect = image.rotatedBounds.cgRect.offsetBy(dx: editor.layout.contentOrigin.x, dy: editor.layout.contentOrigin.y)
            scrollRectToVisible(sheet.convert(rect.insetBy(dx: -24, dy: -24), to: self), animated: true)
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard !adjusting, bounds.width > 40, bounds.height > 40, sheet.bounds.width > 0 else { return }
        if previousSize != bounds.size || needsInitialFit {
            adjusting = true
            let oldSize = previousSize
            let center = CGPoint(x: (contentOffset.x + oldSize.width / 2) / zoomScale,
                                 y: (contentOffset.y + oldSize.height / 2) / zoomScale)
            let relativeZoom = zoomScale / fitWidth
            fitWidth = (bounds.width - 32) / sheet.bounds.width
            minimumZoomScale = min(fitWidth, (bounds.height - 32) / sheet.bounds.height)
            maximumZoomScale = max(fitWidth * 6, 6)
            let desired = needsInitialFit ? fitWidth : fitWidth * relativeZoom
            setZoomScale(min(max(desired, minimumZoomScale), maximumZoomScale), animated: false)
            centerSheet()
            if needsInitialFit {
                contentOffset = CGPoint(x: -contentInset.left, y: -contentInset.top)
            } else {
                let x = center.x * zoomScale - bounds.width / 2
                let y = center.y * zoomScale - bounds.height / 2
                contentOffset = CGPoint(
                    x: min(max(x, -contentInset.left), max(-contentInset.left, contentSize.width - bounds.width + contentInset.right)),
                    y: min(max(y, -contentInset.top), max(-contentInset.top, contentSize.height - bounds.height + contentInset.bottom)))
            }
            previousSize = bounds.size
            needsInitialFit = false
            adjusting = false
        } else { centerSheet() }
        if let target = pendingSearch {
            pendingSearch = nil
            scrollRectToVisible(sheet.convert(target.insetBy(dx: -16, dy: -16), to: self), animated: false)
        }
    }

    private func centerSheet() {
        let horizontal = max(16, (bounds.width - contentSize.width) / 2)
        let vertical = max(16, (bounds.height - contentSize.height) / 2)
        let insets = UIEdgeInsets(top: vertical, left: horizontal, bottom: vertical, right: horizontal)
        if contentInset != insets { contentInset = insets }
    }
    func viewForZooming(in scrollView: UIScrollView) -> UIView? { sheet }
    func scrollViewDidZoom(_ scrollView: UIScrollView) { centerSheet() }
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
    /// Only for the read tool (PDF text selection/links). Normal display uses
    /// `pdfRaster`: PDFKit stalled the main thread for seconds when zoomed.
    private let pdfView = PDFView()
    private let pdfRaster = PDFSourceRasterView()
    private var pdfDocument: PDFDocument?
    private let canvas = DrawingCanvasView()
    private let imageLayer = ImageObjectLayer()
    private let shapeLayer = ShapeObjectLayer()
    private let objectLayer = ObjectEditingLayer()
    private let textLayer = TextObjectLayer()
    private let hitHighlight = UIView()
    private var sourceDark = false
    private var sourceDarkCalculated = false
    private var automaticPen = false
    private var darkMargin = false
    private var configuredWidth: CGFloat = 2
    private var markerStraight = false
    private var markerTip = MarkerTip.round
    private var scribbleErase = true
    /// Whole-stroke eraser gesture: marked strokes are only dimmed (never
    /// published, saved or recorded) and removed together on lift.
    private struct EraseSession {
        var base: PageContent
        var strokes: [PKStroke]
        var polylines: [Int: [PagePoint]] = [:]
        var marked = Set<Int>()
        var shapes = Set<UUID>()
        var last: PagePoint?
    }
    private var eraseSession: EraseSession?
    /// Soft trail of the "Ganz" eraser: exactly the hit width, recent part only.
    private let eraseTrail = CAShapeLayer()
    private var trailPoints: [(point: CGPoint, time: CFTimeInterval)] = []
    private var trailLink: CADisplayLink?
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
    private var pageLayout = PageLayout(source: .testPaper, legacyA4: true)
    private var lastDrawing = Data()
    private var updating = false
    private var tool = EditorTool.pen
    private var editable = false
    private var lastTool: EditorTool?
    private var lastColor: UIColor?
    private var lastWidth: CGFloat = 0
    private var contentGeneration = 0
    private let undoForwarder = NotebookUndoForwarder()
    private var onInkSession: (() -> Void)?
    private var onDrawing: ((Data) -> Void)?
    private var pageContent = PageContent(page: Page())
    private var onContent: ((PageContent, PageContent) -> Bool)?
    private var onPencilAction: (() -> Void)?
    private var onPencilSqueeze: ((PencilSqueezeEvent) -> Void)?
    private var holdEnabled = true
    private var holdPoints: [PagePoint] = []
    private var holdBase: PageContent?
    private var heldShape: RecognizedShape?
    /// Live resize of the recognised shape until the Pencil lifts.
    private var heldAdjustment: HeldShapeAdjustment?
    private var heldColor = InkColor(0, 0, 0)
    /// Drawn width (from PencilKit's own points) for the preview and shape objects.
    private var heldWidth: CGFloat = 2
    /// Ratio of PencilKit's drawn point size to the tool width, per ink type.
    private var drawnWidthRatio: [PKInk.InkType: CGFloat] = [:]
    private var holdSerial = 0
    private var holdCompletion = StrokeCompletionGate()
    private let heldInkImage = UIImageView()
    private let heldShapeLayer = CAShapeLayer()
    private var holdFeedback: UIFeedbackGenerator?
    private let holdGesture = PencilHoldGesture()
    private let checkboxTap = CheckboxTapGesture()
    private let interactionObserver = PageInteractionObserver()
    private let interactionID = UUID()
    private let textInteractionID = UUID()
    private var onInteraction: ((UUID, Bool) -> Void)?
    private var inkActive = false
    private var renderViewport: InkRenderViewport?
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
        pdfView.displayMode = .singlePage
        pdfView.autoScales = true
        pdfView.backgroundColor = .white
        pdfView.displaysPageBreaks = false
        pdfView.pageBreakMargins = .zero
        pdfView.pageShadowsEnabled = false
        pdfView.displayBox = .cropBox
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
            if let adjustment = self.heldAdjustment, self.heldShape != nil {
                let shape = adjustment.shape(at: .init(x: canonical.x, y: canonical.y))
                if shape != self.heldShape, self.heldFits(shape) { self.heldShape = shape; self.updateHeldPath() }
            }
            if self.eraseSession != nil { self.eraseSweep(to: .init(x: canonical.x, y: canonical.y)) }
        }
        holdGesture.onBegin = { [weak self] point in
            guard let self else { return }
            self.commitPendingHeldStroke()
            self.cancelErase()
            if self.editable, self.tool == .strokeEraser { self.beginErase() }
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
        }
        textLayer.onCaretChanged = { [weak self] in self?.onRevealCaret?() }
        objectLayer.onPreview = { [weak self] content in self?.showObjectPreview(content) }
        objectLayer.onInkPreview = { [weak self] data, indices, transform in
            self?.showSelectionInk(data, indices: indices, transform: transform)
        }
        let interaction = UIPencilInteraction(); interaction.delegate = self; addInteraction(interaction)
        PencilLocationTracker.shared.observe(self)
        [paperBackground, pdfRaster, pdfView, imageLayer, shapeLayer, canvas, textLayer, objectLayer, hitHighlight].forEach { addSubview($0) }
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
    func focusText(_ focus: TextFlowFocus) { textLayer.applyTextFocus(focus) }
    func finishTextEditing() { textLayer.endTextEditing() }
    /// PencilKit's private ruler recognizers (moved/rotated with two fingers).
    /// The notebook's own pan/pinch must wait for them, otherwise the outer
    /// scroll view swallows every ruler gesture.
    var rulerGestureRecognizers: [UIGestureRecognizer] {
        guard canvas.isRulerActive else { return [] }
        var result: [UIGestureRecognizer] = []
        var names = Set<String>()
        func collect(_ view: UIView) {
            for gesture in view.gestureRecognizers ?? [] {
                let name = NSStringFromClass(type(of: gesture))
                names.insert(name)
                if name.localizedCaseInsensitiveContains("ruler") { result.append(gesture) }
            }
            view.subviews.forEach(collect)
        }
        collect(canvas)
        if !Self.loggedRulerGestures {
            Self.loggedRulerGestures = true
            Self.renderLog.notice("Canvas gestures with ruler: \(names.sorted().joined(separator: ","), privacy: .public); ruler=\(result.count, privacy: .public)")
        }
        return result
    }
    private static var loggedRulerGestures = false

    override func layoutSubviews() {
        super.layoutSubviews()
        HangProbe.hit("Sheet.layoutSubviews")
        paperBackground.paperBounds = bounds
        if let viewport = renderViewport {
            paperBackground.frame = viewport.frame.cgRect
            paperBackground.bounds = viewport.frame.cgRect
        } else { paperBackground.frame = bounds }
        if pdfRaster.frame != bounds { pdfRaster.frame = bounds }
        if !pdfView.isHidden {
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
        let started = CACurrentMediaTime()
        defer {
            let elapsed = CACurrentMediaTime() - started
            if elapsed > 0.016 {
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
        if window == nil { cancelErase() }
        if window == nil { onInteraction?(textInteractionID, false) }
        updateInputMode()
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
        onContent = editor.onContent; onPencilAction = editor.onPencilAction; onPencilSqueeze = editor.onPencilSqueeze; holdEnabled = editor.recognizeShapes; markerStraight = editor.markerStraight
        scribbleErase = editor.scribbleErase
        let originChanged = pageLayout.contentOrigin != editor.layout.contentOrigin
        let layoutChanged = pageLayout != editor.layout
        let contentReplaced = contentGeneration != editor.contentGeneration
        if let session = eraseSession, first || contentReplaced || layoutChanged || !editor.enabled || editor.tool != .strokeEraser
            || editor.drawing != session.base.drawing || editor.shapes != session.base.shapes { cancelErase() }
        if first || contentReplaced || layoutChanged || !editor.enabled || editor.tool != tool {
            holdSerial += 1; clearHeldPreview()
        }
        contentGeneration = editor.contentGeneration
        pageLayout = editor.layout
        if layoutChanged { renderViewport = nil }
        backgroundColor = (editor.margins?.color ?? editor.paperColor) == .dark ? .black : .white
        let hasSource = editor.sourcePage != nil || editor.paper == .legacyTest
        let readMode = hasSource && editor.tool == .read
        pdfView.isHidden = !readMode
        pdfRaster.isHidden = !hasSource || readMode
        paperBackground.configure(style: editor.margins?.style ?? (editor.sourcePage == nil ? editor.paper : .blank),
                                  color: editor.margins?.color ?? editor.paperColor, coordinateScale: pageLayout.writingCoordinateScale)
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
        if pdfView.document !== shownDocument {
            pdfView.document = shownDocument
            if readMode {
                pdfView.frame = pageLayout.sourceFrame.cgRect; pdfView.layoutIfNeeded(); lockPDFScrolling(in: pdfView)
            }
        }
        if lastDrawing != editor.drawing || originChanged || contentReplaced {
            if editor.drawing.isEmpty { canvas.drawing = PKDrawing() }
            else if let drawing = try? PKDrawing(data: editor.drawing) { canvas.drawing = drawing.transformed(using: pageLayout.inkTranslation) }
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
            sourceDark = editor.sourcePage.map(Self.isDarkPDF) ?? (editor.paperColor == .dark)
            sourceDarkCalculated = true
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
        if eraseSession != nil { dimErasedShapes() }
        pdfView.isUserInteractionEnabled = tool == .read
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
        if selectionInkSource == nil, let drawing = try? PKDrawing(data: content.drawing) {
            canvas.drawing = drawing.transformed(using: pageLayout.inkTranslation)
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
            }
            selectionInkSource = nil; selectionInkIndices = []
            selectionInkImage.isHidden = true; selectionInkImage.image = nil
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
            canvas.drawing = remainder.transformed(using: pageLayout.inkTranslation)
        }
        let center = CGPoint(x: selectionInkFrame.midX, y: selectionInkFrame.midY).applying(transform)
        selectionInkImage.transform = .identity
        selectionInkImage.bounds = CGRect(origin: .zero, size: selectionInkFrame.size)
        selectionInkImage.center = CGPoint(x: center.x + pageLayout.contentOrigin.x, y: center.y + pageLayout.contentOrigin.y)
        selectionInkImage.transform = CGAffineTransform(a: transform.a, b: transform.b, c: transform.c, d: transform.d, tx: 0, ty: 0)
        selectionInkImage.isHidden = false
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
        }
    }
    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        HangProbe.hit("Sheet.drawingDidChange")
        guard !updating, [.pen, .pencil, .marker, .strokeEraser, .precisionEraser].contains(tool) else { return }
        if heldShape != nil {
            holdCompletion.drawingChanged(); finishHeldStroke(serial: holdSerial); return
        }
        if tool == .marker, markerStraight { straightenLastMarkerStroke() }
        if tool == .pen, scribbleErase { eraseByScribble() }
        recordDrawnWidth()
        lastDrawing = canonicalDrawingData()
        pageContent.drawing = lastDrawing
        onDrawing?(lastDrawing)
    }
    /// Straight-highlighter option: replace the stroke just finished with one
    /// snapped straight segment (`MarkerStraightening`), keeping its ink and
    /// the drawn point attributes so it stays exactly as wide and opaque.
    private func straightenLastMarkerStroke() {
        let previous = (try? PKDrawing(data: pageContent.drawing)) ?? PKDrawing()
        let canonical = canvas.drawing.transformed(using: pageLayout.inkTranslation.inverted())
        guard canonical.strokes.count == previous.strokes.count + 1, let stroke = canonical.strokes.last,
              stroke.ink.inkType == .marker || stroke.ink.inkType == .monoline else { return }
        let points = stroke.path.map { $0.location.applying(stroke.transform) }.map { PagePoint(x: $0.x, y: $0.y) }
        guard let line = MarkerStraightening.line(points) else { return }
        let straight = inkStroke(from: stroke, ink: stroke.ink, path: RecognizedShape.line(start: line.start, end: line.end).outline(spacing: 12))
        guard pageLayout.canonicalInkBounds.insetBy(dx: -0.02, dy: -0.02).contains(straight.renderBounds) else { return }
        let wasUpdating = updating; updating = true
        canvas.drawing = PKDrawing(strokes: Array(canonical.strokes.dropLast()) + [straight]).transformed(using: pageLayout.inkTranslation)
        updating = wasUpdating
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
    private func previewHeldStroke() {
        guard editable, holdEnabled, heldShape == nil, holdBase != nil, tool.isInk,
              let first = holdPoints.first, let last = holdPoints.last else { return }
        let recognized = ShapeRecognition.shape(holdPoints)
            ?? (ShapeRecognition.lineAfterHold(holdPoints) ? .line(start: first, end: LineSnapping.end(from: first, to: last)) : nil)
        guard let shape = recognized, let base = holdBase else { return }
        if tool == .marker { guard case .line = shape else { return } }
        heldColor = InkColor(Color(lastColor ?? .black))
        heldWidth = configuredWidth * (drawnWidthRatio[inkType] ?? 1)
        guard heldFits(shape) else { return }
        heldShape = shape
        heldAdjustment = HeldShapeAdjustment(shape: shape, grab: last)
        let frame = renderViewport?.frame.cgRect ?? bounds
        let scale = min(4, 2048 / max(1, frame.width, frame.height))
        let drawing = ((try? PKDrawing(data: base.drawing)) ?? PKDrawing()).transformed(using: pageLayout.inkTranslation)
        heldInkImage.frame = frame
        canvas.traitCollection.performAsCurrent {
            heldInkImage.image = drawing.image(from: frame, scale: scale).withRenderingMode(.alwaysOriginal)
        }
        heldInkImage.isHidden = false; canvas.layer.opacity = 0
        updateHeldPath()
        if #available(iOS 17.5, *), let feedback = holdFeedback as? UICanvasFeedbackGenerator, let end = shape.outline().last {
            feedback.pathCompleted(at: CGPoint(x: end.x + pageLayout.contentOrigin.x, y: end.y + pageLayout.contentOrigin.y))
        }
    }
    private func heldFits(_ shape: RecognizedShape) -> Bool {
        let outline = shape.outline()
        guard !outline.isEmpty, outline.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return false }
        if case let .line(start, end) = shape, hypot(end.x - start.x, end.y - start.y) < 1 { return false }
        let xs = outline.map(\.x), ys = outline.map(\.y), pad = max(heldWidth / 2, shape.object(color: heldColor, lineWidth: heldWidth)?.padding ?? 0)
        let rect = CGRect(x: xs.min()! - pad, y: ys.min()! - pad, width: xs.max()! - xs.min()! + 2 * pad, height: ys.max()! - ys.min()! + 2 * pad)
        return pageLayout.canonicalInkBounds.contains(rect)
    }
    /// Pen results that fit the editable object model (arrow, axis-aligned
    /// rectangle/square, ellipse/circle) become shapes; the rest native ink.
    /// Pencil results always stay native ink, keeping the graphite texture.
    private func heldObject(width: CGFloat) -> ShapeObject? {
        guard tool == .pen, let shape = heldShape?.object(color: heldColor, lineWidth: min(40, max(0.5, width))),
              (try? shape.validate()) != nil else { return nil }
        return shape
    }
    private func updateHeldPath() {
        guard let shape = heldShape else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        heldShapeLayer.frame = bounds
        let path: UIBezierPath
        if let object = heldObject(width: heldWidth) { path = ShapeRendering.path(object) }
        else {
            path = UIBezierPath()
            for (index, point) in shape.outline().enumerated() {
                if index == 0 { path.move(to: CGPoint(x: point.x, y: point.y)) } else { path.addLine(to: CGPoint(x: point.x, y: point.y)) }
            }
        }
        path.apply(pageLayout.inkTranslation)
        heldShapeLayer.path = path.cgPath; heldShapeLayer.lineWidth = heldWidth
        heldShapeLayer.strokeColor = heldColor.uiColor.withAlphaComponent(heldColor.alpha * (tool == .marker && markerTip == .chisel ? 0.35 : tool == .pencil ? 0.8 : 1)).cgColor
        heldShapeLayer.isHidden = false
        CATransaction.commit()
    }
    private func clearHeldPreview() {
        heldShape = nil; heldAdjustment = nil; holdBase = nil; holdPoints = []
        holdCompletion = StrokeCompletionGate()
        heldInkImage.isHidden = true; heldInkImage.image = nil
        heldShapeLayer.isHidden = true; heldShapeLayer.path = nil; canvas.layer.opacity = 1
    }
    /// A held line whose lift is done but whose final PencilKit callback never
    /// came: commit it before the next touch (or after the fallback delay)
    /// instead of silently keeping the freehand stroke.
    private func commitPendingHeldStroke() {
        guard heldShape != nil, holdCompletion.lifted, !inkActive else { return }
        finishHeldStroke(serial: holdSerial, force: true)
    }
    private func finishHeldStroke(serial: Int, force: Bool = false) {
        guard serial == holdSerial, force || holdCompletion.canCommit, !inkActive, editable, let shape = heldShape, let base = holdBase else { return }
        let canonical = canvas.drawing.transformed(using: pageLayout.inkTranslation.inverted())
        let oldDrawing = (try? PKDrawing(data: base.drawing)) ?? PKDrawing()
        let source = canonical.strokes.count > oldDrawing.strokes.count ? canonical.strokes.last : nil
        if force && source == nil { return }
        let previous = pageContent
        let currentData = canonical.dataRepresentation()
        // Keep the expected published state. Replace the finalized live stroke
        // once: same ink and drawn point attributes (never the bare tool width,
        // which rendered as a hairline), or an editable shape of the drawn width.
        var next = previous
        if let object = heldObject(width: source.map(Self.drawnWidth) ?? heldWidth) {
            next.drawing = oldDrawing.dataRepresentation(); next.shapes.append(object)
        } else {
            let ink = source?.ink ?? PKInk(inkType, color: heldColor.uiColor)
            let stroke = inkStroke(from: source, ink: ink, path: shape.outline(spacing: 8))
            guard pageLayout.canonicalInkBounds.insetBy(dx: -0.02, dy: -0.02).contains(stroke.renderBounds) else {
                clearHeldPreview(); canvasViewDrawingDidChange(canvas); return
            }
            next.drawing = PKDrawing(strokes: oldDrawing.strokes + [stroke]).dataRepresentation()
        }
        // The model records stroke → shape/line as one notebook-wide undo step.
        if onContent?(next, previous) == true {
            installContent(next)
            shapeLayer.configure(next.shapes, origin: pageLayout.contentOrigin)
            clearHeldPreview()
        } else {
            clearHeldPreview()
            if currentData != previous.drawing { canvasViewDrawingDidChange(canvas) }
        }
    }
    /// Median drawn point width in page units (the visible stroke width).
    private static func drawnWidth(_ stroke: PKStroke) -> CGFloat {
        let t = stroke.transform, scale = sqrt(abs(t.a * t.d - t.b * t.c))
        let widths = stroke.path.map { min($0.size.width, $0.size.height) * scale }.sorted()
        return widths.isEmpty ? 0 : widths[widths.count / 2]
    }
    /// Learns PencilKit's drawn width per tool width, so the next held preview
    /// shows the width the replacement will actually have.
    private func recordDrawnWidth() {
        guard let stroke = canvas.drawing.strokes.last, configuredWidth > 0,
              canvas.drawing.strokes.count == ((try? PKDrawing(data: pageContent.drawing))?.strokes.count ?? 0) + 1 else { return }
        let width = Self.drawnWidth(stroke)
        if width > 0 { drawnWidthRatio[stroke.ink.inkType] = width / configuredWidth }
    }
    /// Rebuilds a finished stroke along `path` (page units). Size, opacity,
    /// force and tilt come from the drawn points at the same arc-length
    /// fraction: PencilKit's own point sizes differ from the tool width (marker
    /// tip, pressure, zoom), so a constant tool width rendered far thinner.
    private func inkStroke(from source: PKStroke?, ink: PKInk, path: [PagePoint]) -> PKStroke {
        let drawn = source.map { Array($0.path) } ?? []
        let transform = source?.transform ?? .identity
        let scale = sqrt(abs(transform.a * transform.d - transform.b * transform.c))
        let fractions = StraightStroke.arcFractions(path)
        let indices = StraightStroke.sampleIndices(along: drawn.map {
            let point = $0.location.applying(transform); return PagePoint(x: point.x, y: point.y)
        }, fractions: fractions)
        var time = -1.0
        let points = path.indices.map { index -> PKStrokePoint in
            let location = CGPoint(x: path[index].x, y: path[index].y)
            guard index < indices.count else {
                time = max(fractions[index], time + 0.001)
                return PKStrokePoint(location: location, timeOffset: time, size: CGSize(width: heldWidth, height: heldWidth),
                    opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
            }
            let sample = drawn[indices[index]]
            time = max(sample.timeOffset, time + 0.001)
            let size = CGSize(width: sample.size.width * scale, height: sample.size.height * scale)
            if #available(iOS 26.0, *) {
                return PKStrokePoint(location: location, timeOffset: time, size: size, opacity: sample.opacity, force: sample.force,
                    azimuth: sample.azimuth, altitude: sample.altitude, secondaryScale: sample.secondaryScale, threshold: sample.threshold)
            }
            return PKStrokePoint(location: location, timeOffset: time, size: size, opacity: sample.opacity, force: sample.force,
                azimuth: sample.azimuth, altitude: sample.altitude, secondaryScale: sample.secondaryScale)
        }
        return PKStroke(ink: ink, path: PKStrokePath(controlPoints: points, creationDate: source?.path.creationDate ?? Date()))
    }
    private func installContent(_ content: PageContent) {
        updating = true
        pageContent = content; lastDrawing = content.drawing
        canvas.drawing = ((try? PKDrawing(data: content.drawing)) ?? PKDrawing()).transformed(using: pageLayout.inkTranslation)
        updating = false
    }
    private static func polyline(_ stroke: PKStroke) -> [PagePoint] {
        stroke.path.interpolatedPoints(by: .distance(3)).map {
            let point = $0.location.applying(stroke.transform); return PagePoint(x: point.x, y: point.y)
        }
    }
    private func beginErase() {
        let drawing = (try? PKDrawing(data: pageContent.drawing)) ?? PKDrawing()
        eraseSession = EraseSession(base: pageContent, strokes: drawing.strokes)
        trailPoints = []; trailLink?.invalidate()
        eraseTrail.removeAllAnimations(); eraseTrail.opacity = 1; eraseTrail.path = nil; eraseTrail.isHidden = false
        let link = CADisplayLink(target: self, selector: #selector(updateEraseTrail)); link.add(to: .main, forMode: .common); trailLink = link
    }
    @objc private func updateEraseTrail() {
        let now = CACurrentMediaTime()
        trailPoints.removeAll { now - $0.time > 0.3 }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        eraseTrail.frame = bounds; eraseTrail.lineWidth = max(configuredWidth, 6)
        let path = UIBezierPath()
        for (index, entry) in trailPoints.enumerated() {
            if index == 0 { path.move(to: entry.point) } else { path.addLine(to: entry.point) }
        }
        if trailPoints.count == 1, let point = trailPoints.first?.point { path.addLine(to: point) }
        eraseTrail.path = trailPoints.isEmpty ? nil : path.cgPath
        CATransaction.commit()
    }
    private func endEraseTrail() {
        trailLink?.invalidate(); trailLink = nil; trailPoints = []
        guard !eraseTrail.isHidden, eraseTrail.path != nil else { eraseTrail.isHidden = true; return }
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            guard let self, self.trailLink == nil else { return }
            self.eraseTrail.isHidden = true; self.eraseTrail.path = nil
        }
        let fade = CABasicAnimation(keyPath: "opacity"); fade.fromValue = 1; fade.toValue = 0; fade.duration = 0.22
        eraseTrail.opacity = 0; eraseTrail.add(fade, forKey: "fade")
        CATransaction.commit()
    }
    /// Sweeps a capsule as wide as the pen (minimum 6 pt) from the last point.
    private func eraseSweep(to point: PagePoint) {
        guard var session = eraseSession else { return }
        let from = session.last ?? point
        let radius = max(configuredWidth, 6) / 2
        let sweep = CGRect(x: min(from.x, point.x), y: min(from.y, point.y), width: abs(point.x - from.x), height: abs(point.y - from.y))
        var changed = false
        for index in session.strokes.indices where !session.marked.contains(index) {
            let stroke = session.strokes[index]
            guard stroke.renderBounds.insetBy(dx: -radius - 1, dy: -radius - 1).intersects(sweep) else { continue }
            let reach = radius + Self.drawnWidth(stroke) / 2 + 1
            let points = session.polylines[index] ?? Self.polyline(stroke)
            session.polylines[index] = points
            if StrokeHitTest.hits(sweep: from, point, radius: reach, stroke: points) { session.marked.insert(index); changed = true }
        }
        // Shapes: hit along the same swept width as ink.
        let steps = max(1, Int((hypot(point.x - from.x, point.y - from.y) / radius).rounded(.up)))
        let samples = (0...steps).map { CGPoint(x: from.x + (point.x - from.x) * Double($0) / Double(steps), y: from.y + (point.y - from.y) * Double($0) / Double(steps)) }
        for shape in session.base.shapes where !session.shapes.contains(shape.id) {
            let path = ShapeRendering.path(shape)
            let outline = path.cgPath.copy(strokingWithWidth: shape.lineWidth + 2 * radius, lineCap: .round, lineJoin: .round, miterLimit: 4)
            if samples.contains(where: { outline.contains($0) || (shape.fill != nil && path.contains($0)) }) { session.shapes.insert(shape.id); changed = true }
        }
        trailPoints.append((CGPoint(x: point.x + pageLayout.contentOrigin.x, y: point.y + pageLayout.contentOrigin.y), CACurrentMediaTime()))
        session.last = point
        eraseSession = session
        if changed { showErasePreview() }
    }
    private func showErasePreview() {
        guard let session = eraseSession else { return }
        let strokes = session.strokes.enumerated().map { index, stroke -> PKStroke in
            guard session.marked.contains(index) else { return stroke }
            let color = stroke.ink.color
            return PKStroke(ink: PKInk(stroke.ink.inkType, color: color.withAlphaComponent(color.cgColor.alpha * 0.28)),
                            path: stroke.path, transform: stroke.transform, mask: stroke.mask)
        }
        let wasUpdating = updating; updating = true
        canvas.drawing = PKDrawing(strokes: strokes).transformed(using: pageLayout.inkTranslation)
        updating = wasUpdating
        dimErasedShapes()
    }
    private func dimErasedShapes() {
        guard let session = eraseSession else { return }
        shapeLayer.configure(session.base.shapes.map { shape in
            guard session.shapes.contains(shape.id) else { return shape }
            var dimmed = shape; dimmed.color.alpha *= 0.28; dimmed.fill?.alpha *= 0.28; return dimmed
        }, origin: pageLayout.contentOrigin)
    }
    /// Restores the visible state; nothing was ever published.
    private func cancelErase() {
        guard let session = eraseSession else { return }
        eraseSession = nil; endEraseTrail()
        guard !session.marked.isEmpty || !session.shapes.isEmpty else { return }
        installContent(pageContent)
        shapeLayer.configure(pageContent.shapes, origin: pageLayout.contentOrigin)
    }
    /// One content change (and so one undo step) for every stroke/shape marked.
    private func finishErase() {
        guard let session = eraseSession else { return }
        guard !session.marked.isEmpty || !session.shapes.isEmpty, editable, pageContent == session.base else { cancelErase(); return }
        eraseSession = nil; endEraseTrail()
        var next = session.base
        next.drawing = PKDrawing(strokes: session.strokes.enumerated().filter { !session.marked.contains($0.offset) }.map(\.element)).dataRepresentation()
        next.shapes = session.base.shapes.filter { !session.shapes.contains($0.id) }
        if onContent?(next, session.base) == true { installContent(next) } else { installContent(pageContent) }
        shapeLayer.configure(pageContent.shapes, origin: pageLayout.contentOrigin)
    }
    /// "Durchkritzeln löscht": a finished pen scribble over existing ink
    /// removes the strokes it covers together with itself. The scribble was
    /// never published, so the change is one ink step from before it.
    private func eraseByScribble() {
        let previous = (try? PKDrawing(data: pageContent.drawing)) ?? PKDrawing()
        let canonical = canvas.drawing.transformed(using: pageLayout.inkTranslation.inverted())
        guard canonical.strokes.count == previous.strokes.count + 1, let scribble = canonical.strokes.last,
              scribble.ink.inkType != .marker else { return }
        let points = Self.polyline(scribble)
        guard ScribbleErase.isScribble(points) else { return }
        let others = Array(canonical.strokes.dropLast())
        let hull = CGRect(x: points.map(\.x).min()!, y: points.map(\.y).min()!, width: 0, height: 0)
            .union(CGRect(x: points.map(\.x).max()!, y: points.map(\.y).max()!, width: 0, height: 0)).insetBy(dx: -8, dy: -8)
        let candidates = others.indices.filter { others[$0].renderBounds.intersects(hull) }
        let covered = ScribbleErase.coveredStrokes(scribble: points, strokes: candidates.map { Self.polyline(others[$0]) },
                                                   padding: max(4, Self.drawnWidth(scribble))).map { candidates[$0] }
        guard !covered.isEmpty else { return }
        let removed = Set(covered)
        let wasUpdating = updating; updating = true
        canvas.drawing = PKDrawing(strokes: others.enumerated().filter { !removed.contains($0.offset) }.map(\.element))
            .transformed(using: pageLayout.inkTranslation)
        updating = wasUpdating
    }
    /// Every preloaded sheet owns an interaction; only the focused one may act,
    /// otherwise an even number of sheets toggles the tool back and forth.
    private func pencilAction() { if worksheetFocused, window != nil { onPencilAction?() } }
    func pencilInteractionDidTap(_ interaction: UIPencilInteraction) { pencilAction() }
    @available(iOS 17.5, *)
    func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveTap tap: UIPencilInteraction.Tap) { pencilAction() }
    @available(iOS 17.5, *)
    func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveSqueeze squeeze: UIPencilInteraction.Squeeze) {
        guard let onPencilSqueeze else { if squeeze.phase == .ended { pencilAction() }; return }
        if worksheetFocused, window != nil { onPencilSqueeze(PencilSqueezeEvent(squeeze, in: self)) }
    }
    private static func isDarkPDF(_ page: PDFPage) -> Bool {
        let image = page.thumbnail(of: CGSize(width: 32, height: 32), for: .cropBox)
        var pixels = [UInt8](repeating: 255, count: 32 * 32 * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let luminance: Double = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 128,
                space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue), let cg = image.cgImage else { return 1 }
            context.setFillColor(UIColor.white.cgColor); context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
            context.draw(cg, in: CGRect(x: 0, y: 0, width: 32, height: 32))
            let data = buffer.bindMemory(to: UInt8.self)
            var sum = 0.0
            for i in stride(from: 0, to: data.count, by: 4) { sum += 0.2126 * Double(data[i]) + 0.7152 * Double(data[i+1]) + 0.0722 * Double(data[i+2]) }
            return sum / (1024 * 255)
        }
        return luminance < 0.5
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
    private var inkType: PKInk.InkType {
        tool == .marker ? (markerTip == .round ? .monoline : .marker) : tool == .pencil ? .pencil : .pen
    }
    private func inkingTool(color: UIColor, width: CGFloat) -> PKInkingTool { PKInkingTool(inkType, color: color, width: width) }
    private func canonicalDrawingData() -> Data {
        // The dimmed erase preview is display-only and must never be saved.
        if let session = eraseSession { return session.base.drawing }
        let translation = pageLayout.inkTranslation
        if translation.isIdentity { return canvas.drawing.dataRepresentation() }
        return canvas.drawing.transformed(using: translation.inverted()).dataRepresentation()
    }
}

@MainActor
private final class PaperBackgroundView: UIView {
    private var style: PaperStyle = .blank
    private var color: PaperColor = .white
    private var coordinateScale: CGFloat = 1
    var paperBounds = CGRect.zero { didSet { if oldValue != paperBounds { setNeedsDisplay() } } }
    override init(frame: CGRect) {
        super.init(frame: frame); isOpaque = true; contentMode = .redraw; isUserInteractionEnabled = false
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func configure(style: PaperStyle, color: PaperColor, coordinateScale: CGFloat = 1) {
        if self.style != style || self.color != color || self.coordinateScale != coordinateScale {
            self.style = style; self.color = color; self.coordinateScale = coordinateScale; setNeedsDisplay()
        }
    }
    override func draw(_ rect: CGRect) { PDFExporter.drawPaper(style: style, bounds: paperBounds, color: color, coordinateScale: coordinateScale) }
}
