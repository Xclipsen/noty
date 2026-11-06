import SwiftUI
import NotebookCore

/// The law window: its own title bar (grip, the title „Gesetze ⌄“ as the
/// arrangement menu, „An den Rand“, ✕) and the reader below it. The bar is
/// the window chrome; everything under the bar's hairline belongs to
/// `LawReaderView`, which gets the full window width and the remaining
/// height without extra insets (see `LawPanelView.barHeight`). While the
/// window has the keys (`LawKeyboard.focused`) the title is bright and a
/// 2-pt accent line runs under the bar. In an app window (not full screen)
/// the bar starts with a strip that moves the app window instead
/// (`windowDragClearance`, see `LawWindowDrag.swift`).
struct LawPanelView: View {
    /// Height of the title bar plus its hairline (without the app-window
    /// strip); the reader starts below it.
    static var barHeight: CGFloat { 52.5 }
    @EnvironmentObject private var panel: LawPanelModel
    @ObservedObject private var keyboard = LawKeyboard.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Moves the window live; the workspace decides side, dock and stash on release.
    var move: LawMoveActions
    /// Named coordinate space the move is measured in (the workspace).
    var moveSpace: String
    /// Top strip of the bar left to the app window's own drag (0 full screen).
    var windowDragClearance: CGFloat = 0
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

    /// Lets the app-window strip wait for the bar's pan.
    @State private var dragLink = LawWindowDragLink()

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: docked ? 0 : 16, style: .continuous) }
    private var focused: Bool { keyboard.focused }

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
        // The whole window and a near-miss band around it (bar, grip, resize
        // handle, rounded corners) keep notebook ink from starting there.
        .pencilGuard(margin: docked ? 8 : 12, active: panel.isVisible)
        .environment(\.colorScheme, .dark)
    }

    // MARK: Title bar

    private var bar: some View {
        VStack(spacing: 0) {
            if windowDragClearance > 0 {
                // Grabbing here moves the app window, not the law window.
                AppWindowDragStrip(link: dragLink)
                    .frame(height: windowDragClearance)
                    .accessibilityHidden(true)
            }
            controls
        }
        // Keyboard focus: an accent line along the bar's lower edge (the
        // layout keeps its 0.5-pt hairline, the reader does not move).
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.notyAccent).frame(height: 2)
                .opacity(focused ? 1 : 0)
                .allowsHitTesting(false).accessibilityHidden(true)
        }
        .animation(NotyMotion.highlight(reduceMotion), value: focused)
        .lawGlass(Rectangle())
        .environment(\.notyTooltipAxis, .horizontal)
    }

    /// Title menu, „An den Rand“, ✕ and the grip; the whole row is the grip.
    private var controls: some View {
        HStack(spacing: 0) {
            titleMenu
            Spacer(minLength: 8)
            barButton("An den Rand schieben", symbol: parkSymbol, tooltip: keyHint("An den Rand", "window.park"),
                      hint: "Bleibt als Lasche am Bildschirmrand; die Lesestelle bleibt.") { panel.park() }
            barButton("Gesetzessammlung schließen", symbol: "xmark", weight: .semibold, tooltip: keyHint("Schließen", "window.toggle"),
                      hint: "Wieder öffnen: Heft-Menü › Gesetzessammlung oder ⇧⌘L.") { panel.close() }
        }
        .padding(.horizontal, 4).padding(.top, 8)
        .frame(height: 52)
        .overlay(alignment: .top) { grip.padding(.top, 6) }
        // The whole row is the grip, not only the dots.
        .contentShape(Rectangle())
        .lawWindowMove(space: moveSpace, link: dragLink, actions: move)
    }

    private var parkSymbol: String {
        switch panel.edge { case .left: "arrow.left.to.line"; case .right: "arrow.right.to.line"; case .bottom: "arrow.down.to.line" }
    }
    private func keyHint(_ text: String, _ id: String) -> String {
        LawShortcuts.shortcut(id: id)?.combo.map { "\(text) (\($0.label))" } ?? text
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
            .accessibilityLabel("Gesetzessammlung verschieben")
            .accessibilityHint("Leiste ziehen: an einen Rand andocken, schweben lassen oder über den Rand schieben.")
            .accessibilityAction(named: "An den Rand schieben") { panel.park() }
            .accessibilityAction(named: "Schließen") { panel.close() }
    }

    /// The title is the arrangement menu („Gesetze ⌄“); bright while the
    /// window has the keyboard focus, dimmed otherwise.
    private var titleMenu: some View {
        Menu {
            if panel.docked {
                Button { panel.float() } label: {
                    Text("Über dem Heft schweben")
                    if hidesSecondNotebook { Text("Zweites Heft kommt zurück") }
                    Image(systemName: "rectangle.on.rectangle")
                }
            } else {
                // Shown also without room, so the way is visible.
                Button { panel.dock(panel.edge) } label: {
                    Text(panel.edge == .bottom ? "Unter dem Heft andocken" : "Neben dem Heft andocken")
                    if !canDock { Text("Braucht mehr Breite") } else if hidesSecondNotebook { Text("Zweites Heft wird ausgeblendet") }
                    Image(systemName: panel.edge == .bottom ? "rectangle.split.1x2" : "rectangle.split.2x1")
                }
                .disabled(!canDock)
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
            HStack(spacing: 5) {
                Text("Gesetze").font(.headline).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(.white.opacity(focused ? 1 : 0.55))
            .padding(.horizontal, 10).frame(minHeight: 44).contentShape(Rectangle())
        }
        .buttonStyle(NotyToolStyle())
        .accessibilityLabel("Gesetze, Fenster anordnen")
        .accessibilityValue(focused ? "Tastaturfokus" : "")
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

/// Palette title of the same switch, worded like the menu bar: what the
/// command does now.
func lawPanelPaletteTitle(_ phase: LawPanelState.Phase) -> String {
    switch phase {
    case .visible: "Gesetzessammlung schließen"
    case .parked: "Gesetzessammlung vom Rand holen"
    case .closed: "Gesetzessammlung öffnen"
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
