import SwiftUI
import NotebookCore

/// Outline silhouettes follow the supplied references, drawn as native vectors.
struct ToolbarGlyph: View {
    let tool: WritingTool
    var selected = false
    var tint: Color = .white
    /// Marker glyph shows the chosen tip (round nib or chisel).
    var markerTip: MarkerTip = .round
    private var sheen: LinearGradient {
        LinearGradient(colors: [tint, selected ? Color(red: 0.62, green: 0.84, blue: 1) : tint.opacity(0.74)], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
    var body: some View {
        Group {
            switch tool {
            case .pen, .pencil, .marker, .strokeEraser, .precisionEraser:
                WritingGlyph(kind: tool, roundTip: markerTip == .round).stroke(sheen, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                    .frame(width: 26, height: 26)
            case .laser: LaserGlyph(sheen: sheen, tint: tint).frame(width: 26, height: 26)
            case .text: Text("Tt").font(.system(size: 23, weight: .medium, design: .rounded)).foregroundStyle(sheen)
            case .selection:
                RoundedRectangle(cornerRadius: 2).stroke(sheen, style: StrokeStyle(lineWidth: 1.4, dash: [3, 3]))
                    .frame(width: 23, height: 23)
                    .overlay {
                        ForEach(0..<4) { index in
                            RoundedRectangle(cornerRadius: 1).fill(sheen).frame(width: 3, height: 3)
                                .offset(x: index.isMultiple(of: 2) ? -11 : 11, y: index < 2 ? -11 : 11)
                        }
                    }
            default:
                Image(systemName: tool == .image ? "plus.circle" : tool.symbol)
                    .font(.system(size: 23, weight: .regular)).symbolRenderingMode(.hierarchical).foregroundStyle(sheen)
            }
        }.shadow(color: .black.opacity(0.4), radius: 0.7, x: 0, y: 1)
    }
}

private struct WritingGlyph: Shape {
    let kind: WritingTool
    var roundTip = false
    func path(in rect: CGRect) -> Path {
        var path = Path()
        func line(_ points: [(Double, Double)], close: Bool = false) {
            guard let first = points.first else { return }
            func point(_ value: (Double, Double)) -> CGPoint { CGPoint(x: rect.minX + value.0 / 32 * rect.width, y: rect.minY + value.1 / 32 * rect.height) }
            path.move(to: point(first))
            for value in points.dropFirst() { path.addLine(to: point(value)) }
            if close { path.closeSubpath() }
        }
        switch kind {
        case .pen:
            line([(3,29),(5,21),(21,5),(28,12),(12,28)], close: true)
            line([(21,5),(24,2),(31,9),(28,12)])
            line([(5,21),(12,28)]); line([(4,26),(6,28)]); line([(9,19),(23,5)])
        case .pencil:
            // Sharpened cone with lead, faceted body, ferrule and eraser.
            line([(6,20),(3,29),(12,26)]); line([(4,26),(6,28)]); line([(6,20),(12,26)])
            line([(6,20),(21,5)]); line([(12,26),(27,11)]); line([(9,23),(22,10)])
            line([(19,7),(25,13)]); line([(21,5),(23,3),(29,9),(27,11)])
        case .marker:
            line([(5,20),(20,5),(29,14),(14,29)], close: true)
            if roundTip {
                // Neck narrowing to a round nib centred at (7, 27).
                let nib: [(Double, Double)] = stride(from: 45.0, through: 225.0, by: 22.5).map { (degrees: Double) -> (Double, Double) in
                    let angle = degrees * Double.pi / 180
                    return (7 + 2.2 * cos(angle), 27 + 2.2 * sin(angle))
                }
                let outline: [(Double, Double)] = [(5, 20), (14, 29)]
                line(outline + nib, close: true)
            } else {
                line([(5,20),(14,29),(11,31),(3,27),(2,24)], close: true)
            }
            line([(9,16),(18,25)]); line([(18,7),(27,16)])
        default:
            line([(3,21),(17,5),(29,16),(17,30),(12,30)], close: true)
            line([(9,14),(22,25)])
        }
        return path
    }
}

/// Glowing dot with a fading trail.
private struct LaserGlyph: View {
    let sheen: LinearGradient
    let tint: Color
    var body: some View {
        GeometryReader { proxy in
            let s = proxy.size.width / 32
            ZStack {
                Path { path in
                    path.move(to: CGPoint(x: 3 * s, y: 28 * s))
                    path.addQuadCurve(to: CGPoint(x: 16 * s, y: 16 * s), control: CGPoint(x: 6 * s, y: 15 * s))
                }.stroke(LinearGradient(colors: [tint.opacity(0.08), tint.opacity(0.9)], startPoint: .bottomLeading, endPoint: .topTrailing),
                         style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
                Circle().stroke(sheen, lineWidth: 1.4).frame(width: 14 * s, height: 14 * s).position(x: 22 * s, y: 10 * s)
                Circle().fill(sheen).frame(width: 6 * s, height: 6 * s).position(x: 22 * s, y: 10 * s)
            }
        }
    }
}
