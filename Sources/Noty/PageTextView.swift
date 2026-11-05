import UIKit
import NotebookCore

@MainActor
final class PageTextView: UITextView {
    private let ruling = RuledTextLayout()
    /// The lines this field's text stands on (`TextLinePaper.grid(for:)`); nil: free layout.
    var lineGrid: TextLineGrid? { ruling.grid }
    func setLineGrid(_ grid: TextLineGrid?) {
        guard ruling.grid != grid else { return }
        ruling.grid = grid
        layoutManager.invalidateLayout(forCharacterRange: NSRange(location: 0, length: textStorage.length), actualCharacterRange: nil)
        (layoutManager as? TaskLayoutManager)?.onDisplayChange?()
    }
    /// The zoomed raster draws the text; the native view only when no
    /// viewport is known yet. Switching redraws the native layer once.
    var drawsNatively = true {
        didSet {
            guard drawsNatively != oldValue, let manager = layoutManager as? TaskLayoutManager else { return }
            manager.drawsNatively = drawsNatively
            manager.invalidateDisplay(forCharacterRange: NSRange(location: 0, length: textStorage.length))
            setNeedsDisplay(); subviews.forEach { $0.setNeedsDisplay() }
        }
    }
    /// A laid-out line's glyphs (with a little reach) are at this point.
    func hitsText(at point: CGPoint) -> Bool {
        let manager = layoutManager, inset = textContainerInset
        manager.ensureLayout(for: textContainer)
        guard manager.numberOfGlyphs > 0 else { return false }
        let local = CGPoint(x: point.x - inset.left, y: point.y - inset.top)
        let glyph = manager.glyphIndex(for: local, in: textContainer)
        var line = NSRange()
        let fragment = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &line)
        guard local.y >= fragment.minY, local.y <= fragment.maxY else { return false }
        let text = textStorage.string as NSString
        var characters = manager.characterRange(forGlyphRange: line, actualGlyphRange: nil)
        while characters.length > 0, let scalar = UnicodeScalar(text.character(at: NSMaxRange(characters) - 1)),
              CharacterSet.whitespacesAndNewlines.contains(scalar) { characters.length -= 1 }
        guard characters.length > 0 else { return false }
        let used = manager.boundingRect(forGlyphRange: manager.glyphRange(forCharacterRange: characters, actualCharacterRange: nil), in: textContainer)
        return local.x >= used.minX - 16 && local.x <= used.maxX + 16
    }
    /// A laid-out text line (its used glyph area, widened by `slack`) is at
    /// `point` (own coordinates). Empty lines count as no text. An empty field
    /// is hit inside its frame only while being edited: stored empty fields
    /// exist (a field saved before leaving it, former page text with a frame
    /// as large as its writing area), and they would invisibly catch every
    /// touch on what lies below them.
    func hitsLine(at point: CGPoint, slack: CGFloat) -> Bool {
        let manager = layoutManager, inset = textContainerInset
        manager.ensureLayout(for: textContainer)
        guard manager.numberOfGlyphs > 0 else { return isFirstResponder && bounds.insetBy(dx: -slack, dy: -slack).contains(point) }
        let local = CGPoint(x: point.x - inset.left, y: point.y - inset.top)
        var hit = false
        manager.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: manager.numberOfGlyphs)) { _, used, _, _, stop in
            if used.width > 0.5, used.insetBy(dx: -slack, dy: -slack).contains(local) { hit = true; stop.pointee = true }
        }
        return hit
    }
    /// Text tool on page/margin text: from the middle rightwards, a tap beside
    /// or below the text belongs to a new free field, not to these lines.
    func opensFreeField(at point: CGPoint) -> Bool {
        guard isFlow, isEditable, markedTextRange == nil, bounds.contains(point) else { return false }
        return TextPlacement.opensFreeField(tapX: Double(point.x), regionWidth: Double(bounds.width), hitsText: hitsText(at: point))
    }
    /// Click-and-type: a caret shown on a line below the text; its empty
    /// lines are only written with the first typed character.
    var placement: CaretPlacement? { didSet { if placement != oldValue { refreshCaret() } } }
    var onMaterializePlacement: ((CaretPlacement) -> Void)?
    var onListTab: ((Bool) -> Bool)?
    private func refreshCaret() {
        guard isFirstResponder, let range = selectedTextRange else { return }
        let delegate = self.delegate; self.delegate = nil
        selectedTextRange = nil; selectedTextRange = range
        self.delegate = delegate
    }
    private func materializePlacement() {
        guard let pending = placement else { return }
        placement = nil
        if selectedRange == NSRange(location: pending.location, length: 0), markedTextRange == nil { onMaterializePlacement?(pending) }
    }
    override func insertText(_ text: String) { materializePlacement(); super.insertText(text) }
    override func setMarkedText(_ markedText: String?, selectedRange: NSRange) {
        materializePlacement(); super.setMarkedText(markedText, selectedRange: selectedRange)
    }
    override func paste(_ sender: Any?) {
        // The input line takes it; outside typing the text view itself takes no text.
        if KeyboardRouter.shared.textPrompt != nil {
            if let text = UIPasteboard.general.string { KeyboardRouter.shared.pasteIntoPrompt(text, editor: self) }
            return
        }
        if !KeyboardRouter.shared.allowsTyping { historyOwner?.keyboardPaste(self); return }
        if let text = UIPasteboard.general.string, historyOwner?.replaceFlowSelection(with: text) == true { return }
        materializePlacement(); super.paste(sender)
    }
    override func copy(_ sender: Any?) {
        if let text = historyOwner?.flowSelectionText { UIPasteboard.general.string = text } else { super.copy(sender) }
    }
    override func cut(_ sender: Any?) {
        if !KeyboardRouter.shared.allowsTyping, historyOwner?.keyboardCut(self) == true { return }
        if let text = historyOwner?.flowSelectionText {
            UIPasteboard.general.string = text
            _ = historyOwner?.replaceFlowSelection(with: "")
        } else { super.cut(sender) }
    }
    /// ⌘A: the whole text document, not only this page's part of it. The
    /// edit menu's „Alles auswählen“ keeps the native selection with its handles.
    func selectEverything() {
        if historyOwner?.keyboardSelectAll(self) == true || historyOwner?.selectWholeFlow() == true { return }
        selectAll(nil)
    }
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if TextFlowSelection.shared.range != nil, [#selector(copy(_:)), #selector(cut(_:)), #selector(paste(_:))].contains(action) { return true }
        return super.canPerformAction(action, withSender: sender)
    }
    // MARK: Keyboard mode
    /// NOR and SEL: a wide caret on the character (the block cursor).
    var normalCaret = false { didSet { if normalCaret != oldValue { refreshCaret() } } }
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if !KeyboardRouter.shared.handle(presses, text: self) { super.pressesBegan(presses, with: event) }
    }
    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if !KeyboardRouter.shared.pressEnded(presses) { super.pressesEnded(presses, with: event) }
    }
    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if !KeyboardRouter.shared.pressEnded(presses) { super.pressesCancelled(presses, with: event) }
    }
    func finishByEscape() { onEscape?() }
    /// TextKit spans caret/selection over the whole line fragment, which on ruled
    /// paper includes the gap up to the previous line. Use the glyph band instead.
    override func caretRect(for position: UITextPosition) -> CGRect {
        var rect = textCaretRect(for: position)
        if normalCaret { rect.size.width = max(rect.width, rect.height * 0.5) }
        return rect
    }
    private func textCaretRect(for position: UITextPosition) -> CGRect {
        if let placement, selectedRange == NSRange(location: placement.location, length: 0),
           offset(from: beginningOfDocument, to: position) == placement.location { return placement.caret }
        let rect = super.caretRect(for: position)
        guard rect.minY.isFinite, rect.height.isFinite, rect.height > 0 else { return rect }
        let index = offset(from: beginningOfDocument, to: position)
        guard let band = glyphBand(near: rect, caretIndex: index) else { return rect }
        return CGRect(x: rect.minX, y: band.minY, width: rect.width, height: band.height)
    }
    override func selectionRects(for range: UITextRange) -> [UITextSelectionRect] {
        super.selectionRects(for: range).flatMap { item -> [UITextSelectionRect] in
            guard item.rect.minY.isFinite, item.rect.height > 0 else { return [item] }
            let bands = glyphBands(in: item.rect)
            guard let first = bands.first, let last = bands.last else { return [item] }
            return bands.map { band in
                GlyphSelectionRect(item, rect: CGRect(x: item.rect.minX, y: band.minY, width: item.rect.width, height: band.height),
                                   start: item.containsStart && band == first, end: item.containsEnd && band == last)
            }
        }
    }
    /// UIKit reports all lines between the first and the last selected one as
    /// a single rectangle: one glyph band per line inside it, or only the
    /// line at its middle would stay marked.
    private func glyphBands(in rect: CGRect) -> [CGRect] {
        let manager = layoutManager, top = textContainerInset.top
        var middles: [CGFloat] = []
        manager.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: manager.numberOfGlyphs)) { fragment, _, _, _, _ in
            let middle = fragment.midY + top
            if middle > rect.minY, middle < rect.maxY { middles.append(middle) }
        }
        guard middles.count > 1 else { return glyphBand(near: rect, caretIndex: nil).map { [$0] } ?? [] }
        return middles.compactMap { glyphBand(near: CGRect(x: rect.minX, y: $0, width: rect.width, height: 0), caretIndex: nil) }
    }
    private static func isBreak(_ c: unichar) -> Bool { c == 10 || c == 13 || c == 0x2028 || c == 0x2029 }
    private func caretFont(at index: Int) -> UIFont {
        let text = textStorage.string as NSString, length = text.length
        func stored(_ i: Int) -> UIFont? { textStorage.attribute(.font, at: i, effectiveRange: nil) as? UIFont }
        if selectedRange.length == 0, index == selectedRange.location, let typed = typingAttributes[.font] as? UIFont { return typed }
        if index > 0, index <= length, !Self.isBreak(text.character(at: index - 1)), let value = stored(index - 1) { return value }
        if index < length, let value = stored(index) { return value }
        return typingAttributes[.font] as? UIFont ?? font ?? .systemFont(ofSize: 14)
    }
    /// Ascender…descender around the line's baseline (incl. the ruling lift), in view coordinates.
    private func glyphBand(near rect: CGRect, caretIndex: Int?) -> CGRect? {
        let manager = layoutManager, inset = textContainerInset
        let text = textStorage.string as NSString, length = text.length
        let baseline: CGFloat
        var fonts: [UIFont] = caretIndex.map { [caretFont(at: $0)] } ?? []
        if let index = caretIndex, index >= length, length == 0 || Self.isBreak(text.character(at: length - 1)) {
            // Empty trailing line: not laid out as glyphs; place where typed text will land.
            let extra = manager.extraLineFragmentRect
            guard let font = fonts.first, length == 0 || extra.height > 0 else { return nil }
            baseline = ruling.baseline(top: extra.minY, ascent: font.ascender) ?? extra.minY + font.ascender
        } else {
            guard manager.numberOfGlyphs > 0 else { return nil }
            let point = CGPoint(x: rect.midX - inset.left, y: rect.midY - inset.top)
            let glyph = manager.glyphIndex(for: point, in: textContainer)
            var line = NSRange()
            let fragment = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &line)
            guard fragment.height > 0, point.y >= fragment.minY - 1, point.y <= fragment.maxY + 1 else { return nil }
            let characters = manager.characterRange(forGlyphRange: line, actualGlyphRange: nil)
            var reference = glyph
            textStorage.enumerateAttribute(.baselineOffset, in: characters) { value, range, stop in
                guard ((value as? NSNumber)?.doubleValue ?? 0) == 0 else { return }
                reference = manager.glyphIndexForCharacter(at: range.location); stop.pointee = true
            }
            baseline = fragment.minY + manager.location(forGlyphAt: reference).y
            if caretIndex == nil {
                textStorage.enumerateAttribute(.font, in: characters) { value, _, _ in if let value = value as? UIFont { fonts.append(value) } }
            }
        }
        if fonts.isEmpty { fonts = [typingAttributes[.font] as? UIFont ?? .systemFont(ofSize: 14)] }
        let ascent = fonts.map(\.ascender).max() ?? 0, descent = fonts.map { -$0.descender }.max() ?? 0
        guard ascent > 0, baseline.isFinite else { return nil }
        return CGRect(x: 0, y: inset.top + baseline - ascent, width: 0, height: ascent + max(0, descent))
    }
    let objectID: UUID
    weak var historyOwner: TextObjectLayer?
    var onEscape: (() -> Void)?
    var onBold: (() -> Void)?
    var onItalic: (() -> Void)?
    var onUnderline: (() -> Void)?
    var onShortcut: ((String) -> Void)?
    var onFlowUndo: ((Bool) -> Void)?
    var onFlowBackspace: (() -> Void)?
    var isFlow = false
    var typedSpace = false
    override func scrollRangeToVisible(_ range: NSRange) { /* Outer viewport owns caret reveal. */ }
    override func scrollRectToVisible(_ rect: CGRect, animated: Bool) { }
    override func deleteBackward() {
        if placement != nil { placement = nil; return }
        if historyOwner?.replaceFlowSelection(with: "") == true { return }
        if isFlow, selectedRange.location == 0, selectedRange.length == 0 { onFlowBackspace?() }
        else if selectedRange == NSRange(location: 0, length: 0), historyOwner?.backspaceAtStart(self) == true { return }
        else { super.deleteBackward() }
    }
    init(id: UUID) {
        objectID = id
        let storage = NSTextStorage(), manager = TaskLayoutManager()
        let container = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true; container.heightTracksTextView = false
        storage.addLayoutManager(manager); manager.addTextContainer(container)
        super.init(frame: .zero, textContainer: container)
        manager.delegate = ruling
        // noty calculates itself (`TextCalculator`).
        if #available(iOS 18.0, *) { mathExpressionCompletionType = .no }
        // With the text tool the Pencil scrolls the paper; handwriting-to-text
        // (Scribble) would turn every Pencil drag over text into writing.
        addInteraction(UIScribbleInteraction(delegate: NoScribble.shared))
        addGestureRecognizer(touchWatcher)
        touchWatcher.onEnded = { [weak self] touch in
            guard let self, self.lastTouchEndedAsTap else { return }
            self.writeAfterTap()
            self.onCleanTap?(touch.location(in: self), touch.tapCount)
        }
    }
    /// A tap in the text writes, also with the keyboard gone (no Esc then).
    func writeAfterTap() {
        guard isFirstResponder, !KeyboardRouter.shared.allowsTyping else { return }
        TextFlowSelection.shared.set(nil)
        KeyboardRouter.shared.tappedText(self)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    /// Feedback zu Build 62: „Der Cursor sollte erst reingehen, wenn man
    /// einmal normal gedrückt hat.“ The text view's own gestures (long press,
    /// drag, loupe, double tap held) may only open it after a clean tap: put
    /// down and lifted within 0.5 s, at most 10 screen points apart, just now.
    /// Code paths that open a field on purpose (new field by tap, „Bearbeiten“,
    /// second tap on a selected field, flow hand-off) set `openingOnPurpose`.
    /// UIKit starts a pointer click on touch-down, before it can be clean, and
    /// places a finger's caret at word ends: every clean tap ends in
    /// `onCleanTap`, which opens the field and sets the caret at the tap.
    private let touchWatcher = TouchDownWatcher()
    var openingOnPurpose = false
    /// A clean tap ended at this point (own coordinates) with this tap count.
    var onCleanTap: ((CGPoint, Int) -> Void)?
    /// Held clicks are no accident: the time limit is for fingers and the Pencil.
    private var lastTouchEndedAsTap: Bool {
        guard let start = touchWatcher.start, touchWatcher.quiet else { return false }
        let touch = start.touch
        guard touch.phase == .ended else { return false }
        let point = touch.location(in: nil)
        return hypot(point.x - start.point.x, point.y - start.point.y) <= 10
            && (touch.type == .indirectPointer || touch.timestamp - start.time <= 0.5)
    }
    var lastTouchWasCleanTap: Bool {
        guard lastTouchEndedAsTap, let touch = touchWatcher.start?.touch else { return false }
        return ProcessInfo.processInfo.systemUptime - touch.timestamp <= 0.6
    }
    /// Opens the field for typing from app code (not a native text gesture).
    func beginEditingOnPurpose() {
        openingOnPurpose = true; defer { openingOnPurpose = false }
        becomeFirstResponder()
    }
    override var undoManager: UndoManager? { historyOwner?.notebookUndo }
    override var keyCommands: [UIKeyCommand]? {
        (super.keyCommands ?? []) + (isFlow ? [
            UIKeyCommand(input: "z", modifierFlags: .command, action: #selector(undoFlow)),
            UIKeyCommand(input: "z", modifierFlags: [.command, .shift], action: #selector(redoFlow)), Self.pageBreakCommand] : []) + [UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(escape)),
            Self.selectAllCommand,
            UIKeyCommand(input: "b", modifierFlags: .command, action: #selector(bold)),
            UIKeyCommand(input: "i", modifierFlags: .command, action: #selector(italic)),
            UIKeyCommand(input: "u", modifierFlags: .command, action: #selector(underline))] + Self.formatCommands + Self.listCommands
    }
    private static let pageBreakCommand: UIKeyCommand = {
        let command = UIKeyCommand(title: "Seitenumbruch", action: #selector(shortcut(_:)), input: "\r", modifierFlags: .command, propertyList: "pagebreak")
        command.wantsPriorityOverSystemBehavior = true
        return command
    }()
    /// Tab/⇧Tab by `TextIndentEditing.tab`: in the prefix of a paragraph (and
    /// over several lines) a leading tab more or less, elsewhere Tab goes to
    /// the next stop (`TextTabs`) like the on-screen Tab.
    private static let listCommands: [UIKeyCommand] = [UIKeyModifierFlags(), .shift].map { flags in
        let command = UIKeyCommand(input: "\t", modifierFlags: flags, action: #selector(listTab(_:)))
        command.wantsPriorityOverSystemBehavior = true
        return command
    }
    @objc private func listTab(_ command: UIKeyCommand) {
        let outdent = command.modifierFlags.contains(.shift)
        if KeyboardRouter.shared.handle(token: outdent ? "<S-Tab>" : "<Tab>", text: self) { return }
        guard KeyboardRouter.shared.allowsTyping else { return }
        if onListTab?(outdent) != true, !outdent { insertText("\t") }
    }
    private static let formatCommands: [UIKeyCommand] = {
        let items: [(String, String, UIKeyModifierFlags, String)] = [
            ("Titel", "1", .command, "title"), ("Überschrift", "2", .command, "heading"),
            ("Unterüberschrift", "3", .command, "subheading"), ("Text", "4", .command, "body"),
            ("Schrift größer", "+", .command, "larger"), ("Schrift größer", "=", .command, "larger"),
            ("Schrift kleiner", "-", .command, "smaller"), ("Durchstreichen", "x", [.command, .shift], "strike"),
            ("Aufzählung", "7", [.command, .shift], "bullet"), ("Nummerierung", "8", [.command, .shift], "numbered"),
            ("Checkliste", "9", [.command, .shift], "checkbox"), ("Link", "k", .command, "link"), ("Markieren", "h", [.command, .shift], "highlight"),
            // German layouts report ⇧7/8/9 as their shifted characters.
            ("Aufzählung", "/", [.command, .shift], "bullet"), ("Nummerierung", "(", [.command, .shift], "numbered"), ("Checkliste", ")", [.command, .shift], "checkbox")]
        let aliases: Set<String> = ["=", "/", "(", ")"]
        return items.map { title, input, flags, id in
            let command = UIKeyCommand(title: title, action: #selector(shortcut(_:)), input: input, modifierFlags: flags, propertyList: id)
            command.wantsPriorityOverSystemBehavior = true
            if aliases.contains(input) { command.attributes = .hidden }
            return command
        }
    }()
    @objc private func shortcut(_ command: UIKeyCommand) { (command.propertyList as? String).map { onShortcut?($0) } }
    @objc private func undoFlow() { onFlowUndo?(false) }
    @objc private func redoFlow() { onFlowUndo?(true) }
    @objc private func escape() { if !KeyboardRouter.shared.handle(token: "<Esc>", text: self) { onEscape?() } }
    private static let selectAllCommand: UIKeyCommand = {
        let command = UIKeyCommand(input: "a", modifierFlags: .command, action: #selector(selectAllKey))
        command.wantsPriorityOverSystemBehavior = true
        return command
    }()
    @objc private func selectAllKey() { selectEverything() }
    @objc private func bold() { onBold?() }
    @objc private func italic() { onItalic?() }
    @objc private func underline() { onUnderline?() }
}

extension PageTextView: KeyboardTextTarget {
    var keepsTextFocus: Bool { window != nil && isEditable && historyOwner != nil }
    func keyboardColorRows() -> [KeyChoiceRow] { historyOwner?.keyboardColorRows() ?? [] }
    @discardableResult func keyboardSync() -> Bool { historyOwner?.keyboardSync(self) == true }
    func keyboardRun(_ command: TextEngine.Command, count: Int?) { historyOwner?.keyboardRun(command, count: count, editor: self) }
    func keyboardEscape() -> Bool { historyOwner?.keyboardEscape(self) ?? false }
    func keyboardShowSelection() { historyOwner?.keyboardShowSelection(self) }
    func keyboardUndo(redo: Bool) { historyOwner?.keyboardUndo(redo: redo, editor: self) }
    func insertPageBreak() { historyOwner?.insertPageBreak() }
}

struct CaretPlacement: Equatable {
    var location: Int
    var newlines: Int
    var caret: CGRect
}

final class NoScribble: NSObject, UIScribbleInteractionDelegate {
    static let shared = NoScribble()
    func scribbleInteraction(_ interaction: UIScribbleInteraction, shouldBeginAt location: CGPoint) -> Bool { false }
}

@MainActor
final class GlyphSelectionRect: UITextSelectionRect {
    private let base: UITextSelectionRect
    private let frame: CGRect
    private let start: Bool, end: Bool
    init(_ base: UITextSelectionRect, rect: CGRect, start: Bool, end: Bool) {
        self.base = base; frame = rect; self.start = start; self.end = end; super.init()
    }
    override var rect: CGRect { frame }
    override var writingDirection: NSWritingDirection { base.writingDirection }
    override var containsStart: Bool { start }
    override var containsEnd: Bool { end }
    override var isVertical: Bool { base.isVertical }
}

/// Notes the first touch of each sequence on a text view (also on its
/// subviews) until it ends; never recognizes, never delays or cancels touches.
final class TouchDownWatcher: UIGestureRecognizer, UIGestureRecognizerDelegate {
    private(set) var start: (touch: UITouch, point: CGPoint, time: TimeInterval)?
    init() {
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false; delaysTouchesBegan = false; delaysTouchesEnded = false; delegate = self
        // The default is „platform dependent“ (UIGestureRecognizer.h); every clean tap decides here.
        allowedTouchTypes = [UITouch.TouchType.direct, .indirectPointer, .pencil].map { NSNumber(value: $0.rawValue) }
    }
    var onEnded: ((UITouch) -> Void)?
    /// One finger on a resting page: stopping a scroll or pinching over text is no tap.
    private(set) var quiet = true
    private var viewportMoves: Bool {
        var current = view?.superview
        while let ancestor = current {
            if let scroll = ancestor as? UIScrollView, scroll.isDragging || scroll.isDecelerating || scroll.isZooming { return true }
            current = ancestor.superview
        }
        return false
    }
    /// A touch sequence is running. Decided by this recognizer's own life
    /// cycle, not by the phase of the last touch: a kept pointer touch never
    /// has to reach `.ended` or `.cancelled` (it can go on hovering), and then
    /// no later tap on this text ever counted and the field stayed closed.
    private var tracking = false
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = touches.first else { return }
        if (event.allTouches?.count ?? 1) > 1 { quiet = false }
        if !tracking {
            tracking = true
            quiet = (event.allTouches?.count ?? 1) == 1 && !viewportMoves
            start = (touch, touch.location(in: nil), touch.timestamp)
        }
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        if let start, touches.contains(start.touch) { tracking = false; onEnded?(start.touch); state = .failed }
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        if let start, touches.contains(start.touch) { tracking = false; state = .failed }
    }
    /// `start` stays: `lastTouchWasCleanTap` reads it right after the sequence.
    override func reset() { tracking = false; super.reset() }
    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
}
