import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass
import PDFKit
import NotebookCore

/// A text marking resolved for the current section; `id` is the personal item.
struct LawTextMark: Hashable {
    var id: String
    var anchor: LawAnchor
    var color: String?
}

/// What Apple Pencil does in the law reader, taken from the notebook's active
/// tool: the highlighter marks (in its colour, straightened like in the
/// notebook), an eraser removes marks, every other tool leaves Pencil to scroll
/// and select like a finger.
struct LawPenMode: Equatable {
    enum Kind: Hashable { case none, marker, eraser }
    var kind = Kind.none
    var color = InkColor(1, 1, 0)
    /// „Immer gerade“ of the notebook highlighter.
    var straight = false
    /// „Linie nach Halten begradigen“ of the notebook highlighter.
    var holdStraighten = true
    /// Stored colour of new marks; the notebook's yellow becomes the website's.
    var hex: String {
        LawMarkEditing.colorKey(String(format: "#%02X%02X%02X", Int((color.red * 255).rounded()), Int((color.green * 255).rounded()), Int((color.blue * 255).rounded())))
    }
    /// The five mark colours (bar, edit menu, keys 1–5) as before. The
    /// notebook highlighter keeps its yellow; law marks store and show the
    /// website's `#F3CC37` for it (`hex`, `LawMarkEditing.colorKey`).
    static let presets: [(name: String, color: InkColor)] = [
        ("Gelb", InkColor(1, 1, 0)), ("Grün", InkColor(0.35, 0.9, 0.35)), ("Blau", InkColor(0.35, 0.75, 1)),
        ("Rosa", InkColor(1, 0.45, 0.8)), ("Orange", InkColor(1, 0.62, 0.15)),
    ]
}

/// One of the five mark colours.
struct LawMarkColor: Identifiable, Hashable {
    var name: String
    var hex: String
    var id: String { hex }
    static let palette: [LawMarkColor] = LawPenMode.presets.map { preset in
        var pen = LawPenMode(); pen.color = preset.color
        return LawMarkColor(name: preset.name, hex: pen.hex)
    }
}

/// Highlight colour of a stored mark (`#RRGGBB`); yellow like the website otherwise.
func lawMarkColor(_ hex: String?) -> UIColor {
    let key = LawMarkEditing.colorKey(hex)
    guard let value = UInt32(key.dropFirst(), radix: 16) else { return UIColor(red: 243 / 255, green: 204 / 255, blue: 55 / 255, alpha: 1) }
    return UIColor(red: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255, blue: CGFloat(value & 0xFF) / 255, alpha: 1)
}
/// Fill of a mark over text: light enough to read through in light and dark mode.
func lawMarkFill(_ hex: String?) -> UIColor {
    UIColor { traits in lawMarkColor(hex).withAlphaComponent(traits.userInterfaceStyle == .dark ? 0.36 : 0.45) }
}

/// Shared between the reader, its text/PDF views and `LawMarkController`: the
/// live selection, the marks it touches or the tapped mark, and the rendered
/// text the range refers to. HTML rendering may differ from the plain section
/// text in non-letters.
@MainActor
final class LawTextSelection: ObservableObject {
    /// Text selection in the rendered section text.
    @Published var range = NSRange(location: 0, length: 0)
    /// Marks touched by the text or PDF selection, or the tapped mark.
    @Published var marks: [String] = []
    /// `marks` is a tapped (selected) mark, drawn with an outline.
    @Published var tapped = false
    /// The PDF has a text selection.
    @Published var pdfSelection = false
    var text = ""
    weak var view: UITextView?
    weak var pdf: PDFView?
    /// Set when the reader connects; the text and PDF views reach the
    /// controller through it (their next update attaches the bar).
    weak var controller: LawMarkController? { didSet { if oldValue !== controller { objectWillChange.send() } } }
    var active: Bool { range.length > 0 || !marks.isEmpty || pdfSelection }
    /// Whatever shows the section now; PDFKit keeps its scroll view inside.
    private var scroller: UIScrollView? {
        if let view, view.window != nil { return view }
        func find(_ root: UIView) -> UIScrollView? {
            for sub in root.subviews { if let found = sub as? UIScrollView ?? find(sub) { return found } }
            return nil
        }
        return pdf.flatMap(find)
    }
    func scroll(lines: Int) { scroll(by: CGFloat(lines) * 44) }
    func scroll(screens: Double) { scroll(by: CGFloat(screens) * (scroller?.bounds.height ?? 0)) }
    /// To the start, or past everything to the end.
    func scrollToEdge(end: Bool) { scroll(by: end ? .greatestFiniteMagnitude / 2 : -.greatestFiniteMagnitude / 2) }
    private func scroll(by distance: CGFloat) {
        guard let scroller else { return }
        let inset = scroller.adjustedContentInset
        let limit = max(-inset.top, scroller.contentSize.height - scroller.bounds.height + inset.bottom)
        scroller.setContentOffset(CGPoint(x: scroller.contentOffset.x, y: min(limit, max(-inset.top, scroller.contentOffset.y + distance))), animated: false)
    }
    /// Selects a tapped mark (outline, bar with colour/remove/adjust).
    func select(mark id: String?) {
        let next = id.map { [$0] } ?? []
        if marks != next { marks = next }
        if tapped != (id != nil) { tapped = id != nil }
    }
    func clear() {
        view?.selectedTextRange = nil
        if pdf?.currentSelection != nil { pdf?.clearSelection() }
        if range.length > 0 { range = NSRange(location: 0, length: 0) }
        if !marks.isEmpty { marks = [] }
        if tapped { tapped = false }
        if pdfSelection { pdfSelection = false }
        controller?.endAdjusting()
    }
}

/// Apple Pencil stroke that begins on touch-down. A pan waits for its movement
/// threshold and then loses against the text view's own Pencil selection,
/// which made marking hit-or-miss; beginning at once prevents those gestures.
/// Enabled only while the notebook tool gives Pencil a job here.
final class LawPencilStroke: UIGestureRecognizer {
    private(set) var startLocation: CGPoint?
    private(set) var startTime: TimeInterval = 0
    /// Longest distance from the start so far (view points): tap or stroke.
    private(set) var travel: CGFloat = 0
    private weak var touch: UITouch?
    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        allowedTouchTypes = [NSNumber(value: UITouch.TouchType.pencil.rawValue)]
    }
    /// Short and nearly still: a tap rather than a stroke.
    var isTap: Bool { travel < 6 && ProcessInfo.processInfo.systemUptime - startTime < 0.45 }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard touch == nil, let first = touches.first else { touches.forEach { ignore($0, for: event) }; return }
        touch = first; startLocation = first.location(in: view); startTime = first.timestamp; travel = 0
        state = .began
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch, touches.contains(touch) else { return }
        if let start = startLocation { let p = touch.location(in: view); travel = max(travel, hypot(p.x - start.x, p.y - start.y)) }
        state = .changed
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        if let touch, touches.contains(touch) { state = .ended }
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        if let touch, touches.contains(touch) { state = .cancelled }
    }
    override func location(in view: UIView?) -> CGPoint { touch?.location(in: view) ?? super.location(in: view) }
    override func reset() {
        super.reset()
        startLocation = nil; touch = nil; travel = 0
    }
}

var lawTouchTypesWithoutPencil: [NSNumber] { [UITouch.TouchType.direct, .indirect, .indirectPointer].map { NSNumber(value: $0.rawValue) } }
var lawAllTouchTypes: [NSNumber] { [UITouch.TouchType.direct, .indirect, .pencil, .indirectPointer].map { NSNumber(value: $0.rawValue) } }

extension LawReaderView {
    /// What Apple Pencil does in the law text and PDF, in the grammar of the
    /// notebook's option rows. Fingers always scroll and select; choosing the
    /// highlighter or an eraser in the notebook switches along.
    func penSwitch(_ change: @escaping (LawPenMode) -> Void) -> some View {
        func set(_ kind: LawPenMode.Kind) { var next = pen; next.kind = kind; change(next) }
        return HStack(spacing: 0) {
            Image(systemName: "applepencil").font(.system(size: 15)).foregroundStyle(.secondary).frame(width: 28).accessibilityHidden(true)
            NotySymbolOption("Lesen", symbol: "hand.point.up.left", selected: pen.kind == .none, help: "Apple Pencil scrollt und wählt aus") { set(.none) }
            NotySymbolOption("Markieren", symbol: "highlighter", selected: pen.kind == .marker, help: "Apple Pencil markiert Wörter") { set(.marker) }
            NotySymbolOption("Radieren", symbol: "eraser", selected: pen.kind == .eraser, help: "Apple Pencil entfernt Markierungen") { set(.eraser) }
            NotyGroupDivider()
            ForEach(LawMarkColor.palette) { color in
                NotySwatch(Color(lawMarkColor(color.hex)), selected: pen.kind == .marker && pen.hex == color.hex, title: "Stiftfarbe \(color.name)") {
                    var next = pen; next.kind = .marker
                    next.color = LawPenMode.presets.first { $0.name == color.name }?.color ?? next.color
                    change(next)
                }
            }
        }.buttonStyle(NotyToolStyle())
    }
    /// The floating mark bar lives in the text and PDF views themselves
    /// (`LawMarkOverlay`); this former bottom bar stays empty.
    var selectionBar: some View { EmptyView() }
    func basePayload(_ doc: LawDocument) -> [String: LawJSON] { ["lawId": .string(doc.id), "versionId": .string(doc.version)] }
    /// Marks the given range of the rendered section text (keyboard, edit
    /// menu, Pencil); `color` (`#RRGGBB`) defaults to the pen's colour.
    func mark(_ range: NSRange, color: String? = nil) {
        markController.markText(range, color: color)
    }
    /// Removes marks: the selected text from the marks it touches when `ids`
    /// are the marks under the selection, otherwise these marks completely.
    func unmark(_ ids: [String]) {
        if textSelection.range.length > 0, ids == textSelection.marks, !textSelection.tapped {
            markController.removeSelection()
        } else {
            markController.removeMarks(ids)
        }
    }
}
