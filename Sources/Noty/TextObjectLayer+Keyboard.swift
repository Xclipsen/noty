import UIKit
import NotebookCore

/// A selection over several pages of a text document (⌘A, visual mode). Each
/// page's text view only knows its own segment, so the selection lives here
/// and every text layer marks its part; text inside one page stays native.
@MainActor
final class TextFlowSelection {
    static let shared = TextFlowSelection()
    static let changed = Notification.Name("noty.flowSelection")
    private(set) var range: NSRange?
    private(set) var parts: [UUID: NSRange] = [:]
    /// ⌘A outside the text: selects as soon as the text has the caret.
    var selectAllWhenFocused = false
    func set(_ range: NSRange?, parts: [UUID: NSRange] = [:]) {
        // A new layout of the same range must be marked anew, too.
        guard range != nil || self.range != nil else { return }
        self.range = range; self.parts = parts
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }
}

/// The whole flow of a text document, for the page-local text layer.
struct TextFlowActions {
    var content: () -> TextBox?
    var offset: (UUID, Int) -> Int?
    var parts: (NSRange) -> [UUID: NSRange]
    var paragraph: (NSRange) -> NSRange?
    /// Replaces a range; the caret goes to the given flow offset (default: behind the text).
    var edit: (NSRange, String, Int?) -> Void
    var restyle: (NSRange, (inout TextBoxStyle) -> Void) -> Void
    /// The caret to a flow offset, on any page.
    var moveCaret: (Int) -> Void
}

extension TextObjectLayer {
    // MARK: Selection over pages

    /// ⌘A in a text document with several written pages. False: the field's own selection does it.
    func selectWholeFlow() -> Bool {
        guard let flow = flowActions, let content = flow.content(), let selectedID,
              boxes.first(where: { $0.id == selectedID })?.flowID != nil else { return false }
        let range = NSRange(location: 0, length: (content.text as NSString).length)
        let parts = flow.parts(range)
        guard parts.count > 1 else { return false }
        TextFlowSelection.shared.set(range, parts: parts)
        return true
    }
    /// ⌘A outside typing: visual mode over everything, so `d`, `y` and `c` work on it.
    func keyboardSelectAll(_ editor: PageTextView) -> Bool {
        let router = KeyboardRouter.shared
        guard router.isEnabled, router.textMode != .insert, let buffer = keyboardBuffer(editor), buffer.text.length > 0 else { return false }
        router.visualAnchor = 0; router.visualCaret = buffer.text.length - 1
        router.setTextMode(.visual(line: false), editor: editor)
        showVisual(editor: editor, buffer: buffer)
        return true
    }
    var flowSelectionText: String? {
        guard let range = TextFlowSelection.shared.range, let text = flowActions?.content()?.text as NSString?,
              NSMaxRange(range) <= text.length else { return nil }
        return text.substring(with: range)
    }
    /// Typing, paste and delete on a selection over pages. False: there is none.
    func replaceFlowSelection(with text: String) -> Bool {
        guard let range = TextFlowSelection.shared.range, let flow = flowActions else { return false }
        KeyboardRouter.shared.textChangedElsewhere()
        KeyboardRouter.shared.handoff = true
        flow.edit(range, text, nil)
        return true
    }
    func showFlowSelection() {
        let selection = TextFlowSelection.shared
        for (id, field) in fields {
            guard let local = selection.parts[id], NSMaxRange(local) <= field.editor.attributedText.length else { field.setFlowHighlight(nil); continue }
            let path = CGMutablePath(), manager = field.editor.layoutManager, container = field.editor.textContainer
            manager.ensureLayout(for: container)
            let glyphs = manager.glyphRange(forCharacterRange: local, actualCharacterRange: nil)
            manager.enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: container) { rect, _ in
                path.addRect(rect)
            }
            field.setFlowHighlight(path)
        }
    }

    // MARK: Keyboard mode on a text

    /// The text the commands work on: the whole flow, or the field.
    private func keyboardBuffer(_ editor: PageTextView) -> (text: NSString, base: Int)? {
        guard let box = boxes.first(where: { $0.id == editor.objectID }) else { return nil }
        if box.flowID != nil, let flow = flowActions, let content = flow.content(), let base = flow.offset(box.id, 0) {
            return (content.text as NSString, base)
        }
        return ((editor.text ?? "") as NSString, 0)
    }
    private func caret(_ editor: PageTextView, base: Int) -> Int { base + editor.selectedRange.location }

    private func setCaret(_ offset: Int, editor: PageTextView, buffer: (text: NSString, base: Int)) {
        let local = offset - buffer.base, length = editor.attributedText.length
        let last = buffer.base + length >= buffer.text.length
        if local >= 0, local < length || (local == length && last) {
            editor.selectedRange = NSRange(location: local, length: 0)
            requestCaretReveal(.navigation)
        } else {
            KeyboardRouter.shared.handoff = true
            flowActions?.moveCaret(offset)
        }
    }

    /// Visual lines inside this page's text view; over a page edge the next
    /// segment. `offset` may lie on another page in visual mode: whole lines then.
    private func verticalTarget(down: Bool, count: Int, from offset: Int, editor: PageTextView, buffer: (text: NSString, base: Int)) -> Int {
        var current = offset
        for _ in 0..<max(1, count) {
            let local = current - buffer.base
            if local >= 0, local <= editor.attributedText.length,
               let position = editor.position(from: editor.beginningOfDocument, offset: local),
               let next = editor.position(from: position, in: down ? .down : .up, offset: 1), editor.compare(next, to: position) != .orderedSame {
                current = buffer.base + editor.offset(from: editor.beginningOfDocument, to: next)
            } else if down {
                let end = TextMotions.lineEnd(buffer.text, current)
                current = end < buffer.text.length ? end + 1 : current
            } else {
                let start = TextMotions.lineStart(buffer.text, current)
                current = start > 0 ? TextMotions.lineStart(buffer.text, start - 1) : current
            }
        }
        return TextMotions.normalCaret(buffer.text, current)
    }
    private func target(_ motion: TextMotion, count: Int, explicit: Bool, from offset: Int, editor: PageTextView,
                        buffer: (text: NSString, base: Int)) -> Int {
        switch motion {
        case .down: return verticalTarget(down: true, count: count, from: offset, editor: editor, buffer: buffer)
        case .up: return verticalTarget(down: false, count: count, from: offset, editor: editor, buffer: buffer)
        case .documentEnd where explicit, .documentStart where explicit:
            // 12G: the twelfth line.
            var line = 1, index = 0
            while line < count, index < buffer.text.length {
                index = TextMotions.lineEnd(buffer.text, index) + 1; line += 1
            }
            return TextMotions.normalCaret(buffer.text, min(index, buffer.text.length))
        default: return TextMotions.target(motion, in: buffer.text, from: offset, count: count) ?? offset
        }
    }

    /// Replaces a range of the buffer: one undo step, inside this page like a
    /// native edit, over a page change through the whole flow.
    private func replace(_ range: NSRange, with replacement: String, caret: Int, editor: PageTextView, buffer: (text: NSString, base: Int)) {
        onUndoBoundary?()
        let local = NSRange(location: range.location - buffer.base, length: range.length)
        if local.location >= 0, NSMaxRange(local) <= editor.attributedText.length, let index = boxes.firstIndex(where: { $0.id == editor.objectID }) {
            let flow = boxes[index].flowID != nil
            applyListEdits([TextListEditing.Edit(range: local, replacement: replacement)], at: index, editor: editor)
            if let fresh = keyboardBuffer(editor) { setCaret(caret, editor: editor, buffer: fresh) }
            // The edit left a focus for the next view update: this newer one replaces it.
            if flow { KeyboardRouter.shared.handoff = true; flowActions?.moveCaret(caret) }
        } else {
            KeyboardRouter.shared.handoff = true
            flowActions?.edit(range, replacement, caret)
        }
    }

    private func store(_ range: NSRange, of text: NSString, linewise: Bool) {
        var value = text.substring(with: range)
        guard !value.isEmpty else { return } // an empty line must not wipe the pasteboard
        // The last line takes the break before it: as a register it is a line like the others.
        if linewise, value.hasPrefix("\n"), !value.hasSuffix("\n") { value = String(value.dropFirst()) + "\n" }
        let router = KeyboardRouter.shared
        router.register = value; router.registerLinewise = linewise
        UIPasteboard.general.string = value
    }

    /// `content`: what `c` replaces where that differs from `range` (lines keep their break).
    private func apply(_ op: TextOperator, _ range: NSRange, linewise: Bool, content: NSRange? = nil, editor: PageTextView, buffer: (text: NSString, base: Int)) {
        store(range, of: buffer.text, linewise: linewise)
        let router = KeyboardRouter.shared
        switch op {
        case .yank:
            setCaret(TextMotions.normalCaret(buffer.text, range.location), editor: editor, buffer: buffer)
        case .delete:
            let after = buffer.text.replacingCharacters(in: range, with: "") as NSString
            replace(range, with: "", caret: TextMotions.normalCaret(after, min(range.location, after.length)), editor: editor, buffer: buffer)
        case .change:
            let target = content ?? range
            router.setTextMode(.insert, editor: editor)
            if target.length > 0 { replace(target, with: "", caret: target.location, editor: editor, buffer: buffer) }
            else { setCaret(target.location, editor: editor, buffer: buffer) }
        }
    }

    private func visualRange(_ buffer: (text: NSString, base: Int)) -> NSRange {
        let router = KeyboardRouter.shared
        // Clamped: the text may have become shorter than a stored offset.
        let length = buffer.text.length
        let low = min(router.visualAnchor, router.visualCaret, length), high = min(max(router.visualAnchor, router.visualCaret), length)
        if router.isLinewiseVisual {
            let start = TextMotions.lineStart(buffer.text, low), end = TextMotions.lineEnd(buffer.text, high)
            return NSRange(location: start, length: min(buffer.text.length, end + 1) - start)
        }
        let end = high < buffer.text.length ? NSMaxRange(buffer.text.rangeOfComposedCharacterSequence(at: high)) : high
        return NSRange(location: low, length: end - low)
    }
    private func showVisual(editor: PageTextView, buffer: (text: NSString, base: Int)) {
        let range = visualRange(buffer)
        guard let flow = flowActions, boxes.first(where: { $0.id == editor.objectID })?.flowID != nil else {
            editor.selectedRange = range; return
        }
        let parts = flow.parts(range)
        if parts.count == 1, let local = parts[editor.objectID] {
            TextFlowSelection.shared.set(nil)
            editor.selectedRange = local
        } else {
            TextFlowSelection.shared.set(range, parts: parts)
        }
        requestCaretReveal(.navigation)
    }

    /// ⌘V on a marked text: it is replaced, also over pages.
    func keyboardReplaceSelection(with text: String, editor: PageTextView) {
        guard KeyboardRouter.shared.isVisual, let buffer = keyboardBuffer(editor) else { return }
        let range = visualRange(buffer)
        TextFlowSelection.shared.set(nil)
        KeyboardRouter.shared.setTextMode(.normal, editor: editor)
        let after = buffer.text.replacingCharacters(in: range, with: text) as NSString
        replace(range, with: text, caret: TextMotions.normalCaret(after, range.location), editor: editor, buffer: buffer)
    }
    /// Back in normal mode: the caret stands where visual mode stood.
    func keyboardEndVisual(_ editor: PageTextView) {
        guard let buffer = keyboardBuffer(editor) else { return }
        setCaret(KeyboardRouter.shared.visualCaret, editor: editor, buffer: buffer)
    }
    /// Esc after typing: like vim, one character back onto the last typed one.
    func keyboardStepBackAfterTyping(_ editor: PageTextView) {
        guard let buffer = keyboardBuffer(editor) else { return }
        let offset = caret(editor, base: buffer.base)
        let step = TextMotions.target(.left, in: buffer.text, from: offset) ?? offset
        setCaret(TextMotions.normalCaret(buffer.text, step), editor: editor, buffer: buffer)
    }

    /// Runs a text command. False: not a text command (the router goes on).
    func keyboardPerform(_ action: KeyAction, count: Int, explicit: Bool, editor: PageTextView) -> Bool {
        guard let buffer = keyboardBuffer(editor) else { return false }
        let router = KeyboardRouter.shared, offset = caret(editor, base: buffer.base)
        switch action {
        case .move(let motion):
            if router.isVisual {
                router.visualCaret = target(motion, count: count, explicit: explicit, from: router.visualCaret, editor: editor, buffer: buffer)
                showVisual(editor: editor, buffer: buffer)
            } else {
                setCaret(target(motion, count: count, explicit: explicit, from: offset, editor: editor, buffer: buffer), editor: editor, buffer: buffer)
            }
        case .visual(let line):
            if router.textMode == .visual(line: line) { _ = router.escape(in: editor); return true }
            if !router.isVisual { router.visualAnchor = offset; router.visualCaret = offset }
            router.setTextMode(.visual(line: line), editor: editor)
            showVisual(editor: editor, buffer: buffer)
        case .operateSelection(let op):
            let range = visualRange(buffer), linewise = router.isLinewiseVisual
            var content = range
            if linewise, content.length > 0, TextMotions.isLineBreak(buffer.text.character(at: NSMaxRange(content) - 1)) { content.length -= 1 }
            TextFlowSelection.shared.set(nil)
            router.setTextMode(.normal, editor: editor)
            apply(op, range, linewise: linewise, content: content, editor: editor, buffer: buffer)
        case .operate(let op, let motion):
            let found = TextMotions.range(of: motion, in: buffer.text, from: offset, count: count)
            guard found.range.length > 0 else { return true }
            apply(op, found.range, linewise: found.linewise,
                  content: TextMotions.changeRange(of: motion, in: buffer.text, from: offset, count: count), editor: editor, buffer: buffer)
        case .operateLine(let op):
            let range = TextMotions.lineRange(in: buffer.text, at: offset, count: count, trailingBreakOnly: op == .yank)
            guard range.length > 0 || op == .change else { return true }
            apply(op, range, linewise: true, content: TextMotions.lineContent(in: buffer.text, at: offset, count: count), editor: editor, buffer: buffer)
        case .deleteCharacter(let before):
            guard let edit = TextMotions.deleteCharacter(in: buffer.text, at: offset, before: before, count: count) else { return true }
            store(edit.range, of: buffer.text, linewise: false)
            let after = buffer.text.replacingCharacters(in: edit.range, with: "") as NSString
            replace(edit.range, with: "", caret: TextMotions.normalCaret(after, edit.caret), editor: editor, buffer: buffer)
        case .joinLines:
            guard let edit = TextMotions.joinLines(in: buffer.text, at: offset) else { return true }
            replace(edit.range, with: edit.replacement, caret: edit.caret, editor: editor, buffer: buffer)
        case .paste(let before):
            let clip = UIPasteboard.general.string ?? ""
            guard !clip.isEmpty else { return true }
            let edit = TextMotions.paste(clip, linewise: router.registerLinewise && clip == router.register, in: buffer.text, at: offset, before: before, count: count)
            replace(edit.range, with: edit.replacement, caret: edit.caret, editor: editor, buffer: buffer)
        case .insert(let entry):
            let edit = TextMotions.insertion(entry, in: buffer.text, at: offset)
            router.setTextMode(.insert, editor: editor)
            if edit.replacement.isEmpty { setCaret(edit.caret, editor: editor, buffer: buffer) }
            else { replace(edit.range, with: edit.replacement, caret: edit.caret, editor: editor, buffer: buffer) }
        case .undo, .redo:
            let redo = action == .redo
            if boxes.first(where: { $0.id == editor.objectID })?.flowID != nil { onFlowUndo?(redo) }
            else if redo { notebookUndo?.redo() } else { notebookUndo?.undo() }
        default: return false
        }
        return true
    }
}
