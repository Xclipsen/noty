import SwiftUI
import UIKit
import Combine
import NotebookCore

/// The floating mark bar at a text or PDF selection or a tapped mark, in the
/// look of `SelectionActionBar`: dark capsule (white 0.13, 52 pt), 44-pt
/// symbol cells with 4 pt between them, colour dots, 1 × 26 dividers,
/// „Entfernen“ red and always last. At most 360 pt wide. A text or PDF
/// selection: colours | Kopieren, ✕ | Entfernen (if it touches marks). A
/// tapped mark: colours | Bereich anpassen | Entfernen, without „Kopieren“
/// and ✕: tapping beside it or Esc closes the bar.
struct LawMarkBar: View {
    @ObservedObject var controller: LawMarkController
    @ObservedObject var selection: LawTextSelection
    static let height: CGFloat = 52
    static let maxWidth: CGFloat = 360

    private var tappedItem: LawPersonalItem? {
        guard selection.tapped, let id = selection.marks.first else { return nil }
        return controller.laws?.liveItem(id)
    }
    var body: some View {
        ViewThatFits(in: .horizontal) {
            content
            ScrollView(.horizontal, showsIndicators: false) { content }.frame(maxWidth: Self.maxWidth)
        }
        .frame(height: Self.height)
        .background(Color(white: 0.13).opacity(0.98), in: Capsule(style: .continuous))
        .overlay(Capsule(style: .continuous).strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
        .clipShape(Capsule(style: .continuous))
        .foregroundStyle(.white)
        .buttonStyle(NotyToolStyle())
        .environment(\.notyTooltipAxis, .horizontal)
        // Hover names (Pencil, pointer) above the bar, outside its capsule.
        .notyTooltipHost()
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Markieren")
    }
    private var content: some View {
        let item = tappedItem
        let tapped = item != nil
        let current = item.map { LawMarkEditing.colorKey($0.payload["color"]?.string) }
        let adjusting = controller.adjusting != nil
        let adjustable = item?.payload["kind"]?.string == "text" && item.flatMap { controller.originalRange(of: $0.id) } != nil
        let removable = !selection.marks.isEmpty && !adjusting
        // A text selection takes only its own text out of the marks it touches.
        let partial = !selection.tapped && !selection.pdfSelection
        let middle = adjusting || (tapped ? adjustable : true)
        return HStack(spacing: 4) {
            HStack(spacing: 0) {
                ForEach(Array(LawMarkColor.palette.enumerated()), id: \.element.id) { index, color in
                    NotySwatch(Color(lawMarkColor(color.hex)), selected: current == color.hex,
                               title: item == nil ? "\(color.name) markieren (\(index + 1))" : "Farbe \(color.name) (\(index + 1))") {
                        controller.mark(color: color.hex)
                    }
                }
            }
            if middle {
                Self.divider
                if adjusting {
                    NotySymbolOption("Übernehmen", symbol: "checkmark", help: "Übernehmen – Markierung auf die neue Auswahl setzen") { controller.applyAdjusting() }
                    NotySymbolOption("Abbrechen", symbol: "xmark", help: "Anpassen abbrechen (Esc)") { controller.clearSelection() }
                } else if tapped {
                    NotySymbolOption("Bereich anpassen", symbol: "selection.pin.in.out", help: "Bereich anpassen – Auswahl auf die Markierung setzen") {
                        controller.adjustSelectedMark()
                    }
                } else {
                    NotySymbolOption("Kopieren", symbol: "doc.on.doc", help: "Kopieren – Text in die Zwischenablage") { controller.copySelection() }
                    NotySymbolOption("Schließen", symbol: "xmark", help: "Auswahl aufheben (Esc)") { controller.clearSelection() }
                }
            }
            if removable {
                Self.divider
                NotySymbolOption(partial ? "Aus Markierung entfernen" : "Entfernen", symbol: "trash",
                                 help: partial ? "Aus Markierung entfernen – nur den ausgewählten Text (⌫)" : "Entfernen – ganze Markierung (⌫)") {
                    controller.removeSelection()
                }.foregroundStyle(Color(uiColor: .systemRed))
            }
        }
        .padding(.horizontal, 4)
    }
    /// Like `SelectionActionBar`'s group divider.
    private static var divider: some View {
        Rectangle().fill(.white.opacity(0.14)).frame(width: 1, height: 26)
            .allowsHitTesting(false).accessibilityHidden(true)
    }
}

/// „Markiert · Rückgängig“, „Markierung entfernt · Rückgängig“ and short
/// notes under the reader.
struct LawMarkToastView: View {
    @ObservedObject var controller: LawMarkController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        ZStack {
            if let toast = controller.toast {
                HStack(spacing: 12) {
                    Text(toast.message).font(.subheadline).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    if toast.undo && controller.canUndo {
                        Rectangle().fill(.white.opacity(0.14)).frame(width: 0.5, height: 18).accessibilityHidden(true)
                        Button("Rückgängig") { controller.undoFromToast() }
                            .font(.subheadline.weight(.semibold)).foregroundStyle(Color.notyAccent)
                            .frame(minHeight: 44).contentShape(Rectangle()).buttonStyle(NotyPressStyle())
                    }
                }
                .padding(.horizontal, 16).frame(minHeight: 44)
                .background(Color(white: 0.13).opacity(0.98), in: Capsule(style: .continuous))
                .overlay(Capsule(style: .continuous).strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
                .foregroundStyle(.white).environment(\.colorScheme, .dark)
                .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                .id(toast.id)
                .accessibilityAddTraits(.isStaticText)
                .onAppear {
                    let undo = toast.undo && controller.canUndo
                    UIAccessibility.post(notification: .announcement, argument: undo ? "\(toast.message). Rückgängig möglich." : toast.message)
                }
            }
        }
        .animation(NotyMotion.palette(reduceMotion), value: controller.toast?.id)
    }
}

/// Hosts the mark bar (at `anchor`) and the toast (bottom) above the law text
/// or PDF. Takes touches only on the bar and the toast.
@MainActor
final class LawMarkOverlay: UIView {
    /// Where the bar belongs, in this view's coordinates; nil = no bar.
    var anchor: () -> CGRect? = { nil }
    /// Room at the bottom taken by the reader's footer (glass navigator):
    /// neither the toast nor the bar is placed behind it.
    var bottomReserve: CGFloat = 0 { didSet { if oldValue != bottomReserve { setNeedsLayout() } } }
    private var bar: UIHostingController<LawMarkBar>?
    private var toast: UIHostingController<LawMarkToastView>?
    private weak var controller: LawMarkController?
    private weak var selection: LawTextSelection?
    private var watching: [AnyCancellable] = []
    private var barVisible = false
    private var scheduled = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// True when `attach` would rebuild the bar (callers defer that out of SwiftUI updates).
    func needsAttach(controller: LawMarkController?, selection: LawTextSelection) -> Bool {
        guard let controller else { return false }
        return controller !== self.controller || selection !== self.selection
    }
    func attach(controller: LawMarkController?, selection: LawTextSelection) {
        guard let controller, controller !== self.controller || selection !== self.selection else { return }
        self.controller = controller; self.selection = selection
        bar?.view.removeFromSuperview(); toast?.view.removeFromSuperview()
        let bar = UIHostingController(rootView: LawMarkBar(controller: controller, selection: selection))
        let toast = UIHostingController(rootView: LawMarkToastView(controller: controller))
        for host in [bar.view!, toast.view!] {
            host.backgroundColor = .clear
            addSubview(host)
        }
        bar.safeAreaRegions = []; toast.safeAreaRegions = []
        bar.view.alpha = 0; bar.view.isHidden = true
        bar.view.layer.shadowColor = UIColor.black.cgColor; bar.view.layer.shadowOpacity = 0.28
        bar.view.layer.shadowRadius = 10; bar.view.layer.shadowOffset = CGSize(width: 0, height: 4)
        self.bar = bar; self.toast = toast
        barVisible = false
        watching = []
        controller.objectWillChange.merge(with: selection.objectWillChange)
            .sink { [weak self] _ in self?.setNeedsReposition() }
            .store(in: &watching)
        setNeedsReposition()
    }
    /// After the published change has landed (objectWillChange comes before).
    func setNeedsReposition() {
        guard !scheduled else { return }
        scheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.scheduled = false
            self.reposition(animated: true)
        }
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        reposition(animated: false)
    }
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }
    /// Room between the selection and the bar: clear of the selection
    /// handles below and the system edit menu above.
    static let selectionGap: CGFloat = 24
    /// Height kept free for the system edit menu above a text selection.
    static let editMenuRoom: CGFloat = 52

    func reposition(animated: Bool) {
        guard let bar, let toast, let selection, let controller, bounds.width > 0 else { return }
        let reduced = UIAccessibility.isReduceMotionEnabled
        // Toast: centred at the bottom; the bar stays above it.
        var toastTop: CGFloat?
        if controller.toast != nil {
            let toastSize = toast.sizeThatFits(in: CGSize(width: bounds.width - 24, height: 120))
            toast.view.isHidden = false
            toast.view.frame = CGRect(x: (bounds.width - toastSize.width) / 2, y: bounds.height - safeAreaInsets.bottom - bottomReserve - toastSize.height - 12,
                                      width: toastSize.width, height: toastSize.height)
            toastTop = toast.view.frame.minY
        } else if !toast.view.isHidden {
            // Let the fade-out run, then stop taking touches there.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self, weak toast] in
                if self?.controller?.toast == nil { toast?.view.isHidden = true }
            }
        }
        // Bar: below the selection (the system edit menu sits above), above
        // when there is no room, always inside the view.
        let wanted = (selection.active || controller.adjusting != nil) ? anchor() : nil
        guard let rect = wanted else {
            guard barVisible else { return }
            barVisible = false
            let view = bar.view!
            UIView.animate(withDuration: reduced ? 0.1 : 0.16, delay: 0, options: [.beginFromCurrentState, .curveEaseOut]) {
                view.alpha = 0
                if !reduced { view.transform = CGAffineTransform(scaleX: 0.94, y: 0.94) }
            } completion: { _ in if !self.barVisible { view.isHidden = true; view.transform = .identity } }
            return
        }
        let limit = min(LawMarkBar.maxWidth, bounds.width - 16)
        let size = bar.sizeThatFits(in: CGSize(width: limit, height: LawMarkBar.height))
        let width = min(size.width, limit), height = LawMarkBar.height
        let top = safeAreaInsets.top + 8
        var bottom = bounds.height - safeAreaInsets.bottom - bottomReserve - 8
        if let toastTop { bottom = min(bottom, toastTop - 8) }
        // Below the selection (the edit menu sits above it); without room
        // there, above it and above where the edit menu appears.
        let gap = Self.selectionGap
        var y = rect.maxY + gap
        if y + height > bottom {
            let menu = selection.range.length > 0 || selection.pdfSelection ? Self.editMenuRoom : 0
            y = rect.minY - gap - menu - height
            if y < top { y = rect.minY - gap - height }
        }
        y = min(max(top, y), max(top, bottom - height))
        let x = min(max(8, rect.midX - width / 2), max(8, bounds.width - width - 8))
        let frame = CGRect(x: x, y: y, width: width, height: height)
        let view = bar.view!
        func place() { view.bounds = CGRect(origin: .zero, size: frame.size); view.center = CGPoint(x: frame.midX, y: frame.midY) }
        if !barVisible {
            barVisible = true
            view.transform = .identity; place(); view.isHidden = false
            // VoiceOver: the bar is new on screen; its first element is next.
            UIAccessibility.post(notification: .layoutChanged, argument: view)
            if !reduced { view.transform = CGAffineTransform(scaleX: 0.92, y: 0.92) }
            UIView.animate(withDuration: reduced ? 0.12 : 0.36, delay: 0, usingSpringWithDamping: 0.86, initialSpringVelocity: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
                view.alpha = 1; view.transform = .identity
            }
        } else if animated && view.center != CGPoint(x: frame.midX, y: frame.midY) && !reduced {
            UIView.animate(withDuration: 0.32, delay: 0, usingSpringWithDamping: 0.94, initialSpringVelocity: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
                place()
            }
        } else {
            place()
        }
    }
}

/// A coloured dot for edit-menu entries.
func lawMarkSwatchImage(_ hex: String) -> UIImage {
    UIGraphicsImageRenderer(size: CGSize(width: 18, height: 18)).image { context in
        lawMarkColor(hex).setFill()
        context.cgContext.fillEllipse(in: CGRect(x: 1, y: 1, width: 16, height: 16))
        UIColor.label.withAlphaComponent(0.3).setStroke()
        context.cgContext.strokeEllipse(in: CGRect(x: 1, y: 1, width: 16, height: 16))
    }.withRenderingMode(.alwaysOriginal)
}
