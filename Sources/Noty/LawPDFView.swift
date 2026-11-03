import SwiftUI
import UIKit
import PDFKit
import NotebookCore

struct NativeLawPDF: UIViewRepresentable {
    let url: URL
    let page: Int
    let top: Double
    var selection: LawTextSelection
    var onPage: (Int) -> Void
    var items: [LawPersonalItem]
    var pen: LawPenMode
    var onMark: ([String: LawJSON]) -> Void
    var onRemove: ([String]) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> PDFView {
        let c = context.coordinator
        let v = PDFView(); v.autoScales = true; v.displayMode = .singlePageContinuous; v.displayDirection = .vertical
        v.document = PDFDocument(url: url)
        NotificationCenter.default.addObserver(c, selector: #selector(Coordinator.pageChanged), name: .PDFViewPageChanged, object: v)
        NotificationCenter.default.addObserver(c, selector: #selector(Coordinator.selectionChanged), name: .PDFViewSelectionChanged, object: v)
        // Pencil strokes are previewed here; the overlay itself takes no touches.
        let ink = LawPDFInkOverlay()
        ink.pdf = v; ink.isUserInteractionEnabled = false; ink.backgroundColor = .clear
        v.addSubview(ink); ink.translatesAutoresizingMaskIntoConstraints = false
        var button = UIButton.Configuration.borderedProminent()
        button.title = "Markieren"; button.image = UIImage(systemName: "highlighter"); button.imagePadding = 6
        let mark = UIButton(configuration: button, primaryAction: UIAction { [weak c] _ in c?.markSelection() })
        mark.isHidden = true
        v.addSubview(mark); mark.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            ink.leadingAnchor.constraint(equalTo: v.leadingAnchor), ink.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            ink.topAnchor.constraint(equalTo: v.topAnchor), ink.bottomAnchor.constraint(equalTo: v.bottomAnchor),
            mark.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -12), mark.bottomAnchor.constraint(equalTo: v.safeAreaLayoutGuide.bottomAnchor, constant: -12),
        ])
        let stroke = LawPencilStroke(target: c, action: #selector(Coordinator.pencil(_:)))
        stroke.delegate = c
        v.addGestureRecognizer(stroke)
        c.view = v; c.ink = ink; c.markButton = mark; c.stroke = stroke
        return v
    }
    func updateUIView(_ v: PDFView, context: Context) {
        let c = context.coordinator
        c.parent = self
        selection.pdf = v
        c.stroke?.isEnabled = pen.kind != .none
        // PDFKit builds its scroll view lazily; route Pencil on every update.
        c.routePencil(in: v)
        let destination = "\(page):\(top)"
        if c.destination != destination {
            c.destination = destination
            if let p = v.document?.page(at: max(0, page - 1)) {
                let bounds = p.bounds(for: .cropBox)
                v.go(to: PDFDestination(page: p, at: CGPoint(x: bounds.minX, y: bounds.maxY - bounds.height * max(0, min(1, top)))))
            }
        }
        guard c.items != items, let doc = v.document else { return }
        c.items = items
        for index in 0..<doc.pageCount {
            guard let p = doc.page(at: index) else { continue }
            p.annotations.filter { $0.userName == "noty-law" }.forEach { p.removeAnnotation($0) }
            let bounds = p.bounds(for: .cropBox)
            for item in items where item.payload["page"]?.int == index + 1 {
                let color = lawMarkColor(item.payload["color"]?.string).withAlphaComponent(0.4)
                if case let .array(rects) = item.payload["rectangles"] {
                    for rect in rects {
                        guard case let .object(r) = rect, case let .number(x) = r["x"], case let .number(y) = r["y"], case let .number(w) = r["width"], case let .number(h) = r["height"] else { continue }
                        let a = PDFAnnotation(bounds: CGRect(x: bounds.minX + x * bounds.width, y: bounds.maxY - (y + h) * bounds.height, width: w * bounds.width, height: h * bounds.height), forType: .highlight, withProperties: nil)
                        a.color = color; a.userName = "noty-law"; p.addAnnotation(a)
                    }
                } else if case let .array(points) = item.payload["points"] {
                    let path = UIBezierPath()
                    for (i, point) in points.enumerated() {
                        guard case let .array(pair) = point, pair.count == 2, case let .number(x) = pair[0], case let .number(y) = pair[1] else { continue }
                        let pos = CGPoint(x: x * bounds.width, y: (1 - y) * bounds.height)
                        if i == 0 { path.move(to: pos) } else { path.addLine(to: pos) }
                    }
                    let a = PDFAnnotation(bounds: bounds, forType: .ink, withProperties: nil)
                    a.add(path); a.color = color; let border = PDFBorder(); border.lineWidth = bounds.width * 0.018; a.border = border; a.userName = "noty-law"; p.addAnnotation(a)
                }
            }
        }
    }
    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: NativeLawPDF
        weak var view: PDFView?
        fileprivate weak var ink: LawPDFInkOverlay?
        weak var markButton: UIButton?
        weak var stroke: LawPencilStroke?
        var destination = ""
        var items: [LawPersonalItem] = []
        private var straightened = false
        private var lastMove = CGPoint.zero
        private var holdToken = 0
        init(_ parent: NativeLawPDF) { self.parent = parent }
        /// With highlighter/eraser Pencil marks and fingers scroll; otherwise
        /// Pencil scrolls and selects like a finger.
        func routePencil(in root: UIView) {
            let types = parent.pen.kind == .none ? lawAllTouchTypes : lawTouchTypesWithoutPencil
            for sub in root.subviews {
                if let scroll = sub as? UIScrollView, scroll.panGestureRecognizer.allowedTouchTypes != types {
                    scroll.panGestureRecognizer.allowedTouchTypes = types
                }
                routePencil(in: sub)
            }
        }
        /// The „Markieren“ button stays tappable with Pencil.
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool { !(touch.view is UIControl) }
        @objc func pageChanged() {
            guard let v = view, let doc = v.document, let page = v.currentPage else { return }
            routePencil(in: v)
            let n = doc.index(for: page) + 1
            DispatchQueue.main.async { [weak self] in self?.parent.onPage(n) }
        }
        @objc func selectionChanged() {
            let empty = view?.currentSelection?.string?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
            markButton?.isHidden = empty
        }
        func markSelection() {
            guard let v = view, let doc = v.document, let selection = v.currentSelection else { return }
            for line in selection.selectionsByLine() {
                for page in line.pages {
                    let bounds = page.bounds(for: .cropBox), r = line.bounds(for: page).intersection(bounds)
                    guard !r.isNull, bounds.width > 0, bounds.height > 0, r.width > 0, r.height > 0 else { continue }
                    let rect: LawJSON = .object(["x": .number((r.minX - bounds.minX) / bounds.width), "y": .number((bounds.maxY - r.maxY) / bounds.height), "width": .number(r.width / bounds.width), "height": .number(r.height / bounds.height)])
                    parent.onMark(["kind": .string("pdf-text"), "page": .number(Double(doc.index(for: page) + 1)), "rectangles": .array([rect])])
                }
            }
            v.clearSelection()
            markButton?.isHidden = true
        }
        /// Like the notebook highlighter: „Immer gerade“ straightens on release,
        /// „nach Halten begradigen“ when Pencil rests at the end; after that the
        /// line end follows Pencil with angle snapping. The eraser removes marks
        /// the stroke touches.
        @objc func pencil(_ gesture: LawPencilStroke) {
            guard let v = view, let ink else { return }
            let point = gesture.location(in: v)
            switch gesture.state {
            case .began:
                straightened = false
                ink.begin(at: gesture.startLocation ?? point, color: parent.pen.kind == .eraser ? .systemGray : lawMarkColor(parent.pen.hex))
                ink.extend(to: point); lastMove = point; scheduleHold()
            case .changed:
                if straightened { ink.moveStraightEnd(to: point); return }
                ink.extend(to: point)
                if hypot(point.x - lastMove.x, point.y - lastMove.y) > 4 { lastMove = point; scheduleHold() }
            case .ended:
                holdToken += 1
                if !straightened { ink.extend(to: point) }
                if parent.pen.kind == .eraser {
                    let hit = erased()
                    ink.cancel()
                    if !hit.isEmpty { parent.onRemove(hit) }
                } else {
                    if parent.pen.straight && !straightened { ink.straighten() }
                    if let payload = ink.finish() { parent.onMark(payload) }
                }
            default:
                holdToken += 1
                ink.cancel()
            }
        }
        private func scheduleHold() {
            holdToken += 1
            guard parent.pen.kind == .marker, parent.pen.holdStraighten else { return }
            let token = holdToken
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, self.holdToken == token, !self.straightened, let ink = self.ink, ink.isDrawing, ink.straighten() else { return }
                self.straightened = true
                UISelectionFeedbackGenerator().selectionChanged()
            }
        }
        /// Marks on the stroke's page that the stroke touches (page units, y down).
        private func erased() -> [String] {
            guard let ink, let page = ink.page, let doc = view?.document else { return [] }
            let number = doc.index(for: page) + 1, bounds = page.bounds(for: .cropBox)
            let scale = { (p: CGPoint) in CGPoint(x: p.x * bounds.width, y: p.y * bounds.height) }
            let stroke = ink.normalizedPoints.map(scale)
            let reach = bounds.width * 0.02
            func distance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
                let dx = b.x - a.x, dy = b.y - a.y, length = dx * dx + dy * dy
                let t = length > 0 ? min(1, max(0, ((p.x - a.x) * dx + (p.y - a.y) * dy) / length)) : 0
                return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
            }
            func point(_ value: LawJSON) -> CGPoint? {
                guard case let .array(pair) = value, pair.count == 2, case let .number(x) = pair[0], case let .number(y) = pair[1] else { return nil }
                return scale(CGPoint(x: x, y: y))
            }
            return items.filter { item in
                guard item.payload["page"]?.int == number else { return false }
                if case let .array(rects) = item.payload["rectangles"] {
                    return rects.contains { rect in
                        guard case let .object(r) = rect, case let .number(x) = r["x"], case let .number(y) = r["y"], case let .number(w) = r["width"], case let .number(h) = r["height"] else { return false }
                        let box = CGRect(x: x * bounds.width, y: y * bounds.height, width: w * bounds.width, height: h * bounds.height).insetBy(dx: -reach, dy: -reach)
                        return stroke.contains { box.contains($0) }
                    }
                }
                if case let .array(values) = item.payload["points"] {
                    let line = values.compactMap(point)
                    let segments = line.count == 1 ? [(line[0], line[0])] : Array(zip(line, line.dropFirst()))
                    return stroke.contains { p in segments.contains { distance(p, $0.0, $0.1) < reach } }
                }
                return false
            }.map(\.id)
        }
    }
}

/// Live preview of a Pencil stroke over the PDF. Points are kept in PDF page
/// coordinates; the source PDF is never saved with the derived annotations.
@MainActor
private final class LawPDFInkOverlay: UIView {
    weak var pdf: PDFView?
    private(set) weak var page: PDFPage?
    private var pagePoints: [CGPoint] = []
    private var straightLine: (start: CGPoint, end: CGPoint)?
    private let preview = CAShapeLayer()
    var isDrawing: Bool { page != nil }
    override init(frame: CGRect) {
        super.init(frame: frame)
        preview.fillColor = UIColor.clear.cgColor; preview.lineCap = .round; preview.lineJoin = .round
        layer.addSublayer(preview)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func begin(at point: CGPoint, color: UIColor) {
        guard let pdf else { return }
        page = pdf.page(for: point, nearest: true); pagePoints = []; straightLine = nil
        preview.strokeColor = color.withAlphaComponent(0.45).cgColor
        if let page { preview.lineWidth = max(2, pdf.convert(page.bounds(for: .cropBox), from: page).width * 0.018) }
        extend(to: point)
    }
    func extend(to point: CGPoint) {
        guard pagePoints.count < 1500, let pdf, let page else { return }
        let p = pdf.convert(point, to: page)
        guard page.bounds(for: .cropBox).contains(p) else { return }
        pagePoints.append(p); redraw()
    }
    /// Replaces the drawn stroke by one fitted, angle-snapped segment.
    @discardableResult
    func straighten() -> Bool {
        guard let line = MarkerStraightening.line(pagePoints.map { PagePoint(x: $0.x, y: $0.y) }) else { return false }
        straightLine = (CGPoint(x: line.start.x, y: line.start.y), CGPoint(x: line.end.x, y: line.end.y)); redraw()
        return true
    }
    /// After straightening the start stays; the end follows Pencil, snapped in angle.
    func moveStraightEnd(to point: CGPoint) {
        guard let pdf, let page, let line = straightLine else { return }
        let p = pdf.convert(point, to: page)
        let end = LineSnapping.end(from: PagePoint(x: line.start.x, y: line.start.y), to: PagePoint(x: p.x, y: p.y))
        straightLine = (line.start, CGPoint(x: end.x, y: end.y)); redraw()
    }
    /// Stroke relative to the crop box: x to the right, y down from the top, 0…1.
    var normalizedPoints: [CGPoint] {
        guard let page else { return [] }
        let b = page.bounds(for: .cropBox)
        guard b.width > 0, b.height > 0 else { return [] }
        return (straightLine.map { [$0.start, $0.end] } ?? pagePoints).map {
            CGPoint(x: min(1, max(0, ($0.x - b.minX) / b.width)), y: min(1, max(0, (b.maxY - $0.y) / b.height)))
        }
    }
    func finish() -> [String: LawJSON]? {
        defer { cancel() }
        let points = normalizedPoints
        guard let page, let doc = pdf?.document, points.count >= 2 else { return nil }
        return ["kind": .string("pdf"), "page": .number(Double(doc.index(for: page) + 1)), "points": .array(points.map { .array([.number($0.x), .number($0.y)]) })]
    }
    func cancel() { pagePoints = []; straightLine = nil; page = nil; preview.path = nil }
    private func redraw() {
        guard let pdf, let page else { preview.path = nil; return }
        let path = UIBezierPath()
        for (index, p) in (straightLine.map { [$0.start, $0.end] } ?? pagePoints).enumerated() {
            let local = convert(pdf.convert(p, from: page), from: pdf)
            if index == 0 { path.move(to: local) } else { path.addLine(to: local) }
        }
        preview.path = path.cgPath
    }
}
