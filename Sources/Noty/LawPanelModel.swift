import SwiftUI
import NotebookCore

/// Where the law window was last: open/stashed, docked/floating, edge, width
/// and height, kept across notebooks and launches. Display state only; nothing
/// of this is part of a notebook, the law store or a backup.
///
/// Owned by `LawLibraryModel` (`laws.panel`), so turning the collection off
/// in the settings can still close the window; `NotyApp` provides it as its
/// own environment object.
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
    @Published var isOpen = UserDefaults.standard.bool(forKey: LawPanelModel.openKey) {
        didSet { if !isOpen { stashed = false }; UserDefaults.standard.set(isOpen, forKey: Self.openKey) }
    }
    /// Pushed past the screen edge like iPad Slide Over: hidden behind an edge
    /// tab, reader state kept. Closing the window completely clears it.
    @Published var stashed = UserDefaults.standard.bool(forKey: LawPanelModel.stashedKey) {
        didSet { UserDefaults.standard.set(stashed, forKey: Self.stashedKey) }
    }
    @Published var docked = UserDefaults.standard.bool(forKey: LawPanelModel.dockedKey) {
        didSet { UserDefaults.standard.set(docked, forKey: Self.dockedKey) }
    }
    @Published var edge: LawPanelEdge = UserDefaults.standard.string(forKey: LawPanelModel.edgeKey).flatMap(LawPanelEdge.init(rawValue:))
        ?? (UserDefaults.standard.bool(forKey: LawPanelModel.leftKey) ? .left : .right) {
        didSet {
            UserDefaults.standard.set(edge.rawValue, forKey: Self.edgeKey)
            if edge.isSide { UserDefaults.standard.set(edge == .left, forKey: Self.leftKey) }
        }
    }
    var onLeft: Bool { edge == .left }
    /// Live width of a side window while resizing; stored by `saveSize()`
    /// when the resize ends.
    @Published var width = UserDefaults.standard.object(forKey: LawPanelModel.widthKey) as? Double ?? 380
    /// Height of a window at the bottom edge; stored like the width.
    @Published var height = UserDefaults.standard.object(forKey: LawPanelModel.heightKey) as? Double ?? 360
    func saveSize() {
        UserDefaults.standard.set(width, forKey: Self.widthKey)
        UserDefaults.standard.set(height, forKey: Self.heightKey)
    }
}
