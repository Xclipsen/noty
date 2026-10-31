import UIKit
import NotebookCore

// MARK: - Lists, nesting and click-and-type

final class SimultaneousTap: NSObject, UIGestureRecognizerDelegate {
    static let shared = SimultaneousTap()
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        (gestureRecognizer.view as? PageTextView)?.isFlow == true && (gestureRecognizer.view as? UITextView)?.isEditable == true
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
}

extension TextObjectLayer {
    func connectListInput(_ editor: PageTextView) {
        editor.onListTab = { [weak self, weak editor] outdent in
            guard let self, let editor else { return false }
            if self.nestList(editor, outdent: outdent) { return true }
            if outdent { self.indentFromBar(outdent: true) }
            return outdent
        }
        editor.onMaterializePlacement = { [weak self, weak editor] placement in
            guard let self, let editor else { return }
            self.writePlacement(placement, in: editor)
        }
        let tap = UITapGestureRecognizer(target: self, action: #selector(placementTap(_:)))
        tap.delegate = SimultaneousTap.shared; tap.cancelsTouchesInView = false; tap.delaysTouchesEnded = false
        // Pencil taps place the caret / open a field too; Pencil drags scroll (viewport).
        tap.allowedTouchTypes = [UITouch.TouchType.direct, .indirectPointer, .pencil].map { NSNumber(value: $0.rawValue) }
        editor.addGestureRecognizer(tap)
    }

    /// UIKit places its own caret for the same tap; afterwards a tap below the
    /// text keeps a pending caret on the tapped line.
    @objc fileprivate func placementTap(_ tap: UITapGestureRecognizer) {
        guard tap.state == .ended, active, let editor = tap.view as? PageTextView else { return }
        let point = tap.location(in: editor), page = pageID, expected = generation
        DispatchQueue.main.async { [weak self, weak editor] in
            guard let self, let editor, self.pageID == page, self.generation == expected else { return }
            self.placeCaret(in: editor, at: point)
        }
    }

    func placeCaret(in editor: PageTextView, at point: CGPoint) {
        guard active, editor.isFlow, editor.isFirstResponder, editor.markedTextRange == nil,
              fields[editor.objectID]?.editor === editor, let placement = caretPlacement(in: editor, at: point) else { return }
        let wasUpdating = updating; updating = true
        editor.selectedRange = NSRange(location: placement.location, length: 0)
        updating = wasUpdating
        editor.placement = placement
        requestCaretReveal(.navigation)
    }

    /// Only below the existing text: the nearest line there, always at the
    /// left edge (Feedback 44: no indent/centre/right placement by tapping;
    /// right of the middle a tap opens a free field instead).
    private func caretPlacement(in editor: PageTextView, at point: CGPoint) -> CaretPlacement? {
        let manager = editor.layoutManager, container = editor.textContainer, inset = editor.textContainerInset
        manager.ensureLayout(for: container)
        let text = editor.textStorage.string as NSString, length = text.length
        let font = editor.typingAttributes[.font] as? UIFont ?? .systemFont(ofSize: 14)
        let local = CGPoint(x: point.x - inset.left, y: point.y - inset.top)
        let width = Double(editor.bounds.width - inset.left - inset.right)
        let ascent = Double(font.ascender), descent = Double(-font.descender)
        guard width > 40, local.x >= 0, local.x <= width + 1 else { return nil }
        let top = manager.numberOfGlyphs == 0 ? 0 : manager.lineFragmentRect(forGlyphAt: manager.numberOfGlyphs - 1, effectiveRange: nil).maxY
        guard local.y >= top else { return nil }
        let ends = length == 0 || [10, 13, 0x2028, 0x2029].contains(text.character(at: length - 1))
        guard let result = TextPlacement.below(tap: .init(x: Double(local.x), y: Double(local.y)), top: Double(top), endsWithBreak: ends,
                width: width, height: Double(editor.bounds.height - inset.top - inset.bottom),
                lineHeight: Double(font.lineHeight), ascent: ascent, descent: descent,
                ruling: editor.rulingOrigin == nil ? nil : editor.rulingLines, origin: Double(editor.rulingOrigin ?? 0),
                pageTop: editor.rulingPageTop.map(Double.init)),
              result.newlines > 0 else { return nil }
        return CaretPlacement(location: length, newlines: result.newlines,
            caret: CGRect(x: Double(inset.left), y: result.baseline - ascent + Double(inset.top), width: 2, height: ascent + descent))
    }

    /// Writes the pending empty lines right before the first typed character;
    /// the following native edit records one undo step. The new line starts
    /// at the left edge like the shown caret.
    private func writePlacement(_ placement: CaretPlacement, in editor: PageTextView) {
        guard active, fields[editor.objectID]?.editor === editor, placement.location <= editor.textStorage.length else { return }
        var typing = editor.typingAttributes
        let wasUpdating = updating; updating = true
        defer { updating = wasUpdating }
        if placement.newlines > 0 {
            var filler = typing; filler[.paragraphStyle] = NSParagraphStyle.default
            editor.textStorage.replaceCharacters(in: NSRange(location: placement.location, length: 0),
                with: NSAttributedString(string: String(repeating: "\n", count: placement.newlines), attributes: filler))
        }
        editor.selectedRange = NSRange(location: placement.location + placement.newlines, length: 0)
        let paragraph = ((typing[.paragraphStyle] as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
        paragraph.headIndent = 0; paragraph.firstLineHeadIndent = 0; paragraph.alignment = .left
        typing[.paragraphStyle] = paragraph
        editor.typingAttributes = typing
    }

    /// Tab, ⇧Tab, the indent buttons and Return on an empty nested item.
    func nestList(_ editor: PageTextView, outdent: Bool) -> Bool {
        guard active, editor.markedTextRange == nil, fields[editor.objectID]?.editor === editor,
              let index = boxes.firstIndex(where: { $0.id == editor.objectID }),
              let plan = boxes[index].listNesting(selection: editor.selectedRange, outdent: outdent) else { return false }
        editor.placement = nil
        let previous = boxes[index]
        var selection = editor.selectedRange
        updating = true
        editor.textStorage.beginEditing()
        for (range, indent) in zip(plan.paragraphs, plan.indents) where NSMaxRange(range) <= editor.textStorage.length {
            editor.textStorage.enumerateAttribute(.paragraphStyle, in: range) { value, part, _ in
                let style = ((value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
                style.headIndent = indent; style.firstLineHeadIndent = indent
                editor.textStorage.addAttribute(.paragraphStyle, value: style, range: part)
            }
        }
        for batch in [plan.markers, plan.renumbering] {
            replace(batch, in: editor); selection = TextListEditing.selection(selection, after: batch)
        }
        editor.textStorage.endEditing()
        editor.selectedRange = selection
        updating = false
        boxes[index].capture(editor.attributedText); fields[boxes[index].id]?.content = boxes[index]
        grow(index); synchronize()
        if boxes[index].flowID != nil { commitFlow(previous: previous, editor: editor) }
        else { publish() }
        layoutIfNeeded(); requestCaretReveal(.typing)
        return true
    }
    func indentFromBar(outdent: Bool) {
        if let editor = selectedID.flatMap({ fields[$0]?.editor }), nestList(editor, outdent: outdent) { return }
        changeStyle({ $0.indent = outdent ? max(0, ($0.indent ?? 0) - 20) : min(240, ($0.indent ?? 0) + 20) }, paragraph: true)
    }

    private func replace(_ edits: [TextListEditing.Edit], in editor: PageTextView) {
        for edit in edits.sorted(by: { $0.range.location > $1.range.location }) where NSMaxRange(edit.range) <= editor.textStorage.length {
            let location = min(edit.range.location, max(0, editor.textStorage.length - 1))
            let attributes = editor.textStorage.length > 0 ? editor.textStorage.attributes(at: location, effectiveRange: nil) : editor.typingAttributes
            editor.textStorage.replaceCharacters(in: edit.range, with: NSAttributedString(string: edit.replacement, attributes: attributes))
        }
    }

    /// Free fields renumber locally; page flows renumber across pages in Core.
    func normalizeFloatingList(_ index: Int, previous: TextBox, editor: PageTextView) {
        guard boxes[index].flowID == nil, editor.markedTextRange == nil,
              let changed = TextListEditing.changedRange(from: previous.text, to: boxes[index].text) else { return }
        let box = boxes[index]
        let edits = TextListEditing.normalize(box.text, level: box.listLevel(at:), changed: changed,
            restart: TextListEditing.numberedItem(in: previous.text, at: changed.location, level: previous.listLevel(at:)))
        guard !edits.isEmpty else { return }
        let wasUpdating = updating; updating = true
        let selection = TextListEditing.selection(editor.selectedRange, after: edits)
        editor.textStorage.beginEditing(); replace(edits, in: editor); editor.textStorage.endEditing()
        editor.selectedRange = selection
        updating = wasUpdating
        boxes[index].capture(editor.attributedText); fields[boxes[index].id]?.content = boxes[index]
    }

    /// Tab inserts no tab in lists; Return on an empty nested item moves it out
    /// one level instead of ending the list. Remembers a typed space.
    func handleListInput(_ textView: UITextView, range: NSRange, text: String) -> Bool? {
        guard let editor = textView as? PageTextView, !insertingList, editor.markedTextRange == nil else { return nil }
        editor.typedSpace = text == " " && range.length == 0
        if text == "\t", nestList(editor, outdent: false) { return false }
        if text == "\n", let edit = TextListEditing.newline(in: editor.text ?? "", range: range), edit.replacement.isEmpty,
           let box = boxes.first(where: { $0.id == editor.objectID }),
           box.listLevel(at: ((editor.text ?? "") as NSString).lineRange(for: NSRange(location: range.location, length: 0)).location) > 0,
           nestList(editor, outdent: true) { return false }
        return nil
    }

    /// "- ", "* ", "1) ", "[] " … at a paragraph start become a list: a
    /// separate undo step, so one undo restores the typed characters.
    func finishListInput(_ editor: PageTextView) {
        guard editor.typedSpace else { return }
        editor.typedSpace = false
        guard active, editor.markedTextRange == nil, editor.selectedRange.length == 0,
              let index = boxes.firstIndex(where: { $0.id == editor.objectID }) else { return }
        let text = editor.text ?? "", caret = editor.selectedRange.location
        let start = (text as NSString).lineRange(for: NSRange(location: max(0, caret - 1), length: 0)).location
        guard let edit = TextListEditing.autoList(in: text, caret: caret, level: boxes[index].listLevel(at: start)) else { return }
        onUndoBoundary?()
        applyListEdits([edit], at: index, editor: editor)
        onUndoBoundary?()
    }
}
