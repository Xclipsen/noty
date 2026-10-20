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

@MainActor
final class TextFieldContainer: UIView {
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

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        // Right of the middle beside/below page text: the layer opens a free field there.
        if editor.isFlow, editor.opensFreeField(at: convert(point, to: editor)) { return false }
        return bounds.insetBy(dx: selected && floating ? -48 / displayScale : 0, dy: selected && floating ? -48 / displayScale : 0).contains(point)
    }
}
