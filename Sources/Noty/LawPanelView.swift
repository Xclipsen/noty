import SwiftUI
import NotebookCore

/// The law window: its own title bar (grip, arrangement menu, „An den Rand“,
/// ✕) and the reader below it. The bar is the window chrome; everything
/// under the bar's hairline belongs to `LawReaderView`, which gets the full
/// window width and the remaining height without extra insets (see
/// `LawPanelView.barHeight`).
struct LawPanelView<Drag: Gesture>: View {
    /// Height of the title bar plus its hairline; the reader starts below it.
    static var barHeight: CGFloat { 52.5 }
    @EnvironmentObject private var panel: LawPanelModel
    /// Moves the window live; the workspace decides side, dock and stash on release.
    var drag: Drag
    /// What Apple Pencil does in the reader, and how the reader changes it.
    var pen = LawPenMode()
    var onPenChange: ((LawPenMode) -> Void)? = nil
    /// Room to dock at the current edge; without it the window can only float.
    var canDock = true
    /// Whether it really is docked now (the layout also needs room to dock).
    var docked = false
    /// The window is being dragged by its bar (grip lights up).
    var dragging = false
    /// False until the window was visible once: a window parked since launch
    /// shows only its shell and loads no reader (B14).
    var loadsReader = true
    /// A second notebook is open: docking hides it until the window floats again.
    var hidesSecondNotebook = false

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: docked ? 0 : 16, style: .continuous) }

    var body: some View {
        VStack(spacing: 0) {
            bar
            Rectangle().fill(.white.opacity(0.14)).frame(height: 0.5).accessibilityHidden(true)
            Group {
                if loadsReader {
                    LawReaderView(inPanel: true, pen: pen, onPenChange: onPenChange)
                } else {
                    Color(white: 0.065).accessibilityHidden(true)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(white: 0.065))
        }
        .clipShape(shape)
        // A tap anywhere in the window gives it the keyboard shortcuts.
        .lawKeyFocusArea()
        .overlay { if !docked { shape.strokeBorder(.white.opacity(0.18), lineWidth: 1).allowsHitTesting(false) } }
        .shadow(color: .black.opacity(docked ? 0 : 0.45), radius: 18, y: 8)
        .environment(\.colorScheme, .dark)
    }

    // MARK: Title bar

    private var bar: some View {
        HStack(spacing: 0) {
            arrangeMenu
            Text("Gesetze").font(.headline).foregroundStyle(.white)
                .lineLimit(1).padding(.leading, 2)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            barButton("Gesetzesfenster an den Rand schieben", symbol: parkSymbol, tooltip: "An den Rand",
                      hint: "Bleibt als Lasche am Bildschirmrand; die Lesestelle bleibt.") { panel.park() }
            barButton("Gesetzesfenster schließen", symbol: "xmark", weight: .semibold, tooltip: "Schließen",
                      hint: "Über „Gesetzessammlung“ im Heft wieder öffnen; Lage und Größe bleiben.") { panel.close() }
        }
        .padding(.horizontal, 4).padding(.top, 8)
        .frame(height: 52)
        .overlay(alignment: .top) { grip.padding(.top, 6) }
        .lawGlass(Rectangle())
        // The whole bar is the grip, not only the dots.
        .contentShape(Rectangle())
        .gesture(drag)
        .environment(\.notyTooltipAxis, .horizontal)
    }

    private var parkSymbol: String {
        switch panel.edge { case .left: "arrow.left.to.line"; case .right: "arrow.right.to.line"; case .bottom: "arrow.down.to.line" }
    }

    private func barButton(_ label: String, symbol: String, weight: Font.Weight = .regular, tooltip: String, hint: String,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 18, weight: weight))
                .frame(width: 44, height: 44).contentShape(Rectangle())
        }
        .buttonStyle(NotyToolStyle())
        .foregroundStyle(.white)
        .accessibilityLabel(label).accessibilityHint(hint)
        .notyTooltip(tooltip)
    }

    /// Three dots like the pane strips' handle; brighter while dragging.
    private var grip: some View {
        HStack(spacing: 4) { ForEach(0..<3, id: \.self) { _ in Circle().frame(width: 5, height: 5) } }
            .foregroundStyle(.white.opacity(dragging ? 0.9 : 0.45))
            .frame(width: 44, height: 8)
            .allowsHitTesting(false)
            .accessibilityElement()
            .accessibilityLabel("Gesetzesfenster verschieben")
            .accessibilityHint("Leiste ziehen: an einen Rand andocken, schweben lassen oder über den Rand schieben.")
            .accessibilityAction(named: "An den Rand schieben") { panel.park() }
            .accessibilityAction(named: "Schließen") { panel.close() }
    }

    private var arrangeMenu: some View {
        Menu {
            if canDock {
                if panel.docked {
                    Button { panel.float() } label: {
                        Text("Über dem Heft schweben")
                        if hidesSecondNotebook { Text("Zweites Heft kommt zurück") }
                        Image(systemName: "rectangle.on.rectangle")
                    }
                } else {
                    Button { panel.dock(panel.edge) } label: {
                        Text(panel.edge == .bottom ? "Unter dem Heft andocken" : "Neben dem Heft andocken")
                        if hidesSecondNotebook { Text("Zweites Heft wird ausgeblendet") }
                        Image(systemName: panel.edge == .bottom ? "rectangle.split.1x2" : "rectangle.split.2x1")
                    }
                }
            }
            // Left, right or along the bottom edge (also by dragging the bar).
            Picker("Position", selection: Binding(get: { panel.edge }, set: { panel.move(to: $0) })) {
                Label("Links", systemImage: "rectangle.lefthalf.inset.filled").tag(LawPanelEdge.left)
                Label("Rechts", systemImage: "rectangle.righthalf.inset.filled").tag(LawPanelEdge.right)
                Label("Unten", systemImage: "rectangle.bottomhalf.inset.filled").tag(LawPanelEdge.bottom)
            }.pickerStyle(.menu)
            Section {
                Button("An den Rand schieben", systemImage: parkSymbol) { panel.park() }
                Button("Schließen", systemImage: "xmark") { panel.close() }
            }
        } label: {
            Image(systemName: "ellipsis").font(.system(size: 18))
                .frame(width: 44, height: 44).contentShape(Rectangle())
        }
        .buttonStyle(NotyToolStyle())
        .foregroundStyle(.white)
        .accessibilityLabel("Gesetzesfenster anordnen")
        .notyTooltip("Anordnen")
    }
}

/// „Gesetzessammlung“ in the notebook menu: a real switch with a check mark
/// while the window is on screen. Closed → opens, parked → brings it out,
/// visible → closes (`LawPanelModel.toggle()` through `action`).
struct LawPanelMenuToggle: View {
    @EnvironmentObject private var panel: LawPanelModel
    let action: () -> Void
    var body: some View {
        Toggle("Gesetzessammlung", systemImage: "books.vertical", isOn: Binding(get: { panel.isVisible }, set: { _ in action() }))
    }
}

/// Palette title of the same switch; the palette has no check marks of its own.
func lawPanelPaletteTitle(_ phase: LawPanelState.Phase) -> String {
    switch phase {
    case .visible: "Gesetzessammlung ✓"
    case .parked: "Gesetzessammlung (am Rand)"
    case .closed: "Gesetzessammlung"
    }
}

private struct LawGlass<S: Shape>: ViewModifier {
    let shape: S
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @ViewBuilder func body(content: Content) -> some View {
        // Same surfaces as `notyGlass`, in any shape (window bar, edge tab).
        if reduceTransparency {
            content.background(Color(white: 0.13), in: shape)
        } else if #available(iOS 26.0, *) {
            content.glassEffect(.regular.tint(.black.opacity(0.3)), in: shape)
        } else {
            content.background(.ultraThinMaterial, in: shape)
        }
    }
}

extension View {
    /// `notyGlass` for the law window's bar and edge tab.
    func lawGlass<S: Shape>(_ shape: S) -> some View { modifier(LawGlass(shape: shape)) }
}
