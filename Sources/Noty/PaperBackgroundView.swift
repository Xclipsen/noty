import UIKit
import NotebookCore

@MainActor
final class PaperBackgroundView: UIView {
    private var style: PaperStyle = .blank
    private var color: PaperColor = .white
    private var coordinateScale: CGFloat = 1
    private var columns: [ClosedRange<Double>]?
    var paperBounds = CGRect.zero { didSet { if oldValue != paperBounds { setNeedsDisplay() } } }
    override init(frame: CGRect) {
        super.init(frame: frame); isOpaque = true; contentMode = .redraw; isUserInteractionEnabled = false
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func configure(style: PaperStyle, color: PaperColor, coordinateScale: CGFloat = 1, columns: [ClosedRange<Double>]? = nil) {
        if self.style != style || self.color != color || self.coordinateScale != coordinateScale || self.columns != columns {
            self.style = style; self.color = color; self.coordinateScale = coordinateScale; self.columns = columns; setNeedsDisplay()
        }
    }
    override func draw(_ rect: CGRect) {
        PDFExporter.drawPaper(style: style, bounds: paperBounds, color: color, coordinateScale: coordinateScale, columns: columns)
    }
}
