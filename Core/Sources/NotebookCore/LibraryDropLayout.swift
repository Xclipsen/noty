import Foundation

/// Where a dragged library entry would land, relative to a displayed entry.
/// Shared by the sidebar tree, the pinned tiles and the main grid/list.
public enum LibraryDropTarget: Equatable, Hashable, Sendable {
    /// Directly before/after the entry, among its siblings (insertion line).
    case before(UUID), after(UUID)
    /// Into the folder (behind its contents); `nil` is the top level.
    case into(UUID?)
    /// At the start of an expanded folder whose children follow below it.
    case intoStart(UUID)
}

/// Screen frame of one displayed row/tile in the drop coordinate space.
/// Only layout input; never stored.
public struct LibraryDropFrame: Equatable, Sendable {
    public let id: UUID
    public var minX: Double, minY: Double, maxX: Double, maxY: Double
    public var isFolder: Bool
    /// Tree rows: expanded folder whose children are shown directly below.
    public var opensBelow: Bool

    public init(id: UUID, minX: Double, minY: Double, maxX: Double, maxY: Double, isFolder: Bool, opensBelow: Bool = false) {
        self.id = id; self.minX = minX; self.minY = minY; self.maxX = maxX; self.maxY = maxY
        self.isFolder = isFolder; self.opensBelow = opensBelow
    }
    var midX: Double { (minX + maxX) / 2 }
    var height: Double { max(1, maxY - minY) }
    var width: Double { max(1, maxX - minX) }
}

/// Pure geometry → target mapping for drag & drop in the library. Positions
/// between entries only exist with manual order (`positional`); folders always
/// accept drops into their middle.
public enum LibraryDropLayout {
    /// Vertical list (sidebar tree, list view). `rows` in display order.
    /// Folder rows: upper quarter = before, middle = into, lower quarter =
    /// after (or the start of an expanded folder). Other rows: halves.
    /// Points in gaps or beyond the ends use the nearest row.
    public static func listTarget(y: Double, rows: [LibraryDropFrame], positional: Bool) -> LibraryDropTarget? {
        guard let row = nearest(rows, y: y) else { return nil }
        let fraction = min(1, max(0, (y - row.minY) / row.height))
        if row.isFolder {
            if !positional { return .into(row.id) }
            if fraction < 0.25 { return .before(row.id) }
            if fraction > 0.75 { return row.opensBelow ? .intoStart(row.id) : .after(row.id) }
            return .into(row.id)
        }
        guard positional else { return nil }
        return fraction < 0.5 ? .before(row.id) : .after(row.id)
    }

    /// Wrapping grid (main area, pinned tiles). `tiles` in display order.
    /// On a folder tile the central half (horizontally) drops into it; on the
    /// left/right part of any tile, before/after it. In gaps the nearest
    /// visual row decides, then the tile edge closest to the point.
    public static func gridTarget(x: Double, y: Double, tiles: [LibraryDropFrame], positional: Bool) -> LibraryDropTarget? {
        guard !tiles.isEmpty else { return nil }
        if let tile = tiles.first(where: { x >= $0.minX && x <= $0.maxX && y >= $0.minY && y <= $0.maxY }) {
            let fraction = (x - tile.minX) / tile.width
            if tile.isFolder && (!positional || (fraction >= 0.25 && fraction <= 0.75)) { return .into(tile.id) }
            guard positional else { return nil }
            return fraction < 0.5 ? .before(tile.id) : .after(tile.id)
        }
        guard positional else { return nil }
        // Visual row: tiles sharing the vertical band nearest to the point.
        guard let anchor = nearest(tiles, y: y) else { return nil }
        let row = tiles.filter { $0.minY < anchor.maxY && $0.maxY > anchor.minY }.sorted { $0.minX < $1.minX }
        if let next = row.first(where: { x < $0.midX }) { return .before(next.id) }
        return row.last.map { .after($0.id) }
    }

    private static func nearest(_ frames: [LibraryDropFrame], y: Double) -> LibraryDropFrame? {
        var best: LibraryDropFrame?
        var distance = Double.infinity
        for frame in frames {
            let value = y < frame.minY ? frame.minY - y : (y > frame.maxY ? y - frame.maxY : 0)
            if value < distance { best = frame; distance = value }
        }
        return best
    }
}

/// Resolved destination for `LibraryStore.place(_:in:before:)`.
public struct LibraryPlacement: Equatable, Sendable {
    public let parentID: UUID?
    public let beforeID: UUID?
    public init(parentID: UUID?, beforeID: UUID?) { self.parentID = parentID; self.beforeID = beforeID }
}

extension LibrarySnapshot {
    /// Placement of `id` for a drop at `target` in manual (index) order.
    /// nil when the drop is invalid (missing/trashed entries, a folder into
    /// itself or a subfolder) or would not change anything.
    public func placement(of id: UUID, at target: LibraryDropTarget) -> LibraryPlacement? {
        guard let dragged = items.first(where: { $0.id == id }), !isTrashed(id) else { return nil }
        func active(_ other: UUID) -> LibraryItem? {
            guard other != id, let item = items.first(where: { $0.id == other }), !isTrashed(other) else { return nil }
            return item
        }
        func siblings(_ parent: UUID?) -> [UUID] { children(of: parent).map(\.id).filter { $0 != id } }
        let result: LibraryPlacement
        switch target {
        case .before(let anchor):
            guard let item = active(anchor) else { return nil }
            result = LibraryPlacement(parentID: item.parentID, beforeID: anchor)
        case .after(let anchor):
            guard let item = active(anchor) else { return nil }
            let list = siblings(item.parentID)
            let next = list.firstIndex(of: anchor).flatMap { $0 + 1 < list.count ? list[$0 + 1] : nil }
            result = LibraryPlacement(parentID: item.parentID, beforeID: next)
        case .into(let folder):
            if let folder { guard let item = active(folder), item.isFolder else { return nil } }
            // Dropping into the current folder keeps the position.
            if dragged.parentID == folder { return nil }
            result = LibraryPlacement(parentID: folder, beforeID: nil)
        case .intoStart(let folder):
            guard let item = active(folder), item.isFolder else { return nil }
            result = LibraryPlacement(parentID: folder, beforeID: siblings(folder).first)
        }
        // A folder can never land inside itself or one of its subfolders.
        var ancestor = result.parentID
        var visited = Set<UUID>()
        while let folder = ancestor, visited.insert(folder).inserted {
            if folder == id { return nil }
            ancestor = items.first { $0.id == folder }?.parentID
        }
        if dragged.parentID == result.parentID {
            let list = children(of: result.parentID).map(\.id)
            let current = list.firstIndex(of: id).flatMap { $0 + 1 < list.count ? list[$0 + 1] : nil }
            if current == result.beforeID { return nil }
        }
        return result
    }
}

/// Display order of pinned entries. The pin itself is the index's `favorite`
/// flag; the order is a per-area display preference (stable IDs only).
public enum LibraryPinOrder {
    /// `pinned` (index order) arranged by `order`; pins missing from `order`
    /// follow in index order, unknown IDs in `order` are ignored.
    public static func arrange(_ pinned: [LibraryItem], order: [UUID]) -> [LibraryItem] {
        let rank = Dictionary(order.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { first, _ in first })
        return pinned.enumerated().sorted { lhs, rhs in
            switch (rank[lhs.element.id], rank[rhs.element.id]) {
            case let (a?, b?): return a < b
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return lhs.offset < rhs.offset
            }
        }.map(\.element)
    }

    /// New stored order after putting `id` directly before `beforeID` (nil =
    /// at the end) in the displayed order `current`.
    public static func placing(_ id: UUID, before beforeID: UUID?, in current: [UUID]) -> [UUID] {
        var order = current.filter { $0 != id }
        if let beforeID, beforeID != id, let index = order.firstIndex(of: beforeID) {
            order.insert(id, at: index)
        } else {
            order.append(id)
        }
        return order
    }

    /// `placing` for a drop target between pinned tiles; nil for other targets.
    public static func placing(_ id: UUID, at target: LibraryDropTarget, in current: [UUID]) -> [UUID]? {
        switch target {
        case .before(let anchor):
            guard anchor != id else { return nil }
            return placing(id, before: anchor, in: current)
        case .after(let anchor):
            guard anchor != id else { return nil }
            let list = current.filter { $0 != id }
            let next = list.firstIndex(of: anchor).flatMap { $0 + 1 < list.count ? list[$0 + 1] : nil }
            return placing(id, before: next, in: current)
        case .into, .intoStart:
            return nil
        }
    }
}
