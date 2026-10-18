import Foundation

/// Viewport-only space and preloading; never alters saved page coordinates.
public enum NotebookViewportGeometry {
    public struct ZoomRange: Equatable, Sendable {
        public let fit: Double
        public let minimum: Double
        public let maximum: Double
    }

    public static func zoomRange(viewport: PageSize, page: PageSize, contentWidth: Double? = nil) -> ZoomRange {
        let width = max(1, viewport.width - 32), height = max(1, viewport.height - 32)
        let fit = width / max(1, contentWidth ?? page.width)
        let wholePage = min(width / max(1, page.width), height / max(1, page.height))
        return ZoomRange(fit: fit, minimum: min(fit, wholePage), maximum: max(6, fit * 6))
    }

    public static func widthSnap(scale: Double, range: ZoomRange) -> Double? {
        guard scale.isFinite, scale > 0, range.fit > 0 else { return nil }
        let widthDistance = abs(scale - range.fit) / range.fit
        guard widthDistance <= 0.08 + 0.0000001 else { return nil }
        // A nearby whole-sheet limit must remain reachable in its own right.
        if range.minimum < range.fit,
           abs(scale - range.minimum) / range.minimum < widthDistance { return nil }
        return range.fit
    }

    /// Minimal caret reveal, in scroll-content coordinates. Keeping an already
    /// visible caret stationary avoids keyboard/selection feedback loops.
    public static func caretOffset(caret: PageRect, visible: PageRect) -> PagePoint {
        var x = visible.x, y = visible.y
        if caret.x < visible.x { x = caret.x }
        else if caret.x + caret.width > visible.x + visible.width { x += caret.x + caret.width - visible.x - visible.width }
        if caret.y < visible.y { y = caret.y }
        else if caret.y + caret.height > visible.y + visible.height { y += caret.y + caret.height - visible.y - visible.height }
        return PagePoint(x: x, y: y)
    }

    public static func horizontalInset(viewportWidth: Double, contentWidth: Double) -> Double {
        max(16, viewportWidth * 0.65, (viewportWidth - contentWidth) / 2)
    }

    /// Includes every visible pixel plus half a viewport above and below.
    /// All values are unzoomed surface coordinates.
    public static func preloadRect(visible: PageRect) -> PageRect {
        let margin = min(1000, max(0, visible.height) * 0.5)
        return PageRect(x: visible.x, y: visible.y - margin,
                        width: visible.width, height: visible.height + 2 * margin)
    }
}
