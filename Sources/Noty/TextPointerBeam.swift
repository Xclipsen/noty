import UIKit
import NotebookCore

/// The trackpad I-beam over text fields (`PageTextView`) and the text document
/// (`DocumentTextSurface`). UIKit's own beam is measured from the text geometry
/// in the view's coordinates and grows with everything above it: field units,
/// page scale and viewport zoom (up to 6×), on ruled paper possibly from line
/// fragments several rulings tall. This one is as tall as the text under the
/// pointer looks on screen, within `TextCursorGeometry` limits; the system's
/// pointer interactions on that view stay off (`silence`). Only the pointer's
/// look changes: clicks, selection and drags remain the view's gestures.
@MainActor
final class TextPointerBeam: NSObject, UIPointerInteractionDelegate {
    /// Glyph height (ascender to descender) of the text at a point, in the
    /// view's own units; nil: no beam there (the next view decides).
    private let textHeight: (CGPoint) -> CGFloat?

    init(on view: UIView, textHeight: @escaping (CGPoint) -> CGFloat?) {
        self.textHeight = textHeight
        super.init()
        // The view holds the interaction, its owner this delegate.
        view.addInteraction(UIPointerInteraction(delegate: self))
        view.interactions.forEach(Self.silence)
    }

    /// A pointer interaction UIKit puts on a text view (its own I-beam) gives
    /// way to the beam: otherwise it is not certain which of both is asked first.
    static func silence(_ interaction: UIInteraction) {
        guard let pointer = interaction as? UIPointerInteraction, !(pointer.delegate is TextPointerBeam) else { return }
        pointer.isEnabled = false
    }

    /// Screen points per own point of `view` (zoom and scales, not rotation).
    static func screenScale(of view: UIView) -> CGFloat {
        guard let window = view.window else { return 1 }
        let a = view.convert(CGPoint.zero, to: window), b = view.convert(CGPoint(x: 100, y: 0), to: window)
        return max(0.001, hypot(b.x - a.x, b.y - a.y) / 100)
    }

    private struct Beam: Hashable { let halfPoints: Int }

    func pointerInteraction(_ interaction: UIPointerInteraction, regionFor request: UIPointerRegionRequest,
                            defaultRegion: UIPointerRegion) -> UIPointerRegion? {
        guard let view = interaction.view, let height = textHeight(request.location) else { return nil }
        let scale = Double(Self.screenScale(of: view))
        let length = TextCursorGeometry.beamLength(textHeight: Double(height), screenScale: scale)
        let rect = TextCursorGeometry.beamRegion(containing: PagePoint(x: Double(request.location.x), y: Double(request.location.y)),
                                                 length: length, screenScale: scale)
        return UIPointerRegion(rect: rect.cgRect, identifier: Beam(halfPoints: Int((length * 2).rounded())))
    }

    func pointerInteraction(_ interaction: UIPointerInteraction, styleFor region: UIPointerRegion) -> UIPointerStyle? {
        guard let beam = region.identifier as? Beam else { return nil }
        return UIPointerStyle(shape: .verticalBeam(length: CGFloat(beam.halfPoints) / 2), constrainedAxes: [])
    }
}
