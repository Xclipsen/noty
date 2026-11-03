import SwiftUI
import UIKit
import Combine
import NotebookCore

struct NativeLawText: UIViewRepresentable {
    var text: String
    var html: String?
    var notes: String
    var sectionID: String
    var fontSize: Double
    var marks: [LawTextMark]
    var paragraph: String?
    var selection: LawTextSelection
    var pen: LawPenMode
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
        context.coordinator.container = container
        container.overlay.anchor = { [weak coordinator = context.coordinator] in coordinator?.barAnchor() }
        return container
    }
    func updateUIView(_ container: LawTextContainer, context: Context) {
        let v = container.textView
        let c = context.coordinator
        c.parent = self
        selection.view = v
        container.overlay.attach(controller: selection.controller, selection: selection)
        // Highlighter/eraser: Pencil marks; fingers keep scrolling and selecting.
        // Other notebook tools: Pencil scrolls and selects like a finger.
        let penActive = pen.kind != .none
        if c.penActive != penActive {
            c.penActive = penActive
            c.stroke?.isEnabled = penActive
            v.panGestureRecognizer.allowedTouchTypes = penActive ? lawTouchTypesWithoutPencil : lawAllTouchTypes
            c.tap?.allowedTouchTypes = penActive ? lawTouchTypesWithoutPencil : lawAllTouchTypes
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
            if c.richKey != richKey { c.richKey = richKey; c.importRich(html: html, text: text) }
            let body = c.rich.map { c.scaled($0, to: fontSize) } ?? NSMutableAttributedString(string: text, attributes: attributes)
            // One reading colour and spacing for HTML and plain text.
            LawReadingStyle.apply(to: body, fontSize: fontSize)
            let rendered = body.string
            if !notes.isEmpty { body.append(NSAttributedString(string: "\n\n" + notes, attributes: attributes)) }
            c.renderedText = rendered; c.bodyLength = (rendered as NSString).length
            selection.text = rendered
            c.updating = true
            v.attributedText = body
            if changedSection { v.setContentOffset(.zero, animated: false) } else {
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
        let jump = "\(sectionID):\(paragraph ?? "")"
        if c.jump != jump {
            c.jump = jump
            if let paragraph {
                let r = (c.renderedText as NSString).range(of: "(\(paragraph))")
                if r.location != NSNotFound { v.scrollRangeToVisible(r) }
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
        var penActive: Bool?
        private var strokeStart: Int?
        private var strokePreview: NSRange?
        /// The line a Pencil stroke is bound to (text view coordinates).
        private var boundLine: (mid: CGFloat, height: CGFloat)?
        init(_ parent: NativeLawText) { self.parent = parent }

        /// Rich native HTML supports tables/lists. Only use it if its exact
        /// canonical text matches the shared anchor contract; otherwise plain
        /// source text is authoritative. Never fetch remote HTML resources.
        func importRich(html: String?, text: String) {
            rich = nil
            guard let html, !html.isEmpty, html.utf8.count <= 250_000,
                  html.range(of: "<(?:script|iframe|img|link|object|style)|(?:src|href)\\s*=", options: [.regularExpression, .caseInsensitive]) == nil else { return }
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
            let selection = parent.selection
            var outlined = Set(selection.tapped ? selection.marks : [])
            if let adjusting = selection.controller?.adjusting { outlined.insert(adjusting) }
            var fills = markRanges.filter { NSMaxRange($0.range) <= bodyLength }.map {
                LawMarkLayoutManager.Fill(range: $0.range, color: lawMarkFill($0.color), outline: outlined.contains($0.id) ? .systemBlue : nil)
            }
            if let preview = strokePreview, NSMaxRange(preview) <= bodyLength {
                let color = parent.pen.kind == .eraser ? UIColor.systemGray.withAlphaComponent(0.45) : lawMarkColor(parent.pen.hex).withAlphaComponent(0.6)
                fills.append(.init(range: preview, color: color, outline: nil))
            }
            container.layout.fills = fills
            container.layout.invalidateDisplay(forCharacterRange: NSRange(location: 0, length: container.storage.length))
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
        }
        func textViewDidChangeSelection(_ textView: UITextView) {
            guard !updating else { return }
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
                actions.append(UIAction(title: "Markierung entfernen", image: UIImage(systemName: "trash"), attributes: .destructive) { [weak controller] _ in
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

/// The law text view with its own TextKit 1 stack (marks drawn by
/// `LawMarkLayoutManager`) and the mark overlay above it.
final class LawTextContainer: UIView {
    let storage = NSTextStorage()
    let layout = LawMarkLayoutManager()
    let textView: UITextView
    let overlay = LawMarkOverlay()
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
    }
    var fills: [Fill] = []

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: CGPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        guard !fills.isEmpty, let storage = textStorage, let container = textContainers.first else { return }
        let text = storage.string as NSString
        for fill in fills where fill.range.length > 0 && NSMaxRange(fill.range) <= storage.length {
            let glyphs = glyphRange(forCharacterRange: fill.range, actualCharacterRange: nil)
            guard NSIntersectionRange(glyphs, glyphsToShow).length > 0 else { continue }
            let rects = lineRects(glyphs, text: text, storage: storage, container: container).map { $0.offsetBy(dx: origin.x, dy: origin.y) }
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
