import Foundation

/// Viewport motion only (display state): sideways rubber band with a soft
/// return, and the page making room for the attached tool options.
/// Never changes saved page coordinates.
public extension NotebookViewportGeometry {
    /// Displayed overshoot for a finger that pulled `excess` points beyond the
    /// allowed horizontal range (UIKit-like resistance: grows ever slower and
    /// never reaches `dimension`).
    static func rubberBand(_ excess: Double, dimension: Double, coefficient: Double = 0.55) -> Double {
        guard excess.isFinite, dimension > 0, excess != 0 else { return 0 }
        let magnitude = abs(excess)
        let shown = (1 - 1 / (magnitude * coefficient / dimension + 1)) * dimension
        return excess < 0 ? -shown : shown
    }

    /// Inverse of `rubberBand`: the finger excess that shows `displayed`.
    /// Used when a new drag catches a sheet that is still springing back.
    static func rubberBandExcess(displayed: Double, dimension: Double, coefficient: Double = 0.55) -> Double {
        guard displayed.isFinite, dimension > 0, coefficient > 0, displayed != 0 else { return 0 }
        let fraction = min(abs(displayed) / dimension, 0.999)
        let magnitude = (1 / (1 - fraction) - 1) * dimension / coefficient
        return displayed < 0 ? -magnitude : magnitude
    }

    /// One step of a sideways finger drag. `base` is the in-range part of the
    /// offset, `excess` the raw finger distance beyond the range, `delta` the
    /// finger's change of the offset since the last step. A range that moved
    /// (vertical scrolling across sheets of different width) carries the base
    /// along, so only the finger itself creates an overshoot.
    static func elasticDragStep(base: Double, excess: Double, delta: Double,
                                range: ClosedRange<Double>) -> (base: Double, excess: Double) {
        let candidate = min(max(base, range.lowerBound), range.upperBound) + excess + delta
        let clamped = min(max(candidate, range.lowerBound), range.upperBound)
        return (clamped, candidate - clamped)
    }

    /// Remaining fraction of an overshoot while it springs back (critically
    /// damped, no oscillation, so the sheet never swings past the centre).
    /// 1 at the start, exactly 0 from `duration` on.
    static func elasticReturnFraction(elapsed: Double, duration: Double) -> Double {
        guard duration > 0, elapsed.isFinite else { return 0 }
        guard elapsed > 0 else { return 1 }
        guard elapsed < duration else { return 0 }
        // (1 + x)·e^(−x) is below 1 % at x ≈ 6.64; the remainder is faded out
        // linearly so the curve really ends at the destination.
        let x = 6.64 * elapsed / duration
        let spring = (1 + x) * exp(-x)
        return spring * (1 - elapsed / duration)
    }

    /// Content offset after the options bar closes. `current` must be read
    /// before the avoidance inset is removed: UIKit clamps the offset into
    /// the smaller inset at once, and taking back the shift from that clamped
    /// offset moved the page twice (Nutzer zu Build 62: at the document start
    /// the page ended up under the toolbar). Untouched since opening: exactly
    /// the offset before opening; scrolled meanwhile: the shift taken back
    /// from where the user is. `minY`/`maxY`: offset limits without the inset.
    static func avoidanceReleaseOffset(current: PagePoint, after: PagePoint, shift: Double,
                                       minY: Double, maxY: Double) -> PagePoint {
        let untouched = abs(current.y - after.y) < 0.5 && abs(current.x - after.x) < 0.5
        let base = untouched ? after : current
        return PagePoint(x: base.x, y: min(max(base.y - shift, minY), max(minY, maxY)))
    }

    /// Vertical distance the visible pages move so the attached options bar
    /// next to a top or bottom toolbar covers none of them (positive: content
    /// moves up, as for a bottom toolbar; negative: down). Everything is in
    /// viewport points. `bar` is the options bar, `pages` the on-screen sheet
    /// frames, `freeTop`/`freeBottom` the area not covered by other chrome.
    /// Only page content actually under the bar counts; the result never
    /// exceeds the bar plus `gap`.
    static func chromeAvoidanceShift(edge: ToolbarAvoidanceEdge, bar: PageRect, pages: [PageRect],
                                     freeTop: Double, freeBottom: Double, gap: Double = 8) -> Double {
        guard bar.width > 0, bar.height > 0, freeBottom > freeTop else { return 0 }
        let barLeft = bar.x, barRight = bar.x + bar.width
        let relevant = pages.filter { $0.x < barRight && $0.x + $0.width > barLeft && $0.width > 0 && $0.height > 0 }
        switch edge {
        case .bottom:
            // Lowest visible page content inside the bar's band.
            let top = max(bar.y, freeTop), bottom = min(bar.y + bar.height, freeBottom)
            guard bottom > top else { return 0 }
            let reach = relevant.filter { $0.y < bottom && $0.y + $0.height > top }
                .map { min($0.y + $0.height, freeBottom) }.max()
            guard let reach else { return 0 }
            return max(0, min(reach - bar.y + gap, bar.height + gap))
        case .top:
            let top = max(bar.y, freeTop), bottom = min(bar.y + bar.height, freeBottom)
            guard bottom > top else { return 0 }
            let reach = relevant.filter { $0.y < bottom && $0.y + $0.height > top }
                .map { max($0.y, freeTop) }.min()
            guard let reach else { return 0 }
            return -max(0, min(bar.y + bar.height - reach + gap, bar.height + gap))
        }
    }
}

/// Which way the pages make room for the attached tool options. Side and
/// floating toolbars have none: their options bar is short and sits beside
/// the toolbar, and a sideways shift would fight the centred page.
public enum ToolbarAvoidanceEdge: String, Equatable, Sendable {
    case top, bottom

    public init?(dock: ToolbarDock) {
        switch dock {
        case .top: self = .top
        case .bottom: self = .bottom
        case .left, .right, .floating: return nil
        }
    }
}
