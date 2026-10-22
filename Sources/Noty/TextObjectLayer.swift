import UIKit
import NotebookCore
import OSLog

/// Page-local native text views and history. Canonical coordinates never include
/// the current paper margins; only their display frames receive that translation.
///
/// Textneubau Stufe 1 (docs/TEXT-REBUILD-62.md): notebooks hold only free
/// fields. With the text tool a tap on empty paper opens a field with its
/// caret there (automatic width, height from the content, last used style);
/// a tap on a field's text line sets the caret. A tap beside the field being
/// edited ends it: with the tool fixed (`locked`) a new field opens at once,
/// otherwise the editor returns to the previous tool (`onLeaveField`).
/// Selecting, the width points and rotation of a selected field that is not
/// being edited live in `ObjectEditingLayer`.
@MainActor
final class TextObjectLayer: UIView, UITextViewDelegate, UIGestureRecognizerDelegate, UIColorPickerViewControllerDelegate, UIFontPickerViewControllerDelegate, UIPopoverPresentationControllerDelegate {
    var onEditingActive: ((Bool) -> Void)?
    var onCaretChanged: (() -> Void)?
    /// The user left the edited field (tap beside it, Esc, „Fertig“) while
    /// the text tool is not fixed: the editor returns to the previous tool.
    var onLeaveField: (() -> Void)?
    /// A tap of the text tool (layer coordinates), remembered for pasting.
    var onTap: ((CGPoint) -> Void)?
    /// „Textwerkzeug fixieren“: leaving a field keeps the tool, a tap beside opens a new field.
    private(set) var locked = false
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
    private enum FieldDrag { case move, left, right }
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
                   paperStyle: PaperStyle = .blank, marginStyle: PaperStyle = .blank, locked: Bool? = nil,
                   onChange: @escaping ([TextBox]) -> Void) {
        if let locked { self.locked = locked }
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
    /// Esc, „Fertig“ or a tap beside the field: the user leaves it.
    func finishFieldByUser() {
        endTextEditing()
        if !locked { onLeaveField?() }
    }
    var isEditingField: Bool { fields.values.contains { $0.editor.isFirstResponder } }

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
                field.editor.onEscape = { [weak self] in self?.finishFieldByUser() }
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
                // Frame zone moves (only touches on the container itself, not
                // on its text); the width points change the width.
                let border = UIPanGestureRecognizer(target: self, action: #selector(moveField(_:)))
                border.delegate = FieldBorderDrag.shared; border.maximumNumberOfTouches = 1
                field.addGestureRecognizer(border)
                for (handle, action) in [(field.leftWidth, #selector(widenLeft(_:))), (field.rightWidth, #selector(widenRight(_:)))] {
                    let pan = UIPanGestureRecognizer(target: self, action: action)
                    pan.delegate = ScrollPanPriority.shared // the notebook pan waits for field drags
                    handle.addGestureRecognizer(pan)
                }
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
            // Flow segments and the fields migrated from page text keep the ruling of their region.
            let lines = box.flowRegion.flatMap { TextRuling(paper: $0 == .page ? paperStyle : marginStyle) }
            let pointScale = coordinateScale(for: box)
            editor.setRulingOrigin(lines == nil ? nil : (box.y + pageLayout.contentOrigin.y) / pointScale, lines: lines ?? .lined)
            editor.isEditable = active; editor.isSelectable = active || readOnly
            editor.isUserInteractionEnabled = active || readOnly
            position(field, for: box); updateRaster(field, for: box)
            let overflowing = neededHeight(editor, width: box.width / pointScale) * pointScale > box.height + 1
            field.configure(editing: active && selectedID == box.id && box.flowID == nil, overflowing: overflowing)
        }
        // Later fields lie on top („Nach vorne“/„Nach hinten“ reorder the array).
        for box in boxes { if let field = fields[box.id] { bringSubviewToFront(field) } }
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
    /// Margin text keeps normal-page units: flow segments and migrated fields (`flowRegion`).
    func coordinateScale(for box: TextBox) -> CGFloat {
        box.flowRegion != nil && box.flowRegion != .page ? pageLayout.writingCoordinateScale : 1
    }
    /// Turned about the field's top-left corner, like preview, PDF and lasso.
    private func position(_ field: TextFieldContainer, for box: TextBox) {
        let scale = coordinateScale(for: box), frame = displayFrame(box)
        let local = CGRect(x: 0, y: 0, width: frame.width / scale, height: frame.height / scale)
        let transform = CGAffineTransform(rotationAngle: box.angle * .pi / 180).scaledBy(x: scale, y: scale)
        if field.bounds != local { field.bounds = local }
        if field.transform != transform { field.transform = transform }
        let middle = box.center
        let center = CGPoint(x: middle.x + pageLayout.contentOrigin.x, y: middle.y + pageLayout.contentOrigin.y)
        if field.center != center { field.center = center }
    }
    private var canonicalBounds: CGRect { pageLayout.canonicalInkBounds }
    func publish() { if !updating { HangProbe.hit("Text.publish"); onChange?(boxes) } }
    func neededHeight(_ editor: UITextView, width: Double) -> Double {
        ceil(editor.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height)
    }
    /// Height always from the content, width from the text while automatic.
    func grow(_ index: Int) {
        guard boxes[index].flowID == nil else { return }
        boxes[index] = fitted(boxes[index], keepOnPage: true)
    }
    func minimumWidth(_ box: TextBox) -> Double { max(16, box.style.fontSize) * Double(coordinateScale(for: box)) }
    /// Text height at the box's width in canonical units (the field's own
    /// editor when it exists, otherwise the shared layout).
    func measuredHeight(_ box: TextBox) -> Double {
        let scale = coordinateScale(for: box)
        if let editor = fields[box.id]?.editor, editor.attributedText.string == box.text {
            return neededHeight(editor, width: box.width / scale) * scale
        }
        return Double(TextObjectLayout(box, coordinateScale: scale).usedHeight)
    }
    /// Textneubau: the height follows the content (never beyond the page, more
    /// text stays stored and is marked as overflow); with `autoWidth` the width
    /// follows the longest line up to the page edge, then the text wraps.
    /// `keepOnPage`: shift a field that would no longer fit completely onto the page.
    func fitted(_ original: TextBox, keepOnPage: Bool = false) -> TextBox {
        guard original.flowID == nil else { return original }
        var box = original
        let limits = PageRect(canonicalBounds)
        let scale = Double(coordinateScale(for: box))
        if box.autoWidth == true {
            let minimum = minimumWidth(box)
            let widest = max(minimum, box.maximumWidth(in: limits, minimum: minimum))
            // Very long text (a large paste) wraps at the page edge anyway: no extra layout pass.
            if (box.text as NSString).length > 20_000 { box.width = widest }
            else {
                var probe = box; probe.width = widest
                let natural = Double(TextObjectLayout(probe, coordinateScale: CGFloat(scale)).usedWidth)
                box.width = min(widest, max(minimum, ceil(natural) + 4 * scale))
            }
        }
        let line = ceil(box.style.fontSize * TextStylePreset.lineHeightFactor * scale)
        let needed = max(line, measuredHeight(box))
        box.height = max(1, min(needed, box.maximumHeight(in: limits, minimum: min(needed, line))))
        if keepOnPage, !box.fits(in: limits), let shifted = box.shifted(into: limits) { box = shifted }
        return box
    }
    /// A text line of `box` (laid out by its field) is at the canonical point;
    /// the empty rest of the frame is no hit. `slack` in page units.
    func hitsTextLine(_ box: TextBox, at point: PagePoint, slack: Double) -> Bool {
        guard let field = fields[box.id], field.content?.text == box.text else { return box.contains(point, tolerance: slack) }
        let display = CGPoint(x: point.x + pageLayout.contentOrigin.x, y: point.y + pageLayout.contentOrigin.y)
        let scale = Double(coordinateScale(for: box))
        return field.editor.hitsLine(at: convert(display, to: field.editor), slack: CGFloat(slack / scale))
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
        let point = tap.location(in: self)
        onTap?(point)
        // A tap beside the field being edited ends it; fixed tool: new field at once.
        if isEditingField {
            finishFieldByUser()
            if locked { createField(at: point) }
            return
        }
        createField(at: point)
    }

    /// „Textfeld +“ and „Textfeld hinzufügen“: a new field at `point` (layer coordinates).
    func insertText(at point: CGPoint) { createField(at: point) }

    /// A new free field at `point` (layer coordinates) with the caret at the
    /// tap: the first line is centred on it, automatic width, last used style.
    /// `focus == false`: only published (pasting while another tool is active).
    @discardableResult
    func createField(at point: CGPoint, text: String = "", focus: Bool = true) -> UUID? {
        guard active || !focus else { if tracing { inputLog.info("[noty.text-input] Insertion ignored: text mode inactive") }; return nil }
        guard boxes.count < 200 else {
            notice.text = "Höchstens 200 Textfelder pro Seite."
            let width = min(360, max(40, bounds.width - 16))
            notice.frame = CGRect(x: min(max(8, point.x - width / 2), max(8, bounds.width - width - 8)),
                                  y: min(max(8, point.y - 52), max(8, bounds.height - 52)), width: width, height: 44)
            notice.isHidden = false; bringSubviewToFront(notice)
            return nil
        }
        notice.isHidden = true
        if fields.count >= 400 { releaseMemory() } // views of removed boxes, see there
        let limits = PageRect(canonicalBounds)
        let canonical = PagePoint(x: point.x - pageLayout.contentOrigin.x, y: point.y - pageLayout.contentOrigin.y)
        let dark = hasPDF ? (!pageLayout.sourceFrame.cgRect.contains(point) && darkMargins) : darkPaper
        let style = TextStyleMemory.style(light: dark)
        let line = ceil(style.fontSize * TextStylePreset.lineHeightFactor)
        guard let frame = TextFieldPlacement.frame(tap: canonical, limits: limits, width: max(16, style.fontSize), lineHeight: line) else { return nil }
        var box = TextBox(x: frame.x, y: frame.y, width: frame.width, height: frame.height, text: text, style: style)
        box.autoWidth = true
        boxes.append(box)
        if focus { selectedID = box.id }
        synchronize() // creates the native view the height is measured with
        if let index = boxes.firstIndex(where: { $0.id == box.id }) { boxes[index] = fitted(boxes[index], keepOnPage: true) }
        if tracing { inputLog.info("[noty.text-input] Text field inserted count=\(self.boxes.count) x=\(Double(box.x)) y=\(Double(box.y))") }
        synchronize(); publish()
        if focus, let editor = fields[box.id]?.editor {
            editor.becomeFirstResponder()
            editor.selectedRange = NSRange(location: (text as NSString).length, length: 0)
        }
        return box.id
    }

    /// Opens an existing field for typing; the caret goes to `point` (layer
    /// coordinates), otherwise to the end of the text.
    func focusField(_ id: UUID, at point: CGPoint?) {
        guard active, let field = fields[id], boxes.contains(where: { $0.id == id }) else { return }
        selectedID = id; synchronize(); layoutIfNeeded()
        let editor = field.editor
        if !editor.isFirstResponder { editor.becomeFirstResponder() }
        guard editor.markedTextRange == nil else { return }
        if let point, let position = editor.closestPosition(to: convert(point, to: editor)) {
            editor.selectedTextRange = editor.textRange(from: position, to: position)
        } else {
            editor.selectedRange = NSRange(location: editor.attributedText.length, length: 0)
        }
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

    @objc private func moveField(_ gesture: UIPanGestureRecognizer) { drag(gesture, kind: .move) }
    @objc private func widenLeft(_ gesture: UIPanGestureRecognizer) { drag(gesture, kind: .left) }
    @objc private func widenRight(_ gesture: UIPanGestureRecognizer) { drag(gesture, kind: .right) }
    /// While editing: the frame zone moves the field (through the one move
    /// path, `ObjectMovement`), the width points set a fixed width. The field
    /// keeps its caret; the model gets one change when the drag ends.
    private func drag(_ gesture: UIPanGestureRecognizer, kind: FieldDrag) {
        guard active, let field = (gesture.view as? TextFieldContainer) ?? (gesture.view?.superview as? TextFieldContainer),
              let index = boxes.firstIndex(where: { $0.id == field.id }), boxes[index].flowID == nil else { return }
        if gesture.state == .began {
            selectedID = field.id
            dragStart = (boxes, boxes[index], generation)
        }
        guard let start = dragStart, start.generation == generation else { return }
        let delta = gesture.translation(in: self)
        let limits = PageRect(canonicalBounds)
        switch gesture.state {
        case .began, .changed:
            var box = start.box
            switch kind {
            case .move:
                let shift = ObjectMovement.translation(moving: box.rotatedBounds, by: PagePoint(x: delta.x, y: delta.y), within: limits)
                box.x += shift.x; box.y += shift.y
            case .left, .right:
                let radians = box.angle * .pi / 180
                let along = Double(delta.x) * cos(radians) + Double(delta.y) * sin(radians)
                let minimum = minimumWidth(box)
                box.autoWidth = nil // a dragged width stays fixed
                if kind == .right { box.width = max(minimum, start.box.width + along) }
                else {
                    let width = max(minimum, start.box.width - along), moved = start.box.width - width
                    box.width = width; box.x += moved * cos(radians); box.y += moved * sin(radians)
                }
                box = fitted(box)
                guard box.fits(in: limits) else { return } // keep the last frame that fits
            }
            // Live feedback stays local; the model gets one change at the end
            // (one undo step, no autosave/SwiftUI round trip per frame).
            boxes[index] = box
            if gesture.state == .began { synchronize() } else { showDragged(index) }
        case .ended:
            dragStart = nil; synchronize(); publish()
        case .cancelled, .failed:
            boxes = start.boxes; dragStart = nil; synchronize(); publish()
        default: break
        }
    }

    /// One drag frame: only the dragged field moves or changes width.
    private func showDragged(_ index: Int) {
        let box = boxes[index]
        guard let field = fields[box.id] else { return }
        position(field, for: box); updateRaster(field, for: box)
        let pointScale = coordinateScale(for: box)
        let overflowing = neededHeight(field.editor, width: box.width / pointScale) * pointScale > box.height + 1
        field.configure(editing: active && selectedID == box.id, overflowing: overflowing)
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
        // New fields take over the last used style; „Formatierung entfernen“ leads back.
        if let used = selectionStyle { TextStyleMemory.remember(used) }
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
