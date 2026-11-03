import UIKit
import NotebookCore

/// Switchable aid for touch problems on the device, where no log can be read
/// without USB: after every tap a small line names what the touch reached and
/// which text fields lie there. Shows sizes and lengths only, never content.
@MainActor
final class TapDiagnostics: NSObject, UIGestureRecognizerDelegate {
    static let shared = TapDiagnostics()
    private let label = UILabel()
    private var taps: [ObjectIdentifier: UITapGestureRecognizer] = [:]
    private var observing = false

    private var enabled: Bool { UserDefaults.standard.bool(forKey: AppSettingsKey.tapDiagnostics) }
    private var windows: [UIWindow] {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
            .sorted { $0.windowLevel > $1.windowLevel }
    }

    /// After the setting changed or a window appeared (the keyboard has its own).
    func refresh() {
        if !observing {
            observing = true
            NotificationCenter.default.addObserver(self, selector: #selector(windowAppeared), name: UIWindow.didBecomeVisibleNotification, object: nil)
        }
        for window in windows {
            let id = ObjectIdentifier(window)
            if enabled, taps[id] == nil {
                let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
                tap.cancelsTouchesInView = false; tap.delaysTouchesEnded = false; tap.delegate = self
                tap.allowedTouchTypes = [UITouch.TouchType.direct, .indirectPointer, .pencil].map { NSNumber(value: $0.rawValue) }
                window.addGestureRecognizer(tap); taps[id] = tap
            } else if !enabled, let tap = taps[id] {
                window.removeGestureRecognizer(tap); taps[id] = nil
            }
        }
        if enabled { show("Tipp-Diagnose an: auf das Feld tippen") } else { label.removeFromSuperview() }
    }
    @objc private func windowAppeared() { if enabled { refresh() } }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

    @objc private func tapped(_ tap: UITapGestureRecognizer) {
        guard tap.state == .ended, let source = tap.view as? UIWindow else { return }
        let point = tap.location(in: source)
        var lines = ["Fenster \(Self.name(source)), Zeiger \(Int(point.x))/\(Int(point.y))"]
        for window in windows where !window.isHidden {
            let local = window.convert(point, from: source)
            guard let hit = window.hitTest(local, with: nil) else { continue }
            lines.append("Treffer: " + Self.chain(hit))
            break
        }
        for window in windows where !window.isHidden {
            let local = window.convert(point, from: source)
            if let layer = Self.textLayer(in: window, at: local) {
                lines.append(layer.tapReport(at: window.convert(local, to: layer)))
                break
            }
        }
        show(lines.joined(separator: "\n"))
    }
    private static func name(_ object: AnyObject) -> String { String(describing: type(of: object)) }
    private static func chain(_ view: UIView) -> String {
        var names: [String] = [], current: UIView? = view
        while let item = current, names.count < 5 { names.append(name(item)); current = item.superview }
        return names.joined(separator: " < ")
    }
    private static func textLayer(in view: UIView, at point: CGPoint) -> TextObjectLayer? {
        guard !view.isHidden, view.alpha > 0 else { return nil }
        if let layer = view as? TextObjectLayer { return layer.bounds.contains(point) ? layer : nil }
        for child in view.subviews.reversed() {
            if let found = textLayer(in: child, at: view.convert(point, to: child)) { return found }
        }
        return nil
    }
    private func show(_ text: String) {
        guard let window = windows.first(where: { $0.isKeyWindow }) ?? windows.last, let host = window.rootViewController?.view else { return }
        label.numberOfLines = 0; label.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        label.textColor = .white; label.backgroundColor = UIColor.black.withAlphaComponent(0.82)
        label.layer.cornerRadius = 6; label.clipsToBounds = true; label.isUserInteractionEnabled = false
        label.text = text
        let width = min(host.bounds.width - 40, 700)
        let size = label.sizeThatFits(CGSize(width: width, height: 400))
        label.frame = CGRect(x: (host.bounds.width - width) / 2, y: 96, width: width, height: size.height + 8)
        if label.superview !== host { label.removeFromSuperview(); host.addSubview(label) }
        host.bringSubviewToFront(label)
    }
}

extension TextObjectLayer {
    /// Fields at `point`, topmost first: place, size and text length.
    func tapReport(at point: CGPoint) -> String {
        let canonical = PagePoint(x: point.x - pageLayout.contentOrigin.x, y: point.y - pageLayout.contentOrigin.y)
        var lines = ["Seite \(Int(canonical.x))/\(Int(canonical.y)), Textebene aktiv: \(active), Felder: \(boxes.count), leer: \(boxes.filter { $0.text.isEmpty }.count)"]
        for box in boxes.reversed() where box.contains(canonical, tolerance: 8) {
            let field = fields[box.id]
            let editing = field?.editor.isFirstResponder == true ? " bearbeitet" : ""
            let hit = field.map { $0.point(inside: convert(point, to: $0), with: nil) } ?? false
            let flow = box.flowID != nil ? " Fluss" : box.flowRegion.map { " Bereich \($0)" } ?? ""
            lines.append("Feld \(Int(box.x))/\(Int(box.y)) \(Int(box.width))×\(Int(box.height)), \(box.text.count) Zeichen, Treffer: \(hit)\(flow)\(editing)")
            if lines.count >= 7 { break }
        }
        return lines.joined(separator: "\n")
    }
}
