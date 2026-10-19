import SwiftUI
import NotebookCore
import OSLog

/// Device-log timings for opening a notebook (category `editor-performance`),
/// only with Settings › Diagnose. Each event is logged once per open,
/// relative to the editor appearing.
@MainActor
enum EditorOpenTrace {
    private static let log = Logger(subsystem: "de.la.noty", category: "editor-performance")
    private static var start: CFTimeInterval?
    private static var logged = Set<String>()
    static func begin() { guard HangProbe.isInstalled else { return }; start = CACurrentMediaTime(); logged = [] }
    static func mark(_ event: String, _ detail: @autoclosure () -> String = "") {
        guard let start else { return }
        let elapsed = CACurrentMediaTime() - start
        // Later renders (scrolling minutes after opening) are not open timings.
        guard elapsed < 20 else { Self.start = nil; return }
        guard logged.insert(event).inserted else { return }
        let text = detail()
        log.notice("Open: \(event, privacy: .public) after \(Int(elapsed * 1000), privacy: .public) ms \(text, privacy: .public)")
    }
}

/// One viewport; only visible pages and their immediate neighbours own native
/// canvases. Ordinary SwiftUI/autosave updates keep those worksheet instances.
struct PageRevealRequest: Equatable {
    let id = UUID()
    let pageID: UUID
}

struct NotebookEditor: UIViewRepresentable {
    var pages: [Page]
    var selectedPageID: UUID
    var paging: Bool
    var normalizeWidths: Bool
    var fitRequest: Int
    var textInsertRequest: Int
    var textFocus: TextFlowFocus? = nil
    var enabled: Bool
    var fingerDrawing: Bool
    /// Writing mode: sideways scrolling until the sheet centre meets the screen edge.
    var writingScroll = false
    /// Floating header/palette height; pages scroll underneath it.
    var topObstruction: CGFloat = 0
    /// Further screen-fixed chrome over the pages (floating palette), viewport points.
    var obstructions: [CGRect] = []
    var configuration: (Page) -> PageEditor
    var onSelect: (UUID) -> Void
    /// Atomic multi-page content change (cross-page selection move and its undo).
    var onTransfer: (([PageContentReplacement]) -> Bool)? = nil
    var onError: (String) -> Void = { _ in }
    /// Undo/redo changed this page: it becomes selected; the view only jumps
    /// there when the page is not already on screen.
    var revealRequest: PageRevealRequest? = nil
    /// Laser pointer tool active: viewport-level overlay above all pages (display only).
    var laser: LaserPointerStyle? = nil
    func makeUIView(context: Context) -> NotebookViewport { NotebookViewport() }
    func updateUIView(_ view: NotebookViewport, context: Context) { view.configure(self) }
}

final class NotebookViewport: UIScrollView, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    /// Dark backdrop behind and between the sheets (also the editor's SwiftUI
    /// and loading background). Page seams stay visible as 0.42 grey rules.
    static let backdrop = UIColor(white: 0.07, alpha: 1)
    private let surface = UIView()
    private var sheets: [UUID: WorksheetView] = [:]
    private var frames: [UUID: CGRect] = [:]
    private var state: NotebookEditor?
    private var layoutKey: [NotebookPagePlacement] = []
    private var placements: [UUID: NotebookPagePlacement] = [:]
    private var mode = false
    private var normalized = false
    private var writingScroll = false
    private var topObstruction: CGFloat = 0
    private var obstructions: [CGRect] = []
    private var selected: UUID?
    private var reported: UUID?
    private var previousSize = CGSize.zero
    private var fitWidth: CGFloat = 1
    private var fitRequest = 0
    private var textRequest = 0
    private var pendingFit = true
    private var pendingJump = true
    private var changing = false
    private var userZoomPage: UUID?
    private var zoomLink: CADisplayLink?
    private var zoomTransition: ZoomTransition?
    private var zoomStart: CFTimeInterval = 0
    private var logicalZoomRange: NotebookViewportGeometry.ZoomRange?
    private var widthSnapInProgress = false
    private var pinchTargetAttached = false
    /// Weak: recognizers of unloaded sheets vanish; reused addresses can't mask new ones.
    private let rulerGestures = NSHashTable<UIGestureRecognizer>.weakObjects()
    private var separators: [CALayer] = []
    private var lastSearch: PageRect?
    private var pendingSearch: CGRect?
    private var lastTextFocus: UUID?
    private var lastReveal: UUID?
    /// Animated scroll to the page focused after a deletion; the horizontal
    /// clamp of intermediate pages must not interrupt it.
    fileprivate var focusScrolling = false
    private var pendingTextFocus: TextFlowFocus?
    private var caretRevealQueued = false
    private var keyboardScreenFrame: CGRect?
    private var configurationRevision = 0
    private var sheetRevisions: [UUID: Int] = [:]
    private var refreshQueued = false
    private var refreshing = false
    private let performanceLog = Logger(subsystem: "de.la.noty", category: "editor-performance")
    private var lastSlowRefreshLog: CFTimeInterval = 0
    private let floatingSelection = UIImageView()
    private var floatingLift: SelectionLift?
    private weak var floatingGesture: UIGestureRecognizer?
    private var autoScrollLink: CADisplayLink?
    private let laser = LaserPointerView()
    /// Page below a floating selection; entering another page ticks on Apple Pencil Pro.
    private var floatTarget: UUID?
    private var selectionFeedback: UIFeedbackGenerator?


    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self; backgroundColor = Self.backdrop
        contentInsetAdjustmentBehavior = .never; keyboardDismissMode = .interactive
        delaysContentTouches = false; alwaysBounceVertical = true; alwaysBounceHorizontal = true; bouncesZoom = false
        panGestureRecognizer.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        addSubview(surface)
        laser.install(on: self, surface: surface)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardChanged(_:)),
            name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardChanged(_:)),
            name: UIResponder.keyboardWillHideNotification, object: nil)
        for direction: UISwipeGestureRecognizer.Direction in [.left, .right] {
            let swipe = UISwipeGestureRecognizer(target: self, action: #selector(turnPage(_:)))
            swipe.direction = direction; swipe.delegate = self
            swipe.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
            addGestureRecognizer(swipe); panGestureRecognizer.require(toFail: swipe)
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(_ next: NotebookEditor) {
        HangProbe.hit("Viewport.configure")
        let first = state == nil
        configurationRevision += 1
        let oldSelection = selected
        let focusChanged = next.textFocus.map { $0.requestID != lastTextFocus } ?? false
        if focusChanged, let focus = next.textFocus {
            lastTextFocus = focus.requestID; pendingTextFocus = focus
            reported = focus.pageID
            pendingJump = false
        }
        if let reveal = next.revealRequest, reveal.id != lastReveal {
            lastReveal = reveal.id
            // Already visible: select without moving (like a page reported by scrolling).
            if !next.paging, next.paging == mode, isOnScreen(reveal.pageID) { reported = reveal.pageID }
        }
        let modeChanged = mode != next.paging
        let normalizationChanged = normalized != next.normalizeWidths
        if modeChanged || normalizationChanged || (oldSelection != next.selectedPageID && next.selectedPageID != reported) { stopZoomTransition() }
        state = next; mode = next.paging; normalized = next.normalizeWidths; selected = next.selectedPageID
        let scrollModeChanged = writingScroll != next.writingScroll
        writingScroll = next.writingScroll; topObstruction = next.topObstruction; obstructions = next.obstructions
        panGestureRecognizer.minimumNumberOfTouches = next.fingerDrawing ? 2 : 1
        laser.configure(next.laser, fingerDrawing: next.fingerDrawing)
        let placement = NotebookViewportLayout(pages: next.pages, selectedPageID: next.selectedPageID,
            paging: mode, normalizeWidths: normalized)
        let key = placement.pages
        // Deleting the open page: it collapses and fades, the following pages
        // slide up, then the view scrolls to the newly focused page.
        let deletion = deletedOpenPage(old: layoutKey, new: key, oldSelection: oldSelection,
                                       animatable: !first && !modeChanged && !normalizationChanged && !focusChanged)
        var slide: [UUID: CGPoint] = [:]
        if let deletion {
            for (id, sheet) in sheets where id != deletion.id { slide[id] = sheet.center }
            collapse(sheets.removeValue(forKey: deletion.id), frame: deletion.frame)
            sheetRevisions.removeValue(forKey: deletion.id)
        }
        if key != layoutKey || modeChanged || normalizationChanged || (mode && oldSelection != selected) {
            changing = true
            let oldFrame = oldSelection.flatMap { frames[$0] }
            let localY = oldFrame.map { (contentOffset.y + bounds.height / 2) / zoomScale - $0.minY }
            layoutKey = key
            updateSeparators(key, animated: deletion != nil)
            frames = Dictionary(uniqueKeysWithValues: key.map { ($0.id, $0.frame.cgRect) })
            placements = Dictionary(uniqueKeysWithValues: key.map { ($0.id, $0) })
            surface.bounds = placement.size.bounds
            surface.center = CGPoint(x: placement.size.width * zoomScale / 2, y: placement.size.height * zoomScale / 2)
            contentSize = CGSize(width: placement.size.width * zoomScale, height: placement.size.height * zoomScale)
            // Keep the page that was measured stable; a simultaneous selection
            // change (e.g. after a cross-page drop onto the materialized draft)
            // must not shift the document by the distance between both pages.
            if deletion == nil, let localY, let frame = oldSelection.flatMap({ frames[$0] }) ?? selected.flatMap({ frames[$0] }),
               !first, !modeChanged, !normalizationChanged, !focusChanged {
                contentOffset.y = (frame.minY + localY) * zoomScale - bounds.height / 2
            }
            changing = false
            if first || modeChanged || normalizationChanged || (!focusChanged && mode && (oldSelection != selected || oldFrame?.size != selected.flatMap({ frames[$0]?.size }))) {
                pendingFit = true; pendingJump = true
            }
        }
        if deletion != nil {
            // Pages above keep their place; the focus scroll follows the slide.
            reported = selected
        } else if oldSelection != selected && selected != reported {
            if let oldSelection { sheets[oldSelection]?.finishTextEditing() }
            pendingJump = true
        }
        if fitRequest != next.fitRequest { fitRequest = next.fitRequest; pendingFit = true; pendingJump = true }
        if let page = next.pages.first(where: { $0.id == selected }) {
            let config = next.configuration(page)
            // Text tool: the Pencil scrolls the paper like a finger; Pencil taps
            // still place the caret or open a field (text layer recognizers).
            let textTool = config.tool == .text && next.enabled
            let allowed = (textTool ? [UITouch.TouchType.direct, .pencil] : [.direct]).map { NSNumber(value: $0.rawValue) }
            if panGestureRecognizer.allowedTouchTypes != allowed { panGestureRecognizer.allowedTouchTypes = allowed }
            if textTool { panGestureRecognizer.minimumNumberOfTouches = 1 }
            if lastSearch != config.searchHighlight || oldSelection != selected || normalizationChanged {
                lastSearch = config.searchHighlight
                if let hit = config.searchHighlight, let placement = placements[page.id] {
                    pendingSearch = placement.surfaceRect(for: hit).cgRect
                }
            }
        }
        if first { textRequest = next.textInsertRequest }
        setNeedsLayout(); layoutIfNeeded()
        if scrollModeChanged { constrainHorizontalOffset(animated: true) }
        refreshSheets()
        if let deletion { slideAfterDeletion(from: slide, deletion: deletion) }
        if oldSelection != selected { queueCaretReveal() }
        if let focus = pendingTextFocus, let sheet = sheets[focus.pageID], next.enabled {
            pendingTextFocus = nil
            sheet.focusText(focus); queueCaretReveal()
        }
        if textRequest != next.textInsertRequest, let selected, let sheet = sheets[selected] {
            textRequest = next.textInsertRequest
            let point = convert(CGPoint(x: bounds.midX, y: bounds.midY), to: sheet)
            sheet.insertText(at: CGPoint(x: point.x, y: min(max(0, point.y), sheet.bounds.height - 24)))
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        HangProbe.hit("Viewport.layoutSubviews")
        // UIScrollView creates its pinch recognizer only once zooming is possible
        // (min < max), i.e. after the first fit. Attaching in init silently failed.
        if !pinchTargetAttached, let pinch = pinchGestureRecognizer {
            pinch.addTarget(self, action: #selector(pinchChanged(_:))); pinchTargetAttached = true
        }
        guard !changing, let selected, let placement = placements[selected], bounds.width > 40, bounds.height > 40 else { return }
        changing = true
        let resized = previousSize != bounds.size
        // A fit centres the complete sheet (writing space included); other
        // jumps keep the zoom and put the PDF/base sheet in the middle.
        let fitting = pendingFit
        if previousSize != bounds.size || pendingFit {
            let oldSize = previousSize
            let center = CGPoint(x: (contentOffset.x + oldSize.width / 2) / zoomScale,
                                 y: (contentOffset.y + oldSize.height / 2) / zoomScale)
            let relative = zoomScale / fitWidth
            let range = NotebookViewportGeometry.zoomRange(viewport: PageSize(width: bounds.width, height: bounds.height),
                placement: placement)
            fitWidth = range.fit; logicalZoomRange = range
            maximumZoomScale = max(range.maximum, minimumZoomScale)
            minimumZoomScale = range.minimum; maximumZoomScale = range.maximum
            setZoomScale(min(max(pendingFit ? fitWidth : fitWidth * relative, minimumZoomScale), maximumZoomScale), animated: false)
            if !pendingJump {
                contentOffset = CGPoint(x: center.x * zoomScale - bounds.width / 2, y: center.y * zoomScale - bounds.height / 2)
            }
            previousSize = bounds.size; pendingFit = false
        }
        updateInsets()
        if pendingJump {
            contentOffset = jumpOffset(placement, wholeSheet: fitting)
            pendingJump = false; reported = selected
            EditorOpenTrace.mark("first page positioned", "zoom=\(String(format: "%.2f", Double(zoomScale)))")
        }
        constrainHorizontalOffset()
        if let target = pendingSearch {
            pendingSearch = nil
            super.scrollRectToVisible(surface.convert(target.insetBy(dx: -16, dy: -16), to: self), animated: false)
        }
        changing = false
        refreshSheets()
        if resized { revealCaret() }
    }
    /// Top of the page below the header; horizontally see `jumpOffsetX`.
    private func jumpOffset(_ placement: NotebookPagePlacement, wholeSheet: Bool) -> CGPoint {
        CGPoint(x: NotebookViewportGeometry.jumpOffsetX(placement, scale: zoomScale, viewportWidth: bounds.width, wholeSheet: wholeSheet),
                y: placement.frame.y * zoomScale - contentInset.top)
    }
    /// Jump target clamped to the scrollable range (an animated scroll must
    /// not end beyond the content and bounce back).
    fileprivate func jumpOffsetForAnimation(_ placement: NotebookPagePlacement) -> CGPoint {
        let target = jumpOffset(placement, wholeSheet: false)
        return CGPoint(
            x: min(max(target.x, -contentInset.left), max(-contentInset.left, contentSize.width - bounds.width + contentInset.right)),
            y: min(max(target.y, -contentInset.top), max(-contentInset.top, contentSize.height - bounds.height + contentInset.bottom)))
    }
    /// One grey rule per seam, spanning the wider of the two neighbouring sheets.
    private func updateSeparators(_ pages: [NotebookPagePlacement], animated: Bool = false) {
        let seams = zip(pages, pages.dropFirst()).map { a, b in
            CGRect(x: min(a.frame.x, b.frame.x), y: a.frame.y + a.frame.height,
                   width: max(a.frame.x + a.frame.width, b.frame.x + b.frame.width) - min(a.frame.x, b.frame.x),
                   height: b.frame.y - a.frame.y - a.frame.height)
        }
        CATransaction.begin(); CATransaction.setDisableActions(!animated)
        if animated {
            CATransaction.setAnimationDuration(Self.deletionDuration)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
        }
        while separators.count > seams.count { separators.removeLast().removeFromSuperlayer() }
        while separators.count < seams.count {
            let line = CALayer(); line.backgroundColor = UIColor(white: 0.42, alpha: 1).cgColor
            surface.layer.insertSublayer(line, at: 0); separators.append(line)
        }
        for (line, rect) in zip(separators, seams) { line.frame = rect }
        CATransaction.commit()
    }
    private func updateInsets() {
        let side = NotebookViewportGeometry.horizontalInset(viewportWidth: bounds.width, contentWidth: contentSize.width)
        let inset = UIEdgeInsets(top: topObstruction + 12, left: side, bottom: 32 + keyboardOverlap, right: side)
        if contentInset != inset { contentInset = inset }
    }
    private func refreshSheets() {
        guard !refreshing, let state, !frames.isEmpty else { return }
        HangProbe.hit("Viewport.refreshSheets")
        refreshing = true
        let started = HangProbe.isInstalled ? CACurrentMediaTime() : nil
        defer {
            refreshing = false
            if let started {
                let now = CACurrentMediaTime()
                if now - started > 0.025, now - lastSlowRefreshLog > 1 {
                    lastSlowRefreshLog = now
                    performanceLog.notice("Page refresh took \(Int((now - started) * 1000), privacy: .public) ms; native pages=\(self.sheets.count, privacy: .public)")
                }
            }
        }
        let visible = CGRect(x: contentOffset.x / zoomScale, y: contentOffset.y / zoomScale,
                             width: bounds.width / zoomScale, height: bounds.height / zoomScale)
        let live = liveZoom
        let nearby = NotebookViewportGeometry.preloadRect(visible: PageRect(x: visible.minX, y: visible.minY,
            width: visible.width, height: visible.height)).cgRect
        var keep = Set(frames.filter { $0.value.intersects(nearby) }.map(\.key))
        if let selected { keep.insert(selected) }
        // Never remove a native text editor during composition or a live stroke.
        for (id, sheet) in sheets where sheet.hasLiveInput { keep.insert(id) }
        // Keep a small warm set during short reversals instead of repeatedly
        // rebuilding PDFView/TextKit/PencilKit at the preload boundary.
        let warm = sheets.keys.filter { !keep.contains($0) && frames[$0] != nil }.sorted {
            abs((frames[$0]?.midY ?? 0) - visible.midY) < abs((frames[$1]?.midY ?? 0) - visible.midY)
        }
        keep.formUnion(warm.prefix(max(0, 4 - keep.count)))
        for id in Array(sheets.keys) where !keep.contains(id) {
            sheets[id]?.removeFromSuperview(); sheets.removeValue(forKey: id); sheetRevisions.removeValue(forKey: id)
        }
        var created = false
        let orderedPages = state.pages.filter { keep.contains($0.id) }.sorted {
            if $0.id == $1.id { return false }
            if $0.id == selected { return true }; if $1.id == selected { return false }
            let a = frames[$0.id]?.intersects(visible) == true, b = frames[$1.id]?.intersects(visible) == true
            return a && !b
        }
        for page in orderedPages {
            guard let placement = placements[page.id] else { continue }
            let sheet: WorksheetView
            if let existing = sheets[page.id] { sheet = existing }
            else {
                // Spread newly exposed PDF/UITextView construction across frames.
                if created { queueRefresh(); continue }
                sheet = WorksheetView(); sheets[page.id] = sheet; surface.addSubview(sheet); created = true
            }
            // Bounds are canonical points; UIKit converts touches/caret through
            // the common scale for all layers. Never write surface sizes back.
            let size = placement.canvas.cgSize
            if sheet.bounds.size != size { sheet.bounds = CGRect(origin: .zero, size: size) }
            let transform = CGAffineTransform(scaleX: placement.scale, y: placement.scale)
            if sheet.transform != transform { sheet.transform = transform }
            let center = CGPoint(x: placement.frame.x + placement.frame.width / 2, y: placement.frame.y + placement.frame.height / 2)
            if sheet.center != center { sheet.center = center }
            if sheetRevisions[page.id] == configurationRevision {
                sheet.updateRendering(visible: convert(bounds, to: sheet), scale: zoomScale * placement.scale, live: live)
                continue
            }
            var config = state.configuration(page)
            config.focused = page.id == selected
            let generation = config.contentGeneration
            config.onRevealCaret = { [weak self, weak sheet] in
                guard let self, let sheet, sheet.editingCaret != nil,
                      self.state?.configuration(page).contentGeneration == generation else { return }
                self.queueCaretReveal()
            }
            let callback = config.onInteraction
            config.onInteraction = { [weak self] id, active in
                callback(id, active)
                guard let self, active, !self.isZooming, !self.widthSnapInProgress,
                      self.pinchGestureRecognizer?.state != .began, self.pinchGestureRecognizer?.state != .changed else { return }
                self.reported = page.id
                self.state?.onSelect(page.id)
            }
            sheetRevisions[page.id] = configurationRevision
            // Every model change (save status, undo availability, another
            // page's edit) re-runs the SwiftUI body. Pages whose inputs are
            // unchanged only adopt the new callbacks.
            if sheet.matches(config) {
                sheet.adoptCallbacks(config)
            } else {
                let configureStarted = CACurrentMediaTime()
                sheet.configure(config)
                if page.id == selected {
                    EditorOpenTrace.mark("first sheet configured", "configure=\(Int((CACurrentMediaTime() - configureStarted) * 1000)) ms pdf=\(config.sourcePage != nil) zoom=\(String(format: "%.2f", Double(zoomScale)))")
                }
            }
            // PencilKit may install its ruler recognizers after activation.
            for gesture in sheet.rulerGestureRecognizers where !rulerGestures.contains(gesture) {
                rulerGestures.add(gesture)
                panGestureRecognizer.require(toFail: gesture); pinchGestureRecognizer?.require(toFail: gesture)
            }
            sheet.updateRendering(visible: convert(bounds, to: sheet), scale: zoomScale * placement.scale, live: live)
        }
    }
    /// A pinch or snap animation is in progress; final resolution follows at its end.
    private var liveZoom: Bool {
        userZoomPage != nil || widthSnapInProgress || isZooming
            || pinchGestureRecognizer?.state == .began || pinchGestureRecognizer?.state == .changed
    }
    private func queueRefresh() {
        guard !refreshQueued else { return }; refreshQueued = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60) { [weak self] in
            guard let self else { return }; self.refreshQueued = false; self.refreshSheets()
        }
    }
    func viewForZooming(in scrollView: UIScrollView) -> UIView? { surface }
    func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) {
        guard pinchGestureRecognizer?.state == .began || pinchGestureRecognizer?.state == .changed else { return }
        stopZoomTransition()
        if !sheets.values.contains(where: { $0.editingCaret != nil }), let pinch = pinchGestureRecognizer {
            let point = pinch.location(in: surface)
            if let id = frames.first(where: { $0.value.contains(point) })?.key, id != selected {
                selected = id; reported = id; state?.onSelect(id)
            }
        }
        guard let selected, let placement = placements[selected] else { return }
        userZoomPage = selected
        let range = NotebookViewportGeometry.zoomRange(viewport: PageSize(width: bounds.width, height: bounds.height),
            placement: placement)
        logicalZoomRange = range
        changing = true
        maximumZoomScale = max(range.maximum, minimumZoomScale)
        minimumZoomScale = NotebookViewportGeometry.elasticMinimum(range); maximumZoomScale = range.maximum
        changing = false
    }
    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        guard !widthSnapInProgress, let pageID = userZoomPage else { return }
        userZoomPage = nil
        guard pageID == selected,
              !changing, state?.enabled == true, let placement = placements[pageID], let range = logicalZoomRange else { return }
        let center = PagePoint(x: (contentOffset.x + bounds.width / 2) / zoomScale,
                               y: (contentOffset.y + bounds.height / 2) / zoomScale)
        guard let destination = NotebookViewportGeometry.zoomDestination(scale: scale, range: range, page: placement.frame,
            widthRegion: placement.frame,
            viewport: .init(width: bounds.width, height: bounds.height), center: center) else {
            minimumZoomScale = range.minimum; refreshSheets(); return
        }
        zoomTransition = ZoomTransition(fromScale: zoomScale, fromOffset: .init(x: contentOffset.x, y: contentOffset.y), destination: destination)
        widthSnapInProgress = true
        if UIAccessibility.isReduceMotionEnabled { advanceZoomTransition(fraction: 1); return }
        zoomStart = CACurrentMediaTime()
        let link = CADisplayLink(target: self, selector: #selector(zoomTick(_:)))
        zoomLink = link; link.add(to: .main, forMode: .common)
    }
    @objc private func pinchChanged(_ pinch: UIPinchGestureRecognizer) {
        if pinch.state == .began, userZoomPage == nil { scrollViewWillBeginZooming(self, with: surface) }
        // Runs after UIScrollView's own pinch handling: keep the sheet centred
        // (or within the writing-mode range) instead of drifting with the fingers.
        if pinch.state == .changed, !widthSnapInProgress { constrainHorizontalOffset(duringZoom: true) }
        if pinch.state == .ended || pinch.state == .cancelled {
            if userZoomPage != nil { scrollViewDidEndZooming(self, with: surface, atScale: zoomScale) }
            if HangProbe.isInstalled { performanceLog.debug("Pinch ended at zoom \(Double(self.zoomScale), privacy: .public)") }
            // Full-resolution re-render once the fingers are gone.
            DispatchQueue.main.async { [weak self] in self?.refreshSheets() }
        }
    }
    @objc private func zoomTick(_ link: CADisplayLink) {
        advanceZoomTransition(fraction: (link.timestamp - zoomStart) / 0.34)
    }
    private func advanceZoomTransition(fraction: Double) {
        guard let transition = zoomTransition else { stopZoomTransition(); return }
        let value = transition.value(at: fraction)
        changing = true
        setZoomScale(value.scale, animated: false); updateInsets()
        contentOffset = CGPoint(
            x: min(max(value.offset.x, -contentInset.left), max(-contentInset.left, contentSize.width - bounds.width + contentInset.right)),
            y: min(max(value.offset.y, -contentInset.top), max(-contentInset.top, contentSize.height - bounds.height + contentInset.bottom)))
        changing = false
        refreshSheets()
        if fraction >= 1 {
            stopZoomTransition()
            if let range = logicalZoomRange { minimumZoomScale = range.minimum }
            // The snap target centres the sheet; near a seam to a sheet of other
            // width the horizontal limit is blended. Settle here, so the first
            // later layout pass (typically the next pen stroke) moves nothing.
            constrainHorizontalOffset(animated: true)
            refreshSheets()
        }
    }
    private func stopZoomTransition() {
        zoomLink?.invalidate(); zoomLink = nil; zoomTransition = nil; widthSnapInProgress = false
    }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { stopZoomTransition(); userZoomPage = nil; hideFloatingSelection(); laser.reset() }
    }
    private var keyboardOverlap: CGFloat {
        guard let window, let screenFrame = keyboardScreenFrame else { return 0 }
        let rect = convert(window.convert(screenFrame, from: window.screen.coordinateSpace), from: window)
        let overlap = bounds.intersection(rect)
        // Floating keyboards may be panned around; only docked keyboards reserve
        // a full-width bottom inset. Text focus itself never changes zoom.
        guard !overlap.isNull, overlap.width > bounds.width * 0.7, rect.maxY >= bounds.maxY - 4 else { return 0 }
        return max(0, bounds.maxY - overlap.minY)
    }
    @objc private func keyboardChanged(_ note: Notification) {
        keyboardScreenFrame = note.name == UIResponder.keyboardWillHideNotification ? nil
            : (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect)
        let duration = (note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double) ?? 0.25
        let rawCurve = (note.userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey] as? UInt) ?? 7
        UIView.animate(withDuration: UIAccessibility.isReduceMotionEnabled ? 0 : duration, delay: 0,
            options: [UIView.AnimationOptions(rawValue: rawCurve << 16), .beginFromCurrentState]) {
            self.updateInsets(); self.revealCaret()
        }
    }
    private func queueCaretReveal() {
        guard !caretRevealQueued else { return }
        caretRevealQueued = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }; self.caretRevealQueued = false; self.revealCaret()
        }
    }
    // UIKit may try to reveal an entire nested text view. Only the active caret
    // controls document motion; requests from offscreen/preloaded text views stop here.
    override func scrollRectToVisible(_ rect: CGRect, animated: Bool) {
        // Nested PencilKit/TextKit viewport updates are not navigation requests.
        // Search calls super explicitly; text uses the bounded caret reveal below.
    }
    /// Feedback 44: follow the caret as little as possible. Typing keeps a small
    /// margin (or the typewriter line); taps, caret drags, arrow keys, keyboard
    /// and page changes move only a caret that is really hidden, i.e. outside
    /// the free area or under the header (back arrow), a top/floating toolbar
    /// or the keyboard with its format bar. Selections never move the page.
    private func revealCaret() {
        guard !changing, pendingTextFocus == nil, !isDragging, !isDecelerating, !isZooming,
              userZoomPage == nil, !widthSnapInProgress,
              pinchGestureRecognizer?.state != .began, pinchGestureRecognizer?.state != .changed,
              state?.enabled == true, let selected, let sheet = sheets[selected], sheet.editingCaret != nil else { return }
        sheet.layoutIfNeeded()
        let kind = sheet.takeCaretReveal()
        guard let caret = sheet.editingCaret else { return }
        let target = sheet.convert(caret, to: self)
        // Content coordinates: bounds.origin is the content offset.
        let free = PageRect(x: contentOffset.x, y: contentOffset.y + topObstruction,
            width: max(1, bounds.width), height: max(1, bounds.height - keyboardOverlap - topObstruction))
        let chrome = obstructions.map { PageRect($0.offsetBy(dx: contentOffset.x, dy: contentOffset.y)) }
        let delta = NotebookViewportGeometry.caretRevealDelta(caret: PageRect(target), visible: free, obstructions: chrome, kind: kind)
        let result = CGPoint(x: min(max(contentOffset.x + delta.x, -contentInset.left), max(-contentInset.left, contentSize.width - bounds.width + contentInset.right)),
            y: min(max(contentOffset.y + delta.y, -contentInset.top), max(-contentInset.top, contentSize.height - bounds.height + contentInset.bottom)))
        guard abs(result.x - contentOffset.x) > 0.5 || abs(result.y - contentOffset.y) > 0.5 else { return }
        // Typewriter line steps glide briefly; larger jumps stay immediate.
        let glide = kind == .typewriter && !UIAccessibility.isReduceMotionEnabled && abs(result.y - contentOffset.y) < bounds.height / 4
        changing = true
        if glide { UIView.animate(withDuration: 0.12, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) { self.contentOffset = result } }
        else { setContentOffset(result, animated: false) }
        changing = false
    }
    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        HangProbe.hit("Viewport.didZoom")
        laser.refresh()
        if !changing { updateInsets(); queueRefresh() }
    }
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        HangProbe.hit("Viewport.didScroll")
        laser.refresh()
        guard !changing, !pendingJump, let state else { return }
        if focusScrolling && (isDragging || isZooming) { focusScrolling = false }
        if !isZooming && !widthSnapInProgress && !focusScrolling { constrainHorizontalOffset() }
        queueRefresh()
        guard !mode, !isZooming, !widthSnapInProgress, !sheets.values.contains(where: { $0.editingCaret != nil }), isDragging || isDecelerating else { return }
        let center = (contentOffset.y + bounds.height * 0.4) / zoomScale
        if let id = pageAt(vertical: center), id != reported {
            reported = id
            DispatchQueue.main.async { [weak self] in
                guard let self, self.reported == id else { return }
                // A locked editor (import, backup) drops the report; forget it so
                // the next scroll event reports this page again.
                guard self.state?.enabled == true else { self.reported = self.selected; return }
                state.onSelect(id)
            }
        }
    }
    /// At least 48 screen points of the page are visible below the header.
    private func isOnScreen(_ id: UUID) -> Bool {
        guard let frame = frames[id], zoomScale > 0 else { return false }
        let top = topObstruction, height = max(1, bounds.height - top - keyboardOverlap)
        let visible = CGRect(x: contentOffset.x / zoomScale, y: (contentOffset.y + top) / zoomScale,
                             width: bounds.width / zoomScale, height: height / zoomScale)
        let shared = visible.intersection(frame)
        return !shared.isNull && shared.height * zoomScale >= 48 && shared.width * zoomScale >= 48
    }
    private func pageAt(vertical y: CGFloat) -> UUID? {
        if let selected, let frame = frames[selected], y >= frame.minY && y <= frame.maxY { return selected }
        return frames.min { a, b in
            let da = NotebookViewportGeometry.verticalDistance(y, page: PageRect(a.value))
            let db = NotebookViewportGeometry.verticalDistance(y, page: PageRect(b.value))
            return da == db ? a.value.minY < b.value.minY : da < db
        }?.key
    }
    private func constrainHorizontalOffset(duringZoom: Bool = false, animated: Bool = false) {
        guard duringZoom || !isZooming, !widthSnapInProgress, bounds.width > 0, !layoutKey.isEmpty else { return }
        let pages = layoutKey, width = bounds.width, scale = zoomScale, writing = writingScroll
        // Glide between sheets of different width over ~35 % of the viewport.
        // Pure clamp into a blended interval: idempotent, so layout passes after
        // strokes/autosaves at an unchanged scroll position never move the view.
        guard let x = NotebookViewportGeometry.blendedHorizontalOffset(contentOffset.x,
            referenceY: (contentOffset.y + bounds.height * 0.4) / zoomScale, band: bounds.height * 0.35 / zoomScale,
            pages: pages.map(\.frame), range: { index in
                NotebookViewportGeometry.horizontalRange(viewportWidth: width, page: pages[index].frame,
                    scale: scale, anchors: writing ? pages[index].writingScrollAnchors : nil,
                    centre: pages[index].contentFrame.x + pages[index].contentFrame.width / 2)
            }) else { return }
        // Sub-pixel tolerance: UIKit's pixel rounding of contentOffset must not
        // cause a write on every layout pass.
        guard abs(x - contentOffset.x) > 0.5 else { return }
        HangProbe.hit("Viewport.constrainMoved")
        let previous = changing; changing = true
        if animated && !UIAccessibility.isReduceMotionEnabled {
            UIView.animate(withDuration: 0.25, delay: 0, options: [.curveEaseOut, .beginFromCurrentState]) { self.contentOffset.x = x }
        } else { contentOffset.x = x }
        changing = previous
    }
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer is UISwipeGestureRecognizer {
            return mode && state?.enabled == true && state?.fingerDrawing == false
                && !sheets.values.contains(where: { $0.editingCaret != nil }) && abs(zoomScale-fitWidth) < 0.03
        }
        return true
    }
    @objc private func turnPage(_ gesture: UISwipeGestureRecognizer) {
        guard let state, let index = state.pages.firstIndex(where: { $0.id == selected }) else { return }
        let next = index + (gesture.direction == .left ? 1 : -1)
        if state.pages.indices.contains(next) { state.onSelect(state.pages[next].id) }
    }
}

/// Animated removal of the open page (Reduce Motion: instant, as before).
/// Remaining sheets keep their native instances; only their centres animate.
extension NotebookViewport {
    static let deletionDuration: TimeInterval = 0.35
    struct PageDeletion { let id: UUID; let frame: CGRect; let index: Int; let shift: CGFloat }

    /// Exactly the open page disappeared and all other pages kept their order.
    func deletedOpenPage(old: [NotebookPagePlacement], new: [NotebookPagePlacement], oldSelection: UUID?,
                         animatable: Bool) -> PageDeletion? {
        guard animatable, !mode, !UIAccessibility.isReduceMotionEnabled, let oldSelection,
              let index = old.firstIndex(where: { $0.id == oldSelection }), !new.contains(where: { $0.id == oldSelection }),
              old.count == new.count + 1, old.map(\.id).filter({ $0 != oldSelection }) == new.map(\.id) else { return nil }
        let frame = old[index].frame.cgRect
        let shift = index + 1 < old.count ? CGFloat(old[index + 1].frame.y - old[index].frame.y) : 0
        return PageDeletion(id: oldSelection, frame: frame, index: index, shift: shift)
    }

    /// The deleted sheet (no longer managed) shrinks towards its top edge and fades out.
    func collapse(_ sheet: WorksheetView?, frame: CGRect) {
        guard let sheet else { return }
        sheet.isUserInteractionEnabled = false
        sheet.finishTextEditing()
        let base = sheet.transform
        UIView.animate(withDuration: Self.deletionDuration * 0.8, delay: 0, options: [.curveEaseIn, .beginFromCurrentState]) {
            sheet.alpha = 0
            sheet.transform = base.scaledBy(x: 0.94, y: 0.06)
            sheet.center = CGPoint(x: frame.midX, y: frame.minY + frame.height * 0.03)
        } completion: { _ in sheet.removeFromSuperview() }
    }

    /// Following pages slide up into the gap (sheets created just now start
    /// where they would have been), then the focus page scrolls into place.
    func slideAfterDeletion(from old: [UUID: CGPoint], deletion: PageDeletion) {
        let order = layoutKey.map(\.id)
        var moves: [(WorksheetView, CGPoint)] = []
        for (id, sheet) in sheets {
            let target = sheet.center
            let start: CGPoint
            if let previous = old[id] { start = previous }
            else if let index = order.firstIndex(of: id), index >= deletion.index { start = CGPoint(x: target.x, y: target.y + deletion.shift) }
            else { continue }
            guard abs(start.y - target.y) > 0.5 || abs(start.x - target.x) > 0.5 else { continue }
            sheet.center = start; moves.append((sheet, target))
        }
        UIView.animate(withDuration: Self.deletionDuration, delay: 0, usingSpringWithDamping: 0.9, initialSpringVelocity: 0,
                       options: [.beginFromCurrentState, .allowUserInteraction]) {
            for (sheet, target) in moves { sheet.center = target }
        } completion: { [weak self] _ in self?.scrollToFocusAfterDeletion() }
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        guard focusScrolling else { return }
        focusScrolling = false
        constrainHorizontalOffset(); refreshSheets()
    }

    private func scrollToFocusAfterDeletion() {
        guard window != nil, let selected, let placement = placements[selected], !isDragging, !isZooming else { return }
        updateInsets()
        let target = jumpOffsetForAnimation(placement)
        guard abs(target.x - contentOffset.x) > 0.5 || abs(target.y - contentOffset.y) > 0.5 else { return }
        focusScrolling = true
        setContentOffset(target, animated: true)
    }
}

/// Lasso selections dragged off their sheet float above all pages in surface
/// coordinates (so they zoom with the notebook) and drop onto another page.
extension NotebookViewport: SelectionTransferHost {
    func floatSelection(_ lift: SelectionLift, gesture: UIGestureRecognizer) {
        guard placements[lift.pageID] != nil else { hideFloatingSelection(); return }
        if floatingSelection.superview !== surface {
            floatingSelection.isUserInteractionEnabled = false
            floatingSelection.contentMode = .scaleToFill
            floatingSelection.layer.shadowColor = UIColor.black.cgColor
            floatingSelection.layer.shadowOpacity = 0.25; floatingSelection.layer.shadowRadius = 6
            floatingSelection.layer.shadowOffset = CGSize(width: 0, height: 3)
            surface.addSubview(floatingSelection)
        }
        if floatingSelection.image !== lift.snapshot { floatingSelection.image = lift.snapshot }
        if floatingLift == nil {
            floatTarget = lift.pageID
            if #available(iOS 17.5, *), selectionFeedback == nil { selectionFeedback = UICanvasFeedbackGenerator(view: self) }
            selectionFeedback?.prepare()
        }
        floatingLift = lift; floatingGesture = gesture
        surface.bringSubviewToFront(floatingSelection)
        floatingSelection.isHidden = false
        positionFloatingSelection()
        if autoScrollLink == nil {
            let link = CADisplayLink(target: self, selector: #selector(autoScrollTick(_:)))
            link.add(to: .main, forMode: .common); autoScrollLink = link
        }
    }

    func hideFloatingSelection() {
        autoScrollLink?.invalidate(); autoScrollLink = nil
        floatingLift = nil; floatingGesture = nil; floatTarget = nil
        floatingSelection.isHidden = true; floatingSelection.image = nil
    }

    func dropSelection(_ lift: SelectionLift, gesture: UIGestureRecognizer) -> Bool {
        let point = gesture.location(in: surface)
        hideFloatingSelection()
        guard let state, state.enabled, !liveZoom, let transfer = state.onTransfer,
              let source = placements[lift.pageID], let sourceSheet = sheets[lift.pageID],
              let target = dropTarget(at: point), target.id != lift.pageID, let targetSheet = sheets[target.id],
              sourceSheet.objectPageID == lift.pageID, targetSheet.objectPageID == target.id,
              let move = CrossPageMove(source: source, target: target, sourceStart: PagePoint(x: lift.start.x, y: lift.start.y),
                                       surfacePoint: PagePoint(x: point.x, y: point.y)) else { return false }
        let targetContent = targetSheet.objectContent
        let result: SelectionTransfer.Result
        do {
            result = try SelectionTransfer.build(lift, move: move, target: targetContent,
                limits: PageRect(targetSheet.objectLayout.canonicalInkBounds))
        } catch {
            state.onError(error.localizedDescription); return false
        }
        let changes = [PageContentReplacement(pageID: lift.pageID, expected: lift.content, replacement: result.source),
                       PageContentReplacement(pageID: target.id, expected: targetContent, replacement: result.target)]
        guard transfer(changes) else { return false }
        // The model recorded one notebook-wide undo step for both pages.
        sourceSheet.adoptTransfer(result.source)
        targetSheet.adoptTransfer(result.target, selecting: result.selection)
        // The moved selection stays selected on the target, which becomes the
        // focused page without a jump (the selection can be dragged on at once).
        // Deferred so a materialized draft relayouts against the old selection first.
        let id = target.id
        reported = id
        DispatchQueue.main.async { [weak self] in
            guard let self, self.reported == id, self.state?.enabled == true else { return }
            self.state?.onSelect(id)
        }
        return true
    }

    private func dropTarget(at point: CGPoint) -> NotebookPagePlacement? {
        layoutKey.first { $0.frame.cgRect.contains(point) }
    }

    private func positionFloatingSelection() {
        guard let lift = floatingLift, let gesture = floatingGesture, let source = placements[lift.pageID] else { return }
        let point = gesture.location(in: surface)
        let start = source.surfacePoint(forContent: PagePoint(x: lift.start.x, y: lift.start.y))
        let rect = source.surfaceRect(for: PageRect(lift.frame)).cgRect
            .offsetBy(dx: point.x - start.x, dy: point.y - start.y)
        UIView.performWithoutAnimation {
            floatingSelection.frame = rect
            let target = dropTarget(at: point)?.id
            floatingSelection.alpha = target != nil && target != lift.pageID ? 0.85 : 0.45
            if target != floatTarget {
                floatTarget = target
                if let target, target != lift.pageID, #available(iOS 17.5, *), let feedback = selectionFeedback as? UICanvasFeedbackGenerator {
                    feedback.alignmentOccurred(at: gesture.location(in: self))
                }
            }
        }
    }

    /// Scrolls while the floating selection is held near the top/bottom edge.
    @objc private func autoScrollTick(_ link: CADisplayLink) {
        guard floatingLift != nil, let gesture = floatingGesture,
              gesture.state == .began || gesture.state == .changed else { hideFloatingSelection(); return }
        guard !liveZoom, !mode else { return }
        let y = gesture.location(in: self).y - contentOffset.y
        let edge: CGFloat = 72, maximum: CGFloat = 16
        let top = topObstruction + edge, bottom = bounds.height - keyboardOverlap - edge
        var step: CGFloat = 0
        if y < top { step = -maximum * min(1, (top - y) / edge) }
        else if y > bottom { step = maximum * min(1, (y - bottom) / edge) }
        guard step != 0 else { return }
        let limit = max(-contentInset.top, contentSize.height - bounds.height + contentInset.bottom)
        let next = min(max(contentOffset.y + step, -contentInset.top), limit)
        guard abs(next - contentOffset.y) > 0.1 else { return }
        contentOffset.y = next
        surface.bringSubviewToFront(floatingSelection)
        positionFloatingSelection()
    }
}
