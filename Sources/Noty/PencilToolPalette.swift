import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass
import NotebookCore

/// One Apple Pencil Pro squeeze phase, located in window coordinates.
struct PencilSqueezeEvent {
    var phase: PencilSqueezeTracker.Phase
    var time: TimeInterval
    var location: CGPoint
    /// Inferred from the Pencil's azimuth (iPadOS exposes no handedness setting).
    var leftHanded: Bool
    var preference: PencilSqueezeTracker.Preference

    @available(iOS 17.5, *)
    @MainActor init(_ squeeze: UIPencilInteraction.Squeeze, in view: UIView) {
        let phase: PencilSqueezeTracker.Phase = switch squeeze.phase {
        case .began: .began
        case .changed: .changed
        case .ended: .ended
        default: .cancelled
        }
        self.init(phase: phase, time: squeeze.timestamp, hover: squeeze.hoverPose.map { ($0.location, $0.azimuthUnitVector) },
                  in: view, preference: Self.preference)
    }
    /// A Pencil double tap whose system setting asks for a palette (colour
    /// palette, ink attributes): opens the Noty palette like one squeeze.
    @available(iOS 17.5, *)
    @MainActor init(tap: UIPencilInteraction.Tap, in view: UIView) {
        self.init(phase: .ended, time: tap.timestamp, hover: tap.hoverPose.map { ($0.location, $0.azimuthUnitVector) },
                  in: view, preference: .palette)
    }
    /// Double tap before iPadOS 17.5 (no tap object, no hover pose).
    @MainActor init(tapIn view: UIView) {
        self.init(phase: .ended, time: ProcessInfo.processInfo.systemUptime, hover: nil, in: view, preference: .palette)
    }
    /// Location: the hover pose (in `view`), else the last Pencil hover/touch
    /// on a page, else the centre of the visible part of `view`.
    @MainActor private init(phase: PencilSqueezeTracker.Phase, time: TimeInterval, hover: (location: CGPoint, azimuth: CGVector)?,
                            in view: UIView, preference: PencilSqueezeTracker.Preference) {
        self.phase = phase; self.time = time
        let tracker = PencilLocationTracker.shared
        if let hover {
            location = view.convert(hover.location, to: nil)
            tracker.recordAzimuth(hover.azimuth)
        } else if let last = tracker.location(in: view.window) { location = last }
        else {
            let visible = view.convert(view.bounds, to: nil).intersection(view.window?.bounds ?? .infinite)
            location = visible.isNull ? view.convert(CGPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
                : CGPoint(x: visible.midX, y: visible.midY)
        }
        leftHanded = tracker.leftHanded
        self.preference = preference
    }

    /// Apple: consult `preferredSqueezeAction`. Squeeze turned off (or a system
    /// shortcut) does nothing here; “switch to eraser/previous tool” keeps the
    /// quick toggle on one squeeze; palette-like choices (the default
    /// “Palette anzeigen”) open the Noty palette.
    @available(iOS 17.5, *)
    @MainActor static var preference: PencilSqueezeTracker.Preference {
        switch UIPencilInteraction.preferredSqueezeAction {
        case .ignore, .runSystemShortcut: .ignore
        case .switchEraser, .switchPrevious: .toggle
        default: .palette
        }
    }
}

/// Remembers where the Pencil last hovered or touched a page (window
/// coordinates) as a fallback anchor when a squeeze carries no hover pose,
/// and which way the Pencil leans (writing hand).
@MainActor
final class PencilLocationTracker: NSObject, UIGestureRecognizerDelegate {
    static let shared = PencilLocationTracker()
    private weak var window: UIWindow?
    private var point: CGPoint?
    /// Default right-handed until a clearly tilted Pencil says otherwise.
    private(set) var leftHanded = false

    func location(in window: UIWindow?) -> CGPoint? { window != nil && window === self.window ? point : nil }

    /// The azimuth vector points towards the Pencil's cap, i.e. the writing
    /// hand: cap to the right means right-handed. Near-vertical or sideways
    /// readings are ignored.
    func recordAzimuth(_ vector: CGVector) {
        guard abs(vector.dx) > 0.35 else { return }
        leftHanded = vector.dx < 0
    }

    /// Passive observers: never recognize exclusively, never delay or cancel touches.
    func observe(_ view: UIView) {
        let hover = UIHoverGestureRecognizer(target: self, action: #selector(hovered(_:)))
        hover.delegate = self
        view.addGestureRecognizer(hover)
        let touch = PencilTouchObserver { [weak self] touch in
            self?.record(touch.location(in: nil), window: touch.window)
            self?.recordAzimuth(touch.azimuthUnitVector(in: nil))
        }
        touch.delegate = self
        view.addGestureRecognizer(touch)
    }
    @objc private func hovered(_ recognizer: UIHoverGestureRecognizer) {
        guard recognizer.state == .began || recognizer.state == .changed, let window = recognizer.view?.window else { return }
        record(recognizer.location(in: nil), window: window)
        // Pointer hover reports no tilt; only a tilted Pencil updates the hand.
        if recognizer.altitudeAngle < .pi / 2 - 0.2 { recordAzimuth(recognizer.azimuthUnitVector(in: nil)) }
    }
    private func record(_ location: CGPoint, window: UIWindow?) {
        guard let window else { return }
        self.window = window; point = location
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
}

/// Reports Pencil touch-down locations and fails at once.
@MainActor
private final class PencilTouchObserver: UIGestureRecognizer {
    private let onPencil: (UITouch) -> Void
    init(onPencil: @escaping (UITouch) -> Void) {
        self.onPencil = onPencil
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false; delaysTouchesBegan = false; delaysTouchesEnded = false
    }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        if let touch = touches.first(where: { $0.type == .pencil }) { onPencil(touch) }
        state = .failed
    }
}

struct PencilPalettePresentation: Identifiable, Equatable {
    let id = UUID()
    /// Window coordinates.
    var location: CGPoint
    var leftHanded = false
}

/// Squeeze palette: a compact arc beside the Pencil tip (away from the
/// writing hand) with undo/redo, the main toolbar's drawing tools, colour,
/// width and Autostift. Shows a few items at a time; a finger or Pencil drag
/// along the arc scrolls the rest in. Tool selection goes through `onSelect`
/// (the toolbar's own selection path).
struct PencilToolPalette: View {
    let presentation: PencilPalettePresentation
    @Binding var tool: WritingTool
    @Binding var preferences: ToolbarPreferences
    /// Ink tool used before; colour/width apply to it while another tool is active
    /// (the laser pointer keeps its own colours).
    let inkTool: WritingTool
    let canUndo: Bool
    let canRedo: Bool
    let onUndo: (Bool) -> Void
    let onSelect: (WritingTool) -> Void
    let onDismiss: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var appeared = false
    @State private var detail: Detail?
    @State private var scroll: Double?
    /// Last drag location while scrolling the arc (incremental, hard-clamped).
    @State private var dragPoint: CGPoint?
    private enum Detail { case color, width }
    private enum Item: Hashable { case undo, redo, tool(WritingTool), color, width, autoPen }
    private static let itemSize: CGFloat = 40
    /// Hit target per item: the full slot spacing (46 pt ≥ 44 pt), so a
    /// Pencil tap between two glyphs still lands on one of them.
    private static let hitSize: CGFloat = 46
    private static let space = "pencil-palette"

    /// First-level tools, then the laser pointer (second toolbar level).
    private var tools: [WritingTool] { (preferences.primaryTools + preferences.secondaryTools).filter { $0 != .image && $0 != .read } }
    private var items: [Item] { [.undo, .redo] + tools.map(Item.tool) + [.color, .width, .autoPen] }
    private var dividers: [Double] { [1.5, Double(tools.count) + 1.5] }
    private var inkTarget: WritingTool { tool.isInk || tool == .shape ? tool : (inkTool.isInk ? inkTool : .pen) }
    private var widthTarget: WritingTool { tool == .precisionEraser ? .precisionEraser : inkTarget }
    private var currentColor: InkColor { tool == .laser ? preferences.laserStyle.color : preferences.inkColor(for: inkTarget) }
    private func isSelected(_ item: WritingTool) -> Bool { tool == item || (item == .strokeEraser && tool == .precisionEraser) }

    var body: some View {
        GeometryReader { proxy in
            let origin = proxy.frame(in: .global).origin
            let layout = PencilPaletteLayout(
                anchor: PagePoint(x: presentation.location.x - origin.x, y: presentation.location.y - origin.y),
                bounds: PageRect(x: 0, y: 0, width: proxy.size.width, height: proxy.size.height),
                itemCount: items.count, leftHanded: presentation.leftHanded)
            let offset = scroll ?? layout.scroll(centering: items.firstIndex { if case .tool(let t) = $0 { isSelected(t) } else { false } } ?? 0)
            ZStack(alignment: .topLeading) {
                // Any touch outside (finger or Pencil, tap or scroll) closes the palette.
                Color.black.opacity(0.001).contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onChanged { _ in onDismiss() })
                    .accessibilityHidden(true)
                arc(layout, offset: offset, size: proxy.size)
                    .simultaneousGesture(scrollGesture(layout, offset: offset))
                if let detail { detailRow(detail, layout: layout, size: proxy.size) }
            }
            .coordinateSpace(name: Self.space)
            // Rotation/split view moves the anchor: close instead of floating at a stale spot.
            .onChange(of: proxy.size) { onDismiss() }
        }
        .onChange(of: scenePhase) { _, phase in if phase != .active { onDismiss() } }
        .onChange(of: tool) { _, next in if next == .text || next == .read || next == .image { onDismiss() } }
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Werkzeugpalette")
        .accessibilityAddTraits(.isModal)
        .accessibilityAction(.escape) { onDismiss() }
        .sensoryFeedback(.selection, trigger: detail)
        .onAppear { withAnimation(reduceMotion ? .easeOut(duration: 0.08) : .spring(response: 0.16, dampingFraction: 0.9)) { appeared = true } }
    }

    /// Drag along the arc: items follow the finger/Pencil, then snap to a slot.
    /// Hard stops at both ends (no rubber band, no wrap-around); a slightly
    /// sliding Pencil tap (< 12 pt) stays a tap on the item.
    private func scrollGesture(_ layout: PencilPaletteLayout, offset: Double) -> some Gesture {
        DragGesture(minimumDistance: 12, coordinateSpace: .named(Self.space))
            .onChanged { value in
                guard layout.maximumScroll > 0 else { return }
                let previous = dragPoint ?? value.startLocation
                if dragPoint == nil { detail = nil }
                dragPoint = value.location
                scroll = layout.scrolled(scroll ?? offset, from: PagePoint(x: previous.x, y: previous.y),
                                         to: PagePoint(x: value.location.x, y: value.location.y))
            }
            .onEnded { _ in
                guard dragPoint != nil else { return }
                dragPoint = nil
                withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.85)) {
                    scroll = layout.clampedScroll((scroll ?? offset).rounded())
                }
            }
    }

    @ViewBuilder private func arc(_ layout: PencilPaletteLayout, offset: Double, size: CGSize) -> some View {
        let center = CGPoint(x: layout.center.x, y: layout.center.y)
        let half = layout.step / 2
        let band = ArcBand(center: center, radius: layout.radius, width: Self.itemSize + 8,
                           start: layout.firstAngle - half * 0.6, end: layout.angle(item: Double(layout.visibleSlots - 1), scroll: 0) + half * 0.6)
        let unit = UnitPoint(x: size.width > 0 ? center.x / size.width : 0.5, y: size.height > 0 ? center.y / size.height : 0.5)
        ZStack(alignment: .topLeading) {
            Color.clear.frame(width: size.width, height: size.height)
                .modifier(PaletteGlass(shape: band))
                .overlay { band.stroke(.white.opacity(0.14), lineWidth: 0.6).allowsHitTesting(false) }
                // A touch on the band between items must not close the palette.
                .contentShape(band).onTapGesture {}
                .accessibilityHidden(true)
                .scaleEffect(appeared || reduceMotion ? 1 : 0.85, anchor: unit)
                .opacity(appeared ? 1 : 0)
            // More items beyond either end.
            ForEach([-0.62, Double(layout.visibleSlots) - 0.38], id: \.self) { slot in
                let more = slot < 0 ? offset > 0.01 : offset < layout.maximumScroll - 0.01
                let p = layout.point(item: slot, scroll: 0)
                Circle().fill(.white.opacity(more && appeared ? 0.55 : 0)).frame(width: 4, height: 4)
                    .position(x: p.x, y: p.y).allowsHitTesting(false)
            }
            ForEach(dividers, id: \.self) { index in
                let inner = layout.point(item: index, scroll: offset, radius: layout.radius - 12)
                let outer = layout.point(item: index, scroll: offset, radius: layout.radius + 12)
                Path { path in path.move(to: CGPoint(x: inner.x, y: inner.y)); path.addLine(to: CGPoint(x: outer.x, y: outer.y)) }
                    .stroke(.white.opacity(0.28), lineWidth: 1)
                    .opacity(appeared ? layout.visibility(item: index, scroll: offset) : 0)
                    .allowsHitTesting(false)
            }
            ForEach(Array(items.enumerated()), id: \.element) { index, item in
                let visibility = layout.visibility(item: Double(index), scroll: offset)
                let p = layout.point(item: Double(index), scroll: offset)
                view(for: item)
                    .frame(width: Self.hitSize, height: Self.hitSize)
                    .scaleEffect(appeared || reduceMotion ? 0.7 + 0.3 * visibility : 0.6)
                    .opacity(appeared ? visibility : 0)
                    .position(appeared || reduceMotion ? CGPoint(x: p.x, y: p.y) : center)
                    .allowsHitTesting(visibility > 0.6)
                    .accessibilityHidden(visibility < 0.6)
                    .animation(reduceMotion || dragPoint != nil ? nil : .spring(response: 0.16, dampingFraction: 0.9), value: appeared)
            }
        }
    }

    @ViewBuilder private func view(for item: Item) -> some View {
        switch item {
        case .undo: symbolButton("Rückgängig", symbol: "arrow.uturn.backward", enabled: canUndo) { onUndo(false) }
        case .redo: symbolButton("Wiederholen", symbol: "arrow.uturn.forward", enabled: canRedo) { onUndo(true) }
        case .tool(let value): toolButton(value)
        case .color: colorButton
        case .width: widthButton
        case .autoPen:
            let pencil = inkTarget == .pencil
            let on = preferences.automaticInk(for: pencil ? .pencil : .pen)
            Button {
                // The pen's Autostift also drives the pencil unless it was set apart.
                preferences.setAutomaticInk(!on, for: pencil ? .pencil : .pen)
                if !on, pencil ? tool != .pencil : (tool != .pen && tool != .shape) { onSelect(pencil ? .pencil : .pen) }
                onDismiss()
            } label: {
                Image(systemName: on ? "a.circle.fill" : "a.circle").font(.system(size: 20, weight: .medium))
                    .foregroundStyle(on ? Color(red: 0.62, green: 0.84, blue: 1) : .white.opacity(0.9))
                    .frame(width: Self.hitSize, height: Self.hitSize).contentShape(Circle())
            }.buttonStyle(NotyPressStyle()).accessibilityLabel("Autostift")
                .accessibilityValue(on ? "Ein" : "Aus").accessibilityHint("Schwarz oder Weiß passend zum Hintergrund.")
        }
    }

    private func toolButton(_ item: WritingTool) -> some View {
        let selected = isSelected(item)
        return Button { if !selected { onSelect(item) }; onDismiss() } label: {
            ToolbarGlyph(tool: item, selected: selected, markerTip: preferences.effectiveMarkerTip)
                .scaleEffect(0.86)
                .frame(width: Self.itemSize, height: Self.itemSize)
                .background {
                    if selected {
                        Circle().fill(LinearGradient(colors: [.white.opacity(0.2), .blue.opacity(0.2)], startPoint: .topLeading, endPoint: .bottomTrailing))
                            .overlay(Circle().strokeBorder(.white.opacity(0.3), lineWidth: 0.6))
                    }
                }
                .frame(width: Self.hitSize, height: Self.hitSize).contentShape(Circle())
        }.buttonStyle(NotyPressStyle())
            .accessibilityLabel(item == .strokeEraser ? "Radierer" : item.title)
            .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func symbolButton(_ title: String, symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 16, weight: .medium)).foregroundStyle(.white.opacity(0.9))
                .frame(width: Self.hitSize, height: Self.hitSize).contentShape(Circle())
                .opacity(enabled ? 1 : 0.35)
        }.buttonStyle(NotyPressStyle()).disabled(!enabled).accessibilityLabel(title)
    }

    private var colorButton: some View {
        Button { detail = detail == .color ? nil : .color } label: {
            Circle().fill(currentColor.color)
                .overlay(Circle().strokeBorder(.white.opacity(detail == .color ? 0.95 : 0.6), lineWidth: detail == .color ? 2.5 : 1.2))
                .frame(width: 28, height: 28).frame(width: Self.hitSize, height: Self.hitSize).contentShape(Circle())
        }.buttonStyle(NotyPressStyle()).accessibilityLabel("Farbe").accessibilityValue(tool == .laser ? tool.title : inkTarget.title)
    }

    private var widthButton: some View {
        let value = width(of: widthTarget)
        return Button { detail = detail == .width ? nil : .width } label: {
            Circle().fill(.white.opacity(detail == .width ? 0.28 : 0.14))
                .overlay(Circle().fill(.white).frame(width: dot(value, for: widthTarget), height: dot(value, for: widthTarget)))
                .frame(width: 32, height: 32).frame(width: Self.hitSize, height: Self.hitSize).contentShape(Circle())
        }.buttonStyle(NotyPressStyle()).accessibilityLabel("Breite").accessibilityValue(value.formatted())
    }

    /// Colour/width choices just outside the arc, away from the tip and hand.
    @ViewBuilder private func detailRow(_ detail: Detail, layout: PencilPaletteLayout, size: CGSize) -> some View {
        let count = detail == .color ? swatches.count + 1 : widths.count
        let rowWidth = CGFloat(count) * 40 + 12
        let raw = CGPoint(x: layout.center.x + (layout.radius + 54) * cos(layout.direction),
                          y: layout.center.y + (layout.radius + 54) * sin(layout.direction))
        let x = min(max(raw.x, rowWidth / 2 + 8), max(rowWidth / 2 + 8, size.width - rowWidth / 2 - 8))
        let y = min(max(raw.y, 30), max(30, size.height - 30))
        HStack(spacing: 0) {
            if detail == .color {
                ForEach(Array(swatches.enumerated()), id: \.offset) { _, color in
                    Button { apply(color: color); onDismiss() } label: {
                        Circle().fill(color.color)
                            .overlay(Circle().strokeBorder(.white.opacity(same(color, currentColor) ? 0.95 : 0.35), lineWidth: same(color, currentColor) ? 2.5 : 1))
                            .frame(width: 26, height: 26).frame(width: 40, height: 40).contentShape(Circle())
                    }.buttonStyle(NotyPressStyle()).accessibilityLabel("Farbe")
                }
                ColorPicker("Weitere Farbe", selection: Binding(get: { currentColor.color }, set: { apply(color: InkColor($0)) }))
                    .labelsHidden().frame(width: 40, height: 40)
            } else {
                ForEach(widths, id: \.self) { value in
                    let current = width(of: widthTarget)
                    let nearest = widths.min { abs($0 - current) < abs($1 - current) } == value
                    Button { apply(width: value); onDismiss() } label: {
                        Circle().fill(.white).frame(width: dot(value, for: widthTarget), height: dot(value, for: widthTarget))
                            .frame(width: 40, height: 40)
                            .background(Circle().fill(.white.opacity(nearest ? 0.2 : 0)).frame(width: 34, height: 34))
                            .contentShape(Circle())
                    }.buttonStyle(NotyPressStyle()).accessibilityLabel("Breite \(value.formatted())")
                        .accessibilityAddTraits(nearest ? .isSelected : [])
                }
            }
        }
        .padding(.horizontal, 6).frame(height: 48)
        .modifier(PaletteGlass(shape: Capsule()))
        .overlay(Capsule().strokeBorder(.white.opacity(0.14), lineWidth: 0.6))
        .position(x: x, y: y)
        .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.9)))
    }

    // MARK: Colour and width

    private var swatches: [InkColor] {
        if tool == .laser { return LaserPointerView.colors.map(\.color) }
        let target = inkTarget == .shape ? .pen : inkTarget
        let favorites = preferences.presets.filter { $0.tool == target }.map(\.color)
        let standard: [InkColor] = switch target {
        case .marker: [InkColor(1, 1, 0), InkColor(0.55, 1, 0.45), InkColor(1, 0.55, 0.8), InkColor(0.45, 0.8, 1), InkColor(1, 0.7, 0.3)]
        case .pencil: [ToolbarPreferences.defaultPencilColor, InkColor(0, 0, 0), InkColor(0.05, 0.3, 0.85), InkColor(0.85, 0.12, 0.12), InkColor(1, 1, 1)]
        default: [InkColor(0, 0, 0), InkColor(0.05, 0.3, 0.85), InkColor(0.85, 0.12, 0.12), InkColor(0.1, 0.55, 0.25), InkColor(1, 1, 1)]
        }
        var result: [InkColor] = []
        for color in favorites + standard where !result.contains(where: { same($0, color) }) { result.append(color) }
        return Array(result.prefix(8))
    }
    private func same(_ a: InkColor, _ b: InkColor) -> Bool {
        abs(a.red - b.red) < 0.01 && abs(a.green - b.green) < 0.01 && abs(a.blue - b.blue) < 0.01 && abs(a.alpha - b.alpha) < 0.01
    }
    private func apply(color: InkColor) {
        if tool == .laser { preferences.laserColor = color; return }
        preferences.setInkColor(color, for: inkTarget)
        if tool != inkTarget { onSelect(inkTarget) }
    }
    private var widths: [Double] {
        switch widthTarget {
        case .marker: [6, 10, 14, 22, 32]
        case .pencil: [2, 3, 5, 8, 12]
        case .precisionEraser: [6, 12, 20, 32, 48]
        default: [1, 2, 3.5, 6, 10]
        }
    }
    private func width(of target: WritingTool) -> Double { preferences.inkWidth(for: target) }
    private func apply(width value: Double) {
        preferences.setInkWidth(value, for: widthTarget)
        if tool != widthTarget { onSelect(widthTarget) }
    }
    /// Preview dot diameter within the slider range of each tool.
    private func dot(_ value: Double, for target: WritingTool) -> CGFloat {
        let range: ClosedRange<Double> = target == .precisionEraser ? 4...60 : ToolbarPreferences.widthRange(for: target) ?? 1...12
        let fraction = (min(max(value, range.lowerBound), range.upperBound) - range.lowerBound) / (range.upperBound - range.lowerBound)
        return 3 + 15 * sqrt(fraction)
    }
}

/// Thick round-capped arc segment, used as the glass band behind the items.
private struct ArcBand: Shape {
    var center: CGPoint
    var radius: Double
    var width: Double
    var start: Double
    var end: Double
    func path(in rect: CGRect) -> Path {
        var arc = Path()
        arc.addArc(center: center, radius: radius, startAngle: .radians(start), endAngle: .radians(end), clockwise: false)
        return arc.strokedPath(StrokeStyle(lineWidth: width, lineCap: .round))
    }
}

/// `notyGlass` for arbitrary shapes, darker like the system Pencil palette.
private struct PaletteGlass<S: Shape>: ViewModifier {
    let shape: S
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @ViewBuilder func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(Color(white: 0.11), in: shape)
        } else if #available(iOS 26.0, *) {
            content.glassEffect(.regular.tint(.black.opacity(0.45)), in: shape)
        } else {
            content.background(Color.black.opacity(0.35), in: shape).background(.ultraThinMaterial, in: shape)
        }
    }
}
