import Foundation

/// The two editor panes by identity, not by position: `.primary` is the
/// notebook the workspace was opened with. Each document still has exactly one
/// model/writer; this type only describes where a pane is displayed.
public enum SplitPane: Int, CaseIterable, Sendable {
    case primary, secondary
    public var other: SplitPane { self == .primary ? .secondary : .primary }
}

/// Position along the split axis: `.first` is left (side by side) or top (stacked).
public enum SplitSlot: Int, CaseIterable, Sendable {
    case first, second
    public var other: SplitSlot { self == .first ? .second : .first }
}

/// Display arrangement of the two editor panes in viewport points. A pure
/// display preference: never part of notebook data, backups or revisions.
public struct SplitPaneArrangement: Equatable, Sendable {
    /// Divider snap points (share of the first slot).
    public static let snapFractions: [Double] = [1.0 / 3, 0.5, 2.0 / 3]
    /// Smallest pane extent along the split axis; narrower snaps fall back.
    public static let minimumPane = 320.0
    /// Visible gap between the panes; the divider is centred in it.
    public static let gap = 6.0

    public var secondaryFirst: Bool
    public var vertical: Bool
    /// Share of the first slot; always one of `snapFractions`.
    public private(set) var fraction: Double

    public init(secondaryFirst: Bool = false, vertical: Bool = false, fraction: Double = 0.5) {
        self.secondaryFirst = secondaryFirst
        self.vertical = vertical
        self.fraction = Self.nearest(fraction, in: Self.snapFractions)
    }

    public func slot(of pane: SplitPane) -> SplitSlot {
        (pane == .secondary) == secondaryFirst ? .first : .second
    }
    public func pane(in slot: SplitSlot) -> SplitPane {
        (slot == .first) == secondaryFirst ? .secondary : .primary
    }
    /// Display order, first slot first.
    public var order: [SplitPane] { [pane(in: .first), pane(in: .second)] }

    /// Exchanges the sides. Each pane keeps its size (1/3 ↔ 2/3).
    public mutating func swapSides() {
        secondaryFirst.toggle()
        fraction = Self.nearest(1 - fraction, in: Self.snapFractions)
    }

    /// Moves `pane` into `slot` (the other pane takes the remaining slot).
    /// Returns whether the arrangement changed; dropping in place does nothing.
    @discardableResult
    public mutating func place(_ pane: SplitPane, in slot: SplitSlot) -> Bool {
        guard self.slot(of: pane) != slot else { return false }
        swapSides()
        return true
    }

    public func placing(_ pane: SplitPane, in slot: SplitSlot) -> SplitPaneArrangement {
        var copy = self
        copy.place(pane, in: slot)
        return copy
    }

    public mutating func setFraction(_ value: Double) {
        fraction = Self.nearest(value, in: Self.snapFractions)
    }

    /// Slot under a drag location along the split axis; nil if unusable.
    public static func dropSlot(at location: Double, extent: Double) -> SplitSlot? {
        guard extent.isFinite, extent > 0, location.isFinite else { return nil }
        return location < extent / 2 ? .first : .second
    }

    /// Drop slot for a point in a container of `size` (current axis).
    public func dropSlot(at point: PagePoint, in size: PageSize) -> SplitSlot? {
        vertical ? Self.dropSlot(at: point.y, extent: size.height)
            : Self.dropSlot(at: point.x, extent: size.width)
    }

    /// Snap points at which both panes keep at least `minimumPane`. Halves are
    /// always allowed, even in a container too small for any minimum.
    public static func allowedFractions(extent: Double, minimumPane: Double = minimumPane) -> [Double] {
        let usable = max(0, extent - gap)
        let allowed = snapFractions.filter { usable * min($0, 1 - $0) >= minimumPane - 1e-9 }
        return allowed.isEmpty ? [0.5] : allowed
    }

    /// The divider released at `location` (container coordinates along the
    /// axis): nearest allowed snap point.
    public static func snappedFraction(location: Double, extent: Double, minimumPane: Double = minimumPane) -> Double {
        let allowed = allowedFractions(extent: extent, minimumPane: minimumPane)
        guard extent.isFinite, extent > gap, location.isFinite else { return 0.5 }
        let raw = (location - gap / 2) / (extent - gap)
        return nearest(raw, in: allowed)
    }

    /// Stored fraction as shown in a concrete container: a third that would
    /// make a pane too small falls back to the nearest allowed snap point
    /// without changing the stored preference.
    public func effectiveFraction(extent: Double) -> Double {
        Self.nearest(fraction, in: Self.allowedFractions(extent: extent))
    }

    /// Frame of a slot in a container of `size`, panes separated by `gap`.
    public func frame(of slot: SplitSlot, in size: PageSize) -> PageRect {
        let extent = vertical ? size.height : size.width
        let usable = max(0, extent - Self.gap)
        let first = (usable * effectiveFraction(extent: extent)).rounded()
        let offset = slot == .first ? 0 : first + Self.gap
        let length = slot == .first ? first : usable - first
        return vertical ? PageRect(x: 0, y: offset, width: size.width, height: length)
            : PageRect(x: offset, y: 0, width: length, height: size.height)
    }

    public func frame(of pane: SplitPane, in size: PageSize) -> PageRect {
        frame(of: slot(of: pane), in: size)
    }

    /// Centre of the divider along the split axis.
    public func dividerPosition(in size: PageSize) -> Double {
        let first = frame(of: .first, in: size)
        return (vertical ? first.y + first.height : first.x + first.width) + Self.gap / 2
    }

    // MARK: Persistence (display preference, UserDefaults string)

    /// Compact, versioned and tolerant: `v1;s=0;v=0;f=1` (f = snap index).
    public var storageValue: String {
        let index = Self.snapFractions.firstIndex { abs($0 - fraction) < 1e-9 } ?? 1
        return "v1;s=\(secondaryFirst ? 1 : 0);v=\(vertical ? 1 : 0);f=\(index)"
    }

    /// Unknown, damaged or empty values fall back to the default arrangement.
    public init(storageValue: String) {
        self.init()
        let fields = storageValue.split(separator: ";").map(String.init)
        guard fields.first == "v1" else { return }
        for field in fields.dropFirst() {
            let pair = field.split(separator: "=", maxSplits: 1).map(String.init)
            guard pair.count == 2, let value = Int(pair[1]) else { continue }
            switch pair[0] {
            case "s" where value == 0 || value == 1: secondaryFirst = value == 1
            case "v" where value == 0 || value == 1: vertical = value == 1
            case "f" where Self.snapFractions.indices.contains(value): fraction = Self.snapFractions[value]
            default: continue
            }
        }
    }

    private static func nearest(_ value: Double, in candidates: [Double]) -> Double {
        guard value.isFinite else { return 0.5 }
        return candidates.min { abs($0 - value) < abs($1 - value) } ?? 0.5
    }
}
