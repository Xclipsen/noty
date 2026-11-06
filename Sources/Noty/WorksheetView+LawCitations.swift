// Gesetzesverweise auf der Seite (docs/PARAGRAPH-LINKS.md): Textfelder und der
// Text der Quell-PDF werden nach „§ 35a EStG“ & Co. durchsucht, Treffer dezent
// gepunktet unterstrichen. Stift-Hover (ruhend) oder Zeiger-Hover zeigt die
// Vorschaukarte, ein Zeigerklick öffnet das Gesetz, ein Fingertipp auf die
// Unterstreichung zeigt die Karte (ein zweiter öffnet). Der Stift auf dem
// Papier schreibt weiter und öffnet nie etwas. Alles abgeleitet: nichts davon
// kommt ins Heft. Wiederhergestellte Kopien haben keine Verweise.
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
    /// Identity on the page: two equal citations in different fields (or
    /// places) are different placements.
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
/// click and tap gestures. The gestures never cancel, delay or prevent ink,
/// scrolling or text editing; a tap on an underline is owned by the citation
/// (`ownsTap`): the field below is then neither selected nor edited.
@MainActor
final class LawCitationPageLinks: NSObject, UIGestureRecognizerDelegate {
    private weak var sheet: WorksheetView?
    private var installed = false
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
    /// Fields an object preview (drag, resize, lift) shows elsewhere than the page.
    private var previewBoxes = Set<UUID>()
    /// Scanner results for the current page's texts, for `scannedGeneration`.
    private var scanned: [String: [LawCitation]] = [:]
    private var scannedGeneration = -1
    /// Laid-out citations per field, valid while field, line paper, origin and citations are unchanged.
    private var boxCache: [UUID: (box: TextBox, paper: TextLinePaper, origin: PagePoint, found: [LawCitation], placements: [LawCitationPlacement])] = [:]
    /// `PDFPage.string`, read once per source page (`LawCitationPDFText`).
    private weak var pdfPage: PDFPage?
    private weak var pdfRequested: PDFPage?
    private var pdfLoaded = false
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
    /// The card this sheet's hover asked for (leaving it ends the hover).
    private var shown: LawCitationPlacement.Key?
    /// The placement this sheet last presented (hover or tap): the model
    /// compares citations, this tells equal ones apart.
    private var presentedKey: LawCitationPlacement.Key?
    private var feedback: UIFeedbackGenerator?
    /// The placement the last touch-down's tap belongs to (`ownsTap`).
    private var downTarget: LawCitationPlacement.Key?

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

    /// Only remembers the sheet: views and gestures follow with the first
    /// configuration that allows links (never in a restored copy).
    func install(on sheet: WorksheetView) { self.sheet = sheet }

    private func activate() {
        guard !installed, let sheet else { return }
        installed = true
        underline.frame = sheet.bounds
        underline.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        underline.onWindowChange = { [weak self] attached in
            guard let self else { return }
            if attached { self.requested = nil; self.contentChanged() } else { self.detached() }
        }
        sheet.insertSubview(underline, aboveSubview: sheet.textLayer)

        hover.addTarget(self, action: #selector(hovered(_:)))
        click.addTarget(self, action: #selector(clicked(_:)))
        fingerTap.addTarget(self, action: #selector(tapped(_:)))
        click.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
        fingerTap.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        for gesture in [click, fingerTap] {
            gesture.cancelsTouchesInView = false; gesture.delaysTouchesBegan = false; gesture.delaysTouchesEnded = false
        }
        touches.onTouchDown = { [weak self] touch in self?.touchBegan(touch) }
        for gesture in [hover, click, fingerTap, touches] as [UIGestureRecognizer] {
            gesture.delegate = self
            sheet.addGestureRecognizer(gesture)
        }
        model.$scannerGeneration.removeDuplicates().dropFirst()
            .sink { [weak self] _ in self?.scannerChanged() }
            .store(in: &subscriptions)
    }

    // MARK: Viewport

    private static var viewports: [ObjectIdentifier: (offset: CGPoint, zoom: CGFloat)] = [:]
    /// Scroll or zoom of the notebook began: a shown card goes at once.
    static func viewportMoved() {
        let model = LawCitationPreviewModel.shared
        if model.presentation != nil { DispatchQueue.main.async { model.pageInteractionBegan() } }
    }
    /// Every scroll/zoom callback, also programmatic ones (jumps, caret
    /// reveal): a card goes once offset or zoom really changed.
    static func viewportChanged(_ viewport: UIScrollView) {
        let id = ObjectIdentifier(viewport), now = (offset: viewport.contentOffset, zoom: viewport.zoomScale)
        let last = viewports[id]
        viewports[id] = now
        guard let last, LawCitationPreviewModel.shared.presentation != nil else { return }
        if hypot(now.offset.x - last.offset.x, now.offset.y - last.offset.y) > 0.5 || abs(now.zoom / max(last.zoom, 0.0001) - 1) > 0.001 {
            viewportMoved()
        }
    }

    /// Model changes never run inside a SwiftUI update (configure).
    private enum Deferred { case dismiss, pageInteraction }
    private func later(_ action: Deferred) {
        DispatchQueue.main.async {
            switch action {
            case .dismiss: LawCitationPreviewModel.shared.dismiss()
            case .pageInteraction: LawCitationPreviewModel.shared.pageInteractionBegan()
            }
        }
    }
    /// The model shows a card for this page.
    private var presentsHere: Bool { pageID != nil && model.presentation?.pageID == pageID }

    // MARK: Scanning

    /// After every configuration (`full`) and every callback-only one:
    /// rescans debounced when what the page shows changed, at once when all
    /// its texts are already scanned.
    func contentChanged(full: Bool = false) {
        guard let sheet, let editor = sheet.configuration else { return }
        guard editor.lawCitations else { clear(); return }
        activate()
        if full, !previewBoxes.isEmpty { previewBoxes = []; redraw() }
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
        schedule(after: allScanned(editor) ? 0 : Self.debounce)
    }

    /// Every text the page shows has its scanner result (moved or restyled fields).
    private func allScanned(_ editor: PageEditor) -> Bool {
        guard scannedGeneration == model.scannerGeneration else { return false }
        if let source = editor.sourcePage {
            guard pdfPage === source, pdfLoaded else { return false }
            if let pdfString, !pdfString.isEmpty, scanned[pdfString] == nil { return false }
        }
        return editor.textBoxes.allSatisfy { !scans($0) || $0.text.isEmpty || scanned[$0.text] != nil }
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
        guard let sheet, let editor = sheet.configuration, editor.lawCitations, sheet.window != nil else { return }
        guard let scanner = model.scanner else { clear(); return }
        // Never while a stroke is drawn: try again once the Pencil rests.
        if sheet.inkActive || touches.pencilDown { schedule(); return }
        let generation = model.scannerGeneration
        if generation != scannedGeneration {
            scanned = [:]; boxCache = [:]; pdfCache = nil; scannedGeneration = generation
        }
        if let source = editor.sourcePage {
            if pdfPage !== source { pdfPage = source; pdfString = nil; pdfLoaded = false; pdfCache = nil }
            // PDFKit text extraction: one sheet per run-loop turn (`LawCitationPDFText`).
            if !pdfLoaded { requestPDFText(source); return }
        } else { pdfPage = nil; pdfRequested = nil; pdfString = nil; pdfLoaded = false; pdfCache = nil }
        var texts = Set(editor.textBoxes.filter { scans($0) }.map(\.text))
        if let pdfString { texts.insert(pdfString) }
        texts.remove("")
        // Only this page's texts stay cached.
        scanned = scanned.filter { texts.contains($0.key) }
        let missing = texts.filter { scanned[$0] == nil }
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

    private func requestPDFText(_ page: PDFPage) {
        guard pdfRequested !== page else { return }
        pdfRequested = page
        LawCitationPDFText.enqueue { [weak self, weak page] in
            guard let self else { return }
            guard let page, self.pdfPage === page, !self.pdfLoaded else {
                // Given up (another page meanwhile): a later scan may ask again.
                if self.pdfRequested === page || page == nil { self.pdfRequested = nil }
                return
            }
            self.pdfString = page.string; self.pdfLoaded = true; self.pdfRequested = nil
            self.schedule(after: 0)
        }
    }

    /// Fields whose text is scanned: not the edited one (it changes with every
    /// key), not Text editor 2's flow (drawn by its own store).
    private func scans(_ box: TextBox) -> Bool { !(documentEditor && box.flowID != nil) && box.id != editingBox }

    /// Geometry for the found citations (main actor: TextKit and PDFKit).
    private func build() {
        guard let sheet, let editor = sheet.configuration else { return }
        if sheet.inkActive || touches.pencilDown { schedule(); return }
        let origin = sheet.pageLayout.contentOrigin, paper = sheet.textLayer.linePaper
        let dark = (editor.margins?.color ?? editor.paperColor) == .dark
        var result: [LawCitationPlacement] = []
        var cache: [UUID: (box: TextBox, paper: TextLinePaper, origin: PagePoint, found: [LawCitation], placements: [LawCitationPlacement])] = [:]
        // The edited field stays hidden; it is laid out again once editing ends.
        for box in editor.textBoxes where scans(box) {
            guard let found = scanned[box.text], !found.isEmpty else { continue }
            if let cached = boxCache[box.id], cached.box == box, cached.paper == paper, cached.origin == origin, cached.found == found {
                cache[box.id] = cached; result += cached.placements; continue
            }
            let placed = Self.placements(found, in: box, layout: sheet.textLayer.layout(box), origin: origin, onDark: dark)
            cache[box.id] = (box, paper, origin, found, placed)
            result += placed
        }
        boxCache = cache
        if let source = editor.sourcePage, pdfPage === source, let text = pdfString, let found = scanned[text], !found.isEmpty {
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
        if let shown, !result.contains(where: { $0.key == shown }) { self.shown = nil }
        // A card (any input) whose citation is gone from this page (text
        // edited, field deleted, page replaced) disappears.
        if presentsHere, let citation = model.presentation?.citation,
           !result.contains(where: { $0.key == presentedKey && $0.citation == citation }) {
            presentedKey = nil
            later(.dismiss)
        }
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
    /// (`ContentSearchView.pdfLines`): PDF page space → sheet through
    /// `pdfToCanvas`. A selection whose text is not the citation's (PDFs whose
    /// `string` indices differ from `selection(for:)`) is skipped, never guessed.
    private static func placements(_ found: [LawCitation], on page: PDFPage, text: String, layout: PageLayout) -> [LawCitationPlacement] {
        let length = (text as NSString).length
        let transform = layout.pdfToCanvas.cgTransform
        return found.compactMap { citation in
            let range = citation.range
            guard range.length > 0, range.location >= 0, NSMaxRange(range) <= length,
                  let selection = page.selection(for: range),
                  comparable(selection.string ?? "") == comparable(citation.text) else { return nil }
            let lines = selection.selectionsByLine().compactMap { line -> LawCitationPlacement.Line? in
                let bounds = line.bounds(for: page)
                guard !bounds.isEmpty, bounds.minX.isFinite else { return nil }
                // Displayed first (rotated pages turn the line), then underlined
                // along its longer side at the bottom edge.
                let area = bounds.applying(transform)
                guard max(area.width, area.height) > 0.2 else { return nil }
                if area.width >= area.height {
                    let y = area.maxY - area.height * 0.12
                    return .init(area: area, start: CGPoint(x: area.minX, y: y), end: CGPoint(x: area.maxX, y: y))
                }
                // Vertical text on the displayed page.
                let x = area.maxX - area.width * 0.12
                return .init(area: area, start: CGPoint(x: x, y: area.minY), end: CGPoint(x: x, y: area.maxY))
            }
            return placement(citation, boxID: nil, lines: lines, onDark: false)
        }
    }
    /// Whitespace collapsed, soft hyphens removed.
    private static func comparable(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{00AD}", with: "")
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    private static func placement(_ citation: LawCitation, boxID: UUID?, lines: [LawCitationPlacement.Line], onDark: Bool) -> LawCitationPlacement? {
        guard let first = lines.first else { return nil }
        let bounds = lines.dropFirst().reduce(first.area) { $0.union($1.area) }
        return LawCitationPlacement(citation: citation, boxID: boxID, lines: lines, bounds: bounds, onDark: onDark)
    }

    private func clear() {
        pending?.cancel(); pending = nil; scanToken += 1; requested = nil
        cancelDwell()
        shown = nil
        if presentsHere { presentedKey = nil; later(.dismiss) }
        guard !placements.isEmpty || !boxCache.isEmpty || !scanned.isEmpty else { return }
        placements = []; boxCache = [:]; pdfCache = nil; scanned = [:]
        redraw()
    }

    // MARK: Display

    private var visiblePlacements: [LawCitationPlacement] {
        guard editingBox != nil || !previewBoxes.isEmpty else { return placements }
        return placements.filter { $0.boxID.map { $0 != editingBox && !previewBoxes.contains($0) } ?? true }
    }
    private func redraw() { if installed { underline.show(visiblePlacements) } }

    /// The sheet's zoom (page point → screen point): dots stay the same size on screen.
    func displayScaleChanged(_ scale: CGFloat) {
        guard installed, scale.isFinite, scale > 0, abs(scale - displayScale) / displayScale > 0.15 else { return }
        displayScale = scale
        underline.restyle(scale: scale)
    }

    /// An object preview (drag, resize, lift of a selection) shows `boxes`:
    /// fields that differ from the page are hidden until the next configuration.
    func objectPreview(_ boxes: [TextBox]) {
        guard installed, let current = sheet?.configuration?.textBoxes else { return }
        let committed = Dictionary(current.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var moved = Set(boxes.filter { committed[$0.id] != $0 }.map(\.id))
        // Fields lifted off the page (moved to another one) are gone from the preview.
        let shown = Set(boxes.map(\.id))
        moved.formUnion(current.map(\.id).filter { !shown.contains($0) })
        guard moved != previewBoxes else { return }
        previewBoxes = moved
        redraw()
        if presentsHere, let key = presentedKey, let id = key.boxID, moved.contains(id) {
            presentedKey = nil; later(.dismiss)
        }
    }

    /// A field started or ended editing: its underlines hide while it is edited.
    func editingChanged(_ active: Bool) {
        guard installed else { return }
        let id = active ? sheet?.textLayer.fields.first(where: { $0.value.editor.isFirstResponder })?.key : nil
        if active, presentsHere { later(.pageInteraction) }
        guard id != editingBox else { return }
        let previous = editingBox
        editingBox = id
        redraw()
        // A field left (also straight into another one) is laid out again.
        if previous != nil { requested = nil; contentChanged() }
    }

    private func pageLeft(_ previous: UUID) {
        cancelDwell(); shown = nil; presentedKey = nil
        if model.presentation?.pageID == previous { later(.pageInteraction) }
    }
    private func detached() {
        pending?.cancel(); pending = nil; requested = nil
        cancelDwell(); shown = nil
        if presentsHere { presentedKey = nil; later(.dismiss) }
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
    /// The model's card shows exactly this placement.
    private func presents(_ hit: LawCitationPlacement) -> Bool {
        presentsHere && presentedKey == hit.key && model.presentation?.citation == hit.citation
    }
    /// The model tells citations apart by their value: an equal one at
    /// another place (another field) first closes the shown card.
    private func prepareToPresent(_ hit: LawCitationPlacement) {
        if presentsHere, model.presentation?.citation == hit.citation, presentedKey != hit.key { model.dismiss() }
        presentedKey = hit.key
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
            if kind == .pencil, recognizer.state == .began, !placements.isEmpty, #available(iOS 17.5, *) {
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
        prepareToPresent(hit)
        model.hover(hit.citation, anchor: anchor(hit), input: kind == .pencil ? .pencilHover : .pointerHover, pageID: pageID)
        if kind == .pencil, #available(iOS 17.5, *), let generator = feedback as? UICanvasFeedbackGenerator {
            generator.alignmentOccurred(at: point)
        }
    }

    // MARK: Click, tap and touches

    /// Pencil or finger on the page: a shown card goes at once, except under
    /// a finger on exactly the presented citation (its second tap opens it).
    /// Whether a tap of this touch belongs to a citation is decided here,
    /// before any tap action runs (their order is not defined).
    private func touchBegan(_ touch: UITouch) {
        downTarget = nil
        if let sheet {
            let point = touch.location(in: sheet)
            switch touch.type {
            case .direct: downTarget = fingerTarget(at: point)?.key
            case .indirectPointer: downTarget = clickTarget(at: point)?.key
            default: break
            }
        }
        guard touch.type == .pencil || touch.type == .direct else { return }
        cancelDwell()
        shown = nil
        guard model.presentation != nil else { return }
        if touch.type == .direct, let sheet, let hit = placement(at: touch.location(in: sheet), slop: 6 / screenScale), presents(hit) { return }
        model.pageInteractionBegan()
    }

    /// The citation at `point` takes the tap of the touch that began last:
    /// its card or law window instead of a selection (`downTarget`). Kept
    /// conservative, Pencil hover is the main way to a card.
    func ownsTap(at point: CGPoint) -> Bool { target(at: point) != nil }

    /// The placement decided at touch-down, if the tap still lands on it.
    private func target(at point: CGPoint) -> LawCitationPlacement? {
        guard installed, model.scanner != nil, let key = downTarget, let hit = placement(key),
              hit.contains(point, slop: 6 / screenScale) else { return nil }
        return hit
    }

    /// A click opens only a citation whose hover card is shown (the user saw
    /// it after the dwell); a quick click selects as before.
    private func clickTarget(at point: CGPoint) -> LawCitationPlacement? {
        guard let sheet, sheet.tool != .text, !sheet.tool.isEraser, sheet.tool != .laser,
              let hit = placement(at: point, slop: 2 / screenScale), presents(hit),
              model.presentation?.input != .touch else { return nil }
        return hit
    }
    /// A finger tap takes a citation only where nothing else can mean it:
    /// PDF text with no object above it, or a field's text with the read
    /// tool. Never a checkbox, a drawing finger, the text tool, the plane
    /// tools (shape, lasso, image: their own taps and selections) or while
    /// a finger selection stands.
    private func fingerTarget(at point: CGPoint) -> LawCitationPlacement? {
        guard let sheet, let editor = sheet.configuration, !touches.selectionAtDown,
              !sheet.objectLayer.handlesTapsItself, !sheet.fingerTapHitsCheckbox(point) else { return nil }
        let tool = sheet.tool
        if tool == .text || tool.isEraser || tool == .laser { return nil }
        // With finger drawing the finger writes (as `acceptsFingerObjectTaps`).
        if editor.fingerDrawing, editor.enabled, tool != .read { return nil }
        guard let hit = placement(at: point, slop: 6 / screenScale) else { return nil }
        if hit.boxID != nil { return tool == .read ? hit : nil }
        return sheet.objectHits(at: point).isEmpty ? hit : nil
    }

    @objc private func clicked(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended, let sheet, let hit = target(at: gesture.location(in: sheet)) else { return }
        cancelDwell(); shown = nil
        presentedKey = nil
        model.open(hit.citation)
    }
    @objc private func tapped(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended, let sheet, let hit = target(at: gesture.location(in: sheet)) else { return }
        cancelDwell(); shown = nil
        prepareToPresent(hit)
        model.tap(hit.citation, anchor: anchor(hit), pageID: pageID)
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === click || gestureRecognizer === fingerTap else { return true }
        guard let sheet, model.scanner != nil else { return false }
        let wanted: UITouch.TouchType = gestureRecognizer === click ? .indirectPointer : .direct
        return touches.lastType == wanted && target(at: gestureRecognizer.location(in: sheet)) != nil
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
}

/// `PDFPage.string` for the sheets, one page per run-loop turn with a short
/// pause between them: a dense PDF scrolled into view does not read all its
/// loaded pages in one frame.
@MainActor
enum LawCitationPDFText {
    private static var queue: [@MainActor () -> Void] = []
    private static var running = false
    static func enqueue(_ work: @escaping @MainActor () -> Void) {
        queue.append(work)
        guard !running else { return }
        running = true
        next()
    }
    private static func next() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { step() }
    }
    private static func step() {
        guard !queue.isEmpty else { running = false; return }
        queue.removeFirst()()
        next()
    }
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

    func show(_ placements: [LawCitationPlacement]) {
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

/// Touches on the sheet: touch-down hides a card and records what a tap
/// then means (input type, a finger selection standing); Pencil lifts tell
/// the hover when writing paused. Never recognises, cancels or delays.
@MainActor
final class LawCitationTouchObserver: UIGestureRecognizer {
    var onTouchDown: ((UITouch) -> Void)?
    private var active = Set<UITouch>()
    private var pencils = Set<UITouch>()
    private(set) var lastPencilLift: CFTimeInterval = 0
    /// Type of the most recent touch-down and whether a finger selection stood then.
    private(set) var lastType: UITouch.TouchType?
    private(set) var selectionAtDown = false
    var pencilDown: Bool { !pencils.isEmpty }

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        cancelsTouchesInView = false; delaysTouchesBegan = false; delaysTouchesEnded = false
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        active.formUnion(touches)
        pencils.formUnion(touches.filter { $0.type == .pencil })
        guard let touch = touches.first else { return }
        lastType = touch.type
        selectionAtDown = (view as? WorksheetView)?.objectLayer.hasTouchSelection ?? false
        onTouchDown?(touch)
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
