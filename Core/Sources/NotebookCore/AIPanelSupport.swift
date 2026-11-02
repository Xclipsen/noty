import Foundation

// Display state and local bookkeeping of the AI panel. Nothing here is part of
// a notebook, revision or backup.

/// Which page a citation of an answer means, noted when the question goes out:
/// numbers shift when pages move, page IDs do not. The oldest entries go first.
public struct AICitationLedger: Codable, Equatable, Sendable {
    public static let defaultCapacity = 200
    private struct Entry: Codable, Equatable, Sendable {
        var document: UUID
        var pages: [Int: UUID]
    }
    private var entries: [String: Entry] = [:]
    private var order: [String] = []
    private var capacity = AICitationLedger.defaultCapacity

    public init(capacity: Int = defaultCapacity) { self.capacity = capacity }

    public mutating func record(requestID: String, document: UUID, pages: [Int: UUID]) {
        order.removeAll { $0 == requestID }
        entries[requestID] = nil
        guard !pages.isEmpty else { return }
        entries[requestID] = Entry(document: document, pages: pages)
        order.append(requestID)
        while order.count > capacity { entries[order.removeFirst()] = nil }
    }

    /// Empty for an unknown request or another notebook: its citations stay text.
    public func pages(requestID: String, document: UUID) -> [Int: UUID] {
        guard let entry = entries[requestID], entry.document == document else { return [:] }
        return entry.pages
    }
}

/// `onAppear` of a new panel can run before `onDisappear` of the old one.
public struct AIPanelPresence: Equatable, Sendable {
    private var count = 0
    public init() {}
    public var visible: Bool { count > 0 }
    public mutating func appeared() { count += 1 }
    public mutating func disappeared() { count = max(0, count - 1) }
}

/// Parsed answers by message. A growing answer is parsed anew at most once per
/// `interval`; until then the new text comes back as a raw tail.
public struct AIRenderCache<Value> {
    private struct Entry {
        var text: String
        var pages: Set<Int>
        var value: Value
        var date: Date
    }
    private var entries: [String: Entry] = [:]
    private var order: [String] = []
    private let capacity: Int
    private let interval: TimeInterval

    public init(capacity: Int = 80, interval: TimeInterval = 1.5) {
        self.capacity = capacity; self.interval = interval
    }

    public mutating func value(id: String, text: String, pages: Set<Int>, growing: Bool, now: Date = Date(),
                               render: (String) -> Value) -> (value: Value, tail: Substring) {
        if let entry = entries[id], entry.pages == pages {
            if entry.text == text { return (entry.value, text[text.endIndex...]) }
            if growing, now.timeIntervalSince(entry.date) < interval, text.hasPrefix(entry.text) {
                return (entry.value, text.dropFirst(entry.text.count))
            }
        }
        let value = render(text)
        if entries[id] == nil { order.append(id) }
        entries[id] = Entry(text: text, pages: pages, value: value, date: now)
        while order.count > capacity { entries[order.removeFirst()] = nil }
        return (value, text[text.endIndex...])
    }
}

/// Where the floating panel goes: over the view the user is not working in,
/// beside the law window. `active` and `inactive` are the two views of a
/// split, `law` what the law window takes up (all in workspace points).
public enum AIPanelPlacement {
    public static let width = 380.0
    public static let minimumWidth = 300.0
    public static let minimumHeight = 240.0
    /// Over a view above or below the other one: broad, for reading.
    public static let stackedWidth = 640.0
    public static let margin = 10.0
    public static let gap = 6.0
    /// Top bar of the law window: its grip stays free in any case.
    public static let lawGrip = 44.0

    public static func frame(area: PageRect, active: PageRect?, inactive: PageRect?, law: PageRect?, flipped: Bool) -> PageRect {
        let slot = (flipped ? active : inactive) ?? area
        let wanted = wantedFrame(area: area, slot: slot, other: flipped ? inactive : active, flipped: flipped)
        guard let law, overlap(wanted, law) != nil else { return wanted }
        guard let free = freeRoom(area: area, law: law, slot: slot) else {
            let top = max(wanted.y, law.y + lawGrip)
            return PageRect(x: wanted.x, y: top, width: wanted.width, height: max(0, wanted.y + wanted.height - top))
        }
        return moved(wanted, into: free, slot: slot)
    }

    private static func wantedFrame(area: PageRect, slot: PageRect, other: PageRect?, flipped: Bool) -> PageRect {
        let room = inset(area)
        let stacked = other.map { $0.x == slot.x } ?? false
        let wantedWidth = stacked ? stackedWidth : width
        let frameWidth = min(room.width, max(min(wantedWidth, slot.width - 2 * margin), minimumWidth))
        let frameHeight = min(room.height, max(slot.height - 2 * margin, minimumHeight))
        let onLeft = other.map { slot.x < $0.x } ?? flipped
        let x = !stacked && onLeft ? slot.x + margin : slot.x + slot.width - margin - frameWidth
        let y = slot.y + margin
        return PageRect(x: clamp(x, room.x, room.x + room.width - frameWidth), y: clamp(y, room.y, room.y + room.height - frameHeight),
                        width: frameWidth, height: frameHeight)
    }

    /// The part of the area beside the law window that lies most in `slot`.
    private static func freeRoom(area: PageRect, law: PageRect, slot: PageRect) -> PageRect? {
        let room = inset(area)
        let right = room.x + room.width, bottom = room.y + room.height
        let lawRight = law.x + law.width + gap, lawBottom = law.y + law.height + gap
        let parts = [
            PageRect(x: room.x, y: room.y, width: law.x - gap - room.x, height: room.height),
            PageRect(x: lawRight, y: room.y, width: right - lawRight, height: room.height),
            PageRect(x: room.x, y: room.y, width: room.width, height: law.y - gap - room.y),
            PageRect(x: room.x, y: lawBottom, width: room.width, height: bottom - lawBottom),
        ]
        func share(_ part: PageRect) -> Double { overlap(part, slot).map { $0.width * $0.height } ?? 0 }
        return parts.filter { $0.width >= minimumWidth && $0.height >= minimumHeight }.max { share($0) < share($1) }
    }

    /// No wider or taller than it takes to stay in `slot`, as far as the
    /// panel's minimum size allows: the active view stays uncovered.
    private static func moved(_ wanted: PageRect, into free: PageRect, slot: PageRect) -> PageRect {
        let shared = overlap(free, slot)
        let fitWidth = min(wanted.width, free.width, max(minimumWidth, shared?.width ?? 0))
        let fitHeight = min(wanted.height, free.height, max(minimumHeight, shared?.height ?? 0))
        return PageRect(x: clamp(wanted.x, free.x, free.x + free.width - fitWidth),
                        y: clamp(wanted.y, free.y, free.y + free.height - fitHeight), width: fitWidth, height: fitHeight)
    }

    private static func inset(_ area: PageRect) -> PageRect {
        PageRect(x: area.x + margin, y: area.y + margin, width: max(0, area.width - 2 * margin), height: max(0, area.height - 2 * margin))
    }

    private static func overlap(_ a: PageRect, _ b: PageRect) -> PageRect? {
        let left = max(a.x, b.x), right = min(a.x + a.width, b.x + b.width)
        let top = max(a.y, b.y), bottom = min(a.y + a.height, b.y + b.height)
        return left < right && top < bottom ? PageRect(x: left, y: top, width: right - left, height: bottom - top) : nil
    }

    private static func clamp(_ value: Double, _ low: Double, _ high: Double) -> Double { max(low, min(value, max(low, high))) }
}
