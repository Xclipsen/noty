import Foundation

public enum ToolbarAxis: String, Codable, Sendable { case horizontal, vertical }

/// Shared sizing and magnetism in viewport points, never document coordinates.
public struct ToolbarLayout: Equatable, Sendable {
    public static let cell = 48.0
    public static let spacing = 0.0
    public static let padding = 2.0
    public static let grip = 44.0
    public static let thickness = 52.0
    public let viewport: PageSize
    public let items: Int
    public let headerItems: Int
    public let axis: ToolbarAxis
    public let frame: PageRect
    public let inlineHeader: Bool
    public let compactHeader: Bool
    public let headerActionCount: Int
    public let headerLeadingFrame: PageRect
    public let headerActionsFrame: PageRect
    public let topInset: Double
    public let bottomInset: Double
    public let leftInset: Double
    public let rightInset: Double

    public static func axis(for dock: ToolbarDock, floating: ToolbarAxis) -> ToolbarAxis {
        switch dock {
        case .left, .right: .vertical
        case .top, .bottom: .horizontal
        case .floating: floating
        }
    }
    /// `tools`: visible first-level tools, plus the level arrow. The second
    /// level shows the utilities, `secondaryTools` (laser pointer, PDF lesen) and the arrow.
    public static func itemCount(more: Bool, presets: Int, secondView: Bool, tools: Int = 8, secondaryTools: Int = 0) -> Int {
        more ? (secondView ? 6 : 5) + max(0, secondaryTools) : max(1, tools) + 1 + max(0, presets)
    }
    public static func itemCount(more: Bool, preferences: ToolbarPreferences, secondView: Bool) -> Int {
        itemCount(more: more, presets: preferences.presets.count, secondView: secondView,
                  tools: preferences.primaryTools.count, secondaryTools: preferences.secondaryTools.count)
    }
    public static func length(items: Int) -> Double {
        let count = max(1, items)
        return Double(count) * cell + Double(count - 1) * spacing + padding * 2 + grip
    }
    public init(viewport: PageSize, dock: ToolbarDock, floatingAxis: ToolbarAxis = .horizontal,
                items: Int, headerItems: Int? = nil, floatingX: Double = 0.5, floatingY: Double = 0.2) {
        let w = max(1, viewport.width), h = max(1, viewport.height)
        self.viewport = PageSize(width: w, height: h)
        self.items = items
        self.headerItems = headerItems ?? items
        axis = Self.axis(for: dock, floating: floatingAxis)
        let header = min(64, max(0, h - Self.thickness - 24))
        let usableHeight = max(1, h - header - 24)
        let mainLength = Self.length(items: self.headerItems)
        let edge = 8.0, gap = 10.0
        // Undo, redo, writing scroll, options, add page, sidebar; narrower
        // headers drop add page, then writing scroll, then redo.
        func actionsWidth(_ count: Double) -> Double { count * 44 + 8 }
        if dock == .top {
            let sideRoom = (w - mainLength) / 2 - edge - gap
            headerActionCount = sideRoom >= actionsWidth(6) ? 6 : sideRoom >= actionsWidth(5) ? 5
                : sideRoom >= actionsWidth(4) ? 4 : 3
        } else { headerActionCount = w >= 600 ? 6 : 3 }
        compactHeader = headerActionCount < 6
        let actions = Double(headerActionCount) * 44 + 8
        let headerCapacity = max(1, w - 2 * (actions + edge + gap))
        inlineHeader = dock == .top && headerCapacity >= min(320, mainLength)
        let availableLength = axis == .horizontal ? (inlineHeader ? headerCapacity : max(1, w - 24)) : usableHeight
        let length = min(Self.length(items: items), availableLength)
        let width = axis == .horizontal ? length : min(Self.thickness, max(1, w - 24))
        let height = axis == .vertical ? length : min(Self.thickness, usableHeight)
        let leadingWidth = inlineHeader ? (w - min(mainLength, headerCapacity)) / 2 - gap - edge : w - 2 * edge - actions - 8
        headerLeadingFrame = PageRect(x: edge, y: 8, width: max(0, leadingWidth), height: 44)
        headerActionsFrame = PageRect(x: w - edge - actions, y: 8, width: actions, height: 44)
        let minX = min(12, max(0, (w - width) / 2))
        let minY = min(header + 12, max(0, h - height - 12))
        let maxX = max(minX, w - width - 12), maxY = max(minY, h - height - 12)
        func unit(_ value: Double) -> Double { value.isFinite ? min(1, max(0, value)) : 0.5 }
        let x: Double
        let y: Double
        switch dock {
        case .top: x = (w + min(mainLength, availableLength)) / 2 - width; y = inlineHeader ? 4 : minY
        case .bottom: x = (w + min(mainLength, availableLength)) / 2 - width; y = maxY
        case .left: x = minX; y = min(maxY, max(minY, (h + header + min(mainLength, availableLength)) / 2 - height))
        case .right: x = maxX; y = min(maxY, max(minY, (h + header + min(mainLength, availableLength)) / 2 - height))
        case .floating:
            x = minX + unit(floatingX) * (maxX - minX)
            y = minY + unit(floatingY) * (maxY - minY)
        }
        frame = PageRect(x: x, y: y, width: width, height: height)
        topInset = dock == .top && !inlineHeader ? y + height + 12 : header
        bottomInset = dock == .bottom ? height + 24 : 0
        leftInset = dock == .left ? width + 24 : 0
        rightInset = dock == .right ? width + 24 : 0
    }
    public var center: PagePoint { PagePoint(x: frame.x + frame.width / 2, y: frame.y + frame.height / 2) }

    /// Compact options attach below horizontal palettes, above at the bottom,
    /// or inward beside vertical palettes. Never leave the visible viewport.
    public func optionsFrame(preferredWidth: Double, height: Double = 52) -> PageRect {
        let gap = 8.0, margin = 12.0
        let h = min(height, max(1, viewport.height - 24))
        if axis == .vertical {
            let leftRoom = max(1, frame.x - gap - margin)
            let rightRoom = max(1, viewport.width - frame.x - frame.width - gap - margin)
            let right = rightRoom >= leftRoom
            let width = min(preferredWidth, right ? rightRoom : leftRoom)
            return PageRect(x: right ? frame.x + frame.width + gap : frame.x - gap - width,
                y: min(max(margin, frame.y), max(margin, viewport.height - h - margin)), width: width, height: h)
        }
        let width = min(preferredWidth, max(1, viewport.width - 24))
        let below = frame.y + frame.height + gap
        let y = below + h <= viewport.height - margin ? below : max(margin, frame.y - gap - h)
        return PageRect(x: min(max(margin, center.x - width / 2), max(margin, viewport.width - width - margin)),
            y: y, width: width, height: h)
    }

    /// Keep the same centre when axis/content count changes, then clamp to screen.
    public func floatingPosition(center: PagePoint) -> PagePoint {
        let header = min(64, max(0, viewport.height - Self.thickness - 24))
        let minX = min(12, max(0, (viewport.width - frame.width) / 2))
        let minY = min(header + 12, max(0, viewport.height - frame.height - 12))
        let rangeX = max(0, viewport.width - frame.width - 12 - minX)
        let rangeY = max(0, viewport.height - frame.height - 12 - minY)
        return PagePoint(x: rangeX > 0 ? min(1, max(0, (center.x - frame.width / 2 - minX) / rangeX)) : 0,
                         y: rangeY > 0 ? min(1, max(0, (center.y - frame.height / 2 - minY) / rangeY)) : 0)
    }

    public func guide(for dock: ToolbarDock) -> PageRect {
        let target = ToolbarLayout(viewport: viewport, dock: dock, items: items, headerItems: headerItems)
        switch dock {
        case .top, .bottom:
            let width = min(240, max(30, viewport.width - 32))
            return PageRect(x: target.center.x - width / 2, y: target.center.y - 14, width: width, height: 28)
        case .left, .right:
            let height = min(240, max(30, viewport.height - 120))
            return PageRect(x: target.center.x - 14, y: target.center.y - height / 2, width: 28, height: height)
        case .floating: return frame
        }
    }
    public func snapTarget(pointer: PagePoint, center: PagePoint, previous: ToolbarDock? = nil) -> ToolbarDock? {
        func distance(_ point: PagePoint, _ zone: PageRect) -> Double {
            let dx = max(zone.x - point.x, 0, point.x - zone.x - zone.width)
            let dy = max(zone.y - point.y, 0, point.y - zone.y - zone.height)
            return hypot(dx, dy)
        }
        func proximity(_ dock: ToolbarDock) -> Double {
            let zone = guide(for: dock)
            return min(distance(pointer, zone), distance(center, zone))
        }
        if let previous, previous != .floating, proximity(previous) <= 48 { return previous }
        return [ToolbarDock.top, .bottom, .left, .right]
            .filter { proximity($0) <= 30 }.min { proximity($0) < proximity($1) }
    }
}
