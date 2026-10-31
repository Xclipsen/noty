import UIKit
import NotebookCore

/// Draws a field's text for the visible part only, at the zoomed resolution,
/// through the editor's own layout manager (identical glyph positions). Below
/// the transparent text view, so caret, selection and handles stay on top.
@MainActor
final class TextRasterView: UIView {
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

/// One text field on the page. Textneubau (docs/TEXT-REBUILD-62.md): no
/// icons above the field. While it is being edited it shows a thin frame and
/// four corner points (width only); dragging at the frame (about 20 pt wide
/// zone, mostly outside) moves it, dragging inside the text selects text.
/// Not being edited, only its laid-out text lines take touches: an empty part
/// of the frame reaches through to the field or page below.
@MainActor
final class TextFieldContainer: UIView {
    let id: UUID
    let editor: PageTextView
    /// Corner points while editing (top-left, top-right, bottom-right,
    /// bottom-left): they change only the width; left ones the left edge.
    let widthHandles = (0..<4).map { _ in SelectionHandle() }
    static func changesLeftEdge(_ index: Int) -> Bool { index == 0 || index == 3 }
    private let raster = TextRasterView()
    /// Feldstil (Stufe 4): fill and frame below the text; editing/overflow frame.
    private let styleLayer = CAShapeLayer()
    private let frameLayer = CAShapeLayer()
    /// Padding, corner radius and frame width of the field style in own
    /// units (page points divided by the field's unit scale); 0 without style.
    private(set) var stylePadding: CGFloat = 0
    private var styleRadius: CGFloat = 0
    private var styleLineWidth: CGFloat = 0
    private var styleFilled = false
    private var styleFramed = false
    /// Page points per own point (margin text units).
    private var unitScale: CGFloat = 1
    var content: TextBox?
    var automaticLight: Bool?
    /// This field's part of a selection over several pages (`TextFlowSelection`).
    private var flowHighlight: CAShapeLayer?
    func setFlowHighlight(_ path: CGPath?) {
        guard let path else { flowHighlight?.removeFromSuperlayer(); flowHighlight = nil; return }
        let shape = flowHighlight ?? CAShapeLayer()
        if flowHighlight == nil {
            shape.fillColor = UIColor.systemBlue.withAlphaComponent(0.28).cgColor
            layer.addSublayer(shape); flowHighlight = shape
        }
        shape.frame = editor.frame; shape.path = path
    }
    private(set) var editing = false
    /// Frame drag zone in screen points: outside the frame and inside it.
    static let outerBorder: CGFloat = 14
    static let innerBorder: CGFloat = 6
    init(id: UUID) {
        self.id = id; editor = PageTextView(id: id)
        super.init(frame: .zero)
        clipsToBounds = false
        editor.backgroundColor = .clear; editor.linkTextAttributes = [:]; editor.textContainerInset = .zero
        editor.textContainer.lineFragmentPadding = 0; editor.isScrollEnabled = false
        // Glyphs may reach left of x = 0 (italics, „J“, „f“) and the caret sits
        // on the left edge: never clipped (the text does not scroll).
        editor.clipsToBounds = false
        editor.keyboardAppearance = .dark; editor.overrideUserInterfaceStyle = .dark
        editor.inputAssistantItem.leadingBarButtonGroups = []; editor.inputAssistantItem.trailingBarButtonGroups = []
        editor.accessibilityLabel = "Textfeld"
        editor.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        let labels = ["Textfeldbreite oben links ändern", "Textfeldbreite oben rechts ändern",
                      "Textfeldbreite unten rechts ändern", "Textfeldbreite unten links ändern"]
        for (handle, label) in zip(widthHandles, labels) { handle.accessibilityLabel = label; handle.isHidden = true }
        raster.editor = editor
        (editor.layoutManager as? TaskLayoutManager)?.onDisplayChange = { [weak raster] in raster?.setNeedsDisplay() }
        ([raster, editor] + widthHandles).forEach { addSubview($0) }
        styleLayer.actions = ["path": NSNull(), "fillColor": NSNull(), "strokeColor": NSNull(), "lineWidth": NSNull(), "hidden": NSNull()]
        frameLayer.actions = styleLayer.actions
        layer.insertSublayer(styleLayer, at: 0)
        frameLayer.fillColor = UIColor.clear.cgColor; frameLayer.isHidden = true
        layer.insertSublayer(frameLayer, below: widthHandles[0].layer)
        accessibilityLabel = "Textfeld"
    }
    /// The visible field in own coordinates: the text frame plus the style's padding.
    var styleRect: CGRect { bounds.insetBy(dx: -stylePadding, dy: -stylePadding) }
    /// The editing frame: the visible field widened by the same
    /// screen-constant gap as every selection (`SelectionOutline.gap`, the
    /// selected field's frame in `ObjectEditingLayer`), in own units.
    var selectionGap: CGFloat {
        let pageScale = displayScale / unitScale
        return CGFloat(SelectionOutline.gap(displayScale: Double(pageScale))) / unitScale
    }
    var selectionRect: CGRect { styleRect.insetBy(dx: -selectionGap, dy: -selectionGap) }
    /// Room beyond the frame where glyphs may still draw (italic overhang).
    var glyphOverhang: CGFloat { content.map(TextObjectLayout.glyphOverhang) ?? 4 }
    /// Feldstil from the resolved box (automatic colours as shown);
    /// `unitScale`: page points per own point (margin text units).
    private var appliedStyle: (TextFieldFill?, TextFieldBorder?, TextColor, InkColor?, CGFloat)?
    func applyFieldStyle(_ resolved: TextBox, unitScale: CGFloat) {
        let scale = max(0.001, unitScale)
        if self.unitScale != scale { self.unitScale = scale; setNeedsLayout() }
        if let applied = appliedStyle, applied.0 == resolved.fill, applied.1 == resolved.border,
           applied.2 == resolved.style.color, applied.3 == resolved.style.ink, applied.4 == scale { return }
        appliedStyle = (resolved.fill, resolved.border, resolved.style.color, resolved.style.ink, scale)
        stylePadding = CGFloat(resolved.fieldPadding) / scale
        styleRadius = CGFloat(TextBox.fieldCornerRadius) / scale
        styleLineWidth = CGFloat(TextBox.fieldBorderWidth) / scale
        styleFilled = resolved.fill != nil
        styleFramed = resolved.border != nil
        styleLayer.fillColor = resolved.fill?.uiColor.cgColor ?? UIColor.clear.cgColor
        styleLayer.strokeColor = TextFieldStyleRendering.borderColor(resolved)?.cgColor
        styleLayer.isHidden = !resolved.hasFieldStyle
        accessibilityValue = resolved.fill.map { "Füllung \($0.title)" }
        setNeedsLayout()
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
    func configure(editing: Bool, overflowing: Bool) {
        self.editing = editing
        frameLayer.isHidden = !(editing || overflowing)
        frameLayer.strokeColor = (overflowing ? UIColor.systemRed : SelectionStyle.color).cgColor
        widthHandles.forEach { $0.isHidden = !editing }
        setNeedsLayout()
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        if editor.frame != bounds { editor.frame = bounds; raster.setNeedsDisplay() }
        let scale = displayScale
        for control in widthHandles {
            control.bounds = CGRect(x: 0, y: 0, width: 44, height: 44)
            control.transform = CGAffineTransform(scaleX: 1 / scale, y: 1 / scale)
        }
        let visible = styleRect, selection = selectionRect
        let corners = [CGPoint(x: selection.minX, y: selection.minY), CGPoint(x: selection.maxX, y: selection.minY),
                       CGPoint(x: selection.maxX, y: selection.maxY), CGPoint(x: selection.minX, y: selection.maxY)]
        for (handle, corner) in zip(widthHandles, corners) { handle.center = corner }
        frameLayer.frame = bounds
        let gap = selectionGap
        frameLayer.path = CGPath(roundedRect: selection, cornerWidth: gap, cornerHeight: gap, transform: nil)
        frameLayer.lineWidth = SelectionStyle.lineWidth / scale
        styleLayer.frame = bounds
        if !styleLayer.isHidden {
            // Stroked inside the visible edge like the PDF (`TextFieldStyleRendering.draw`).
            let inset = styleFramed ? styleLineWidth / 2 : 0
            let rect = visible.insetBy(dx: inset, dy: inset)
            let radius = max(0, min(styleRadius - inset, rect.width / 2, rect.height / 2))
            styleLayer.path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
            styleLayer.lineWidth = styleFramed ? styleLineWidth : 0
        }
    }
    /// Screen points per own point (zoom, field units, not the rotation).
    var displayScale: CGFloat {
        guard let window else { return 1 }
        let a = convert(CGPoint.zero, to: window), b = convert(CGPoint(x: 100, y: 0), to: window)
        return max(0.001, hypot(b.x - a.x, b.y - a.y) / 100)
    }
    /// In the frame drag zone (own coordinates) while editing.
    func inBorderZone(_ point: CGPoint) -> Bool {
        guard editing else { return false }
        let scale = displayScale
        let outer = selectionRect.insetBy(dx: -Self.outerBorder / scale, dy: -Self.outerBorder / scale)
        let inner = bounds.insetBy(dx: min(bounds.width / 3, Self.innerBorder / scale), dy: min(bounds.height / 3, Self.innerBorder / scale))
        return outer.contains(point) && !inner.contains(point)
    }
    /// Touch slack around text lines (about 8 screen points).
    var lineSlack: CGFloat { 8 / displayScale }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        if editing {
            let scale = displayScale
            if widthHandles.contains(where: { !$0.isHidden && $0.frame.contains(point) }) { return true }
            return selectionRect.insetBy(dx: -Self.outerBorder / scale, dy: -Self.outerBorder / scale).contains(point)
        }
        // A filled field takes its whole surface, a framed one its frame line
        // (like shapes); otherwise only real text lines, the empty rest of the
        // frame reaches through.
        let slack = lineSlack, visible = styleRect
        if styleFilled, visible.insetBy(dx: -slack, dy: -slack).contains(point) { return true }
        if styleFramed, visible.insetBy(dx: -slack, dy: -slack).contains(point),
           !visible.insetBy(dx: min(slack, visible.width / 2), dy: min(slack, visible.height / 2)).contains(point) { return true }
        return editor.hitsLine(at: convert(point, to: editor), slack: slack)
    }
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard self.point(inside: point, with: event), isUserInteractionEnabled, !isHidden else { return nil }
        for handle in widthHandles where !handle.isHidden && handle.frame.contains(point) { return handle }
        // The frame zone belongs to the move drag, not to text selection.
        if inBorderZone(point) { return self }
        // Padding of a styled field (not being edited): the text view sets the
        // caret at the nearest place, like a tap on its text.
        if !editing, !bounds.contains(point), !editor.isHidden { return editor }
        return super.hitTest(point, with: event)
    }
}

/// The frame-zone drag of a field: only touches whose hit view is the
/// container itself (its border zone, `TextFieldContainer.hitTest`), never
/// text selection inside it; wins over notebook scrolling.
final class FieldBorderDrag: NSObject, UIGestureRecognizerDelegate {
    static let shared = FieldBorderDrag()
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        touch.view === gestureRecognizer.view
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
        ScrollPanPriority.outranksScrolling(gestureRecognizer, other)
    }
}

/// „Neue Felder übernehmen den zuletzt benutzten Stil; Formatierung entfernen
/// führt zurück“: the character style of the last formatting change (font,
/// size, bold/italic, colour). Emphasis of single words (marker, underline,
/// strikethrough, links, raised text) and paragraph settings stay behind.
@MainActor
enum TextStyleMemory {
    private static let key = "noty.text.lastStyle"
    static func remember(_ style: TextBoxStyle) {
        var kept = TextBoxStyle(font: style.font, fontSize: style.fontSize, bold: style.bold, italic: style.italic, color: style.color)
        kept.fontName = style.fontName; kept.ink = style.ink; kept.automaticColor = style.automaticColor
        guard (try? kept.validate()) != nil, let data = try? JSONEncoder().encode(kept) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
    /// Style of a new field; `light`: automatic colour on a dark background.
    static func style(light: Bool) -> TextBoxStyle {
        if let data = UserDefaults.standard.data(forKey: key), var style = try? JSONDecoder().decode(TextBoxStyle.self, from: data),
           (try? style.validate()) != nil {
            if style.automaticColor == true { style.color = light ? .white : .black; style.ink = nil }
            return style
        }
        return TextBoxStyle().clearingCharacterFormatting(light: light)
    }
}
