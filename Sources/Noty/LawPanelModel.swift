import SwiftUI
import NotebookCore

/// Where the law window was last: closed/parked/visible, docked/floating,
/// edge, width and height, kept across notebooks and launches. Display state
/// only; nothing of this is part of a notebook, the law store or a backup.
///
/// Owned by `LawLibraryModel` (`laws.panel`), so turning the collection off
/// in the settings can still close the window; `NotyApp` provides it as its
/// own environment object.
///
/// ## Actions (for buttons, menus, palette and keyboard commands)
///
/// Every way of opening, closing or moving the window goes through these
/// functions. Each one animates with `NotyMotion.panel` (none with Reduce
/// Motion) and returns whether anything changed. The transitions themselves
/// are `LawPanelState` (Core, with tests).
///
/// - `open()`: closed or parked → visible.
/// - `close()`: any → closed, no edge tab; edge, docking and size stay for
///   the next opening (the reading position is kept by the reader's data).
/// - `park()`: visible → parked behind the edge tab (reader state kept);
///   closed stays closed.
/// - `unpark()`: parked → visible; otherwise nothing.
/// - `toggle()`: the switch of the notebook menu, the palette, `Space l` and
///   ⇧⌘L: closed → visible, parked → visible, visible → closed.
/// - `togglePark()`: ⌥⌘L: visible → parked, parked/closed → visible.
/// - `dock(_ edge:)`: docks at `.left`, `.right` or `.bottom` and shows the
///   window. Without room to dock there (`LawPanelLayout.canDock`) it floats.
/// - `float()` / `float(_ edge:)`: floats above the notebooks (optionally at
///   another edge) and shows the window.
/// - `move(to:)`: other edge, keeping docked/floating.
///
/// Read `phase` (`.closed`, `.parked`, `.visible`) or `isVisible` for the
/// current state, e.g. for a check mark.
@MainActor
final class LawPanelModel: ObservableObject {
    static let openKey = "noty.laws.panelOpen"
    static let stashedKey = "noty.laws.panelStashed"
    static let dockedKey = "noty.laws.panelDocked"
    static let leftKey = "noty.laws.panelLeft"
    static let widthKey = "noty.laws.panelWidth"
    /// Edge of the window: `left`, `right` or `bottom` (22.10.2026). Older
    /// builds only know `leftKey`, which stays in step for the sides.
    static let edgeKey = "noty.laws.panelEdge"
    static let heightKey = "noty.laws.panelHeight"

    @Published private(set) var state: LawPanelState {
        didSet { if state != oldValue { store(state) } }
    }
    /// Live width of a side window while resizing; stored by `saveSize()`
    /// when the resize ends.
    @Published var width = UserDefaults.standard.object(forKey: LawPanelModel.widthKey) as? Double ?? 380
    /// Height of a window at the bottom edge; stored like the width.
    @Published var height = UserDefaults.standard.object(forKey: LawPanelModel.heightKey) as? Double ?? 360

    init() {
        let defaults = UserDefaults.standard
        let edge = defaults.string(forKey: Self.edgeKey).flatMap(LawPanelEdge.init(rawValue:))
            ?? (defaults.bool(forKey: Self.leftKey) ? .left : .right)
        state = LawPanelState(isOpen: defaults.bool(forKey: Self.openKey), isStashed: defaults.bool(forKey: Self.stashedKey),
                              isDocked: defaults.bool(forKey: Self.dockedKey), edge: edge)
    }

    var phase: LawPanelState.Phase { state.phase }
    var isVisible: Bool { state.isVisible }

    // MARK: Actions

    @discardableResult func open() -> Bool { change { $0.open() } }
    @discardableResult func close() -> Bool { change { $0.close() } }
    @discardableResult func park() -> Bool { change { $0.park() } }
    @discardableResult func unpark() -> Bool { change { $0.unpark() } }
    @discardableResult func toggle() -> Bool { change { $0.toggle() } }
    @discardableResult func togglePark() -> Bool { change { $0.togglePark() } }
    @discardableResult func dock(_ edge: LawPanelEdge) -> Bool { change { $0.dock(edge) } }
    @discardableResult func float(_ edge: LawPanelEdge? = nil) -> Bool { change { $0.float(edge) } }
    @discardableResult func move(to edge: LawPanelEdge) -> Bool {
        change { state in
            guard state.edge != edge else { return false }
            state.edge = edge; return true
        }
    }
    /// Releasing a drag of the bar (already inside the drag's animation).
    @discardableResult func apply(_ drop: LawPanelDrop) -> Bool { change(animated: false) { $0.apply(drop) } }
    /// Dragging past the edge (inside the drag's animation).
    @discardableResult func park(at edge: LawPanelEdge) -> Bool { change(animated: false) { $0.park(at: edge) } }

    @discardableResult private func change(animated: Bool = true, _ transition: (inout LawPanelState) -> Bool) -> Bool {
        var next = state
        guard transition(&next) else { return false }
        if animated {
            // Reduce Motion: a short fade instead of no feedback at all.
            withAnimation(NotyMotion.appear(UIAccessibility.isReduceMotionEnabled)) { state = next }
        } else {
            state = next
        }
        return true
    }

    // MARK: Older call sites

    /// Open (visible or parked). Setting `false` closes, `true` opens; prefer `open()`/`close()`.
    var isOpen: Bool {
        get { state.isOpen }
        set { _ = newValue ? open() : close() }
    }
    /// Parked at the screen edge. Setting it parks or brings out; prefer `park()`/`unpark()`.
    var stashed: Bool {
        get { state.isStashed }
        set { _ = newValue ? park() : unpark() }
    }
    /// Docked or floating, without showing a closed or parked window.
    var docked: Bool {
        get { state.isDocked }
        set { change { state in
            guard state.isDocked != newValue else { return false }
            state.isDocked = newValue; return true
        } }
    }
    var edge: LawPanelEdge {
        get { state.edge }
        set { move(to: newValue) }
    }
    var onLeft: Bool { state.edge == .left }

    func saveSize() {
        UserDefaults.standard.set(width, forKey: Self.widthKey)
        UserDefaults.standard.set(height, forKey: Self.heightKey)
    }

    private func store(_ state: LawPanelState) {
        let defaults = UserDefaults.standard
        defaults.set(state.isOpen, forKey: Self.openKey)
        defaults.set(state.isStashed, forKey: Self.stashedKey)
        defaults.set(state.isDocked, forKey: Self.dockedKey)
        defaults.set(state.edge.rawValue, forKey: Self.edgeKey)
        if state.edge.isSide { defaults.set(state.edge == .left, forKey: Self.leftKey) }
    }
}
