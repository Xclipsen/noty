import Foundation

/// The last runs of the app, so that a report delivered later (MetricKit at
/// the next launch) finds the run it belongs to, and so that a run that ended
/// in the foreground without a clean exit is noticed. One small JSON file;
/// rewritten only on phase and scene changes.
public struct DiagnosticSessionLog: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable {
        /// Started, not yet active.
        case launching
        /// In the foreground.
        case active
        /// Went to the background or inactive cleanly: being ended now is normal.
        case background
    }

    public struct Session: Codable, Equatable, Sendable {
        public var launchID: String
        public var build: String
        public var startedAt: Int64
        public var phase: String
        public var state: State
        /// Last time the state or phase changed.
        public var updatedAt: Int64
    }

    public static let keptSessions = 5
    public private(set) var sessions: [Session] = []

    public init(sessions: [Session] = []) { self.sessions = sessions }

    public static func load(_ url: URL) -> DiagnosticSessionLog {
        guard let data = try? Data(contentsOf: url), let log = try? JSONDecoder().decode(Self.self, from: data) else { return .init() }
        return log
    }

    public func save(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }

    /// Starts a new run. Returns the previous run when it ended while the
    /// app was launching or in the foreground (a crash, a watchdog kill or an
    /// out-of-memory end) and the launch IDs no longer kept.
    public mutating func begin(launchID: String, build: String, at time: Int64) -> (abnormal: Session?, dropped: [String]) {
        let abnormal = sessions.last.flatMap { $0.state == .background ? nil : $0 }
        sessions.append(Session(launchID: launchID, build: build, startedAt: time, phase: "launch", state: .launching, updatedAt: time))
        var dropped: [String] = []
        while sessions.count > Self.keptSessions { dropped.append(sessions.removeFirst().launchID) }
        return (abnormal, dropped)
    }

    public mutating func update(launchID: String, phase: String? = nil, state: State? = nil, at time: Int64) {
        guard let index = sessions.lastIndex(where: { $0.launchID == launchID }) else { return }
        if let phase { sessions[index].phase = phase }
        if let state { sessions[index].state = state }
        sessions[index].updatedAt = time
    }

    /// The run that was going on at `time` (milliseconds since 1970).
    public func session(at time: Int64) -> Session? {
        sessions.last { $0.startedAt <= time }
    }

    public func session(id: String) -> Session? { sessions.first { $0.launchID == id } }
}

/// Reports waiting to be sent and the ones already sent, for „Letzte
/// Berichte“. Files are written atomically; a report is only ever moved from
/// `pending` to `sent` after the server confirmed it. Old files go after 90
/// days; at most 50 pending and 30 sent stay.
public final class DiagnosticOutbox: @unchecked Sendable {
    public struct Entry: Equatable, Sendable {
        public var report: DiagnosticReport
        public var url: URL
        public var sent: Bool
    }

    public static let retentionDays = 90
    public static let maximumPending = 50
    public static let maximumSent = 30
    /// More than this many reports per day of the noisy kinds (slow, hang,
    /// failure) are not kept: a loop must not fill the device or the server.
    public static let dailyLimit = 40

    public let directory: URL
    private let lock = NSLock()
    private var pendingURL: URL { directory.appendingPathComponent("pending", isDirectory: true) }
    private var sentURL: URL { directory.appendingPathComponent("sent", isDirectory: true) }

    public init(directory: URL) { self.directory = directory }

    /// Adds a report. Returns false when the daily limit keeps it out.
    @discardableResult
    public func add(_ report: DiagnosticReport, now: Date = Date()) throws -> Bool {
        let data = try report.encoded()
        guard data.count <= DiagnosticReport.maximumEncodedSize else { throw DiagnosticOutboxError.tooLarge(data.count) }
        lock.lock(); defer { lock.unlock() }
        try FileManager.default.createDirectory(at: pendingURL, withIntermediateDirectories: true)
        let noisy: Set<DiagnosticKind> = [.slow, .hang, .appHang, .failure, .cpu, .diskWrite]
        if noisy.contains(report.kind) {
            let dayAgo = DiagnosticReport.milliseconds(now) - 86_400_000
            let today = (entriesLocked(in: pendingURL, sent: false) + entriesLocked(in: sentURL, sent: true))
                .filter { $0.report.createdAt >= dayAgo && noisy.contains($0.report.kind) }.count
            if today >= Self.dailyLimit { return false }
        }
        let time = String(max(report.createdAt, 0)), padded = String(repeating: "0", count: max(0, 13 - time.count)) + time
        let name = "\(padded)-\(report.kind.rawValue)-\(report.id).json"
        try data.write(to: pendingURL.appendingPathComponent(name), options: .atomic)
        pruneLocked(now: now)
        return true
    }

    public func pending() -> [Entry] {
        lock.lock(); defer { lock.unlock() }
        return entriesLocked(in: pendingURL, sent: false)
    }

    /// Pending and sent, newest first.
    public func recent(limit: Int = 30) -> [Entry] {
        lock.lock(); defer { lock.unlock() }
        let all = entriesLocked(in: pendingURL, sent: false) + entriesLocked(in: sentURL, sent: true)
        return Array(all.sorted { $0.report.createdAt > $1.report.createdAt }.prefix(limit))
    }

    public func markSent(_ entry: Entry, now: Date = Date()) throws {
        lock.lock(); defer { lock.unlock() }
        try FileManager.default.createDirectory(at: sentURL, withIntermediateDirectories: true)
        let target = sentURL.appendingPathComponent(entry.url.lastPathComponent)
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: entry.url, to: target)
        pruneLocked(now: now)
    }

    public func removeAll() {
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.removeItem(at: pendingURL)
        try? FileManager.default.removeItem(at: sentURL)
    }

    private func entriesLocked(in folder: URL, sent: Bool) -> [Entry] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }.compactMap { url in
            guard let data = try? Data(contentsOf: url), let report = try? DiagnosticReport.decode(data) else {
                // Unreadable or from another format: of no use, never sent.
                try? FileManager.default.removeItem(at: url); return nil
            }
            return Entry(report: report, url: url, sent: sent)
        }
    }

    private func pruneLocked(now: Date) {
        let cutoff = DiagnosticReport.milliseconds(now) - Int64(Self.retentionDays) * 86_400_000
        for (folder, keep) in [(pendingURL, Self.maximumPending), (sentURL, Self.maximumSent)] {
            let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasSuffix(".json") }.sorted()
            for (index, name) in names.enumerated() {
                let time = Int64(name.prefix(13)) ?? 0
                if time < cutoff || index < names.count - keep { try? FileManager.default.removeItem(at: folder.appendingPathComponent(name)) }
            }
        }
    }
}

public enum DiagnosticOutboxError: Error, Equatable {
    case tooLarge(Int)
}

/// One report per operation and hour at most for `slow`; the breadcrumb is
/// written every time regardless.
public struct DiagnosticThrottle: Sendable {
    public var interval: Int64
    private var last: [String: Int64] = [:]

    public init(intervalMilliseconds: Int64 = 3_600_000) { interval = intervalMilliseconds }

    public mutating func allow(_ key: String, at time: Int64) -> Bool {
        if let previous = last[key], time - previous < interval { return false }
        last[key] = time
        return true
    }
}

/// Thresholds for slow operations (docs/DIAGNOSE.md). Above the threshold an
/// operation leaves a `slow` breadcrumb and, at most hourly, a report.
public enum DiagnosticThresholds {
    /// The main thread stalls: a breadcrumb from here on …
    public static let hangNoteMilliseconds = 250
    /// … and a report with the main thread's stack from here on.
    public static let hangReportMilliseconds = 2_000

    public static func milliseconds(for operation: String) -> Int {
        switch operation {
        case "notebook.open": 2_000
        case "page.switch": 500
        case "save": 1_000
        case "stroke.commit": 150
        case "law.window": 1_000
        case "law.load": 2_000
        case "search": 2_000
        case "pdf.export": 15_000
        case "backup": 30_000
        case "appSync": 15_000
        default: 1_000
        }
    }
}
