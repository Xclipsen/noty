import Foundation

/// Key-downs by hardware key and press time, never by `UIPress` object: UIKit
/// may reuse that object for the next press of a key. A press the app does not
/// use walks up the responder chain and reaches several views; only that second
/// delivery of one event is refused. A key-up forgets the key, so a press time
/// that stayed the same cannot block the next press; a lost key-up (the focus
/// moved while the key was down) cannot either, the next press has a new time.
public struct KeyPressGate: Sendable {
    private var times: [Int: Double] = [:]
    private var swallowed = Set<Int>()
    public init() {}

    /// False for a second delivery of the same key-down.
    public mutating func began(key: Int, time: Double) -> Bool {
        guard times[key] != time else { return false }
        times[key] = time; swallowed.remove(key)
        return true
    }
    /// This press was used: its key-up stays away from the system too.
    public mutating func swallow(key: Int) { swallowed.insert(key) }
    /// True when the key-up belongs to a swallowed press.
    public mutating func ended(key: Int) -> Bool {
        times[key] = nil
        return swallowed.remove(key) != nil
    }
}

/// One press, whichever way UIKit brings it. Esc and Tab can arrive through
/// `pressesBegan` or as a key command, and which one (or both) is UIKit's
/// choice: nothing ties the two together, a key command has no press time. So
/// a key the one way used is refused to the other way for a moment, once. Two
/// presses that take the same way both count, a held key's repeats too.
public struct KeyDeliveryLatch: Sendable {
    public enum Route: Sendable { case press, keyCommand }
    /// Longer than one main thread cycle, shorter than two deliberate presses.
    public static let window = 0.12
    private var last: [String: Delivery] = [:]
    private struct Delivery: Sendable { var route: Route; var time: Double }
    public init() {}

    /// False: this is the second way of a press the other way already used.
    public mutating func allows(_ token: String, by route: Route, now: Double) -> Bool {
        guard let delivery = last[token], delivery.route != route else { return true }
        last[token] = nil
        return now - delivery.time >= Self.window
    }
    /// The press did something. An unused one stays free for the other way.
    public mutating func used(_ token: String, by route: Route, now: Double) {
        last[token] = Delivery(route: route, time: now)
    }
}

/// Command palette: every action by name, plus `:w`, `:q`, `:wq`, `:12`.
public enum KeyPalette {
    public enum Direct: Equatable, Sendable { case save, close, page(Int) }
    public static func direct(_ query: String) -> Direct? {
        let value = query.trimmingCharacters(in: .whitespaces).lowercased()
        switch value {
        case "w": return .save
        case "q", "wq", "x": return .close
        default: return Int(value).flatMap { $0 > 0 ? .page($0) : nil }
        }
    }
    /// Only an open document can be saved, closed or paged: in the library
    /// and in a dialog `w` or `12` are search words.
    public static func direct(_ query: String, in context: HelixContext) -> Direct? {
        [.page, .text, .sidebar, .law].contains(context) ? direct(query) : nil
    }
    /// Fuzzy match of `query` in `title`: nil if its letters are not in that
    /// order; a smaller value is better (word starts and neighbours win).
    public static func score(_ query: String, in title: String) -> Int? {
        let needle = Array(query.lowercased().filter { !$0.isWhitespace })
        let haystack = Array(title.lowercased())
        guard !needle.isEmpty else { return 0 }
        var score = 0, position = 0, previous = -2
        for letter in needle {
            guard let found = haystack[position...].firstIndex(of: letter) else { return nil }
            let wordStart = found == 0 || !haystack[found - 1].isLetter
            score += found == previous + 1 ? 0 : wordStart ? 1 : 3 + (found - position)
            previous = found; position = found + 1
        }
        return score
    }
}
