import SwiftUI
import NotebookCore

/// Tool glyph after the „Werkzeug-Icons“ design: duotone vectors on a 32-unit
/// grid (outline, translucent body, secondary parts, solid details, white glass
/// highlight) in `tint`. The selected state is drawn by the cell
/// (`NotyToolSelection`), so `selected` leaves the glyph unchanged.
struct ToolbarGlyph: View {
    let tool: WritingTool
    var selected = false
    var tint: Color = .white
    /// Marker glyph shows the chosen tip (round nib or chisel).
    var markerTip: MarkerTip = .round
    var body: some View {
        Canvas { context, size in
            NotyGlyphArt.draw(tool, roundTip: markerTip == .round, with: GlyphPainter(context, size: size, tint: tint))
        }
        .frame(width: 28, height: 28)
        .shadow(color: .black.opacity(0.45), radius: 1, x: 0, y: 1)
    }
}

/// Undo/redo glyph from the same design. Draws into the square frame it is
/// given (intended 26 × 26).
struct NotyActionGlyph: View {
    enum Kind { case undo, redo }
    let kind: Kind
    var tint: Color = .white
    var body: some View {
        Canvas { context, size in
            let g = GlyphPainter(context, size: size, tint: tint)
            switch kind {
            case .undo: NotyGlyphArt.undo(g)
            case .redo: NotyGlyphArt.redo(g)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .shadow(color: .black.opacity(0.45), radius: 1, x: 0, y: 1)
    }
}

/// Selected tool cell after the design: accent fill and edge, a fine top sheen
/// and a soft glow small enough to stay inside the 48-pt toolbar cell.
struct NotyToolSelection<S: InsettableShape>: View {
    let shape: S
    var body: some View {
        let accent = Color(red: 125 / 255, green: 211 / 255, blue: 252 / 255)
        shape.fill(accent.opacity(0.26))
            .overlay { shape.strokeBorder(accent.opacity(0.62), lineWidth: 1) }
            .overlay {
                shape.inset(by: 1).strokeBorder(LinearGradient(colors: [.white.opacity(0.34), .white.opacity(0)],
                                                               startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.3)), lineWidth: 1)
            }
            .shadow(color: accent.opacity(0.45), radius: 3)
    }
}

/// Paint roles of the design's CSS classes (`.b` body, `.s` secondary,
/// `.f` solid, `.hl` highlight) plus the fixed colours it uses.
private enum GlyphPaint { case body, secondary, solid, highlight, white, marker, shade }

/// Draws paths given in the design's 32-unit grid, scaled into the canvas.
private struct GlyphPainter {
    private var context: GraphicsContext
    private let tint: Color

    init(_ context: GraphicsContext, size: CGSize, tint: Color) {
        let side = min(size.width, size.height)
        var context = context
        context.translateBy(x: (size.width - side) / 2, y: (size.height - side) / 2)
        context.scaleBy(x: side / 32, y: side / 32)
        self.context = context
        self.tint = tint
    }

    private func color(_ paint: GlyphPaint) -> Color {
        switch paint {
        case .body: tint.opacity(0.2)
        case .secondary: tint.opacity(0.62)
        case .solid: tint
        case .highlight: Color.white.opacity(0.55)
        case .white: Color.white
        case .marker: Color(red: 253 / 255, green: 224 / 255, blue: 71 / 255)
        case .shade: Color(red: 11 / 255, green: 18 / 255, blue: 32 / 255)
        }
    }

    /// `.o` outline over a fill role (`class="o b"` / `"o s"`).
    func shape(_ path: Path, _ paint: GlyphPaint) {
        fill(path, paint)
        stroke(path, 1.8)
    }

    func fill(_ path: Path, _ paint: GlyphPaint) {
        context.fill(path, with: .color(color(paint)))
    }

    func stroke(_ path: Path, _ width: CGFloat, paint: GlyphPaint = .solid, opacity: Double = 1,
                cap: CGLineCap = .round, dash: [CGFloat] = []) {
        context.stroke(path, with: .color(color(paint).opacity(opacity)),
                       style: StrokeStyle(lineWidth: width, lineCap: cap, lineJoin: .round, dash: dash))
    }

    /// Fill fading in from transparent at `start` to `opacity` at `end`.
    func fade(_ path: Path, start: (CGFloat, CGFloat), end: (CGFloat, CGFloat), opacity: Double) {
        let gradient = Gradient(colors: [tint.opacity(0), tint.opacity(opacity)])
        context.fill(path, with: .linearGradient(gradient, startPoint: CGPoint(x: start.0, y: start.1),
                                                 endPoint: CGPoint(x: end.0, y: end.1)))
    }

    /// SVG `rotate(degrees x y)`; the default pivot is the grid centre.
    func rotated(_ degrees: Double, _ x: CGFloat = 16, _ y: CGFloat = 16) -> GlyphPainter {
        var copy = self
        copy.context.translateBy(x: x, y: y)
        copy.context.rotate(by: .degrees(degrees))
        copy.context.translateBy(x: -x, y: -y)
        return copy
    }
}

/// SVG-like path segments in design units. `.arc(cornerX, cornerY, endX, endY,
/// radius)` is a tangent arc (`Path.addArc(tangent1End:tangent2End:radius:)`)
/// that also draws the straight run up to the corner's rounding.
private enum GlyphSegment {
    case m(CGFloat, CGFloat), l(CGFloat, CGFloat), c(CGFloat, CGFloat, CGFloat, CGFloat, CGFloat, CGFloat)
    case arc(CGFloat, CGFloat, CGFloat, CGFloat, CGFloat), z
}

/// Glyph geometry. Design symbols (`g-…`) were converted from the SVG mockup;
/// pencil, laser and the round marker nib are drawn in the same style.
private enum NotyGlyphArt {
    static func draw(_ tool: WritingTool, roundTip: Bool, with g: GlyphPainter) {
        switch tool {
        case .pen: pen(g)
        case .pencil: pencil(g)
        case .marker: marker(g, roundTip: roundTip)
        case .strokeEraser: eraser(g)
        case .precisionEraser: precisionEraser(g)
        case .inkSelection: lasso(g)
        case .selection: select(g)
        case .text: text(g)
        case .shape: shapes(g)
        case .image: image(g)
        case .read: read(g)
        case .laser: laser(g)
        }
    }

    // MARK: Glyphs

    /// g-pen
    static func pen(_ g: GlyphPainter) {
        let r = g.rotated(45)
        r.shape(poly(12, 9.5, 20, 9.5, 20, 22, 12, 22), .body)
        r.shape(poly(12, 22, 20, 22, 16, 29), .secondary)
        r.fill(poly(14.8, 26.8, 16, 29, 17.2, 26.8), .solid)
        r.shape(path(.m(12, 9.5), .arc(12, 2.4, 13.8, 2.4, 1.8), .arc(20, 2.4, 20, 4.2, 1.8), .l(20, 9.5), .z), .secondary)
        r.stroke(line(12, 7.2, 20, 7.2), 1.4, cap: .butt)
        r.fill(rect(13.6, 11, 1.6, 9, r: 0.8), .highlight)
    }

    /// Own design in the pen's pose: sharpened wooden cone with graphite tip,
    /// lacquered barrel with two facet edges and a scalloped sharpening line,
    /// bright metal ferrule and a rounded eraser.
    static func pencil(_ g: GlyphPainter) {
        let r = g.rotated(45)
        r.shape(path(.m(12, 20), .c(12.9, 21.4, 13.8, 21.4, 14.67, 20), .c(15.5, 21.4, 16.5, 21.4, 17.33, 20),
                     .c(18.2, 21.4, 19.1, 21.4, 20, 20), .l(16, 29.6), .z), .body)
        r.fill(poly(14.25, 25.4, 17.75, 25.4, 16, 29.6), .solid)
        r.shape(path(.m(12, 9.6), .l(20, 9.6), .l(20, 20), .c(19.1, 21.4, 18.2, 21.4, 17.33, 20),
                     .c(16.5, 21.4, 15.5, 21.4, 14.67, 20), .c(13.8, 21.4, 12.9, 21.4, 12, 20), .z), .secondary)
        r.stroke(line(14.67, 10.6, 14.67, 19.2), 1, paint: .shade, opacity: 0.45)
        r.stroke(line(17.33, 10.6, 17.33, 19.2), 1, paint: .shade, opacity: 0.45)
        r.shape(rect(12, 6.6, 8, 3), .solid)
        r.stroke(line(12, 8.1, 20, 8.1), 1, paint: .shade, opacity: 0.5, cap: .butt)
        r.shape(path(.m(12, 6.6), .arc(12, 2.2, 14.8, 2.2, 2.8), .arc(20, 2.2, 20, 5, 2.8), .l(20, 6.6), .z), .body)
    }

    /// g-marker; the round variant (own design) swaps the chisel for a bullet nib.
    static func marker(_ g: GlyphPainter, roundTip: Bool) {
        let r = g.rotated(45)
        r.shape(poly(11, 10, 21, 10, 21, 24, 11, 24), .body)
        r.shape(path(.m(10.4, 10), .arc(10.4, 2.2, 12.2, 2.2, 1.8), .arc(21.6, 2.2, 21.6, 4, 1.8), .l(21.6, 10), .z), .secondary)
        if roundTip { roundNib(r) } else { chiselNib(r) }
        r.fill(rect(12.8, 11.6, 1.8, 10, r: 0.9), .highlight)
        g.stroke(path(.m(3.5, 28.5), .c(8, 27.5, 12, 27.5, 16, 28.5)), 3.6, paint: .marker, opacity: 0.9)
    }

    private static func chiselNib(_ r: GlyphPainter) {
        r.shape(poly(11, 24, 21, 24, 19, 29, 13, 29), .secondary)
        r.stroke(line(13, 29, 19, 29), 2.2)
    }

    private static func roundNib(_ r: GlyphPainter) {
        r.shape(poly(11, 24, 21, 24, 19.4, 26.4, 12.6, 26.4), .secondary)
        r.shape(path(.m(13, 26.4), .arc(13, 29.4, 16, 29.4, 3), .arc(19, 29.4, 19, 26.4, 3), .z), .solid)
    }

    /// g-eraser
    static func eraser(_ g: GlyphPainter) {
        let r = g.rotated(-40)
        r.shape(path(.m(6, 12), .arc(6, 10, 8, 10, 2), .l(16, 10), .l(16, 22), .arc(6, 22, 6, 20, 2), .z), .body)
        r.shape(path(.m(16, 10), .arc(26, 10, 26, 12, 2), .arc(26, 22, 24, 22, 2), .l(16, 22), .z), .secondary)
        r.fill(rect(8.4, 12, 6.6, 2.2, r: 1.1), .highlight)
        g.stroke(path(.m(4, 27.5), .l(8, 27.5), .m(11, 29), .l(14, 29)), 1.8, opacity: 0.6)
    }

    /// g-peraser
    static func precisionEraser(_ g: GlyphPainter) {
        let r = g.rotated(45)
        r.shape(poly(12.5, 5, 19.5, 5, 19.5, 21, 12.5, 21), .body)
        r.shape(path(.m(12.5, 5), .arc(12.5, 1.4, 14.1, 1.4, 1.6), .arc(19.5, 1.4, 19.5, 3, 1.6), .l(19.5, 5), .z), .secondary)
        r.shape(poly(12.5, 21, 19.5, 21, 17.5, 26, 14.5, 26), .secondary)
        r.fill(rect(14, 6.5, 1.5, 11, r: 0.75), .highlight)
        g.shape(circle(8.2, 23.8, 5), .body)
        g.fill(circle(8.2, 23.8, 1.5), .solid)
        g.stroke(path(.m(8.2, 16.2), .l(8.2, 18), .m(8.2, 29.6), .l(8.2, 31.4), .m(0.6, 23.8), .l(2.4, 23.8),
                      .m(14, 23.8), .l(15.8, 23.8)), 1.6)
    }

    /// g-lasso
    static func lasso(_ g: GlyphPainter) {
        g.fill(ellipse(16, 12, 11, 7), .body)
        g.stroke(ellipse(16, 12, 11, 7), 2.2, cap: .butt, dash: [4, 2.6])
        g.stroke(path(.m(10.5, 18), .c(9, 21, 10.5, 23, 13, 24), .c(15.5, 25, 15.5, 27.5, 13.5, 29.5)), 2.2)
        g.fill(circle(10.6, 18.4, 2.4), .solid)
        g.stroke(path(.m(8.5, 8.6), .c(10.5, 7.2, 13, 6.4, 16, 6.4)), 1.3, paint: .white, opacity: 0.6)
    }

    /// g-text
    static func text(_ g: GlyphPainter) {
        g.shape(path(.m(4, 5), .arc(25.5, 5, 25.5, 6.5, 1.5), .arc(25.5, 12, 24, 12, 1.5), .l(17.5, 12),
                     .arc(17.5, 27.5, 16, 27.5, 1.5), .arc(10.5, 27.5, 10.5, 26, 1.5), .l(10.5, 12),
                     .arc(2.5, 12, 2.5, 10.5, 1.5), .arc(2.5, 5, 4, 5, 1.5), .z), .body)
        g.fill(rect(5, 6.8, 8, 2, r: 1), .highlight)
        g.stroke(line(27.5, 15, 27.5, 28), 2.2)
        g.stroke(path(.m(25.3, 15), .l(29.7, 15), .m(25.3, 28), .l(29.7, 28)), 1.8)
    }

    /// g-select
    static func select(_ g: GlyphPainter) {
        g.fill(rect(4, 4, 18, 18, r: 2.5), .body)
        g.stroke(rect(4, 4, 18, 18, r: 2.5), 1.8, cap: .butt, dash: [3.2, 3])
        g.fill(rect(2, 2, 5, 5, r: 1.3), .solid)
        g.fill(rect(19, 2, 5, 5, r: 1.3), .solid)
        g.fill(rect(2, 19, 5, 5, r: 1.3), .solid)
        g.shape(poly(15.5, 15.5, 29, 20.5, 23.2, 23.2, 20.5, 29), .secondary)
    }

    /// g-shape
    static func shapes(_ g: GlyphPainter) {
        g.shape(circle(10.5, 10.5, 7.5), .body)
        g.shape(poly(21, 4, 29.5, 19, 12.5, 19), .body)
        g.shape(rect(10, 16, 13, 13, r: 3), .secondary)
        g.rotated(-30, 8, 7.6).fill(ellipse(8, 7.6, 2.2, 1.3), .highlight)
    }

    /// g-image
    static func image(_ g: GlyphPainter) {
        let r = g.rotated(-6)
        r.shape(rect(4, 3.5, 24, 25, r: 2.5), .body)
        r.stroke(rect(6.5, 6, 19, 15, r: 1), 1.4)
        r.fill(circle(20.5, 10.5, 2.3), .solid)
        r.fill(poly(6.5, 21, 6.5, 17.5, 11.5, 12.5, 15.5, 16.5, 18.5, 14, 25.5, 19.5, 25.5, 21), .secondary)
        r.fill(rect(8, 7.5, 6, 1.8, r: 0.9), .highlight)
    }

    /// g-read
    static func read(_ g: GlyphPainter) {
        g.shape(path(.m(16, 9), .c(13, 6.5, 9, 5.8, 4, 6.5), .l(4, 25), .c(9, 24.3, 13, 25, 16, 27.5), .z), .secondary)
        g.shape(path(.m(16, 9), .c(19, 6.5, 23, 5.8, 28, 6.5), .l(28, 25), .c(23, 24.3, 19, 25, 16, 27.5), .z), .body)
        g.stroke(path(.m(7, 11), .c(9.5, 11, 11.5, 11.5, 13.5, 12.6), .m(7, 15), .c(9.5, 15, 11.5, 15.5, 13.5, 16.6),
                      .m(7, 19), .c(9.5, 19, 11.5, 19.5, 13.5, 20.6)), 1.4, paint: .shade, opacity: 0.55)
        g.stroke(path(.m(25, 11), .c(22.5, 11, 20.5, 11.5, 18.5, 12.6), .m(25, 15), .c(22.5, 15, 20.5, 15.5, 18.5, 16.6)),
                 1.4, opacity: 0.6)
    }

    /// Own design, like the in-app laser: wide glow, halo and bright core with a
    /// trail fading out towards the lower left.
    static func laser(_ g: GlyphPainter) {
        g.fade(path(.m(3, 29), .l(17.2, 9.2), .l(22.8, 14.8), .z), start: (4, 28), end: (17, 15), opacity: 0.85)
        g.fill(circle(20, 12, 9), .body)
        g.fill(circle(20, 12, 6), .secondary)
        g.fill(circle(20, 12, 3.4), .solid)
    }

    /// g-undo
    static func undo(_ g: GlyphPainter) {
        g.stroke(path(.m(9, 12.5), .arc(26, 12.5, 26, 19, 6.5), .arc(26, 25.5, 19.5, 25.5, 6.5), .l(13, 25.5)), 2.6)
        g.shape(poly(11.5, 5.5, 4, 12.5, 11.5, 19.5), .secondary)
        g.stroke(path(.m(19.5, 15.5), .arc(23, 15.5, 23, 19, 3.5), .arc(23, 22.5, 19.5, 22.5, 3.5)), 1.4, opacity: 0.4)
    }

    /// g-redo
    static func redo(_ g: GlyphPainter) {
        g.stroke(path(.m(23, 12.5), .arc(6, 12.5, 6, 19, 6.5), .arc(6, 25.5, 12.5, 25.5, 6.5), .l(19, 25.5)), 2.6)
        g.shape(poly(20.5, 5.5, 28, 12.5, 20.5, 19.5), .secondary)
        g.stroke(path(.m(12.5, 15.5), .arc(9, 15.5, 9, 19, 3.5), .arc(9, 22.5, 12.5, 22.5, 3.5)), 1.4, opacity: 0.4)
    }

    // MARK: Path helpers (design units)

    static func path(_ segments: GlyphSegment...) -> Path {
        Path { p in
            for segment in segments {
                switch segment {
                case let .m(x, y): p.move(to: CGPoint(x: x, y: y))
                case let .l(x, y): p.addLine(to: CGPoint(x: x, y: y))
                case let .c(x1, y1, x2, y2, x, y):
                    p.addCurve(to: CGPoint(x: x, y: y), control1: CGPoint(x: x1, y: y1), control2: CGPoint(x: x2, y: y2))
                case let .arc(cx, cy, x, y, r):
                    p.addArc(tangent1End: CGPoint(x: cx, y: cy), tangent2End: CGPoint(x: x, y: y), radius: r)
                case .z: p.closeSubpath()
                }
            }
        }
    }

    /// Open polyline through x, y pairs.
    static func line(_ xy: CGFloat...) -> Path {
        var p = Path()
        p.addLines(points(xy))
        return p
    }

    /// Closed polygon through x, y pairs.
    static func poly(_ xy: CGFloat...) -> Path {
        var p = Path()
        p.addLines(points(xy))
        p.closeSubpath()
        return p
    }

    static func rect(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat, r: CGFloat = 0) -> Path {
        Path(roundedRect: CGRect(x: x, y: y, width: width, height: height), cornerRadius: r, style: .circular)
    }

    static func circle(_ x: CGFloat, _ y: CGFloat, _ radius: CGFloat) -> Path { ellipse(x, y, radius, radius) }

    static func ellipse(_ x: CGFloat, _ y: CGFloat, _ rx: CGFloat, _ ry: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: x - rx, y: y - ry, width: 2 * rx, height: 2 * ry))
    }

    private static func points(_ xy: [CGFloat]) -> [CGPoint] {
        stride(from: 0, to: xy.count - 1, by: 2).map { CGPoint(x: xy[$0], y: xy[$0 + 1]) }
    }
}
