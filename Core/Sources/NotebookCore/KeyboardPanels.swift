import Foundation

/// Cursor of a list or grid with keys (sidebar, hits): moves, stops at the ends.
public enum KeyList {
    /// The index after a move; nil on an empty list. Nothing chosen yet: every
    /// direction starts at the first entry.
    public static func moved(_ index: Int?, dx: Int = 0, dy: Int = 0, columns: Int = 1, count: Int) -> Int? {
        guard count > 0 else { return nil }
        guard let index else { return 0 }
        return min(max(0, index + dx + dy * max(1, columns)), count - 1)
    }
    /// A list that got shorter under the cursor.
    public static func clamped(_ index: Int?, count: Int) -> Int? {
        guard let index, count > 0 else { return nil }
        return min(index, count - 1)
    }
}

/// The options of a dialog in reading order, with the wandering cursor of
/// `Tab` and `j`/`k`. A dialog is built by SwiftUI, so its order comes from
/// where the controls stand, not from the order they appeared in.
public enum KeyOptionRing {
    public struct Place<ID: Hashable> {
        public let id: ID
        public let x: Double
        public let y: Double
        public let enabled: Bool
        public init(id: ID, x: Double, y: Double, enabled: Bool = true) { self.id = id; self.x = x; self.y = y; self.enabled = enabled }
    }
    /// Controls this close in height stand in one row, left to right.
    public static let rowTolerance = 14.0

    /// Enabled options, top to bottom and left to right.
    public static func order<ID>(_ places: [Place<ID>]) -> [ID] {
        var rows: [[Place<ID>]] = []
        for place in places.filter(\.enabled).sorted(by: { $0.y < $1.y }) {
            if let first = rows.last?.first, place.y - first.y <= rowTolerance { rows[rows.count - 1].append(place) }
            else { rows.append([place]) }
        }
        return rows.flatMap { $0.sorted { $0.x < $1.x } }.map(\.id)
    }
    /// The next option. Without `wraps` nil past the ends: a lazy list may
    /// have to scroll first, its next row does not exist yet.
    public static func step<ID: Equatable>(from current: ID?, by delta: Int, in order: [ID], wraps: Bool = true) -> ID? {
        guard !order.isEmpty else { return nil }
        guard let current, let index = order.firstIndex(of: current) else { return delta < 0 ? order.last : order.first }
        let target = index + delta
        if order.indices.contains(target) { return order[target] }
        guard wraps else { return nil }
        return order[((target % order.count) + order.count) % order.count]
    }
}

/// A choice with `h`/`l` or the space bar: goes round at the ends.
public enum KeyChoice {
    public static func stepped<Value: Equatable>(_ value: Value, by delta: Int, in values: [Value]) -> Value {
        guard !values.isEmpty else { return value }
        guard let index = values.firstIndex(of: value) else { return values[0] }
        return values[((index + delta) % values.count + values.count) % values.count]
    }
    /// A slider's next value, on its grid and inside its range.
    public static func stepped(_ value: Double, by delta: Int, in range: ClosedRange<Double>, step: Double) -> Double {
        let next = ((value + Double(delta) * step) / step).rounded() * step
        return min(range.upperBound, max(range.lowerBound, next))
    }
    /// Evenly spread stops of a width slider for the palette, on half points.
    public static func widths(in range: ClosedRange<Double>, count: Int = 6) -> [Double] {
        guard count > 1 else { return [range.lowerBound] }
        let span = (range.upperBound - range.lowerBound) / Double(count - 1)
        let values = (0..<count).map { ((range.lowerBound + span * Double($0)) * 2).rounded() / 2 }
        return values.reduce(into: [Double]()) { if $0.last != $1 { $0.append($1) } }
    }
}

/// Cursor of the colour and stroke panel: rows of different lengths.
public struct KeyChoiceCursor: Equatable, Sendable {
    public private(set) var row: Int
    public private(set) var column: Int
    public let rows: [Int]
    public init(rows: [Int], row: Int = 0, column: Int = 0) {
        self.rows = rows
        let start = rows.indices.contains(row) ? row : 0
        self.row = start
        self.column = rows.indices.contains(start) ? min(max(0, column), max(0, rows[start] - 1)) : 0
    }
    public mutating func move(dx: Int, dy: Int) {
        guard !rows.isEmpty else { return }
        row = ((row + dy) % rows.count + rows.count) % rows.count
        column = min(max(0, column + dx), max(0, rows[row] - 1))
    }
    /// `1`–`9` in the current row; false when it has no such entry.
    public mutating func pick(_ number: Int) -> Bool {
        guard rows.indices.contains(row), number >= 1, number <= rows[row] else { return false }
        column = number - 1
        return true
    }
}

/// A line of text fed by key tokens: the search field of a sheet, a title, the
/// paragraph of the law reader. The responder of the router keeps the keys, so
/// nothing has to come back from a text field; what a dialog shows is its own
/// field, filled from here. As in the input line of `/`: no dead keys.
public enum KeyInputLine {
    public enum Outcome: Equatable, Sendable {
        case text(String)
        case submit
        case cancel
        /// Leave the line for the next or previous entry.
        case step(Int)
        case ignored
    }
    public static func apply(_ token: String, to text: String) -> Outcome {
        switch token {
        case "<Esc>": return .cancel
        case "<CR>": return .submit
        case "<BS>": return text.isEmpty ? .ignored : .text(String(text.dropLast()))
        case "<Space>", "<S-Space>": return .text(text + " ")
        case "<Tab>", "<Down>", "^n": return .step(1)
        case "<S-Tab>", "<Up>", "^p": return .step(-1)
        default:
            // A control key or a named key is no text.
            guard token.count == 1, token.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { return .ignored }
            return .text(text + token)
        }
    }
    /// Pasted text stays one line.
    public static func pasted(_ value: String, to text: String) -> String {
        text + value.replacingOccurrences(of: "\r\n", with: " ").replacingOccurrences(of: "\n", with: " ")
    }
}

/// Parts of the app with keys of their own, in the order they opened. The last
/// one has the keys; closing any of them leaves the rest as they were (a pushed
/// settings page disappears after the next one appeared, and a sheet can go
/// while a question stands above it).
public struct KeyPanelStack<Panel: AnyObject> {
    public private(set) var panels: [Panel] = []
    public init() {}
    public var active: Panel? { panels.last }
    public var isEmpty: Bool { panels.isEmpty }
    public mutating func enter(_ panel: Panel) {
        guard !panels.contains(where: { $0 === panel }) else { return }
        panels.append(panel)
    }
    /// True when it was open.
    @discardableResult
    public mutating func leave(_ panel: Panel) -> Bool {
        guard let index = panels.firstIndex(where: { $0 === panel }) else { return false }
        panels.remove(at: index)
        return true
    }
    public mutating func removeAll(where condition: (Panel) -> Bool) { panels.removeAll(where: condition) }
    /// The newest panel that has a responder of its own: a question over a
    /// sheet takes its keys from the sheet's responder.
    public func last(where condition: (Panel) -> Bool) -> Panel? { panels.last(where: condition) }
}

/// Who has to hold the first responder for keys to arrive. The rule behind
/// „after every closing keys work again“, one place for all of them.
public enum KeyFocusTarget: Equatable, Sendable {
    /// The responder inside a sheet.
    case panelHost
    case heldText
    case page
    case library
    case none

    public static func resolve(hasPanelHost: Bool, inEditor: Bool, heldText: Bool, editorActive: Bool, libraryActive: Bool) -> KeyFocusTarget {
        if hasPanelHost { return .panelHost }
        if inEditor {
            if heldText { return .heldText }
            return editorActive ? .page : .none
        }
        return libraryActive ? .library : .none
    }
}
