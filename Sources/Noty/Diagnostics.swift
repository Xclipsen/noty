import Foundation
import UIKit
import OSLog
import os
import NotebookCore

/// Einheitliche Fehler- und Ruckler-Diagnose (docs/DIAGNOSE.md).
///
/// Collects in every app: the event history of this run (`DiagnosticJournal`,
/// fixed names and numbers only), measured operations, failures, the own
/// hang watchdog (`HangProbe`) and MetricKit (`DiagnosticsMetricKit`).
/// Reports wait in Library/Application Support/Diagnose (not in Documents,
/// not in backups) and go to the own server only when „Fehlerberichte
/// automatisch senden“ is on: in noty dev, noty AI and noty calendar by
/// default, in noty never unless the user switches it on. The server address
/// and key come from Info.plist (`NotyDiagURL`, `NotyDiagKey`), written by
/// publish_ota.sh from `.tools/ota.env`; local builds have none and send nothing.
///
/// Everything here is cheap on the calling thread: an event is one locked
/// append and one unbuffered `write`; reports are encoded and sent on a
/// utility queue.
enum Diagnostics {
    static let log = Logger(subsystem: "de.la.noty", category: "diagnostics")
    static let autoSendKey = "noty.diagnostics.autoSend"

    // MARK: Identity of this build

    static let channel = Bundle.main.object(forInfoDictionaryKey: "NotyChannel") as? String ?? "stable"
    static var isTestChannel: Bool { channel != "stable" }
    static let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
    static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    static let commit = (Bundle.main.object(forInfoDictionaryKey: "NotyCommit") as? String) ?? ""
    static let serverURL: URL? = (Bundle.main.object(forInfoDictionaryKey: "NotyDiagURL") as? String)
        .flatMap { $0.hasPrefix("https://") ? URL(string: $0) : nil }
    static let serverKey = (Bundle.main.object(forInfoDictionaryKey: "NotyDiagKey") as? String) ?? ""
    /// This build knows a server to send to.
    static var canSend: Bool { serverURL != nil && serverKey.count >= 16 }
    static var defaultAutoSend: Bool { isTestChannel }
    static var autoSend: Bool {
        canSend && (UserDefaults.standard.object(forKey: autoSendKey) as? Bool ?? defaultAutoSend)
    }

    static let appImage: String = {
        (Bundle.main.executableURL?.lastPathComponent).flatMap(DiagnosticPrivacy.safeDetail) ?? "Noty"
    }()

    static let launchID = UUID().uuidString

    static let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Diagnose", isDirectory: true)
    }()
    private static var sessionsURL: URL { directory.appendingPathComponent("sessions.json") }
    private static var journalDirectory: URL { directory.appendingPathComponent("journal", isDirectory: true) }

    static let outbox = DiagnosticOutbox(directory: directory.appendingPathComponent("reports", isDirectory: true))
    static let journal = DiagnosticJournal(launchID: launchID, directory: journalDirectory)

    nonisolated(unsafe) private static var reporterStorage: DiagnosticReporter?
    static var reporter: DiagnosticReporter {
        if let reporterStorage { return reporterStorage }
        // Before `start` (should not happen): a reporter without device facts.
        return DiagnosticReporter(app: appInfo, device: DiagnosticDeviceInfo(model: "?", os: "?"), launchID: launchID, appImage: appImage)
    }
    private static var appInfo: DiagnosticAppInfo {
        DiagnosticAppInfo(channel: channel, bundleID: Bundle.main.bundleIdentifier ?? "?", version: version, build: build,
                          commit: DiagnosticPrivacy.safeDetail(commit) ?? "")
    }

    /// Session state; changed on the main actor only, read from the watchdog.
    private struct State: Sendable {
        var sessions = DiagnosticSessionLog()
        var phase = "launch"
        var throttle = DiagnosticThrottle()
        /// Longest duration stored per `appHang` report: a late 2 s write
        /// never replaces the final one.
        var hangMilliseconds: [String: Int] = [:]
    }
    private static let state = OSAllocatedUnfairLock(initialState: State())
    static var phase: String { state.withLock { $0.phase } }
    static let queue = DispatchQueue(label: "noty.diagnostics", qos: .utility)

    // MARK: Start

    @MainActor private static var started = false

    /// First thing in `NotyApp.init`.
    @MainActor static func start() {
        guard !started else { return }
        started = true
        var uts = utsname()
        uname(&uts)
        let machine = withUnsafeBytes(of: &uts.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        let device = DiagnosticDeviceInfo(model: DiagnosticPrivacy.safeDetail(machine) ?? "?",
                                          os: "iPadOS \(UIDevice.current.systemVersion)")
        reporterStorage = DiagnosticReporter(app: appInfo, device: device, launchID: launchID, appImage: appImage)
        let now = DiagnosticReport.milliseconds(Date())
        // File I/O outside the lock; nothing else touches the sessions yet.
        var sessions = DiagnosticSessionLog.load(sessionsURL)
        let (abnormal, dropped) = sessions.begin(launchID: launchID, build: build, at: now)
        try? sessions.save(sessionsURL)
        state.withLock { [sessions] in $0.sessions = sessions }
        journal.record("app.launch", ["build": Int(build) ?? 0])
        // The old run's journal is read off the main thread.
        queue.async {
            for id in dropped { try? FileManager.default.removeItem(at: journalDirectory.appendingPathComponent("\(id).jsonl")) }
            guard let abnormal else { return }
            let crumbs = DiagnosticJournal.load(journalDirectory.appendingPathComponent("\(abnormal.launchID).jsonl"))
            add(reporter.abnormalExit(abnormal, breadcrumbs: crumbs, at: now))
            log.error("Previous run \(abnormal.launchID, privacy: .public) ended abnormally in phase \(abnormal.phase, privacy: .public)")
        }
        DiagnosticsMetricKit.shared.subscribe()
        HangProbe.installWatchdog()
        Uploader.shared.schedule(after: 15)
    }

    /// The run's breadcrumbs up to `time`, for MetricKit reports of earlier
    /// runs: never this run, even when the payload ends after this launch.
    static func breadcrumbs(ofRunAt time: Int64) -> (DiagnosticSessionLog.Session?, [DiagnosticBreadcrumb]) {
        let session = state.withLock { $0.sessions.session(before: time, excluding: launchID) }
        guard let session else { return (nil, []) }
        return (session, DiagnosticJournal.load(journalDirectory.appendingPathComponent("\(session.launchID).jsonl"), until: time))
    }

    // MARK: Events and phases

    /// One step of the history: a fixed name and numbers, never content.
    static func note(_ event: DiagnosticEvent, _ values: KeyValuePairs<DiagnosticKey, Int> = [:]) {
        journal.record(event, values)
    }

    /// A launch phase was reached (library, notebook, lawWindow, running).
    static func enter(phase: DiagnosticEvent) {
        let now = DiagnosticReport.milliseconds(Date())
        let changed = state.withLock { state -> Bool in
            guard state.phase != phase.name else { return false }
            state.phase = phase.name
            state.sessions.update(launchID: launchID, phase: phase.name, at: now)
            return true
        }
        guard changed else { return }
        journal.append(name: "phase." + phase.name, values: [:])
        persistSessions()
    }

    enum SceneState { case active, inactive, background }

    /// `NotyApp`'s scene phase: background (and inactive) count as a clean
    /// place to be ended by the system; active means a crash now is abnormal.
    @MainActor static func scene(_ scene: SceneState) {
        let now = DiagnosticReport.milliseconds(Date())
        let sessionState: DiagnosticSessionLog.State = scene == .active ? .active : .background
        state.withLock { $0.sessions.update(launchID: launchID, state: sessionState, at: now) }
        switch scene {
        case .active:
            journal.record("scene.active")
            Uploader.shared.schedule(after: 5)
            runningWork?.cancel()
            let work = DispatchWorkItem { enter(phase: "running") }
            runningWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: work)
        case .inactive: journal.record("scene.inactive")
        case .background: journal.record("scene.background")
        }
        persistSessions()
    }
    @MainActor private static var runningWork: DispatchWorkItem?

    private static func persistSessions() {
        let sessions = state.withLock { $0.sessions }
        // Small and rare (phase and scene changes); written at once so that
        // a crash a moment later is attributed correctly.
        try? sessions.save(sessionsURL)
    }

    // MARK: Measured operations

    struct Measurement: Sendable {
        let operation: DiagnosticEvent
        let start: CFTimeInterval
        let quiet: Bool
    }

    /// Starts a measurement. `quiet`: no breadcrumb unless it was slow
    /// (strokes, which happen too often for the history).
    static func begin(_ operation: DiagnosticEvent, quiet: Bool = false) -> Measurement {
        Measurement(operation: operation, start: CACurrentMediaTime(), quiet: quiet)
    }

    /// Ends a measurement: a breadcrumb with its duration and, above the
    /// operation's threshold, a `slow` breadcrumb and at most hourly a report.
    @discardableResult
    static func end(_ measurement: Measurement, _ values: KeyValuePairs<DiagnosticKey, Int> = [:]) -> Int {
        let ms = Int((CACurrentMediaTime() - measurement.start) * 1000)
        let threshold = DiagnosticThresholds.milliseconds(for: measurement.operation.name)
        var numbers: [String: Int] = ["ms": ms]
        for (key, value) in values { numbers[key.name] = value }
        let slow = ms >= threshold
        if !measurement.quiet || slow {
            journal.append(name: measurement.operation.name, values: numbers)
        }
        guard slow else { return ms }
        journal.append(name: "slow", values: ["ms": ms])
        let now = DiagnosticReport.milliseconds(Date())
        let allowed = state.withLock { $0.throttle.allow("slow." + measurement.operation.name, at: now) }
        guard allowed else { return ms }
        let extra = numbers.filter { $0.key != "ms" }
        let breadcrumbs = journal.recent(), phase = self.phase
        queue.async {
            add(reporter.slow(measurement.operation, milliseconds: ms, threshold: threshold, values: extra,
                              phase: phase, breadcrumbs: breadcrumbs, at: now))
        }
        return ms
    }

    /// Pending measurements across objects (notebook open: library tap → editor loaded).
    @MainActor private static var open: [String: Measurement] = [:]
    @MainActor static func begin(shared operation: DiagnosticEvent) { open[operation.name] = begin(operation) }
    @MainActor static func end(shared operation: DiagnosticEvent, _ values: KeyValuePairs<DiagnosticKey, Int> = [:]) {
        guard let measurement = open.removeValue(forKey: operation.name) else { return }
        // Left over from an attempt that never ended (a missed cancel): no measurement.
        guard CACurrentMediaTime() - measurement.start <= 60 else { return }
        end(measurement, values)
    }
    @MainActor static func cancel(shared operation: DiagnosticEvent) { open.removeValue(forKey: operation.name) }

    /// A failure: a breadcrumb and (hourly per operation) a report with the
    /// error's domain and code only.
    static func failure(_ operation: DiagnosticEvent, _ error: Error) {
        let code = DiagnosticReporter.errorCode(error)
        journal.append(name: "failure", values: ["code": code.code])
        journal.append(name: operation.name + ".failed", values: [:])
        let now = DiagnosticReport.milliseconds(Date())
        guard state.withLock({ $0.throttle.allow("failure." + operation.name, at: now) }) else { return }
        let breadcrumbs = journal.recent(), phase = self.phase
        queue.async { add(reporter.failure(operation, error: error, phase: phase, breadcrumbs: breadcrumbs, at: now)) }
    }

    // MARK: Hangs (HangProbe)

    /// A main run-loop iteration took `ms` ≥ 250 ms. Main thread.
    static func noteHang(milliseconds ms: Int) { journal.record("hang", ["ms": ms]) }

    /// The watchdog saw main stalled for 2 s; called on `queue`. The same
    /// report is rewritten with the final duration when the stall ends (the
    /// uploader skips it until then, `HangProbe.unfinishedReportID`); the
    /// longer duration always wins.
    static func hangReport(milliseconds ms: Int, stack: [DiagnosticFrame], id: String, createdAt: Int64, test: Bool) {
        let ms = state.withLock { state -> Int in
            let longest = max(ms, state.hangMilliseconds[id] ?? 0)
            state.hangMilliseconds[id] = longest
            return longest
        }
        var report = reporter.appHang(milliseconds: ms, stack: stack, phase: phase, breadcrumbs: journal.recent(), at: createdAt, test: test)
        report.id = id
        add(report, upload: false)
    }

    // MARK: Reports

    static func add(_ report: DiagnosticReport, upload: Bool = true) {
        do {
            if try outbox.add(report) {
                log.notice("Report \(report.kind.rawValue, privacy: .public): \(report.summary, privacy: .public)")
                if upload { Uploader.shared.schedule(after: 5) }
            }
        } catch {
            log.error("Report not stored: \(String(describing: error), privacy: .public)")
        }
        DispatchQueue.main.async { NotificationCenter.default.post(name: reportsChanged, object: nil) }
    }

    static let reportsChanged = Notification.Name("noty.diagnostics.reportsChanged")

    /// „Testbericht senden“ in the hidden test menu.
    static func sendTestReport() {
        let now = DiagnosticReport.milliseconds(Date())
        journal.record("test.report")
        add(reporter.test("test.report", phase: phase, breadcrumbs: journal.recent(), at: now))
        Uploader.shared.schedule(after: 0)
    }

    // MARK: Sharing

    /// „Diagnose teilen …“: recent reports, the runs and this run's history in
    /// one JSON file (no content: the same data the server would get).
    static func exportFile() throws -> URL {
        let reports = outbox.recent(limit: 30).map(\.report)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        struct Export: Encodable {
            var app: DiagnosticAppInfo; var device: DiagnosticDeviceInfo; var phase: String
            var sessions: DiagnosticSessionLog; var breadcrumbs: [DiagnosticBreadcrumb]; var reports: [DiagnosticReport]
        }
        let export = Export(app: reporter.app, device: reporter.device, phase: phase,
                            sessions: state.withLock { $0.sessions }, breadcrumbs: journal.recent(), reports: reports)
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withFullDate, .withTime]
        let stamp = formatter.string(from: Date())
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("noty-diagnose-\(channel)-\(build)-\(stamp).json")
        try encoder.encode(export).write(to: url, options: .atomic)
        return url
    }
}

extension DiagnosticJournal {
    /// Names built from fixed parts in this file (operation names plus a
    /// fixed suffix); `DiagnosticPrivacy` drops anything else when a report
    /// is built.
    fileprivate func append(name: String, values: [String: Int]) {
        guard DiagnosticPrivacy.isSafeName(name) else { return }
        append(DiagnosticBreadcrumb(t: DiagnosticReport.milliseconds(Date()), e: name, v: values))
    }
}

// MARK: - Sending

/// Sends pending reports one by one to the own server and moves each to
/// `sent` only after a 2xx answer. Off unless `Diagnostics.autoSend`.
final class Uploader: @unchecked Sendable {
    static let shared = Uploader()
    private struct Flags: Sendable { var scheduled = false; var running = false; var lastResult: String? }
    private let flags = OSAllocatedUnfairLock(initialState: Flags())
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.waitsForConnectivity = false
        configuration.httpCookieStorage = nil
        return URLSession(configuration: configuration)
    }()

    func schedule(after seconds: Double) {
        let first = flags.withLock { flags -> Bool in
            guard !flags.scheduled else { return false }
            flags.scheduled = true; return true
        }
        guard first else { return }
        Diagnostics.queue.asyncAfter(deadline: .now() + seconds) { [self] in
            flags.withLock { $0.scheduled = false }
            Task { await flush() }
        }
    }

    func flush(force: Bool = false) async {
        guard force || Diagnostics.autoSend, let url = Diagnostics.serverURL, Diagnostics.canSend else { return }
        let started = flags.withLock { flags -> Bool in
            guard !flags.running else { return false }
            flags.running = true; return true
        }
        guard started else { return }
        defer { flags.withLock { $0.running = false } }
        var sent = 0
        for entry in Diagnostics.outbox.pending() {
            // A stall still going on: sent with its final duration later.
            guard entry.report.id != HangProbe.unfinishedReportID else { continue }
            guard let body = try? entry.report.encoded() else { continue }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(Diagnostics.serverKey, forHTTPHeaderField: "X-Noty-Key")
            request.setValue("noty-diagnostics/1", forHTTPHeaderField: "User-Agent")
            do {
                let (_, response) = try await session.upload(for: request, from: body)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if (200..<300).contains(status) || status == 409 {
                    // 409: the server has this report already.
                    try? Diagnostics.outbox.markSent(entry)
                    sent += 1
                } else if status == 400 || status == 413 {
                    // The server will never take it: keep it locally, marked sent so it does not loop.
                    try? Diagnostics.outbox.markSent(entry)
                    setResult("Server lehnte einen Bericht ab (\(status))")
                } else {
                    setResult("Senden fehlgeschlagen (HTTP \(status))"); break
                }
            } catch {
                setResult("Server nicht erreichbar"); break
            }
        }
        if sent > 0 {
            setResult("\(sent) gesendet, \(Date().formatted(date: .omitted, time: .shortened))")
            DispatchQueue.main.async { NotificationCenter.default.post(name: Diagnostics.reportsChanged, object: nil) }
        }
    }

    private func setResult(_ text: String) {
        flags.withLock { $0.lastResult = text }
        Diagnostics.log.notice("Upload: \(text, privacy: .public)")
    }

    var status: String? { flags.withLock { $0.lastResult } }
}
