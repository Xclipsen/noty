import SwiftUI
import NotebookCore

/// Outline silhouettes follow the supplied references, drawn as native vectors.
struct ToolbarGlyph: View {
    let tool: WritingTool
    var selected = false
    var tint: Color = .white
    private var sheen: LinearGradient {
        LinearGradient(colors: [tint, selected ? Color(red: 0.62, green: 0.84, blue: 1) : tint.opacity(0.74)], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
    var body: some View {
        Group {
            switch tool {
            case .pen, .marker, .strokeEraser, .precisionEraser:
                WritingGlyph(kind: tool).stroke(sheen, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                    .frame(width: 26, height: 26)
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
        case .marker:
            line([(5,20),(20,5),(29,14),(14,29)], close: true)
            line([(5,20),(14,29),(11,31),(3,27),(2,24)], close: true)
            line([(9,16),(18,25)]); line([(18,7),(27,16)])
        default:
            line([(3,21),(17,5),(29,16),(17,30),(12,30)], close: true)
            line([(9,14),(22,25)])
        }
        return path
    }
}
