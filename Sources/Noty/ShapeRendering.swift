import UIKit
import NotebookCore

@MainActor
enum ShapeRendering {
    static func path(_ shape: ShapeObject) -> UIBezierPath {
        let path = UIBezierPath()
        switch shape.kind {
        case .rectangle: return UIBezierPath(rect: shape.frame.cgRect)
        case .ellipse: return UIBezierPath(ovalIn: shape.frame.cgRect)
        case .line, .arrow:
            path.move(to: CGPoint(x: shape.start.x, y: shape.start.y))
            path.addLine(to: CGPoint(x: shape.end.x, y: shape.end.y))
            if shape.kind == .arrow {
                let angle = atan2(shape.end.y - shape.start.y, shape.end.x - shape.start.x)
                let length = max(10, shape.lineWidth * 3)
                for side in [-0.5, 0.5] {
                    path.move(to: CGPoint(x: shape.end.x - length * cos(angle + side), y: shape.end.y - length * sin(angle + side)))
                    path.addLine(to: CGPoint(x: shape.end.x, y: shape.end.y))
                }
            }
        }
        return path
    }
    static func draw(_ shapes: [ShapeObject], origin: PagePoint, context: CGContext) {
        context.saveGState(); defer { context.restoreGState() }
        context.translateBy(x: origin.x, y: origin.y)
        for shape in shapes {
            let path = path(shape)
            if let fill = shape.fill, shape.kind == .rectangle || shape.kind == .ellipse {
                fill.uiColor.setFill(); path.fill()
            }
            shape.color.uiColor.setStroke(); path.lineWidth = shape.lineWidth
            path.lineCapStyle = .round; path.lineJoinStyle = .round
            let dashes: [CGFloat] = switch shape.pattern {
            case .solid: []
            case .dashed: [shape.lineWidth * 4, shape.lineWidth * 2.5]
            case .dotted: [0.01, shape.lineWidth * 2.5]
            }
            path.setLineDash(dashes, count: dashes.count, phase: 0); path.stroke()
        }
    }
    static func hit(_ shape: ShapeObject, at point: CGPoint) -> Bool {
        if shape.fill != nil, path(shape).contains(point) { return true }
        return path(shape).cgPath.copy(strokingWithWidth: max(16, shape.lineWidth + 8), lineCap: .round,
                                      lineJoin: .round, miterLimit: 4).contains(point)
    }
}

extension InkColor {
    @MainActor var uiColor: UIColor { UIColor(red: red, green: green, blue: blue, alpha: alpha) }
}

extension ShapeKind {
    var title: String { switch self { case .line: "Gerade"; case .arrow: "Pfeil"; case .rectangle: "Rechteck"; case .ellipse: "Ellipse" } }
}
extension StrokePattern {
    var title: String { switch self { case .solid: "Durchgezogen"; case .dashed: "Gestrichelt"; case .dotted: "Gepunktet" } }
}

struct ShapeToolOptions: Equatable {
    var kind = ShapeKind.line
    var pattern = StrokePattern.solid
    var filled = false
}
