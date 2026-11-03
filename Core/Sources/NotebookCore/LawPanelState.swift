// Zustandsübergänge des Gesetzesfensters (docs/LAW-REWORK.md, Paket B1),
// plattformunabhängig und ohne SwiftUI testbar. Die Geometrie bleibt in
// LawPanelGeometry.swift, das Speichern und Animieren in
// Sources/Noty/LawPanelModel.swift.
import Foundation

/// Display state of the law window: closed, parked at its screen edge behind
/// a tab, or visible; plus how it is arranged (docked or floating, edge).
/// Display state only; nothing of this is part of a notebook or backup.
///
/// Arrangement (`isDocked`, `edge`) survives closing, so the next opening
/// brings the window back where it was. Opening never restores a parked
/// state: a closed window always opens visible.
public struct LawPanelState: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        /// Not shown at all, no edge tab (and no reader in the view tree).
        case closed
        /// Pushed past its screen edge; only the edge tab shows, the reader keeps its state.
        case parked
        /// On screen.
        case visible
    }

    public private(set) var isOpen: Bool
    /// Only ever true while open.
    public private(set) var isStashed: Bool
    public var isDocked: Bool
    public var edge: LawPanelEdge

    public init(isOpen: Bool = false, isStashed: Bool = false, isDocked: Bool = false, edge: LawPanelEdge = .right) {
        self.isOpen = isOpen
        self.isStashed = isOpen && isStashed
        self.isDocked = isDocked
        self.edge = edge
    }

    public var phase: Phase { !isOpen ? .closed : isStashed ? .parked : .visible }
    public var isVisible: Bool { phase == .visible }

    /// Closed or parked → visible. Returns whether anything changed.
    @discardableResult public mutating func open() -> Bool {
        set(.visible)
    }

    /// Any state → closed (no edge tab). Edge and docking stay for the next opening.
    @discardableResult public mutating func close() -> Bool {
        set(.closed)
    }

    /// Visible → parked behind the edge tab, optionally at another edge
    /// (dragging past an edge). A closed window stays closed: there is
    /// nothing to park.
    @discardableResult public mutating func park(at target: LawPanelEdge? = nil) -> Bool {
        guard isOpen else { return false }
        let movedEdge = target.map { $0 != edge } ?? false
        if let target { edge = target }
        return set(.parked) || movedEdge
    }

    /// Parked → visible. A closed or visible window stays as it is.
    @discardableResult public mutating func unpark() -> Bool {
        guard phase == .parked else { return false }
        return set(.visible)
    }

    /// The notebook menu, the palette, `Space l` and ⇧⌘L: closed → visible,
    /// parked → visible (brought out), visible → closed.
    @discardableResult public mutating func toggle() -> Bool {
        phase == .visible ? close() : open()
    }

    /// ⌥⌘L: visible → parked, parked → visible, closed → visible.
    @discardableResult public mutating func togglePark() -> Bool {
        phase == .visible ? park() : open()
    }

    /// Docks at `target` and shows the window (an explicit arrangement
    /// command is meant to be seen). Whether there is room to dock is the
    /// layout's decision (`LawPanelLayout.canDock`); without it the window floats.
    @discardableResult public mutating func dock(_ target: LawPanelEdge) -> Bool {
        let before = self
        isDocked = true; edge = target
        set(.visible)
        return self != before
    }

    /// Floats above the notebooks, optionally at another edge, and shows the window.
    @discardableResult public mutating func float(_ target: LawPanelEdge? = nil) -> Bool {
        let before = self
        isDocked = false
        if let target { edge = target }
        set(.visible)
        return self != before
    }

    /// What releasing a drag of the window's bar does.
    @discardableResult public mutating func apply(_ drop: LawPanelDrop) -> Bool {
        switch drop {
        case .stay: false
        case .float(let target): float(target)
        case .dock(let target): dock(target)
        case .stash(let target): park(at: target)
        }
    }

    @discardableResult private mutating func set(_ phase: Phase) -> Bool {
        guard phase != self.phase else { return false }
        isOpen = phase != .closed
        isStashed = phase == .parked
        return true
    }
}
