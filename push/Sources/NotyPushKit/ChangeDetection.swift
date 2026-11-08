import Foundation
import NotebookCore

/// A timetable change as the push service needs it. Decoupled from Core's
/// `CalendarLessonChange` so the service only depends on this adapter.
public struct DetectedChange: Equatable, Sendable {
    /// Stable id, identical to the one the app computes for the same change.
    public var id: String
    public var kinds: [String]
    public var text: String
    public var lesson: CalendarLesson
}

/// The comparison of two snapshots. One implementation: Core's
/// `CalendarChangeDetector` (the same logic as in the app). The protocol
/// exists so tests can inject results and a later Core API change only
/// touches `CoreChangeDetector`.
public protocol TimetableChangeDetecting: Sendable {
    func changes(old: CalendarSourceSnapshot?, new: CalendarSourceSnapshot, now: Date, calendar: Calendar) -> [DetectedChange]
}

public struct CoreChangeDetector: TimetableChangeDetecting {
    public init() {}
    public func changes(old: CalendarSourceSnapshot?, new: CalendarSourceSnapshot, now: Date, calendar: Calendar) -> [DetectedChange] {
        CalendarChangeDetector.changes(old: old, new: new, now: now, calendar: calendar).map {
            DetectedChange(id: $0.id, kinds: $0.kinds.map(\.rawValue), text: $0.text(calendar: calendar), lesson: $0.lesson)
        }
    }
}
