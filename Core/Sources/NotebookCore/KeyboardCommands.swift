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
