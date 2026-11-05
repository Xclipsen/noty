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
        // Hardware Tab/⇧Tab: the same rule as the on-screen Tab (`handleIndentInput`).
        editor.onListTab = { [weak self, weak editor] outdent in
            guard let self, let editor else { return false }
            return self.indentTab(editor, outdent: outdent) || outdent
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
        // Behind a page break the text goes on on the next page, not below it.
        guard length == 0 || text.character(at: length - 1) != TextLines.pageBreak else { return nil }
        let font = editor.typingAttributes[.font] as? UIFont ?? .systemFont(ofSize: 14)
        let local = CGPoint(x: point.x - inset.left, y: point.y - inset.top)
        let width = Double(editor.bounds.width - inset.left - inset.right)
        let ascent = Double(font.ascender), descent = Double(-font.descender)
        guard width > 40, local.x >= 0, local.x <= width + 1 else { return nil }
        let top = manager.numberOfGlyphs == 0 ? 0 : manager.lineFragmentRect(forGlyphAt: manager.numberOfGlyphs - 1, effectiveRange: nil).maxY
        guard local.y >= top else { return nil }
        let ends = length == 0 || TextLines.isBreak(text.character(at: length - 1))
        guard let result = TextPlacement.below(tap: .init(x: Double(local.x), y: Double(local.y)), top: Double(top), endsWithBreak: ends,
                width: width, height: Double(editor.bounds.height - inset.top - inset.bottom),
                lineHeight: Double(font.lineHeight), ascent: ascent, descent: descent,
                ruling: editor.lineGrid?.ruling, origin: editor.lineGrid?.origin ?? 0, pageTop: editor.lineGrid?.pageTop),
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

    /// Tab and ⇧Tab of both keyboards and the indent buttons
    /// (`TextIndentEditing.tab`, `wholeParagraphs` for the buttons). False:
    /// Tab types an ordinary tab at the caret, ⇧Tab changes nothing.
    @discardableResult
    func indentTab(_ editor: PageTextView, outdent: Bool, wholeParagraphs: Bool = false) -> Bool {
        guard active, editor.markedTextRange == nil, fields[editor.objectID]?.editor === editor,
              let index = boxes.firstIndex(where: { $0.id == editor.objectID }) else { return false }
        let rules = indentRules(boxes[index])
        guard let plan = TextIndentEditing.tab(boxes[index], selection: editor.selectedRange, outdent: outdent, wholeParagraphs: wholeParagraphs,
                                               canChangeIndent: rules.canChangeIndent, continuation: rules.continuation) else { return false }
        applyIndentPlan(plan, at: index, editor: editor)
        return true
    }
    /// Paragraph indents, then tabs and marks, then the renumbering
    /// (`TextIndentEditing.Plan`), as one change of the field.
    func applyIndentPlan(_ plan: TextIndentEditing.Plan, at index: Int, editor: PageTextView) {
        editor.placement = nil
        let previous = boxes[index], storage = editor.textStorage
        let caretStart = TextLines.start(storage.string as NSString, editor.selectedRange.location)
        var selection = editor.selectedRange
        updating = true
        storage.beginEditing()
        for change in plan.indents where NSMaxRange(change.paragraph) <= storage.length {
            storage.enumerateAttribute(.paragraphStyle, in: change.paragraph) { value, part, _ in
                let style = ((value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
                style.firstLineHeadIndent = change.indent; style.headIndent = change.indent
                storage.addAttribute(.paragraphStyle, value: style, range: part)
            }
        }
        for batch in [plan.edits, plan.renumbering] {
            replace(batch, in: editor); selection = TextListEditing.selection(selection, after: batch)
        }
        storage.endEditing()
        editor.selectedRange = selection
        // Typing in the paragraph (also an empty last one) goes on with its new indent.
        if let change = plan.indents.first(where: { $0.paragraph.location == caretStart }),
           let typing = editor.typingAttributes[.paragraphStyle] as? NSParagraphStyle,
           let next = typing.mutableCopy() as? NSMutableParagraphStyle {
            next.firstLineHeadIndent = change.indent; next.headIndent = change.indent
            editor.typingAttributes[.paragraphStyle] = next
        }
        updating = false
        boxes[index].capture(editor.attributedText); fields[boxes[index].id]?.content = boxes[index]
        grow(index); synchronize()
        if boxes[index].flowID != nil { commitFlow(previous: previous, editor: editor) }
        else { publish() }
        layoutIfNeeded(); requestCaretReveal(.typing)
    }
    /// The indent buttons of the format bar: Tab or ⇧Tab in the prefix of every touched paragraph.
    func indentFromBar(outdent: Bool) {
        guard let editor = selectedID.flatMap({ fields[$0]?.editor }) else { return }
        indentTab(editor, outdent: outdent, wholeParagraphs: true)
    }

    private func replace(_ edits: [TextListEditing.Edit], in editor: PageTextView) {
        for edit in edits.sorted(by: { $0.range.location > $1.range.location }) where NSMaxRange(edit.range) <= editor.textStorage.length {
            let location = min(edit.range.location, max(0, editor.textStorage.length - 1))
            // At the very end (an empty last paragraph) the typing format, not the line before.
            let atEnd = edit.range.length == 0 && edit.range.location == editor.textStorage.length
            let attributes = editor.textStorage.length > 0 && !atEnd ? editor.textStorage.attributes(at: location, effectiveRange: nil) : editor.typingAttributes
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

    /// Tab, Return and ⌫ by the rules of `TextIndentEditing` (also the
    /// on-screen Tab over several lines, like the hardware Tab). nil: the text
    /// view types as usual. Remembers a typed space.
    func handleIndentInput(_ textView: UITextView, range: NSRange, text: String) -> Bool? {
        guard let editor = textView as? PageTextView, !insertingList, editor.markedTextRange == nil,
              fields[editor.objectID]?.editor === editor, let index = boxes.firstIndex(where: { $0.id == editor.objectID }) else { return nil }
        editor.typedSpace = text == " " && range.length == 0
        switch text {
        case "\t":
            return indentTab(editor, outdent: false) ? false : nil
        case "\n":
            let rules = indentRules(boxes[index])
            switch TextIndentEditing.newline(boxes[index], range: range, canChangeIndent: rules.canChangeIndent, continuation: rules.continuation) {
            case .edit(let edit)?:
                if edit.replacement.hasPrefix("\n") {
                    // One native insertion: one undo step for the break and its indent.
                    insertingList = true; defer { insertingList = false }
                    editor.selectedRange = edit.range; editor.insertText(edit.replacement)
                } else { applyListEdits([edit], at: index, editor: editor) }
                return false
            case .plan(let plan)?:
                applyIndentPlan(plan, at: index, editor: editor)
                return false
            case nil: return nil
            }
        case "" where range.length > 0 && editor.selectedRange.length == 0 && NSMaxRange(range) == editor.selectedRange.location:
            return backspace(editor, at: index) ? false : nil
        default: return nil
        }
    }
    /// ⌫ behind a list mark or at the start of an indented paragraph (`TextIndentEditing.backspace`).
    @discardableResult
    func backspace(_ editor: PageTextView, at index: Int) -> Bool {
        let rules = indentRules(boxes[index])
        switch TextIndentEditing.backspace(boxes[index], caret: editor.selectedRange.location,
                                           canChangeIndent: rules.canChangeIndent, continuation: rules.continuation) {
        case .edit(let edit)?: applyListEdits([edit], at: index, editor: editor)
        case .plan(let plan)?: applyIndentPlan(plan, at: index, editor: editor)
        case nil: return false
        }
        return true
    }
    /// ⌫ at the very start of a free field: UIKit asks no delegate there.
    func backspaceAtStart(_ editor: PageTextView) -> Bool {
        guard active, editor.markedTextRange == nil, editor.selectedRange == NSRange(location: 0, length: 0),
              fields[editor.objectID]?.editor === editor,
              let index = boxes.firstIndex(where: { $0.id == editor.objectID }), boxes[index].flowID == nil else { return false }
        return backspace(editor, at: index)
    }

    /// "* ", "1) ", "[] " … at a paragraph start become a list, „-> “ and the
    /// like an arrow (`TextArrowReplacement`): each a separate undo step, so
    /// one undo restores the typed characters.
    func finishListInput(_ editor: PageTextView) {
        guard editor.typedSpace else { return }
        editor.typedSpace = false
        guard active, editor.markedTextRange == nil, editor.selectedRange.length == 0,
              let index = boxes.firstIndex(where: { $0.id == editor.objectID }) else { return }
        let text = editor.text ?? "", caret = editor.selectedRange.location
        let start = TextLines.lineRange(text as NSString, NSRange(location: max(0, caret - 1), length: 0)).location
        if let edit = TextListEditing.autoList(in: text, caret: caret, level: boxes[index].listLevel(at: start)) {
            onUndoBoundary?()
            applyListEdits([edit], at: index, editor: editor)
            onUndoBoundary?()
            return
        }
        let enabled = UserDefaults.standard.object(forKey: AppSettingsKey.arrows) as? Bool ?? true
        guard enabled, let replacement = TextArrowReplacement.replacement(in: text, caret: caret) else { return }
        // ⌫ brought these characters back here: they stay.
        if let kept = keptArrow, kept.id == editor.objectID, kept.location == replacement.edit.range.location { return }
        keptArrow = nil
        onUndoBoundary?()
        applyListEdits([replacement.edit], at: index, editor: editor)
        onUndoBoundary?()
        replacedArrow = (editor.objectID, replacement)
    }
    /// ⌫ right behind an arrow just written: the typed characters come back
    /// at once (synchronously, no new replacement at this place).
    func restoreArrow(_ textView: UITextView, range: NSRange, text: String) -> Bool {
        guard let (id, replacement) = replacedArrow else { return false }
        replacedArrow = nil
        guard let editor = textView as? PageTextView, editor.objectID == id, !insertingList, editor.markedTextRange == nil,
              text.isEmpty, editor.selectedRange.length == 0, NSMaxRange(range) == editor.selectedRange.location,
              let index = boxes.firstIndex(where: { $0.id == id }),
              let edit = TextArrowReplacement.restoring(replacement, in: editor.text ?? "", caret: editor.selectedRange.location) else { return false }
        keptArrow = (id, edit.range.location)
        applyListEdits([edit], at: index, editor: editor)
        return true
    }
}
