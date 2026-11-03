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
    var hex: String { String(format: "#%02X%02X%02X", Int((color.red * 255).rounded()), Int((color.green * 255).rounded()), Int((color.blue * 255).rounded())) }
    static let presets: [(name: String, color: InkColor)] = [
        ("Gelb", InkColor(1, 1, 0)), ("Grün", InkColor(0.35, 0.9, 0.35)), ("Blau", InkColor(0.35, 0.75, 1)),
        ("Rosa", InkColor(1, 0.45, 0.8)), ("Orange", InkColor(1, 0.62, 0.15)),
    ]
}

/// Highlight colour of a stored mark (`#RRGGBB`), yellow like the website otherwise.
func lawMarkColor(_ hex: String?) -> UIColor {
    guard let hex, hex.count == 7, hex.hasPrefix("#"), let value = UInt32(hex.dropFirst(), radix: 16) else { return .systemYellow }
    return UIColor(red: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255, blue: CGFloat(value & 0xFF) / 255, alpha: 1)
}

/// Shared between the reader and its UITextView: the live selection, the marks
/// under it (or the tapped mark) and the rendered text the range refers to.
/// HTML rendering may differ from the plain section text in non-letters.
@MainActor
final class LawTextSelection: ObservableObject {
    @Published var range = NSRange(location: 0, length: 0)
    @Published var marks: [String] = []
    var text = ""
    weak var view: UITextView?
    weak var pdf: PDFView?
    var active: Bool { range.length > 0 || !marks.isEmpty }
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
    func clear() {
        view?.selectedTextRange = nil
        if range.length > 0 { range = NSRange(location: 0, length: 0) }
        if !marks.isEmpty { marks = [] }
    }
}

/// Apple Pencil stroke that begins on touch-down. A pan waits for its movement
/// threshold and then loses against the text view's own Pencil selection,
/// which made marking hit-or-miss; beginning at once prevents those gestures.
/// Enabled only while the notebook tool gives Pencil a job here.
final class LawPencilStroke: UIGestureRecognizer {
    private(set) var startLocation: CGPoint?
    private weak var touch: UITouch?
    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        allowedTouchTypes = [NSNumber(value: UITouch.TouchType.pencil.rawValue)]
    }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard touch == nil, let first = touches.first else { touches.forEach { ignore($0, for: event) }; return }
        touch = first; startLocation = first.location(in: view)
        state = .began
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        if let touch, touches.contains(touch) { state = .changed }
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
        startLocation = nil; touch = nil
    }
}

var lawTouchTypesWithoutPencil: [NSNumber] { [UITouch.TouchType.direct, .indirect, .indirectPointer].map { NSNumber(value: $0.rawValue) } }
var lawAllTouchTypes: [NSNumber] { [UITouch.TouchType.direct, .indirect, .pencil, .indirectPointer].map { NSNumber(value: $0.rawValue) } }

extension LawReaderView {
    /// What Apple Pencil does in the law text and PDF. Fingers always scroll and
    /// select; choosing the highlighter or an eraser in the notebook switches along.
    func penSwitch(_ change: @escaping (LawPenMode) -> Void) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "applepencil").foregroundStyle(.secondary).accessibilityHidden(true)
            Picker("Apple Pencil", selection: Binding(get: { pen.kind }, set: { var next = pen; next.kind = $0; change(next) })) {
                Text("Lesen").tag(LawPenMode.Kind.none)
                Text("Markieren").tag(LawPenMode.Kind.marker)
                Text("Radieren").tag(LawPenMode.Kind.eraser)
            }.pickerStyle(.segmented)
            Menu {
                ForEach(LawPenMode.presets, id: \.name) { preset in
                    Button(preset.name) { var next = pen; next.color = preset.color; next.kind = .marker; change(next) }
                }
            } label: {
                Circle().fill(Color(lawMarkColor(pen.hex))).frame(width: 22, height: 22)
                    .overlay(Circle().stroke(.secondary, lineWidth: 1)).frame(width: 32, height: 32)
            }.accessibilityLabel("Markierfarbe")
        }
    }
    /// Like the website's selection toolbar: mark, remove touched marks, dismiss.
    var selectionBar: some View {
        HStack(spacing: 8) {
            if textSelection.range.length > 0 {
                Button("Markieren", systemImage: "highlighter") { mark(textSelection.range) }.buttonStyle(.borderedProminent)
            }
            if !textSelection.marks.isEmpty {
                Button(textSelection.marks.count == 1 ? "Markierung entfernen" : "Markierungen entfernen", systemImage: "eraser", role: .destructive) {
                    unmark(textSelection.marks)
                }.buttonStyle(.bordered)
            }
            Button { textSelection.clear() } label: { Image(systemName: "xmark") }.buttonStyle(.bordered).accessibilityLabel("Auswahl aufheben")
        }
        .padding(8).background(.regularMaterial, in: Capsule()).padding(.bottom, 10)
    }
    func basePayload(_ doc: LawDocument) -> [String: LawJSON] { ["lawId": .string(doc.id), "versionId": .string(doc.version)] }
    /// Marks the given range of the rendered section text (selection, edit menu
    /// or Pencil stroke). Pure punctuation/whitespace strokes are ignored.
    /// `color` (`#RRGGBB`) defaults to the pen's colour.
    func mark(_ range: NSRange, color: String? = nil) {
        guard let doc = document, let section else { return }
        let text = textSelection.text as NSString
        guard range.location >= 0, NSMaxRange(range) <= text.length,
              !LawTextAnchor.canonical(text.substring(with: range)).isEmpty else { textSelection.clear(); return }
        guard let anchor = LawTextAnchor.anchor(text: textSelection.text, range: range, sectionID: section.id),
              let data = try? JSONEncoder().encode(anchor), let value = try? JSONDecoder().decode(LawJSON.self, from: data) else {
            loadError = "Diese Auswahl lässt sich nicht eindeutig zuordnen."; return
        }
        guard (anchor.quote as NSString).length <= 4000 else { loadError = "Bitte eine kürzere Textstelle markieren."; return }
        var payload = basePayload(doc); payload["kind"] = .string("text"); payload["page"] = .number(0); payload["anchor"] = value
        payload["color"] = .string(color ?? pen.hex)
        loadError = ""
        textSelection.clear()
        Task { await laws.save(kind: "annotation", payload: payload) }
    }
    func unmark(_ ids: [String]) {
        let doomed = laws.items.filter { ids.contains($0.id) && !$0.deleted }
        textSelection.clear()
        Task { for item in doomed { await laws.remove(item) } }
    }
}
