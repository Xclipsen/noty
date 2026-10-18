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
        let pad = 64 / self.scale
        let step = pad
        let x = min(max(0, floor((visible.x - pad) / step) * step), max(0, page.width - 1))
        let y = min(max(0, floor((visible.y - pad) / step) * step), max(0, page.height - 1))
        frame = .init(x: x, y: y,
            width: max(1, min(page.width, ceil((visible.x + visible.width + pad) / step) * step) - x),
            height: max(1, min(page.height, ceil((visible.y + visible.height + pad) / step) * step) - y))
    }
    public func pagePoint(native point: PagePoint) -> PagePoint { .init(x: point.x / scale, y: point.y / scale) }
}

extension NotebookViewportGeometry {
    public struct ZoomDestination: Equatable, Sendable {
        public let scale: Double
        public let offset: PagePoint
    }
    public static func elasticMinimum(_ range: ZoomRange) -> Double { range.minimum * 0.65 }
    /// Compute scale AND focus before the return animation starts. No second
    /// centering stage after a UIScrollView-owned bounce.
    public static func zoomDestination(scale: Double, range: ZoomRange, page: PageRect, widthRegion: PageRect,
                                       viewport: PageSize, center: PagePoint) -> ZoomDestination? {
        let whole = scale <= range.minimum * 1.015
        guard whole || widthSnap(scale: scale, range: range) != nil else { return nil }
        let target = whole ? range.minimum : range.fit
        let region = whole ? page : widthRegion
        let y = whole ? region.y + region.height / 2 : center.y
        return ZoomDestination(scale: target, offset: .init(
            x: (region.x + region.width / 2) * target - viewport.width / 2,
            y: y * target - viewport.height / 2))
    }
}

public enum EditorRenderGeometry {
    public static func inkScale(displayScale: Double) -> Double {
        let scale = max(0.0001, displayScale.isFinite ? displayScale : 1)
        return pow(2, ceil(log2(scale) * 2) / 2)
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
