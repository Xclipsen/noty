import Foundation

/// Decides at launch whether the last notebook is reopened automatically.
/// A launch with an explicit reason – an incoming file or URL, a tapped
/// notification, the widget/tile link – shows what was asked for instead; the
/// stored pointer is kept for the next normal launch. The reason can arrive
/// after the library has loaded, so the decision waits for the first scene
/// activation: the reason is reported with it.
public struct LaunchReopenGate: Equatable, Sendable {
    public enum Decision: Equatable, Sendable { case wait, reopen, skip }
    /// Once set it stays for this process: only the launch reopens a notebook.
    public private(set) var explicitReason = false
    public init() {}
    public mutating func noteExplicitReason() { explicitReason = true }
    public func decision(sceneActive: Bool) -> Decision {
        if explicitReason { return .skip }
        return sceneActive ? .reopen : .wait
    }
}
