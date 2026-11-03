import SwiftUI
import UIKit
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
    var onMark: (NSRange) -> Void
    var onRemove: ([String]) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> UITextView {
        // TextKit 1: highlights are changed in place as text attributes. TextKit 2
        // (default since iOS 16) did not reliably redraw such changes, so new and
        // removed marks only showed after the section was rebuilt.
        let v = UITextView(usingTextLayoutManager: false); v.isEditable = false; v.isSelectable = true; v.backgroundColor = .systemBackground
        // Bottom room for the floating selection bar.
        v.textContainerInset = UIEdgeInsets(top: 8, left: 12, bottom: 72, right: 12); v.delegate = context.coordinator
        v.scrollsToTop = false
        let stroke = LawPencilStroke(target: context.coordinator, action: #selector(Coordinator.pencil(_:)))
        v.addGestureRecognizer(stroke)
        context.coordinator.stroke = stroke
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped(_:)))
        tap.delegate = context.coordinator
        v.addGestureRecognizer(tap)
        context.coordinator.view = v
        return v
    }
    func updateUIView(_ v: UITextView, context: Context) {
        let c = context.coordinator
        c.parent = self
        selection.view = v
        // Highlighter/eraser: Pencil marks; fingers keep scrolling and selecting.
        // Other notebook tools: Pencil scrolls and selects like a finger.
        let penActive = pen.kind != .none
        if c.penActive != penActive {
            c.penActive = penActive
            c.stroke?.isEnabled = penActive
            v.panGestureRecognizer.allowedTouchTypes = penActive ? lawTouchTypesWithoutPencil : lawAllTouchTypes
        }
        let bodyKey = "\(sectionID):\(fontSize):\(text.hashValue):\(html.hashValue):\(notes.hashValue)"
        if c.bodyKey != bodyKey {
            let changedSection = c.sectionID != sectionID
            let resized = !changedSection && c.fontSize != fontSize
            let offset = v.contentOffset
            // The first visible character stays on top when the size changes.
            let topCharacter = resized ? v.closestPosition(to: CGPoint(x: v.textContainerInset.left + 1, y: offset.y + v.textContainerInset.top + 1)) .map { v.offset(from: v.beginningOfDocument, to: $0) } : nil
            let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: fontSize), .foregroundColor: UIColor.label]
            let richKey = "\(sectionID):\(text.hashValue):\(html.hashValue)"
            if c.richKey != richKey { c.richKey = richKey; c.importRich(html: html, text: text) }
            let body = c.rich.map { c.scaled($0, to: fontSize) } ?? NSMutableAttributedString(string: text, attributes: attributes)
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
        // Marks only change attributes in place: no new text, no scroll jump.
        if c.marksKey != marks.hashValue {
            c.marksKey = marks.hashValue
            let ranges = LawTextAnchor.originalRanges(text: c.renderedText, anchors: marks.map(\.anchor))
            c.markRanges = zip(marks, ranges).compactMap { mark, range in range.map { (mark.id, $0, lawMarkColor(mark.color)) } }
            c.applyHighlights(preview: nil)
        }
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
        var parent: NativeLawText
        weak var view: UITextView?
        var bodyKey = "", sectionID = "", jump = "", richKey = ""
        var fontSize = 0.0
        var marksKey: Int?
        /// HTML rendering of the current section at a reference size, or nil when
        /// the plain text is used. Imported once per section, not per size step.
        var rich: NSAttributedString?
        private var richBase: CGFloat = 17
        var updating = false
        var renderedText = ""
        var bodyLength = 0
        var markRanges: [(id: String, range: NSRange, color: UIColor)] = []
        weak var stroke: LawPencilStroke?
        var penActive: Bool?
        private var strokeStart: Int?
        private var strokePreview: NSRange?
        init(_ parent: NativeLawText) { self.parent = parent }

        /// Rich native HTML supports tables/lists. Only use it if its exact
        /// canonical text matches the shared anchor contract; otherwise plain
        /// source text is authoritative. Never fetch remote HTML resources.
        func importRich(html: String?, text: String) {
            rich = nil
            guard let html, !html.isEmpty, html.utf8.count <= 250_000,
                  html.range(of: "<(?:script|iframe|img|link|object|style)|(?:src|href)\\s*=", options: [.regularExpression, .caseInsensitive]) == nil else { return }
            let markup = "<html><head><meta charset='utf-8'><style>body{font-family:-apple-system;font-size:17px;color:#eeeeee}table{border-collapse:collapse}td,th{border:1px solid #666;padding:4px}</style></head><body>" + html + "</body></html>"
            guard let data = markup.data(using: .utf8),
                  let imported = try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.html, .characterEncoding: String.Encoding.utf8.rawValue], documentAttributes: nil),
                  LawTextAnchor.canonical(imported.string) == LawTextAnchor.canonical(text) else { return }
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
        func applyHighlights(preview: NSRange?) {
            guard let storage = view?.textStorage else { return }
            let body = NSRange(location: 0, length: min(bodyLength, storage.length))
            storage.beginEditing()
            storage.removeAttribute(.backgroundColor, range: body)
            for mark in markRanges where NSMaxRange(mark.range) <= body.length {
                storage.addAttribute(.backgroundColor, value: mark.color.withAlphaComponent(0.4), range: mark.range)
            }
            if let preview, NSMaxRange(preview) <= body.length {
                let color = parent.pen.kind == .eraser ? UIColor.systemGray.withAlphaComponent(0.5) : lawMarkColor(parent.pen.hex).withAlphaComponent(0.6)
                storage.addAttribute(.backgroundColor, value: color, range: preview)
            }
            storage.endEditing()
            view?.layoutManager.invalidateDisplay(forCharacterRange: body)
        }
        private func marks(in range: NSRange) -> [String] {
            markRanges.filter { NSIntersectionRange($0.range, range).length > 0 }.map(\.id)
        }
        /// Caret offset nearest to `point`, limited to the section text (not notes).
        private func caret(at point: CGPoint) -> Int {
            guard let v = view, let position = v.closestPosition(to: point) else { return 0 }
            return min(max(0, v.offset(from: v.beginningOfDocument, to: position)), bodyLength)
        }
        func textViewDidChangeSelection(_ textView: UITextView) {
            guard !updating else { return }
            let range = NSIntersectionRange(textView.selectedRange, NSRange(location: 0, length: bodyLength)), id = parent.sectionID
            let hit = range.length > 0 ? marks(in: range) : nil
            // Published state must not change during the SwiftUI update pass.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.parent.sectionID == id else { return }
                let selection = self.parent.selection
                selection.range = range.length > 0 ? range : NSRange(location: 0, length: 0)
                if let hit { selection.marks = hit }
            }
        }
        func textView(_ textView: UITextView, editMenuForTextIn range: NSRange, suggestedActions: [UIMenuElement]) -> UIMenu? {
            let clipped = NSIntersectionRange(range, NSRange(location: 0, length: bodyLength))
            guard clipped.length > 0 else { return nil }
            var actions: [UIMenuElement] = [UIAction(title: "Markieren", image: UIImage(systemName: "highlighter")) { [weak self] _ in self?.parent.onMark(clipped) }]
            let hit = marks(in: clipped)
            if !hit.isEmpty {
                actions.append(UIAction(title: hit.count == 1 ? "Markierung entfernen" : "Markierungen entfernen", image: UIImage(systemName: "eraser"), attributes: .destructive) { [weak self] _ in
                    self?.parent.onRemove(hit)
                })
            }
            return UIMenu(children: actions + suggestedActions)
        }
        /// A tap on a highlight offers to remove it; a tap elsewhere dismisses that.
        @objc func tapped(_ gesture: UITapGestureRecognizer) {
            guard let v = view, gesture.state == .ended else { return }
            let point = gesture.location(in: v)
            var hit: [String] = []
            if let character = v.characterRange(at: point) {
                let index = v.offset(from: v.beginningOfDocument, to: character.start)
                hit = markRanges.filter { NSLocationInRange(index, $0.range) }.map(\.id)
            }
            let selection = parent.selection, id = parent.sectionID
            // After the text view has handled the same tap (it may clear a selection).
            DispatchQueue.main.async { [weak self] in
                guard let self, self.parent.sectionID == id, (self.view?.selectedRange.length ?? 0) == 0 else { return }
                selection.marks = hit
            }
        }
        /// Highlighter: the stroke covers whole words from its start to its end, so
        /// the result is always a straight band along the lines. Eraser: marks
        /// under the stroke are removed.
        @objc func pencil(_ gesture: LawPencilStroke) {
            guard let v = view else { return }
            switch gesture.state {
            case .began:
                strokeStart = caret(at: gesture.startLocation ?? gesture.location(in: v))
                showStroke(stroke(to: gesture.location(in: v)))
            case .changed:
                showStroke(stroke(to: gesture.location(in: v)))
            case .ended:
                let range = stroke(to: gesture.location(in: v))
                strokeStart = nil; strokePreview = nil
                applyHighlights(preview: nil)
                guard let range else { return }
                if parent.pen.kind == .eraser {
                    let hit = marks(in: range)
                    if !hit.isEmpty { parent.onRemove(hit) }
                } else { parent.onMark(range) }
            default:
                strokeStart = nil; strokePreview = nil
                applyHighlights(preview: nil)
            }
        }
        /// Restyles only when the covered characters change, not per Pencil sample.
        private func showStroke(_ range: NSRange?) {
            guard range != strokePreview else { return }
            strokePreview = range
            applyHighlights(preview: range)
        }
        private func stroke(to point: CGPoint) -> NSRange? {
            guard let start = strokeStart else { return nil }
            let end = caret(at: point)
            guard end != start else { return nil }
            return words(NSRange(location: min(start, end), length: abs(end - start)))
        }
        /// Widens a stroke range to whole words and drops spaces at its ends.
        private func words(_ range: NSRange) -> NSRange? {
            let text = renderedText as NSString
            func word(_ i: Int) -> Bool {
                guard i >= 0, i < text.length, let scalar = UnicodeScalar(text.character(at: i)) else { return false }
                return CharacterSet.alphanumerics.contains(scalar)
            }
            var lo = range.location, hi = min(NSMaxRange(range), text.length)
            while lo < hi, !word(lo), CharacterSet.whitespacesAndNewlines.contains(UnicodeScalar(text.character(at: lo)) ?? "x") { lo += 1 }
            while hi > lo, !word(hi - 1), CharacterSet.whitespacesAndNewlines.contains(UnicodeScalar(text.character(at: hi - 1)) ?? "x") { hi -= 1 }
            guard hi > lo else { return nil }
            while lo > 0, word(lo), word(lo - 1) { lo -= 1 }
            while hi < text.length, word(hi - 1), word(hi) { hi += 1 }
            return NSRange(location: lo, length: hi - lo)
        }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    }
}
