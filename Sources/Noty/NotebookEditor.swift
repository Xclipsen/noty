import SwiftUI
import NotebookCore
import OSLog

/// One viewport; only visible pages and their immediate neighbours own native
/// canvases. Ordinary SwiftUI/autosave updates keep those worksheet instances.
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
    var configuration: (Page) -> PageEditor
    var onSelect: (UUID) -> Void
    func makeUIView(context: Context) -> NotebookViewport { NotebookViewport() }
    func updateUIView(_ view: NotebookViewport, context: Context) { view.configure(self) }
}

final class NotebookViewport: UIScrollView, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    private let surface = UIView()
    private var sheets: [UUID: WorksheetView] = [:]
    private var frames: [UUID: CGRect] = [:]
    private var state: NotebookEditor?
    private var layoutKey: [NotebookPagePlacement] = []
    private var placements: [UUID: NotebookPagePlacement] = [:]
    private var mode = false
    private var normalized = false
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
    private var lastSearch: PageRect?
    private var pendingSearch: CGRect?
    private var lastTextFocus: UUID?
    private var pendingTextFocus: TextFlowFocus?
    private var caretRevealQueued = false
    private var keyboardScreenFrame: CGRect?
    private var configurationRevision = 0
    private var sheetRevisions: [UUID: Int] = [:]
    private var refreshQueued = false
    private var refreshing = false
    private let performanceLog = Logger(subsystem: "de.la.noty", category: "editor-performance")
    private var lastSlowRefreshLog: CFTimeInterval = 0


    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self; backgroundColor = UIColor(white: 0.075, alpha: 1)
        contentInsetAdjustmentBehavior = .never; keyboardDismissMode = .interactive
        delaysContentTouches = false; alwaysBounceVertical = true; alwaysBounceHorizontal = true; bouncesZoom = false
        panGestureRecognizer.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        addSubview(surface)
        pinchGestureRecognizer?.addTarget(self, action: #selector(pinchChanged(_:)))
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
        let first = state == nil
        configurationRevision += 1
        let oldSelection = selected
        let focusChanged = next.textFocus.map { $0.requestID != lastTextFocus } ?? false
        if focusChanged, let focus = next.textFocus {
            lastTextFocus = focus.requestID; pendingTextFocus = focus
            reported = focus.pageID
            pendingJump = false
        }
        let modeChanged = mode != next.paging
        let normalizationChanged = normalized != next.normalizeWidths
        if modeChanged || normalizationChanged || (oldSelection != next.selectedPageID && next.selectedPageID != reported) { stopZoomTransition() }
        state = next; mode = next.paging; normalized = next.normalizeWidths; selected = next.selectedPageID
        panGestureRecognizer.minimumNumberOfTouches = next.fingerDrawing ? 2 : 1
        let placement = NotebookViewportLayout(pages: next.pages, selectedPageID: next.selectedPageID,
            paging: mode, normalizeWidths: normalized)
        let key = placement.pages
        if key != layoutKey || modeChanged || normalizationChanged || (mode && oldSelection != selected) {
            changing = true
            let oldFrame = oldSelection.flatMap { frames[$0] }
            let localY = oldFrame.map { (contentOffset.y + bounds.height / 2) / zoomScale - $0.minY }
            layoutKey = key
            frames = Dictionary(uniqueKeysWithValues: key.map { ($0.id, $0.frame.cgRect) })
            placements = Dictionary(uniqueKeysWithValues: key.map { ($0.id, $0) })
            surface.bounds = placement.size.bounds
            surface.center = CGPoint(x: placement.size.width * zoomScale / 2, y: placement.size.height * zoomScale / 2)
            contentSize = CGSize(width: placement.size.width * zoomScale, height: placement.size.height * zoomScale)
            if let localY, let frame = selected.flatMap({ frames[$0] }), !first, !modeChanged, !normalizationChanged, !focusChanged {
                contentOffset.y = (frame.minY + localY) * zoomScale - bounds.height / 2
            }
            changing = false
            if first || modeChanged || normalizationChanged || (!focusChanged && mode && (oldSelection != selected || oldFrame?.size != selected.flatMap({ frames[$0]?.size }))) {
                pendingFit = true; pendingJump = true
            }
        }
        if oldSelection != selected && selected != reported {
            if let oldSelection { sheets[oldSelection]?.finishTextEditing() }
            pendingJump = true
        }
        if fitRequest != next.fitRequest { fitRequest = next.fitRequest; pendingFit = true; pendingJump = true }
        if let page = next.pages.first(where: { $0.id == selected }) {
            let config = next.configuration(page)
            if lastSearch != config.searchHighlight || oldSelection != selected || normalizationChanged {
                lastSearch = config.searchHighlight
                if let hit = config.searchHighlight, let placement = placements[page.id] {
                    pendingSearch = placement.surfaceRect(for: hit).cgRect
                }
            }
        }
        if first { textRequest = next.textInsertRequest }
        setNeedsLayout(); layoutIfNeeded()
        refreshSheets()
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
        guard !changing, let selected, let placement = placements[selected], bounds.width > 40, bounds.height > 40 else { return }
        let frame = (normalized ? placement.contentFrame : placement.frame).cgRect
        changing = true
        let resized = previousSize != bounds.size
        if previousSize != bounds.size || pendingFit {
            let oldSize = previousSize
            let center = CGPoint(x: (contentOffset.x + oldSize.width / 2) / zoomScale,
                                 y: (contentOffset.y + oldSize.height / 2) / zoomScale)
            let relative = zoomScale / fitWidth
            let range = NotebookViewportGeometry.zoomRange(viewport: PageSize(width: bounds.width, height: bounds.height),
                page: placement.frame.size, contentWidth: normalized ? placement.contentFrame.width : nil)
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
            contentOffset = CGPoint(x: frame.midX * zoomScale - bounds.width / 2,
                                    y: frame.minY * zoomScale - contentInset.top)
            pendingJump = false; reported = selected
        }
        if let target = pendingSearch {
            pendingSearch = nil
            scrollRectToVisible(surface.convert(target.insetBy(dx: -16, dy: -16), to: self), animated: false)
        }
        changing = false
        refreshSheets()
        if resized { revealCaret() }
    }
    private func updateInsets() {
        let side = NotebookViewportGeometry.horizontalInset(viewportWidth: bounds.width, contentWidth: contentSize.width)
        let inset = UIEdgeInsets(top: 16, left: side, bottom: 32 + keyboardOverlap, right: side)
        if contentInset != inset { contentInset = inset }
    }
    private func refreshSheets() {
        guard !refreshing, let state, !frames.isEmpty else { return }
        refreshing = true
        let started = CACurrentMediaTime()
        defer {
            refreshing = false
            let now = CACurrentMediaTime()
            if now - started > 0.025, now - lastSlowRefreshLog > 1 {
                lastSlowRefreshLog = now
                performanceLog.notice("Page refresh took \(Int((now - started) * 1000), privacy: .public) ms; native pages=\(self.sheets.count, privacy: .public)")
            }
        }
        let visible = CGRect(x: contentOffset.x / zoomScale, y: contentOffset.y / zoomScale,
                             width: bounds.width / zoomScale, height: bounds.height / zoomScale)
        let nearby = NotebookViewportGeometry.preloadRect(visible: PageRect(x: visible.minX, y: visible.minY,
            width: visible.width, height: visible.height)).cgRect
        var keep = Set(frames.filter { $0.value.intersects(nearby) }.map(\.key))
        if let selected { keep.insert(selected) }
        // Never remove a native text editor during composition or a live stroke.
        for (id, sheet) in sheets where sheet.hasLiveInput { keep.insert(id) }
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
            sheet.transform = CGAffineTransform(scaleX: placement.scale, y: placement.scale)
            sheet.center = CGPoint(x: placement.frame.x + placement.frame.width / 2,
                                   y: placement.frame.y + placement.frame.height / 2)
            if sheetRevisions[page.id] == configurationRevision {
                sheet.updateRendering(visible: convert(bounds, to: sheet), scale: zoomScale * placement.scale)
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
            sheet.configure(config); sheetRevisions[page.id] = configurationRevision
            sheet.updateRendering(visible: convert(bounds, to: sheet), scale: zoomScale * placement.scale)
        }
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
            page: placement.frame.size, contentWidth: normalized ? placement.contentFrame.width : nil)
        logicalZoomRange = range
        changing = true
        maximumZoomScale = max(range.maximum, minimumZoomScale)
        minimumZoomScale = NotebookViewportGeometry.elasticMinimum(range); maximumZoomScale = range.maximum
        changing = false
    }
    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        guard !widthSnapInProgress, let pageID = userZoomPage, pageID == selected,
              !changing, state?.enabled == true, let placement = placements[pageID], let range = logicalZoomRange else { return }
        userZoomPage = nil
        let center = PagePoint(x: (contentOffset.x + bounds.width / 2) / zoomScale,
                               y: (contentOffset.y + bounds.height / 2) / zoomScale)
        guard let destination = NotebookViewportGeometry.zoomDestination(scale: scale, range: range, page: placement.frame,
            widthRegion: normalized ? placement.contentFrame : placement.frame,
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
        if pinch.state == .ended || pinch.state == .cancelled, userZoomPage != nil {
            scrollViewDidEndZooming(self, with: surface, atScale: zoomScale)
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
            refreshSheets()
        }
    }
    private func stopZoomTransition() {
        zoomLink?.invalidate(); zoomLink = nil; zoomTransition = nil; widthSnapInProgress = false
    }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { stopZoomTransition(); userZoomPage = nil }
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
        guard !sheets.values.contains(where: { $0.editingCaret != nil }) else { return }
        super.scrollRectToVisible(rect, animated: animated)
    }
    private func revealCaret() {
        guard !changing, pendingTextFocus == nil, !isDragging, !isDecelerating, !isZooming,
              state?.enabled == true, let selected, let sheet = sheets[selected], sheet.editingCaret != nil else { return }
        sheet.layoutIfNeeded()
        guard let caret = sheet.editingCaret else { return }
        let target = sheet.convert(caret, to: self)
        let visible = PageRect(x: contentOffset.x + 20, y: contentOffset.y + 20,
            width: max(1, bounds.width - 40), height: max(1, bounds.height - keyboardOverlap - 40))
        let offset = NotebookViewportGeometry.caretOffset(caret: PageRect(x: target.minX, y: target.minY,
            width: target.width, height: target.height), visible: visible)
        let result = CGPoint(x: min(max(offset.x - 20, -contentInset.left), max(-contentInset.left, contentSize.width - bounds.width + contentInset.right)),
            y: min(max(offset.y - 20, -contentInset.top), max(-contentInset.top, contentSize.height - bounds.height + contentInset.bottom)))
        guard abs(result.x - contentOffset.x) > 0.5 || abs(result.y - contentOffset.y) > 0.5 else { return }
        changing = true; setContentOffset(result, animated: false); changing = false
    }
    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        if !changing { updateInsets(); refreshSheets() }
    }
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard !changing, !pendingJump, let state else { return }
        refreshSheets()
        guard !mode, !isZooming, !widthSnapInProgress, !sheets.values.contains(where: { $0.editingCaret != nil }), isDragging || isDecelerating else { return }
        let center = (contentOffset.y + bounds.height * 0.4) / zoomScale
        if let id = frames.min(by: { abs($0.value.midY-center) < abs($1.value.midY-center) })?.key, id != reported {
            reported = id
            DispatchQueue.main.async { [weak self] in
                guard let self, self.reported == id, self.state?.enabled == true else { return }
                state.onSelect(id)
            }
        }
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
