import SwiftUI
import UIKit
import OSLog
import NotebookCore

/// Start-Absturzschutz (`LaunchGuardState`, Core, with tests): the app
/// reopens the last notebook and the law window at launch, so a crash there
/// would repeat on every launch. After one interrupted run nothing is
/// restored; after two in a row this session also runs in the safe mode
/// (law links and handwriting OCR, `PencilGuard`, typing suggestions and the
/// Hang/Input diagnostics off). Only three UserDefaults values; no user data.
///
/// Breadcrumbs: `log stream`/`idevicesyslog`, subsystem `de.la.noty`,
/// category `launch`.
@MainActor
final class LaunchGuard: ObservableObject {
    static let shared = LaunchGuard()
    nonisolated static let log = Logger(subsystem: "de.la.noty", category: "launch")

    private static let inProgressKey = "noty.launch.inProgress"
    private static let streakKey = "noty.launch.streak"
    private static let phaseKey = "noty.launch.phase"
    /// Active (and drawn) this long: the run counts as finished.
    private static let settleDelay: TimeInterval = 8

    let launch: LaunchGuardState.Launch
    /// The library's notice; nil once dismissed or on a normal launch.
    @Published private(set) var notice: String?
    /// „Normal neu starten“ was chosen: the next launch runs normally.
    @Published private(set) var normalRestartChosen = false
    private var state: LaunchGuardState
    private var finishWork: DispatchWorkItem?

    /// Nothing is restored at this launch (last notebook, law window).
    var skipsRestore: Bool { launch.mode != .normal }
    /// Optional features are off for this session.
    var safeMode: Bool { launch.mode == .safe }
    static var safeMode: Bool { shared.safeMode }

    private init() {
        let defaults = UserDefaults.standard
        var state = LaunchGuardState(inProgress: defaults.bool(forKey: Self.inProgressKey),
                                     streak: defaults.integer(forKey: Self.streakKey),
                                     phase: defaults.string(forKey: Self.phaseKey))
        launch = state.begin()
        self.state = state
        notice = LaunchGuardState.notice(for: launch)
        Self.persist(state)
        // docs/DIAGNOSE.md: the guard's verdict in the run's history.
        Diagnostics.note("launchGuard", ["interrupted": launch.interrupted, "restoreSkipped": launch.mode != .normal ? 1 : 0,
                                         "safeMode": launch.mode == .safe ? 1 : 0])
        Self.log.notice("[launch] begin mode=\(String(describing: self.launch.mode), privacy: .public) interrupted=\(self.launch.interrupted, privacy: .public) lastPhase=\(self.launch.phase?.rawValue ?? "-", privacy: .public)")
    }

    /// Called first thing in `NotyApp.init`, before any model restores state.
    static func start() { _ = shared }

    /// A phase was reached (library ready, notebook opened, law window shown).
    func enter(_ phase: LaunchPhase) {
        let rearmed = state.enter(phase)
        // Set aside (background launch): the stored values are the run before.
        guard state.inProgress, !state.setAside else { return }
        Self.persist(state)
        Self.log.notice("[launch] phase=\(phase.rawValue, privacy: .public)\(rearmed ? " (armed again)" : "", privacy: .public)")
        if rearmed { scheduleFinish() }
    }

    /// `NotyApp`'s scene phase: active for a while or a clean background
    /// finishes the run.
    func scenePhaseChanged(_ phase: ScenePhase) {
        // A scene in the foreground: a run set aside as a background launch
        // is a start the user sees from here on.
        if phase != .background, state.foreground() {
            Self.persist(state)
            Self.log.notice("[launch] shown after a background launch (armed again)")
        }
        switch phase {
        case .active:
            Self.log.notice("[launch] scene active")
            scheduleFinish()
        case .background:
            finish(reason: "background")
        default: break
        }
    }

    /// The calendar's background refresh starts (`NotyApp`, `.backgroundTask`).
    /// In a process iPadOS launched for it that has shown no scene, this run
    /// is no start the user saw: it is set aside, so the suspended process
    /// ending later is not counted as interrupted, and the verdict about the
    /// run before stays for the next real start. Nothing changes for a
    /// process the user had opened. Not decided in `didFinishLaunching`: with
    /// scenes the application state there is no reliable sign of a
    /// background launch, and a wrong guess would disarm a real start.
    func backgroundRefreshBegan() {
        guard UIApplication.shared.applicationState == .background, state.backgroundLaunch() else { return }
        finishWork?.cancel(); finishWork = nil
        Self.persist(state)
        Self.log.notice("[launch] background launch without a shown scene: not counted")
    }

    /// „Normal neu starten“: only clears the guard; the user restarts the app.
    func restartNormally() {
        finishWork?.cancel(); finishWork = nil
        state.resetToNormal()
        Self.persist(state)
        normalRestartChosen = true
        notice = "Beim nächsten Start läuft noty wieder normal. Bitte die App schließen und neu öffnen."
        Self.log.notice("[launch] reset to normal by the user")
    }

    func dismissNotice() { notice = nil }

    private func scheduleFinish() {
        guard state.inProgress, finishWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.finish(reason: "settled") }
        }
        finishWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.settleDelay, execute: work)
    }

    private func finish(reason: String) {
        finishWork?.cancel(); finishWork = nil
        guard state.inProgress, !state.setAside else { return }
        state.finish()
        Self.persist(state)
        Self.log.notice("[launch] finished (\(reason, privacy: .public))")
    }

    /// Written at once and flushed: the next launch must see it even after
    /// a crash a moment later.
    private static func persist(_ state: LaunchGuardState) {
        let defaults = UserDefaults.standard
        defaults.set(state.inProgress, forKey: inProgressKey)
        defaults.set(state.streak, forKey: streakKey)
        if let phase = state.phase { defaults.set(phase, forKey: phaseKey) } else { defaults.removeObject(forKey: phaseKey) }
        defaults.synchronize()
    }
}

/// The library's notice after an interrupted launch.
struct LaunchNoticeBanner: View {
    @ObservedObject private var guardModel = LaunchGuard.shared
    var body: some View {
        if let notice = guardModel.notice {
            HStack(alignment: .top, spacing: 12) {
                Label(notice, systemImage: guardModel.safeMode && !guardModel.normalRestartChosen ? "shield.lefthalf.filled" : "exclamationmark.triangle")
                    .font(.caption).frame(maxWidth: .infinity, alignment: .leading)
                if guardModel.safeMode && !guardModel.normalRestartChosen {
                    Button("Normal neu starten") { guardModel.restartNormally() }
                        .font(.caption.weight(.semibold)).buttonStyle(.bordered)
                }
                Button { guardModel.dismissNotice() } label: { Image(systemName: "xmark") }
                    .font(.caption).buttonStyle(.plain).accessibilityLabel("Hinweis schließen")
            }
            .padding().frame(maxWidth: .infinity, alignment: .leading)
            .background(.orange.opacity(0.12))
        }
    }
}
