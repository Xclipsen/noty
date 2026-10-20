import UIKit
import NotebookCore
import OSLog

/// Page-local native text views and history. Canonical coordinates never include
/// the current paper margins; only their display frames receive that translation.
@MainActor
final class TextObjectLayer: UIView, UITextViewDelegate, UIGestureRecognizerDelegate, UIColorPickerViewControllerDelegate, UIFontPickerViewControllerDelegate, UIPopoverPresentationControllerDelegate {
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
    weak var colorPopover: UIViewController?
    weak var iconPopover: UIViewController?
    var colorSelection: (UUID, UUID, Int, NSRange)?
    /// Counts the whole flow across pages (set by the sheet); nil: this segment only.
    var readFlowText: ((UUID) -> String)?
    var counterRefresh: DispatchWorkItem?
    var lastHighlight: HighlightColor {
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
    func requestCaretReveal(_ kind: CaretReveal) {
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
    var boxes: [TextBox] = []
    var fields: [UUID: TextFieldContainer] = [:]
    private var textViewport: InkRenderViewport?
    private var rasterScreenScale: CGFloat = 2
    var selectedID: UUID?
    var pageID: UUID?
    private var contentGeneration = -1
    var generation = 0
    private var pageLayout = PageLayout(source: .testPaper, legacyA4: true)
    var active = false
    private var readOnly = false
    var updating = false
    var insertingList = false
    private var darkPaper = false
    private var darkMargins = false
    private var hasPDF = false
    private var paperStyle = PaperStyle.blank
    private var marginStyle = PaperStyle.blank
    private let notice = UILabel()
    private var onChange: (([TextBox]) -> Void)?
    private var dragStart: (boxes: [TextBox], box: TextBox, generation: Int)?
    private lazy var accessory = makeAccessory()
    var buttons: [String: UIButton] = [:]
    /// BUG-18 input diagnosis (category `text-input`), only with Settings › Diagnose.
    private let inputLog = Logger(subsystem: "de.la.noty", category: "text-input")
    private var tracing: Bool { HangProbe.isInstalled }
    private var loggedSize = CGSize.zero

    /// Notebook-wide undo (set by the sheet). Text views, the keyboard
    /// shortcut bar and ⌘Z use it, so text undo follows the same chronological
    /// history as ink, images and objects: every change is published to the
    /// model, which records it (`onChange`, `onFlowChange`). No local history.
    weak var notebookUndo: UndoManager?
    override var canBecomeFirstResponder: Bool { true }
    override var undoManager: UndoManager? { notebookUndo }
    override var inputView: UIView? { UIView(frame: .zero) }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear; clipsToBounds = true
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
        // A field drag keeps its live frame locally and commits once when it
        // ends; the unchanged model state meanwhile is no conflicting update.
        var incoming = incoming
        if !reset, active, self.active, let start = dragStart, start.generation == generation, start.boxes == incoming { incoming = boxes }
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
        if !reset && boxes != incoming { dragStart = nil }
        if reset {
            onEditingActive?(false)
            compositionBase = nil
            generation += 1; dragStart = nil; notice.isHidden = true
            for field in fields.values {
                field.editor.delegate = nil; field.editor.resignFirstResponder()
                field.editor.historyOwner = nil
                field.removeFromSuperview()
            }
            fields.removeAll(); selectedID = nil
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

    /// Memory warning: text views of removed boxes are kept for reuse (and so
    /// none is released inside its own delegate callback); drop them here.
    func releaseMemory() {
        let live = Set(boxes.map(\.id))
        for (id, field) in fields where !live.contains(id) && !field.editor.isFirstResponder {
            field.editor.delegate = nil; field.editor.historyOwner = nil
            field.removeFromSuperview(); fields.removeValue(forKey: id)
        }
    }
    /// The fields show exactly these boxes (no local edit pending).
    func shows(_ incoming: [TextBox]) -> Bool { boxes == incoming }
    func adoptCallback(_ onChange: @escaping ([TextBox]) -> Void) { self.onChange = onChange }

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

    func synchronize() {
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
                for (handle, action) in [(field.move, #selector(moveField(_:))), (field.resize, #selector(resizeField(_:)))] {
                    let pan = UIPanGestureRecognizer(target: self, action: action)
                    pan.delegate = ScrollPanPriority.shared // the notebook pan waits for field drags
                    handle.addGestureRecognizer(pan)
                }
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
    func publish() { if !updating { HangProbe.hit("Text.publish"); onChange?(boxes) } }
    func neededHeight(_ editor: UITextView, width: Double) -> Double {
        ceil(editor.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height)
    }
    func grow(_ index: Int) {
        guard boxes[index].flowID == nil, let field = fields[boxes[index].id] else { return }
        let available = max(1, canonicalBounds.maxY - boxes[index].y)
        boxes[index].height = min(available, max(boxes[index].height, max(24, neededHeight(field.editor, width: boxes[index].width))))
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
        notice.isHidden = true
        if fields.count >= 400 { releaseMemory() } // views of removed boxes, see there
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
        boxes.append(box); selectedID = box.id
        if tracing { inputLog.info("[noty.text-input] Text field inserted count=\(self.boxes.count) x=\(Double(box.x)) y=\(Double(box.y))") }
        synchronize(); publish()
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
            self.boxes.remove(at: index)
            if self.selectedID == id { self.selectedID = nil }
            self.synchronize(); self.publish()
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
    func commitFlow(previous: TextBox, editor: PageTextView) {
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
            // Live feedback stays local; the model gets one change at the end
            // (one undo step, no autosave/SwiftUI round trip per frame).
            boxes[index] = box; grow(index)
            if gesture.state == .began { synchronize() } else { showDragged(index) }
        case .ended:
            dragStart = nil; synchronize(); publish()
        case .cancelled, .failed:
            boxes = start.boxes; dragStart = nil; synchronize(); publish()
        default: break
        }
    }

    /// One drag frame: only the dragged free field moves or changes width.
    private func showDragged(_ index: Int) {
        let box = boxes[index]
        guard let field = fields[box.id] else { return }
        position(field, for: box); updateRaster(field, for: box)
        let pointScale = coordinateScale(for: box)
        let overflowing = neededHeight(field.editor, width: box.width / pointScale) * pointScale > box.height + 1
        field.configure(selected: active && selectedID == box.id, overflowing: overflowing, floating: box.flowID == nil)
    }

    @objc private func deleteSelected() {
        guard active, let selectedID else { return }
        fields[selectedID]?.editor.resignFirstResponder()
        boxes.removeAll { $0.id == selectedID }; self.selectedID = nil
        synchronize(); publish()
        becomeFirstResponder()
    }

    var selectionStyle: TextBoxStyle? {
        guard let selectedID, let box = boxes.first(where: { $0.id == selectedID }), let editor = fields[selectedID]?.editor else { return nil }
        if editor.selectedRange.length > 0, editor.selectedRange.location < editor.attributedText.length {
            return TextBoxStyle(attributes: editor.attributedText.attributes(at: editor.selectedRange.location, effectiveRange: nil), fallback: box.style)
        }
        return TextBoxStyle(attributes: editor.typingAttributes, fallback: box.style)
    }
    func changeStyle(_ action: (inout TextBoxStyle) -> Void, paragraph: Bool = false, wholeFloatingField: Bool = false) {
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
        else { publish() }
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
    @objc func toggleBold() { changeStyle { $0.bold.toggle() } }
    @objc func toggleItalic() { changeStyle { $0.italic.toggle() } }
    @objc func toggleTextUnderline() { changeStyle { $0.underline.toggle() } }
    /// Tap repeats the last marker colour (again removes it); long press picks one.
    @objc func toggleHighlight() {
        let style = selectionStyle, color = lastHighlight
        applyHighlight(style?.highlighted == true && (style?.highlightColor ?? .yellow) == color ? nil : color)
    }
    func applyHighlight(_ color: HighlightColor?) {
        if let color { lastHighlight = color }
        changeStyle { $0.highlighted = color == nil ? nil : true; $0.highlightColor = color == .yellow ? nil : color }
    }
    func applyPreset(_ preset: TextStylePreset) {
        let flow = selectedID.flatMap { id in boxes.first { $0.id == id } }?.flowID != nil
        changeStyle({ preset.apply(to: &$0) }, paragraph: flow, wholeFloatingField: !flow)
    }
    var selectedLight: Bool { selectedID.flatMap { id in boxes.first { $0.id == id } }.map(automaticLight) ?? false }
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
    @objc func smaller() { changeStyle({ $0.fontSize = max(8, $0.fontSize - 1) }, wholeFloatingField: true) }
    @objc func larger() { changeStyle({ $0.fontSize = min(96, $0.fontSize + 1) }, wholeFloatingField: true) }

    func toggleList(_ kind: TextListEditing.Kind) {
        guard let selectedID, let index = boxes.firstIndex(where: { $0.id == selectedID }),
              let editor = fields[selectedID]?.editor, editor.isFirstResponder, editor.markedTextRange == nil else { return }
        let edits = TextListEditing.toggle(kind, in: editor.text ?? "", range: editor.selectedRange, level: boxes[index].listLevel(at:))
        applyListEdits(edits, at: index, editor: editor)
    }
    func applyListEdits(_ edits: [TextListEditing.Edit], at index: Int, editor: PageTextView) {
        guard !edits.isEmpty else { return }
        let previous = boxes[index], selection = TextListEditing.selection(editor.selectedRange, after: edits)
        updating = true
        editor.textStorage.beginEditing()
        for edit in edits.reversed() {
            let location = min(edit.range.location, max(0, editor.attributedText.length - 1))
            let attributes = editor.attributedText.length > 0 ? editor.attributedText.attributes(at: location, effectiveRange: nil) : editor.typingAttributes
            editor.textStorage.replaceCharacters(in: edit.range, with: NSAttributedString(string: edit.replacement, attributes: attributes))
        }
        editor.textStorage.endEditing()
        editor.selectedRange = selection
        updating = false
        boxes[index].capture(editor.attributedText); fields[boxes[index].id]?.content = boxes[index]
        normalizeFloatingList(index, previous: previous, editor: editor)
        grow(index); synchronize()
        if boxes[index].flowID != nil { commitFlow(previous: previous, editor: editor) }
        else { publish() }
        layoutIfNeeded(); requestCaretReveal(.typing)
    }
}
