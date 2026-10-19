import UIKit
import NotebookCore
import OSLog

/// Page-local native text views and history. Canonical coordinates never include
/// the current paper margins; only their display frames receive that translation.
@MainActor
final class TextObjectLayer: UIView, UITextViewDelegate, UIGestureRecognizerDelegate, UIColorPickerViewControllerDelegate, UIFontPickerViewControllerDelegate, UIPopoverPresentationControllerDelegate {
    private(set) var textHistory = UndoManager()
    var onEditingActive: ((Bool) -> Void)?
    var onCaretChanged: (() -> Void)?
    var onFlowChange: ((TextBox, TextBox, NSRange) -> TextFlowFocus?)?
    var onFlowUndo: ((Bool) -> Void)?
    var onFlowBackspace: ((TextBox) -> Void)?
    /// The next notebook undo record starts its own step (automatic lists).
    var onUndoBoundary: (() -> Void)?
    var readCurrentBoxes: (() -> [TextBox])?
    private var applyingFlow = false
    private var compositionBase: TextBox?
    private weak var colorPopover: UIViewController?
    private weak var iconPopover: UIViewController?
    private var colorSelection: (UUID, UUID, Int, NSRange)?
    /// Counts the whole flow across pages (set by the sheet); nil: this segment only.
    var readFlowText: ((UUID) -> String)?
    private var counterRefresh: DispatchWorkItem?
    private var lastHighlight: HighlightColor {
        get { (UserDefaults.standard.string(forKey: "noty.text.highlight")).flatMap(HighlightColor.init(rawValue:)) ?? .yellow }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "noty.text.highlight") }
    }
    /// Off unless chosen (Feedback 44: the page moved too often while typing).
    static var typewriterEnabled: Bool {
        get { UserDefaults.standard.object(forKey: AppSettingsKey.typewriter) as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: AppSettingsKey.typewriter) }
    }
    /// Strongest caret-follow reason since the viewport last looked. Typing may
    /// keep a margin (or the typewriter line); taps and selection changes only
    /// move the view when the caret is really hidden; selections never.
    private var pendingReveal: CaretReveal?
    private func requestCaretReveal(_ kind: CaretReveal) {
        var kind = kind
        if kind == .typing, Self.typewriterEnabled,
           fields.values.first(where: { $0.editor.isFirstResponder })?.editor.selectedRange.length == 0 { kind = .typewriter }
        pendingReveal = max(pendingReveal ?? kind, kind)
        onCaretChanged?()
    }
    /// Read once by the viewport's coalesced caret reveal.
    func takeCaretReveal() -> CaretReveal? {
        defer { pendingReveal = nil }
        return pendingReveal
    }

    var editingCaret: CGRect? {
        guard let editor = fields.values.first(where: { $0.editor.isFirstResponder })?.editor,
              let range = editor.selectedTextRange else { return nil }
        return editor.convert(editor.caretRect(for: range.end), to: self)
    }
    private var boxes: [TextBox] = []
    private var fields: [UUID: TextFieldContainer] = [:]
    private var textViewport: InkRenderViewport?
    private var rasterScreenScale: CGFloat = 2
    private var selectedID: UUID?
    private var pageID: UUID?
    private var contentGeneration = -1
    private var generation = 0
    private var pageLayout = PageLayout(source: .testPaper, legacyA4: true)
    private var active = false
    private var readOnly = false
    private var updating = false
    private var insertingList = false
    private var darkPaper = false
    private var darkMargins = false
    private var hasPDF = false
    private var paperStyle = PaperStyle.blank
    private var marginStyle = PaperStyle.blank
    private let notice = UILabel()
    private var onChange: (([TextBox]) -> Void)?
    private var dragStart: (boxes: [TextBox], box: TextBox, generation: Int)?
    private lazy var accessory = makeAccessory()
    private var buttons: [String: UIButton] = [:]
    /// BUG-18 input diagnosis (category `text-input`), only with Settings › Diagnose.
    private let inputLog = Logger(subsystem: "de.la.noty", category: "text-input")
    private var tracing: Bool { HangProbe.isInstalled }
    private var loggedSize = CGSize.zero

    /// Notebook-wide undo (set by the sheet). Text views, the keyboard
    /// shortcut bar and ⌘Z use it, so text undo follows the same chronological
    /// history as ink, images and objects. `textHistory` remains the fallback.
    weak var notebookUndo: UndoManager?
    override var canBecomeFirstResponder: Bool { true }
    override var undoManager: UndoManager? { notebookUndo ?? textHistory }
    override var inputView: UIView? { UIView(frame: .zero) }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear; clipsToBounds = true
        textHistory.levelsOfUndo = 50
        notice.font = .systemFont(ofSize: 14); notice.textColor = .systemRed
        notice.backgroundColor = .systemBackground; notice.layer.cornerRadius = 6
        notice.clipsToBounds = true; notice.numberOfLines = 2; notice.isHidden = true
        notice.isUserInteractionEnabled = false; addSubview(notice)
        let tap = UITapGestureRecognizer(target: self, action: #selector(insertAtTap(_:)))
        tap.delegate = self; tap.cancelsTouchesInView = false
        // Pencil taps place the caret / open a field too; Pencil drags scroll (viewport).
        tap.allowedTouchTypes = [UITouch.TouchType.direct, .indirectPointer, .pencil].map { NSNumber(value: $0.rawValue) }
        addGestureRecognizer(tap)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(boxes incoming: [TextBox], pageID: UUID, layout: PageLayout,
                   contentGeneration: Int, active: Bool, readOnly: Bool = false, darkPaper: Bool, darkMargins: Bool, hasPDF: Bool,
                   paperStyle: PaperStyle = .blank, marginStyle: PaperStyle = .blank,
                   onChange: @escaping ([TextBox]) -> Void) {
        let reset = self.pageID != pageID || self.contentGeneration != contentGeneration || self.pageLayout != layout
        if !reset, boxes == incoming, self.active == active, self.readOnly == readOnly,
           self.darkPaper == darkPaper, self.darkMargins == darkMargins, self.hasPDF == hasPDF,
           self.paperStyle == paperStyle, self.marginStyle == marginStyle {
            self.onChange = onChange
            return
        }
        if reset || self.active != active {
            iconPopover?.dismiss(animated: false)
            if tracing { inputLog.info("[noty.text-input] Text mode active=\(active) reset=\(reset)") }
        }
        updating = true
        defer { updating = false }
        if !reset && boxes != incoming { textHistory.removeAllActions(); dragStart = nil }
        if reset {
            onEditingActive?(false)
            compositionBase = nil
            generation += 1; dragStart = nil; notice.isHidden = true
            for field in fields.values {
                field.editor.delegate = nil; field.editor.resignFirstResponder()
                field.editor.historyOwner = nil
                field.removeFromSuperview()
            }
            fields.removeAll(); selectedID = nil; textHistory.removeAllActions()
            textHistory = UndoManager(); textHistory.levelsOfUndo = 50
        }
        self.pageID = pageID; self.contentGeneration = contentGeneration
        self.pageLayout = layout; self.active = active; self.readOnly = readOnly; self.darkPaper = darkPaper
        self.darkMargins = darkMargins; self.hasPDF = hasPDF
        self.paperStyle = paperStyle; self.marginStyle = marginStyle
        self.onChange = onChange
        if !fields.values.contains(where: { $0.editor.markedTextRange != nil }) { boxes = incoming }
        isUserInteractionEnabled = active || readOnly
        if !active { endEditing(true); selectedID = nil; notice.isHidden = true }
        synchronize()
    }

    func endTextEditing() { endEditing(true); onEditingActive?(false); selectedID = nil; synchronize() }

    private func checkboxHit(at point: CGPoint) -> (Int, TextListEditing.Edit)? {
        for index in boxes.indices.reversed() {
            guard let editor = fields[boxes[index].id]?.editor, editor.attributedText.length > 0 else { continue }
            let local = convert(point, to: editor)
            guard editor.bounds.insetBy(dx: -4, dy: -4).contains(local) else { continue }
            let manager = editor.layoutManager, container = editor.textContainer
            manager.ensureLayout(for: container)
            let glyph = manager.glyphIndex(for: local, in: container)
            guard glyph < manager.numberOfGlyphs else { continue }
            let character = manager.characterIndexForGlyph(at: glyph)
            guard let edit = TextListEditing.checkbox(in: editor.text ?? "", range: .init(location: character, length: 0)) else { continue }
            let range = manager.glyphRange(forCharacterRange: edit.range, actualCharacterRange: nil)
            let rect = manager.boundingRect(forGlyphRange: range, in: container).insetBy(dx: -4, dy: -4)
            if rect.contains(local) { return (index, edit) }
        }
        return nil
    }
    func hasCheckbox(at point: CGPoint) -> Bool { checkboxHit(at: point) != nil }
    func tapCheckbox(at point: CGPoint) {
        guard let (index, edit) = checkboxHit(at: point), let editor = fields[boxes[index].id]?.editor,
              editor.markedTextRange == nil else { return }
        applyListEdits([edit], at: index, editor: editor)
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let target = super.hitTest(point, with: event)
        if readOnly && !active { return target === self || target === notice ? nil : target }
        return target
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        HangProbe.hit("Text.layoutSubviews")
        if tracing, loggedSize != bounds.size {
            loggedSize = bounds.size
            inputLog.info("[noty.text-input] Text surface width=\(Double(self.bounds.width)) height=\(Double(self.bounds.height))")
        }
        for box in boxes {
            guard let field = fields[box.id] else { continue }
            position(field, for: box); updateRaster(field, for: box)
        }
    }

    private func synchronize() {
        HangProbe.hit("Text.synchronize")
        let wasUpdating = updating; updating = true
        defer { updating = wasUpdating }
        let live = Set(boxes.map(\.id))
        for (id, field) in fields where !live.contains(id) {
            field.editor.resignFirstResponder(); field.removeFromSuperview()
        }
        for box in boxes {
            let field: TextFieldContainer
            if let existing = fields[box.id] { field = existing }
            else {
                field = TextFieldContainer(id: box.id)
                field.editor.historyOwner = self; field.editor.delegate = self
                field.editor.inputAccessoryView = accessory
                field.editor.onEscape = { [weak self] in self?.endTextEditing() }
                field.editor.onBold = { [weak self] in self?.toggleBold() }
                field.editor.onItalic = { [weak self] in self?.toggleItalic() }
                field.editor.onUnderline = { [weak self] in self?.toggleTextUnderline() }
                field.editor.onShortcut = { [weak self] id in self?.performShortcut(id) }
                field.editor.onFlowUndo = { [weak self] redo in self?.onFlowUndo?(redo) }
                connectListInput(field.editor)
                field.editor.onFlowBackspace = { [weak self, weak field] in
                    guard let self, let field, let box = self.boxes.first(where: { $0.id == field.id }) else { return }
                    self.onFlowBackspace?(box)
                }
                field.move.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(moveField(_:))))
                field.resize.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(resizeField(_:))))
                field.delete.addTarget(self, action: #selector(deleteSelected), for: .touchUpInside)
                fields[box.id] = field
            }
            if field.superview !== self { addSubview(field) }
            let editor = field.editor
            let selectedRange = editor.selectedRange
            let light = automaticLight(box)
            if (field.content?.text != box.text || field.content?.runs != box.runs || field.content?.style != box.style || field.automaticLight != light), editor.markedTextRange == nil {
                let shown = box.resolvingAutomaticColor(light: light)
                editor.attributedText = shown.attributedText
                editor.typingAttributes = shown.style.attributes
                let length = (box.text as NSString).length
                editor.selectedRange = NSRange(location: min(selectedRange.location, length),
                                               length: min(selectedRange.length, max(0, length - min(selectedRange.location, length))))
            }
            field.content = box; field.automaticLight = light
            editor.isFlow = box.flowID != nil
            let lines = box.flowID == nil ? nil : TextRuling(paper: box.flowRegion == .page ? paperStyle : marginStyle)
            let pointScale = coordinateScale(for: box)
            editor.setRulingOrigin(lines == nil ? nil : (box.y + pageLayout.contentOrigin.y) / pointScale, lines: lines ?? .lined)
            editor.isEditable = active; editor.isSelectable = active || readOnly
            editor.isUserInteractionEnabled = active || readOnly
            position(field, for: box); updateRaster(field, for: box)
            let overflowing = neededHeight(editor, width: box.width / pointScale) * pointScale > box.height + 1
            // Free fields (PDF, or opened right of the middle on paper) get handles.
            field.configure(selected: active && selectedID == box.id, overflowing: overflowing, floating: box.flowID == nil)
        }
        for box in boxes where box.flowID == nil { if let field = fields[box.id] { bringSubviewToFront(field) } }
        bringSubviewToFront(notice)
        updateAccessory()
        setNeedsLayout()
    }

    /// Crisp text at every zoom (Feedback 44: text blurred when zoomed in).
    /// UIKit rasterizes a text view at the screen scale and the notebook zoom
    /// only magnified that bitmap; a page-sized bitmap at zoom resolution is far
    /// too large. Each field instead draws through `TextRasterView` for a
    /// padded, scale-quantized viewport (same reuse rule as the ink viewport).
    /// - Parameters: visible: this layer's visible rect; scale: page point to
    ///   screen point; live: pinch/snap in progress, keep the current raster.
    func updateDisplay(visible: CGRect, scale: CGFloat, screenScale: CGFloat, live: Bool) {
        let size = superview?.bounds.size ?? bounds.size
        guard size.width > 0, size.height > 0, scale.isFinite, scale > 0, screenScale > 0, !visible.isNull else { return }
        let page = PageSize(width: size.width, height: size.height)
        let quantized = TextRasterScale.quantized(Double(scale))
        if let current = textViewport, rasterScreenScale == screenScale,
           current.covers(PageRect(visible), page: page, scale: quantized, ignoringScale: live) { return }
        textViewport = InkRenderViewport(page: page, visible: PageRect(visible), scale: quantized)
        rasterScreenScale = screenScale
        for box in boxes { if let field = fields[box.id] { updateRaster(field, for: box) } }
    }
    private func updateRaster(_ field: TextFieldContainer, for box: TextBox) {
        guard let viewport = textViewport else { field.setRaster(nil, scale: 1); return }
        let local = field.convert(viewport.frame.cgRect, from: self).intersection(field.bounds)
        let area = local.isNull ? CGRect.zero : local
        let pointScale = coordinateScale(for: box)
        let scale = EditorRenderGeometry.contentScale(size: PageSize(width: area.width, height: area.height),
            displayScale: viewport.scale * pointScale, screenScale: Double(rasterScreenScale))
        field.setRaster(area, scale: CGFloat(scale))
    }

    private func displayFrame(_ box: TextBox) -> CGRect {
        CGRect(x: box.x + pageLayout.contentOrigin.x, y: box.y + pageLayout.contentOrigin.y,
               width: box.width, height: box.height)
    }
    private func automaticLight(_ box: TextBox) -> Bool {
        EditorInteractionPolicy.automaticTextIsLight(box: box, pageSize: pageLayout.contentCanvas, hasPDF: hasPDF,
            darkPaper: darkPaper, darkMargins: darkMargins)
    }
    private func coordinateScale(for box: TextBox) -> CGFloat {
        box.flowID != nil && box.flowRegion != .page ? pageLayout.writingCoordinateScale : 1
    }
    private func position(_ field: TextFieldContainer, for box: TextBox) {
        let scale = coordinateScale(for: box), frame = displayFrame(box)
        let local = CGRect(x: 0, y: 0, width: frame.width / scale, height: frame.height / scale)
        let transform = CGAffineTransform(scaleX: scale, y: scale)
        if field.bounds != local { field.bounds = local }
        if field.transform != transform { field.transform = transform }
        let center = CGPoint(x: frame.midX, y: frame.midY)
        if field.center != center { field.center = center }
    }
    private var canonicalBounds: CGRect { pageLayout.canonicalInkBounds }
    private func publish() { if !updating { HangProbe.hit("Text.publish"); onChange?(boxes) } }
    private func neededHeight(_ editor: UITextView, width: Double) -> Double {
        ceil(editor.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height)
    }
    private func grow(_ index: Int) {
        guard boxes[index].flowID == nil, let field = fields[boxes[index].id] else { return }
        let available = max(1, canonicalBounds.maxY - boxes[index].y)
        boxes[index].height = min(available, max(boxes[index].height, max(24, neededHeight(field.editor, width: boxes[index].width))))
    }

    private func compactHistoryPool() {
        guard fields.count >= 400 else { return }
        // Native undo actions may retain removed UITextViews. Discard their
        // history before releasing those targets; current text views stay alive.
        textHistory.removeAllActions()
        let live = Set(boxes.map(\.id))
        for id in Array(fields.keys) where !live.contains(id) {
            fields[id]?.editor.delegate = nil
            fields[id]?.editor.historyOwner = nil
            fields.removeValue(forKey: id)
        }
    }
    private func record(_ previous: [TextBox], name: String) {
        guard previous != boxes else { return }
        textHistory.registerUndo(withTarget: self) { layer in layer.restore(previous, name: name) }
        textHistory.setActionName(name)
    }
    private func restore(_ snapshot: [TextBox], name: String) {
        let previous = boxes
        boxes = snapshot
        if let selectedID, !boxes.contains(where: { $0.id == selectedID }) { self.selectedID = nil }
        record(previous, name: name)
        synchronize(); publish()
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        // UIKit may hit a blank descendant rather than this exact UIView.
        // Native text selection and field controls keep their own gestures.
        var view = touch.view
        while let current = view, current !== self {
            if current is TextFieldContainer || current is UITextView || current is UIControl {
                if tracing { inputLog.info("[noty.text-input] Insertion tap belongs to an existing field/control") }
                return false
            }
            view = current.superview
        }
        let accepted = view === self && active
        if tracing { inputLog.info("[noty.text-input] Insertion touch type=\(touch.type.rawValue) accepted=\(accepted)") }
        return accepted
    }
    @objc private func insertAtTap(_ tap: UITapGestureRecognizer) {
        guard active, tap.state == .ended else { return }
        insertText(at: tap.location(in: self), placing: true)
    }

    /// `placing`: a real tap also sets a click-and-type caret (not the „+“ button).
    func insertText(at point: CGPoint, placing: Bool = false) {
        guard active else { if tracing { inputLog.info("[noty.text-input] Insertion ignored: text mode inactive") }; return }
        guard boxes.count < 200 else {
            notice.text = "Höchstens 200 Textfelder pro Seite."
            let width = min(360, max(40, bounds.width - 16))
            notice.frame = CGRect(x: min(max(8, point.x - width / 2), max(8, bounds.width - width - 8)),
                                  y: min(max(8, point.y - 52), max(8, bounds.height - 52)), width: width, height: 44)
            notice.isHidden = false; bringSubviewToFront(notice)
            return
        }
        notice.isHidden = true; compactHistoryPool()
        let limits = canonicalBounds
        guard limits.width >= 40, limits.height >= 24 else { return }
        let canonical = PagePoint(x: point.x - pageLayout.contentOrigin.x, y: point.y - pageLayout.contentOrigin.y)
        var page = Page(); page.geometry = try? PDFPageGeometry(mediaBox: .init(x: 0, y: 0, width: pageLayout.contentCanvas.width, height: pageLayout.contentCanvas.height),
            cropBox: .init(x: 0, y: 0, width: pageLayout.contentCanvas.width, height: pageLayout.contentCanvas.height), rotation: 0)
        page.margins = PageMargins(left: -limits.minX, right: limits.maxX - pageLayout.contentCanvas.width,
            top: -limits.minY, bottom: limits.maxY - pageLayout.contentCanvas.height)
        var region = page.writingRegion(at: canonical, hasPDF: hasPDF)
        // Click-and-type (Feedback 44): the left half of a writing region always
        // offers the flowing lines; from the middle rightwards a tap beside or
        // below the text opens a separate free field instead of indenting.
        var fieldLimits = PageRect(limits)
        if placing, let current = region, let rect = page.writingRect(current) {
            let flow = boxes.first(where: { $0.flowRegion == current }).flatMap { fields[$0.id]?.editor }
            let hits = flow.map { $0.hitsText(at: convert(point, to: $0)) } ?? false
            if TextPlacement.opensFreeField(tapX: canonical.x, regionX: rect.x, regionWidth: rect.width, hitsText: hits) {
                region = nil; fieldLimits = rect
            }
        }
        if let region, let existing = boxes.first(where: { $0.flowRegion == region }), let field = fields[existing.id] {
            selectedID = existing.id; synchronize(); field.editor.becomeFirstResponder()
            if placing { placeCaret(in: field.editor, at: convert(point, to: field.editor)) }
            return
        }
        let dark = hasPDF ? (!pageLayout.sourceFrame.cgRect.contains(point) && darkMargins) : darkPaper
        var style = TextBoxStyle(); style.fontSize = 14; style.color = dark ? .white : .black; style.automaticColor = true
        var box: TextBox
        if let region, let rect = page.writingRect(region) {
            box = TextBox(x: rect.x, y: rect.y, width: rect.width, height: rect.height, style: style)
            box.flowID = UUID(); box.flowRegion = region
        } else if let frame = TextPlacement.freeFieldFrame(tap: canonical, limits: fieldLimits, fontSize: style.fontSize) {
            box = TextBox(x: frame.x, y: frame.y, width: frame.width, height: frame.height, style: style)
        } else { return }
        let previous = boxes; boxes.append(box); selectedID = box.id
        if tracing { inputLog.info("[noty.text-input] Text field inserted count=\(self.boxes.count) x=\(Double(box.x)) y=\(Double(box.y))") }
        record(previous, name: "Textfeld einfügen"); synchronize(); publish()
        fields[box.id]?.editor.becomeFirstResponder()
        if placing, box.flowID != nil, let editor = fields[box.id]?.editor { layoutIfNeeded(); placeCaret(in: editor, at: convert(point, to: editor)) }
    }

    func textViewShouldBeginEditing(_ textView: UITextView) -> Bool {
        guard active, let editor = textView as? PageTextView,
              boxes.contains(where: { $0.id == editor.objectID }) else { return false }
        selectedID = editor.objectID; notice.isHidden = true
        // Free fields stay free fields, also on paper and in writing margins
        // (they are opened on purpose right of the middle since Feedback 44);
        // they are no longer converted into page text on first edit.
        synchronize()
        return true
    }
    func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        guard active else { return false }
        if let handled = handleListInput(textView, range: range, text: text) { return handled }
        guard !insertingList, text == "\n", let edit = TextListEditing.newline(in: textView.text ?? "", range: range) else { return true }
        insertingList = true; defer { insertingList = false }
        textView.selectedRange = edit.range; textView.insertText(edit.replacement)
        return false
    }
    func textViewDidBeginEditing(_ textView: UITextView) {
        guard !updating, active else { return }
        onEditingActive?(true); layoutIfNeeded(); requestCaretReveal(.navigation)
    }
    func textViewDidEndEditing(_ textView: UITextView) {
        (textView as? PageTextView)?.placement = nil
        onEditingActive?(fields.values.contains { $0.editor.isFirstResponder })
        removeIfEmptyFreeField(textView)
    }
    /// A free field opened by a tap and left without text disappears again,
    /// so stray taps right of the middle leave nothing behind.
    private func removeIfEmptyFreeField(_ textView: UITextView) {
        guard let editor = textView as? PageTextView, fields[editor.objectID]?.editor === editor else { return }
        let id = editor.objectID, page = pageID, expected = generation
        DispatchQueue.main.async { [weak self] in
            guard let self, self.pageID == page, self.generation == expected,
                  let index = self.boxes.firstIndex(where: { $0.id == id }), self.boxes[index].flowID == nil,
                  self.boxes[index].text.isEmpty, self.fields[id]?.editor.isFirstResponder != true,
                  self.fields[id]?.editor.markedTextRange == nil, self.dragStart == nil else { return }
            let previous = self.boxes
            self.boxes.remove(at: index)
            if self.selectedID == id { self.selectedID = nil }
            self.record(previous, name: "Leeres Textfeld entfernen"); self.synchronize(); self.publish()
        }
    }
    func textViewDidChange(_ textView: UITextView) {
        guard !updating, active, let editor = textView as? PageTextView,
              fields[editor.objectID]?.editor === editor,
              let index = boxes.firstIndex(where: { $0.id == editor.objectID }) else { return }
        let previous = boxes[index]
        keepAppTypingAttributes(editor)
        boxes[index].capture(editor.attributedText)
        if let style = selectionStyle { boxes[index].style = style }
        fields[editor.objectID]?.content = boxes[index]
        if previous.flowID != nil, editor.markedTextRange != nil {
            if compositionBase == nil { compositionBase = previous }
        } else if previous.flowID != nil {
            let base = compositionBase ?? previous; compositionBase = nil
            commitFlow(previous: base, editor: editor)
        } else if previous.flowID == nil {
            normalizeFloatingList(index, previous: previous, editor: editor)
            grow(index); synchronize(); publish()
        }
        finishListInput(editor)
        layoutIfNeeded(); requestCaretReveal(.typing)
    }
    /// After typing, UIKit derives typing attributes from the typed character
    /// and may drop app keys (marker colour, automatic ink, font name). The
    /// typed character itself still carries them: continue with exactly those,
    /// so a chosen marker colour does not fall back to yellow after one letter.
    private func keepAppTypingAttributes(_ editor: PageTextView) {
        let selection = editor.selectedRange
        guard selection.length == 0, editor.markedTextRange == nil, selection.location > 0,
              selection.location <= editor.textStorage.length else { return }
        let typed = editor.textStorage.attributes(at: selection.location - 1, effectiveRange: nil)
        var typing = editor.typingAttributes, changed = false
        for (key, value) in typed where key.rawValue.hasPrefix("noty.") && typing[key] == nil {
            typing[key] = value; changed = true
        }
        if changed { editor.typingAttributes = typing }
    }
    private func commitFlow(previous: TextBox, editor: PageTextView) {
        guard !applyingFlow, let current = boxes.first(where: { $0.id == previous.id }), let onFlowChange else { return }
        applyingFlow = true
        defer { applyingFlow = false }
        if let focus = onFlowChange(previous, current, editor.selectedRange) {
            if let readCurrentBoxes { boxes = readCurrentBoxes() }
            synchronize()
            if focus.pageID == pageID, focus.boxID == editor.objectID {
                applyTextFocus(focus)
            }
        }
    }
    func applyTextFocus(_ focus: TextFlowFocus) {
        guard active, focus.pageID == pageID, let field = fields[focus.boxID],
              boxes.contains(where: { $0.id == focus.boxID }) else { return }
        selectedID = focus.boxID; synchronize(); layoutIfNeeded()
        defer { pendingReveal = max(pendingReveal ?? .typing, .typing) } // flow hand-off while typing
        let editor = field.editor
        if !editor.isFirstResponder { editor.becomeFirstResponder() }
        if editor.markedTextRange == nil {
            let length = editor.attributedText.length
            let range = NSRange(location: min(focus.selection.location, length), length: min(focus.selection.length, max(0, length - focus.selection.location)))
            if editor.selectedRange != range { editor.selectedRange = range }
            let light = boxes.first(where: { $0.id == focus.boxID }).map(automaticLight) ?? false
            editor.typingAttributes = focus.typingStyle.resolvingAutomaticColor(light: light).attributes
        }
    }

    @objc private func moveField(_ gesture: UIPanGestureRecognizer) { drag(gesture, resizing: false) }
    @objc private func resizeField(_ gesture: UIPanGestureRecognizer) { drag(gesture, resizing: true) }
    private func drag(_ gesture: UIPanGestureRecognizer, resizing: Bool) {
        guard active, let field = gesture.view?.superview as? TextFieldContainer,
              let index = boxes.firstIndex(where: { $0.id == field.id }) else { return }
        if gesture.state == .began {
            selectedID = field.id
            dragStart = (boxes, boxes[index], generation)
            endEditing(true)
        }
        guard let start = dragStart, start.generation == generation else { return }
        let delta = gesture.translation(in: self)
        let limits = canonicalBounds
        switch gesture.state {
        case .began, .changed:
            var box = start.box
            if resizing {
                let available = max(1, limits.maxX - box.x)
                box.width = min(max(min(40, available), start.box.width + delta.x), available)
            } else {
                box.x = min(max(start.box.x + delta.x, limits.minX), limits.maxX - box.width)
                box.y = min(max(start.box.y + delta.y, limits.minY), limits.maxY - box.height)
            }
            boxes[index] = box; grow(index); synchronize(); publish()
        case .ended:
            record(start.boxes, name: resizing ? "Textfeldbreite ändern" : "Textfeld verschieben")
            dragStart = nil; synchronize(); publish()
        case .cancelled, .failed:
            boxes = start.boxes; dragStart = nil; synchronize(); publish()
        default: break
        }
    }

    @objc private func deleteSelected() {
        guard active, let selectedID else { return }
        let previous = boxes
        fields[selectedID]?.editor.resignFirstResponder()
        boxes.removeAll { $0.id == selectedID }; self.selectedID = nil
        record(previous, name: "Textfeld löschen"); synchronize(); publish()
        becomeFirstResponder()
    }

    private var selectionStyle: TextBoxStyle? {
        guard let selectedID, let box = boxes.first(where: { $0.id == selectedID }), let editor = fields[selectedID]?.editor else { return nil }
        if editor.selectedRange.length > 0, editor.selectedRange.location < editor.attributedText.length {
            return TextBoxStyle(attributes: editor.attributedText.attributes(at: editor.selectedRange.location, effectiveRange: nil), fallback: box.style)
        }
        return TextBoxStyle(attributes: editor.typingAttributes, fallback: box.style)
    }
    private func changeStyle(_ action: (inout TextBoxStyle) -> Void, paragraph: Bool = false, wholeFloatingField: Bool = false) {
        guard let selectedID, let index = boxes.firstIndex(where: { $0.id == selectedID }),
              let editor = fields[selectedID]?.editor else { return }
        let previous = boxes
        let selection = editor.selectedRange
        let wasUpdating = updating; updating = true
        var range = EditorInteractionPolicy.formattingRange(selection: selection, textLength: editor.attributedText.length,
            floating: boxes[index].allowsObjectSelection, wholeField: wholeFloatingField)
        if paragraph, !boxes[index].text.isEmpty { range = (boxes[index].text as NSString).paragraphRange(for: selection) }
        if range.length > 0 {
            let formatted = NSMutableAttributedString(attributedString: editor.attributedText)
            editor.attributedText.enumerateAttributes(in: range) { attributes, subrange, _ in
                var style = TextBoxStyle(attributes: attributes, fallback: boxes[index].style)
                action(&style); formatted.setAttributes(style.attributes, range: subrange)
            }
            editor.attributedText = formatted; editor.selectedRange = selection
            if wholeFloatingField, selection.length == 0 {
                action(&boxes[index].style)
            }
            if selection.length == 0 {
                editor.typingAttributes = formatted.attributes(at: min(selection.location, formatted.length - 1), effectiveRange: nil)
            }
        } else {
            var style = selectionStyle ?? boxes[index].style
            action(&style); editor.typingAttributes = style.attributes
            boxes[index].style = style
        }
        boxes[index].capture(editor.attributedText)
        fields[selectedID]?.content = boxes[index]
        grow(index); synchronize()
        updating = wasUpdating
        if boxes[index].flowID != nil { commitFlow(previous: previous[index], editor: editor) }
        else { record(previous, name: "Text formatieren"); publish() }
        layoutIfNeeded(); requestCaretReveal(.typing)
    }
    func textViewDidChangeSelection(_ textView: UITextView) {
        if let editor = textView as? PageTextView, let placement = editor.placement,
           editor.selectedRange != NSRange(location: placement.location, length: 0) { editor.placement = nil }
        if !updating, !applyingFlow, active {
            if let editor = textView as? PageTextView, editor.markedTextRange == nil,
               let current = boxes.first(where: { $0.id == editor.objectID }),
               let persisted = readCurrentBoxes?().first(where: { $0.id == editor.objectID }), current != persisted, current.flowID != nil {
                let base = compositionBase ?? persisted; compositionBase = nil
                commitFlow(previous: base, editor: editor)
            }
            // Selection drags/handles never move the page; a moved caret only when hidden.
            updateAccessory()
            if textView.isFirstResponder, textView.selectedRange.length == 0 { requestCaretReveal(.navigation) }
        }
    }
    @objc private func toggleBold() { changeStyle { $0.bold.toggle() } }
    @objc private func toggleItalic() { changeStyle { $0.italic.toggle() } }
    @objc private func toggleTextUnderline() { changeStyle { $0.underline.toggle() } }
    /// Tap repeats the last marker colour (again removes it); long press picks one.
    @objc private func toggleHighlight() {
        let style = selectionStyle, color = lastHighlight
        applyHighlight(style?.highlighted == true && (style?.highlightColor ?? .yellow) == color ? nil : color)
    }
    private func applyHighlight(_ color: HighlightColor?) {
        if let color { lastHighlight = color }
        changeStyle { $0.highlighted = color == nil ? nil : true; $0.highlightColor = color == .yellow ? nil : color }
    }
    private func applyPreset(_ preset: TextStylePreset) {
        let flow = selectedID.flatMap { id in boxes.first { $0.id == id } }?.flowID != nil
        changeStyle({ preset.apply(to: &$0) }, paragraph: flow, wholeFloatingField: !flow)
    }
    private var selectedLight: Bool { selectedID.flatMap { id in boxes.first { $0.id == id } }.map(automaticLight) ?? false }
    private func performShortcut(_ id: String) {
        switch id {
        case "title": applyPreset(.title)
        case "heading": applyPreset(.heading)
        case "subheading": applyPreset(.subheading)
        case "body": applyPreset(.body)
        case "larger": larger()
        case "smaller": smaller()
        case "strike": changeStyle { $0.strikethrough = $0.strikethrough == true ? nil : true }
        case "bullet": toggleList(.bullet)
        case "numbered": toggleList(.numbered)
        case "checkbox": toggleList(.checkbox)
        default: break
        }
    }
    @objc private func smaller() { changeStyle({ $0.fontSize = max(8, $0.fontSize - 1) }, wholeFloatingField: true) }
    @objc private func larger() { changeStyle({ $0.fontSize = min(96, $0.fontSize + 1) }, wholeFloatingField: true) }

    private func toggleList(_ kind: TextListEditing.Kind) {
        guard let selectedID, let index = boxes.firstIndex(where: { $0.id == selectedID }),
              let editor = fields[selectedID]?.editor, editor.isFirstResponder, editor.markedTextRange == nil else { return }
        let edits = TextListEditing.toggle(kind, in: editor.text ?? "", range: editor.selectedRange, level: boxes[index].listLevel(at:))
        applyListEdits(edits, at: index, editor: editor)
    }
    private func applyListEdits(_ edits: [TextListEditing.Edit], at index: Int, editor: PageTextView) {
        guard !edits.isEmpty else { return }
        let previous = boxes, selection = TextListEditing.selection(editor.selectedRange, after: edits)
        updating = true
        textHistory.disableUndoRegistration()
        editor.textStorage.beginEditing()
        for edit in edits.reversed() {
            let location = min(edit.range.location, max(0, editor.attributedText.length - 1))
            let attributes = editor.attributedText.length > 0 ? editor.attributedText.attributes(at: location, effectiveRange: nil) : editor.typingAttributes
            editor.textStorage.replaceCharacters(in: edit.range, with: NSAttributedString(string: edit.replacement, attributes: attributes))
        }
        editor.textStorage.endEditing()
        editor.selectedRange = selection
        textHistory.enableUndoRegistration(); updating = false
        boxes[index].capture(editor.attributedText); fields[boxes[index].id]?.content = boxes[index]
        normalizeFloatingList(index, previous: previous[index], editor: editor)
        grow(index); synchronize()
        if boxes[index].flowID != nil { commitFlow(previous: previous[index], editor: editor) }
        else { record(previous, name: "Listenformat ändern"); publish() }
        layoutIfNeeded(); requestCaretReveal(.typing)
    }

    private func makeAccessory() -> UIView {
        let root = UIView(frame: CGRect(x: 0, y: 0, width: 1024, height: 54))
        root.overrideUserInterfaceStyle = .dark; root.backgroundColor = UIColor(white: 0.045, alpha: 0.98)
        root.layer.borderColor = UIColor.white.withAlphaComponent(0.16).cgColor; root.layer.borderWidth = 0.5
        let scroll = UIScrollView(frame: root.bounds)
        scroll.autoresizingMask = [.flexibleWidth, .flexibleHeight]; scroll.showsHorizontalScrollIndicator = false
        let stack = UIStackView(); stack.axis = .horizontal; stack.spacing = 2; stack.alignment = .center
        func button(_ key: String, title: String? = nil, symbol: String? = nil, width: CGFloat = 44, action: Selector? = nil) -> UIButton {
            let button = UIButton(type: .system)
            var config = UIButton.Configuration.plain()
            config.baseForegroundColor = .white
            config.title = title
            if let symbol { config.image = formatIcon(symbol) }
            config.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 6, bottom: 0, trailing: 6)
            button.configuration = config
            button.titleLabel?.font = .systemFont(ofSize: 15, weight: .medium)
            button.widthAnchor.constraint(equalToConstant: width).isActive = true
            button.heightAnchor.constraint(equalToConstant: 44).isActive = true
            button.layer.cornerRadius = 9; button.accessibilityLabel = key
            if let action { button.addTarget(self, action: action, for: .touchUpInside) }
            stack.addArrangedSubview(button); buttons[key] = button
            return button
        }
        func separator() {
            let view = UIView(); view.backgroundColor = UIColor.white.withAlphaComponent(0.14)
            view.widthAnchor.constraint(equalToConstant: 1).isActive = true
            view.heightAnchor.constraint(equalToConstant: 26).isActive = true
            stack.addArrangedSubview(view)
        }
        let preset = button("Textstil", title: "Text", width: 150)
        preset.backgroundColor = UIColor.white.withAlphaComponent(0.055); preset.showsMenuAsPrimaryAction = true
        preset.menu = UIMenu(title: "Absatzstil", children: TextStylePreset.allCases.map { item in
            UIAction(title: item.title, subtitle: "\(Int(item.fontSize)) pt\(item.bold ? " · fett" : "")") { [weak self] _ in self?.applyPreset(item) }
        })
        let family = button("Schrift", title: "System", width: 124)
        family.backgroundColor = UIColor.white.withAlphaComponent(0.055); family.showsMenuAsPrimaryAction = true
        family.menu = UIMenu(children: [
            UIAction(title: "System") { [weak self] _ in self?.changeStyle { $0.font = .system; $0.fontName = nil } },
            UIAction(title: "Serif") { [weak self] _ in self?.changeStyle { $0.font = .serif; $0.fontName = nil } },
            UIAction(title: "Festbreite") { [weak self] _ in self?.changeStyle { $0.font = .monospaced; $0.fontName = nil } },
            UIAction(title: "Weitere Schriften …", image: UIImage(systemName: "textformat")) { [weak self] _ in self?.chooseFont() }
        ])
        _ = button("Kleiner", symbol: "minus.circle", action: #selector(smaller))
        _ = button("Schriftgröße", title: "14", width: 38)
        buttons["Schriftgröße"]?.isUserInteractionEnabled = false
        _ = button("Größer", symbol: "plus.circle", action: #selector(larger))
        _ = button("Farbe", symbol: "circle.fill", action: #selector(chooseColor))
        separator()
        _ = button("F", symbol: "bold", action: #selector(toggleBold))
        _ = button("K", symbol: "italic", action: #selector(toggleItalic))
        _ = button("U", symbol: "underline", action: #selector(toggleTextUnderline))
        _ = button("Weitere Textformate", symbol: "chevron.down", action: #selector(showExtraFormats))
        separator()
        let marker = button("Markieren", symbol: "highlighter", action: #selector(toggleHighlight))
        marker.accessibilityHint = "Lang drücken für weitere Markerfarben"
        marker.menu = UIMenu(title: "Markerfarbe", children: HighlightColor.allCases.map { color in
            UIAction(title: color.title, image: swatch(color.uiColor.withAlphaComponent(0.6))) { [weak self] _ in self?.applyHighlight(color) }
        } + [UIAction(title: "Markierung entfernen", image: UIImage(systemName: "xmark.circle")) { [weak self] _ in self?.applyHighlight(nil) }])
        let link = button("Link", symbol: "link"); link.addAction(UIAction { [weak self] _ in self?.editLink() }, for: .touchUpInside)
        separator()
        for (key, symbol, kind) in [("Checkbox", "checkmark.circle", TextListEditing.Kind.checkbox), ("Aufzählung", "list.bullet", .bullet), ("Nummerierung", "list.number", .numbered)] {
            let item = button(key, symbol: symbol)
            item.addAction(UIAction { [weak self] _ in self?.toggleList(kind) }, for: .touchUpInside)
        }
        _ = button("Ausrichten", symbol: "text.alignleft", action: #selector(showAlignment))
        separator()
        let decrease = button("Einzug verkleinern", symbol: "decrease.indent")
        decrease.addAction(UIAction { [weak self] _ in self?.indentFromBar(outdent: true) }, for: .touchUpInside)
        let increase = button("Einzug vergrößern", symbol: "increase.indent")
        increase.addAction(UIAction { [weak self] _ in self?.indentFromBar(outdent: false) }, for: .touchUpInside)
        separator()
        let counter = button("Wortzahl", title: "0 Wörter", width: 112)
        counter.showsMenuAsPrimaryAction = true
        counter.configuration?.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes; attributes.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular); return attributes
        }
        let typewriter = button("Schreibmaschinen-Modus", symbol: "text.line.first.and.arrowtriangle.forward")
        typewriter.addAction(UIAction { [weak self] _ in Self.typewriterEnabled.toggle(); self?.updateAccessory() }, for: .touchUpInside)
        typewriter.accessibilityHint = "Hält die Schreibzeile im oberen Drittel"
        separator()
        _ = button("Fertig", symbol: "keyboard.chevron.compact.down", action: #selector(finishEditing))
        stack.translatesAutoresizingMaskIntoConstraints = false; scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            stack.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor)
        ])
        root.addSubview(scroll); root.autoresizingMask = [.flexibleWidth]
        return root
    }
    private var presentingController: UIViewController? {
        var responder: UIResponder? = self
        while let current = responder { if let controller = current as? UIViewController { return controller }; responder = current.next }
        return nil
    }
    private struct FormatIconChoice {
        var label: String
        var symbol: String
        var selected: Bool
        var change: (inout TextBoxStyle) -> Void
    }
    /// Fixed-size vector canvases keep differently shaped SF symbols centered.
    private func formatIcon(_ name: String) -> UIImage? {
        guard let symbol = UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: 19, weight: .regular)) else { return nil }
        return UIGraphicsImageRenderer(size: CGSize(width: 24, height: 24)).image { _ in
            let scale = min(22 / max(1, symbol.size.width), 22 / max(1, symbol.size.height))
            let size = CGSize(width: symbol.size.width * scale, height: symbol.size.height * scale)
            symbol.draw(in: CGRect(x: (24 - size.width) / 2, y: (24 - size.height) / 2, width: size.width, height: size.height))
        }.withRenderingMode(.alwaysTemplate)
    }
    @objc private func showExtraFormats() {
        guard let style = selectionStyle else { return }
        showIconMenu(sourceKey: "Weitere Textformate", choices: [
            .init(label: "Durchstreichen", symbol: "strikethrough", selected: style.strikethrough == true,
                change: { $0.strikethrough = !($0.strikethrough ?? false) }),
            .init(label: "Hochstellen", symbol: "textformat.superscript", selected: style.baseline == 1,
                change: { $0.baseline = $0.baseline == 1 ? nil : 1 }),
            .init(label: "Tiefstellen", symbol: "textformat.subscript", selected: style.baseline == -1,
                change: { $0.baseline = $0.baseline == -1 ? nil : -1 }),
            .init(label: "Formatierung entfernen", symbol: "eraser", selected: false,
                change: { [light = selectedLight] in $0 = $0.clearingCharacterFormatting(light: light) })
        ])
    }
    @objc private func showAlignment() {
        guard let style = selectionStyle else { return }
        let choices: [FormatIconChoice] = [("Links", "text.alignleft", TextAlignment.left),
            ("Mittig", "text.aligncenter", .center), ("Rechts", "text.alignright", .right),
            ("Blocksatz", "text.justify", .justified)].map { label, symbol, value in
                FormatIconChoice(label: label, symbol: symbol, selected: (style.alignment ?? .left) == value,
                    change: { $0.alignment = value })
            }
        showIconMenu(sourceKey: "Ausrichten", choices: choices, paragraph: true)
    }
    private func showIconMenu(sourceKey: String, choices: [FormatIconChoice], paragraph: Bool = false) {
        guard let controller = presentingController, controller.presentedViewController == nil,
              let source = buttons[sourceKey], rememberFormatSelection(), let selectedID,
              let editor = fields[selectedID]?.editor, editor.markedTextRange == nil else { return }
        let insertion = editor.typingAttributes
        let original = NSAttributedString(attributedString: editor.attributedText)
        let popover = UIViewController(); popover.overrideUserInterfaceStyle = .dark
        popover.view.backgroundColor = UIColor(white: 0.09, alpha: 1)
        popover.preferredContentSize = CGSize(width: choices.count * 44 + 16, height: 60)
        popover.modalPresentationStyle = .popover
        for (index, choice) in choices.enumerated() {
            let button = UIButton(type: .system)
            button.frame = CGRect(x: 8 + index * 44, y: 8, width: 44, height: 44)
            button.setImage(formatIcon(choice.symbol), for: .normal)
            button.tintColor = .white; button.layer.cornerRadius = 9
            button.backgroundColor = choice.selected ? UIColor.systemBlue.withAlphaComponent(0.4) : .clear
            button.isSelected = choice.selected; button.accessibilityLabel = choice.label
            button.addAction(UIAction { [weak self, weak popover, weak editor] _ in
                defer { popover?.dismiss(animated: true) }
                guard let self, let editor, editor.attributedText.isEqual(to: original), self.restoreFormatSelection() else { return }
                if editor.selectedRange.length == 0 { editor.typingAttributes = insertion }
                self.changeStyle(choice.change, paragraph: paragraph)
            }, for: .touchUpInside)
            popover.view.addSubview(button)
        }
        popover.popoverPresentationController?.sourceView = source
        popover.popoverPresentationController?.sourceRect = source.bounds
        popover.popoverPresentationController?.delegate = self
        iconPopover = popover; controller.present(popover, animated: true)
    }
    func adaptivePresentationStyle(for controller: UIPresentationController) -> UIModalPresentationStyle { .none }
    func adaptivePresentationStyle(for controller: UIPresentationController, traitCollection: UITraitCollection) -> UIModalPresentationStyle { .none }
    private func rememberFormatSelection() -> Bool {
        guard let pageID, let selectedID, let editor = fields[selectedID]?.editor else { return false }
        colorSelection = (pageID, selectedID, generation, editor.selectedRange); return true
    }
    private func restoreFormatSelection() -> Bool {
        guard let (page, id, gen, range) = colorSelection, active, page == pageID, gen == generation,
              selectedID == id, let editor = fields[id]?.editor else { return false }
        editor.selectedRange = range; return true
    }
    @objc private func chooseColor() {
        guard let controller = presentingController, let source = buttons["Farbe"], rememberFormatSelection() else { return }
        let popover = UIViewController(); popover.overrideUserInterfaceStyle = .dark
        popover.view.backgroundColor = UIColor(white: 0.035, alpha: 1)
        popover.preferredContentSize = CGSize(width: 360, height: 152)
        popover.modalPresentationStyle = .popover
        let colors: [(String, InkColor)] = [
            ("Gelb", .init(1,1,0)), ("Orange", .init(1,0.6,0)), ("Rot", .init(0.8,0.12,0.12)), ("Pink", .init(1,0,0.7)),
            ("Hellgrün", .init(0.5,0.9,0)), ("Grün", .init(0.3,0.7,0.3)), ("Violett", .init(0.7,0.2,0.9)), ("Lila", .init(0.6,0.4,0.8)),
            ("Mint", .init(0.5,1,0.8)), ("Blau", .init(0.1,0.35,0.8)), ("Hellblau", .init(0.3,0.5,0.9)), ("Lavendel", .init(0.6,0.5,1)),
            ("Schwarz", .init(0,0,0)), ("Grau", .init(0.4,0.4,0.4)), ("Weiß", .init(1,1,1)), ("Braun", .init(0.7,0.5,0.3))
        ]
        for (i, item) in colors.enumerated() {
            let button = UIButton(type: .system); button.accessibilityLabel = item.0
            button.frame = CGRect(x: 4 + (i % 8) * 44, y: 8 + (i / 8) * 44, width: 44, height: 44)
            let swatch = UIView(frame: CGRect(x: 9, y: 9, width: 26, height: 26)); swatch.isUserInteractionEnabled = false
            swatch.backgroundColor = UIColor(red: item.1.red, green: item.1.green, blue: item.1.blue, alpha: 1)
            swatch.layer.cornerRadius = 13; swatch.layer.borderWidth = 1; swatch.layer.borderColor = UIColor.white.withAlphaComponent(0.3).cgColor
            button.addSubview(swatch)
            button.addAction(UIAction { [weak self, weak popover] _ in
                guard let self, self.restoreFormatSelection() else { return }
                self.changeStyle { $0.ink = item.1; $0.automaticColor = nil }
                popover?.dismiss(animated: true)
            }, for: .touchUpInside)
            popover.view.addSubview(button)
        }
        let automatic = UIButton(type: .system); automatic.setTitle(" Automatisch", for: .normal)
        automatic.setImage(automaticSwatch().withRenderingMode(.alwaysOriginal), for: .normal)
        automatic.frame = CGRect(x: 8, y: 104, width: 168, height: 44); automatic.layer.cornerRadius = 9
        automatic.accessibilityHint = "Schwarz oder Weiß passend zum Papier, auch nach späterem Umstellen"
        if selectionStyle?.automaticColor == true { automatic.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.3) }
        automatic.addAction(UIAction { [weak self, weak popover] _ in
            guard let self, self.restoreFormatSelection() else { return }
            let light = self.selectedLight
            self.changeStyle { $0.automaticColor = true; $0.ink = nil; $0.color = light ? .white : .black }
            popover?.dismiss(animated: true)
        }, for: .touchUpInside); popover.view.addSubview(automatic)
        let custom = UIButton(type: .system); custom.setTitle("Weitere Farben …", for: .normal)
        custom.frame = CGRect(x: 184, y: 104, width: 168, height: 44)
        custom.addAction(UIAction { [weak self, weak popover] _ in
            popover?.dismiss(animated: true) { self?.chooseCustomColor() }
        }, for: .touchUpInside); popover.view.addSubview(custom)
        popover.popoverPresentationController?.sourceView = source
        popover.popoverPresentationController?.sourceRect = source.bounds
        colorPopover = popover; controller.present(popover, animated: true)
    }
    private func chooseCustomColor() {
        guard restoreFormatSelection(), let controller = presentingController else { return }
        let picker = UIColorPickerViewController(); picker.overrideUserInterfaceStyle = .dark
        picker.supportsAlpha = false; picker.delegate = self
        controller.present(picker, animated: true)
    }
    func colorPickerViewControllerDidSelectColor(_ viewController: UIColorPickerViewController) {
        guard restoreFormatSelection() else { return }
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        viewController.selectedColor.getRed(&r, green: &g, blue: &b, alpha: &a)
        changeStyle { $0.ink = InkColor(r,g,b,a); $0.automaticColor = nil }
    }
    private func chooseFont() {
        guard let controller = presentingController, rememberFormatSelection() else { return }
        let config = UIFontPickerViewController.Configuration(); config.includeFaces = true
        let picker = UIFontPickerViewController(configuration: config); picker.overrideUserInterfaceStyle = .dark
        picker.delegate = self; controller.present(picker, animated: true)
    }
    func fontPickerViewControllerDidPickFont(_ viewController: UIFontPickerViewController) {
        guard restoreFormatSelection(), let descriptor = viewController.selectedFontDescriptor else { return }
        let name = UIFont(descriptor: descriptor, size: 17).fontName
        changeStyle { $0.font = .system; $0.fontName = name }
        viewController.dismiss(animated: true)
    }
    private func editLink() {
        var responder: UIResponder? = self
        while responder != nil && !(responder is UIViewController) { responder = responder?.next }
        guard let controller = responder as? UIViewController else { return }
        // Link problems are shown as an alert.
        func warn(_ text: String) {
            let message = UIAlertController(title: "Link", message: text, preferredStyle: .alert)
            message.overrideUserInterfaceStyle = .dark
            message.addAction(UIAlertAction(title: "OK", style: .default))
            controller.present(message, animated: true)
        }
        guard let selectedID, let field = fields[selectedID], field.editor.selectedRange.length > 0 else {
            warn("Für einen Link zuerst Text markieren."); return
        }
        let expectedPage = pageID, expectedGeneration = generation
        let range = field.editor.selectedRange
        let alert = UIAlertController(title: "Link", message: "https://, http:// oder mailto:", preferredStyle: .alert)
        alert.overrideUserInterfaceStyle = .dark
        alert.addTextField { $0.text = self.selectionStyle?.link; $0.keyboardType = .URL; $0.autocapitalizationType = .none }
        alert.addAction(UIAlertAction(title: "Abbrechen", style: .cancel))
        alert.addAction(UIAlertAction(title: "Übernehmen", style: .default) { [weak self, weak field, weak alert] _ in
            guard let self, let field, self.active, self.pageID == expectedPage, self.generation == expectedGeneration else { return }
            let value = alert?.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !value.isEmpty {
                guard let scheme = URL(string: value)?.scheme?.lowercased(), ["https", "http", "mailto"].contains(scheme), value.utf8.count <= 2048 else {
                    warn("Ungültige Link-Adresse."); return
                }
            }
            field.editor.selectedRange = range
            self.changeStyle { $0.link = value.isEmpty ? nil : value }
        })
        controller.present(alert, animated: true)
    }
    @objc private func finishEditing() { endTextEditing() }
    private func swatch(_ color: UIColor) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 22, height: 22)).image { context in
            context.cgContext.setFillColor(color.cgColor); context.cgContext.fillEllipse(in: CGRect(x: 2, y: 2, width: 18, height: 18))
        }.withRenderingMode(.alwaysOriginal)
    }
    /// Half black, half white: follows the paper like the automatic pen.
    private func automaticSwatch() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 28, height: 28)).image { context in
            let rect = CGRect(x: 2, y: 2, width: 24, height: 24), cg = context.cgContext
            cg.setFillColor(UIColor.white.cgColor); cg.fillEllipse(in: rect)
            cg.saveGState(); cg.addEllipse(in: rect); cg.clip()
            cg.setFillColor(UIColor.black.cgColor); cg.fill(CGRect(x: rect.midX, y: rect.minY, width: rect.width / 2, height: rect.height))
            cg.restoreGState()
            cg.setStrokeColor(UIColor.white.withAlphaComponent(0.5).cgColor); cg.setLineWidth(1); cg.strokeEllipse(in: rect)
        }
    }
    /// Word/character counter, debounced: whole flow across pages or the selection.
    private func scheduleCounter() {
        counterRefresh?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refreshCounter() }
        counterRefresh = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }
    private func refreshCounter() {
        guard let button = buttons["Wortzahl"], let selectedID, let box = boxes.first(where: { $0.id == selectedID }),
              let editor = fields[selectedID]?.editor else { return }
        let selection = editor.selectedRange, text = editor.text ?? ""
        let partial = selection.length > 0 && NSMaxRange(selection) <= (text as NSString).length
        let source = partial ? (text as NSString).substring(with: selection) : box.flowID.flatMap { readFlowText?($0) } ?? text
        let stats = TextStatistics(source)
        button.setTitle(stats.words == 1 ? "1 Wort" : "\(stats.words) Wörter", for: .normal)
        button.accessibilityValue = "\(stats.words) Wörter, \(stats.characters) Zeichen"
        button.menu = UIMenu(title: partial ? "Auswahl" : box.flowID == nil ? "Textfeld" : "Gesamter Text", children: [
            UIAction(title: "Wörter: \(stats.words)", attributes: .disabled) { _ in },
            UIAction(title: "Zeichen: \(stats.characters)", attributes: .disabled) { _ in },
            UIAction(title: "Zeichen ohne Leerzeichen: \(stats.charactersWithoutSpaces)", attributes: .disabled) { _ in }
        ])
    }
    private func updateAccessory() {
        guard let selectedID, let box = boxes.first(where: { $0.id == selectedID }), let field = fields[selectedID] else { return }
        field.editor.accessibilityHint = neededHeight(field.editor, width: box.width) > box.height + 1
            ? "Textfeld am Seitenende · Text bleibt vollständig gespeichert." : nil
        let style = selectionStyle ?? box.style
        buttons["Textstil"]?.setTitle(TextStylePreset.matching(style).title, for: .normal)
        buttons["Schriftgröße"]?.setTitle(String(Int(style.fontSize)), for: .normal)
        buttons["Schrift"]?.setTitle(style.fontName.flatMap { UIFont(name: $0, size: 17)?.familyName } ?? (style.font == .serif ? "Serif" : style.font == .monospaced ? "Festbreite" : "System"), for: .normal)
        if style.automaticColor == true {
            buttons["Farbe"]?.setImage(automaticSwatch().withRenderingMode(.alwaysOriginal), for: .normal)
        } else if let ink = style.attributes[.foregroundColor] as? UIColor {
            let swatch = UIGraphicsImageRenderer(size: CGSize(width: 28, height: 28)).image { context in
                let rect = CGRect(x: 2, y: 2, width: 24, height: 24)
                context.cgContext.setFillColor(ink.cgColor); context.cgContext.fillEllipse(in: rect)
                context.cgContext.setStrokeColor(UIColor.white.withAlphaComponent(0.5).cgColor)
                context.cgContext.setLineWidth(1); context.cgContext.strokeEllipse(in: rect)
            }.withRenderingMode(.alwaysOriginal)
            buttons["Farbe"]?.setImage(swatch, for: .normal)
        }
        buttons["Markieren"]?.backgroundColor = style.highlighted == true ? (style.highlightColor?.uiColor ?? .systemYellow).withAlphaComponent(0.3) : .clear
        buttons["Markieren"]?.configuration?.baseForegroundColor = lastHighlight == .yellow ? .white : lastHighlight.uiColor
        buttons["Schreibmaschinen-Modus"]?.backgroundColor = Self.typewriterEnabled ? UIColor.systemBlue.withAlphaComponent(0.2) : .clear
        buttons["Schreibmaschinen-Modus"]?.accessibilityValue = Self.typewriterEnabled ? "Ein" : "Aus"
        scheduleCounter()
        let extraActive = style.strikethrough == true || (style.baseline ?? 0) != 0
        buttons["Weitere Textformate"]?.backgroundColor = extraActive ? UIColor.systemBlue.withAlphaComponent(0.2) : .clear
        let alignmentSymbol = switch style.alignment ?? .left {
        case .left: "text.alignleft"; case .center: "text.aligncenter"; case .right: "text.alignright"; case .justified: "text.justify"
        }
        buttons["Ausrichten"]?.setImage(formatIcon(alignmentSymbol), for: .normal)
        for (key, kind) in [("Checkbox", TextListEditing.Kind.checkbox), ("Aufzählung", .bullet), ("Nummerierung", .numbered)] {
            let enabled = TextListEditing.isActive(kind, in: field.editor.text ?? "", range: field.editor.selectedRange)
            buttons[key]?.isSelected = enabled
            buttons[key]?.backgroundColor = enabled ? UIColor.systemBlue.withAlphaComponent(0.2) : .clear
        }
        for (title, enabled) in [("F", style.bold), ("K", style.italic), ("U", style.underline)] {
            buttons[title]?.isSelected = enabled
            buttons[title]?.backgroundColor = enabled ? UIColor.systemBlue.withAlphaComponent(0.15) : .clear
        }
    }
}

@MainActor
private final class PageTextView: UITextView {
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
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var undoManager: UndoManager? { historyOwner?.notebookUndo ?? (isFlow ? nil : historyOwner?.textHistory) }
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

private final class NoScribble: NSObject, UIScribbleInteractionDelegate {
    static let shared = NoScribble()
    func scribbleInteraction(_ interaction: UIScribbleInteraction, shouldBeginAt location: CGPoint) -> Bool { false }
}

/// Draws a field's text for the visible part only, at the zoomed resolution,
/// through the editor's own layout manager (identical glyph positions). Below
/// the transparent text view, so caret, selection and handles stay on top.
@MainActor
private final class TextRasterView: UIView {
    weak var editor: PageTextView?
    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false; isOpaque = false; backgroundColor = .clear
        // Same appearance as the text view (dynamic marker colours, `.label`).
        overrideUserInterfaceStyle = .dark
        isAccessibilityElement = false
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ rect: CGRect) {
        guard let editor, let manager = editor.layoutManager as? TaskLayoutManager,
              let context = UIGraphicsGetCurrentContext() else { return }
        let inset = editor.textContainerInset
        // Own coordinates → editor coordinates (the editor fills the container).
        let area = rect.offsetBy(dx: frame.minX - inset.left, dy: frame.minY - inset.top)
        manager.rasterPass = true
        defer { manager.rasterPass = false; manager.lastRaster = CACurrentMediaTime() }
        let glyphs = manager.glyphRange(forBoundingRect: area, in: editor.textContainer)
        guard glyphs.length > 0 else { return }
        context.saveGState()
        context.translateBy(x: -frame.minX, y: -frame.minY)
        let origin = CGPoint(x: inset.left, y: inset.top)
        manager.drawBackground(forGlyphRange: glyphs, at: origin)
        manager.drawGlyphs(forGlyphRange: glyphs, at: origin)
        context.restoreGState()
    }
}

@MainActor
private final class GlyphSelectionRect: UITextSelectionRect {
    private let base: UITextSelectionRect
    private let frame: CGRect
    init(_ base: UITextSelectionRect, rect: CGRect) { self.base = base; frame = rect; super.init() }
    override var rect: CGRect { frame }
    override var writingDirection: NSWritingDirection { base.writingDirection }
    override var containsStart: Bool { base.containsStart }
    override var containsEnd: Bool { base.containsEnd }
    override var isVertical: Bool { base.isVertical }
}

@MainActor
private final class TextFieldContainer: UIView {
    let id: UUID
    let editor: PageTextView
    let move = UIView()
    let resize = UIView()
    let delete = UIButton(type: .system)
    private let raster = TextRasterView()
    var content: TextBox?
    var automaticLight: Bool?
    private var selected = false
    private var floating = false
    init(id: UUID) {
        self.id = id; editor = PageTextView(id: id)
        super.init(frame: .zero)
        clipsToBounds = false
        editor.backgroundColor = .clear; editor.linkTextAttributes = [:]; editor.textContainerInset = .zero
        editor.textContainer.lineFragmentPadding = 0; editor.isScrollEnabled = false
        editor.keyboardAppearance = .dark; editor.overrideUserInterfaceStyle = .dark
        editor.inputAssistantItem.leadingBarButtonGroups = []; editor.inputAssistantItem.trailingBarButtonGroups = []
        editor.accessibilityLabel = "Frei platziertes Textfeld"
        editor.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        move.backgroundColor = .clear; resize.backgroundColor = .clear
        move.isAccessibilityElement = true; resize.isAccessibilityElement = true
        move.accessibilityLabel = "Textfeld verschieben"; resize.accessibilityLabel = "Textfeldbreite ändern"
        let icon = UIImageView(image: UIImage(systemName: "arrow.up.and.down.and.arrow.left.and.right"))
        icon.tintColor = .systemBlue; icon.frame = CGRect(x: 12, y: 12, width: 20, height: 20)
        icon.isUserInteractionEnabled = false; move.addSubview(icon)
        let dot = UIView(frame: CGRect(x: 16, y: 16, width: 12, height: 12))
        dot.backgroundColor = .systemBlue; dot.layer.cornerRadius = 6; dot.isUserInteractionEnabled = false
        resize.addSubview(dot)
        delete.setImage(UIImage(systemName: "xmark.circle.fill"), for: .normal)
        delete.accessibilityLabel = "Textfeld löschen"
        raster.editor = editor
        (editor.layoutManager as? TaskLayoutManager)?.onDisplayChange = { [weak raster] in raster?.setNeedsDisplay() }
        [raster, editor, move, resize, delete].forEach { addSubview($0) }
    }
    /// `rect`: visible part in own coordinates; nil: no viewport yet, native text.
    func setRaster(_ rect: CGRect?, scale: CGFloat) {
        editor.drawsNatively = rect == nil
        guard let rect, !rect.isEmpty, scale.isFinite, scale > 0 else { raster.isHidden = true; return }
        raster.isHidden = false
        if raster.frame != rect { raster.frame = rect; raster.setNeedsDisplay() }
        if abs(raster.contentScaleFactor - scale) > 0.001 { raster.contentScaleFactor = scale; raster.setNeedsDisplay() }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func configure(selected: Bool, overflowing: Bool, floating: Bool) {
        self.selected = selected; self.floating = floating
        layer.borderWidth = (selected && floating) || overflowing ? 1 : 0
        layer.borderColor = (overflowing ? UIColor.systemRed : .systemBlue).cgColor
        [move, resize, delete].forEach { $0.isHidden = !(selected && floating) }
        setNeedsLayout()
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        if editor.frame != bounds { editor.frame = bounds; raster.setNeedsDisplay() }
        let scale = displayScale
        let top: CGFloat = frame.minY >= 48 / scale ? -24 / scale : bounds.height + 24 / scale
        for control in [move, resize, delete] {
            control.bounds = CGRect(x: 0, y: 0, width: 44, height: 44)
            control.transform = CGAffineTransform(scaleX: 1 / scale, y: 1 / scale)
        }
        move.center = CGPoint(x: 22 / scale, y: top)
        resize.center = CGPoint(x: bounds.width, y: bounds.height)
        delete.center = CGPoint(x: max(22 / scale, bounds.width - 22 / scale), y: top)
        if layer.borderWidth > 0 { layer.borderWidth = 1 / scale }
    }
    private var displayScale: CGFloat {
        guard let window else { return 1 }
        let a = convert(CGPoint.zero, to: window), b = convert(CGPoint(x: 100, y: 0), to: window)
        return max(0.001, hypot(b.x - a.x, b.y - a.y) / 100)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        var parent = superview
        while let current = parent {
            if let scroll = current as? UIScrollView {
                for handle in [move, resize] {
                    for gesture in handle.gestureRecognizers ?? [] {
                        scroll.panGestureRecognizer.require(toFail: gesture)
                    }
                }
                break
            }
            parent = current.superview
        }
    }
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        // Right of the middle beside/below page text: the layer opens a free field there.
        if editor.isFlow, editor.opensFreeField(at: convert(point, to: editor)) { return false }
        return bounds.insetBy(dx: selected && floating ? -48 / displayScale : 0, dy: selected && floating ? -48 / displayScale : 0).contains(point)
    }
}

// MARK: - Lists, nesting and click-and-type

private final class SimultaneousTap: NSObject, UIGestureRecognizerDelegate {
    static let shared = SimultaneousTap()
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        (gestureRecognizer.view as? PageTextView)?.isFlow == true && (gestureRecognizer.view as? UITextView)?.isEditable == true
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
}

extension TextObjectLayer {
    fileprivate func connectListInput(_ editor: PageTextView) {
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

    fileprivate func placeCaret(in editor: PageTextView, at point: CGPoint) {
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
                ruling: editor.rulingOrigin == nil ? nil : editor.rulingLines, origin: Double(editor.rulingOrigin ?? 0)),
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
            textHistory.disableUndoRegistration()
            editor.textStorage.replaceCharacters(in: NSRange(location: placement.location, length: 0),
                with: NSAttributedString(string: String(repeating: "\n", count: placement.newlines), attributes: filler))
            textHistory.enableUndoRegistration()
        }
        editor.selectedRange = NSRange(location: placement.location + placement.newlines, length: 0)
        let paragraph = ((typing[.paragraphStyle] as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
        paragraph.headIndent = 0; paragraph.firstLineHeadIndent = 0; paragraph.alignment = .left
        typing[.paragraphStyle] = paragraph
        editor.typingAttributes = typing
    }

    /// Tab, ⇧Tab, the indent buttons and Return on an empty nested item.
    fileprivate func nestList(_ editor: PageTextView, outdent: Bool) -> Bool {
        guard active, editor.markedTextRange == nil, fields[editor.objectID]?.editor === editor,
              let index = boxes.firstIndex(where: { $0.id == editor.objectID }),
              let plan = boxes[index].listNesting(selection: editor.selectedRange, outdent: outdent) else { return false }
        editor.placement = nil
        let previous = boxes
        var selection = editor.selectedRange
        updating = true
        textHistory.disableUndoRegistration()
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
        textHistory.enableUndoRegistration(); updating = false
        boxes[index].capture(editor.attributedText); fields[boxes[index].id]?.content = boxes[index]
        grow(index); synchronize()
        if boxes[index].flowID != nil { commitFlow(previous: previous[index], editor: editor) }
        else { record(previous, name: outdent ? "Liste ausrücken" : "Liste einrücken"); publish() }
        layoutIfNeeded(); requestCaretReveal(.typing)
        return true
    }
    fileprivate func indentFromBar(outdent: Bool) {
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
    fileprivate func normalizeFloatingList(_ index: Int, previous: TextBox, editor: PageTextView) {
        guard boxes[index].flowID == nil, editor.markedTextRange == nil,
              let changed = TextListEditing.changedRange(from: previous.text, to: boxes[index].text) else { return }
        let box = boxes[index]
        let edits = TextListEditing.normalize(box.text, level: box.listLevel(at:), changed: changed,
            restart: TextListEditing.numberedItem(in: previous.text, at: changed.location, level: previous.listLevel(at:)))
        guard !edits.isEmpty else { return }
        let wasUpdating = updating; updating = true
        let selection = TextListEditing.selection(editor.selectedRange, after: edits)
        textHistory.disableUndoRegistration()
        editor.textStorage.beginEditing(); replace(edits, in: editor); editor.textStorage.endEditing()
        editor.selectedRange = selection
        textHistory.enableUndoRegistration(); updating = wasUpdating
        boxes[index].capture(editor.attributedText); fields[boxes[index].id]?.content = boxes[index]
    }

    /// Tab inserts no tab in lists; Return on an empty nested item moves it out
    /// one level instead of ending the list. Remembers a typed space.
    fileprivate func handleListInput(_ textView: UITextView, range: NSRange, text: String) -> Bool? {
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
    fileprivate func finishListInput(_ editor: PageTextView) {
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
