import UIKit

// Feedback 09.11.2026: after importing into an existing notebook (a PDF via
// „Seite hinzufügen“ or a shared file appended through the filing sheet) the
// notebook no longer scrolled until the user opened the „…“ menu. Opening a
// menu makes UIKit cancel every touch and reset every gesture recognizer.
// What it repaired: a recognizer that took a touch whose end never arrived
// (the touch that went on in a sheet, a file picker or another app) and so
// stayed waiting, while the notebook's scroll pan waited for it in turn.
//
// Two safeguards, so no such state needs an unrelated tap again:
// - when a sheet, picker, dialog or import over the editor ends and when the
//   app returns to the foreground, every notebook viewport resets its gesture
//   recognizers once it is idle (`NotebookViewport.resetStalledGestures`),
//   exactly what the menu did;
// - noty's own recognizers that keep touches drop the ones the current event
//   no longer has (`UIEvent.stillDown`) before they decide anything.

extension Notification.Name {
    /// Something presented over the editor ended: viewports reset recognizers a lost touch may have left waiting.
    static let notyResetStalledGestures = Notification.Name("noty.resetStalledGestures")
}

enum StalledGestures {
    @MainActor static func requestReset() {
        NotificationCenter.default.post(name: .notyResetStalledGestures, object: nil)
    }
}

extension UIEvent {
    /// `touch` is still down in this event. A tracked touch that is not lost
    /// its end (a sheet or another app took over mid-touch) and must not keep
    /// a recognizer waiting.
    func stillDown(_ touch: UITouch) -> Bool {
        (allTouches?.contains(touch) ?? false) && touch.phase != .ended && touch.phase != .cancelled
    }
}
