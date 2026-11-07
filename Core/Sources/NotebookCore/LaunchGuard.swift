import Foundation

/// How far a launch (or a later risky step: opening a notebook, the law
/// window) got before the app ended. Stored as its raw value.
public enum LaunchPhase: String, Sendable, CaseIterable {
    case starting
    case library
    case editorOpen = "editor-open"
    case lawWindow = "law-window"

    /// „Der letzte Start wurde … unterbrochen.“
    var interruptedPlace: String {
        switch self {
        case .starting: return "beim Starten"
        case .library: return "in der Bibliothek"
        case .editorOpen: return "beim Öffnen des Hefts"
        case .lawWindow: return "beim Öffnen des Gesetzesfensters"
        }
    }
}

/// Start-Absturzschutz: a run that ended (crash, watchdog) before it was
/// marked finished counts as interrupted. Launches restore the last notebook
/// and the law window, so a crash there would repeat on every launch.
///
/// - First interrupted run: the next launch restores nothing (`skipRestore`).
/// - Two or more in a row: additionally `safe` for that session (optional
///   features off). Never touches user data; only these three values persist.
///
/// A run is finished once the app was active for a few seconds or went to
/// the background cleanly. Opening a notebook or the law window later arms
/// the guard again until that step has run for a few seconds as well.
public struct LaunchGuardState: Equatable, Sendable {
    public enum Mode: Equatable, Sendable { case normal, skipRestore, safe }

    /// What this launch does, decided once by `begin()`.
    public struct Launch: Equatable, Sendable {
        public var mode: Mode
        /// Consecutive interrupted runs before this launch.
        public var interrupted: Int
        /// Phase the last interrupted run reached (nil: unknown or none).
        public var phase: LaunchPhase?
        public init(mode: Mode, interrupted: Int, phase: LaunchPhase?) {
            self.mode = mode; self.interrupted = interrupted; self.phase = phase
        }
    }

    /// The current run is not finished (yet).
    public var inProgress: Bool
    /// Consecutive interrupted runs, including the one counted at `begin()`.
    public var streak: Int
    /// Phase the current run reached (raw value; unknown values are ignored).
    public var phase: String?

    public init(inProgress: Bool = false, streak: Int = 0, phase: String? = nil) {
        self.inProgress = inProgress; self.streak = max(0, streak); self.phase = phase
    }

    /// Start of a launch: counts the previous run if it never finished and
    /// arms the guard for this one.
    public mutating func begin() -> Launch {
        let previous = phase.flatMap(LaunchPhase.init(rawValue:))
        let launch: Launch
        if inProgress {
            streak = min(streak + 1, 99)
            launch = Launch(mode: streak >= 2 ? .safe : .skipRestore, interrupted: streak, phase: previous)
        } else {
            streak = 0
            launch = Launch(mode: .normal, interrupted: 0, phase: nil)
        }
        inProgress = true
        phase = LaunchPhase.starting.rawValue
        return launch
    }

    /// A phase was reached. Returns true when this re-armed a finished run
    /// (notebook or law window opened later): the caller finishes it again
    /// after the same delay.
    @discardableResult
    public mutating func enter(_ next: LaunchPhase) -> Bool {
        if inProgress { phase = next.rawValue; return false }
        guard next == .editorOpen || next == .lawWindow else { return false }
        inProgress = true
        phase = next.rawValue
        return true
    }

    /// The run got past the risky part (active for a while, or a clean
    /// background). The streak stays until the next `begin()`, so a crash
    /// after re-arming still counts on top of it.
    public mutating func finish() {
        inProgress = false
    }

    /// „Normal neu starten“: the next launch runs normally whatever happened.
    public mutating func resetToNormal() {
        inProgress = false; streak = 0; phase = nil
    }

    /// The library's notice for this launch (nil: normal launch).
    public static func notice(for launch: Launch) -> String? {
        guard launch.mode != .normal else { return nil }
        let start = launch.phase.map { "Der letzte Start wurde \($0.interruptedPlace) unterbrochen." } ?? "Der letzte Start wurde unterbrochen."
        var text = start + " Das zuletzt geöffnete Heft wurde nicht automatisch geöffnet."
        if launch.mode == .safe {
            text += " noty läuft bis zum nächsten Start im sicheren Modus: Gesetzesverweise, Handschrifterkennung, Stiftschutz an Bedienelementen, Tippvorschläge und Diagnosen sind aus."
        }
        return text
    }
}
