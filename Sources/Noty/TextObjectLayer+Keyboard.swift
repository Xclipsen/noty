import UIKit
import NotebookCore

/// A selection over several pages of a text document (⌘A, keyboard mode). Each
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
    /// Replaces ranges (ascending) as one undo step; the caret goes to the given flow offset (default: behind the text).
    var edit: ([TextListEditing.Edit], Int?) -> Void
    var restyle: (NSRange, (inout TextBoxStyle) -> Void) -> Void
    /// The selection to a flow range, on any page.
    var moveCaret: (NSRange) -> Void
    /// The segments with their pages, for lines over a page change.
    var segments: () -> [(page: Page, box: TextBox)]
    /// Text editor 2: the model follows its buffer. The closure gives the
    /// layout's page length for a page and the text from there on (nil: unknown).
    var change: ((TextFlowChange, @escaping (Page, TextBox) -> Int?) -> TextFlowFocus?)? = nil
    /// The start of a segment moves back onto the page before, if it fits.
    /// The selection (flow offsets) goes with its text.
    var settle: (UUID, NSRange?) -> Void = { _, _ in }
}

/// `j`/`k` go by the lines on screen, measured by the same layout that draws them.
@MainActor
private struct KeyboardLineLayout: @MainActor TextEngineLayout {
    weak var layer: TextObjectLayer?
    weak var editor: PageTextView?
    var visibleLines: Int {
        guard let viewport = KeyboardRouter.shared.viewport, let editor, let font = editor.font else { return 40 }
        return max(1, Int(viewport.bounds.height / max(1, font.lineHeight * viewport.zoomScale)))
    }
    func verticalTarget(from offset: Int, lines: Int, goal: Double?, in text: NSString) -> (offset: Int, goal: Double) {
        guard let layer, let editor else { return LogicalLineLayout().verticalTarget(from: offset, lines: lines, goal: goal, in: text) }
        return layer.displayedLine(from: offset, lines: lines, goal: goal, editor: editor)
    }
}

/// The laid-out lines of one text view or flow segment. `base`: its first
/// offset in the buffer; offsets here are local to it.
@MainActor
private struct LineSpan {
    let manager: NSLayoutManager
    let container: NSTextContainer
    let base: Int
    let length: Int
    /// The empty line behind a final line break exists only here: on a page
    /// before the end of the flow the text goes on on the next page.
    let isLast: Bool
    /// Keeps the layout of a page without a text view alive.
    var layout: TextObjectLayout?

    private var extraLine: CGRect? {
        let extra = manager.extraLineFragmentRect
        return isLast && extra.height > 0 ? extra : nil
    }
    /// The left edge of the character at `local`.
    func x(of local: Int) -> CGFloat {
        manager.ensureLayout(for: container)
        let count = manager.numberOfGlyphs
        if local < length, count > 0 {
            let glyph = manager.glyphIndexForCharacter(at: local)
            return manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minX + manager.location(forGlyphAt: glyph).x
        }
        if let extraLine { return extraLine.minX }
        return count > 0 ? manager.lineFragmentUsedRect(forGlyphAt: count - 1, effectiveRange: nil).maxX : 0
    }
    /// The place at `x` on the next line up or down; nil: no such line here.
    func neighbour(of local: Int, down: Bool, x: CGFloat) -> Int? {
        manager.ensureLayout(for: container)
        let count = manager.numberOfGlyphs
        guard count > 0 else { return nil }
        if local >= length, extraLine != nil { return down ? nil : place(onLineOf: count - 1, x: x) }
        var line = NSRange()
        _ = manager.lineFragmentRect(forGlyphAt: manager.glyphIndexForCharacter(at: min(local, length - 1)), effectiveRange: &line)
        if down {
            if NSMaxRange(line) < count { return place(onLineOf: NSMaxRange(line), x: x) }
            return extraLine == nil ? nil : length
        }
        return line.location > 0 ? place(onLineOf: line.location - 1, x: x) : nil
    }
    func firstLine(x: CGFloat) -> Int {
        manager.ensureLayout(for: container)
        return manager.numberOfGlyphs > 0 ? place(onLineOf: 0, x: x) : 0
    }
    func lastLine(x: CGFloat) -> Int {
        manager.ensureLayout(for: container)
        if extraLine != nil { return length }
        return manager.numberOfGlyphs > 0 ? place(onLineOf: manager.numberOfGlyphs - 1, x: x) : 0
    }
    private func place(onLineOf glyph: Int, x: CGFloat) -> Int {
        var line = NSRange()
        let rect = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &line)
        let hit = manager.glyphIndex(for: CGPoint(x: x, y: rect.midY), in: container)
        return manager.characterIndexForGlyph(at: min(max(hit, line.location), NSMaxRange(line) - 1))
    }
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
    /// ⌘A outside typing: `%`, so `d`, `y` and `c` work on it.
    func keyboardSelectAll(_ editor: PageTextView) -> Bool {
        let router = KeyboardRouter.shared
        guard router.isEnabled, router.mode != .insert, let buffer = keyboardBuffer(editor), buffer.text.length > 0 else { return false }
        keyboardRun(.selectAll, count: nil, editor: editor)
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
        flow.edit([TextListEditing.Edit(range: range, replacement: text)], nil)
        return true
    }
    /// A manual page break, one undo step. In NOR and SEL it goes before the
    /// selection, which stays text.
    func insertPageBreak() {
        guard let selectedID, boxes.first(where: { $0.id == selectedID })?.flowID != nil, let flow = flowActions,
              let editor = fields[selectedID]?.editor, editor.markedTextRange == nil,
              let caret = flow.offset(selectedID, editor.selectedRange.location) else { return }
        let router = KeyboardRouter.shared
        var range = TextFlowSelection.shared.range ?? NSRange(location: caret, length: editor.selectedRange.length)
        if !router.allowsTyping { range.length = 0 }
        router.textChangedElsewhere()
        router.handoff = true
        flow.edit([TextListEditing.Edit(range: range, replacement: TextLines.pageBreakText)], nil)
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

    // MARK: Buffer and engine

    /// The text the commands work on: the whole flow, or the field.
    private func keyboardBuffer(_ editor: PageTextView) -> (text: NSString, base: Int)? {
        guard let box = boxes.first(where: { $0.id == editor.objectID }) else { return nil }
        guard box.flowID != nil, let flow = flowActions else { return ((editor.text ?? "") as NSString, 0) }
        guard let content = flow.content(), let base = flow.offset(box.id, 0) else { return nil }
        return (content.text as NSString, base)
    }
    private func isFlow(_ editor: PageTextView) -> Bool {
        flowActions != nil && boxes.first(where: { $0.id == editor.objectID })?.flowID != nil
    }
    /// A flow edit changes the model at once and the views with the next
    /// update. Until then this view must neither take edits nor set a selection:
    /// `textViewDidChangeSelection` would publish its old text over the new.
    private func viewIsCurrent(_ editor: PageTextView) -> Bool {
        guard isFlow(editor) else { return true }
        return readCurrentBoxes?().first(where: { $0.id == editor.objectID })?.text == editor.text
    }

    /// The selection in buffer offsets, as the screen shows it.
    private func shownSelection(_ editor: PageTextView, buffer: (text: NSString, base: Int)) -> NSRange {
        let router = KeyboardRouter.shared
        // A focus request is on its way: the view is behind the engine.
        if router.handoff, router.mode != .insert { return router.engine.selectedRange }
        if isFlow(editor), let range = TextFlowSelection.shared.range, NSMaxRange(range) <= buffer.text.length { return range }
        return NSRange(location: buffer.base + editor.selectedRange.location, length: editor.selectedRange.length)
    }
    /// Undo, taps and typing happen outside the engine: it takes over what the view shows.
    @discardableResult
    func keyboardSync(_ editor: PageTextView) -> Bool {
        guard let buffer = keyboardBuffer(editor) else { return false }
        let router = KeyboardRouter.shared
        router.engine.useJumps(of: boxes.first(where: { $0.id == editor.objectID })?.flowID ?? editor.objectID)
        router.engine.sync(text: buffer.text as String, selection: shownSelection(editor, buffer: buffer))
        return true
    }

    /// Runs a text command in NOR or SEL.
    func keyboardRun(_ command: TextEngine.Command, count: Int?, editor: PageTextView) {
        guard keyboardSync(editor) else { return }
        let router = KeyboardRouter.shared
        switch command {
        case .paste, .replaceWithRegister, .playMacro: router.adoptPasteboard()
        default: break
        }
        router.engine.layout = KeyboardLineLayout(layer: self, editor: editor)
        // Editing here types at one caret: `c`, `i`, `o` … must not touch selections out of sight.
        finish(router.engine.performAtPrimary(command, count: count), editor: editor)
    }

    private func finish(_ outcome: TextEngine.Outcome, editor: PageTextView) {
        let router = KeyboardRouter.shared
        if outcome.yanked { router.exportRegister() }
        if let notice = outcome.notice { router.show(notice) }
        if router.mode == .insert { router.insertBegan(at: router.engine.cursor) }
        router.modeChanged(editor: editor)
        if outcome.edits.isEmpty { keyboardShowSelection(editor) } else { apply(outcome, editor: editor) }
    }

    /// One undo step: inside this page like a native edit, otherwise through
    /// the whole flow. The separate edits keep the formats between them. What
    /// INS types next belongs to `c` or `o`, after anything else it is a step of its own.
    private func apply(_ outcome: TextEngine.Outcome, editor: PageTextView) {
        guard let buffer = keyboardBuffer(editor) else { return }
        let router = KeyboardRouter.shared, flowing = isFlow(editor)
        onUndoBoundary?()
        defer { if router.mode != .insert { onUndoBoundary?() } }
        let edits = outcome.textEdits(in: flowing ? flowActions?.content() : boxes.first { $0.id == editor.objectID })
        let start = edits.first?.range.location ?? 0, end = edits.map { NSMaxRange($0.range) }.max() ?? start
        // On a new empty last line only the reflow knows the page, it may be the
        // next one. It needs that caret, and its focus stands: `moveCaret` goes
        // by the written text and would pull the caret back.
        let text = router.engine.text
        let onEmptyLastLine = flowing && text.length > 0 && router.engine.cursor == text.length && TextLines.isBreak(text.character(at: text.length - 1))
        if onEmptyLastLine, let flow = flowActions {
            router.handoff = true
            TextFlowSelection.shared.set(nil)
            flow.edit(edits, router.engine.cursor)
        } else if viewIsCurrent(editor), start >= buffer.base, end - buffer.base <= editor.attributedText.length,
                  let index = boxes.firstIndex(where: { $0.id == editor.objectID }) {
            let local = edits.map { TextListEditing.Edit(range: NSRange(location: $0.range.location - buffer.base, length: $0.range.length), replacement: $0.replacement) }
            applyListEdits(local, at: index, editor: editor)
            // The edit left a focus for the next view update: this newer one replaces it.
            keyboardShowSelection(editor, focusing: flowing)
        } else if let flow = flowActions {
            router.handoff = true
            flow.edit(edits, router.engine.cursor)
            keyboardShowSelection(editor, focusing: true)
        }
    }

    /// The engine's primary selection on screen: native inside one page, over
    /// pages `TextFlowSelection` with the caret at the cursor. A cursor on a
    /// character is the wide caret, not a selection. `focusing`: a focus
    /// request also goes out, whatever this view can show itself.
    func keyboardShowSelection(_ editor: PageTextView, focusing: Bool = false) {
        guard let buffer = keyboardBuffer(editor) else { return }
        let engine = KeyboardRouter.shared.engine
        let wide = engine.mode != .insert && engine.primaryIsWide
        let caret = NSRange(location: engine.cursor, length: 0)
        var shown = wide ? engine.selectedRange : caret
        if isFlow(editor), let flow = flowActions {
            let parts = wide ? flow.parts(shown) : [:]
            if parts.count > 1 { TextFlowSelection.shared.set(shown, parts: parts); shown = caret } else { TextFlowSelection.shared.set(nil) }
        }
        place(shown, focusing: focusing, editor: editor, buffer: buffer)
    }
    private func place(_ range: NSRange, focusing: Bool, editor: PageTextView, buffer: (text: NSString, base: Int)) {
        let router = KeyboardRouter.shared
        let flow = isFlow(editor) ? flowActions : nil
        let local = range.location - buffer.base, length = editor.attributedText.length, end = local + range.length
        // A place on the boundary of two segments belongs to the next one, a selection may end there.
        let last = buffer.base + length >= buffer.text.length
        let fits = local >= 0 && (end < length || (end == length && (last || range.length > 0)))
        // With a focus request under way only a newer request is sure to come last.
        if flow == nil || (fits && !router.handoff && viewIsCurrent(editor)) {
            let start = min(max(0, local), length)
            router.showingSelection = true
            editor.selectedRange = NSRange(location: start, length: min(range.length, length - start))
            router.showingSelection = false
            requestCaretReveal(.navigation)
            if !focusing { return }
        }
        guard let flow else { return }
        router.handoff = true
        flow.moveCaret(range)
    }

    // MARK: Paths from outside the keys

    /// Esc: back one level. False: nothing left, the text ends.
    func keyboardEscape(_ editor: PageTextView) -> Bool {
        let router = KeyboardRouter.shared
        if router.mode == .insert { syncAfterTyping(editor) } else { keyboardSync(editor) }
        let outcome = router.engine.perform(.escape)
        guard !outcome.leavesText else { return false }
        finish(outcome, editor: editor)
        return true
    }
    /// Typing behind `i` or `a` goes on as the selection (`TextEngine.sync`).
    /// After a tap or a moved caret there is nothing to go on from: the cursor
    /// goes on the last typed character, or stays where the tap put it.
    private func syncAfterTyping(_ editor: PageTextView) {
        guard let buffer = keyboardBuffer(editor) else { return }
        let router = KeyboardRouter.shared, selection = shownSelection(editor, buffer: buffer)
        if selection.length == 0, router.insertRun == selection.location {
            router.engine.sync(text: buffer.text as String, selection: selection)
            return
        }
        var place = selection
        let caret = min(selection.location, buffer.text.length)
        if selection.length == 0, caret > 0 {
            let atEnd = caret == buffer.text.length || TextLines.isBreak(buffer.text.character(at: caret))
                || caret == buffer.base + editor.attributedText.length
            if router.typedSinceInsert || atEnd, !TextLines.isBreak(buffer.text.character(at: caret - 1)) {
                place.location = buffer.text.rangeOfComposedCharacterSequence(at: caret - 1).location
            }
        }
        router.engine.sync(text: buffer.text as String, selection: place, mode: .insert)
    }
    /// After native typing in INS.
    func keyboardTyped(_ editor: PageTextView) {
        let router = KeyboardRouter.shared
        guard router.isEnabled, router.keyboardSeen, router.mode == .insert else { return }
        let local = editor.selectedRange.location
        router.typed(caret: isFlow(editor) ? flowActions?.offset(editor.objectID, local) ?? local : local)
    }
    /// Automatic pairs: a typed character at a plain caret. Marked text,
    /// autocorrection and dictation replace ranges or bring more than one
    /// character, they stay native. Only this page's text counts here, the
    /// neighbour of a caret on the page's edge is unknown.
    func handlePairInput(_ textView: UITextView, range: NSRange, text: String) -> Bool? {
        guard let editor = textView as? PageTextView, !insertingList, KeyboardRouter.shared.pairsTyping,
              editor.markedTextRange == nil, editor.selectedRange.length == 0, NSMaxRange(range) == editor.selectedRange.location else { return nil }
        let source = (editor.text ?? "") as NSString
        if text.isEmpty, range.length == 1 {
            guard let pair = TextTyping.pairDeletion(in: source, at: NSMaxRange(range)),
                  let index = boxes.firstIndex(where: { $0.id == editor.objectID }) else { return nil }
            applyListEdits([TextListEditing.Edit(range: pair, replacement: "")], at: index, editor: editor)
            keyboardTyped(editor)
            return false
        }
        guard range.length == 0, let pairing = TextTyping.pairing(text, in: source, at: range.location) else { return nil }
        if !pairing.insert.isEmpty {
            insertingList = true; defer { insertingList = false }
            editor.insertText(pairing.insert)
        }
        let caret = range.location + pairing.advance
        editor.selectedRange = NSRange(location: caret, length: 0)
        // The edit left a focus behind the pair: this newer one replaces it.
        if let flow = isFlow(editor) ? flowActions : nil, let offset = flow.offset(editor.objectID, caret) {
            KeyboardRouter.shared.handoff = true
            flow.moveCaret(NSRange(location: offset, length: 0))
        }
        keyboardTyped(editor)
        return false
    }
    /// ⌘V outside typing: replaces a marked text, otherwise `P`. The register takes the pasteboard.
    func keyboardPaste(_ editor: PageTextView) {
        guard keyboardSync(editor) else { return }
        let router = KeyboardRouter.shared
        keyboardRun(router.engine.primaryIsWide || router.mode == .select ? .replaceWithRegister : .paste(before: true), count: nil, editor: editor)
    }
    /// ⌘X outside typing. False: only a cursor, nothing marked.
    func keyboardCut(_ editor: PageTextView) -> Bool {
        guard keyboardSync(editor), KeyboardRouter.shared.engine.primaryIsWide else { return false }
        keyboardRun(.delete, count: nil, editor: editor)
        return true
    }
    func keyboardUndo(redo: Bool, editor: PageTextView) {
        let router = KeyboardRouter.shared
        if boxes.first(where: { $0.id == editor.objectID })?.flowID != nil {
            onFlowUndo?(redo)
        } else if redo { notebookUndo?.redo() } else { notebookUndo?.undo() }
        router.textChangedElsewhere()
    }

    // MARK: Lines on screen

    /// The offset `lines` displayed lines away, in this view and on over page
    /// changes. The goal is an x position.
    func displayedLine(from offset: Int, lines: Int, goal: Double?, editor: PageTextView) -> (offset: Int, goal: Double) {
        guard var span = lineSpan(at: offset, editor: editor) else { return (offset, goal ?? 0) }
        let x = goal.map { CGFloat($0) } ?? span.x(of: offset - span.base)
        var current = offset
        for _ in 0..<abs(lines) {
            if let next = span.neighbour(of: current - span.base, down: lines > 0, x: x) { current = span.base + next; continue }
            let edge = lines > 0 ? span.base + span.length : span.base - 1
            guard !span.isLast || lines < 0, edge >= 0, let other = lineSpan(at: edge, editor: editor) else { break }
            current = other.base + (lines > 0 ? other.firstLine(x: x) : other.lastLine(x: x))
            span = other
        }
        return (current, Double(x))
    }
    private func lineSpan(at offset: Int, editor: PageTextView) -> LineSpan? {
        guard let flow = isFlow(editor) ? flowActions : nil else {
            return LineSpan(manager: editor.layoutManager, container: editor.textContainer, base: 0, length: editor.attributedText.length, isLast: true)
        }
        let segments = flow.segments()
        let lastWritten = segments.lastIndex { !$0.box.text.isEmpty } ?? segments.count - 1
        var base = 0
        for (index, segment) in segments.enumerated() {
            let length = (segment.box.text as NSString).length
            if offset < base + length || index == lastWritten {
                if segment.box.id == editor.objectID, viewIsCurrent(editor) {
                    return LineSpan(manager: editor.layoutManager, container: editor.textContainer, base: base, length: length, isLast: index == lastWritten)
                }
                let layout = TextObjectLayout(segment.box, on: segment.page)
                return LineSpan(manager: layout.manager, container: layout.container, base: base, length: length, isLast: index == lastWritten, layout: layout)
            }
            base += length
        }
        return nil
    }
}
