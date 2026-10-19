import Foundation

/// A bounded native PencilKit viewport. Native zoom and its inverse outer
/// transform cancel visually while giving PencilKit the actual rendering scale.
public struct InkRenderViewport: Equatable, Sendable {
    public let frame: PageRect
    public let scale: Double
    public var nativeSize: PageSize { .init(width: frame.width * scale, height: frame.height * scale) }
    public var nativeOffset: PagePoint { .init(x: frame.x * scale, y: frame.y * scale) }
    public init(page: PageSize, visible: PageRect, scale: Double) {
        self.scale = max(0.0001, scale.isFinite ? scale : 1)
        let pad = 192 / self.scale
        let step = 96 / self.scale
        let x = min(max(0, floor((visible.x - pad) / step) * step), max(0, page.width - 1))
        let y = min(max(0, floor((visible.y - pad) / step) * step), max(0, page.height - 1))
        frame = .init(x: x, y: y,
            width: max(1, min(page.width, ceil((visible.x + visible.width + pad) / step) * step) - x),
            height: max(1, min(page.height, ceil((visible.y + visible.height + pad) / step) * step) - y))
    }
    public func pagePoint(native point: PagePoint) -> PagePoint { .init(x: point.x / scale, y: point.y / scale) }
    /// Reuse a native viewport until the visible region approaches its reserve.
    /// A page edge needs no reserve outside the page itself.
    /// `ignoringScale` keeps the current raster while a pinch is still moving:
    /// only uncovered areas force a new native viewport, not resolution steps.
    public func covers(_ visible: PageRect, page: PageSize, scale desired: Double, ignoringScale: Bool = false) -> Bool {
        guard ignoringScale || scale == desired else { return false }
        let reserve = 32 / scale
        let left = frame.x > 0 ? frame.x + reserve : 0
        let top = frame.y > 0 ? frame.y + reserve : 0
        let right = frame.x + frame.width < page.width ? frame.x + frame.width - reserve : page.width
        let bottom = frame.y + frame.height < page.height ? frame.y + frame.height - reserve : page.height
        return max(0, visible.x) >= left && max(0, visible.y) >= top
            && min(page.width, visible.x + visible.width) <= right && min(page.height, visible.y + visible.height) <= bottom
    }
}

extension NotebookViewportGeometry {
    public struct ZoomDestination: Equatable, Sendable {
        public let scale: Double
        public let offset: PagePoint
    }
    public static func elasticMinimum(_ range: ZoomRange) -> Double { range.minimum * 0.65 }
    /// Compute scale AND focus before the return animation starts. No second
    /// centering stage after a UIScrollView-owned bounce. Zooming out past the
    /// limit springs back to it; both snaps keep the vertical reading position
    /// and centre the sheet horizontally.
    public static func zoomDestination(scale: Double, range: ZoomRange, page: PageRect, widthRegion: PageRect,
                                       viewport: PageSize, center: PagePoint) -> ZoomDestination? {
        let limit = scale <= range.minimum * 1.015
        guard limit || widthSnap(scale: scale, range: range) != nil else { return nil }
        let target = limit ? range.minimum : range.fit
        let region = limit ? page : widthRegion
        return ZoomDestination(scale: target, offset: .init(
            x: (region.x + region.width / 2) * target - viewport.width / 2,
            y: center.y * target - viewport.height / 2))
    }
}

public enum EditorRenderGeometry {
    public static func viewportScale(size: PageSize, displayScale: Double, screenScale: Double) -> Double {
        min(max(0.001, displayScale * screenScale), sqrt(6_000_000 / max(1, size.width * size.height)))
    }
    public static func textScale(size: PageSize, displayScale: Double) -> Double {
        min(max(0.001, displayScale), sqrt(2_000_000 / max(1, size.width * size.height)))
    }
    /// Device logs (Feedback 33) showed multi-second main-thread stalls only at
    /// PencilKit's finest tile level (native zoom ≥ 8). Beyond this cap the ink
    /// raster is magnified instead of re-tiled at ever finer levels.
    public static let maximumInkScale = 4 * 2.0.squareRoot()
    public static func inkScale(displayScale: Double) -> Double {
        let scale = max(0.0001, displayScale.isFinite ? displayScale : 1)
        return min(maximumInkScale, pow(2, ceil(log2(scale) * 2) / 2))
    }
    /// Limit full-plane bitmaps. PencilKit and paper use bounded viewports;
    /// remaining text/object planes must not allocate page-sized 100 MP buffers.
    public static func contentScale(size: PageSize, displayScale: Double, screenScale: Double) -> Double {
        let desired = max(0.001, displayScale * screenScale)
        let limit = sqrt(16_000_000 / max(1, size.width * size.height))
        return max(0.001, min(desired, limit))
    }
}

public struct ZoomTransition: Sendable {
    public let fromScale: Double
    public let fromOffset: PagePoint
    public let destination: NotebookViewportGeometry.ZoomDestination
    public init(fromScale: Double, fromOffset: PagePoint, destination: NotebookViewportGeometry.ZoomDestination) {
        self.fromScale = fromScale; self.fromOffset = fromOffset; self.destination = destination
    }
    public func value(at fraction: Double) -> NotebookViewportGeometry.ZoomDestination {
        let t = min(1, max(0, fraction))
        if t == 1 { return destination }
        let progress = t == 1 ? 1 : (1 - (1 + 8 * t) * exp(-8 * t)) / (1 - 9 * exp(-8.0))
        return .init(scale: fromScale + (destination.scale - fromScale) * progress,
            offset: .init(x: fromOffset.x + (destination.offset.x - fromOffset.x) * progress,
                          y: fromOffset.y + (destination.offset.y - fromOffset.y) * progress))
    }
}
