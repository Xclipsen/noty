import Foundation

/// A fixed event name. Only a string literal can make one, so no title,
/// text or path can become an event (`DiagnosticPrivacy` checks the
/// characters once more when a report is built).
public struct DiagnosticEvent: Hashable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    public typealias StringLiteralType = StaticString
    public let name: String
    public init(stringLiteral value: StaticString) { name = value.description }
    public var description: String { name }
}

/// A fixed key for a number on an event, likewise literal only.
public struct DiagnosticKey: Hashable, Sendable, ExpressibleByStringLiteral {
    public typealias StringLiteralType = StaticString
    public let name: String
    public init(stringLiteral value: StaticString) { name = value.description }
}

/// One step of the event history: when, which fixed name, which numbers.
public struct DiagnosticBreadcrumb: Codable, Equatable, Sendable {
    /// Milliseconds since 1970.
    public var t: Int64
    /// Event name, e.g. `notebook.open`, `law.window.shown`, `key.cmdL`.
    public var e: String
    /// Numbers only, e.g. `["pages": 34, "ms": 412]`.
    public var v: [String: Int]?

    public init(t: Int64, e: String, v: [String: Int]? = nil) { self.t = t; self.e = e; self.v = v?.isEmpty == true ? nil : v }

    /// „notebook.open pages=34 ms=412“.
    public var text: String {
        let values = (v ?? [:]).sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
        return ([e] + values).joined(separator: " ")
    }
}

/// The last steps of this run: a ring of about 200 breadcrumbs in memory, and
/// the same lines appended to one small file per run, so that a crash report
/// delivered at the next launch still finds what happened before it. Every
/// line is written straight away (one `write` per event, no buffering that a
/// crash would lose); events are coarse (operations, windows, phases), never
/// per touch or per Pencil sample.
public final class DiagnosticJournal: @unchecked Sendable {
    public static let capacity = 200
    /// Above this many lines the file is rewritten with the last `capacity`.
    static let compactAfter = 2_000

    public let launchID: String
    public let fileURL: URL?
    private let lock = NSLock()
    private var ring: [DiagnosticBreadcrumb] = []
    private var next = 0
    private var handle: FileHandle?
    private var linesInFile = 0
    private let now: @Sendable () -> Date

    /// `directory` nil: memory only (tests, diagnosis off).
    public init(launchID: String, directory: URL?, now: @escaping @Sendable () -> Date = Date.init) {
        self.launchID = launchID
        self.now = now
        ring.reserveCapacity(Self.capacity)
        if let directory {
            let url = directory.appendingPathComponent("\(launchID).jsonl")
            fileURL = url
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
            handle = try? FileHandle(forWritingTo: url)
            _ = try? handle?.seekToEnd()
        } else {
            fileURL = nil
        }
    }

    deinit { try? handle?.close() }

    public func record(_ event: DiagnosticEvent, _ values: KeyValuePairs<DiagnosticKey, Int> = [:]) {
        var numbers: [String: Int] = [:]
        for (key, value) in values { numbers[key.name] = value }
        append(DiagnosticBreadcrumb(t: DiagnosticReport.milliseconds(now()), e: event.name, v: numbers))
    }

    /// Callers outside Core pass only names checked by `DiagnosticPrivacy.isSafeName`.
    public func append(_ crumb: DiagnosticBreadcrumb) {
        let line: Data? = (try? JSONEncoder().encode(crumb)).map { $0 + Data([0x0A]) }
        lock.lock(); defer { lock.unlock() }
        if ring.count < Self.capacity { ring.append(crumb) } else { ring[next] = crumb }
        next = (next + 1) % Self.capacity
        guard let handle, let line else { return }
        try? handle.write(contentsOf: line)
        linesInFile += 1
        if linesInFile >= Self.compactAfter { compactLocked() }
    }

    /// Oldest first.
    public func recent() -> [DiagnosticBreadcrumb] {
        lock.lock(); defer { lock.unlock() }
        guard ring.count == Self.capacity else { return ring }
        return Array(ring[next...] + ring[..<next])
    }

    private func compactLocked() {
        guard let fileURL else { return }
        let ordered = ring.count == Self.capacity ? Array(ring[next...] + ring[..<next]) : ring
        var data = Data()
        for crumb in ordered { if let line = try? JSONEncoder().encode(crumb) { data += line + Data([0x0A]) } }
        try? handle?.close()
        try? data.write(to: fileURL, options: .atomic)
        handle = try? FileHandle(forWritingTo: fileURL)
        _ = try? handle?.seekToEnd()
        linesInFile = ordered.count
    }

    /// The last `limit` breadcrumbs of a run's file, optionally up to a time;
    /// unreadable lines (a crash in mid-write) are skipped.
    public static func load(_ url: URL, until: Int64? = nil, limit: Int = capacity) -> [DiagnosticBreadcrumb] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        var crumbs: [DiagnosticBreadcrumb] = []
        for line in data.split(separator: 0x0A) {
            guard let crumb = try? decoder.decode(DiagnosticBreadcrumb.self, from: Data(line)) else { continue }
            if let until, crumb.t > until { continue }
            crumbs.append(crumb)
        }
        return Array(crumbs.suffix(limit))
    }
}

/// The guard between the app and a report: event names, number keys and
/// detail values must consist of a small set of characters and stay short.
/// Anything else is dropped, so even a mistake at a call site cannot put a
/// title or a sentence into a report.
public enum DiagnosticPrivacy {
    /// Event names and keys: ASCII letters, digits, `.`, `_`, `-`; up to 48.
    public static func isSafeName(_ name: String) -> Bool {
        guard !name.isEmpty, name.utf8.count <= 48 else { return false }
        return name.utf8.allSatisfy { byte in
            (byte >= 0x61 && byte <= 0x7A) || (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x30 && byte <= 0x39)
                || byte == 0x2E || byte == 0x5F || byte == 0x2D
        }
    }

    /// Detail values are system codes (`EXC_BAD_ACCESS`, `0x8badf00d`,
    /// `NSCocoaErrorDomain`), numbers and fixed words: printable ASCII without
    /// slashes (no paths), up to 160 characters.
    public static func safeDetail(_ value: String) -> String? {
        guard value.utf8.count <= 160 else { return nil }
        let ok = value.utf8.allSatisfy { byte in byte >= 0x20 && byte < 0x7F && byte != 0x2F && byte != 0x5C && byte != 0x7E }
        return ok ? value : nil
    }

    public static func sanitized(details: [String: String]) -> [String: String] {
        var result: [String: String] = [:]
        for (key, value) in details where isSafeName(key) { result[key] = safeDetail(value) ?? "?" }
        return result
    }

    public static func sanitized(breadcrumbs: [DiagnosticBreadcrumb]) -> [DiagnosticBreadcrumb] {
        breadcrumbs.compactMap { crumb in
            guard isSafeName(crumb.e) else { return nil }
            let values = crumb.v?.filter { isSafeName($0.key) }
            return DiagnosticBreadcrumb(t: crumb.t, e: crumb.e, v: values)
        }
    }

    /// MetricKit JSON without free texts: Objective-C exception messages and
    /// their arguments (`composedMessage`, `formatString`, `arguments`) can
    /// quote app data. Everything else in it is addresses, codes and counters.
    public static func strippedMetricKitJSON(_ data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
        let cleaned = strip(object)
        guard let output = try? JSONSerialization.data(withJSONObject: cleaned, options: [.sortedKeys]) else { return nil }
        return String(data: output, encoding: .utf8)
    }

    static let freeTextKeys: Set<String> = ["composedMessage", "formatString", "arguments", "exceptionReason", "message"]

    private static func strip(_ object: Any) -> Any {
        if let dictionary = object as? [String: Any] {
            var result: [String: Any] = [:]
            for (key, value) in dictionary {
                if freeTextKeys.contains(key) {
                    // Keep the exception's class name, which is a type, not data.
                    if key == "exceptionReason", let reason = value as? [String: Any] {
                        result[key] = ["className": reason["className"] ?? "", "exceptionName": reason["exceptionName"] ?? "",
                                       "exceptionType": reason["exceptionType"] ?? ""]
                    }
                    continue
                }
                result[key] = strip(value)
            }
            return result
        }
        if let array = object as? [Any] { return array.map(strip) }
        if let string = object as? String { return safeDetail(string) ?? "?" }
        return object
    }
}
