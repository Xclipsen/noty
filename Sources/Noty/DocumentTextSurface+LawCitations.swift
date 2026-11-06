// Gesetzesverweise im Fließtext von Text editor 2 (docs/PARAGRAPH-LINKS.md):
// Mit dem Textwerkzeug liegt `DocumentTextSurface` über allen Seiten und nimmt
// Hover und Berührungen selbst. Hover wird an die Seite darunter weitergereicht
// (Karte wie überall), eine Berührung blendet eine Karte aus. Tippen, Caret und
// Auswahl der Fläche bleiben unverändert: nichts hier erkennt oder verhindert.
import UIKit

extension DocumentTextSurface {
    /// Called once from `init`.
    func installLawCitationLinks() {
        addGestureRecognizer(LawCitationSurfaceHover())
        let touches = LawCitationTouchObserver(target: nil, action: nil)
        touches.delegate = LawCitationSurfaceHover.simultaneous
        touches.onTouchDown = { [weak self] touch in
            guard let self, let sheet = LawCitationSurfaceHover.sheet(below: self, at: { touch.location(in: $0) }) else { return }
            sheet.lawCitations.forwardedTouchDown(touch)
        }
        addGestureRecognizer(touches)
    }
}

/// Hover over the active document surface, handed to the sheet below it.
@MainActor
final class LawCitationSurfaceHover: UIHoverGestureRecognizer {
    /// Recognises alongside the surface's own interactions (text, pointer beam).
    final class Simultaneous: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    }
    static let simultaneous = Simultaneous()
    private weak var current: WorksheetView?

    init() {
        super.init(target: nil, action: nil)
        addTarget(self, action: #selector(changed))
        delegate = Self.simultaneous
        cancelsTouchesInView = false; delaysTouchesBegan = false; delaysTouchesEnded = false
    }

    /// The sheet under a point of `surface` (siblings on the viewport's zoomed surface).
    static func sheet(below surface: UIView, at location: (UIView) -> CGPoint) -> WorksheetView? {
        guard let container = surface.superview else { return nil }
        for case let sheet as WorksheetView in container.subviews.reversed()
        where !sheet.isHidden && sheet.bounds.contains(location(sheet)) { return sheet }
        return nil
    }

    @objc private func changed() {
        guard let surface = view else { return }
        switch state {
        case .began, .changed:
            guard LawCitationPreviewModel.shared.scanner != nil else { leave(); return }
            let sheet = Self.sheet(below: surface) { self.location(in: $0) }
            if sheet !== current { leave(); current = sheet }
            sheet?.lawCitations.forwardedHover(self, ended: false)
        default:
            leave()
        }
    }
    private func leave() {
        current?.lawCitations.forwardedHover(self, ended: true)
        current = nil
    }
}
