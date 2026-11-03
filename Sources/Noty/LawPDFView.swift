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
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> LawPDFContainer {
        let c = context.coordinator
        let container = LawPDFContainer()
        container.overlay.bottomReserve = LawReadingStyle.footerReserve
        let v = container.pdf
        v.autoScales = true; v.displayMode = .singlePageContinuous; v.displayDirection = .vertical
        v.document = PDFDocument(url: url)
        NotificationCenter.default.addObserver(c, selector: #selector(Coordinator.pageChanged), name: .PDFViewPageChanged, object: v)
        NotificationCenter.default.addObserver(c, selector: #selector(Coordinator.selectionChanged), name: .PDFViewSelectionChanged, object: v)
        NotificationCenter.default.addObserver(c, selector: #selector(Coordinator.visiblePagesChanged), name: .PDFViewVisiblePagesChanged, object: v)
        NotificationCenter.default.addObserver(c, selector: #selector(Coordinator.visiblePagesChanged), name: .PDFViewScaleChanged, object: v)
        // Pencil strokes are previewed here; the overlay itself takes no touches.
        let ink = LawPDFInkOverlay()
        ink.pdf = v; ink.isUserInteractionEnabled = false; ink.backgroundColor = .clear
        v.addSubview(ink); ink.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            ink.leadingAnchor.constraint(equalTo: v.leadingAnchor), ink.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            ink.topAnchor.constraint(equalTo: v.topAnchor), ink.bottomAnchor.constraint(equalTo: v.bottomAnchor),
        ])
        let stroke = LawPencilStroke(target: c, action: #selector(Coordinator.pencil(_:)))
        stroke.delegate = c
        v.addGestureRecognizer(stroke)
        let tap = UITapGestureRecognizer(target: c, action: #selector(Coordinator.tapped(_:)))
        tap.delegate = c
        v.addGestureRecognizer(tap)
        c.container = container; c.ink = ink; c.stroke = stroke; c.tap = tap
        container.overlay.anchor = { [weak c] in c?.barAnchor() }
        return container
    }
    func updateUIView(_ container: LawPDFContainer, context: Context) {
        let c = context.coordinator
        let v = container.pdf
        c.parent = self
        selection.pdf = v
        selection.controller?.pdfHost = c
        container.overlay.attach(controller: selection.controller, selection: selection)
        c.stroke?.isEnabled = pen.kind != .none
        c.tap?.allowedTouchTypes = pen.kind == .none ? lawAllTouchTypes : lawTouchTypesWithoutPencil
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
        c.refreshAnnotations()
    }
    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate, LawPDFMarkHost {
        var parent: NativeLawPDF
        weak var container: LawPDFContainer?
        var view: PDFView? { container?.pdf }
        fileprivate weak var ink: LawPDFInkOverlay?
        weak var stroke: LawPencilStroke?
        weak var tap: UITapGestureRecognizer?
        var destination = ""
        /// Text of each page with glyph boxes, built when a text mark or Pencil needs it.
        private var layouts: [Int: LawPDFTextLayout] = [:]
        /// Rectangles of text marks shown on a page (page index → mark → rectangles).
        private var textRects: [Int: [String: [LawPDFRect]]] = [:]
        /// What each page's annotations were built from.
        private var applied: [Int: Int] = [:]
        private var scrollObservation: NSKeyValueObservation?
        private var straightened = false
        private var lastMove = CGPoint.zero
        private var holdToken = 0
        init(_ parent: NativeLawPDF) { self.parent = parent }

        private var sections: [LawSection] { parent.selection.controller?.document?.sections ?? [] }
        private func kind(_ item: LawPersonalItem) -> String { item.payload["kind"]?.string ?? "" }

        /// With highlighter/eraser Pencil marks and fingers scroll; otherwise
        /// Pencil scrolls and selects like a finger.
        func routePencil(in root: UIView) {
            let types = parent.pen.kind == .none ? lawAllTouchTypes : lawTouchTypesWithoutPencil
            for sub in root.subviews {
                if let scroll = sub as? UIScrollView {
                    if scroll.panGestureRecognizer.allowedTouchTypes != types { scroll.panGestureRecognizer.allowedTouchTypes = types }
                    if scrollObservation == nil {
                        // The bar follows its selection while scrolling and zooming.
                        scrollObservation = scroll.observe(\.contentOffset, options: [.new]) { [weak self] _, _ in
                            MainActor.assumeIsolated { self?.container?.overlay.reposition(animated: false) }
                        }
                    }
                }
                routePencil(in: sub)
            }
        }
        @objc func pageChanged() {
            guard let v = view, let doc = v.document, let page = v.currentPage else { return }
            routePencil(in: v)
            let n = doc.index(for: page) + 1
            DispatchQueue.main.async { [weak self] in self?.parent.onPage(n) }
        }
        @objc func visiblePagesChanged() {
            refreshAnnotations()
            container?.overlay.reposition(animated: false)
        }

        // MARK: Annotations

        /// Page of a PDF mark (1-based), or nil.
        private func pageNumber(_ item: LawPersonalItem) -> Int? { item.payload["page"]?.int }
        /// Pages the provision of a text mark may lie on (0-based indices).
        private func pages(of anchor: LawAnchor, count: Int) -> ClosedRange<Int>? {
            let sections = self.sections
            guard let index = sections.firstIndex(where: { $0.id == anchor.sectionId }), let start = sections[index].pdf?.page else { return nil }
            let next = sections.dropFirst(index + 1).first { $0.pdf != nil }?.pdf?.page ?? count
            return max(0, start - 1)...max(start - 1, min(count - 1, next - 1))
        }
        private func marks(onPage index: Int, count: Int) -> (pdf: [LawPersonalItem], text: [LawPersonalItem]) {
            var pdf: [LawPersonalItem] = [], text: [LawPersonalItem] = []
            for item in parent.items where !item.deleted {
                if kind(item) == "text" {
                    if let anchor = item.textAnchor, pages(of: anchor, count: count)?.contains(index) == true { text.append(item) }
                } else if pageNumber(item) == index + 1 { pdf.append(item) }
            }
            return (pdf, text)
        }
        /// Rebuilds the annotations of visible pages whose marks changed:
        /// one annotation per mark and page (all rectangles as quads), text
        /// marks where their quote is found on the page, an outline for the
        /// selected mark.
        func refreshAnnotations() {
            guard let v = view, let doc = v.document else { return }
            let selected = Set(parent.selection.tapped ? parent.selection.marks : [])
            var indices = Set(v.visiblePages.map { doc.index(for: $0) })
            if let current = v.currentPage { indices.insert(doc.index(for: current)) }
            for index in indices {
                let (pdf, text) = marks(onPage: index, count: doc.pageCount)
                var hasher = Hasher()
                // Entries never change in place (new ID per change): IDs and colours suffice.
                for item in pdf + text { hasher.combine(item.id); hasher.combine(item.payload["color"]?.string) }
                hasher.combine(selected.intersection((pdf + text).map(\.id)).sorted())
                hasher.combine(sections.count)
                let key = hasher.finalize()
                guard applied[index] != key, let page = doc.page(at: index) else { continue }
                applied[index] = key
                rebuild(page, index: index, pdf: pdf, text: text, selected: selected)
            }
        }
        private func rebuild(_ page: PDFPage, index: Int, pdf: [LawPersonalItem], text: [LawPersonalItem], selected: Set<String>) {
            page.annotations.filter { $0.userName == "noty-law" }.forEach { page.removeAnnotation($0) }
            let bounds = page.bounds(for: .cropBox)
            var shown: [String: [LawPDFRect]] = [:]
            for item in pdf {
                let color = lawMarkColor(item.payload["color"]?.string).withAlphaComponent(0.4)
                var outline = CGRect.null
                if case let .array(values) = item.payload["rectangles"] {
                    let rects = values.compactMap(LawPDFRect.init(json:))
                    if let a = highlight(rects, on: page, color: color) { page.addAnnotation(a); outline = a.bounds }
                } else if case let .array(points) = item.payload["points"] {
                    let path = UIBezierPath()
                    for (i, point) in points.enumerated() {
                        guard case let .array(pair) = point, pair.count == 2, case let .number(x) = pair[0], case let .number(y) = pair[1] else { continue }
                        let pos = CGPoint(x: x * bounds.width, y: (1 - y) * bounds.height)
                        if i == 0 { path.move(to: pos) } else { path.addLine(to: pos) }
                    }
                    let a = PDFAnnotation(bounds: bounds, forType: .ink, withProperties: nil)
                    a.add(path); a.color = color; let border = PDFBorder(); border.lineWidth = bounds.width * LawPDFAnchoring.strokeWidth; a.border = border; a.userName = "noty-law"; page.addAnnotation(a)
                    outline = path.bounds.offsetBy(dx: bounds.minX, dy: bounds.minY).insetBy(dx: -border.lineWidth / 2, dy: -border.lineWidth / 2)
                }
                if selected.contains(item.id), !outline.isNull { page.addAnnotation(self.outline(outline)) }
            }
            if !text.isEmpty, let layout = layout(index) {
                for item in text {
                    guard let anchor = item.textAnchor else { continue }
                    let rects = LawPDFAnchoring.rectangles(for: anchor, layout: layout, sections: sections, page: index + 1)
                    guard let a = highlight(rects, on: page, color: lawMarkColor(item.payload["color"]?.string).withAlphaComponent(0.4)) else { continue }
                    shown[item.id] = rects
                    page.addAnnotation(a)
                    if selected.contains(item.id) { page.addAnnotation(outline(a.bounds)) }
                }
            }
            textRects[index] = shown
        }
        private func pageRect(_ r: LawPDFRect, on page: PDFPage) -> CGRect {
            let crop = page.bounds(for: .cropBox)
            return CGRect(x: crop.minX + r.x * crop.width, y: crop.maxY - (r.y + r.height) * crop.height, width: r.width * crop.width, height: r.height * crop.height)
        }
        /// One highlight for all rectangles of a mark on this page (quads).
        private func highlight(_ rects: [LawPDFRect], on page: PDFPage, color: UIColor) -> PDFAnnotation? {
            let boxes = rects.map { pageRect($0, on: page) }.filter { $0.width > 0 && $0.height > 0 }
            guard let first = boxes.first else { return nil }
            let union = boxes.dropFirst().reduce(first) { $0.union($1) }
            let a = PDFAnnotation(bounds: union, forType: .highlight, withProperties: nil)
            a.quadrilateralPoints = boxes.flatMap { r in
                [CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY)]
                    .map { NSValue(cgPoint: CGPoint(x: $0.x - union.minX, y: $0.y - union.minY)) }
            }
            a.color = color; a.userName = "noty-law"
            return a
        }
        private func outline(_ rect: CGRect) -> PDFAnnotation {
            let a = PDFAnnotation(bounds: rect.insetBy(dx: -2, dy: -2), forType: .square, withProperties: nil)
            a.color = .systemBlue
            let border = PDFBorder(); border.lineWidth = 1.5; a.border = border
            a.userName = "noty-law"
            return a
        }
        /// Glyph boxes of a page, normalised to its crop box, origin top left.
        private func layout(_ index: Int) -> LawPDFTextLayout? {
            if let cached = layouts[index] { return cached }
            guard let page = view?.document?.page(at: index) else { return nil }
            let crop = page.bounds(for: .cropBox)
            guard crop.width > 0, crop.height > 0 else { return nil }
            let string = (page.string ?? "") as NSString
            var glyphs: [LawPDFGlyph] = []
            glyphs.reserveCapacity(string.length)
            for i in 0..<string.length {
                let r = page.characterBounds(at: i)
                glyphs.append(LawPDFGlyph(unit: string.character(at: i), x: (r.minX - crop.minX) / crop.width, y: (crop.maxY - r.maxY) / crop.height,
                                          width: r.width / crop.width, height: r.height / crop.height))
            }
            let layout = LawPDFTextLayout(glyphs: glyphs, aspectRatio: crop.height / crop.width)
            layouts[index] = layout
            return layout
        }

        // MARK: Selection and taps

        /// Rectangles (normalised) of a mark on its page, for hits and the bar.
        private func rects(of id: String) -> (index: Int, rects: [LawPDFRect])? {
            for (index, marks) in textRects { if let rects = marks[id], !rects.isEmpty { return (index, rects) } }
            guard let item = parent.items.first(where: { $0.id == id }), let number = pageNumber(item) else { return nil }
            if case let .array(values) = item.payload["rectangles"] { return (number - 1, values.compactMap(LawPDFRect.init(json:))) }
            let points = strokePoints(item)
            guard let first = points.first else { return nil }
            let half = LawPDFAnchoring.strokeWidth / 2
            var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
            for p in points { minX = min(minX, p.x); maxX = max(maxX, p.x); minY = min(minY, p.y); maxY = max(maxY, p.y) }
            return (number - 1, [LawPDFRect(x: minX - half, y: minY - half, width: maxX - minX + 2 * half, height: maxY - minY + 2 * half)])
        }
        private func strokePoints(_ item: LawPersonalItem) -> [LawPDFPoint] {
            guard case let .array(values) = item.payload["points"] else { return [] }
            return values.compactMap { value in
                guard case let .array(pair) = value, pair.count == 2, case let .number(x) = pair[0], case let .number(y) = pair[1] else { return nil }
                return LawPDFPoint(x, y)
            }
        }
        /// The topmost mark at a normalised point of page `index`.
        private func mark(at p: LawPDFPoint, page index: Int) -> String? {
            guard let page = view?.document?.page(at: index) else { return nil }
            let crop = page.bounds(for: .cropBox), aspect = crop.height / max(1, crop.width)
            let pad = 0.004
            for item in parent.items.reversed() where !item.deleted && pageNumber(item) == index + 1 {
                if case let .array(values) = item.payload["rectangles"] {
                    if values.compactMap(LawPDFRect.init(json:)).contains(where: { contains($0, p, pad: pad) }) { return item.id }
                } else {
                    let points = strokePoints(item), reach = LawPDFAnchoring.strokeWidth * 0.75
                    func distance(_ a: LawPDFPoint, _ b: LawPDFPoint) -> Double {
                        // In page-width units (y scaled by the aspect ratio).
                        let ax = a.x, ay = a.y * aspect, bx = b.x, by = b.y * aspect, px = p.x, py = p.y * aspect
                        let dx = bx - ax, dy = by - ay, length = dx * dx + dy * dy
                        let t = length > 0 ? min(1, max(0, ((px - ax) * dx + (py - ay) * dy) / length)) : 0
                        return hypot(px - (ax + t * dx), py - (ay + t * dy))
                    }
                    let segments = points.count == 1 ? [(points[0], points[0])] : Array(zip(points, points.dropFirst()))
                    if segments.contains(where: { distance($0.0, $0.1) < reach }) { return item.id }
                }
            }
            return textRects[index]?.first { $0.value.contains { contains($0, p, pad: pad) } }?.key
        }
        private func contains(_ r: LawPDFRect, _ p: LawPDFPoint, pad: Double) -> Bool {
            p.x >= r.x - pad && p.x <= r.x + r.width + pad && p.y >= r.y - pad && p.y <= r.y + r.height + pad
        }
        private func normalized(_ point: CGPoint, in v: PDFView) -> (index: Int, point: LawPDFPoint)? {
            guard let doc = v.document, let page = v.page(for: point, nearest: false) else { return nil }
            let crop = page.bounds(for: .cropBox), p = v.convert(point, to: page)
            guard crop.width > 0, crop.height > 0 else { return nil }
            return (doc.index(for: page), LawPDFPoint((p.x - crop.minX) / crop.width, (crop.maxY - p.y) / crop.height))
        }
        /// A tap on a mark selects it (outline and bar); elsewhere it ends that.
        @objc func tapped(_ gesture: UITapGestureRecognizer) {
            guard gesture.state == .ended, let v = view else { return }
            let hit = normalized(gesture.location(in: v), in: v).flatMap { mark(at: $0.point, page: $0.index) }
            let selection = parent.selection
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.hasPDFSelection else { return }
                selection.select(mark: hit)
                self.refreshAnnotations()
            }
        }
        @objc func selectionChanged() {
            let has = hasPDFSelection
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let selection = self.parent.selection
                if selection.pdfSelection != has { selection.pdfSelection = has }
                if has {
                    let touched = self.marksTouchedBySelection()
                    if selection.marks != touched { selection.marks = touched }
                    if selection.tapped { selection.tapped = false }
                } else if !selection.tapped, !selection.marks.isEmpty {
                    selection.marks = []
                }
                self.container?.overlay.setNeedsReposition()
            }
        }
        /// Where the bar belongs: the PDF selection or the tapped mark.
        func barAnchor() -> CGRect? {
            guard let v = view, let container else { return nil }
            var union = CGRect.null
            if hasPDFSelection, let current = v.currentSelection {
                for page in current.pages { union = union.union(v.convert(current.bounds(for: page), from: page)) }
            } else if parent.selection.tapped, let id = parent.selection.marks.first, let found = rects(of: id), let page = v.document?.page(at: found.index) {
                for rect in found.rects { union = union.union(v.convert(pageRect(rect, on: page), from: page)) }
            }
            return union.isNull ? nil : container.overlay.convert(union, from: v)
        }

        // MARK: LawPDFMarkHost

        var hasPDFSelection: Bool { !(view?.currentSelection?.string?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) }
        var pdfSelectionText: String? { view?.currentSelection?.string }
        /// Selection lines of a page, normalised.
        private func selectionRects() -> [Int: (rects: [LawPDFRect], text: [String])] {
            guard let v = view, let doc = v.document, let selection = v.currentSelection else { return [:] }
            var pages: [Int: (rects: [LawPDFRect], text: [String])] = [:]
            for line in selection.selectionsByLine() {
                for page in line.pages {
                    let bounds = page.bounds(for: .cropBox), r = line.bounds(for: page).intersection(bounds)
                    guard !r.isNull, bounds.width > 0, bounds.height > 0, r.width > 0, r.height > 0 else { continue }
                    let index = doc.index(for: page)
                    pages[index, default: ([], [])].rects.append(LawPDFRect(x: (r.minX - bounds.minX) / bounds.width, y: (bounds.maxY - r.maxY) / bounds.height, width: r.width / bounds.width, height: r.height / bounds.height))
                    if let string = line.string { pages[index, default: ([], [])].text.append(string) }
                }
            }
            return pages
        }
        /// One `pdf-text` entry per page with all line rectangles, plus a text
        /// anchor when exactly one provision there contains the quote (website rule).
        func pdfSelectionPayloads() -> [[String: LawJSON]] {
            selectionRects().sorted { $0.key < $1.key }.map { index, value in
                let rects = LawPDFAnchoring.limitedRectangles(value.rects)
                var payload: [String: LawJSON] = ["kind": .string("pdf-text"), "page": .number(Double(index + 1)), "rectangles": .array(rects.map(\.json))]
                let top = rects.map(\.y).min() ?? 0, bottom = rects.map { $0.y + $0.height }.max() ?? 0
                if let anchor = LawPDFAnchoring.match(sections, page: index + 1, quote: value.text.joined(separator: " "), top: top, bottom: bottom), let json = anchor.json {
                    payload["anchor"] = json
                }
                return payload
            }
        }
        func marksTouchedBySelection() -> [String] {
            var hit: [String] = []
            for (index, value) in selectionRects() {
                for item in parent.items where !item.deleted && pageNumber(item) == index + 1 {
                    if case let .array(values) = item.payload["rectangles"] {
                        let rects = values.compactMap(LawPDFRect.init(json:))
                        if rects.contains(where: { r in value.rects.contains { intersects($0, r) } }) { hit.append(item.id) }
                    } else if strokePoints(item).contains(where: { p in value.rects.contains { contains($0, p, pad: 0) } }) { hit.append(item.id) }
                }
                for (id, rects) in textRects[index] ?? [:] where rects.contains(where: { r in value.rects.contains { intersects($0, r) } }) { hit.append(id) }
            }
            return Array(Set(hit)).sorted()
        }
        private func intersects(_ a: LawPDFRect, _ b: LawPDFRect) -> Bool {
            a.x < b.x + b.width && b.x < a.x + a.width && a.y < b.y + b.height && b.y < a.y + a.height
        }
        func clearPDFSelection() {
            if view?.currentSelection != nil { view?.clearSelection() }
            if parent.selection.pdfSelection { parent.selection.pdfSelection = false }
        }
        func text(ofMark id: String) -> String? {
            guard let item = parent.items.first(where: { $0.id == id }) else { return nil }
            if case let .array(values) = item.payload["rectangles"], let number = pageNumber(item), let page = view?.document?.page(at: number - 1) {
                let parts = values.compactMap(LawPDFRect.init(json:)).compactMap { page.selection(for: pageRect($0, on: page))?.string }
                if !parts.isEmpty { return parts.joined(separator: "\n") }
            }
            return item.textAnchor?.quote
        }

        // MARK: Pencil

        /// The bar and toast stay tappable with Pencil.
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool { !(touch.view is UIControl) }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            gestureRecognizer === tap
        }
        /// Like the notebook highlighter: „Immer gerade“ straightens on release,
        /// „nach Halten begradigen“ when Pencil rests at the end; after that the
        /// line end follows Pencil with angle snapping. A tap marks the word
        /// under Pencil. The eraser removes marks the stroke or tap touches.
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
                let controller = parent.selection.controller
                if gesture.isTap, !straightened {
                    ink.cancel()
                    tapPencil(at: gesture.startLocation ?? point, in: v)
                    return
                }
                if !straightened { ink.extend(to: point) }
                if parent.pen.kind == .eraser {
                    let hit = erased()
                    ink.cancel()
                    if !hit.isEmpty { controller?.removeMarks(hit) }
                } else {
                    if parent.pen.straight && !straightened { ink.straighten() }
                    if let stroke = ink.finish(), stroke.points.count >= 2 {
                        var payload: [String: LawJSON] = ["kind": .string("pdf"), "page": .number(Double(stroke.index + 1)),
                                                          "points": .array(stroke.points.map { .array([.number($0.x), .number($0.y)]) })]
                        if let layout = layout(stroke.index), let quote = LawPDFAnchoring.quoteUnderStroke(layout, points: stroke.points),
                           let anchor = LawPDFAnchoring.match(sections, page: stroke.index + 1, quote: quote.quote, top: quote.top, bottom: quote.bottom), let json = anchor.json {
                            payload["anchor"] = json
                        }
                        controller?.addPDF([payload])
                    }
                }
            default:
                holdToken += 1
                ink.cancel()
            }
        }
        /// Pencil tap: the highlighter marks the word, the eraser removes the
        /// mark under Pencil.
        private func tapPencil(at point: CGPoint, in v: PDFView) {
            guard let controller = parent.selection.controller, let (index, p) = normalized(point, in: v) else { return }
            if parent.pen.kind == .eraser {
                if let id = mark(at: p, page: index) { controller.removeMarks([id]) }
                return
            }
            guard let layout = layout(index), let word = LawPDFAnchoring.word(at: p, layout: layout) else { return }
            var payload: [String: LawJSON] = ["kind": .string("pdf-text"), "page": .number(Double(index + 1)), "rectangles": .array(word.rectangles.map(\.json))]
            if let anchor = LawPDFAnchoring.match(sections, page: index + 1, quote: word.quote, top: word.top, bottom: word.bottom), let json = anchor.json {
                payload["anchor"] = json
            }
            controller.addPDF([payload])
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
            let index = doc.index(for: page), bounds = page.bounds(for: .cropBox)
            let scale = { (p: LawPDFPoint) in CGPoint(x: p.x * bounds.width, y: p.y * bounds.height) }
            let stroke = ink.normalizedPoints.map(scale)
            let reach = bounds.width * 0.02
            func distance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
                let dx = b.x - a.x, dy = b.y - a.y, length = dx * dx + dy * dy
                let t = length > 0 ? min(1, max(0, ((p.x - a.x) * dx + (p.y - a.y) * dy) / length)) : 0
                return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
            }
            func touches(_ rects: [LawPDFRect]) -> Bool {
                rects.contains { r in
                    let box = CGRect(x: r.x * bounds.width, y: r.y * bounds.height, width: r.width * bounds.width, height: r.height * bounds.height).insetBy(dx: -reach, dy: -reach)
                    return stroke.contains { box.contains($0) }
                }
            }
            var hit = parent.items.filter { item in
                guard !item.deleted, pageNumber(item) == index + 1 else { return false }
                if case let .array(values) = item.payload["rectangles"] { return touches(values.compactMap(LawPDFRect.init(json:))) }
                let line = strokePoints(item).map(scale)
                guard !line.isEmpty else { return false }
                let segments = line.count == 1 ? [(line[0], line[0])] : Array(zip(line, line.dropFirst()))
                return stroke.contains { p in segments.contains { distance(p, $0.0, $0.1) < reach } }
            }.map(\.id)
            hit += (textRects[index] ?? [:]).filter { touches($0.value) }.map(\.key)
            return hit
        }
    }
}

/// The PDF view with the mark overlay above it.
final class LawPDFContainer: UIView {
    let pdf: PDFView = LawKeyPDFView()
    let overlay = LawMarkOverlay()
    init() {
        super.init(frame: .zero)
        addSubview(pdf)
        addSubview(overlay)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layoutSubviews() {
        super.layoutSubviews()
        pdf.frame = bounds
        overlay.frame = bounds
    }
}

/// The law PDF: while it is first responder (a text selection) the law
/// window's shortcuts stay available (`LawKeyboard`).
final class LawKeyPDFView: PDFView {
    override var keyCommands: [UIKeyCommand]? { (super.keyCommands ?? []) + LawKeyboard.shared.keyCommands() }
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
        if let page { preview.lineWidth = max(2, pdf.convert(page.bounds(for: .cropBox), from: page).width * LawPDFAnchoring.strokeWidth) }
        extend(to: point)
    }
    /// Like the website: tiny moves are skipped, and at the server's point
    /// limit every other point is dropped instead of ending the stroke.
    func extend(to point: CGPoint) {
        guard let pdf, let page else { return }
        let p = pdf.convert(point, to: page), bounds = page.bounds(for: .cropBox)
        guard bounds.contains(p) else { return }
        if let last = pagePoints.last, hypot(p.x - last.x, p.y - last.y) < bounds.width * 0.0005 { return }
        if pagePoints.count >= LawPDFAnchoring.maxPoints - 2 { pagePoints = pagePoints.enumerated().filter { $0.offset % 2 == 0 }.map(\.element) }
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
    var normalizedPoints: [LawPDFPoint] {
        guard let page else { return [] }
        let b = page.bounds(for: .cropBox)
        guard b.width > 0, b.height > 0 else { return [] }
        return (straightLine.map { [$0.start, $0.end] } ?? pagePoints).map {
            LawPDFPoint(min(1, max(0, ($0.x - b.minX) / b.width)), min(1, max(0, (b.maxY - $0.y) / b.height)))
        }
    }
    /// The finished stroke: page index and at most 1500 normalised points.
    func finish() -> (index: Int, points: [LawPDFPoint])? {
        defer { cancel() }
        let points = LawPDFAnchoring.thinned(normalizedPoints)
        guard let page, let doc = pdf?.document, points.count >= 2 else { return nil }
        return (doc.index(for: page), points)
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
