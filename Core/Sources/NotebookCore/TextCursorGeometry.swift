/// Sizes of the text cursors drawn by UIKit: the trackpad I-beam over text
/// and the caret. Platform independent (`TextPointerBeam`, `PageTextView`).
public enum TextCursorGeometry {
    /// Screen points: never smaller than a readable beam, never a bar over
    /// half the window at high zoom or for a title.
    public static let minimumBeam = 12.0
    public static let maximumBeam = 40.0

    /// Beam length in screen points for text whose glyphs (ascender to
    /// descender) are `textHeight` own units tall, shown at `screenScale`
    /// screen points per own unit (viewport zoom, field units, page scale).
    public static func beamLength(textHeight: Double, screenScale: Double) -> Double {
        let length = textHeight * screenScale
        guard length.isFinite, length > 0 else { return minimumBeam }
        return min(max(length, minimumBeam), maximumBeam)
    }

    /// The pointer region (own units) around `point`: a cell of a fixed grid,
    /// so moving inside it keeps the region and its style, and leaving it
    /// asks again (another line, another size). Taller than the beam on
    /// screen: UIKit limits a beam to its region's height.
    public static func beamRegion(containing point: PagePoint, length: Double, screenScale: Double) -> PageRect {
        let scale = screenScale.isFinite && screenScale > 0 ? screenScale : 1
        let width = max(length, 8) / scale, height = max(length, minimumBeam) * 1.25 / scale
        let column = (point.x / width).rounded(.down), row = (point.y / height).rounded(.down)
        return PageRect(x: column * width, y: row * height, width: width, height: height)
    }

    /// A caret no taller than its font's glyphs (`fontHeight`, ascender to
    /// descender) plus a little: TextKit's own caret spans the whole line
    /// fragment, on ruled paper also the gap up to the line before (the text
    /// stands at its bottom). Returns top and height; shorter ones unchanged.
    public static func limitedCaret(top: Double, height: Double, fontHeight: Double) -> (top: Double, height: Double) {
        guard fontHeight.isFinite, fontHeight > 0, height.isFinite, height > fontHeight * 1.25 else { return (top, height) }
        return (top + height - fontHeight, fontHeight)
    }
}
