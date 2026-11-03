import UIKit
import NotebookCore

/// Persistent forms sit below native ink; editing controls live above it.
@MainActor
final class ShapeObjectLayer: UIView {
    private var shapes: [ShapeObject] = []
    private var pieces: [ShapeInkPiece] = []
    private var origin = PagePoint(x: 0, y: 0)
    override init(frame: CGRect) {
        super.init(frame: frame); isOpaque = false; backgroundColor = .clear; isUserInteractionEnabled = false
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    /// `pieces`: remaining parts of shapes being cut by the precision eraser.
    func configure(_ shapes: [ShapeObject], origin: PagePoint, pieces: [ShapeInkPiece] = []) {
        guard self.shapes != shapes || self.origin != origin || self.pieces != pieces else { return }
        self.shapes = shapes; self.origin = origin; self.pieces = pieces
        isHidden = shapes.isEmpty && pieces.isEmpty; setNeedsDisplay()
    }
    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        ShapeRendering.draw(shapes, origin: origin, context: context)
        context.saveGState(); defer { context.restoreGState() }
        context.translateBy(x: origin.x, y: origin.y)
        for piece in pieces {
            let path = UIBezierPath()
            for (index, point) in piece.points.enumerated() {
                if index == 0 { path.move(to: CGPoint(x: point.x, y: point.y)) } else { path.addLine(to: CGPoint(x: point.x, y: point.y)) }
            }
            piece.color.uiColor.setStroke(); path.lineWidth = piece.width
            path.lineCapStyle = .round; path.lineJoinStyle = .round; path.stroke()
        }
    }
}

/// A remaining part of a shape under the precision eraser (page units).
struct ShapeInkPiece: Equatable {
    var points: [PagePoint]
    var color: InkColor
    var width: Double
}

@MainActor
enum ShapeRendering {
    /// The one path for editor, held preview, thumbnails and PDF. Lines,
    /// arrows (also with corners) and polygons follow `strokeLines`, the
    /// geometry the precision eraser cuts as well.
    static func path(_ shape: ShapeObject) -> UIBezierPath {
        switch shape.kind {
        case .rectangle: return UIBezierPath(rect: shape.frame.cgRect)
        case .ellipse: return UIBezierPath(ovalIn: shape.frame.cgRect)
        case .line, .arrow, .polygon:
            let path = UIBezierPath()
            for line in shape.strokeLines {
                guard let first = line.points.first else { continue }
                path.move(to: CGPoint(x: first.x, y: first.y))
                for point in line.points.dropFirst() { path.addLine(to: CGPoint(x: point.x, y: point.y)) }
                if line.closed { path.close() }
            }
            return path
        }
    }
    static func draw(_ shapes: [ShapeObject], origin: PagePoint, context: CGContext) {
        context.saveGState(); defer { context.restoreGState() }
        context.translateBy(x: origin.x, y: origin.y)
        for shape in shapes {
            let path = path(shape)
            if let fill = shape.fill, shape.isFillable {
                fill.uiColor.setFill(); path.fill()
            }
            shape.color.uiColor.setStroke(); path.lineWidth = shape.lineWidth
            path.lineCapStyle = .round; path.lineJoinStyle = .round
            let dashes = dashes(shape)
            path.setLineDash(dashes, count: dashes.count, phase: 0); path.stroke()
        }
    }
    /// Dash lengths of the stroke pattern (editor, held preview, thumbnails, PDF).
    static func dashes(_ shape: ShapeObject) -> [CGFloat] {
        switch shape.pattern {
        case .solid: []
        case .dashed: [shape.lineWidth * 4, shape.lineWidth * 2.5]
        case .dotted: [0.01, shape.lineWidth * 2.5]
        }
    }
    /// `tolerance`: page units around the drawn stroke, the same ~10 screen
    /// points at any zoom as text and images (callers divide by the zoom).
    static func hit(_ shape: ShapeObject, at point: CGPoint, tolerance: CGFloat) -> Bool {
        // Only a visible fill makes the inside count; unfilled shapes are their stroke.
        if shape.hasVisibleFill, path(shape).contains(point) { return true }
        return path(shape).cgPath.copy(strokingWithWidth: shape.lineWidth + 2 * max(0, tolerance), lineCap: .round,
                                      lineJoin: .round, miterLimit: 4).contains(point)
    }
}

extension InkColor {
    @MainActor var uiColor: UIColor { UIColor(red: red, green: green, blue: blue, alpha: alpha) }
}

extension ShapeKind {
    var title: String { switch self { case .line: "Gerade"; case .arrow: "Pfeil"; case .rectangle: "Rechteck"; case .ellipse: "Ellipse"; case .polygon: "Vieleck" } }
}
extension StrokePattern {
    var title: String { switch self { case .solid: "Durchgezogen"; case .dashed: "Gestrichelt"; case .dotted: "Gepunktet" } }
}

struct ShapeToolOptions: Equatable {
    var kind = ShapeKind.line
    var pattern = StrokePattern.solid
    var filled = false
    /// Own fill colour of new shapes; nil follows the stroke colour.
    var fillColor: InkColor?
    var fillOpacity = ShapeFill.defaultOpacity

    init() {}
    init(preferences: ToolbarPreferences) {
        kind = preferences.shapeKind ?? .line; pattern = preferences.shapePattern ?? .solid
        filled = preferences.shapeFilled ?? false; fillColor = preferences.shapeFillColor
        fillOpacity = preferences.shapeFillOpacity ?? ShapeFill.defaultOpacity
    }
    func store(in preferences: inout ToolbarPreferences) {
        preferences.shapeKind = kind; preferences.shapePattern = pattern; preferences.shapeFilled = filled
        preferences.shapeFillColor = fillColor
        // Untouched default stays absent, so older preference files keep their bytes.
        preferences.shapeFillOpacity = fillOpacity == ShapeFill.defaultOpacity && preferences.shapeFillOpacity == nil ? nil : ShapeFill.rounded(fillOpacity)
    }
    /// Fill of a new shape drawn in `stroke` (nil when the fill is off).
    func fill(stroke: InkColor) -> InkColor? {
        filled ? ShapeFill.color(fillColor ?? stroke, opacity: fillOpacity) : nil
    }
}
