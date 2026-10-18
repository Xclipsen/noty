import UIKit
import NotebookCore
import OSLog

/// Page-local native text views and history. Canonical coordinates never include
/// the current paper margins; only their display frames receive that translation.
@MainActor
final class TextObjectLayer: UIView, UITextViewDelegate, UIGestureRecognizerDelegate, UIColorPickerViewControllerDelegate, UIFontPickerViewControllerDelegate {
    private(set) var textHistory = UndoManager()
    var onEditingActive: ((Bool) -> Void)?
    var onCaretChanged: (() -> Void)?
    var onFlowChange: ((TextBox, TextBox, NSRange) -> TextFlowFocus?)?
    var onFlowUndo: ((Bool) -> Void)?
    var onFlowBackspace: ((TextBox) -> Void)?
    var readCurrentBoxes: (() -> [TextBox])?
    private var applyingFlow = false
    private var compositionBase: TextBox?
    private weak var colorPopover: UIViewController?
    private var colorSelection: (UUID, UUID, Int, NSRange)?

    var editingCaret: CGRect? {
        guard let editor = fields.values.first(where: { $0.editor.isFirstResponder })?.editor,
              let range = editor.selectedTextRange else { return nil }
        return editor.convert(editor.caretRect(for: range.end), to: self)
    }
    private var boxes: [TextBox] = []
    private var fields: [UUID: TextFieldContainer] = [:]
    private var selectedID: UUID?
    private var lastEditedFlow = false
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
    private let notice = UILabel()
    private var onChange: (([TextBox]) -> Void)?
    private var dragStart: (boxes: [TextBox], box: TextBox, generation: Int)?
    private lazy var accessory = makeAccessory()
    private let warning = UILabel()
    private var buttons: [String: UIButton] = [:]
    private let inputLog = Logger(subsystem: "de.la.noty", category: "text-input")
    private var loggedSize = CGSize.zero

    override var canBecomeFirstResponder: Bool { true }
    override var undoManager: UndoManager? { textHistory }
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
        tap.allowedTouchTypes = [UITouch.TouchType.direct, .indirectPointer].map { NSNumber(value: $0.rawValue) }
        addGestureRecognizer(tap)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(boxes incoming: [TextBox], pageID: UUID, layout: PageLayout,
                   contentGeneration: Int, active: Bool, readOnly: Bool = false, darkPaper: Bool, darkMargins: Bool, hasPDF: Bool,
                   onChange: @escaping ([TextBox]) -> Void) {
        let reset = self.pageID != pageID || self.contentGeneration != contentGeneration || self.pageLayout != layout
        if !reset, boxes == incoming, self.active == active, self.readOnly == readOnly,
           self.darkPaper == darkPaper, self.darkMargins == darkMargins, self.hasPDF == hasPDF {
            self.onChange = onChange
            return
        }
        if reset || self.active != active {
            inputLog.info("[noty.text-input] Text mode active=\(active) reset=\(reset)")
        }
        updating = true
        defer { updating = false }
        if !reset && boxes != incoming { textHistory.removeAllActions(); dragStart = nil }
        if reset {
            onEditingActive?(false)
            compositionBase = nil; lastEditedFlow = false
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
        self.onChange = onChange
        if !fields.values.contains(where: { $0.editor.markedTextRange != nil }) { boxes = incoming }
        isUserInteractionEnabled = active || readOnly
        if !active { endEditing(true); selectedID = nil; notice.isHidden = true }
        synchronize()
    }

    func endTextEditing() { endEditing(true); onEditingActive?(false); selectedID = nil; synchronize() }
    func performUndo(redo: Bool) {
        guard active else { return }
        let usesFlowHistory = selectedID.flatMap { id in boxes.first(where: { $0.id == id })?.flowID != nil } ?? lastEditedFlow
        if usesFlowHistory { onFlowUndo?(redo); return }
        if redo { textHistory.redo() } else { textHistory.undo() }
        // UIKit calls its delegate for native undo; also capture the visible views
        // here so toolbar undo does not depend on that callback's timing.
        for index in boxes.indices {
            if let field = fields[boxes[index].id], field.superview === self {
                boxes[index].capture(field.editor.attributedText)
                field.content = boxes[index]
                grow(index)
            }
        }
        synchronize(); publish()
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let target = super.hitTest(point, with: event)
        if readOnly && !active { return target === self || target === notice ? nil : target }
        return target
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        if loggedSize != bounds.size {
            loggedSize = bounds.size
            inputLog.info("[noty.text-input] Text surface width=\(Double(self.bounds.width)) height=\(Double(self.bounds.height))")
        }
        for box in boxes {
            guard let field = fields[box.id] else { continue }
            field.frame = displayFrame(box)
        }
    }

    private func synchronize() {
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
                field.editor.onFlowUndo = { [weak self] redo in self?.onFlowUndo?(redo) }
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
            if (field.content?.text != box.text || field.content?.runs != box.runs || field.content?.style != box.style), editor.markedTextRange == nil {
                editor.attributedText = box.attributedText
                editor.typingAttributes = box.style.attributes
                let length = (box.text as NSString).length
                editor.selectedRange = NSRange(location: min(selectedRange.location, length),
                                               length: min(selectedRange.length, max(0, length - min(selectedRange.location, length))))
            }
            field.content = box
            editor.isFlow = box.flowID != nil
            editor.isEditable = active; editor.isSelectable = active || readOnly
            editor.isUserInteractionEnabled = active || readOnly
            field.frame = displayFrame(box)
            let overflowing = neededHeight(editor, width: box.width) > box.height + 1
            field.configure(selected: active && selectedID == box.id, overflowing: overflowing, floating: hasPDF && box.flowRegion == nil)
        }
        for box in boxes where box.flowID == nil { if let field = fields[box.id] { bringSubviewToFront(field) } }
        bringSubviewToFront(notice)
        updateAccessory()
        setNeedsLayout()
    }

    func updateDisplayScale(_ scale: CGFloat) {
        for box in boxes {
            guard let editor = fields[box.id]?.editor else { continue }
            let target = EditorRenderGeometry.contentScale(size: box.rect.size, displayScale: scale, screenScale: 1)
            guard abs(editor.contentScaleFactor - target) > 0.05 else { continue }
            func update(_ view: UIView) {
                view.contentScaleFactor = target; view.setNeedsDisplay()
                for child in view.subviews { update(child) }
            }
            update(editor)
        }
    }

    private func displayFrame(_ box: TextBox) -> CGRect {
        CGRect(x: box.x + pageLayout.contentOrigin.x, y: box.y + pageLayout.contentOrigin.y,
               width: box.width, height: box.height)
    }
    private var canonicalBounds: CGRect { pageLayout.canonicalInkBounds }
    private func publish() { if !updating { onChange?(boxes) } }
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
                inputLog.info("[noty.text-input] Insertion tap belongs to an existing field/control")
                return false
            }
            view = current.superview
        }
        let accepted = view === self && active
        inputLog.info("[noty.text-input] Insertion touch type=\(touch.type.rawValue) accepted=\(accepted)")
        return accepted
    }
    @objc private func insertAtTap(_ tap: UITapGestureRecognizer) {
        guard active, tap.state == .ended else { return }
        insertText(at: tap.location(in: self))
    }

    func insertText(at point: CGPoint) {
        guard active else { inputLog.info("[noty.text-input] Insertion ignored: text mode inactive"); return }
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
        let region = page.writingRegion(at: canonical, hasPDF: hasPDF)
        if let region, let existing = boxes.first(where: { $0.flowRegion == region }), let field = fields[existing.id] {
            selectedID = existing.id; synchronize(); field.editor.becomeFirstResponder(); return
        }
        let dark = hasPDF ? (!pageLayout.sourceFrame.cgRect.contains(point) && darkMargins) : darkPaper
        var style = TextBoxStyle(); style.color = dark ? .white : .black
        var box: TextBox
        if let region, let rect = page.writingRect(region) {
            box = TextBox(x: rect.x, y: rect.y, width: rect.width, height: rect.height, style: style)
            box.flowID = UUID(); box.flowRegion = region
        } else {
            let x = min(max(canonical.x, limits.minX), limits.maxX - 40)
            let width = min(260, limits.maxX - x)
            let y = min(max(canonical.y, limits.minY), limits.maxY - 24)
            box = TextBox(x: x, y: y, width: width, height: 24, style: style)
        }
        lastEditedFlow = box.flowID != nil
        let previous = boxes; boxes.append(box); selectedID = box.id
        inputLog.info("[noty.text-input] Text field inserted count=\(self.boxes.count) x=\(Double(box.x)) y=\(Double(box.y))")
        record(previous, name: "Textfeld einfügen"); synchronize(); publish()
        fields[box.id]?.editor.becomeFirstResponder()
    }

    func textViewShouldBeginEditing(_ textView: UITextView) -> Bool {
        guard active, let editor = textView as? PageTextView,
              boxes.contains(where: { $0.id == editor.objectID }) else { return false }
        selectedID = editor.objectID; notice.isHidden = true
        if let index = boxes.firstIndex(where: { $0.id == editor.objectID }), boxes[index].flowID == nil {
            let box = boxes[index], size = pageLayout.contentCanvas
            let region: TextFlowRegion? = box.x >= size.width ? .right : box.x + box.width <= 0 ? .left : box.y + box.height <= 0 ? .top : box.y >= size.height ? .bottom : !hasPDF ? .page : nil
            if let region {
                boxes[index].flowID = UUID(); boxes[index].flowRegion = region
                let endY = region == .top ? 0 : region == .bottom ? canonicalBounds.maxY : size.height
                boxes[index].height = max(box.height, endY - box.y - 16)
                publish()
            }
        }
        lastEditedFlow = boxes.first(where: { $0.id == editor.objectID })?.flowID != nil
        synchronize()
        return true
    }
    func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        guard active else { return false }
        guard !insertingList, text == "\n", let edit = TextListEditing.newline(in: textView.text ?? "", range: range) else { return true }
        insertingList = true; defer { insertingList = false }
        textView.selectedRange = edit.range; textView.insertText(edit.replacement)
        return false
    }
    @objc private func toggleCheckbox() {
        guard let selectedID, let editor = fields[selectedID]?.editor,
              let edit = TextListEditing.checkbox(in: editor.text ?? "", range: editor.selectedRange) else { return }
        let selection = editor.selectedRange
        editor.selectedRange = edit.range; editor.insertText(edit.replacement); editor.selectedRange = selection
    }

    func textViewDidBeginEditing(_ textView: UITextView) {
        guard !updating, active else { return }
        onEditingActive?(true); layoutIfNeeded(); onCaretChanged?()
    }
    func textViewDidEndEditing(_ textView: UITextView) {
        onEditingActive?(fields.values.contains { $0.editor.isFirstResponder })
    }
    func textViewDidChange(_ textView: UITextView) {
        guard !updating, active, let editor = textView as? PageTextView,
              fields[editor.objectID]?.editor === editor,
              let index = boxes.firstIndex(where: { $0.id == editor.objectID }) else { return }
        let previous = boxes[index]
        boxes[index].capture(editor.attributedText)
        if let style = selectionStyle { boxes[index].style = style }
        fields[editor.objectID]?.content = boxes[index]
        if previous.flowID != nil, editor.markedTextRange != nil {
            if compositionBase == nil { compositionBase = previous }
        } else if previous.flowID != nil {
            let base = compositionBase ?? previous; compositionBase = nil
            commitFlow(previous: base, editor: editor)
        } else if previous.flowID == nil {
            grow(index); synchronize(); publish()
        }
        layoutIfNeeded(); onCaretChanged?()
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
        selectedID = focus.boxID; lastEditedFlow = true; synchronize(); layoutIfNeeded()
        let editor = field.editor
        if !editor.isFirstResponder { editor.becomeFirstResponder() }
        if editor.markedTextRange == nil {
            let length = editor.attributedText.length
            let range = NSRange(location: min(focus.selection.location, length), length: min(focus.selection.length, max(0, length - focus.selection.location)))
            if editor.selectedRange != range { editor.selectedRange = range }
            editor.typingAttributes = focus.typingStyle.attributes
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
        lastEditedFlow = false
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
    private func changeStyle(_ action: (inout TextBoxStyle) -> Void, paragraph: Bool = false) {
        guard let selectedID, let index = boxes.firstIndex(where: { $0.id == selectedID }),
              let editor = fields[selectedID]?.editor else { return }
        let previous = boxes
        let selection = editor.selectedRange
        var range = selection
        if paragraph, !boxes[index].text.isEmpty { range = (boxes[index].text as NSString).paragraphRange(for: selection) }
        if range.length > 0 {
            let formatted = NSMutableAttributedString(attributedString: editor.attributedText)
            editor.attributedText.enumerateAttributes(in: range) { attributes, subrange, _ in
                var style = TextBoxStyle(attributes: attributes, fallback: boxes[index].style)
                action(&style); formatted.setAttributes(style.attributes, range: subrange)
            }
            editor.attributedText = formatted; editor.selectedRange = selection
        } else {
            var style = selectionStyle ?? boxes[index].style
            action(&style); editor.typingAttributes = style.attributes
            boxes[index].style = style
        }
        boxes[index].capture(editor.attributedText)
        fields[selectedID]?.content = boxes[index]
        grow(index); synchronize()
        if boxes[index].flowID != nil { commitFlow(previous: previous[index], editor: editor) }
        else { record(previous, name: "Text formatieren"); publish() }
        layoutIfNeeded(); onCaretChanged?()
    }
    func textViewDidChangeSelection(_ textView: UITextView) {
        if !updating, !applyingFlow, active {
            if let editor = textView as? PageTextView, editor.markedTextRange == nil,
               let current = boxes.first(where: { $0.id == editor.objectID }),
               let persisted = readCurrentBoxes?().first(where: { $0.id == editor.objectID }), current != persisted, current.flowID != nil {
                let base = compositionBase ?? persisted; compositionBase = nil
                commitFlow(previous: base, editor: editor)
            }
            updateAccessory(); if textView.isFirstResponder { onCaretChanged?() }
        }
    }
    @objc private func toggleBold() { changeStyle { $0.bold.toggle() } }
    @objc private func toggleItalic() { changeStyle { $0.italic.toggle() } }
    @objc private func toggleTextUnderline() { changeStyle { $0.underline.toggle() } }
    @objc private func toggleHighlight() { changeStyle { $0.highlighted = !($0.highlighted ?? false) } }
    @objc private func smaller() { changeStyle { $0.fontSize = max(10, $0.fontSize - 2) } }
    @objc private func larger() { changeStyle { $0.fontSize = min(72, $0.fontSize + 2) } }

    private func toggleList(_ kind: TextListEditing.Kind) {
        guard let selectedID, let index = boxes.firstIndex(where: { $0.id == selectedID }),
              let editor = fields[selectedID]?.editor, editor.isFirstResponder, editor.markedTextRange == nil else { return }
        let edits = TextListEditing.toggle(kind, in: editor.text ?? "", range: editor.selectedRange)
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
        boxes[index].capture(editor.attributedText); fields[selectedID]?.content = boxes[index]
        grow(index); synchronize()
        if boxes[index].flowID != nil { commitFlow(previous: previous[index], editor: editor) }
        else { record(previous, name: "Listenformat ändern"); publish() }
        layoutIfNeeded(); onCaretChanged?()
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
            if let symbol { config.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 19, weight: .regular)) }
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
        let preset = button("Textstil", title: "Textkörper", width: 132)
        preset.backgroundColor = UIColor.white.withAlphaComponent(0.055); preset.showsMenuAsPrimaryAction = true
        preset.menu = UIMenu(children: [("Überschrift 1", 32.0), ("Überschrift 2", 26.0), ("Überschrift 3", 21.0), ("Textkörper", 17.0), ("Beschriftung", 12.0)].map { title, size in
            UIAction(title: title) { [weak self] _ in self?.changeStyle { $0.fontSize = size; $0.bold = size >= 21 } }
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
        _ = button("Schriftgröße", title: "17", width: 38)
        buttons["Schriftgröße"]?.isUserInteractionEnabled = false
        _ = button("Größer", symbol: "plus.circle", action: #selector(larger))
        _ = button("Farbe", symbol: "circle.fill", action: #selector(chooseColor))
        separator()
        _ = button("F", symbol: "bold", action: #selector(toggleBold))
        _ = button("K", symbol: "italic", action: #selector(toggleItalic))
        _ = button("U", symbol: "underline", action: #selector(toggleTextUnderline))
        let more = button("Weitere Textformate", symbol: "chevron.down"); more.showsMenuAsPrimaryAction = true
        more.menu = UIMenu(children: [
            UIAction(title: "Durchgestrichen", image: UIImage(systemName: "strikethrough")) { [weak self] _ in self?.changeStyle { $0.strikethrough = !($0.strikethrough ?? false) } },
            UIAction(title: "Hochgestellt", image: UIImage(systemName: "textformat.superscript")) { [weak self] _ in self?.changeStyle { $0.baseline = $0.baseline == 1 ? nil : 1 } },
            UIAction(title: "Tiefgestellt", image: UIImage(systemName: "textformat.subscript")) { [weak self] _ in self?.changeStyle { $0.baseline = $0.baseline == -1 ? nil : -1 } }
        ])
        separator()
        _ = button("Markieren", symbol: "highlighter", action: #selector(toggleHighlight))
        let link = button("Link", symbol: "link"); link.addAction(UIAction { [weak self] _ in self?.editLink() }, for: .touchUpInside)
        separator()
        for (key, symbol, kind) in [("Checkbox", "checkmark.circle", TextListEditing.Kind.checkbox), ("Aufzählung", "list.bullet", .bullet), ("Nummerierung", "list.number", .numbered)] {
            let item = button(key, symbol: symbol)
            item.addAction(UIAction { [weak self] _ in self?.toggleList(kind) }, for: .touchUpInside)
        }
        let checkbox = button("Aufgabe abhaken", symbol: "checkmark.circle.fill", action: #selector(toggleCheckbox))
        checkbox.showsMenuAsPrimaryAction = false
        let alignment = button("Ausrichten", symbol: "text.alignleft"); alignment.showsMenuAsPrimaryAction = true
        alignment.menu = UIMenu(children: [("Links", TextAlignment.left), ("Mittig", .center), ("Rechts", .right), ("Blocksatz", .justified)].map { title, value in
            UIAction(title: title) { [weak self] _ in self?.changeStyle({ $0.alignment = value }, paragraph: true) }
        })
        separator()
        let decrease = button("Einzug verkleinern", symbol: "decrease.indent")
        decrease.addAction(UIAction { [weak self] _ in self?.changeStyle({ $0.indent = max(0, ($0.indent ?? 0) - 20) }, paragraph: true) }, for: .touchUpInside)
        let increase = button("Einzug vergrößern", symbol: "increase.indent")
        increase.addAction(UIAction { [weak self] _ in self?.changeStyle({ $0.indent = min(240, ($0.indent ?? 0) + 20) }, paragraph: true) }, for: .touchUpInside)
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
                self.changeStyle { $0.ink = item.1 }
                popover?.dismiss(animated: true)
            }, for: .touchUpInside)
            popover.view.addSubview(button)
        }
        let custom = UIButton(type: .system); custom.setTitle("Weitere Farben …", for: .normal)
        custom.frame = CGRect(x: 8, y: 104, width: 344, height: 44)
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
        changeStyle { $0.ink = InkColor(r,g,b,a) }
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
        guard let selectedID, let field = fields[selectedID], field.editor.selectedRange.length > 0 else {
            warning.text = "Für einen Link zuerst Text markieren."; return
        }
        var responder: UIResponder? = self
        while responder != nil && !(responder is UIViewController) { responder = responder?.next }
        guard let controller = responder as? UIViewController else { return }
        let expectedPage = pageID, expectedGeneration = generation
        let range = field.editor.selectedRange
        let alert = UIAlertController(title: "Link", message: "https://, http:// oder mailto:", preferredStyle: .alert)
        alert.overrideUserInterfaceStyle = .dark
        alert.addTextField { $0.text = self.selectionStyle?.link; $0.keyboardType = .URL; $0.autocapitalizationType = .none }
        alert.addAction(UIAlertAction(title: "Abbrechen", style: .cancel))
        alert.addAction(UIAlertAction(title: "Übernehmen", style: .default) { [weak self, weak field] _ in
            guard let self, let field, self.active, self.pageID == expectedPage, self.generation == expectedGeneration else { return }
            let value = alert.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !value.isEmpty {
                guard let scheme = URL(string: value)?.scheme?.lowercased(), ["https", "http", "mailto"].contains(scheme), value.utf8.count <= 2048 else {
                    self.warning.text = "Ungültige Link-Adresse."; return
                }
            }
            field.editor.selectedRange = range
            self.changeStyle { $0.link = value.isEmpty ? nil : value }
        })
        controller.present(alert, animated: true)
    }
    @objc private func finishEditing() { endTextEditing() }
    private func updateAccessory() {
        guard let selectedID, let box = boxes.first(where: { $0.id == selectedID }), let field = fields[selectedID] else { warning.text = nil; return }
        warning.text = neededHeight(field.editor, width: box.width) > box.height + 1
            ? "Textfeld am Seitenende · Text bleibt vollständig gespeichert." : nil
        field.editor.accessibilityHint = warning.text
        let style = selectionStyle ?? box.style
        buttons["Textstil"]?.setTitle(style.fontSize >= 30 ? "Überschrift 1" : style.fontSize >= 24 ? "Überschrift 2" : style.fontSize >= 20 && style.bold ? "Überschrift 3" : style.fontSize <= 12 ? "Beschriftung" : "Textkörper", for: .normal)
        buttons["Schriftgröße"]?.setTitle(String(Int(style.fontSize)), for: .normal)
        buttons["Schrift"]?.setTitle(style.fontName.flatMap { UIFont(name: $0, size: 17)?.familyName } ?? (style.font == .serif ? "Serif" : style.font == .monospaced ? "Festbreite" : "System"), for: .normal)
        if let ink = style.attributes[.foregroundColor] as? UIColor {
            let swatch = UIGraphicsImageRenderer(size: CGSize(width: 28, height: 28)).image { context in
                let rect = CGRect(x: 2, y: 2, width: 24, height: 24)
                context.cgContext.setFillColor(ink.cgColor); context.cgContext.fillEllipse(in: rect)
                context.cgContext.setStrokeColor(UIColor.white.withAlphaComponent(0.5).cgColor)
                context.cgContext.setLineWidth(1); context.cgContext.strokeEllipse(in: rect)
            }.withRenderingMode(.alwaysOriginal)
            buttons["Farbe"]?.setImage(swatch, for: .normal)
        }
        buttons["Markieren"]?.backgroundColor = style.highlighted == true ? UIColor.systemYellow.withAlphaComponent(0.22) : .clear
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
    let objectID: UUID
    weak var historyOwner: TextObjectLayer?
    var onEscape: (() -> Void)?
    var onBold: (() -> Void)?
    var onItalic: (() -> Void)?
    var onUnderline: (() -> Void)?
    var onFlowUndo: ((Bool) -> Void)?
    var onFlowBackspace: (() -> Void)?
    var isFlow = false
    override func scrollRangeToVisible(_ range: NSRange) { /* Outer viewport owns caret reveal. */ }
    override func scrollRectToVisible(_ rect: CGRect, animated: Bool) { }
    override func deleteBackward() {
        if isFlow, selectedRange.location == 0, selectedRange.length == 0 { onFlowBackspace?() }
        else { super.deleteBackward() }
    }
    init(id: UUID) {
        objectID = id
        let storage = NSTextStorage(), manager = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true; container.heightTracksTextView = false
        storage.addLayoutManager(manager); manager.addTextContainer(container)
        super.init(frame: .zero, textContainer: container)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var undoManager: UndoManager? { isFlow ? nil : historyOwner?.textHistory }
    override var keyCommands: [UIKeyCommand]? {
        (super.keyCommands ?? []) + (isFlow ? [
            UIKeyCommand(input: "z", modifierFlags: .command, action: #selector(undoFlow)),
            UIKeyCommand(input: "z", modifierFlags: [.command, .shift], action: #selector(redoFlow))] : []) + [UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(escape)),
            UIKeyCommand(input: "b", modifierFlags: .command, action: #selector(bold)),
            UIKeyCommand(input: "i", modifierFlags: .command, action: #selector(italic)),
            UIKeyCommand(input: "u", modifierFlags: .command, action: #selector(underline))]
    }
    @objc private func undoFlow() { onFlowUndo?(false) }
    @objc private func redoFlow() { onFlowUndo?(true) }
    @objc private func escape() { onEscape?() }
    @objc private func bold() { onBold?() }
    @objc private func italic() { onItalic?() }
    @objc private func underline() { onUnderline?() }
}

@MainActor
private final class TextFieldContainer: UIView {
    let id: UUID
    let editor: PageTextView
    let move = UIView()
    let resize = UIView()
    let delete = UIButton(type: .system)
    var content: TextBox?
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
        [editor, move, resize, delete].forEach { addSubview($0) }
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
        super.layoutSubviews(); editor.frame = bounds
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
        bounds.insetBy(dx: selected && floating ? -48 / displayScale : 0, dy: selected && floating ? -48 / displayScale : 0).contains(point)
    }
}
