import Foundation

/// Zoom and scroll position of a viewport when its scene stopped being active.
public struct ViewportResumePoint: Equatable, Sendable {
    public var size: PageSize
    public var zoom: Double
    public var offset: PagePoint
    public var pageID: UUID?
    public init(size: PageSize, zoom: Double, offset: PagePoint, pageID: UUID?) {
        self.size = size; self.zoom = zoom; self.offset = offset; self.pageID = pageID
    }
    /// Same viewport size (within half a point) and same selected page.
    public func applies(size other: PageSize, pageID id: UUID?) -> Bool {
        abs(size.width - other.width) < 0.5 && abs(size.height - other.height) < 0.5 && pageID == id
    }
}

/// Leaving the app and coming back is no reason to move the view (Nutzer
/// 03.11.2026: noty zog nach der Rückkehr zum Textfeld). Meanwhile iPadOS
/// hides and shows the keyboard again, may resize the window for its app
/// switcher snapshots (other orientation) and may report caret or text
/// changes of its own. None of that is the user's input.
///
/// - While the scene is inactive nothing reveals the caret.
/// - After the return the gate *holds*: keyboard, layout and page events
///   (`.passive`) do not move the view; a caret move (`.navigation`) only once
///   the user touched or pressed a key since the return, or after the settle
///   window (system restore events come right at the return); typing always.
///   The first such real request ends the hold, everything works as before.
/// - Within the settle window (and while inactive) a viewport that is back at
///   the size it was left at takes the exact zoom and offset it had.
public struct CaretRevealGate: Equatable, Sendable {
    public enum Source: Equatable, Sendable {
        /// Keyboard frame, layout, page change: nobody moved the caret.
        case passive
        /// The caret moved: tap, arrow keys, beginning to edit, focus request.
        case navigation
        /// Text changed at the caret (keys, dictation, Scribble).
        case typing
        public init(_ kind: CaretReveal?) {
            switch kind {
            case nil: self = .passive
            case .navigation?: self = .navigation
            case .typing?, .typewriter?: self = .typing
            }
        }
    }
    /// Seconds after the return in which UIKit's own events are expected.
    public static let settleWindow: Double = 1.5

    public private(set) var inactive = false
    public private(set) var holding = false
    public private(set) var deactivatedAt: Double?
    public private(set) var returnedAt: Double?
    public private(set) var resumePoint: ViewportResumePoint?

    public init() {}

    /// The scene stops being active (app switcher, Home, Control Center).
    public mutating func deactivate(at now: Double, resume: ViewportResumePoint?) {
        // A second notice while still inactive keeps the first state.
        guard !inactive else { return }
        inactive = true; holding = true; deactivatedAt = now; returnedAt = nil
        resumePoint = resume
    }
    public mutating func activate(at now: Double) {
        guard inactive else { return }
        inactive = false; returnedAt = now
    }

    /// The user touched the screen or pressed a key after the return.
    public func userActed(lastUserInput: Double?) -> Bool {
        guard let returnedAt, let lastUserInput else { return false }
        return lastUserInput >= returnedAt
    }
    private func settling(at now: Double) -> Bool {
        guard let returnedAt else { return false }
        return now - returnedAt < Self.settleWindow
    }

    public func allows(_ source: Source, now: Double, lastUserInput: Double?) -> Bool {
        if inactive { return false }
        guard holding else { return true }
        switch source {
        case .typing: return true
        case .navigation: return userActed(lastUserInput: lastUserInput) || !settling(at: now)
        case .passive: return false
        }
    }
    /// `allows`, and a real request ends the hold.
    public mutating func admit(_ source: Source, now: Double, lastUserInput: Double?) -> Bool {
        guard allows(source, now: now, lastUserInput: lastUserInput) else { return false }
        if holding, source != .passive { holding = false }
        return true
    }

    /// Zoom and offset to put back: only while inactive or settling, before
    /// the user did anything, for the same viewport size and page.
    public func resume(size: PageSize, pageID: UUID?, now: Double, lastUserInput: Double?) -> ViewportResumePoint? {
        guard let resumePoint, inactive || settling(at: now), !userActed(lastUserInput: lastUserInput),
              resumePoint.applies(size: size, pageID: pageID) else { return nil }
        return resumePoint
    }
}
