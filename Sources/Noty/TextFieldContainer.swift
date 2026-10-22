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
/// one width point left and right; dragging at the frame (about 20 pt wide
/// zone, mostly outside) moves it, dragging inside the text selects text.
/// Not being edited, only its laid-out text lines take touches: an empty part
/// of the frame reaches through to the field or page below.
@MainActor
final class TextFieldContainer: UIView {
    let id: UUID
    let editor: PageTextView
    /// Width points (left, right) while editing.
    let leftWidth = UIView()
    let rightWidth = UIView()
    private let raster = TextRasterView()
    var content: TextBox?
    var automaticLight: Bool?
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
        editor.keyboardAppearance = .dark; editor.overrideUserInterfaceStyle = .dark
        editor.inputAssistantItem.leadingBarButtonGroups = []; editor.inputAssistantItem.trailingBarButtonGroups = []
        editor.accessibilityLabel = "Textfeld"
        editor.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        for (handle, label) in [(leftWidth, "Textfeldbreite links ändern"), (rightWidth, "Textfeldbreite rechts ändern")] {
            handle.backgroundColor = .clear; handle.isAccessibilityElement = true; handle.accessibilityLabel = label
            let dot = UIView(frame: CGRect(x: 16, y: 16, width: 12, height: 12))
            dot.backgroundColor = .systemBlue; dot.layer.cornerRadius = 6; dot.isUserInteractionEnabled = false
            dot.layer.borderColor = UIColor.white.cgColor; dot.layer.borderWidth = 1.5
            handle.addSubview(dot); handle.isHidden = true
        }
        raster.editor = editor
        (editor.layoutManager as? TaskLayoutManager)?.onDisplayChange = { [weak raster] in raster?.setNeedsDisplay() }
        [raster, editor, leftWidth, rightWidth].forEach { addSubview($0) }
        accessibilityLabel = "Textfeld"
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
        layer.borderWidth = editing || overflowing ? 1 : 0
        layer.borderColor = (overflowing ? UIColor.systemRed : .systemBlue).cgColor
        [leftWidth, rightWidth].forEach { $0.isHidden = !editing }
        setNeedsLayout()
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        if editor.frame != bounds { editor.frame = bounds; raster.setNeedsDisplay() }
        let scale = displayScale
        for control in [leftWidth, rightWidth] {
            control.bounds = CGRect(x: 0, y: 0, width: 44, height: 44)
            control.transform = CGAffineTransform(scaleX: 1 / scale, y: 1 / scale)
        }
        leftWidth.center = CGPoint(x: 0, y: bounds.midY)
        rightWidth.center = CGPoint(x: bounds.width, y: bounds.midY)
        if layer.borderWidth > 0 { layer.borderWidth = 1 / scale }
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
        let outer = bounds.insetBy(dx: -Self.outerBorder / scale, dy: -Self.outerBorder / scale)
        let inner = bounds.insetBy(dx: min(bounds.width / 3, Self.innerBorder / scale), dy: min(bounds.height / 3, Self.innerBorder / scale))
        return outer.contains(point) && !inner.contains(point)
    }
    /// Touch slack around text lines (about 8 screen points).
    var lineSlack: CGFloat { 8 / displayScale }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        if editing {
            let scale = displayScale
            if !leftWidth.isHidden, leftWidth.frame.contains(point) || rightWidth.frame.contains(point) { return true }
            return bounds.insetBy(dx: -Self.outerBorder / scale, dy: -Self.outerBorder / scale).contains(point)
        }
        // Only real text lines; the empty rest of the frame reaches through.
        return editor.hitsLine(at: convert(point, to: editor), slack: lineSlack)
    }
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard self.point(inside: point, with: event), isUserInteractionEnabled, !isHidden else { return nil }
        for handle in [leftWidth, rightWidth] where !handle.isHidden && handle.frame.contains(point) { return handle }
        // The frame zone belongs to the move drag, not to text selection.
        if inBorderZone(point) { return self }
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
