import UIKit
import PencilKit
import NotebookCore

/// What a typical drawn point of one ink looks like (median of a stroke).
struct InkPointTemplate {
    var opacity: CGFloat
    var force: CGFloat
    var azimuth: CGFloat
    var altitude: CGFloat
}

/// The app's one `InkPointProfiles`: learned from every ordinary PencilKit
/// stroke on every page and view, read by held shapes and ruler strokes, kept
/// in `UserDefaults` (not in a notebook or backup). A fresh page draws with
/// what earlier strokes showed instead of the bare tool width.
@MainActor
final class InkPointMemory {
    static let shared = InkPointMemory()
    private static let key = "noty.ink.pointProfiles"
    private var profiles: InkPointProfiles
    private var saveGeneration = 0
    private var dirty = false

    private init() {
        profiles = InkPointProfiles(data: UserDefaults.standard.data(forKey: Self.key))
        for name in [UIApplication.willResignActiveNotification, UIApplication.didEnterBackgroundNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { InkPointMemory.shared.saveNow() }
            }
        }
    }

    /// PencilKit point size per tool width.
    func widthRatio(_ type: PKInk.InkType) -> CGFloat? { profiles[type.rawValue].map { CGFloat($0.widthRatio) } }
    func template(_ type: PKInk.InkType) -> InkPointTemplate? {
        profiles[type.rawValue].map {
            InkPointTemplate(opacity: CGFloat($0.opacity), force: CGFloat($0.force), azimuth: CGFloat($0.azimuth), altitude: CGFloat($0.altitude))
        }
    }

    /// One finished PencilKit stroke drawn with tool width `toolWidth`
    /// (`drawnWidth`: its median point width in page units).
    func learn(_ stroke: PKStroke, drawnWidth: CGFloat, toolWidth: CGFloat) {
        guard toolWidth > 0, drawnWidth > 0 else { return }
        let points = stroke.path.sorted { min($0.size.width, $0.size.height) < min($1.size.width, $1.size.height) }
        guard !points.isEmpty else { return }
        let median = points[points.count / 2]
        profiles.learn(stroke.ink.inkType.rawValue, widthRatio: Double(drawnWidth / toolWidth), opacity: Double(median.opacity),
                       force: Double(median.force), altitude: Double(median.altitude), azimuth: Double(median.azimuth))
        scheduleSave()
    }

    /// A few bytes, off the stroke itself: written a moment later, or when the app goes inactive.
    private func scheduleSave() {
        dirty = true; saveGeneration += 1
        let generation = saveGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.saveGeneration == generation else { return }
            self.saveNow()
        }
    }
    private func saveNow() {
        guard dirty else { return }
        dirty = false
        if let data = profiles.encoded() { UserDefaults.standard.set(data, forKey: Self.key) }
    }
}
