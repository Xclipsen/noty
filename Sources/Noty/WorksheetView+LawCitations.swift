// Gesetzesverweise auf der Seite (docs/PARAGRAPH-LINKS.md): Textfelder und der
// Text der Quell-PDF werden nach „§ 35a EStG“ & Co. durchsucht, Treffer dezent
// gepunktet unterstrichen. Stift-Hover (ruhend) oder Zeiger-Hover zeigt die
// Vorschaukarte, ein Zeigerklick öffnet das Gesetz, ein Fingertipp auf die
// Unterstreichung zeigt die Karte. Der Stift auf dem Papier schreibt weiter
// und öffnet nie etwas. Alles abgeleitet: nichts davon kommt ins Heft.
import UIKit
import UIKit.UIGestureRecognizerSubclass
import PDFKit
import Combine
import NotebookCore

/// One recognised citation on a sheet. Geometry in sheet coordinates
/// (`WorksheetView` bounds: canonical page point + content origin), so zoom
/// and scroll of the notebook move it with the page.
struct LawCitationPlacement {
    struct Line {
        /// Hit area of this line's part of the citation.
        var area: CGRect
        /// Underline just below the baseline (follows a rotated field).
        var start: CGPoint
        var end: CGPoint
    }
    struct Key: Hashable { var boxID: UUID?; var location: Int; var length: Int }
    var citation: LawCitation
    /// The text field it stands in; nil: the page's PDF text.
    var boxID: UUID?
    var lines: [Line]
    var bounds: CGRect
    /// Drawn in the colour for dark paper.
    var onDark: Bool
    var key: Key { Key(boxID: boxID, location: citation.range.location, length: citation.range.length) }

    func contains(_ point: CGPoint, slop: CGFloat) -> Bool {
        lines.contains { $0.area.insetBy(dx: -slop, dy: -slop).contains(point) }
    }
}

/// Citation links of one `WorksheetView`: scanning (debounced, off the stroke
/// path, scanner work off the main actor), the underline plane and the hover,
/// click and tap gestures. Every gesture only observes: it never cancels,
/// delays or prevents ink, text editing, selection or scrolling.
@MainActor
final class LawCitationPageLinks: NSObject, UIGestureRecognizerDelegate {
    private weak var sheet: WorksheetView?
    private let underline = LawCitationUnderlineView()
    private let hover = UIHoverGestureRecognizer()
    private let click = UITapGestureRecognizer()
    private let fingerTap = UITapGestureRecognizer()
    private let touches = LawCitationTouchObserver(target: nil, action: nil)
    private var model: LawCitationPreviewModel { .shared }
    private var subscriptions: Set<AnyCancellable> = []
    /// Text editor 2 draws flow text through its own store (read once, like the viewport).
    private let documentEditor = UserDefaults.standard.bool(forKey: AppSettingsKey.textEditor2)

    private(set) var placements: [LawCitationPlacement] = []
    /// Field being edited: its underlines are hidden until editing ends.
    private var editingBox: UUID?
    /// Scanner results per scanned string, for `scannedGeneration`.
    private var scanned: [String: [LawCitation]] = [:]
    private var scannedGeneration = -1
    /// Laid-out citations per field, valid while field, line paper, origin and citations are unchanged.
    private var boxCache: [UUID: (box: TextBox, paper: TextLinePaper, origin: PagePoint, found: [LawCitation], placements: [LawCitationPlacement])] = [:]
    /// `PDFPage.string`, read once per source page.
    private weak var pdfPage: PDFPage?
    private var pdfString: String?
    private var pdfCache: (page: ObjectIdentifier, layout: PageLayout, found: [LawCitation], placements: [LawCitationPlacement])?
    /// Inputs of the last requested scan; equal inputs schedule nothing.
    private var requested: ContentKey?
    private var pending: DispatchWorkItem?
    private var scanToken = 0
    private var pageID: UUID?
    private var displayScale: CGFloat = 1

    // Hover
    private enum HoverKind { case pencil, pointer }
    private var hoverKind: HoverKind?
    private var hoverPoint: CGPoint?
    private var dwellKey: LawCitationPlacement.Key?
    private var dwellAnchor = CGPoint.zero
    private var dwell: DispatchWorkItem?
    /// The card this sheet's hover asked for.
    private var shown: LawCitationPlacement.Key?
    private var feedback: UIFeedbackGenerator?
    /// Finger selection when the tap began: then the tap belongs to the selection.
    private var selectionAtTouchDown = false

    private static let debounce: TimeInterval = 0.3
    private static let pencilDwell: TimeInterval = 0.5
    private static let pointerDwell: TimeInterval = 0.4
    /// No pencil card this soon after the Pencil left the paper (writing hovers between letters).
    private static let writingPause: CFTimeInterval = 1.0
    /// Screen points the resting Pencil may move.
    private static let restTolerance: CGFloat = 6

    private struct ContentKey: Equatable {
        var pageID: UUID
        var layout: PageLayout
        var paper: TextLinePaper
        var boxes: [TextBox]
        var source: ObjectIdentifier?
        var generation: Int
    }

    func install(on sheet: WorksheetView) {
        self.sheet = sheet
        underline.frame = sheet.bounds
        underline.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        underline.onWindowChange = { [weak self] attached in if !attached { self?.detached() } }
        sheet.insertSubview(underline, aboveSubview: sheet.textLayer)

        hover.addTarget(self, action: #selector(hovered(_:)))
        click.addTarget(self, action: #selector(clicked(_:)))
        fingerTap.addTarget(self, action: #selector(tapped(_:)))
        click.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
        fingerTap.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        for gesture in [click, fingerTap] {
            gesture.cancelsTouchesInView = false; gesture.delaysTouchesBegan = false; gesture.delaysTouchesEnded = false
        }
        touches.onTouchDown = { [weak self] in self?.interactionBegan() }
        for gesture in [hover, click, fingerTap, touches] as [UIGestureRecognizer] {
            gesture.delegate = self
            sheet.addGestureRecognizer(gesture)
        }
        model.$scannerGeneration.removeDuplicates().dropFirst()
            .sink { [weak self] _ in self?.scannerChanged() }
            .store(in: &subscriptions)
    }

    /// Scroll or zoom of the notebook began: a shown card goes at once.
    static func viewportMoved() {
        let model = LawCitationPreviewModel.shared
        if model.presentation != nil { model.pageInteractionBegan() }
    }

    // MARK: Scanning

    /// After every configuration (also the callback-only one): rescans
    /// debounced when what the page shows changed.
    func contentChanged() {
        guard let sheet, let editor = sheet.configuration else { return }
        if let previous = pageID, previous != editor.pageID { pageLeft(previous) }
        pageID = editor.pageID
        guard model.scanner != nil else { clear(); return }
        let key = ContentKey(pageID: editor.pageID, layout: editor.layout, paper: sheet.textLayer.linePaper,
                             boxes: editor.textBoxes, source: editor.sourcePage.map { ObjectIdentifier($0) },
                             generation: model.scannerGeneration)
        guard key != requested else { return }
        // Another page or geometry: old positions are never shown on it.
        if requested?.pageID != key.pageID || requested?.layout != key.layout { placements = []; redraw() }
        requested = key
        schedule()
    }

    private func scannerChanged() {
        requested = nil
        // `@Published` reports before the value is set: read it on the next turn.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.model.scanner == nil { self.clear() } else { self.contentChanged() }
        }
    }

    private func schedule(after delay: TimeInterval = LawCitationPageLinks.debounce) {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.scan() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func scan() {
        pending = nil
        guard let sheet, let editor = sheet.configuration, sheet.window != nil else { return }
        guard let scanner = model.scanner else { clear(); return }
        // Never while a stroke is drawn: try again once the Pencil rests.
        if sheet.inkActive || touches.pencilDown { schedule(); return }
        let generation = model.scannerGeneration
        if generation != scannedGeneration || scanned.count > 400 {
            scanned = [:]; boxCache = [:]; pdfCache = nil; scannedGeneration = generation
        }
        if let source = editor.sourcePage {
            if pdfPage !== source { pdfPage = source; pdfString = source.string; pdfCache = nil }
        } else { pdfPage = nil; pdfString = nil; pdfCache = nil }
        var texts = Set(editor.textBoxes.filter { includes($0) }.map(\.text))
        if let pdfString { texts.insert(pdfString) }
        let missing = texts.filter { !$0.isEmpty && scanned[$0] == nil }
        guard !missing.isEmpty else { build(); return }
        scanToken += 1
        let token = scanToken, page = editor.pageID
        Task { [weak self] in
            let found = await Task.detached(priority: .utility) {
                missing.map { ($0, scanner.citations(in: $0)) }
            }.value
            guard let self, self.scanToken == token, self.scannedGeneration == generation,
                  self.model.scannerGeneration == generation, self.sheet?.configuration?.pageID == page else { return }
            for (text, citations) in found { self.scanned[text] = citations }
            // Content changed meanwhile: its own scan follows.
            if self.pending == nil { self.build() }
        }
    }

    private func includes(_ box: TextBox) -> Bool { !(documentEditor && box.flowID != nil) }

    /// Geometry for the found citations (main actor: TextKit and PDFKit).
    private func build() {
        guard let sheet, let editor = sheet.configuration else { return }
        if sheet.inkActive || touches.pencilDown { schedule(); return }
        let origin = sheet.pageLayout.contentOrigin, paper = sheet.textLayer.linePaper
        let dark = (editor.margins?.color ?? editor.paperColor) == .dark
        var result: [LawCitationPlacement] = []
        var cache: [UUID: (box: TextBox, paper: TextLinePaper, origin: PagePoint, found: [LawCitation], placements: [LawCitationPlacement])] = [:]
        // The edited field stays hidden; it is laid out again once editing ends.
        for box in editor.textBoxes where includes(box) && box.id != editingBox {
            guard let found = scanned[box.text], !found.isEmpty else { continue }
            if let cached = boxCache[box.id], cached.box == box, cached.paper == paper, cached.origin == origin, cached.found == found {
                cache[box.id] = cached; result += cached.placements; continue
            }
            let placed = Self.placements(found, in: box, layout: sheet.textLayer.layout(box), origin: origin, onDark: dark)
            cache[box.id] = (box, paper, origin, found, placed)
            result += placed
        }
        boxCache = cache
        if let source = editor.sourcePage, let text = pdfString, let found = scanned[text], !found.isEmpty {
            let id = ObjectIdentifier(source)
            if let cached = pdfCache, cached.page == id, cached.layout == sheet.pageLayout, cached.found == found {
                result += cached.placements
            } else {
                let placed = Self.placements(found, on: source, text: text, layout: sheet.pageLayout)
                pdfCache = (id, sheet.pageLayout, found, placed)
                result += placed
            }
        }
        placements = result
        redraw()
        // A shown card whose citation is gone (text edited) disappears.
        if let shown, !result.contains(where: { $0.key == shown }) { self.shown = nil; model.endHover() }
    }

    /// Lines of each citation in a field, by the layout the editor, PDF and previews share.
    private static func placements(_ found: [LawCitation], in box: TextBox, layout: TextObjectLayout,
                                   origin: PagePoint, onDark: Bool) -> [LawCitationPlacement] {
        let storage = layout.storage, manager = layout.manager, container = layout.container
        guard storage.length == (box.text as NSString).length else { return [] }
        let transform = layout.transform(at: CGPoint(x: box.x + origin.x, y: box.y + origin.y))
        return found.compactMap { citation in
            let range = citation.range
            guard range.length > 0, range.location >= 0, NSMaxRange(range) <= storage.length else { return nil }
            let size = (storage.attribute(.font, at: range.location, effectiveRange: nil) as? UIFont)?.pointSize ?? CGFloat(box.style.fontSize)
            let glyphs = manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            guard glyphs.length > 0 else { return nil }
            var lines: [LawCitationPlacement.Line] = []
            manager.enumerateLineFragments(forGlyphRange: glyphs) { fragment, _, _, lineGlyphs, _ in
                let part = NSIntersectionRange(lineGlyphs, glyphs)
                guard part.length > 0 else { return }
                let rect = manager.boundingRect(forGlyphRange: part, in: container)
                guard !rect.isEmpty, rect.minX.isFinite, rect.width > 0.5 else { return }
                let baseline = fragment.minY + manager.location(forGlyphAt: part.location).y
                let y = min(rect.maxY, baseline + max(1, size * 0.14))
                lines.append(.init(area: rect.applying(transform),
                                   start: CGPoint(x: rect.minX, y: y).applying(transform),
                                   end: CGPoint(x: rect.maxX, y: y).applying(transform)))
            }
            return placement(citation, boxID: box.id, lines: lines, onDark: onDark)
        }
    }

    /// Lines of each citation in the PDF text, mapped like the content search
    /// (`ContentSearchView.pdfLines`): PDF page space → sheet through `pdfToCanvas`.
    /// `PDFPage.string` and `selection(for:)` share their character indices.
    private static func placements(_ found: [LawCitation], on page: PDFPage, text: String, layout: PageLayout) -> [LawCitationPlacement] {
        let length = (text as NSString).length
        let transform = layout.pdfToCanvas.cgTransform
        return found.compactMap { citation in
            let range = citation.range
            guard range.length > 0, range.location >= 0, NSMaxRange(range) <= length,
                  let selection = page.selection(for: range) else { return nil }
            let lines = selection.selectionsByLine().compactMap { line -> LawCitationPlacement.Line? in
                let bounds = line.bounds(for: page)
                guard !bounds.isEmpty, bounds.minX.isFinite, bounds.width > 0.2 else { return nil }
                // PDF space has y up: the line's bottom (just above the descenders)
                // turns with a rotated page through the same transform.
                let y = bounds.minY + bounds.height * 0.12
                return .init(area: bounds.applying(transform),
                             start: CGPoint(x: bounds.minX, y: y).applying(transform),
                             end: CGPoint(x: bounds.maxX, y: y).applying(transform))
            }
            return placement(citation, boxID: nil, lines: lines, onDark: false)
        }
    }

    private static func placement(_ citation: LawCitation, boxID: UUID?, lines: [LawCitationPlacement.Line], onDark: Bool) -> LawCitationPlacement? {
        guard let first = lines.first else { return nil }
        let bounds = lines.dropFirst().reduce(first.area) { $0.union($1.area) }
        return LawCitationPlacement(citation: citation, boxID: boxID, lines: lines, bounds: bounds, onDark: onDark)
    }

    private func clear() {
        pending?.cancel(); pending = nil; scanToken += 1; requested = nil
        cancelDwell()
        if shown != nil { shown = nil; model.endHover() }
        guard !placements.isEmpty || !boxCache.isEmpty else { return }
        placements = []; boxCache = [:]; pdfCache = nil; scanned = [:]
        redraw()
    }

    // MARK: Display

    private var visiblePlacements: [LawCitationPlacement] {
        guard let editingBox else { return placements }
        return placements.filter { $0.boxID != editingBox }
    }
    private func redraw() { underline.show(visiblePlacements, scale: displayScale) }

    /// The sheet's zoom (page point → screen point): dots stay the same size on screen.
    func displayScaleChanged(_ scale: CGFloat) {
        guard scale.isFinite, scale > 0, abs(scale - displayScale) / displayScale > 0.15 else { return }
        displayScale = scale
        underline.restyle(scale: scale)
    }

    /// A field started or ended editing: its underlines hide while it is edited.
    func editingChanged(_ active: Bool) {
        let id = active ? sheet?.textLayer.fields.first(where: { $0.value.editor.isFirstResponder })?.key : nil
        if active, let pageID, model.presentation?.pageID == pageID { model.pageInteractionBegan() }
        guard id != editingBox else { return }
        editingBox = id
        redraw()
        if !active { requested = nil; contentChanged() }
    }

    private func pageLeft(_ previous: UUID) {
        cancelDwell(); shown = nil
        if model.presentation?.pageID == previous { model.pageInteractionBegan() }
    }
    private func detached() {
        pending?.cancel(); pending = nil; requested = nil
        cancelDwell()
        if shown != nil { shown = nil; model.endHover() }
    }

    private func placement(at point: CGPoint, slop: CGFloat) -> LawCitationPlacement? {
        visiblePlacements.first { $0.contains(point, slop: slop) }
    }
    private func placement(_ key: LawCitationPlacement.Key) -> LawCitationPlacement? {
        visiblePlacements.first { $0.key == key }
    }
    private var screenScale: CGFloat { sheet?.screenScale ?? 1 }
    private func anchor(_ placement: LawCitationPlacement) -> CGRect {
        sheet?.convert(placement.bounds, to: nil) ?? placement.bounds
    }

    // MARK: Hover

    /// Pointer hover reports no height and no tilt; a hovering Pencil does
    /// (`zOffset` > 0 above the glass, altitude below vertical). Once a
    /// sequence showed the Pencil it stays one.
    private func classify(_ recognizer: UIHoverGestureRecognizer) -> HoverKind {
        let pencil = recognizer.zOffset > 0.0001 || recognizer.altitudeAngle < .pi / 2 - 0.02
        if recognizer.state == .began || hoverKind == nil { hoverKind = pencil ? .pencil : .pointer }
        else if pencil { hoverKind = .pencil }
        return hoverKind ?? .pointer
    }

    /// Cards appear for reading and writing tools, never while erasing,
    /// presenting with the laser or a stroke is down.
    private func allowsHover(_ kind: HoverKind) -> Bool {
        guard let sheet, sheet.window != nil, model.scanner != nil, !placements.isEmpty else { return false }
        if sheet.tool.isEraser || sheet.tool == .laser { return false }
        if kind == .pencil, sheet.inkActive || touches.pencilDown { return false }
        return true
    }

    @objc private func hovered(_ recognizer: UIHoverGestureRecognizer) {
        guard let sheet else { return }
        switch recognizer.state {
        case .began, .changed:
            let previous = hoverKind
            let kind = classify(recognizer)
            if previous != nil, previous != kind { cancelDwell() }
            let point = recognizer.location(in: sheet), window = recognizer.location(in: nil)
            hoverPoint = point
            if kind == .pencil, recognizer.state == .began, #available(iOS 17.5, *) {
                if feedback == nil { feedback = UICanvasFeedbackGenerator(view: sheet) }
                feedback?.prepare()
            }
            let scale = screenScale
            // Leaving needs a few points more than entering.
            if let shown {
                if let current = placement(shown), current.contains(point, slop: 8 / scale) { return }
                self.shown = nil; model.endHover()
            }
            guard allowsHover(kind), let hit = placement(at: point, slop: 3 / scale) else { cancelDwell(); return }
            let moved = hypot(window.x - dwellAnchor.x, window.y - dwellAnchor.y)
            if hit.key != dwellKey || dwell == nil || (kind == .pencil && moved > Self.restTolerance) {
                dwellKey = hit.key; dwellAnchor = window
                startDwell(kind, after: kind == .pencil ? Self.pencilDwell : Self.pointerDwell)
            }
        default:
            cancelDwell(); hoverKind = nil; hoverPoint = nil
            if shown != nil { shown = nil; model.endHover() }
        }
    }

    private func startDwell(_ kind: HoverKind, after delay: TimeInterval) {
        dwell?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.dwellEnded(kind) }
        dwell = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
    private func cancelDwell() { dwell?.cancel(); dwell = nil; dwellKey = nil }

    private func dwellEnded(_ kind: HoverKind) {
        dwell = nil
        guard sheet != nil, let key = dwellKey, let point = hoverPoint, hoverKind == kind,
              hover.state == .began || hover.state == .changed, allowsHover(kind),
              let hit = placement(key), hit.contains(point, slop: 3 / screenScale) else { dwellKey = nil; return }
        if kind == .pencil {
            // Writing: the Pencil hovers between letters all the time.
            let since = CACurrentMediaTime() - touches.lastPencilLift
            if since < Self.writingPause { startDwell(kind, after: Self.writingPause - since); return }
        }
        shown = key
        model.hover(hit.citation, anchor: anchor(hit), input: kind == .pencil ? .pencilHover : .pointerHover, pageID: pageID)
        if kind == .pencil, #available(iOS 17.5, *), let generator = feedback as? UICanvasFeedbackGenerator {
            generator.alignmentOccurred(at: point)
        }
    }

    // MARK: Click, tap and touches

    /// Pencil or finger on the page: a shown card goes at once.
    private func interactionBegan() {
        cancelDwell()
        shown = nil
        if model.presentation != nil { model.pageInteractionBegan() }
    }

    /// A finger tap cannot draw here and is no text or selection tap.
    private func fingerTapAllowed(_ hit: LawCitationPlacement) -> Bool {
        guard let sheet, let editor = sheet.configuration else { return false }
        let tool = sheet.tool
        // The text tool's taps set the caret or open fields.
        if tool == .text || selectionAtTouchDown || sheet.tool.isEraser || tool == .laser { return false }
        // With finger drawing the finger writes (as `acceptsFingerObjectTaps`).
        if editor.fingerDrawing, editor.enabled, tool != .image, tool != .read { return false }
        // Text document: a finger tap on the flow puts the caret there.
        if editor.flowDocument, let id = hit.boxID, editor.textBoxes.contains(where: { $0.id == id && $0.flowID != nil }) { return false }
        return true
    }

    @objc private func clicked(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended, let sheet, let hit = placement(at: gesture.location(in: sheet), slop: 2 / screenScale) else { return }
        cancelDwell(); shown = nil
        model.open(hit.citation)
    }
    @objc private func tapped(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended, let sheet, let hit = placement(at: gesture.location(in: sheet), slop: 6 / screenScale) else { return }
        cancelDwell(); shown = nil
        model.tap(hit.citation, anchor: anchor(hit), pageID: pageID)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        if gestureRecognizer === fingerTap { selectionAtTouchDown = sheet?.objectLayer.hasTouchSelection ?? false }
        return true
    }
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === click || gestureRecognizer === fingerTap else { return true }
        guard let sheet, model.scanner != nil else { return false }
        let point = gestureRecognizer.location(in: sheet)
        if gestureRecognizer === click {
            // The text tool's click sets the caret or opens a field.
            guard sheet.tool != .text, !sheet.tool.isEraser else { return false }
            return placement(at: point, slop: 2 / screenScale) != nil
        }
        guard let hit = placement(at: point, slop: 6 / screenScale) else { return false }
        return fingerTapAllowed(hit)
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
}

/// Dotted underlines of the sheet's citations. Display only, takes no touches.
@MainActor
final class LawCitationUnderlineView: UIView {
    private let light = CAShapeLayer(), dark = CAShapeLayer()
    var onWindowChange: ((Bool) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false; backgroundColor = .clear; isOpaque = false
        // Low contrast accent: readable on white paper and on PDFs; brighter on dark paper.
        light.strokeColor = UIColor(red: 0.16, green: 0.42, blue: 0.86, alpha: 0.6).cgColor
        dark.strokeColor = UIColor(red: 0.55, green: 0.75, blue: 1, alpha: 0.7).cgColor
        for layer in [light, dark] {
            layer.fillColor = UIColor.clear.cgColor; layer.lineCap = .round
            self.layer.addSublayer(layer)
        }
        restyle(scale: 1)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        onWindowChange?(window != nil)
    }

    func show(_ placements: [LawCitationPlacement], scale: CGFloat) {
        let lightPath = CGMutablePath(), darkPath = CGMutablePath()
        for placement in placements {
            let path = placement.onDark ? darkPath : lightPath
            for line in placement.lines { path.move(to: line.start); path.addLine(to: line.end) }
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        light.path = lightPath.isEmpty ? nil : lightPath
        dark.path = darkPath.isEmpty ? nil : darkPath
        isHidden = placements.isEmpty
        CATransaction.commit()
    }

    /// Dots of about 1.3 screen points every 3.5 screen points at any zoom.
    func restyle(scale: CGFloat) {
        let width = min(2, max(0.35, 1.3 / scale))
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for layer in [light, dark] {
            layer.lineWidth = width
            layer.lineDashPattern = [NSNumber(value: 0.01), NSNumber(value: Double(width * 2.7))]
        }
        CATransaction.commit()
    }
}

/// Pencil and finger touches on the sheet: touch-down hides a card; Pencil
/// lifts tell the hover when writing paused. Never recognises, cancels or delays.
@MainActor
final class LawCitationTouchObserver: UIGestureRecognizer {
    var onTouchDown: (() -> Void)?
    private var active = Set<UITouch>()
    private var pencils = Set<UITouch>()
    private(set) var lastPencilLift: CFTimeInterval = 0
    var pencilDown: Bool { !pencils.isEmpty }

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        cancelsTouchesInView = false; delaysTouchesBegan = false; delaysTouchesEnded = false
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        active.formUnion(touches)
        pencils.formUnion(touches.filter { $0.type == .pencil })
        if touches.contains(where: { $0.type == .pencil || $0.type == .direct }) { onTouchDown?() }
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) { }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) { lift(touches) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { lift(touches) }
    private func lift(_ touches: Set<UITouch>) {
        if !pencils.isDisjoint(with: touches) { lastPencilLift = CACurrentMediaTime() }
        pencils.subtract(touches); active.subtract(touches)
        if active.isEmpty { state = .failed }
    }
    override func reset() {
        if !pencils.isEmpty { lastPencilLift = CACurrentMediaTime() }
        pencils.removeAll(); active.removeAll()
        super.reset()
    }
    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }
}
