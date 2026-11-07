import SwiftUI
import UIKit
import Combine
import os
import NotebookCore

struct NativeLawText: UIViewRepresentable {
    var text: String
    var html: String?
    var notes: String
    var sectionID: String
    var fontSize: Double
    var marks: [LawTextMark]
    /// Where to scroll: an Absatz (kept in view and briefly highlighted) or a
    /// restored offset; a new `id` repeats the same target.
    var jump: LawTextJump? = nil
    var selection: LawTextSelection
    var pen: LawPenMode
    /// The law shown: a bare „§ 10“ in its text means this law.
    var lawID = ""
    /// Its version shown (the hover card of a reference into the same law reads it).
    var versionID = ""
    /// Hover cards over cross-references: only in the law window (the card layer is there).
    var hoverCards = false
    /// A tap on a cross-reference in the text (not while marking with Pencil).
    var onCitation: ((LawCitation) -> Void)? = nil
    /// Whether the shown law has this section key: references into the same
    /// law that point nowhere get no link (a misattributed list, Core note).
    var hasSection: (@Sendable (String) -> Bool)? = nil
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> LawTextContainer {
        let container = LawTextContainer()
        let v = container.textView
        v.isEditable = false; v.isSelectable = true; v.backgroundColor = LawReadingStyle.background
        // Below the last line: room for the footer and a mark bar under it.
        v.textContainerInset = UIEdgeInsets(top: 8, left: 12, bottom: LawReadingStyle.bottomInset, right: 12); v.delegate = context.coordinator
        container.overlay.bottomReserve = LawReadingStyle.footerReserve
        v.scrollsToTop = false
        let stroke = LawPencilStroke(target: context.coordinator, action: #selector(Coordinator.pencil(_:)))
        v.addGestureRecognizer(stroke)
        context.coordinator.stroke = stroke
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped(_:)))
        tap.delegate = context.coordinator
        v.addGestureRecognizer(tap)
        context.coordinator.tap = tap
        // Cross-references: a plain tap only, after a double tap (word
        // selection) has failed (`shouldRequireFailureOf`).
        let linkTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.linkTapped(_:)))
        linkTap.delegate = context.coordinator
        v.addGestureRecognizer(linkTap)
        context.coordinator.linkTap = linkTap
        // Hover over a cross-reference (Pencil, pointer) shows the citation card.
        let hover = UIHoverGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.hovered(_:)))
        hover.delegate = context.coordinator
        v.addGestureRecognizer(hover)
        // Sees every touch without taking it: touch-down hides a card of the
        // reader, a lifted Pencil delays the next Pencil card (writing pause).
        let watch = LawTouchWatch()
        watch.delegate = context.coordinator
        watch.onBegan = { [weak coordinator = context.coordinator] touch in coordinator?.touchBegan(touch) }
        watch.onEnded = { [weak coordinator = context.coordinator] touch in coordinator?.touchEnded(touch) }
        watch.onReset = { [weak coordinator = context.coordinator] in coordinator?.touchesReset() }
        v.addGestureRecognizer(watch)
        context.coordinator.container = container
        container.onLayout = { [weak coordinator = context.coordinator] in coordinator?.applyTarget() }
        container.overlay.anchor = { [weak coordinator = context.coordinator] in coordinator?.barAnchor() }
        return container
    }
    func updateUIView(_ container: LawTextContainer, context: Context) {
        updateUIView(container, coordinator: context.coordinator)
    }
    func updateUIView(_ container: LawTextContainer, coordinator c: Coordinator) {
        let v = container.textView
        c.parent = self
        selection.view = v
        // Arrow keys and the space bar scroll on purpose: no target holds the text then.
        selection.willScroll = { [weak c] in c?.dropTarget(); LawCitationPreviewModel.shared.dismissReaderCard() }
        // Building the bar's hosting controllers inside SwiftUI's update pass
        // re-entered the graph (watchdog hang in Build 97): attach afterwards.
        if container.overlay.needsAttach(controller: selection.controller, selection: selection) {
            let controller = selection.controller, selection = selection
            DispatchQueue.main.async { [weak container] in container?.overlay.attach(controller: controller, selection: selection) }
        }
        // Highlighter/eraser: Pencil marks; fingers keep scrolling and selecting.
        // Other notebook tools: Pencil scrolls and selects like a finger.
        let penActive = pen.kind != .none
        if c.penActive != penActive {
            c.penActive = penActive
            c.stroke?.isEnabled = penActive
            v.panGestureRecognizer.allowedTouchTypes = penActive ? lawTouchTypesWithoutPencil : lawAllTouchTypes
            c.tap?.allowedTouchTypes = penActive ? lawTouchTypesWithoutPencil : lawAllTouchTypes
            // Markieren/Radieren: links are inactive (Pencil marks, fingers select).
            c.linkTap?.isEnabled = !penActive
            c.applyHighlights()
        }
        let bodyKey = "\(sectionID):\(fontSize):\(text.hashValue):\(html.hashValue):\(notes.hashValue)"
        if c.bodyKey != bodyKey {
            let changedSection = c.sectionID != sectionID
            let resized = !changedSection && c.fontSize != fontSize
            let offset = v.contentOffset
            // The first visible character stays on top when the size changes.
            let topCharacter = resized ? v.closestPosition(to: CGPoint(x: v.textContainerInset.left + 1, y: offset.y + v.textContainerInset.top + 1)) .map { v.offset(from: v.beginningOfDocument, to: $0) } : nil
            let attributes = LawReadingStyle.attributes(fontSize: fontSize)
            let richKey = "\(sectionID):\(text.hashValue):\(html.hashValue)"
            if c.richKey != richKey {
                // The HTML importer spins a nested run loop through WebKit; inside
                // updateUIView that re-entered SwiftUI's update and hung the app
                // (Build 97). Show the plain text now, the rich text right after.
                c.richKey = richKey; c.rich = nil
                let html = html, text = text, key = richKey
                if html?.isEmpty == false {
                    DispatchQueue.main.async { [weak c, weak container] in
                        guard let c, let container, c.richKey == key else { return }
                        // The importer's nested run loop may deliver another
                        // section's import: never one inside the other (that
                        // section keeps its plain text).
                        guard !Coordinator.importing else { return }
                        c.importRich(html: html, text: text, key: key)
                        guard c.richKey == key, c.rich != nil else { return }
                        c.bodyKey = ""
                        c.parent.updateUIView(container, coordinator: c)
                    }
                }
            }
            let body = c.rich.map { c.scaled($0, to: fontSize) } ?? NSMutableAttributedString(string: text, attributes: attributes)
            // One reading colour and spacing for HTML and plain text.
            LawReadingStyle.apply(to: body, fontSize: fontSize)
            let rendered = body.string
            if !notes.isEmpty { body.append(NSAttributedString(string: "\n\n" + notes, attributes: attributes)) }
            c.renderedText = rendered; c.bodyLength = (rendered as NSString).length
            selection.text = rendered
            c.updating = true
            v.attributedText = body
            if changedSection { v.setContentOffset(.zero, animated: false) } else if c.target != nil {
                // A jump in progress: `applyTarget` below places it in the new text.
                v.layoutIfNeeded()
            } else {
                v.layoutIfNeeded()
                var y = offset.y
                if let topCharacter, let start = v.position(from: v.beginningOfDocument, offset: topCharacter),
                   let end = v.position(from: start, offset: 1), let range = v.textRange(from: start, to: end) {
                    let rect = v.firstRect(for: range)
                    if rect.minY.isFinite { y = rect.minY - v.textContainerInset.top }
                }
                v.setContentOffset(CGPoint(x: 0, y: min(max(0, y), max(0, v.contentSize.height - v.bounds.height))), animated: false)
            }
            c.updating = false
            c.bodyKey = bodyKey; c.sectionID = sectionID; c.fontSize = fontSize; c.marksKey = nil
            if changedSection { c.endFlash(redraw: false); c.dropTarget(); c.endHoverCard() }
            c.refreshFlashRange()
            // The rich text replacing the plain one (or a new size) moves the
            // Absatz: the jump holds on and is placed again.
            if c.target != nil { c.hold(); c.applyTarget() }
            c.refreshLinks()
        }
        // Marks are drawn by the layout manager: no new text, no scroll jump.
        let fixed = Set(marks.compactMap { mark in selection.controller?.laws?.liveItem(mark.id).flatMap { $0.payload["kind"]?.string == "text" ? nil : mark.id } })
        var hasher = Hasher(); hasher.combine(marks); hasher.combine(fixed)
        let marksKey = hasher.finalize()
        if c.marksKey != marksKey {
            c.marksKey = marksKey
            let ranges = LawTextAnchor.originalRanges(text: c.renderedText, anchors: marks.map(\.anchor))
            c.markRanges = zip(marks, ranges).compactMap { mark, range in range.map { .init(id: mark.id, range: $0, color: mark.color, fixed: fixed.contains(mark.id)) } }
            c.applyHighlights()
        }
        let outlineKey = "\(selection.tapped):\(selection.marks):\(selection.controller?.adjusting ?? "")"
        if c.outlineKey != outlineKey { c.outlineKey = outlineKey; c.applyHighlights() }
        let jumpKey = "\(sectionID):\(jump?.id ?? -1)"
        if c.jump != jumpKey {
            c.jump = jumpKey
            if let paragraph = jump?.paragraph {
                c.setTarget(.paragraph(paragraph))
                c.startFlash(paragraph)
            } else if let offset = jump?.offset {
                c.setTarget(.offset(offset))
            } else {
                c.dropTarget()
            }
        }
    }
    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate, UIGestureRecognizerDelegate {
        struct MarkRange { var id: String; var range: NSRange; var color: String?; var fixed: Bool }
        var parent: NativeLawText
        weak var container: LawTextContainer?
        var view: UITextView? { container?.textView }
        var bodyKey = "", sectionID = "", jump = "", richKey = "", outlineKey = ""
        var fontSize = 0.0
        var marksKey: Int?
        /// HTML rendering of the current section at a reference size, or nil when
        /// the plain text is used. Imported once per section, not per size step.
        var rich: NSAttributedString?
        private var richBase: CGFloat = 17
        var updating = false
        var renderedText = ""
        var bodyLength = 0
        var markRanges: [MarkRange] = []
        weak var stroke: LawPencilStroke?
        weak var tap: UITapGestureRecognizer?
        weak var linkTap: UITapGestureRecognizer?
        var penActive: Bool?
        /// Where the text has to stay after a jump (`hold`): UIKit may move the
        /// offset once more after new text, a selection reset or a resize (it
        /// used to fall back to the top after the jump to an Absatz). Until
        /// the hold ends or the user scrolls, every such move is undone.
        enum Target: Equatable { case paragraph(String), offset(CGFloat) }
        private(set) var target: Target?
        private var holdUntil = Date.distantPast
        private var placing = false
        /// The Absatz highlighted after a jump, fading out (`startFlash`).
        private var flashParagraph: String?
        private var flashRange: NSRange?
        private var flashAlpha: CGFloat = 0
        private var flashTimer: Timer?
        /// Cross-references of the shown section (`refreshLinks`), scanned off the main thread.
        private(set) var links: [LawCitation] = []
        private var linkKey = ""
        /// The tap began while text or a mark was selected: it only ends that.
        private var tapHadSelection = false
        private var scannerWatch: AnyCancellable?
        // Hover cards (same rules as on a page, WorksheetView+LawCitations).
        private enum HoverKind { case pencil, pointer }
        private var hoverKind: HoverKind?
        private var hoverPoint: CGPoint?
        private weak var hoverSource: UIHoverGestureRecognizer?
        private var dwell: DispatchWorkItem?
        private var dwellLink: NSRange?
        private var dwellAnchor = CGPoint.zero
        /// The link whose card this view's hover asked for.
        private var shownLink: NSRange?
        private var pencilDown = false
        private var lastPencilLift: CFTimeInterval = 0
        private var feedback: UIFeedbackGenerator?
        private static let pencilDwell: TimeInterval = 0.5
        private static let pointerDwell: TimeInterval = 0.4
        private static let writingPause: CFTimeInterval = 1.0
        private static let restTolerance: CGFloat = 6
        private var strokeStart: Int?
        private var strokePreview: NSRange?
        /// The line a Pencil stroke is bound to (text view coordinates).
        private var boundLine: (mid: CGFloat, height: CGFloat)?
        init(_ parent: NativeLawText) {
            self.parent = parent
            super.init()
            scannerWatch = LawCitationPreviewModel.shared.$readerScannerGeneration.dropFirst()
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in MainActor.assumeIsolated { self?.linkKey = ""; self?.refreshLinks() } }
        }

        // MARK: Jump target and Absatz highlight

        func setTarget(_ next: Target) {
            target = next
            hold()
            applyTarget()
        }
        /// Keeps the target for a moment after the latest change of the text.
        func hold() { holdUntil = Date().addingTimeInterval(1.5) }
        func dropTarget() { target = nil }
        /// Puts the target at the top of the view (an Absatz a little below the
        /// edge). Called after every change of text, size or offset while held.
        func applyTarget() {
            guard let target, !placing, let v = view, let container else { return }
            guard Date() < holdUntil else { self.target = nil; return }
            // Not laid out yet (the window opening): the next layout pass places it.
            guard v.bounds.height > 1, v.bounds.width > 1 else { return }
            let layout = container.layout, inset = v.textContainerInset
            layout.ensureLayout(for: v.textContainer)
            var y: CGFloat
            switch target {
            case .paragraph(let paragraph):
                guard let range = LawAbsatz.range(paragraph, in: renderedText), range.location < bodyLength else { self.target = nil; return }
                let glyphs = layout.glyphRange(forCharacterRange: NSRange(location: range.location, length: 1), actualCharacterRange: nil)
                let rect = layout.boundingRect(forGlyphRange: glyphs, in: v.textContainer)
                guard rect.minY.isFinite else { return }
                y = rect.minY + inset.top - 10
            case .offset(let offset):
                y = offset
            }
            let used = layout.usedRect(for: v.textContainer)
            let height = max(v.contentSize.height, used.maxY + inset.top + inset.bottom)
            let top = -v.adjustedContentInset.top
            let limit = max(top, height + v.adjustedContentInset.bottom - v.bounds.height)
            y = min(max(top, y), limit)
            guard abs(v.contentOffset.y - y) > 0.5 else { return }
            placing = true
            v.setContentOffset(CGPoint(x: v.contentOffset.x, y: y), animated: false)
            placing = false
        }
        /// A soft accent behind the Absatz, fading out after about 2 s (with
        /// Reduce Motion it disappears without fading).
        func startFlash(_ paragraph: String) {
            flashTimer?.invalidate(); flashTimer = nil
            flashParagraph = paragraph
            refreshFlashRange()
            guard flashRange != nil else { flashParagraph = nil; return }
            flashAlpha = 1
            applyHighlights()
            let start = Date()
            if UIAccessibility.isReduceMotionEnabled {
                let timer = Timer(timeInterval: 2, repeats: false) { [weak self] _ in
                    MainActor.assumeIsolated { self?.endFlash(redraw: true) }
                }
                // `.common`: it also runs while the text is being scrolled.
                RunLoop.main.add(timer, forMode: .common)
                flashTimer = timer
                return
            }
            let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
                // The view went away: the timer ends itself.
                let gone = MainActor.assumeIsolated { () -> Bool in
                    guard let self else { return true }
                    let elapsed = Date().timeIntervalSince(start)
                    guard elapsed > 1.3 else { return false }
                    // Ease-out over 0.6 s; only the Absatz is redrawn per frame.
                    let t = min(1, CGFloat(elapsed - 1.3) / 0.6)
                    let alpha = (1 - t) * (1 - t)
                    if alpha <= 0 { self.endFlash(redraw: true) } else { self.flashAlpha = alpha; self.applyFlashOnly() }
                    return false
                }
                if gone { timer.invalidate() }
            }
            RunLoop.main.add(timer, forMode: .common)
            flashTimer = timer
        }
        func endFlash(redraw: Bool) {
            flashTimer?.invalidate(); flashTimer = nil
            let had = flashRange != nil
            flashParagraph = nil; flashRange = nil; flashAlpha = 0
            if had, redraw { applyHighlights() }
        }
        /// The highlighted Absatz in the text shown now (plain or rich).
        func refreshFlashRange() {
            guard let flashParagraph else { flashRange = nil; return }
            flashRange = LawAbsatz.range(flashParagraph, in: renderedText).flatMap { NSMaxRange($0) <= bodyLength ? $0 : nil }
        }

        // MARK: Cross-references

        /// Scans the shown section once per text (cached), away from the main thread.
        func refreshLinks() {
            let law = parent.lawID, text = renderedText
            let preview = LawCitationPreviewModel.shared
            guard let scanner = preview.readerScanner, !law.isEmpty, !text.isEmpty else {
                linkKey = ""
                if !links.isEmpty { links = []; applyHighlights() }
                return
            }
            let key = "\(law)|\(parent.versionID)|\(preview.readerScannerGeneration)|\((text as NSString).length)|\(text.hashValue)"
            guard key != linkKey else { return }
            linkKey = key
            if let hit = Self.linkCache[key] { links = hit; applyHighlights(); return }
            if !links.isEmpty { links = []; applyHighlights() }
            Task { [weak self] in
                let has = self?.parent.hasSection
                let found = await Task.detached(priority: .utility) {
                    scanner.citations(in: text, defaultLawID: law, lawText: true)
                        .filter { $0.lawID != law || has?($0.reference.key) ?? true }
                }.value
                guard let self, self.linkKey == key else { return }
                Self.linkCache[key] = found; Self.linkOrder.append(key)
                if Self.linkOrder.count > 32 { Self.linkCache[Self.linkOrder.removeFirst()] = nil }
                self.links = found
                self.applyHighlights()
            }
        }
        @MainActor private static var linkCache: [String: [LawCitation]] = [:]
        @MainActor private static var linkOrder: [String] = []
        private var linksActive: Bool { parent.pen.kind == .none && parent.onCitation != nil }
        /// A plain tap on a cross-reference opens it in the reader. Not while
        /// marking, not on a mark, not when the tap only ends a selection.
        @objc func linkTapped(_ gesture: UITapGestureRecognizer) {
            // A tap that stopped a scroll, ended a selection or follows a
            // long-press selection only does that.
            guard gesture.state == .ended, linksActive, !tapHadSelection, let v = view, v.selectedRange.length == 0,
                  let citation = link(at: gesture.location(in: v)) else { return }
            endHoverCard()
            LawCitationPreviewModel.shared.dismissReaderCard()
            UISelectionFeedbackGenerator().selectionChanged()
            parent.onCitation?(citation)
        }
        /// The cross-reference under `point` (text view coordinates), not on a mark.
        private func link(at point: CGPoint) -> LawCitation? {
            guard let index = character(at: point), !markRanges.contains(where: { NSLocationInRange(index, $0.range) }) else { return nil }
            return links.first { NSLocationInRange(index, $0.range) && NSMaxRange($0.range) <= bodyLength }
        }
        /// Lines of a link in text view coordinates.
        private func linkRect(_ range: NSRange) -> CGRect? {
            guard let v = view, let container, NSMaxRange(range) <= container.storage.length else { return nil }
            let glyphs = container.layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let union = container.layout.lineRects(glyphs, text: container.storage.string as NSString, storage: container.storage, container: v.textContainer)
                .reduce(CGRect.null) { $0.union($1) }
            guard !union.isNull else { return nil }
            return union.offsetBy(dx: v.textContainerInset.left, dy: v.textContainerInset.top)
        }

        // MARK: Hover card over cross-references

        /// Pointer hover reports no height and no tilt; a hovering Pencil does.
        private func classify(_ recognizer: UIHoverGestureRecognizer) -> HoverKind {
            let pencil = recognizer.zOffset > 0.0001 || recognizer.altitudeAngle < .pi / 2 - 0.02
            if recognizer.state == .began || hoverKind == nil { hoverKind = pencil ? .pencil : .pointer }
            else if pencil { hoverKind = .pencil }
            return hoverKind ?? .pointer
        }
        /// Markieren/Radieren: no links and no cards; never with the Pencil down.
        private func allowsHover(_ kind: HoverKind) -> Bool {
            // Only in the law window: a reader elsewhere (Settings) has no card layer.
            guard parent.hoverCards, linksActive, !links.isEmpty, view?.window != nil else { return false }
            if kind == .pencil, pencilDown { return false }
            return true
        }
        @objc func hovered(_ recognizer: UIHoverGestureRecognizer) {
            guard let v = view else { return }
            switch recognizer.state {
            case .began, .changed:
                // Hovering: the Pencil is not on the glass (a lost touch end never sticks).
                if recognizer.state == .began { pencilDown = false }
                hoverSource = recognizer
                let previous = hoverKind
                let kind = classify(recognizer)
                if previous != nil, previous != kind { cancelDwell() }
                let point = recognizer.location(in: v), window = recognizer.location(in: nil)
                hoverPoint = point
                if kind == .pencil, recognizer.state == .began, !links.isEmpty, #available(iOS 17.5, *) {
                    if feedback == nil { feedback = UICanvasFeedbackGenerator(view: v) }
                    feedback?.prepare()
                }
                // Leaving needs a few points more than entering.
                if let shownLink {
                    if let rect = linkRect(shownLink), rect.insetBy(dx: -8, dy: -8).contains(point) { return }
                    self.shownLink = nil
                    LawCitationPreviewModel.shared.endHover()
                }
                guard allowsHover(kind), let hit = link(at: point) else { cancelDwell(); return }
                let moved = hypot(window.x - dwellAnchor.x, window.y - dwellAnchor.y)
                if hit.range != dwellLink || dwell == nil || (kind == .pencil && moved > Self.restTolerance) {
                    dwellLink = hit.range; dwellAnchor = window
                    startDwell(kind, after: kind == .pencil ? Self.pencilDwell : Self.pointerDwell)
                }
            default:
                cancelDwell(); hoverKind = nil; hoverPoint = nil; hoverSource = nil
                // Like on a page: a grace period to reach the card.
                if shownLink != nil { shownLink = nil; LawCitationPreviewModel.shared.endHover() }
            }
        }
        private func startDwell(_ kind: HoverKind, after delay: TimeInterval) {
            dwell?.cancel()
            let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.dwellEnded(kind) } }
            dwell = work
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
        private func cancelDwell() { dwell?.cancel(); dwell = nil; dwellLink = nil }
        private func dwellEnded(_ kind: HoverKind) {
            dwell = nil
            guard let v = view, let range = dwellLink, let point = hoverPoint, hoverKind == kind, let source = hoverSource,
                  source.state == .began || source.state == .changed, allowsHover(kind),
                  let hit = link(at: point), hit.range == range, let rect = linkRect(range) else { dwellLink = nil; return }
            if kind == .pencil {
                // Writing or marking just happened: the Pencil hovers between strokes.
                let since = CACurrentMediaTime() - lastPencilLift
                if since < Self.writingPause { startDwell(kind, after: Self.writingPause - since); return }
            }
            shownLink = range
            let follow: (LawCitation) -> Void = { [weak self] citation in self?.parent.onCitation?(citation) }
            LawCitationPreviewModel.shared.hoverInReader(hit, anchor: v.convert(rect, to: nil), input: kind == .pencil ? .pencilHover : .pointerHover,
                                                         lawID: parent.lawID, versionID: parent.versionID, follow: follow)
            if kind == .pencil, #available(iOS 17.5, *), let generator = feedback as? UICanvasFeedbackGenerator {
                generator.alignmentOccurred(at: point)
            }
        }
        /// This view's hover card ends (section change, link followed).
        func endHoverCard() {
            cancelDwell()
            guard shownLink != nil else { return }
            shownLink = nil
            LawCitationPreviewModel.shared.dismissReaderCard()
        }
        /// Finger or Pencil on the text: a card of the reader goes at once.
        func touchBegan(_ touch: UITouch) {
            if touch.type == .pencil { pencilDown = true }
            guard touch.type == .pencil || touch.type == .direct else { return }
            cancelDwell(); shownLink = nil
            LawCitationPreviewModel.shared.dismissReaderCard()
        }
        func touchEnded(_ touch: UITouch) {
            guard touch.type == .pencil else { return }
            pencilDown = false
            lastPencilLift = CACurrentMediaTime()
        }
        /// The watch's sequence ended (also cancelled by the system): no touch is down.
        func touchesReset() {
            if pencilDown { pencilDown = false; lastPencilLift = CACurrentMediaTime() }
        }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            if gestureRecognizer === linkTap {
                let scrolling = view.map { $0.isDecelerating || $0.isDragging } ?? false
                tapHadSelection = (view?.selectedRange.length ?? 0) > 0 || parent.selection.active || scrolling
            }
            return true
        }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRequireFailureOf other: UIGestureRecognizer) -> Bool {
            guard gestureRecognizer === linkTap, let tap = other as? UITapGestureRecognizer, tap !== self.tap else { return false }
            return tap.numberOfTapsRequired > 1
        }

        /// Rich native HTML supports tables/lists. Only use it if its exact
        /// canonical text matches the shared anchor contract; otherwise plain
        /// source text is authoritative. Never fetch remote HTML resources.
        @MainActor static var importing = false
        /// Recently imported sections (paging back and forth imports once).
        @MainActor private static var cache: [String: (rich: NSAttributedString, base: CGFloat)] = [:]
        @MainActor private static var cacheOrder: [String] = []
        @MainActor func importRich(html: String?, text: String, key: String) {
            rich = nil
            if let hit = Self.cache[key] { richBase = hit.base; rich = hit.rich; return }
            guard let html, !html.isEmpty, html.utf8.count <= 250_000,
                  html.range(of: "<(?:script|iframe|img|link|object|style)|(?:src|href)\\s*=|url\\s*\\(|@import", options: [.regularExpression, .caseInsensitive]) == nil else { return }
            Self.importing = true; defer { Self.importing = false }
            let markup = "<html><head><meta charset='utf-8'><style>\(LawReadingStyle.css)</style></head><body>" + html + "</body></html>"
            guard let data = markup.data(using: .utf8),
                  let imported = try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.html, .characterEncoding: String.Encoding.utf8.rawValue], documentAttributes: nil),
                  // UTF-16 like the anchor contract, not Swift's canonical equivalence.
                  LawTextAnchor.canonical(imported.string).utf16.elementsEqual(LawTextAnchor.canonical(text).utf16) else { return }
            // Body size as the importer actually produced it (its px/pt mapping).
            var lengths: [CGFloat: Int] = [:]
            imported.enumerateAttribute(.font, in: NSRange(location: 0, length: imported.length)) { value, range, _ in
                if let font = value as? UIFont { lengths[font.pointSize, default: 0] += range.length }
            }
            richBase = lengths.max { $0.value < $1.value }?.key ?? 17
            rich = imported
            Self.cache[key] = (imported, richBase); Self.cacheOrder.append(key)
            if Self.cacheOrder.count > 12 { Self.cache[Self.cacheOrder.removeFirst()] = nil }
        }
        /// The imported text with every font scaled so the body text is `size` pt.
        func scaled(_ source: NSAttributedString, to size: Double) -> NSMutableAttributedString {
            let result = NSMutableAttributedString(attributedString: source)
            let factor = CGFloat(size) / max(1, richBase)
            result.enumerateAttribute(.font, in: NSRange(location: 0, length: result.length)) { value, range, _ in
                guard let font = value as? UIFont else { return }
                result.addAttribute(.font, value: font.withSize(font.pointSize * factor), range: range)
            }
            return result
        }
        /// Hands marks, the selected mark's outline and the Pencil preview to
        /// the layout manager and redraws (no attribute changes).
        func applyHighlights() {
            guard let container else { return }
            container.layout.fills = highlightFills()
            container.layout.links = linksActive ? links.map(\.range).filter { NSMaxRange($0) <= bodyLength } : []
            container.layout.invalidateDisplay(forCharacterRange: NSRange(location: 0, length: container.storage.length))
        }
        /// Fade step of the jump highlight: same fills, but only the Absatz is redrawn.
        private func applyFlashOnly() {
            guard let container, let flashRange, NSMaxRange(flashRange) <= container.storage.length else { applyHighlights(); return }
            container.layout.fills = highlightFills()
            container.layout.invalidateDisplay(forCharacterRange: flashRange)
        }
        private func highlightFills() -> [LawMarkLayoutManager.Fill] {
            let selection = parent.selection
            var outlined = Set(selection.tapped ? selection.marks : [])
            if let adjusting = selection.controller?.adjusting { outlined.insert(adjusting) }
            var fills = markRanges.filter { NSMaxRange($0.range) <= bodyLength }.map {
                LawMarkLayoutManager.Fill(range: $0.range, color: lawMarkFill($0.color), outline: outlined.contains($0.id) ? UIColor(white: 0.95, alpha: 1) : nil)
            }
            if let preview = strokePreview, NSMaxRange(preview) <= bodyLength {
                let color = parent.pen.kind == .eraser ? UIColor.systemGray.withAlphaComponent(0.45) : lawMarkColor(parent.pen.hex).withAlphaComponent(0.6)
                fills.append(.init(range: preview, color: color, outline: nil))
            }
            // Behind everything: the Absatz a jump went to.
            if let flashRange, flashAlpha > 0, NSMaxRange(flashRange) <= bodyLength {
                fills.insert(.init(range: flashRange, color: UIColor(Color.notyAccent).withAlphaComponent(0.2 * flashAlpha), outline: nil, block: true), at: 0)
            }
            return fills
        }
        private func marks(in range: NSRange) -> [String] {
            markRanges.filter { NSIntersectionRange($0.range, range).length > 0 }.map(\.id)
        }
        /// Caret offset nearest to `point`, limited to the section text (not notes).
        private func caret(at point: CGPoint) -> Int {
            guard let v = view, let position = v.closestPosition(to: point) else { return 0 }
            return min(max(0, v.offset(from: v.beginningOfDocument, to: position)), bodyLength)
        }
        /// The character under `point` (text view coordinates), only if the
        /// point lies on its glyph's line box.
        private func character(at point: CGPoint) -> Int? {
            guard let v = view, let container = self.container, bodyLength > 0 else { return nil }
            let inset = v.textContainerInset
            let p = CGPoint(x: point.x - inset.left, y: point.y - inset.top)
            var fraction: CGFloat = 0
            let index = container.layout.characterIndex(for: p, in: v.textContainer, fractionOfDistanceBetweenInsertionPoints: &fraction)
            guard index < bodyLength else { return nil }
            let glyphs = container.layout.glyphRange(forCharacterRange: NSRange(location: index, length: 1), actualCharacterRange: nil)
            let box = container.layout.boundingRect(forGlyphRange: glyphs, in: v.textContainer).insetBy(dx: -3, dy: -2)
            return box.contains(p) ? index : nil
        }
        /// Middle and height of the line under `point` (text view coordinates).
        private func line(at point: CGPoint) -> (mid: CGFloat, height: CGFloat)? {
            guard let v = view, let container = self.container, container.storage.length > 0 else { return nil }
            let inset = v.textContainerInset
            let glyph = container.layout.glyphIndex(for: CGPoint(x: point.x - inset.left, y: point.y - inset.top), in: v.textContainer)
            let rect = container.layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            guard rect.height > 0 else { return nil }
            return (rect.midY + inset.top, rect.height)
        }
        /// Where the bar belongs: the text selection or the tapped mark.
        func barAnchor() -> CGRect? {
            guard let v = view, let container else { return nil }
            let selection = parent.selection
            let range: NSRange?
            if selection.range.length > 0 { range = selection.range }
            else if selection.tapped, let id = selection.marks.first { range = markRanges.first { $0.id == id }?.range }
            else { range = nil }
            guard let range, NSMaxRange(range) <= container.storage.length else { return nil }
            let glyphs = container.layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            var union = CGRect.null
            container.layout.enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: v.textContainer) { rect, _ in
                union = union.union(rect)
            }
            guard !union.isNull else { return nil }
            let inText = union.offsetBy(dx: v.textContainerInset.left, dy: v.textContainerInset.top)
            return container.overlay.convert(inText, from: v)
        }
        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            container?.overlay.reposition(animated: false)
            // UIKit moved the text after a jump (new text, selection reset):
            // put it back once that pass is over. The user's own scrolling ends the hold.
            if target != nil, !placing, !scrollView.isTracking, !scrollView.isDragging, !scrollView.isDecelerating {
                DispatchQueue.main.async { [weak self] in self?.applyTarget() }
            }
        }
        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            dropTarget()
            endHoverCard(); LawCitationPreviewModel.shared.dismissReaderCard()
        }
        func textViewDidChangeSelection(_ textView: UITextView) {
            guard !updating else { return }
            if textView.selectedRange.length > 0 { dropTarget() }
            let range = NSIntersectionRange(textView.selectedRange, NSRange(location: 0, length: bodyLength)), id = parent.sectionID
            let hit = range.length > 0 ? marks(in: range) : nil
            // Published state must not change during the SwiftUI update pass.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.parent.sectionID == id else { return }
                let selection = self.parent.selection
                let next = range.length > 0 ? range : NSRange(location: 0, length: 0)
                if selection.range != next { selection.range = next }
                if let hit {
                    if selection.marks != hit { selection.marks = hit }
                    if selection.tapped { selection.tapped = false }
                } else if !selection.tapped, !selection.marks.isEmpty {
                    selection.marks = []
                }
                self.container?.overlay.setNeedsReposition()
            }
        }
        func textView(_ textView: UITextView, editMenuForTextIn range: NSRange, suggestedActions: [UIMenuElement]) -> UIMenu? {
            let clipped = NSIntersectionRange(range, NSRange(location: 0, length: bodyLength))
            guard clipped.length > 0, let controller = parent.selection.controller else { return nil }
            let colors = LawMarkColor.palette.map { color in
                UIAction(title: color.name, image: lawMarkSwatchImage(color.hex)) { [weak controller] _ in controller?.markText(clipped, color: color.hex) }
            }
            var actions: [UIMenuElement] = [UIMenu(title: "Markieren", image: UIImage(systemName: "highlighter"), children: colors)]
            if !marks(in: clipped).isEmpty {
                actions.append(UIAction(title: "Aus Markierung entfernen", image: UIImage(systemName: "trash"), attributes: .destructive) { [weak controller] _ in
                    controller?.removeText(clipped)
                    controller?.clearSelection()
                })
            }
            return UIMenu(children: actions + suggestedActions)
        }
        /// A tap on a highlight selects it (outline and bar); elsewhere it ends that.
        @objc func tapped(_ gesture: UITapGestureRecognizer) {
            guard let v = view, gesture.state == .ended else { return }
            let point = gesture.location(in: v)
            let hit = character(at: point).flatMap { index in markRanges.last { NSLocationInRange(index, $0.range) }?.id }
            let selection = parent.selection, id = parent.sectionID
            // After the text view has handled the same tap (it may clear a selection).
            DispatchQueue.main.async { [weak self] in
                guard let self, self.parent.sectionID == id, (self.view?.selectedRange.length ?? 0) == 0 else { return }
                selection.controller?.endAdjusting()
                selection.select(mark: hit)
            }
        }
        /// Highlighter: whole words from the start to the Pencil, bound to the
        /// start line until Pencil clearly leaves it; a tap marks one word.
        /// Eraser: the covered words are removed from the marks (splitting them).
        @objc func pencil(_ gesture: LawPencilStroke) {
            guard let v = view else { return }
            switch gesture.state {
            case .began:
                dropTarget()
                let start = gesture.startLocation ?? gesture.location(in: v)
                strokeStart = caret(at: start)
                boundLine = line(at: start)
                showStroke(stroke(to: gesture.location(in: v)))
            case .changed:
                showStroke(stroke(to: gesture.location(in: v)))
            case .ended:
                let range = gesture.isTap ? word(at: gesture.startLocation ?? gesture.location(in: v)) : stroke(to: gesture.location(in: v))
                endStroke()
                guard let range, let controller = parent.selection.controller else { return }
                if parent.pen.kind == .eraser {
                    if !marks(in: range).isEmpty { controller.removeText(range) }
                } else {
                    controller.markText(range, color: nil)
                }
            default:
                endStroke()
            }
        }
        private func endStroke() {
            strokeStart = nil; boundLine = nil
            if strokePreview != nil { strokePreview = nil; applyHighlights() }
        }
        /// Restyles only when the covered characters change, not per Pencil sample.
        private func showStroke(_ range: NSRange?) {
            guard range != strokePreview else { return }
            strokePreview = range
            applyHighlights()
        }
        private func stroke(to point: CGPoint) -> NSRange? {
            guard let start = strokeStart else { return nil }
            var y = point.y
            if let bound = boundLine {
                if LawPencilLine.leaves(boundMidY: Double(bound.mid), lineHeight: Double(bound.height), y: Double(point.y)), let next = line(at: point) {
                    boundLine = next
                }
                y = boundLine?.mid ?? point.y
            }
            let end = caret(at: CGPoint(x: point.x, y: y))
            guard end != start else { return nil }
            return words(NSRange(location: min(start, end), length: abs(end - start)))
        }
        private func word(at point: CGPoint) -> NSRange? {
            guard let index = character(at: point), let range = LawMarkEditing.word(in: renderedText, at: index) else { return nil }
            return NSMaxRange(range) <= bodyLength ? range : nil
        }
        /// Widens a stroke range to whole words (system tokenizer).
        private func words(_ range: NSRange) -> NSRange? {
            guard let result = LawMarkEditing.wordRange(in: renderedText, covering: range), NSMaxRange(result) <= bodyLength else { return nil }
            return result
        }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    }
}

/// Watches the touches of the law text without ever recognising: it never
/// delays, cancels or blocks another gesture.
final class LawTouchWatch: UIGestureRecognizer {
    var onBegan: ((UITouch) -> Void)?
    var onEnded: ((UITouch) -> Void)?
    var onReset: (() -> Void)?
    private var active = 0
    init() {
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false; delaysTouchesBegan = false; delaysTouchesEnded = false
    }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        active += touches.count
        touches.forEach { onBegan?($0) }
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) { finish(touches) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { finish(touches) }
    private func finish(_ touches: Set<UITouch>) {
        touches.forEach { onEnded?($0) }
        active = max(0, active - touches.count)
        if active == 0 { state = .failed }
    }
    override func reset() { super.reset(); active = 0; onReset?() }
}

/// A scroll target of `NativeLawText`.
struct LawTextJump: Equatable {
    /// Counts requests: the same Absatz again is a new jump.
    var id: Int
    var paragraph: String?
    /// A content offset to restore (the way back), when no Absatz is named.
    var offset: CGFloat?
}

/// Absätze in the plain section text, shared by the reader (jump, highlight)
/// and the citation card (excerpt, quote).
enum LawAbsatz {
    private static let anyStart = try? NSRegularExpression(pattern: "(?m)^[ \\t\\u00A0]*\\(\\d+[a-z]?\\)")
    /// Compiled once per marker: `range` runs on every layout and scroll
    /// callback during a jump.
    private static let markerPatterns = OSAllocatedUnfairLock<[String: NSRegularExpression]>(initialState: [:])
    private static func markerPattern(_ marker: String) -> NSRegularExpression? {
        if let cached = markerPatterns.withLock({ $0[marker] }) { return cached }
        guard let re = try? NSRegularExpression(pattern: "(?m)^[ \\t\\u00A0]*(" + NSRegularExpression.escapedPattern(for: marker) + ")") else { return nil }
        markerPatterns.withLock { patterns in
            if patterns.count >= 64 { patterns.removeAll() }
            patterns[marker] = re
        }
        return re
    }
    /// From „(6)“ at the start of a line (else the first „(6)“ anywhere) up to
    /// the next Absatz at the start of a line, else to the end; trailing
    /// white space trimmed. Nil when the text has no such marker.
    static func range(_ paragraph: String, in text: String) -> NSRange? {
        let source = text as NSString
        let all = NSRange(location: 0, length: source.length)
        let marker = "(\(paragraph))"
        var start: Int?
        if let re = markerPattern(marker), let match = re.firstMatch(in: text, range: all) {
            start = match.range(at: 1).location
        } else {
            let found = source.range(of: marker)
            if found.location != NSNotFound { start = found.location }
        }
        guard let start else { return nil }
        let from = start + (marker as NSString).length
        var end = source.length
        if from < source.length, let next = anyStart?.firstMatch(in: text, range: NSRange(location: from, length: source.length - from)) {
            end = next.range.location
        }
        while end > start, let scalar = UnicodeScalar(source.character(at: end - 1)), CharacterSet.whitespacesAndNewlines.contains(scalar) { end -= 1 }
        return end > start ? NSRange(location: start, length: end - start) : nil
    }
}

/// The law text view with its own TextKit 1 stack (marks drawn by
/// `LawMarkLayoutManager`) and the mark overlay above it.
final class LawTextContainer: UIView {
    let storage = NSTextStorage()
    let layout = LawMarkLayoutManager()
    let textView: UITextView
    let overlay = LawMarkOverlay()
    /// After every layout pass (window opening, rotation): a jump target is placed again.
    var onLayout: (() -> Void)?
    init() {
        storage.addLayoutManager(layout)
        let textContainer = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        textContainer.widthTracksTextView = true
        layout.addTextContainer(textContainer)
        // TextKit 1 (explicit stack): marks are drawn in place by the layout
        // manager. TextKit 2 did not reliably redraw changed highlights.
        textView = LawKeyTextView(frame: .zero, textContainer: textContainer)
        super.init(frame: .zero)
        addSubview(textView)
        addSubview(overlay)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layoutSubviews() {
        super.layoutSubviews()
        textView.frame = bounds
        overlay.frame = bounds
        onLayout?()
    }
}

/// `LawKeyTextView` (the law text view's class) lives in LawKeyCommands.swift.

/// Draws marks as rounded areas in glyph height behind the text: one shape
/// per line, trimmed of spaces at the line ends, with an outline for the
/// selected mark. Overlapping marks never change each other's text attributes.
final class LawMarkLayoutManager: NSLayoutManager {
    struct Fill {
        var range: NSRange
        var color: UIColor
        var outline: UIColor?
        /// One block over all lines (the highlighted Absatz), not per line.
        var block = false
    }
    var fills: [Fill] = []
    /// Cross-references: a quiet dotted line under the text.
    var links: [NSRange] = []

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: CGPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        guard !fills.isEmpty || !links.isEmpty, let storage = textStorage, let container = textContainers.first else { return }
        let text = storage.string as NSString
        for fill in fills where fill.range.length > 0 && NSMaxRange(fill.range) <= storage.length {
            let glyphs = glyphRange(forCharacterRange: fill.range, actualCharacterRange: nil)
            guard NSIntersectionRange(glyphs, glyphsToShow).length > 0 else { continue }
            let rects = lineRects(glyphs, text: text, storage: storage, container: container).map { $0.offsetBy(dx: origin.x, dy: origin.y) }
            if fill.block {
                let union = rects.reduce(CGRect.null) { $0.union($1) }
                guard !union.isNull else { continue }
                let block = CGRect(x: origin.x + 1, y: union.minY - 4, width: max(0, container.size.width - 2), height: union.height + 8)
                fill.color.setFill()
                UIBezierPath(roundedRect: block, cornerRadius: 8).fill()
                continue
            }
            fill.color.setFill()
            for rect in rects { UIBezierPath(roundedRect: rect, cornerRadius: min(4, rect.height / 4)).fill() }
            if let outline = fill.outline {
                outline.setStroke()
                for rect in rects {
                    let path = UIBezierPath(roundedRect: rect.insetBy(dx: -1, dy: -1), cornerRadius: min(5, rect.height / 4 + 1))
                    path.lineWidth = 1.5; path.stroke()
                }
            }
        }
        guard !links.isEmpty else { return }
        UIColor(Color.notyAccent).withAlphaComponent(0.75).setStroke()
        for link in links where link.length > 0 && NSMaxRange(link) <= storage.length {
            let glyphs = glyphRange(forCharacterRange: link, actualCharacterRange: nil)
            guard NSIntersectionRange(glyphs, glyphsToShow).length > 0 else { continue }
            for rect in lineRects(glyphs, text: text, storage: storage, container: container) {
                let y = rect.maxY - 1.5 + origin.y
                let path = UIBezierPath()
                path.move(to: CGPoint(x: rect.minX + 1.5 + origin.x, y: y))
                path.addLine(to: CGPoint(x: rect.maxX - 1.5 + origin.x, y: y))
                path.lineWidth = 1.2
                path.lineCapStyle = .round
                path.setLineDash([0.1, 3], count: 2, phase: 0)
                path.stroke()
            }
        }
    }
    /// One rectangle per line fragment: from the first to the last visible
    /// character, from ascender to descender of the largest font there.
    func lineRects(_ glyphs: NSRange, text: NSString, storage: NSTextStorage, container: NSTextContainer) -> [CGRect] {
        func blank(_ index: Int) -> Bool {
            guard let scalar = UnicodeScalar(text.character(at: index)) else { return false }
            return CharacterSet.whitespacesAndNewlines.contains(scalar)
        }
        var result: [CGRect] = []
        enumerateLineFragments(forGlyphRange: glyphs) { lineRect, _, _, lineGlyphs, _ in
            let part = NSIntersectionRange(lineGlyphs, glyphs)
            guard part.length > 0 else { return }
            var chars = self.characterRange(forGlyphRange: part, actualGlyphRange: nil)
            while chars.length > 0, blank(chars.location) { chars.location += 1; chars.length -= 1 }
            while chars.length > 0, blank(NSMaxRange(chars) - 1) { chars.length -= 1 }
            guard chars.length > 0 else { return }
            let visible = self.glyphRange(forCharacterRange: chars, actualCharacterRange: nil)
            let bounds = self.boundingRect(forGlyphRange: visible, in: container)
            var ascent: CGFloat = 0, descent: CGFloat = 0
            storage.enumerateAttribute(.font, in: chars) { value, _, _ in
                let font = value as? UIFont ?? .systemFont(ofSize: 17)
                ascent = max(ascent, font.ascender); descent = max(descent, -font.descender)
            }
            let baseline = lineRect.minY + self.location(forGlyphAt: visible.location).y
            result.append(CGRect(x: bounds.minX - 1.5, y: baseline - ascent - 1, width: bounds.width + 3, height: ascent + descent + 2))
        }
        return result
    }
}
