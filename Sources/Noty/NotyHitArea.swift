import SwiftUI

/// A touch area of at least 44 × 44 pt around a smaller visible control,
/// without changing its size or layout: `.contentShape(NotyHitShape())`.
/// The extra area lies outside the view's frame, centred on it.
struct NotyHitShape: Shape {
    var minimum = CGSize(width: 44, height: 44)

    func path(in rect: CGRect) -> Path {
        let dx = min(0, (rect.width - minimum.width) / 2)
        let dy = min(0, (rect.height - minimum.height) / 2)
        return Path(rect.insetBy(dx: dx, dy: dy))
    }
}
