import UIKit
import NotebookCore

/// `j`/`k` by the lines on screen, over page changes.
@MainActor
private struct DocumentLineLayout: @MainActor TextEngineLayout {
    weak var store: DocumentTextStore?
    var lines: Int
    var visibleLines: Int { lines }
    func verticalTarget(from offset: Int, lines: Int, goal: Double?, in text: NSString) -> (offset: Int, goal: Double) {
        store?.verticalTarget(from: offset, lines: lines, goal: goal)
            ?? LogicalLineLayout().verticalTarget(from: offset, lines: lines, goal: goal, in: text)
    }
}

/// The keyboard mode on the surface: the buffer is the whole text, so there is
/// no hand-off between pages. The engine's selections stay as they are between
/// commands and the surface shows all of them (`refreshOverlay`).
extension DocumentTextSurface: KeyboardTextTarget {
    var keepsTextFocus: Bool { window != nil && isActive }
    func finishByEscape() { finishEditing() }

    /// Undo, taps and typing happen outside the engine: it takes over the buffer.
    @discardableResult
    func keyboardSync() -> Bool {
        KeyboardRouter.shared.engine.sync(text: store.string, selection: selection)
        return true
    }

    func keyboardRun(_ command: TextEngine.Command, count: Int?) {
        keyboardSync()
        let router = KeyboardRouter.shared
        switch command {
        case .paste, .replaceWithRegister: router.adoptPasteboard()
        default: break
        }
        router.engine.layout = DocumentLineLayout(store: store, lines: host?.visibleLines() ?? 40)
        finish(router.engine.perform(command, count: count))
    }
    private func finish(_ outcome: TextEngine.Outcome) {
        let router = KeyboardRouter.shared
        if outcome.yanked { router.exportRegister() }
        if let notice = outcome.notice { router.show(notice) }
        if router.mode == .insert { router.insertBegan(at: router.engine.cursor) }
        router.modeChanged(editor: self)
        if outcome.edits.isEmpty { keyboardShowSelection() } else { applyEngine(outcome) }
    }
    /// The engine's edits as one step: several selections, also over pages.
    func applyEngine(_ outcome: TextEngine.Outcome) {
        let edits = outcome.textEdits(in: host?.flow.content())
        guard !edits.isEmpty else { keyboardShowSelection(); return }
        let before = selection
        inputDelegate?.textWillChange(self)
        store.apply(edits, fallback: typingAttributes)
        adopt(selection: engineSelection)
        inputDelegate?.textDidChange(self)
        commit(edits, style: nil, before: before, separate: true)
        keyboardShowSelection()
    }
    private var engineSelection: NSRange {
        let engine = KeyboardRouter.shared.engine
        return engine.mode == .insert ? NSRange(location: engine.cursor, length: 0) : engine.selectedRange
    }
    func keyboardShowSelection() {
        setSelection(engineSelection, reveal: nil)
        requestCaretReveal(.navigation)
    }

    /// Esc: back one level. False: nothing left, the text ends.
    func keyboardEscape() -> Bool {
        let router = KeyboardRouter.shared
        if router.mode == .insert { syncAfterTyping() } else { keyboardSync() }
        let outcome = router.engine.perform(.escape)
        guard !outcome.leavesText else { return false }
        finish(outcome)
        return true
    }
    /// As on a page's text view: typing behind `i` or `a` goes on as the
    /// selection, after a tap the cursor goes on the last typed character.
    private func syncAfterTyping() {
        let router = KeyboardRouter.shared, text = store.text, current = selection
        if hasSeveralCarets { return }
        if current.length == 0, router.insertRun == current.location {
            router.engine.sync(text: store.string, selection: current)
            return
        }
        var place = current
        let caret = min(current.location, text.length)
        if current.length == 0, caret > 0 {
            let atEnd = caret == text.length || TextLines.isBreak(text.character(at: caret))
            if router.typedSinceInsert || atEnd, !TextLines.isBreak(text.character(at: caret - 1)) {
                place.location = DocumentCaretMotion.previous(text, caret)
            }
        }
        router.engine.sync(text: store.string, selection: place, mode: .insert)
    }
    func keyboardUndo(redo: Bool) {
        host?.undo(redo)
        KeyboardRouter.shared.textChangedElsewhere()
    }
    /// ⌘V outside typing: replaces a marked text, otherwise `P`.
    func keyboardPaste() {
        keyboardSync()
        let router = KeyboardRouter.shared
        keyboardRun(router.engine.primaryIsWide || router.mode == .select ? .replaceWithRegister : .paste(before: true), count: nil)
    }
    /// ⌘X outside typing. False: only a cursor, nothing marked.
    func keyboardCut() -> Bool {
        keyboardSync()
        guard KeyboardRouter.shared.engine.primaryIsWide else { return false }
        keyboardRun(.delete, count: nil)
        return true
    }
    /// ⌘A: the whole text; outside typing as `%`.
    func selectEverything() {
        let router = KeyboardRouter.shared
        if router.isEnabled, router.mode != .insert, hasText { keyboardRun(.selectAll, count: nil); return }
        setSelection(NSRange(location: 0, length: store.storage.length), reveal: nil)
    }

    // MARK: Arrows in INS

    func moveByArrow(_ input: String, flags: UIKeyModifierFlags) {
        let router = KeyboardRouter.shared
        if flags.isEmpty, router.isEnabled, !router.allowsTyping {
            let token = input == UIKeyCommand.inputLeftArrow ? "<Left>" : input == UIKeyCommand.inputRightArrow ? "<Right>"
                : input == UIKeyCommand.inputUpArrow ? "<Up>" : "<Down>"
            router.handle(token: token)
            return
        }
        guard router.allowsTyping else { return }
        let extend = flags.contains(.shift), word = flags.contains(.alternate), edge = flags.contains(.command)
        let vertical = input == UIKeyCommand.inputUpArrow || input == UIKeyCommand.inputDownArrow
        let backward = input == UIKeyCommand.inputLeftArrow || input == UIKeyCommand.inputUpArrow
        let text = store.text
        let anchor = selectionAnchor ?? (backward ? NSMaxRange(selection) : selection.location)
        let head = extend && selection.length > 0 ? (anchor == selection.location ? NSMaxRange(selection) : selection.location)
            : backward ? selection.location : NSMaxRange(selection)
        var target = head
        if edge, vertical { target = backward ? 0 : text.length; verticalGoal = nil }
        else if edge { target = (backward ? store.lineBounds(at: head)?.start : store.lineBounds(at: head)?.end) ?? head; verticalGoal = nil }
        else if vertical {
            let found = store.verticalTarget(from: head, lines: backward ? -1 : 1, goal: verticalGoal, overshoot: true)
            target = found.offset; verticalGoal = found.goal
        } else {
            verticalGoal = nil
            if word { target = backward ? DocumentCaretMotion.wordBackward(text, head) : DocumentCaretMotion.wordForward(text, head) }
            // A selection collapses to its edge first.
            else if extend || selection.length == 0 { target = backward ? DocumentCaretMotion.previous(text, head) : DocumentCaretMotion.next(text, head) }
        }
        let goal = verticalGoal
        if extend {
            setSelection(NSRange(location: min(anchor, target), length: abs(anchor - target)), reveal: nil)
            selectionAnchor = anchor
        } else {
            setSelection(NSRange(location: target, length: 0))
        }
        verticalGoal = goal
    }

    // MARK: Formats

    /// ⌘B and the like: over the selection, otherwise on what is typed next.
    func format(_ id: String) {
        switch id {
        case "bold": restyle { $0.bold.toggle() }
        case "italic": restyle { $0.italic.toggle() }
        case "underline": restyle { $0.underline.toggle() }
        case "strike": restyle { $0.strikethrough = $0.strikethrough == true ? nil : true }
        case "title": restyle(paragraph: true) { TextStylePreset.title.apply(to: &$0) }
        case "heading": restyle(paragraph: true) { TextStylePreset.heading.apply(to: &$0) }
        case "subheading": restyle(paragraph: true) { TextStylePreset.subheading.apply(to: &$0) }
        case "body": restyle(paragraph: true) { TextStylePreset.body.apply(to: &$0) }
        default: break
        }
    }
    private func restyle(paragraph: Bool = false, _ change: (inout TextBoxStyle) -> Void) {
        guard let flow = host?.flow, marked == nil else { return }
        var range = selection
        if paragraph, let whole = flow.paragraph(range) { range = whole }
        if range.length > 0 {
            flow.restyle(range, change)
        } else {
            var style = TextBoxStyle(attributes: typingAttributes, fallback: baseStyle)
            change(&style)
            typingAttributes = style.attributes
        }
    }
}
