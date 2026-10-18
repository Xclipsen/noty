import SwiftUI
import PDFKit
import PencilKit
import NotebookCore

struct PageEditor: UIViewRepresentable {
    var sourcePage: PDFPage?
    var layout: PageLayout
    var pageID: UUID
    var drawing: Data
    var textBoxes: [TextBox]
    var images: [ImageObject]
    var shapes: [ShapeObject]
    var searchHighlight: PageRect? = nil
    var paper: PaperStyle = .legacyTest
    var paperColor: PaperColor = .white
    var margins: PageMargins?
    var tool: EditorTool
    var color: UIColor
    var width: CGFloat
    var enabled: Bool
    var focused = true
    var autoPen = false
    var pencilPreview = true
    var onRevealCaret: () -> Void = {}
    var fingerDrawing = false
    var ruler = false
    var shapeOptions = ShapeToolOptions()
    var selectionFilter = SelectionFilter()
    var recognizeShapes = true
    var onPencilAction: () -> Void
    var onInteraction: (UUID, Bool) -> Void
    var undoRequest: Int
    var redoRequest: Int
    var fitRequest: Int
    var contentGeneration: Int
    var textInsertRequest: Int
    var onFlowEdit: ((TextBox, TextBox, NSRange) -> TextFlowFocus?)? = nil
    var onFlowUndo: ((Bool) -> Void)? = nil
    var onFlowBackspace: ((TextBox) -> Void)? = nil
    var readTextBoxes: (() -> [TextBox])? = nil
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

// Ink needs first-responder status for Undo/Redo, but must never summon a
// software keyboard through the responder chain when selecting strokes.
final class DrawingCanvasView: PKCanvasView {
    private let emptyInputView = UIView(frame: .zero)
    override var inputView: UIView? { emptyInputView }
    override var inputAccessoryView: UIView? { nil }
}

final class WorksheetView: UIView, PKCanvasViewDelegate, UIPencilInteractionDelegate {
    private let paperBackground = PaperBackgroundView()
    private let pdfView = PDFView()
    private let canvas = DrawingCanvasView()
    private let imageLayer = ImageObjectLayer()
    private let objectLayer = ObjectEditingLayer()
    private let textLayer = TextObjectLayer()
    private let hitHighlight = UIView()
    private let pencilMark = UIView()
    private lazy var hover = UIHoverGestureRecognizer(target: self, action: #selector(pencilHover(_:)))
    private var previewEnabled = true
    private var sourceDark = false
    private var sourceDarkCalculated = false
    private var worksheetFocused = true
    private var touching = false
    private var textEditing = false
    var hasLiveInput: Bool { touching || textEditing }
    var editingCaret: CGRect? { textLayer.editingCaret.map { textLayer.convert($0, to: self) } }
    private var onRevealCaret: (() -> Void)?
    private var pageID: UUID?
    private var pageLayout = PageLayout(source: .testPaper, legacyA4: true)
    private var lastDrawing = Data()
    private var updating = false
    private var tool = EditorTool.pen
    private var editable = false
    private var lastUndoRequest = 0
    private var lastRedoRequest = 0
    private var lastTool: EditorTool?
    private var lastColor: UIColor?
    private var lastWidth: CGFloat = 0
    private var contentGeneration = 0
    private var undoGeneration = 0
    private var onDrawing: ((Data) -> Void)?
    private var pageContent = PageContent(page: Page())
    private var onContent: ((PageContent, PageContent) -> Bool)?
    private var onPencilAction: (() -> Void)?
    private var holdEnabled = true
    private var pendingRecognition = false
    private let holdGesture = PencilHoldGesture()
    private let interactionObserver = PageInteractionObserver()
    private let interactionID = UUID()
    private let textInteractionID = UUID()
    private var onInteraction: ((UUID, Bool) -> Void)?
    private var strokeStart = 0
    private var inkActive = false
    private var renderViewport: InkRenderViewport?

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
        holdGesture.cancelsTouchesInView = false
        holdGesture.delaysTouchesBegan = false; holdGesture.delaysTouchesEnded = false
        holdGesture.onHold = { [weak self] in
            guard let self, self.holdEnabled, self.tool == .pen else { return }
            self.pendingRecognition = true
        }
        holdGesture.onPoint = { [weak self] point in
            guard let self else { return }; self.eraseShape(at: self.canvas.convert(point, to: self))
        }
        canvas.addGestureRecognizer(holdGesture)
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
        hover.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.pencil.rawValue)]
        hover.cancelsTouchesInView = false; addGestureRecognizer(hover)
        pencilMark.isUserInteractionEnabled = false; pencilMark.isHidden = true
        pencilMark.layer.borderWidth = 1; pencilMark.layer.shadowOpacity = 0.2
        pencilMark.layer.shadowRadius = 3; pencilMark.layer.shadowOffset = CGSize(width: 1, height: 2)
        let interaction = UIPencilInteraction(); interaction.delegate = self; addInteraction(interaction)
        [paperBackground, pdfView, imageLayer, canvas, textLayer, objectLayer, hitHighlight, pencilMark].forEach { addSubview($0) }
        hitHighlight.isUserInteractionEnabled = false; hitHighlight.backgroundColor = UIColor.systemYellow.withAlphaComponent(0.22)
        hitHighlight.layer.borderColor = UIColor.systemOrange.cgColor; hitHighlight.layer.borderWidth = 2
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func insertText(at point: CGPoint) { textLayer.insertText(at: point) }
    func focusText(_ focus: TextFlowFocus) { textLayer.applyTextFocus(focus) }
    func finishTextEditing() { textLayer.endTextEditing() }

    override func layoutSubviews() {
        super.layoutSubviews()
        paperBackground.paperBounds = bounds
        if let viewport = renderViewport {
            paperBackground.frame = viewport.frame.cgRect
            paperBackground.bounds = viewport.frame.cgRect
        } else { paperBackground.frame = bounds }
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
        if imageLayer.frame != bounds { imageLayer.frame = bounds }
        if objectLayer.frame != bounds { objectLayer.frame = bounds }
    }

    func updateRendering(visible: CGRect, scale: CGFloat) {
        guard !inkActive, bounds.intersects(visible), bounds.width > 0, bounds.height > 0 else { return }
        let viewport = InkRenderViewport(page: .init(width: bounds.width, height: bounds.height), visible: PageRect(visible), scale: EditorRenderGeometry.inkScale(displayScale: scale))
        guard viewport != renderViewport else { return }
        renderViewport = viewport
        let wasUpdating = updating; updating = true
        UIView.performWithoutAnimation {
            let s = viewport.scale
            self.canvas.bounds.size = viewport.nativeSize.cgSize
            self.canvas.maximumZoomScale = max(s, self.canvas.minimumZoomScale)
            self.canvas.minimumZoomScale = s; self.canvas.maximumZoomScale = s
            if self.canvas.zoomScale != s { self.canvas.setZoomScale(s, animated: false) }
            self.canvas.contentSize = CGSize(width: self.bounds.width * s, height: self.bounds.height * s)
            self.canvas.contentOffset = CGPoint(x: viewport.nativeOffset.x, y: viewport.nativeOffset.y)
            self.canvas.transform = CGAffineTransform(scaleX: 1 / s, y: 1 / s)
            self.canvas.center = CGPoint(x: viewport.frame.x + viewport.frame.width / 2, y: viewport.frame.y + viewport.frame.height / 2)
            let retina = self.window?.screen.scale ?? 2
            self.paperBackground.contentScaleFactor = s * retina
            self.textLayer.updateDisplayScale(s * retina)
            for plane in [self.imageLayer, self.objectLayer] {
                let factor = EditorRenderGeometry.contentScale(size: .init(width: self.bounds.width, height: self.bounds.height), displayScale: s, screenScale: retina)
                if abs(plane.contentScaleFactor - factor) > 0.01 { plane.contentScaleFactor = factor; plane.setNeedsDisplay() }
            }
            self.setNeedsLayout(); self.layoutIfNeeded()
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
        if window == nil { onInteraction?(textInteractionID, false) }
        updateInputMode()
    }

    func configure(_ editor: PageEditor) {
        updating = true
        let first = pageID != editor.pageID
        if first || !editor.focused || !editor.enabled {
            lastUndoRequest = editor.undoRequest; lastRedoRequest = editor.redoRequest
        }
        let focusChanged = worksheetFocused != editor.focused
        worksheetFocused = editor.focused; previewEnabled = editor.pencilPreview
        if !previewEnabled { pencilMark.isHidden = true }
        let policy: PKCanvasViewDrawingPolicy = editor.fingerDrawing ? .anyInput : .pencilOnly
        if canvas.drawingPolicy != policy { canvas.drawingPolicy = policy }
        holdGesture.allowFinger = editor.fingerDrawing
        canvas.isRulerActive = editor.ruler
        defer { updating = false }
        hitHighlight.isHidden = editor.searchHighlight == nil
        if let rect = editor.searchHighlight {
            hitHighlight.frame = rect.cgRect.offsetBy(dx: editor.layout.contentOrigin.x, dy: editor.layout.contentOrigin.y)
        }
        onDrawing = editor.onDrawing
        onRevealCaret = editor.onRevealCaret
        onInteraction = editor.onInteraction
        onContent = editor.onContent; onPencilAction = editor.onPencilAction; holdEnabled = editor.recognizeShapes
        let originChanged = pageLayout.contentOrigin != editor.layout.contentOrigin
        let layoutChanged = pageLayout != editor.layout
        let contentReplaced = contentGeneration != editor.contentGeneration
        contentGeneration = editor.contentGeneration
        pageLayout = editor.layout
        if layoutChanged { renderViewport = nil }
        backgroundColor = (editor.margins?.color ?? editor.paperColor) == .dark ? UIColor(white: 0.12, alpha: 1) : .white
        pdfView.isHidden = editor.sourcePage == nil && editor.paper != .legacyTest
        paperBackground.configure(style: editor.margins?.style ?? (editor.sourcePage == nil ? editor.paper : .blank),
                                  color: editor.margins?.color ?? editor.paperColor)
        if layoutChanged || contentReplaced || pageID != editor.pageID {
            undoGeneration += 1
            // Display-space undo coordinates predate the new inset. Do not replay
            // those transforms against a resized canvas; canonical data is intact.
            canvas.undoManager?.removeAllActions()
        }
        if pageID != editor.pageID {
            canvas.undoManager?.removeAllActions()
            pageID = editor.pageID
            sourceDark = editor.paperColor == .dark; sourceDarkCalculated = false
            let document = PDFDocument()
            if let page = editor.sourcePage?.copy() as? PDFPage {
                if let ref = page.pageRef, let geometry = try? PDFPageGeometry(ref) {
                    page.setBounds(geometry.effectiveCrop.cgRect, for: .cropBox)
                }
                document.insert(page, at: 0)
            } else if !pdfView.isHidden, let page = PDFExporter.paperPDF(style: editor.paper, size: editor.layout.contentCanvas, color: editor.paperColor).page(at: 0) {
                document.insert(page, at: 0)
            }
            pdfView.document = document
        }
        if lastDrawing != editor.drawing || originChanged || contentReplaced {
            canvas.undoManager?.removeAllActions()
            if editor.drawing.isEmpty { canvas.drawing = PKDrawing() }
            else if let drawing = try? PKDrawing(data: editor.drawing) { canvas.drawing = drawing.transformed(using: pageLayout.inkTranslation) }
            lastDrawing = editor.drawing
        }
        let modeChanged = tool != editor.tool || editable != editor.enabled
        tool = editor.tool
        editable = editor.enabled
        if editor.autoPen, tool == .pen, !sourceDarkCalculated {
            sourceDark = editor.sourcePage.map(Self.isDarkPDF) ?? (editor.paperColor == .dark)
            sourceDarkCalculated = true
        }
        let inkColor = editor.autoPen && tool == .pen ? (sourceDark ? UIColor.white : UIColor.black) : editor.color
        if lastTool != tool || lastColor != inkColor || lastWidth != editor.width {
            switch tool {
            case .pen: canvas.tool = PKInkingTool(.pen, color: inkColor, width: editor.width)
            case .marker: canvas.tool = PKInkingTool(.marker, color: inkColor, width: editor.width)
            case .strokeEraser: canvas.tool = PKEraserTool(.vector)
            case .precisionEraser: canvas.tool = PKEraserTool(.fixedWidthBitmap, width: editor.width)
            case .inkSelection: canvas.tool = PKLassoTool()
            case .text, .image, .shape, .selection, .read: break
            }
            lastTool = tool
            lastColor = inkColor
            lastWidth = editor.width
        }
        textLayer.onFlowChange = editor.onFlowEdit
        textLayer.onFlowUndo = editor.onFlowUndo
        textLayer.onFlowBackspace = editor.onFlowBackspace
        textLayer.readCurrentBoxes = editor.readTextBoxes
        textLayer.configure(boxes: editor.textBoxes, pageID: editor.pageID, layout: editor.layout,
                            contentGeneration: editor.contentGeneration, active: editable && tool == .text, readOnly: editable && tool == .read,
                            darkPaper: editor.paperColor == .dark, darkMargins: editor.margins?.color == .dark,
                            hasPDF: editor.sourcePage != nil, onChange: editor.onTextBoxes)
        imageLayer.configure(objects: editor.images, pageID: editor.pageID, layout: editor.layout,
                             contentGeneration: editor.contentGeneration, active: editable && tool == .image,
                             onChange: editor.onImages, onError: editor.onError)
        var page = Page(); page.drawing = editor.drawing; page.textBoxes = editor.textBoxes
        page.images = editor.images; page.shapes = editor.shapes
        pageContent = PageContent(page: page)
        objectLayer.configure(PageContent(page: page), pageID: editor.pageID, layout: editor.layout,
            generation: editor.contentGeneration, tool: tool, enabled: editable, fingerDrawing: editor.fingerDrawing, options: editor.shapeOptions,
            filter: editor.selectionFilter, color: InkColor(Color(editor.color)), width: editor.width, onCommit: editor.onContent)
        canvas.isUserInteractionEnabled = editable && [.pen, .marker, .strokeEraser, .precisionEraser, .inkSelection].contains(tool)
        pdfView.isUserInteractionEnabled = tool == .read
        if modeChanged || focusChanged || first { updateInputMode() }
        if lastUndoRequest != editor.undoRequest {
            lastUndoRequest = editor.undoRequest
            performUndo(redo: false)
        }
        if lastRedoRequest != editor.redoRequest {
            lastRedoRequest = editor.redoRequest
            performUndo(redo: true)
        }
        setNeedsLayout()
    }

    private func performUndo(redo: Bool) {
        let expectedPage = pageID
        let expectedGeneration = undoGeneration
        let textMode = tool == .text
        let imageMode = tool == .image
        let objectMode = tool == .shape || tool == .selection
        DispatchQueue.main.async { [weak self] in
            guard let self, self.pageID == expectedPage, self.undoGeneration == expectedGeneration else { return }
            if textMode { self.textLayer.performUndo(redo: redo) }
            else if imageMode { self.imageLayer.performUndo(redo: redo) }
            else if objectMode { self.objectLayer.performUndo(redo: redo) }
            else {
                let manager = self.canvas.undoManager
                if redo { manager?.redo() } else { manager?.undo() }
                self.lastDrawing = self.canonicalDrawingData()
                self.onDrawing?(self.lastDrawing)
            }
        }
    }

    private func updateInputMode() {
        guard window != nil else { return }
        if editable && worksheetFocused && [.pen, .marker, .strokeEraser, .precisionEraser, .inkSelection].contains(tool) {
            textLayer.endTextEditing()
            canvas.becomeFirstResponder()
            canvas.reloadInputViews()
        } else {
            canvas.resignFirstResponder()
            if tool != .text { textLayer.endTextEditing() }
        }
    }
    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        guard !updating else { return }
        lastDrawing = canonicalDrawingData()
        pageContent.drawing = lastDrawing
        onDrawing?(lastDrawing)
    }
    func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
        inkActive = true
        pendingRecognition = false; strokeStart = canvas.drawing.strokes.count
    }
    func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
        inkActive = false
        // A vector eraser also removes complete shape objects. Text/images stay protected.
        if tool == .strokeEraser { return }
        guard pendingRecognition, holdEnabled, tool == .pen,
              canvas.drawing.strokes.count > strokeStart, let stroke = canvas.drawing.strokes.last else { return }
        pendingRecognition = false
        let translation = pageLayout.inkTranslation.inverted()
        let stride = max(1, stroke.path.count / 160)
        let points = Swift.stride(from: 0, to: stroke.path.count, by: stride).map { index -> PagePoint in
            let p = stroke.path[index].location.applying(stroke.transform).applying(translation)
            return .init(x: p.x, y: p.y)
        }
        guard let kind = ShapeRecognition.recognize(points), let first = points.first, let last = points.last else { return }
        let xs = points.map(\.x), ys = points.map(\.y)
        let tip = points.max { hypot($0.x-first.x, $0.y-first.y) < hypot($1.x-first.x, $1.y-first.y) }!
        let shape = ShapeObject(kind: kind,
            start: kind == .line || kind == .arrow ? first : .init(x: xs.min()!, y: ys.min()!),
            end: kind == .arrow ? tip : kind == .line ? last : .init(x: xs.max()!, y: ys.max()!), color: InkColor(Color(stroke.ink.color)),
            lineWidth: max(0.5, min(40, stroke.path.first?.size.width ?? 2)))
        guard pageLayout.canonicalInkBounds.insetBy(dx: -0.02, dy: -0.02).contains(shape.bounds.cgRect) else { return }
        var next = pageContent
        let canonical = canvas.drawing.transformed(using: translation)
        next.drawing = PKDrawing(strokes: Array(canonical.strokes.dropLast())).dataRepresentation()
        next.shapes.append(shape)
        let previous = pageContent
        if onContent?(next, previous) == true {
            canvas.undoManager?.removeAllActions()
            installContent(next)
            registerContentUndo(previous, expected: next)
        }
    }
    private func installContent(_ content: PageContent) {
        updating = true
        pageContent = content; lastDrawing = content.drawing
        canvas.drawing = ((try? PKDrawing(data: content.drawing)) ?? PKDrawing()).transformed(using: pageLayout.inkTranslation)
        updating = false
    }
    private func registerContentUndo(_ value: PageContent, expected: PageContent) {
        let expectedPage = pageID, expectedGeneration = undoGeneration
        canvas.undoManager?.registerUndo(withTarget: self) { owner in
            guard owner.pageID == expectedPage, owner.undoGeneration == expectedGeneration,
                  owner.pageContent == expected, owner.onContent?(value, expected) == true else { return }
            owner.installContent(value); owner.registerContentUndo(expected, expected: value)
        }
        canvas.undoManager?.setActionName("Form erkennen")
    }
    private func restoreShapes(_ shapes: [ShapeObject], expected: [ShapeObject]) {
        guard pageContent.shapes == expected else { return }
        var next = pageContent; next.shapes = shapes
        guard onContent?(next, pageContent) == true else { return }
        pageContent = next
        let expectedPage = pageID, expectedGeneration = undoGeneration
        canvas.undoManager?.registerUndo(withTarget: self) { owner in
            guard owner.pageID == expectedPage, owner.undoGeneration == expectedGeneration else { return }
            owner.restoreShapes(expected, expected: shapes)
        }
        canvas.undoManager?.setActionName("Form radieren")
    }
    private func eraseShape(at point: CGPoint) {
        guard editable, tool == .strokeEraser else { return }
        let point = point.applying(pageLayout.inkTranslation.inverted())
        let ids = Set(pageContent.shapes.filter { ShapeRendering.hit($0, at: point) }.map(\.id))
        guard !ids.isEmpty else { return }
        restoreShapes(pageContent.shapes.filter { !ids.contains($0.id) }, expected: pageContent.shapes)
    }
    func pencilInteractionDidTap(_ interaction: UIPencilInteraction) { onPencilAction?() }
    @available(iOS 17.5, *)
    func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveTap tap: UIPencilInteraction.Tap) { onPencilAction?() }
    @available(iOS 17.5, *)
    func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveSqueeze squeeze: UIPencilInteraction.Squeeze) {
        if squeeze.phase == .ended { onPencilAction?() }
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
    @objc private func pencilHover(_ gesture: UIHoverGestureRecognizer) {
        guard editable, previewEnabled, [.pen, .marker, .strokeEraser, .precisionEraser].contains(tool),
              gesture.state == .began || gesture.state == .changed else { pencilMark.isHidden = true; return }
        let point = gesture.location(in: self)
        let diameter = max(6, lastWidth)
        pencilMark.bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
        pencilMark.center = point; pencilMark.layer.cornerRadius = diameter / 2
        pencilMark.backgroundColor = (lastColor ?? .label).withAlphaComponent(0.14)
        pencilMark.layer.borderColor = (lastColor ?? .label).withAlphaComponent(0.65).cgColor
        pencilMark.isHidden = false
    }
    private func canonicalDrawingData() -> Data {
        let translation = pageLayout.inkTranslation
        if translation.isIdentity { return canvas.drawing.dataRepresentation() }
        return canvas.drawing.transformed(using: translation.inverted()).dataRepresentation()
    }
}

@MainActor
private final class PaperBackgroundView: UIView {
    private var style: PaperStyle = .blank
    private var color: PaperColor = .white
    var paperBounds = CGRect.zero { didSet { if oldValue != paperBounds { setNeedsDisplay() } } }
    override init(frame: CGRect) {
        super.init(frame: frame); isOpaque = true; contentMode = .redraw; isUserInteractionEnabled = false
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func configure(style: PaperStyle, color: PaperColor) {
        if self.style != style || self.color != color {
            self.style = style; self.color = color; setNeedsDisplay()
        }
    }
    override func draw(_ rect: CGRect) { PDFExporter.drawPaper(style: style, bounds: paperBounds, color: color) }
}
