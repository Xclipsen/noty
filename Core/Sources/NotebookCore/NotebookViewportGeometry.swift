import Foundation

/// Viewport-only space and preloading; never alters saved page coordinates.
public enum NotebookViewportGeometry {
    public struct ZoomRange: Equatable, Sendable {
        public let fit: Double
        public let minimum: Double
        public let maximum: Double
    }

    /// `page`: the complete sheet including any writing space beside a PDF.
    /// "Fit" shows exactly that complete width (Build 41 feedback: a fit that
    /// covered only the PDF cut the writing space off). `contentWidth` is the
    /// base sheet without writing space; it only sets the zoom-out limit.
    public static func zoomRange(viewport: PageSize, page: PageSize, contentWidth: Double? = nil) -> ZoomRange {
        let width = max(1, viewport.width - 32), height = max(1, viewport.height - 32)
        let fit = width / max(1, page.width)
        let wholePage = min(width / max(1, page.width), height / max(1, page.height))
        // Zooming out stops when about three base pages fit side by side.
        let threePages = max(1, viewport.width) / (3 * max(1, contentWidth ?? page.width))
        return ZoomRange(fit: fit, minimum: min(fit, wholePage, threePages), maximum: max(6, fit * 6))
    }

    /// Zoom range of a placed sheet; its fit includes the writing space.
    public static func zoomRange(viewport: PageSize, placement: NotebookPagePlacement) -> ZoomRange {
        zoomRange(viewport: viewport, page: placement.frame.size, contentWidth: placement.readingFrame.width)
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

    /// Generous scroll room; `horizontalOffset` applies the actual per-page limit.
    public static func horizontalInset(viewportWidth: Double, contentWidth: Double) -> Double {
        max(16, viewportWidth, (viewportWidth - contentWidth) / 2)
    }
    /// Normal mode keeps narrow pages centred and wide page edges at the screen
    /// edges. Writing mode (`anchors`: the sheet edges) additionally lets each
    /// edge move up to the middle of the screen, never further.
    /// `centre`: surface x that may additionally be centred on screen (the base
    /// sheet/PDF beside a writing space, the target of page jumps), so the
    /// clamp never pulls a jump back to the whole-sheet centre.
    public static func horizontalOffset(_ requested: Double, viewportWidth: Double, page: PageRect, scale: Double,
                                        anchors: (left: Double, right: Double)? = nil, centre: Double? = nil) -> Double {
        let range = horizontalRange(viewportWidth: viewportWidth, page: page, scale: scale, anchors: anchors, centre: centre)
        return min(max(requested, range.lowerBound), range.upperBound)
    }
    /// Allowed content-offset x interval of one sheet (see `horizontalOffset`).
    public static func horizontalRange(viewportWidth: Double, page: PageRect, scale: Double,
                                       anchors: (left: Double, right: Double)? = nil, centre: Double? = nil) -> ClosedRange<Double> {
        let left = page.x * scale, right = (page.x + page.width) * scale
        var low = left - 16, high = right - viewportWidth + 16
        if right - left + 32 <= viewportWidth { low = (left + right - viewportWidth) / 2; high = low }
        if let anchors {
            // Never narrower than normal scrolling; edges stop at the screen middle.
            low = min(low, anchors.left * scale - viewportWidth / 2)
            high = max(high, anchors.right * scale - viewportWidth / 2)
        }
        if let centre {
            let focus = centre * scale - viewportWidth / 2
            low = min(low, focus); high = max(high, focus)
        }
        return low...max(low, high)
    }
    /// Horizontal target of a page jump (page number, arrows, sidebar, focus
    /// after deleting): the base sheet/PDF in the middle of the screen at the
    /// current zoom. A fit (`wholeSheet`) centres PDF and writing space together.
    public static func jumpOffsetX(_ placement: NotebookPagePlacement, scale: Double, viewportWidth: Double,
                                   wholeSheet: Bool) -> Double {
        let region = wholeSheet ? placement.frame : placement.contentFrame
        return (region.x + region.width / 2) * scale - viewportWidth / 2
    }
    /// Neighbouring sheets of different width (e.g. paper → PDF with writing
    /// space) have different horizontal ranges. Near their seam the clamp is
    /// blended with a smoothstep over `band` surface points, so the view glides
    /// sideways while scrolling instead of being forced over at the boundary.
    /// `pages` are surface frames sorted top to bottom; `range(i)` is the
    /// allowed offset interval of page i (`horizontalRange`). Returns nil when
    /// no page exists.
    ///
    /// The interval bounds are blended, then the offset is clamped once. A
    /// clamp is idempotent: repeated layout passes at the same scroll position
    /// (e.g. after every pen stroke) never move the view. Build 45 blended the
    /// two clamped offsets instead, which pulled the view a bit further towards
    /// the neighbour's limit on every pass (Strich-Drift nach links).
    public static func blendedHorizontalOffset(_ requested: Double, referenceY: Double, band: Double,
                                               pages: [PageRect], range: (Int) -> ClosedRange<Double>) -> Double? {
        guard let allowed = blendedHorizontalRange(referenceY: referenceY, band: band, pages: pages, range: range) else { return nil }
        return min(max(requested, allowed.lowerBound), allowed.upperBound)
    }
    public static func blendedHorizontalRange(referenceY: Double, band: Double, pages: [PageRect],
                                              range: (Int) -> ClosedRange<Double>) -> ClosedRange<Double>? {
        guard !pages.isEmpty else { return nil }
        let band = max(1, band)
        for i in pages.indices.dropLast() {
            let seam = (pages[i].y + pages[i].height + pages[i + 1].y) / 2
            let d = referenceY - seam
            guard abs(d) < band else { continue }
            let t = (d + band) / (2 * band), smooth = t * t * (3 - 2 * t)
            let above = range(i), below = range(i + 1)
            let low = above.lowerBound + (below.lowerBound - above.lowerBound) * smooth
            let high = above.upperBound + (below.upperBound - above.upperBound) * smooth
            return low...max(low, high)
        }
        let index = pages.indices.min { verticalDistance(referenceY, page: pages[$0]) < verticalDistance(referenceY, page: pages[$1]) }!
        return range(index)
    }
    public static func verticalDistance(_ y: Double, page: PageRect) -> Double {
        max(page.y - y, y - page.y - page.height, 0)
    }

    /// Includes every visible pixel plus half a viewport above and below.
    /// All values are unzoomed surface coordinates.
    public static func preloadRect(visible: PageRect) -> PageRect {
        let margin = min(1000, max(0, visible.height) * 0.5)
        return PageRect(x: visible.x, y: visible.y - margin,
                        width: visible.width, height: visible.height + 2 * margin)
    }
}
