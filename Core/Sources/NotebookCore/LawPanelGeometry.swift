import Foundation

/// Screen edge the law window belongs to (display state only, kept in
/// UserDefaults; nothing of this is part of a notebook or backup).
public enum LawPanelEdge: String, CaseIterable, Sendable {
    case left, right, bottom
    public var isSide: Bool { self != .bottom }
}

/// What releasing a drag of the law window does.
public enum LawPanelDrop: Equatable, Sendable {
    case stay
    case float(LawPanelEdge)
    case dock(LawPanelEdge)
    case stash(LawPanelEdge)
}

/// Geometry of the law window in one workspace size. Docking needs room for
/// the notebook beside or above it; otherwise the window floats.
public struct LawPanelLayout: Equatable, Sendable {
    public static let gap = 6.0
    public static let minimumWidth = 300.0
    public static let minimumHeight = 240.0
    /// Notebook room kept beside (side) or above (bottom) a docked window.
    public static let notebookWidth = 326.0
    public static let notebookHeight = 300.0

    public let size: PageSize
    public let edge: LawPanelEdge
    public let canDock: Bool
    public let docked: Bool
    public let dockWidth: Double
    public let floatWidth: Double
    public let dockHeight: Double
    public let floatHeight: Double

    /// `width`: preferred width of a side window, `height`: preferred height
    /// of a bottom window (both as last chosen by the user).
    public init(size: PageSize, width: Double, height: Double, docked: Bool, edge: LawPanelEdge) {
        self.size = size; self.edge = edge
        canDock = Self.canDock(edge, in: size)
        self.docked = docked && canDock
        let w = max(0, size.width), h = max(0, size.height)
        dockWidth = min(w, min(max(Self.minimumWidth, width), max(Self.minimumWidth, w - Self.notebookWidth)))
        floatWidth = min(max(0, w - 20), min(max(Self.minimumWidth, width), max(Self.minimumWidth, w - 24)))
        dockHeight = min(h, min(max(Self.minimumHeight, height), max(Self.minimumHeight, h - Self.notebookHeight)))
        floatHeight = min(max(0, h - 20), min(max(Self.minimumHeight, height), max(Self.minimumHeight, h - 84)))
    }

    public static func canDock(_ edge: LawPanelEdge, in size: PageSize) -> Bool {
        edge.isSide ? size.width >= 640 : size.height >= 560
    }

    public var margin: Double { docked ? 0 : 10 }
    /// Resting frame of the window in workspace points.
    public var frame: PageRect {
        let m = margin
        switch edge {
        case .left:
            let width = docked ? dockWidth : floatWidth
            return PageRect(x: m, y: m, width: width, height: max(0, size.height - 2 * m))
        case .right:
            let width = docked ? dockWidth : floatWidth
            return PageRect(x: size.width - m - width, y: m, width: width, height: max(0, size.height - 2 * m))
        case .bottom:
            let height = docked ? dockHeight : floatHeight
            return PageRect(x: m, y: size.height - m - height, width: max(0, size.width - 2 * m), height: height)
        }
    }
    /// Unit direction out of the screen through the window's edge.
    public var outward: PagePoint {
        switch edge {
        case .left: PagePoint(x: -1, y: 0)
        case .right: PagePoint(x: 1, y: 0)
        case .bottom: PagePoint(x: 0, y: 1)
        }
    }
    /// Shift that puts the window completely past its screen edge.
    public var hiddenShift: Double { (edge.isSide ? frame.width : frame.height) + margin }
    /// Area left to the notebooks while the window is docked (and visible).
    public var notebookFrame: PageRect {
        guard docked else { return PageRect(x: 0, y: 0, width: size.width, height: size.height) }
        switch edge {
        case .left:
            return PageRect(x: dockWidth + Self.gap, y: 0, width: max(0, size.width - dockWidth - Self.gap), height: size.height)
        case .right:
            return PageRect(x: 0, y: 0, width: max(0, size.width - dockWidth - Self.gap), height: size.height)
        case .bottom:
            return PageRect(x: 0, y: 0, width: size.width, height: max(0, size.height - dockHeight - Self.gap))
        }
    }

    /// The window follows the finger, but never leaves the workspace completely.
    public func dragOffset(_ translation: PagePoint) -> PagePoint {
        let f = frame
        return PagePoint(x: min(size.width - f.x, max(-(f.x + f.width), translation.x)),
                         y: min(size.height - f.y, max(-f.y, translation.y)))
    }

    /// Decided by what the user sees on release (workspace points):
    /// mostly past a side edge, or a bottom window mostly below the screen,
    /// or flicked out → stashed behind an edge tab; finger at the left, right
    /// or bottom screen edge → docked there; otherwise floating on the side
    /// of the finger, in the lower part of the screen at the bottom.
    public func drop(translation: PagePoint, location: PagePoint,
                     predictedTranslation: PagePoint? = nil, predictedLocation: PagePoint? = nil) -> LawPanelDrop {
        let f = frame, w = size.width, h = size.height
        let minX = f.x + translation.x, minY = f.y + translation.y
        if minX + f.width - w > f.width * 0.5 { return .stash(.right) }
        if -minX > f.width * 0.5 { return .stash(.left) }
        // A side window would be "mostly below" long before the finger
        // reaches the bottom zones; only a bottom window is pushed out this way.
        if edge == .bottom, minY + f.height - h > f.height * 0.5 { return .stash(.bottom) }
        if let predictedTranslation, let predictedLocation {
            let aheadX = predictedTranslation.x - translation.x, aheadY = predictedTranslation.y - translation.y
            if aheadX > 240, predictedLocation.x > w + 60 { return .stash(.right) }
            if aheadX < -240, predictedLocation.x < -60 { return .stash(.left) }
            if aheadY > 240, predictedLocation.y > h + 60 { return .stash(.bottom) }
        }
        guard hypot(translation.x, translation.y) > 40 else { return .stay }
        let side = Self.canDock(.left, in: size), bottom = Self.canDock(.bottom, in: size)
        if side, location.x < 80 { return .dock(.left) }
        if side, location.x > w - 80 { return .dock(.right) }
        if bottom, location.y > h - 90 { return .dock(.bottom) }
        if location.y > h * 0.62 { return .float(.bottom) }
        return .float(location.x < w / 2 ? .left : .right)
    }

    /// Whether a drop changes anything (no preview for the current place).
    public func changes(_ drop: LawPanelDrop) -> Bool {
        switch drop {
        case .stay: false
        case .float(let target): docked || target != edge
        case .dock(let target): !docked || target != edge
        case .stash: true
        }
    }
}
