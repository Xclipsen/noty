import Foundation

// Growing answers in the AI panel: incremental Markdown, safe cut points for
// the reveal, the reveal pace and when the view follows. Display state only,
// nothing here is part of a notebook, revision or backup.

// MARK: Incremental Markdown

/// Blocks of one growing answer. Every block that ends before the last idle
/// point of the parser (`AIMarkdownLineParser.isIdle`, only after a complete
/// line) is final and rendered once; only the open rest is parsed and rendered
/// again with each update. Block `index` is the position in the answer and
/// stays the same when an open block becomes final.
public struct AIMarkdownStream<Block> {
    /// Text up to the last idle point; its blocks are `closed`.
    private var closedText = ""
    public private(set) var closed: [Block] = []
    private var last: (text: String, final: Bool, blocks: [Block])?
    /// Calls of `render`, for tests and measurement.
    public private(set) var renders = 0

    public init() {}

    /// `final`: the text is complete, nothing is open any more. `render` gets
    /// the block, its index in the answer and whether it is still open.
    public mutating func update(_ text: String, final: Bool, render: (AIMarkdownBlock, Int, Bool) -> Block) -> [Block] {
        if let last, last.text == text, last.final == final { return last.blocks }
        if !text.hasPrefix(closedText) { closedText = ""; closed = [] }
        let start = text.utf8.index(text.startIndex, offsetBy: closedText.utf8.count)
        // The last piece has no line break after it yet and may still change.
        let lines = text[start...].split(separator: "\n", omittingEmptySubsequences: false).dropLast()
        var parser = AIMarkdownLineParser()
        var idleEnd = start, idleBlocks = 0
        for line in lines {
            parser.feed(line)
            if parser.isIdle { idleEnd = text.index(after: line.endIndex); idleBlocks = parser.blocks.count }
        }
        for block in parser.blocks.prefix(idleBlocks) {
            closed.append(render(block, closed.count, false)); renders += 1
        }
        closedText = String(text[..<idleEnd])
        var rest = AIMarkdownLineParser()
        for line in text[idleEnd...].split(separator: "\n", omittingEmptySubsequences: false) { rest.feed(line) }
        var blocks = closed
        for block in rest.finish() {
            blocks.append(render(block, blocks.count, !final)); renders += 1
        }
        last = (text, final, blocks)
        return blocks
    }
}

/// Rendered answers by message: finished answers once, growing ones through
/// their `AIMarkdownStream`. Another set of citable pages renders anew.
public struct AIAnswerRenderCache<Block> {
    private struct Entry {
        var pages: Set<Int>
        var stream = AIMarkdownStream<Block>()
    }
    private var entries: [String: Entry] = [:]
    private var order: [String] = []
    private let capacity: Int

    public init(capacity: Int = 80) { self.capacity = capacity }

    public mutating func blocks(id: String, text: String, pages: Set<Int>, final: Bool,
                                render: (AIMarkdownBlock, Int, Bool) -> Block) -> [Block] {
        var entry = entries.removeValue(forKey: id) ?? Entry(pages: pages)
        if entry.pages != pages { entry = Entry(pages: pages) }
        let blocks = entry.stream.update(text, final: final, render: render)
        if !order.contains(id) { order.append(id) }
        entries[id] = entry
        while order.count > capacity { entries[order.removeFirst()] = nil }
        return blocks
    }

    /// Render calls so far for `id`, for tests.
    public func renders(id: String) -> Int { entries[id]?.stream.renders ?? 0 }
}

extension AIMarkdownBlocks {
    /// Inline text of a block that is still being written: a bold, underline
    /// or code span opened but not yet closed is closed for display, so the
    /// words appear in their final style instead of as `**`. An opener with
    /// nothing after it is left out. Single `*` stays as it is (`2 * 3`).
    public static func closingOpenInline(_ text: String) -> String {
        struct Open { var index: String.Index; var closer: String }
        var opens: [Open] = []
        var inCode: String.Index?
        var bold: String.Index?, under: String.Index?
        /// A pair of marks at the very end, nothing written after it yet.
        var dangling: String.Index?
        var i = text.startIndex
        func isSpace(_ index: String.Index?) -> Bool { index.map { text[$0].isWhitespace } ?? true }
        while i < text.endIndex {
            let c = text[i]
            let next = text.index(after: i)
            if c == "\\" { i = next < text.endIndex ? text.index(after: next) : next; continue }
            if c == "`" { inCode = inCode == nil ? i : nil; i = next; continue }
            if inCode == nil, c == "*" || c == "_", next < text.endIndex, text[next] == c {
                let after = text.index(after: next)
                let before = i > text.startIndex ? text.index(before: i) : nil
                var open = c == "*" ? bold : under
                if open != nil, !isSpace(before) { open = nil }
                else if open == nil, after < text.endIndex, !isSpace(after) { open = i }
                else if open == nil, text[after...].allSatisfy(\.isWhitespace) { dangling = dangling ?? i }
                if c == "*" { bold = open } else { under = open }
                i = after; continue
            }
            i = next
        }
        if let inCode { opens.append(Open(index: inCode, closer: "`")) }
        if let bold { opens.append(Open(index: bold, closer: "**")) }
        if let under { opens.append(Open(index: under, closer: "__")) }
        guard !opens.isEmpty || dangling != nil else { return text }
        opens.sort { $0.index < $1.index }
        var end = dangling ?? text.endIndex
        opens.removeAll { $0.index >= end }
        while let last = opens.last {
            let marker = text.index(last.index, offsetBy: last.closer.count, limitedBy: end) ?? end
            guard text[marker..<end].allSatisfy(\.isWhitespace) else { break }
            end = last.index; opens.removeLast()
        }
        var result = String(text[..<end])
        while result.last?.isWhitespace == true { result.removeLast() }
        // Innermost first: the span opened last closes first.
        return result + opens.reversed().map(\.closer).joined()
    }
}

// MARK: Reveal

/// Where a growing answer may be cut for display: after a whole word, never
/// inside a grapheme (cuts count `Character`s), never in the middle of a line
/// that is only Markdown marks so far (`##`, `-`, `1.`, a fence or table row,
/// which would show as text first and then turn into a block), never inside a
/// citation or link that is not closed yet.
public enum AIRevealCut {
    static let markers: Set<Character> = ["#", "-", "*", "+", ">", "=", "_", "`", "~", "|"]
    /// A bracket open longer than this is text, not a citation.
    static let bracketReach = 64

    /// Largest safe end in `0...limit`, at least `floor`. `complete`: the
    /// text is whole, its end is safe.
    public static func safeEnd(_ text: [Character], upTo limit: Int, complete: Bool, floor: Int = 0) -> Int {
        let count = text.count
        var end = min(max(limit, 0), count)
        if complete, end == count { return count }
        while end > floor {
            // After a whole word (the next character is known to be a space) or at a line start.
            let atWord = (end < count && text[end].isWhitespace) || text[end - 1] == "\n"
            if !atWord { end -= 1; continue }
            if let back = holdBack(text, end: end), back < end { end = back; continue }
            return end
        }
        return min(floor, count)
    }

    /// Where the open line before `end` must be cut instead, if anywhere.
    private static func holdBack(_ text: [Character], end: Int) -> Int? {
        var start = end
        while start > 0, text[start - 1] != "\n" { start -= 1 }
        let lineComplete = end < text.count && text[end] == "\n"
        guard !lineComplete else { return nil }
        let line = text[start..<end]
        let content = line.drop { $0 == " " || $0 == "\t" }
        guard let first = content.first else { return nil }
        if first == "|" { return start }
        if content.starts(with: ["`", "`", "`"]) || content.starts(with: ["~", "~", "~"]) { return start }
        let marks = content.filter { !$0.isWhitespace }
        if marks.allSatisfy(markers.contains) { return start }
        let digits = marks.prefix { $0.isASCII && $0.isNumber }
        if !digits.isEmpty, digits.count <= 3, marks.count == digits.count + 1, marks.last == "." || marks.last == ")" { return start }
        if let open = line.lastIndex(of: "[") {
            let after = line[(open + 1)...]
            if let close = after.firstIndex(of: "]") {
                // `[text](` without `)` yet.
                if close + 1 < end, text[close + 1] == "(", !text[(close + 1)..<end].contains(")") { return open }
            } else if end - open <= bracketReach {
                return open
            }
        }
        return nil
    }
}

/// The pace of a growing answer: the shown text follows the received text at
/// an even speed, word by word, faster the larger the backlog, and nothing
/// waits longer than `maxLag` once it can be shown. Times in seconds.
public struct AIRevealPacer: Sendable {
    /// Backlog in seconds the speed aims at.
    public static let targetLag = 0.45
    public static let maxLag = 0.9
    /// Characters per second at least, about eight words.
    public static let minimumRate = 50.0
    /// More text than this on first sight was written before: shown at once.
    public static let revealedStart = 160

    private struct Arrival: Sendable { var time: Double; var count: Int }
    public private(set) var characters: [Character] = []
    private var text = ""
    public private(set) var shown = 0
    private var position = 0.0
    private var arrivals: [Arrival] = []
    private var lastTime: Double

    public init(text: String, at time: Double, revealExisting: Bool? = nil) {
        lastTime = time
        receive(text, at: time)
        if !(revealExisting ?? (characters.count <= Self.revealedStart)) {
            shown = AIRevealCut.safeEnd(characters, upTo: characters.count, complete: false)
            position = Double(shown); arrivals = []
        }
    }

    /// The whole text received so far.
    public mutating func receive(_ next: String, at time: Double) {
        guard next != text else { return }
        if next.hasPrefix(text) {
            characters.append(contentsOf: next.dropFirst(characters.count))
        } else {
            // Replaced (the final text of an item differs): keep what still matches.
            let fresh = Array(next)
            let common = zip(characters, fresh).prefix { $0 == $1 }.count
            characters = fresh
            shown = AIRevealCut.safeEnd(characters, upTo: min(shown, common), complete: false)
            position = Double(shown); arrivals = []
        }
        text = next
        arrivals.append(Arrival(time: time, count: characters.count))
    }

    /// Moves on to `time`; `complete` shows everything at once.
    @discardableResult
    public mutating func advance(to time: Double, complete: Bool) -> Int {
        let dt = min(max(0, time - lastTime), 0.1)
        lastTime = time
        if complete {
            shown = characters.count; position = Double(shown); arrivals = []
            return shown
        }
        let limit = AIRevealCut.safeEnd(characters, upTo: characters.count, complete: false, floor: shown)
        let backlog = Double(limit) - position
        if backlog > 0 {
            // Fast enough that every arrival is shown by its deadline, without a jump at the end.
            var rate = max(Self.minimumRate, backlog / Self.targetLag)
            for arrival in arrivals {
                let missing = Double(min(arrival.count, limit)) - position
                if missing > 0 { rate = max(rate, missing / max(arrival.time + Self.maxLag - time, 1.0 / 30)) }
            }
            position = min(Double(limit), position + rate * dt)
        }
        var due = 0
        while let first = arrivals.first, first.time <= time - Self.maxLag || Double(first.count) <= position {
            if first.time <= time - Self.maxLag { due = first.count }
            arrivals.removeFirst()
        }
        position = max(position, Double(min(due, limit)))
        shown = max(shown, AIRevealCut.safeEnd(characters, upTo: Int(position), complete: false, floor: shown))
        return shown
    }

    /// Without animation (Reduce Motion): everything that can be shown safely, at once.
    @discardableResult
    public mutating func revealAll(at time: Double) -> Int {
        lastTime = time
        shown = AIRevealCut.safeEnd(characters, upTo: characters.count, complete: false, floor: shown)
        position = max(position, Double(shown)); arrivals = []
        return shown
    }

    /// Nothing more to show until more text arrives.
    public var caughtUp: Bool {
        AIRevealCut.safeEnd(characters, upTo: characters.count, complete: false, floor: shown) <= shown
    }
    /// Characters received but not shown yet.
    public var backlog: Int { characters.count - shown }
    public var shownText: String { String(characters[..<shown]) }
}

// MARK: Following the answer

/// Whether the conversation follows a growing answer. Only the user's own
/// scrolling changes it, never growing content or the panel's own scrolling:
/// scrolled up, it stops and the reading position stays; it follows again
/// once the user scrolls back to the very bottom, taps „Nach unten“ or sends
/// a question, and when another chat opens. Distances in points.
public struct AIScrollFollow: Equatable, Sendable {
    /// Scrolled up further than this, the view stays where it is.
    public static let leaveDistance = 16.0
    /// Back this close to the bottom, it follows again.
    public static let returnDistance = 6.0

    public private(set) var following = true
    public init() {}

    /// A scroll by the user's finger or its deceleration; `distance` is what
    /// lies below the visible area.
    public mutating func userScrolled(distanceFromBottom distance: Double) {
        if following, distance > Self.leaveDistance { following = false }
        else if !following, distance <= Self.returnDistance { following = true }
    }
    /// „Nach unten“, an own question or another chat.
    public mutating func follow() { following = true }
    /// Whether the panel moves the view after the content changed.
    public var followsGrowth: Bool { following }
    public func showsJumpButton(distanceFromBottom distance: Double) -> Bool {
        !following && distance > Self.returnDistance
    }
}
