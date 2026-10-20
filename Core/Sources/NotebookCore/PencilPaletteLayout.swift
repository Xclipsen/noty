import Foundation

/// Compact, scrollable arc for the Pencil squeeze palette. The arc sits beside
/// the Pencil tip on the side away from the writing hand (upper left for
/// right-handed writers, mirrored for left-handed ones), shows at most
/// `visibleSlots` items and scrolls along itself to reveal the rest. Near
/// screen edges it turns to the first direction that fits and is shifted
/// inward only if none does. Angles use screen coordinates (y grows
/// downwards): -π/2 points up; item angles increase clockwise.
public struct PencilPaletteLayout: Equatable, Sendable {
    /// Arc centre (the Pencil tip unless shifted to stay on screen).
    public var center: PagePoint
    public var radius: Double
    /// Bisector of the visible arc.
    public var direction: Double
    /// Angle between neighbouring items.
    public var step: Double
    /// Angle of the first visible slot.
    public var firstAngle: Double
    public var visibleSlots: Int
    public var itemCount: Int
    /// Largest scroll offset (in items); 0 when everything fits.
    public var maximumScroll: Double { Double(max(0, itemCount - visibleSlots)) }

    /// Preference order for right-handed writers; mirrored horizontally for left-handed ones.
    public static func directions(leftHanded: Bool) -> [Double] {
        let right: [Double] = [-.pi * 3 / 4, -.pi / 2, .pi, .pi * 3 / 4, -.pi / 4, 0, .pi / 2, .pi / 4]
        return leftHanded ? right.map { normalized(.pi - $0) } : right
    }

    public init(anchor: PagePoint, bounds: PageRect, itemCount: Int, visibleSlots: Int = 5, leftHanded: Bool = false,
                itemDiameter: Double = 40, spacing: Double = 46, minimumRadius: Double = 96,
                maximumSpan: Double = .pi / 2, margin: Double = 6) {
        let slots = max(1, min(itemCount, visibleSlots))
        let length = Double(slots - 1) * spacing
        let radius = max(minimumRadius, length / maximumSpan)
        let step = spacing / radius
        let span = Double(slots - 1) * step
        let inset = itemDiameter / 2 + margin
        func place(_ direction: Double, center: PagePoint) -> [PagePoint] {
            (0..<slots).map { slot in
                let angle = direction - span / 2 + Double(slot) * step
                return PagePoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
            }
        }
        func shift(_ low: Double, _ high: Double, _ start: Double, _ size: Double) -> Double {
            if high - low > size { return start + size / 2 - (low + high) / 2 }
            if low < start { return start - low }
            if high > start + size { return start + size - high }
            return 0
        }
        /// Inward shift that keeps every visible slot on screen; centred if the arc is larger than the bounds.
        func correction(_ points: [PagePoint]) -> (x: Double, y: Double, excess: Double) {
            guard let minX = points.map(\.x).min(), let maxX = points.map(\.x).max(),
                  let minY = points.map(\.y).min(), let maxY = points.map(\.y).max() else { return (0, 0, 0) }
            let excess = max(0, maxX - minX + 2 * inset - bounds.width) + max(0, maxY - minY + 2 * inset - bounds.height)
            return (shift(minX - inset, maxX + inset, bounds.x, bounds.width),
                    shift(minY - inset, maxY + inset, bounds.y, bounds.height), excess)
        }
        // Prefer the first direction that fits as is, otherwise the one needing the smallest shift.
        let candidates = Self.directions(leftHanded: leftHanded)
        var best = (direction: candidates[0], cost: Double.infinity, dx: 0.0, dy: 0.0)
        for direction in candidates {
            let fix = correction(place(direction, center: anchor))
            let cost = fix.excess * 1_000_000 + hypot(fix.x, fix.y)
            if cost < best.cost { best = (direction, cost, fix.x, fix.y) }
            if cost == 0 { break }
        }
        center = PagePoint(x: anchor.x + best.dx, y: anchor.y + best.dy)
        self.radius = radius
        self.step = step
        direction = best.direction
        firstAngle = best.direction - span / 2
        self.visibleSlots = slots
        self.itemCount = max(0, itemCount)
    }

    /// Angle of item `index` (fractional for dividers) at a scroll offset.
    public func angle(item index: Double, scroll: Double) -> Double { firstAngle + (index - scroll) * step }
    public func point(item index: Double, scroll: Double, radius: Double? = nil) -> PagePoint {
        let angle = angle(item: index, scroll: scroll), r = radius ?? self.radius
        return PagePoint(x: center.x + r * cos(angle), y: center.y + r * sin(angle))
    }
    /// Visibility in 0...1: fully shown inside the visible slots, fading over half a slot beyond.
    public func visibility(item index: Double, scroll: Double) -> Double {
        let slot = index - scroll
        let outside = max(0, -slot, slot - Double(visibleSlots - 1))
        return max(0, 1 - outside * 2)
    }
    /// Items fading out beyond the visible slots take no touches below this visibility.
    public static let interactiveVisibility = 0.6
    public func isInteractive(item index: Int, scroll: Double) -> Bool {
        visibility(item: Double(index), scroll: scroll) > Self.interactiveVisibility
    }
    /// Item under `point` at a scroll offset: the nearest interactive one
    /// within `hitRadius` (half the slot spacing, so the band has no gaps).
    public func item(at point: PagePoint, scroll: Double, hitRadius: Double = 23) -> Int? {
        guard point.x.isFinite, point.y.isFinite, scroll.isFinite else { return nil }
        var best: (index: Int, distance: Double)?
        for index in 0..<itemCount where isInteractive(item: index, scroll: scroll) {
            let p = self.point(item: Double(index), scroll: scroll)
            let distance = hypot(p.x - point.x, p.y - point.y)
            if distance <= hitRadius, distance < best?.distance ?? .infinity { best = (index, distance) }
        }
        return best?.index
    }
    public func clampedScroll(_ value: Double) -> Double { min(max(0, value), maximumScroll) }
    /// Scroll so that `index` sits as close to the middle slot as possible.
    public func scroll(centering index: Int) -> Double {
        clampedScroll((Double(index) - Double(visibleSlots - 1) / 2).rounded(.down))
    }
    /// Scroll change for a drag along the arc from one point to another (items follow the finger).
    public func scrollDelta(from start: PagePoint, to end: PagePoint) -> Double {
        let a = atan2(start.y - center.y, start.x - center.x), b = atan2(end.y - center.y, end.x - center.x)
        return -Self.normalized(b - a) / step
    }
    /// One incremental drag step, hard-clamped to `0...maximumScroll`: the
    /// palette has a firm end in both directions (no rubber band). Applying
    /// small steps instead of the whole drag never wraps around at ±π, so
    /// circling past an end cannot jump to the other one. Steps near the
    /// centre (unstable angle) are ignored.
    public func scrolled(_ scroll: Double, from start: PagePoint, to end: PagePoint) -> Double {
        let near = radius * 0.3
        guard scroll.isFinite, [start.x, start.y, end.x, end.y].allSatisfy(\.isFinite),
              hypot(start.x - center.x, start.y - center.y) >= near,
              hypot(end.x - center.x, end.y - center.y) >= near else { return clampedScroll(scroll.isFinite ? scroll : 0) }
        return clampedScroll(scroll + scrollDelta(from: start, to: end))
    }

    static func normalized(_ angle: Double) -> Double {
        var value = angle.truncatingRemainder(dividingBy: 2 * .pi)
        if value > .pi { value -= 2 * .pi }
        if value <= -.pi { value += 2 * .pi }
        return value
    }
}

/// One entry of the Pencil quick palette.
public enum PencilPaletteItem: Hashable, Sendable {
    case undo, redo, tool(WritingTool), color, width, autoPen
}

/// Fixed item order of the Pencil quick palette (20.10.2026), independent of
/// the active tool: redo, undo, then the main group pen, pencil, highlighter,
/// eraser, text. The standard position (`standardScroll`) shows undo and the
/// main group; redo sits just before undo and appears after scrolling back
/// one slot (Build-50 feedback). Scrolling forward reveals the other tools
/// (first toolbar level before the second, each in its saved order), then
/// colour, width and Autostift. Groups are separated by dividers.
public struct PencilPaletteContent: Equatable, Sendable {
    public static let mainTools: [WritingTool] = [.pen, .pencil, .marker, .strokeEraser, .text]
    /// Slots visible at once: undo plus the main group.
    public static let visibleSlots = 1 + mainTools.count
    /// Scroll offset of the standard position: redo stays hidden before undo.
    public static let standardScroll = 1.0
    public let items: [PencilPaletteItem]
    /// Separator positions between groups (half-way between two items).
    public let dividers: [Double]

    /// `tools`: the toolbar's tools in display order. The precision eraser is
    /// reached through the eraser; the legacy lasso ID counts as the lasso.
    public init(tools: [WritingTool]) {
        var rest: [WritingTool] = []
        for raw in tools {
            let tool: WritingTool = raw == .selection ? .inkSelection : raw
            guard tool != .precisionEraser, !Self.mainTools.contains(tool), !rest.contains(tool) else { continue }
            rest.append(tool)
        }
        let groups: [[PencilPaletteItem]] = [[.redo, .undo], Self.mainTools.map(PencilPaletteItem.tool), rest.map(PencilPaletteItem.tool),
                                             [.color, .width, .autoPen]]
        var items: [PencilPaletteItem] = [], dividers: [Double] = []
        for group in groups where !group.isEmpty {
            if !items.isEmpty { dividers.append(Double(items.count) - 0.5) }
            items += group
        }
        self.items = items
        self.dividers = dividers
    }
    public init(preferences: ToolbarPreferences) { self.init(tools: preferences.primaryTools + preferences.secondaryTools) }

    /// Largest scroll offset with `visibleSlots` shown.
    public var maximumScroll: Double { Double(max(0, items.count - Self.visibleSlots)) }
}

/// One finger or Pencil touch on the palette arc: either a tap on an item or a
/// scroll along the arc, never both. Once the touch has moved `slop` from
/// where it went down it scrolls for good, and its lift selects nothing —
/// even though the items follow the touch and the lift lands on an item again.
public struct PencilPaletteTouch: Equatable, Sendable {
    /// A slightly sliding Pencil tap below this distance stays a tap.
    public static let slop: Double = 12
    public let start: PagePoint
    /// Item under the touch-down point (nil between or outside the items).
    public let item: Int?
    public private(set) var isScrolling = false
    private var last: PagePoint

    public init(at start: PagePoint, item: Int?) {
        self.start = start; self.item = item; last = start
    }

    /// Item shown as pressed while the touch may still become a tap.
    public var pressedItem: Int? { isScrolling ? nil : item }

    /// Moves the touch to `point`; returns the new scroll offset (unchanged while still a possible tap).
    public mutating func move(to point: PagePoint, scroll: Double, in layout: PencilPaletteLayout) -> Double {
        if !isScrolling {
            guard distance(to: point) >= Self.slop else { return scroll }
            isScrolling = true
        }
        // The first scroll step catches up from the touch-down point: items follow the touch.
        defer { last = point }
        return layout.scrolled(scroll, from: last, to: point)
    }

    /// Lift at `point`: the item to activate, only for a touch that never scrolled.
    public func end(at point: PagePoint) -> Int? {
        guard !isScrolling, distance(to: point) < Self.slop else { return nil }
        return item
    }

    private func distance(to point: PagePoint) -> Double { hypot(point.x - start.x, point.y - start.y) }
}

/// Where the palette opens: at the standard position (undo and the main
/// group, redo hidden just before them) or — within `retention` after it closed — at the position it
/// was closed at, i.e. with the same icons visible.
public struct PencilPaletteMemory: Equatable, Sendable {
    public static let retention: TimeInterval = 10
    public static let standardScroll = PencilPaletteContent.standardScroll
    public private(set) var scroll: Double?
    public private(set) var closedAt: TimeInterval?
    public init() {}

    /// The palette closed at `scroll` (snapped to a whole slot).
    public mutating func close(scroll: Double, at time: TimeInterval) {
        guard scroll.isFinite, time.isFinite else { self = .init(); return }
        self.scroll = max(0, scroll.rounded()); closedAt = time
    }

    /// Scroll offset for a palette opening at `time`. A clock that went
    /// backwards counts as expired.
    public func openingScroll(at time: TimeInterval) -> Double {
        guard let scroll, let closedAt, time.isFinite, time >= closedAt, time - closedAt < Self.retention else { return Self.standardScroll }
        return scroll
    }
}

/// Apple Pencil Pro squeeze handling. A single squeeze opens the palette
/// after the short `showDelay` (`schedule`, confirmed with `fire`). A second
/// squeeze within `doubleInterval` of the first release cancels a pending
/// show and runs the quick action (eraser ↔ last ink tool); if the palette
/// already appeared in the meantime, the second press closes it at once
/// (`dismiss` on began) and its release toggles. Double squeezing therefore
/// never leaves the palette open. A later squeeze while open closes it.
public struct PencilSqueezeTracker: Equatable, Sendable {
    public enum Phase: Sendable { case began, changed, ended, cancelled }
    /// System squeeze preference, reduced to what the editor distinguishes.
    public enum Preference: Sendable { case palette, toggle, ignore }
    public enum Outcome: Equatable, Sendable {
        case none, dismiss, toggle
        /// Show the palette after `showDelay` unless `fire(token)` returns false.
        case schedule(Int)
    }

    /// Delay before a single squeeze shows the palette (was 0.3 s until Build 44).
    public static let showDelay: TimeInterval = 0.16
    /// Time after the first squeeze's release in which a second squeeze counts as double.
    public static let doubleInterval: TimeInterval = 0.35
    private var pending: Int?
    private var release: TimeInterval?
    private var token = 0
    private var secondPending = false
    private var sawBegan = false
    public init() {}

    public mutating func handle(_ phase: Phase, at time: TimeInterval, showing: Bool, preference: Preference = .palette) -> Outcome {
        switch preference {
        case .ignore: reset(); return .none
        case .toggle: if phase == .ended { reset(); return .toggle }; return .none
        case .palette: break
        }
        func quick() -> Bool { release.map { time - $0 >= 0 && time - $0 <= Self.doubleInterval } ?? false }
        switch phase {
        case .began:
            sawBegan = true
            guard quick() else { return .none }
            secondPending = true; pending = nil; release = nil
            return showing ? .dismiss : .none
        case .changed: return .none
        case .cancelled:
            sawBegan = false; secondPending = false
            return .none
        case .ended:
            // Without a reported began the release time itself must be quick.
            let double = secondPending || (!sawBegan && quick())
            sawBegan = false; secondPending = false; pending = nil
            if double { release = nil; return .toggle }
            if showing { release = nil; return .dismiss }
            token += 1
            pending = token; release = time
            return .schedule(token)
        }
    }

    /// The show delay has passed: true if the palette should appear now.
    public mutating func fire(_ token: Int) -> Bool {
        guard pending == token, !secondPending else { return false }
        pending = nil
        return true
    }

    private mutating func reset() { pending = nil; release = nil; secondPending = false; sawBegan = false }
}
