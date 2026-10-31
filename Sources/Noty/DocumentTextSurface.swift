import UIKit
import NotebookCore

final class DocumentTextPosition: UITextPosition {
    let offset: Int
    init(_ offset: Int) { self.offset = offset; super.init() }
}

final class DocumentTextRange: UITextRange {
    let range: NSRange
    init(_ range: NSRange) { self.range = range; super.init() }
    override var start: UITextPosition { DocumentTextPosition(range.location) }
    override var end: UITextPosition { DocumentTextPosition(NSMaxRange(range)) }
    override var isEmpty: Bool { range.length == 0 }
}

final class DocumentSelectionRectangle: UITextSelectionRect {
    private let frame: CGRect, start: Bool, end: Bool
    init(_ frame: CGRect, containsStart: Bool, containsEnd: Bool) {
        self.frame = frame; start = containsStart; end = containsEnd; super.init()
    }
    override var rect: CGRect { frame }
    override var writingDirection: NSWritingDirection { .leftToRight }
    override var containsStart: Bool { start }
    override var containsEnd: Bool { end }
    override var isVertical: Bool { false }
}

/// What the surface needs from viewport and model.
struct DocumentTextHost {
    var flow: TextFlowActions
    var undo: (Bool) -> Void
    var undoManager: () -> UndoManager?
    /// The caret stands on this page now: it becomes the selected one, without a jump.
    var selectPage: (UUID) -> Void
    var reveal: () -> Void
    /// Something on the sheet below takes this surface point (a free field).
    var passesThrough: (CGPoint) -> Bool
    /// A checkbox at this surface point was toggled.
    var checkbox: (CGPoint) -> Bool
    var editing: (Bool) -> Void
    /// The user left the text (Esc): back to the previous tool, unless fixed.
    var leave: () -> Void
    var visibleLines: () -> Int
}

/// Text editor 2 (docs/TEXT-EDITOR-2.md): one input view over all pages of a
/// text document, a child of the viewport's zoomed surface, so its coordinates
/// are surface points. Holds no text and decides no geometry: `DocumentTextStore`
/// lays out, Core computes. Only touches of the text tool land here
/// (`point(inside:)`): ink and everything else reach the sheets below.
///
/// Normally UIKit draws caret and selection (`UITextInteraction`). In NOR, SEL
/// and with several carets the engine's selections are the source and this view
/// draws them all: `caretRect`/`selectionRects` then give UIKit nothing to show.
@MainActor
final class DocumentTextSurface: UIView, @preconcurrency UITextInput {
    let store: DocumentTextStore
    var host: DocumentTextHost?
    /// A commit ended; nil: the model refused it.
    var onCommitted: ((TextFlowFocus?) -> Void)?
    var isActive = false {
        didSet {
            guard isActive != oldValue else { return }
            isUserInteractionEnabled = isActive; isAccessibilityElement = isActive
            if !isActive, isFirstResponder { _ = resignFirstResponder() }
        }
    }
    private(set) var selection = NSRange(location: 0, length: 0)
    private(set) var marked: NSRange?
    /// What the marked text replaces, in the text before it began.
    private var markBase: (range: NSRange, selection: NSRange)?
    /// The format of the text before any run (`TextBox.style`).
    var baseStyle = TextBoxStyle()
    var typingAttributes: [NSAttributedString.Key: Any] = [:] {
        didSet { if let font = typingAttributes[.font] as? UIFont { store.typingFont = font } }
    }
    var verticalGoal: Double?
    /// The fixed end of a selection extended with ⇧ arrows.
    var selectionAnchor: Int?
    private var pendingReveal: CaretReveal?
    private var visiblePages: Set<Int> = []
    private let selectionLayer = CAShapeLayer(), cursorLayer = CAShapeLayer(), primaryLayer = CAShapeLayer()
    private let touchWatcher = TouchDownWatcher()
    private var openingOnPurpose = false
    /// NOR and SEL: set by the router.
    var normalCaret = false { didSet { if normalCaret != oldValue { refreshOverlay() } } }

    // MARK: UITextInputTraits, UITextInput state
    var keyboardAppearance: UIKeyboardAppearance = .dark
    var autocapitalizationType: UITextAutocapitalizationType = .sentences
    var autocorrectionType: UITextAutocorrectionType = .default
    var spellCheckingType: UITextSpellCheckingType = .default
    var keyboardType: UIKeyboardType = .default
    var markedTextStyle: [NSAttributedString.Key: Any]?
    weak var inputDelegate: UITextInputDelegate?
    lazy var tokenizer: UITextInputTokenizer = UITextInputStringTokenizer(textInput: self)
    var textInputView: UIView { self }

    init(store: DocumentTextStore) {
        self.store = store
        super.init(frame: .zero)
        backgroundColor = .clear; isOpaque = false; isUserInteractionEnabled = false
        overrideUserInterfaceStyle = .dark
        accessibilityLabel = "Textdokument"
        inputAssistantItem.leadingBarButtonGroups = []; inputAssistantItem.trailingBarButtonGroups = []
        for (shape, alpha) in [(selectionLayer, 0.28), (cursorLayer, 0.45), (primaryLayer, 0.7)] {
            shape.fillColor = UIColor.systemBlue.withAlphaComponent(alpha).cgColor
            shape.actions = ["path": NSNull(), "hidden": NSNull()]
            layer.addSublayer(shape)
        }
        let interaction = UITextInteraction(for: .editable)
        interaction.textInput = self
        addInteraction(interaction)
        // With the text tool the Pencil scrolls the paper, as on `PageTextView`.
        addInteraction(UIScribbleInteraction(delegate: NoScribble.shared))
        addGestureRecognizer(touchWatcher)
        touchWatcher.onEnded = { [weak self] touch in
            guard let self, self.lastTouchEndedAsTap else { return }
            let point = touch.location(in: self), count = touch.tapCount
            self.writeAfterTap()
            DispatchQueue.main.async { [weak self] in self?.caretAfterTap(at: point, tapCount: count) }
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Only the text tool: ink stays with PencilKit, free fields with their
    /// layer. The surface is transparent to everything else.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        guard isActive, bounds.contains(point) else { return false }
        return host?.passesThrough(point) != true
    }

    // MARK: Focus

    /// As `PageTextView`: the caret only after a clean tap or on purpose,
    /// never from a drag, a long press or a held Pencil.
    override var canBecomeFirstResponder: Bool {
        isActive && (isFirstResponder || openingOnPurpose || lastTouchWasCleanTap || UIAccessibility.isVoiceOverRunning)
    }
    override func becomeFirstResponder() -> Bool {
        let wasFirst = isFirstResponder, became = super.becomeFirstResponder()
        if became, !wasFirst {
            KeyboardRouter.shared.textBegan()
            host?.editing(true)
            refreshOverlay(); requestCaretReveal(.navigation)
        }
        return became
    }
    override func resignFirstResponder() -> Bool {
        let wasFirst = isFirstResponder
        unmarkText()
        let resigned = super.resignFirstResponder()
        if resigned, wasFirst {
            KeyboardRouter.shared.textEnded()
            host?.editing(false)
            refreshOverlay()
        }
        return resigned
    }
    func beginEditingOnPurpose() {
        openingOnPurpose = true; defer { openingOnPurpose = false }
        _ = becomeFirstResponder()
    }
    /// Esc or a jump to another page: the text ends.
    func finishEditing() {
        guard isFirstResponder else { return }
        _ = resignFirstResponder()
        host?.leave()
    }
    private var lastTouchEndedAsTap: Bool {
        guard let start = touchWatcher.start, touchWatcher.quiet else { return false }
        let touch = start.touch
        guard touch.phase == .ended else { return false }
        let point = touch.location(in: nil)
        return hypot(point.x - start.point.x, point.y - start.point.y) <= 10
            && (touch.type == .indirectPointer || touch.timestamp - start.time <= 0.5)
    }
    private var lastTouchWasCleanTap: Bool {
        guard lastTouchEndedAsTap, let touch = touchWatcher.start?.touch else { return false }
        return ProcessInfo.processInfo.systemUptime - touch.timestamp <= 0.6
    }
    /// A tap in the text writes, also out of NOR and SEL.
    private func writeAfterTap() {
        guard isFirstResponder, !KeyboardRouter.shared.allowsTyping else { return }
        KeyboardRouter.shared.tappedText(self)
    }
    private func caretAfterTap(at point: CGPoint, tapCount: Int) {
        guard isActive, host?.checkbox(point) != true else { return }
        if isFirstResponder, tapCount > 1 || selection.length > 0 { return }
        setCaret(at: point)
    }
    /// The caret at a surface point; opens the text.
    func setCaret(at point: CGPoint) {
        guard isActive else { return }
        if !isFirstResponder { beginEditingOnPurpose() }
        guard marked == nil else { return }
        setSelection(NSRange(location: store.offset(closestTo: Self.point(point), in: store.frames), length: 0))
    }
    /// A focus of the model (undo, outline, end of the flow). False: not the flow's.
    func show(_ focus: TextFlowFocus) -> Bool {
        guard let start = host?.flow.offset(focus.boxID, focus.selection.location) else { return false }
        if !isFirstResponder { beginEditingOnPurpose() }
        guard marked == nil else { return true }
        setSelection(NSRange(location: start, length: focus.selection.length))
        typingAttributes = focus.typingStyle.resolvingAutomaticColor(light: lightText).attributes
        if TextFlowSelection.shared.selectAllWhenFocused {
            TextFlowSelection.shared.selectAllWhenFocused = false
            let router = KeyboardRouter.shared
            if router.isEnabled, router.mode == .insert, store.storage.length > 0 { router.setMode(.normal, editor: self) }
            selectEverything()
        }
        return true
    }
    var lightText = false

    /// The model has a new text for the buffer.
    func replacingAllText(_ load: () -> Void) {
        inputDelegate?.textWillChange(self); inputDelegate?.selectionWillChange(self)
        load()
        selection = clamped(selection)
        inputDelegate?.selectionDidChange(self); inputDelegate?.textDidChange(self)
        typingAttributes = store.attributes(at: selection.location) ?? baseStyle.resolvingAutomaticColor(light: lightText).attributes
        refreshOverlay()
    }
    /// The model's text moved the caret (a renumbered list).
    func adopt(selection range: NSRange) { selection = clamped(range); refreshOverlay() }

    // MARK: Selection

    private func clamped(_ range: NSRange) -> NSRange {
        let length = store.storage.length, start = min(max(0, range.location), length)
        return NSRange(location: start, length: min(max(0, range.length), length - start))
    }
    /// `system`: UIKit asked for it (`inputDelegate` is not told then).
    func setSelection(_ range: NSRange, system: Bool = false, reveal: CaretReveal? = .navigation) {
        let next = clamped(range), changed = next != selection
        if !system, changed { inputDelegate?.selectionWillChange(self) }
        selection = next
        if !system, changed { inputDelegate?.selectionDidChange(self) }
        if next.length == 0 {
            selectionAnchor = nil
            if let attributes = store.attributes(at: next.location) { typingAttributes = attributes }
        }
        // A finger moved the selection in NOR: the engine takes it over.
        if system, overlayOwnsSelection { _ = keyboardSync() }
        refreshOverlay()
        reportPage()
        if let reveal, next.length == 0 { requestCaretReveal(reveal) }
    }
    func reportPage() {
        if let slot = store.slot(of: caretOffset) { host?.selectPage(slot.pageID) }
    }
    /// Where the caret to keep in view stands.
    private var caretOffset: Int {
        overlayOwnsSelection ? KeyboardRouter.shared.engine.cursor : NSMaxRange(selection)
    }
    /// The engine's selections are on screen, not UIKit's.
    private var overlayOwnsSelection: Bool {
        let router = KeyboardRouter.shared
        return normalCaret || (router.editing && router.mode == .insert && router.engine.selections.count > 1)
    }
    var hasSeveralCarets: Bool {
        let router = KeyboardRouter.shared
        return router.editing && router.mode == .insert && router.engine.selections.count > 1
    }

    // MARK: Caret reveal

    func requestCaretReveal(_ kind: CaretReveal) {
        var kind = kind
        if kind == .typing, TextObjectLayer.typewriterEnabled, selection.length == 0 { kind = .typewriter }
        pendingReveal = max(pendingReveal ?? kind, kind)
        host?.reveal()
    }
    func takeCaretReveal() -> CaretReveal? {
        defer { pendingReveal = nil }
        return pendingReveal
    }
    /// The caret on the surface while the text is being edited.
    var editingCaret: CGRect? { isFirstResponder ? surfaceCaret(at: caretOffset) : nil }

    private func band(at offset: Int) -> (ascent: Double, descent: Double)? {
        let attributes = selection == NSRange(location: offset, length: 0) ? typingAttributes : store.attributes(at: offset) ?? typingAttributes
        guard let font = attributes[.font] as? UIFont else { return nil }
        return (Double(font.ascender), Double(-font.descender))
    }
    private func surfaceCaret(at offset: Int, width: Double = 2) -> CGRect? {
        guard let caret = store.caret(at: offset, band: band(at: offset), width: width), let frame = frame(ofPage: caret.page) else { return nil }
        return frame.surface(caret.rect).cgRect
    }
    private func frame(ofPage page: Int) -> DocumentPageFrame? {
        store.slots.indices.contains(page) ? store.slots[page].frame : nil
    }
    private static func point(_ point: CGPoint) -> PagePoint { PagePoint(x: Double(point.x), y: Double(point.y)) }

    // MARK: Drawing the engine's selections

    func setVisible(_ rect: CGRect) {
        let pages = Set(store.frames.filter { $0.sheet.cgRect.intersects(rect) }.map(\.page))
        guard pages != visiblePages else { return }
        visiblePages = pages
        if overlayOwnsSelection { refreshOverlay() }
    }
    func refreshOverlay() {
        let marks = CGMutablePath(), cursors = CGMutablePath(), primary = CGMutablePath()
        if isFirstResponder, overlayOwnsSelection {
            let router = KeyboardRouter.shared
            for item in router.engine.shownSelections {
                if item.isWide {
                    for part in store.selectionRects(item.range, pages: visiblePages) {
                        if let frame = frame(ofPage: part.page) { marks.addRect(frame.surface(part.rect).cgRect) }
                    }
                }
                let text = store.text
                var width = 2.0
                if router.mode != .insert, let line = store.line(at: item.cursor) {
                    // The block cursor: over its character, half a line wide on an empty place.
                    let next = DocumentCaretMotion.next(text, item.cursor)
                    width = next > item.cursor && next <= line.end ? store.x(of: next, on: line) - store.x(of: item.cursor, on: line) : 0
                    if width < 1 { width = line.bandHeight * 0.5 }
                }
                if let rect = surfaceCaret(at: item.cursor, width: width) { (item.isPrimary ? primary : cursors).addRect(rect) }
            }
        }
        selectionLayer.path = marks; cursorLayer.path = cursors; primaryLayer.path = primary
    }

    // MARK: UIKeyInput

    var hasText: Bool { store.storage.length > 0 }

    func insertText(_ text: String) {
        guard isActive, KeyboardRouter.shared.allowsTyping else { return }
        if hasSeveralCarets { applyEngine(KeyboardRouter.shared.engine.insertText(text)); return }
        if let marked { replaceMarked(marked, with: text); return }
        if text == "\n", let edit = TextListEditing.newline(in: store.string, range: selection) {
            let before = selection
            type(edit.replacement, over: edit.range, before: before, separate: true)
            return
        }
        type(text, over: selection, before: selection)
        if text == " " { finishAutomaticList() }
    }
    func deleteBackward() {
        guard isActive, KeyboardRouter.shared.allowsTyping else { return }
        if hasSeveralCarets { applyEngine(KeyboardRouter.shared.engine.deleteBackward()); return }
        if selection.length > 0 { type("", over: selection, before: selection); return }
        guard selection.location > 0 else { return }
        let start = (store.string as NSString).rangeOfComposedCharacterSequence(at: selection.location - 1).location
        type("", over: NSRange(location: start, length: selection.location - start), before: selection)
    }
    /// One edit at the caret: the buffer first, then the model behind it.
    private func type(_ text: String, over range: NSRange, before: NSRange, separate: Bool = false) {
        store.replace(range, with: NSAttributedString(string: text, attributes: typingAttributes))
        selection = NSRange(location: range.location + (text as NSString).length, length: 0)
        verticalGoal = nil; selectionAnchor = nil
        commit([TextListEditing.Edit(range: range, replacement: text)], style: typingStyle, before: before, separate: separate)
        afterTyping()
    }
    private var typingStyle: TextBoxStyle { TextBoxStyle(attributes: typingAttributes, fallback: baseStyle) }
    private func afterTyping() {
        refreshOverlay()
        reportPage()
        requestCaretReveal(.typing)
        let router = KeyboardRouter.shared
        if router.isEnabled, router.keyboardSeen, router.mode == .insert { router.typed(caret: selection.location) }
    }
    /// "- ", "1. " … at a paragraph start become a list, a step of its own.
    private func finishAutomaticList() {
        let text = store.string, caret = selection.location
        let level = (typingAttributes[.paragraphStyle] as? NSParagraphStyle).map { TextListEditing.level(forIndent: Double($0.headIndent)) } ?? 0
        guard let edit = TextListEditing.autoList(in: text, caret: caret, level: level) else { return }
        let before = selection, after = TextListEditing.selection(selection, after: [edit])
        store.apply([edit], fallback: typingAttributes)
        selection = after
        commit([edit], style: nil, before: before, separate: true)
    }
    /// The buffer changed by `edits`, the selection is already the new one.
    func commit(_ edits: [TextListEditing.Edit], style: TextBoxStyle?, before: NSRange, separate: Bool) {
        guard let change = host?.flow.change else { onCommitted?(nil); return }
        let store = self.store
        // Only where the caret goes: the selection itself stays with the surface.
        let caret = NSRange(location: selection.location, length: 0)
        let focus = change(TextFlowChange(edits: edits, style: style, selection: caret, selectionBefore: before, separateStep: separate)) { page, box in
            store.capacity(page: page, box: box)
        }
        onCommitted?(focus)
    }

    // MARK: Marked text

    var markedTextRange: UITextRange? { marked.map(DocumentTextRange.init) }
    func setMarkedText(_ markedText: String?, selectedRange: NSRange) {
        guard isActive, KeyboardRouter.shared.allowsTyping else { return }
        let value = markedText ?? "", target = marked ?? selection
        if markBase == nil { markBase = (selection, selection) }
        var attributes = typingAttributes
        attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
        store.replace(target, with: NSAttributedString(string: value, attributes: attributes))
        let length = (value as NSString).length
        marked = NSRange(location: target.location, length: length)
        selection = NSRange(location: target.location + min(selectedRange.location, length), length: min(selectedRange.length, length))
        if length == 0 { unmarkText() } else { requestCaretReveal(.typing) }
    }
    func unmarkText() {
        guard let range = marked, let base = markBase else { return }
        marked = nil; markBase = nil
        store.setAttributes(typingAttributes, range: range)
        let text = (store.string as NSString).substring(with: range)
        selection = NSRange(location: NSMaxRange(range), length: 0)
        commit([TextListEditing.Edit(range: base.range, replacement: text)], style: typingStyle, before: base.selection, separate: false)
        afterTyping()
    }
    /// `insertText` while text is marked: the final text replaces it.
    private func replaceMarked(_ range: NSRange, with text: String) {
        guard let base = markBase else { return }
        marked = nil; markBase = nil
        store.replace(range, with: NSAttributedString(string: text, attributes: typingAttributes))
        selection = NSRange(location: range.location + (text as NSString).length, length: 0)
        commit([TextListEditing.Edit(range: base.range, replacement: text)], style: typingStyle, before: base.selection, separate: false)
        afterTyping()
    }

    // MARK: UITextInput: text

    func text(in range: UITextRange) -> String? {
        guard let range = (range as? DocumentTextRange)?.range else { return nil }
        return (store.string as NSString).substring(with: clamped(range))
    }
    func replace(_ range: UITextRange, withText text: String) {
        guard isActive, KeyboardRouter.shared.allowsTyping, let target = (range as? DocumentTextRange)?.range else { return }
        let edited = clamped(target), before = selection
        let attributes = edited.length > 0 ? store.storage.attributes(at: edited.location, effectiveRange: nil) : typingAttributes
        store.replace(edited, with: NSAttributedString(string: text, attributes: attributes))
        selection = clamped(DocumentCaretMotion.selection(before, replacing: edited, length: (text as NSString).length))
        commit([TextListEditing.Edit(range: edited, replacement: text)],
               style: TextBoxStyle(attributes: attributes, fallback: baseStyle), before: before, separate: false)
        afterTyping()
    }
    var selectedTextRange: UITextRange? {
        get { DocumentTextRange(selection) }
        set {
            guard let range = (newValue as? DocumentTextRange)?.range else { return }
            verticalGoal = nil
            setSelection(range, system: true)
        }
    }

    // MARK: UITextInput: positions

    private func offset(_ position: UITextPosition) -> Int { (position as? DocumentTextPosition)?.offset ?? 0 }
    var beginningOfDocument: UITextPosition { DocumentTextPosition(0) }
    var endOfDocument: UITextPosition { DocumentTextPosition(store.storage.length) }
    func textRange(from fromPosition: UITextPosition, to toPosition: UITextPosition) -> UITextRange? {
        let a = offset(fromPosition), b = offset(toPosition)
        return DocumentTextRange(clamped(NSRange(location: min(a, b), length: abs(a - b))))
    }
    func position(from position: UITextPosition, offset delta: Int) -> UITextPosition? {
        let target = offset(position) + delta
        return (0...store.storage.length).contains(target) ? DocumentTextPosition(target) : nil
    }
    func position(from position: UITextPosition, in direction: UITextLayoutDirection, offset delta: Int) -> UITextPosition? {
        var current = offset(position)
        let text = store.text
        switch direction {
        case .left: for _ in 0..<delta { current = DocumentCaretMotion.previous(text, current) }
        case .right: for _ in 0..<delta { current = DocumentCaretMotion.next(text, current) }
        case .up: current = store.verticalTarget(from: current, lines: -delta, goal: nil).offset
        case .down: current = store.verticalTarget(from: current, lines: delta, goal: nil).offset
        @unknown default: return nil
        }
        return DocumentTextPosition(current)
    }
    func compare(_ position: UITextPosition, to other: UITextPosition) -> ComparisonResult {
        let a = offset(position), b = offset(other)
        return a < b ? .orderedAscending : a > b ? .orderedDescending : .orderedSame
    }
    func offset(from: UITextPosition, to toPosition: UITextPosition) -> Int { offset(toPosition) - offset(from) }
    func position(within range: UITextRange, farthestIn direction: UITextLayoutDirection) -> UITextPosition? {
        direction == .left || direction == .up ? range.start : range.end
    }
    func characterRange(byExtending position: UITextPosition, in direction: UITextLayoutDirection) -> UITextRange? {
        let place = offset(position)
        guard let line = store.lineBounds(at: place) else { return DocumentTextRange(NSRange(location: place, length: 0)) }
        switch direction {
        case .left, .up: return DocumentTextRange(NSRange(location: line.start, length: place - line.start))
        default: return DocumentTextRange(NSRange(location: place, length: max(0, line.end - place)))
        }
    }
    func baseWritingDirection(for position: UITextPosition, in direction: UITextStorageDirection) -> NSWritingDirection { .leftToRight }
    func setBaseWritingDirection(_ writingDirection: NSWritingDirection, for range: UITextRange) {}

    // MARK: UITextInput: geometry

    func firstRect(for range: UITextRange) -> CGRect {
        guard let range = (range as? DocumentTextRange)?.range else { return .zero }
        if let first = store.selectionRects(range, pages: []).first, let frame = frame(ofPage: first.page) {
            return frame.surface(first.rect).cgRect
        }
        return surfaceCaret(at: range.location) ?? .zero
    }
    func caretRect(for position: UITextPosition) -> CGRect {
        let rect = surfaceCaret(at: offset(position)) ?? .zero
        // The surface draws the block cursors: nothing for UIKit to show.
        return overlayOwnsSelection ? CGRect(x: rect.minX, y: rect.minY, width: 0, height: 0) : rect
    }
    func selectionRects(for range: UITextRange) -> [UITextSelectionRect] {
        guard !overlayOwnsSelection, let range = (range as? DocumentTextRange)?.range else { return [] }
        return store.selectionRects(range, pages: visiblePages).compactMap { part in
            frame(ofPage: part.page).map { DocumentSelectionRectangle($0.surface(part.rect).cgRect, containsStart: part.containsStart, containsEnd: part.containsEnd) }
        }
    }
    func closestPosition(to point: CGPoint) -> UITextPosition? {
        DocumentTextPosition(store.offset(closestTo: Self.point(point), in: store.frames))
    }
    func closestPosition(to point: CGPoint, within range: UITextRange) -> UITextPosition? {
        guard let range = (range as? DocumentTextRange)?.range else { return nil }
        return DocumentTextPosition(min(max(store.offset(closestTo: Self.point(point), in: store.frames), range.location), NSMaxRange(range)))
    }
    func characterRange(at point: CGPoint) -> UITextRange? {
        let place = store.offset(closestTo: Self.point(point), in: store.frames), text = store.text
        guard place < text.length else { return nil }
        return DocumentTextRange(text.rangeOfComposedCharacterSequence(at: place))
    }

    // MARK: Hardware keys

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if !KeyboardRouter.shared.handle(presses, text: self) { super.pressesBegan(presses, with: event) }
    }
    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if !KeyboardRouter.shared.pressEnded(presses) { super.pressesEnded(presses, with: event) }
    }
    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if !KeyboardRouter.shared.pressEnded(presses) { super.pressesCancelled(presses, with: event) }
    }
    override var undoManager: UndoManager? { host?.undoManager() }
    override var keyCommands: [UIKeyCommand]? {
        (super.keyCommands ?? []) + Self.textCommands + (marked == nil ? Self.arrowCommands : [])
    }
    private static let textCommands: [UIKeyCommand] = {
        let plain: [(String, UIKeyModifierFlags, Selector)] = [
            ("z", .command, #selector(undoKey)), ("z", [.command, .shift], #selector(redoKey)),
            (UIKeyCommand.inputEscape, [], #selector(escapeKey)), ("a", .command, #selector(selectAllKey))]
        let formats: [(String, String, UIKeyModifierFlags, String)] = [
            ("Fett", "b", .command, "bold"), ("Kursiv", "i", .command, "italic"), ("Unterstrichen", "u", .command, "underline"),
            ("Titel", "1", .command, "title"), ("Überschrift", "2", .command, "heading"), ("Unterüberschrift", "3", .command, "subheading"),
            ("Text", "4", .command, "body"), ("Durchstreichen", "x", [.command, .shift], "strike")]
        return plain.map { input, flags, action in
            let command = UIKeyCommand(input: input, modifierFlags: flags, action: action)
            command.wantsPriorityOverSystemBehavior = true
            return command
        } + formats.map { title, input, flags, id in
            let command = UIKeyCommand(title: title, action: #selector(formatKey(_:)), input: input, modifierFlags: flags, propertyList: id)
            command.wantsPriorityOverSystemBehavior = true
            return command
        }
    }()
    /// Key commands repeat while held and win over UIKit's own arrow handling,
    /// which would stop at nothing here but knows no goal column over pages.
    private static let arrowCommands: [UIKeyCommand] = {
        let inputs = [UIKeyCommand.inputLeftArrow, UIKeyCommand.inputRightArrow, UIKeyCommand.inputUpArrow, UIKeyCommand.inputDownArrow]
        let flags: [UIKeyModifierFlags] = [[], .shift, .alternate, [.alternate, .shift], .command, [.command, .shift]]
        return inputs.flatMap { input in flags.map { flag in
            let command = UIKeyCommand(input: input, modifierFlags: flag, action: #selector(arrowKey(_:)))
            command.wantsPriorityOverSystemBehavior = true
            return command
        } }
    }()
    @objc private func undoKey() { host?.undo(false) }
    @objc private func redoKey() { host?.undo(true) }
    @objc private func escapeKey() { if !KeyboardRouter.shared.escape(in: self) { finishEditing() } }
    @objc private func selectAllKey() { selectEverything() }
    @objc private func formatKey(_ command: UIKeyCommand) { (command.propertyList as? String).map(format) }
    @objc private func arrowKey(_ command: UIKeyCommand) {
        guard let input = command.input else { return }
        moveByArrow(input, flags: command.modifierFlags)
    }

    // MARK: Edit menu

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        switch action {
        case #selector(copy(_:)), #selector(cut(_:)): selection.length > 0
        case #selector(paste(_:)): UIPasteboard.general.hasStrings
        case #selector(selectAll(_:)): hasText
        default: super.canPerformAction(action, withSender: sender)
        }
    }
    override func copy(_ sender: Any?) {
        guard selection.length > 0 else { return }
        UIPasteboard.general.string = (store.string as NSString).substring(with: selection)
    }
    override func cut(_ sender: Any?) {
        if !KeyboardRouter.shared.allowsTyping { if keyboardCut() { return } }
        copy(sender)
        if selection.length > 0 { type("", over: selection, before: selection, separate: true) }
    }
    override func paste(_ sender: Any?) {
        let router = KeyboardRouter.shared
        if router.textPrompt != nil {
            if let text = UIPasteboard.general.string { router.pasteIntoPrompt(text, editor: self) }
            return
        }
        if !router.allowsTyping { keyboardPaste(); return }
        guard let text = UIPasteboard.general.string else { return }
        type(text, over: selection, before: selection, separate: true)
    }
    override func selectAll(_ sender: Any?) { selectEverything() }
}
