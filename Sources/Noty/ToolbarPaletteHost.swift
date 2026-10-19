import SwiftUI
import NotebookCore

struct ToolbarPaletteHost<Content: View, Options: View>: View {
    let layout: ToolbarLayout
    @Binding var preferences: ToolbarPreferences
    @Binding var more: Bool
    let secondView: Bool
    let enabled: Bool
    let showingOptions: Bool
    let optionsWidth: Double
    @ViewBuilder let content: (ToolbarAxis) -> Content
    @ViewBuilder let options: () -> Options
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drag: PaletteDrag?
    @State private var candidate: ToolbarDock?

    private struct PaletteDrag {
        let origin: PageRect
        let axis: ToolbarAxis
        var translation: PagePoint
        var pointer: PagePoint
        var frame: PageRect { .init(x: origin.x + translation.x, y: origin.y + translation.y, width: origin.width, height: origin.height) }
        var center: PagePoint { .init(x: frame.x + frame.width / 2, y: frame.y + frame.height / 2) }
    }
    var body: some View {
        let frame = drag?.frame ?? layout.frame
        let axis = drag?.axis ?? layout.axis
        ZStack(alignment: .topLeading) {
            if drag != nil { guides.transition(.opacity).allowsHitTesting(false) }
            let stack = axis == .horizontal ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
            stack {
                grip(axis: axis)
                content(axis)
            }
            .frame(width: frame.width, height: frame.height)
            .notyPaletteGlass()
            .offset(x: frame.x, y: frame.y)
            .animation(drag == nil ? NotyMotion.palette(reduceMotion) : nil, value: frame)
            .disabled(!enabled)
            if showingOptions && drag == nil {
                let attached = layout.optionsFrame(preferredWidth: optionsWidth)
                options().frame(width: attached.width, height: attached.height)
                    .notyPaletteGlass()
                    .offset(x: attached.x, y: attached.y)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: -6)))
                    .animation(NotyMotion.palette(reduceMotion), value: attached)
                    .disabled(!enabled)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .coordinateSpace(name: "toolbar-drag-area")
        .environment(\.colorScheme, .dark)
        .sensoryFeedback(.selection, trigger: candidate)
        .animation(NotyMotion.highlight(reduceMotion), value: drag != nil)
        .animation(NotyMotion.panel(reduceMotion), value: showingOptions)
        .onChange(of: more) { old, _ in
            guard preferences.effectiveDock == .floating, drag == nil else { return }
            let oldCount = ToolbarLayout.itemCount(more: old, preferences: preferences, secondView: secondView)
            let previous = ToolbarLayout(viewport: layout.viewport, dock: .floating, floatingAxis: layout.axis,
                items: oldCount, floatingX: preferences.floatingX, floatingY: preferences.floatingY)
            let center = PagePoint(x: previous.frame.x + previous.frame.width - layout.frame.width / 2,
                                   y: previous.frame.y + previous.frame.height - layout.frame.height / 2)
            let position = layout.floatingPosition(center: center)
            preferences.floatingX = position.x; preferences.floatingY = position.y
        }
    }
    private func grip(axis: ToolbarAxis) -> some View {
        VStack(spacing: 3) {
            ForEach(0..<2, id: \.self) { _ in
                HStack(spacing: 3) {
                    ForEach(0..<3, id: \.self) { _ in Circle().frame(width: 3, height: 3) }
                }
            }
        }.foregroundStyle(.white.opacity(0.68))
            .frame(width: axis == .horizontal ? ToolbarLayout.grip : ToolbarLayout.thickness,
                   height: axis == .vertical ? ToolbarLayout.grip : ToolbarLayout.thickness)
            .contentShape(Rectangle())
            .accessibilityLabel("Werkzeugleiste bewegen")
            .accessibilityHint(preferences.dockOnly == false ? "Ziehen zum Andocken oder freien Platzieren. Doppeltippen wechselt die Ausrichtung." : "Zu einem der vier hervorgehobenen Andockpunkte ziehen.")
            .accessibilityActions {
                if preferences.dockOnly == false {
                    Button("Horizontal ausrichten") { orient(.horizontal) }
                    Button("Vertikal ausrichten") { orient(.vertical) }
                }
            }
            .onTapGesture(count: 2) { orient(axis == .horizontal ? .vertical : .horizontal) }
            .contextMenu {
                if preferences.dockOnly == false {
                    Button("Horizontal schweben", systemImage: "rectangle") { orient(.horizontal) }
                    Button("Vertikal schweben", systemImage: "rectangle.portrait") { orient(.vertical) }
                }
            }
            .gesture(DragGesture(minimumDistance: 4, coordinateSpace: .named("toolbar-drag-area"))
                .onChanged { value in
                    var current = drag ?? PaletteDrag(origin: layout.frame, axis: layout.axis,
                        translation: .init(x: 0, y: 0), pointer: .init(x: value.startLocation.x, y: value.startLocation.y))
                    current.translation = .init(x: value.translation.width, y: value.translation.height)
                    current.pointer = .init(x: value.location.x, y: value.location.y)
                    drag = current
                    candidate = layout.snapTarget(pointer: current.pointer, center: current.center, previous: candidate)
                }
                .onEnded { _ in
                    guard let current = drag else { return }
                    let target = layout.snapTarget(pointer: current.pointer, center: current.center, previous: candidate)
                    withAnimation(NotyMotion.palette(reduceMotion)) {
                        let destination = preferences.dropDestination(near: target)
                        if destination == .floating {
                            let floating = ToolbarLayout(viewport: layout.viewport, dock: .floating, floatingAxis: current.axis, items: layout.items)
                            let position = floating.floatingPosition(center: current.center)
                            preferences.floatingAxis = current.axis; preferences.floatingX = position.x; preferences.floatingY = position.y
                            preferences.dock = .floating
                        } else { preferences.dock = destination }
                        drag = nil; candidate = nil
                    }
                })
    }
    private func orient(_ axis: ToolbarAxis) {
        guard preferences.dockOnly == false else { return }
        let target = ToolbarLayout(viewport: layout.viewport, dock: .floating, floatingAxis: axis, items: layout.items)
        let position = target.floatingPosition(center: layout.center)
        withAnimation(NotyMotion.palette(reduceMotion)) {
            preferences.floatingAxis = axis; preferences.floatingX = position.x; preferences.floatingY = position.y
            preferences.dock = .floating
        }
    }
    private var guides: some View {
        ForEach([ToolbarDock.top, .bottom, .left, .right], id: \.self) { dock in
            let zone = layout.guide(for: dock)
            let active = candidate == dock
            let label = dock == .top ? "Oben" : dock == .bottom ? "Unten" : dock == .left ? "Links" : "Rechts"
            Capsule()
                .fill(active ? Color.cyan.opacity(0.28) : Color(white: 0.15).opacity(0.85))
                .overlay(Capsule().strokeBorder(active ? .cyan : .white.opacity(0.45), lineWidth: active ? 2 : 1))
                .overlay {
                    Text(active ? "\(label) · Andocken" : label).font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white).fixedSize().rotationEffect(.degrees(dock == .left ? -90 : dock == .right ? 90 : 0))
                }
                .frame(width: zone.width, height: zone.height)
                .scaleEffect(active && !reduceMotion ? 1.06 : 1)
                .shadow(color: active ? .cyan.opacity(0.45) : .black.opacity(0.2), radius: active ? 15 : 4)
                .offset(x: zone.x, y: zone.y)
                .animation(NotyMotion.highlight(reduceMotion), value: active)
        }
    }
}
