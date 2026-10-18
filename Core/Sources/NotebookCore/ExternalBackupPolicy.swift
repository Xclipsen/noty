import Foundation

public enum ExternalBackupTarget: String, Codable, Sendable { case disabled, folder, webDAV }
public struct ExternalBackupPolicy: Codable, Equatable, Sendable {
    public var version = 1
    public var series = UUID()
    public var target: ExternalBackupTarget = .disabled
    public var keep = 7
    public var folderBookmark: Data?
    public var endpoint = ""
    public var lastAttempt: Date?
    public var lastSuccess: Date?
    public init() {}
    public func validate() throws {
        guard version == 1, (3...30).contains(keep) else { throw StorageError.invalidDocument }
        if target == .folder { guard let folderBookmark, !folderBookmark.isEmpty else { throw StorageError.invalidDocument } }
        if target == .webDAV { _ = try Self.webDAVDirectory(endpoint) }
    }
    public func due(at date: Date = Date()) -> Bool {
        guard target != .disabled else { return false }
        if let lastSuccess, date.timeIntervalSince(lastSuccess) < 24 * 3600 { return false }
        // Retry failed/missing targets during active use without hammering the server.
        return lastAttempt.map { date.timeIntervalSince($0) >= 15 * 60 } ?? true
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
