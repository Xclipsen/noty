import Foundation

/// Minimal line logger to stderr (journald). Callers pass only categories,
/// counts, HTTP status codes and shortened device ids: never device tokens,
/// Untis access data, device secrets or the text of timetable changes.
public enum Log {
    public static func info(_ message: String) { write("info", message) }
    public static func warn(_ message: String) { write("warn", message) }
    public static func error(_ message: String) { write("error", message) }

    /// First 8 characters of a device id (enough to tell devices apart in logs).
    public static func device(_ id: String) -> String { String(id.prefix(8)) }

    private static let lock = NSLock()
    private static func write(_ level: String, _ message: String) {
        let line = "[\(level)] " + message.replacingOccurrences(of: "\n", with: " ") + "\n"
        lock.lock(); defer { lock.unlock() }
        FileHandle.standardError.write(Data(line.utf8))
    }
}
