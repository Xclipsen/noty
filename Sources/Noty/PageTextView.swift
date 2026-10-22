import UIKit
import NotebookCore

@MainActor
final class PageTextView: UITextView {
    private let ruling = RuledTextLayout()
    var rulingOrigin: CGFloat? { ruling.originY }
    var rulingLines: TextRuling { ruling.lines }
    func setRulingOrigin(_ y: CGFloat?, lines: TextRuling = .lined) {
        guard ruling.originY != y || ruling.lines != lines else { return }
        ruling.originY = y; ruling.lines = lines
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
    /// `point` (own coordinates). Empty lines count as no text; an empty field
    /// is hit inside its frame (it only exists while being edited).
    func hitsLine(at point: CGPoint, slack: CGFloat) -> Bool {
        let manager = layoutManager, inset = textContainerInset
        manager.ensureLayout(for: textContainer)
        guard manager.numberOfGlyphs > 0 else { return bounds.insetBy(dx: -slack, dy: -slack).contains(point) }
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
    override func paste(_ sender: Any?) { materializePlacement(); super.paste(sender) }
    /// TextKit spans caret/selection over the whole line fragment, which on ruled
    /// paper includes the gap up to the previous line. Use the glyph band instead.
    override func caretRect(for position: UITextPosition) -> CGRect {
        if let placement, selectedRange == NSRange(location: placement.location, length: 0),
           offset(from: beginningOfDocument, to: position) == placement.location { return placement.caret }
        let rect = super.caretRect(for: position)
        guard rect.minY.isFinite, rect.height.isFinite, rect.height > 0 else { return rect }
        let index = offset(from: beginningOfDocument, to: position)
        guard let band = glyphBand(near: rect, caretIndex: index) else { return rect }
        return CGRect(x: rect.minX, y: band.minY, width: rect.width, height: band.height)
    }
    override func selectionRects(for range: UITextRange) -> [UITextSelectionRect] {
        super.selectionRects(for: range).map { item in
            guard item.rect.minY.isFinite, item.rect.height > 0, let band = glyphBand(near: item.rect, caretIndex: nil) else { return item }
            return GlyphSelectionRect(item, rect: CGRect(x: item.rect.minX, y: band.minY, width: item.rect.width, height: band.height))
        }
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
            let natural = extra.minY + font.ascender
            baseline = ruling.originY.map { CGFloat(ruling.lines.baseline(forNatural: Double($0 + natural))) - $0 } ?? natural
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
        if isFlow, selectedRange.location == 0, selectedRange.length == 0 { onFlowBackspace?() }
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
        // With the text tool the Pencil scrolls the paper; handwriting-to-text
        // (Scribble) would turn every Pencil drag over text into writing.
        addInteraction(UIScribbleInteraction(delegate: NoScribble.shared))
        addGestureRecognizer(touchWatcher)
        touchWatcher.onEnded = { [weak self] touch in
            guard let self, self.refusedDuringTouch else { return }
            self.refusedDuringTouch = false
            if self.lastTouchWasCleanTap { self.onCleanTapAfterRefusal?(touch.location(in: self)) }
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    /// Feedback zu Build 62: „Der Cursor sollte erst reingehen, wenn man
    /// einmal normal gedrückt hat.“ The text view's own gestures (long press,
    /// drag, loupe, double tap held) may only open it after a clean tap: put
    /// down and lifted within 0.5 s, at most 10 screen points apart, just now.
    /// Code paths that open a field on purpose (new field by tap, „Bearbeiten“,
    /// second tap on a selected field, flow hand-off) set `openingOnPurpose`.
    private let touchWatcher = TouchDownWatcher()
    var openingOnPurpose = false
    /// Editing was refused while the touch was still down; if it ends as a
    /// clean tap after all, the field opens at the tap (own coordinates).
    var refusedDuringTouch = false
    var onCleanTapAfterRefusal: ((CGPoint) -> Void)?
    var touchIsDown: Bool { touchWatcher.start.map { $0.touch.phase != .ended && $0.touch.phase != .cancelled } ?? false }
    var lastTouchWasCleanTap: Bool {
        guard let start = touchWatcher.start else { return false }
        let touch = start.touch
        guard touch.phase == .ended else { return false }
        let point = touch.location(in: nil)
        return hypot(point.x - start.point.x, point.y - start.point.y) <= 10
            && touch.timestamp - start.time <= 0.5
            && ProcessInfo.processInfo.systemUptime - touch.timestamp <= 0.6
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
            UIKeyCommand(input: "z", modifierFlags: [.command, .shift], action: #selector(redoFlow))] : []) + [UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(escape)),
            UIKeyCommand(input: "b", modifierFlags: .command, action: #selector(bold)),
            UIKeyCommand(input: "i", modifierFlags: .command, action: #selector(italic)),
            UIKeyCommand(input: "u", modifierFlags: .command, action: #selector(underline))] + Self.formatCommands + Self.listCommands
    }
    /// Tab/⇧Tab nest list items; elsewhere Tab stays a tab character.
    private static let listCommands: [UIKeyCommand] = [UIKeyModifierFlags(), .shift].map { flags in
        let command = UIKeyCommand(input: "\t", modifierFlags: flags, action: #selector(listTab(_:)))
        command.wantsPriorityOverSystemBehavior = true
        return command
    }
    @objc private func listTab(_ command: UIKeyCommand) {
        let outdent = command.modifierFlags.contains(.shift)
        if onListTab?(outdent) != true, !outdent { insertText("\t") }
    }
    private static let formatCommands: [UIKeyCommand] = {
        let items: [(String, String, UIKeyModifierFlags, String)] = [
            ("Titel", "1", .command, "title"), ("Überschrift", "2", .command, "heading"),
            ("Unterüberschrift", "3", .command, "subheading"), ("Text", "4", .command, "body"),
            ("Schrift größer", "+", .command, "larger"), ("Schrift größer", "=", .command, "larger"),
            ("Schrift kleiner", "-", .command, "smaller"), ("Durchstreichen", "x", [.command, .shift], "strike"),
            ("Aufzählung", "7", [.command, .shift], "bullet"), ("Nummerierung", "8", [.command, .shift], "numbered"),
            ("Checkliste", "9", [.command, .shift], "checkbox")]
        return items.map { title, input, flags, id in
            let command = UIKeyCommand(title: title, action: #selector(shortcut(_:)), input: input, modifierFlags: flags, propertyList: id)
            command.wantsPriorityOverSystemBehavior = true
            if input == "=" { command.attributes = .hidden }
            return command
        }
    }()
    @objc private func shortcut(_ command: UIKeyCommand) { (command.propertyList as? String).map { onShortcut?($0) } }
    @objc private func undoFlow() { onFlowUndo?(false) }
    @objc private func redoFlow() { onFlowUndo?(true) }
    @objc private func escape() { onEscape?() }
    @objc private func bold() { onBold?() }
    @objc private func italic() { onItalic?() }
    @objc private func underline() { onUnderline?() }
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
    init(_ base: UITextSelectionRect, rect: CGRect) { self.base = base; frame = rect; super.init() }
    override var rect: CGRect { frame }
    override var writingDirection: NSWritingDirection { base.writingDirection }
    override var containsStart: Bool { base.containsStart }
    override var containsEnd: Bool { base.containsEnd }
    override var isVertical: Bool { base.isVertical }
}

/// Notes the first touch of each sequence on a text view (also on its
/// subviews) until it ends; never recognizes, never delays or cancels touches.
final class TouchDownWatcher: UIGestureRecognizer, UIGestureRecognizerDelegate {
    private(set) var start: (touch: UITouch, point: CGPoint, time: TimeInterval)?
    init() {
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false; delaysTouchesBegan = false; delaysTouchesEnded = false; delegate = self
    }
    var onEnded: ((UITouch) -> Void)?
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = touches.first else { return }
        if start.map({ $0.touch.phase == .ended || $0.touch.phase == .cancelled }) ?? true {
            start = (touch, touch.location(in: nil), touch.timestamp)
        }
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        if let start, touches.contains(start.touch) { onEnded?(start.touch); state = .failed }
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        if let start, touches.contains(start.touch) { state = .failed }
    }
    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
}
