import Foundation

public enum ExternalBackupTarget: String, Codable, Sendable { case disabled, folder, webDAV }
/// Result of the last attempt that actually ran. A postponed attempt (editor
/// busy, saving) is not recorded and never counts as a failure.
public enum ExternalBackupOutcome: String, Codable, Sendable { case unreachable, failed, succeeded }

public struct ExternalBackupPolicy: Codable, Equatable, Sendable {
    public var version = 1
    public var series = UUID()
    public var target: ExternalBackupTarget = .disabled
    public var keep = 7
    public var folderBookmark: Data?
    /// Display name of the chosen folder; optional for policies stored by older builds.
    public var folderName: String?
    public var endpoint = ""
    public var lastAttempt: Date?
    public var lastSuccess: Date?
    // Optional so policies stored by older builds keep decoding.
    public var configuredAt: Date?
    public var lastOutcome: ExternalBackupOutcome?
    /// Short German reason of the last failure; never contains credentials or URLs.
    public var lastFailureReason: String?
    public var consecutiveFailures: Int?
    /// Warning of the last success, e.g. a notebook archived in an older readable state.
    public var lastWarning: String?
    public init() {}
    public func validate() throws {
        guard version == 1, (3...30).contains(keep), (consecutiveFailures ?? 0) >= 0,
              (lastFailureReason?.count ?? 0) <= 300, (lastWarning?.count ?? 0) <= 300 else { throw StorageError.invalidDocument }
        if target == .folder { guard let folderBookmark, !folderBookmark.isEmpty else { throw StorageError.invalidDocument } }
        if target == .webDAV { _ = try Self.webDAVDirectory(endpoint) }
    }

    /// Wait after `failures` consecutive failed/unreachable attempts:
    /// 15 min, 1 h, 4 h, then at most 12 h. A success resets the series.
    public static func retryDelay(afterFailures failures: Int) -> TimeInterval {
        switch failures { case ...1: 15 * 60; case 2: 3600; case 3: 4 * 3600; default: 12 * 3600 }
    }
    public func due(at date: Date = Date()) -> Bool {
        guard target != .disabled else { return false }
        if let lastSuccess, (0..<24 * 3600).contains(date.timeIntervalSince(lastSuccess)) { return false }
        guard let next = nextAttempt else { return true }
        // A clock set back must not block backups until it catches up again.
        return date >= next || lastAttempt.map { $0 > date } == true
    }
    /// Earliest automatic retry after the last attempt; nil when none ran yet.
    public var nextAttempt: Date? {
        lastAttempt.map { $0.addingTimeInterval(Self.retryDelay(afterFailures: consecutiveFailures ?? 0)) }
    }
    public mutating func recordFailure(_ outcome: ExternalBackupOutcome, reason: String, at date: Date = Date()) {
        lastAttempt = date; lastOutcome = outcome == .succeeded ? .failed : outcome
        lastFailureReason = String(reason.prefix(300)); consecutiveFailures = (consecutiveFailures ?? 0) + 1
    }
    /// A success with `warning` still counts fully (resets the backoff).
    public mutating func recordSuccess(at date: Date = Date(), warning: String? = nil) {
        lastAttempt = date; lastSuccess = date; lastOutcome = .succeeded; lastFailureReason = nil; consecutiveFailures = nil
        lastWarning = warning.map { String($0.prefix(300)) }
    }
    /// A new target starts without history; older files at the old target stay.
    public mutating func startTarget(_ target: ExternalBackupTarget, at date: Date = Date()) {
        self.target = target; configuredAt = date
        lastAttempt = nil; lastSuccess = nil; lastOutcome = nil; lastFailureReason = nil; consecutiveFailures = nil; lastWarning = nil
    }
    /// Warning text for notebooks archived in an older readable state (nil if none).
    public static func olderStateWarning(_ titles: [String]) -> String? {
        guard !titles.isEmpty else { return nil }
        let names = titles.prefix(3).map { "„\($0.prefix(40))“" }.joined(separator: ", ") + (titles.count > 3 ? " und \(titles.count - 3) weitere" : "")
        return "\(names): älterer lesbarer Stand gesichert, neuere Revision beschädigt"
    }

    public var prefix: String { "noty-auto-\(series.uuidString.lowercased())-" }
    public func filename(at date: Date = Date()) -> String {
        prefix + String(Int64(date.timeIntervalSince1970)) + "-" + UUID().uuidString.lowercased() + ".notylibrary"
    }
    public func timestamp(_ filename: String) -> TimeInterval? {
        guard filename.hasPrefix(prefix), filename.hasSuffix(".notylibrary") else { return nil }
        let body = String(filename.dropFirst(prefix.count).dropLast(12))
        guard let dash = body.firstIndex(of: "-"), let rawTime = Int64(body[..<dash]), (1...4_102_444_800).contains(rawTime),
              UUID(uuidString: String(body[body.index(after: dash)...])) != nil else { return nil }
        return TimeInterval(rawTime)
    }
    /// Own unfinished upload/copy (`<archive>.partial`) or quarantined failed
    /// read-back (`<archive>.failed`); never counted as a backup.
    public func temporaryTimestamp(_ filename: String) -> TimeInterval? {
        for suffix in [".partial", ".failed"] where filename.hasSuffix(suffix) {
            return timestamp(String(filename.dropLast(suffix.count)))
        }
        return nil
    }
    /// Own temporaries whose embedded creation time is more than a day old.
    public func staleTemporaries(_ names: [String], now: Date = Date()) -> [String] {
        Set(names).filter { name in temporaryTimestamp(name).map { now.timeIntervalSince1970 - $0 > 24 * 3600 } ?? false }.sorted()
    }
    /// Only archives from this series; newest verified filename is always retained.
    public func obsolete(_ names: [String], verified: String) -> [String] {
        guard timestamp(verified) != nil else { return [] }
        let sorted = Set(names).filter { timestamp($0) != nil && $0 != verified }
            .sorted { timestamp($0)! > timestamp($1)! }
        return Array(sorted.dropFirst(keep - 1))
    }
    public static func webDAVDirectory(_ string: String) throws -> URL {
        guard let url = URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme?.lowercased() == "https", url.host != nil, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil else { throw StorageError.invalidDocument }
        return url.hasDirectoryPath ? url : url.appendingPathComponent("", isDirectory: true)
    }
}

/// What the library badge and Settings show. A merely postponed attempt is
/// never recorded, so it can never appear as a failure.
public enum ExternalBackupHealth: Equatable, Sendable {
    case notConfigured, folderUnreachable, unreachable(String), failed(String), firstPending
    /// More than three days without a successful backup (or since setup).
    case stale(Date?)
    /// Successful, but with a warning (e.g. an older readable notebook state).
    case warning(Date, String)
    case ok(Date)

    public static let overdueAfter: TimeInterval = 3 * 24 * 3600

    public init(_ policy: ExternalBackupPolicy, folderUnreachable: Bool, running: Bool, now: Date = Date()) {
        if policy.target == .disabled { self = .notConfigured; return }
        if folderUnreachable { self = .folderUnreachable; return }
        if let since = policy.lastSuccess ?? policy.configuredAt, now.timeIntervalSince(since) > Self.overdueAfter {
            self = .stale(policy.lastSuccess); return
        }
        // Policies of older builds have no outcome: their attempt time alone proves nothing.
        let failing = policy.lastAttempt.map { attempt in policy.lastSuccess.map { attempt > $0 } ?? true } ?? false
        if failing, !running, let outcome = policy.lastOutcome, outcome != .succeeded {
            let reason = policy.lastFailureReason ?? "unbekannter Fehler"
            self = outcome == .unreachable ? .unreachable(reason) : .failed(reason); return
        }
        guard let success = policy.lastSuccess else { self = .firstPending; return }
        if let warning = policy.lastWarning { self = .warning(success, warning); return }
        self = .ok(success)
    }

    /// Configured and working (or waiting for its first run).
    public var isSetUp: Bool {
        switch self { case .ok, .firstPending, .warning: true; default: false }
    }
}
