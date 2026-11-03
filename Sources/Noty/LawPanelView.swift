import SwiftUI
import NotebookCore

struct LawPanelView<Drag: Gesture>: View {
    @EnvironmentObject private var laws: LawLibraryModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Moves the window live; the workspace decides side, dock and stash on release.
    var drag: Drag
    /// What Apple Pencil does in the reader, and how the reader changes it.
    var pen = LawPenMode()
    var onPenChange: ((LawPenMode) -> Void)? = nil
    /// Room to dock at the current edge; without it the window can only float.
    var canDock = true
    /// Whether it really is docked now (the layout also needs room to dock).
    var docked = false
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Menu {
                    if canDock {
                    Button(laws.docked ? "Über dem Heft schweben" : laws.panelEdge == .bottom ? "Unter dem Heft andocken" : "Neben dem Heft andocken",
                           systemImage: laws.docked ? "rectangle.on.rectangle" : laws.panelEdge == .bottom ? "rectangle.split.1x2" : "rectangle.split.2x1") {
                        withAnimation(NotyMotion.panel(reduceMotion)) { laws.docked.toggle() }
                    }
                    }
                    // Left, right or along the bottom edge (also by dragging the bar).
                    Picker("Position", selection: Binding(get: { laws.panelEdge }, set: { edge in
                        withAnimation(NotyMotion.panel(reduceMotion)) { laws.panelEdge = edge }
                    })) {
                        Label("Links", systemImage: "rectangle.lefthalf.inset.filled").tag(LawPanelEdge.left)
                        Label("Rechts", systemImage: "rectangle.righthalf.inset.filled").tag(LawPanelEdge.right)
                        Label("Unten", systemImage: "rectangle.bottomhalf.inset.filled").tag(LawPanelEdge.bottom)
                    }.pickerStyle(.menu)
                    Button("An den Rand schieben", systemImage: laws.panelEdge == .left ? "arrow.left.to.line" : laws.panelEdge == .right ? "arrow.right.to.line" : "arrow.down.to.line") {
                        withAnimation(NotyMotion.panel(reduceMotion)) { laws.stashed = true }
                    }
                    // The only way to remove the edge tab as well; the notebook
                    // menu „Gesetzessammlung“ opens the window again.
                    Button("Ganz schließen (ohne Pfeil)", systemImage: "xmark.rectangle") { laws.panelOpen = false }
                } label: { Image(systemName: "rectangle.split.2x1").frame(width: 44, height: 36) }.accessibilityLabel("Gesetzesfenster anordnen")
                Spacer()
                Capsule().fill(.secondary).frame(width: 44, height: 5).frame(width: 80, height: 36)
                    .accessibilityLabel("Gesetzesfenster verschieben")
                Spacer()
                // Closing slides the window past its edge and leaves the arrow
                // tab, like iPad Slide Over; the reader keeps its state.
                Button { withAnimation(NotyMotion.panel(reduceMotion)) { laws.stashed = true } } label: { Image(systemName: "xmark").frame(width: 44, height: 36) }
                    .accessibilityLabel("Gesetzesfenster schließen").accessibilityHint("Bleibt als Pfeil am Bildschirmrand; das ✕ daneben schließt es ganz.")
                    .help("Schließen – bleibt als Pfeil am Rand, erneut ✕ schließt ganz")
            }.background(.ultraThinMaterial)
                // The whole bar is the grip, not only the small capsule.
                .contentShape(Rectangle())
                .gesture(drag)
            LawReaderView(inPanel: true, pen: pen, onPenChange: onPenChange)
        }.clipShape(RoundedRectangle(cornerRadius: docked ? 0 : 16))
            .overlay(RoundedRectangle(cornerRadius: docked ? 0 : 16).strokeBorder(.secondary.opacity(0.25)))
            .shadow(color: .black.opacity(docked ? 0 : 0.3), radius: 16)
    }
}
