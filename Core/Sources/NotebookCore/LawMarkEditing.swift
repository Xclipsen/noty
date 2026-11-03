import Foundation

// Plattformunabhängige Bearbeitung von Gesetzes-Markierungen (docs/LAW-REWORK.md,
// Paket A2; Datenvertrag docs/LAW-MARKS-CONTRACT.md).
//
// Alle Offsets sind UTF-16-Codeeinheiten im kanonischen Text des Paragraphen
// (`LawTextAnchor.canonical(section.text)`). Einträge sind auf dem Server
// unveränderlich: Jede Änderung ist ein Plan aus Löschungen und Neuanlagen mit
// neuen IDs, auch Umfärben und Rückgängig.

/// A text mark of one section in canonical offsets.
public struct LawMarkRange: Hashable, Sendable, Codable {
    public var id: String
    public var sectionId: String
    public var start: Int
    public var end: Int
    /// `#RRGGBB` (local only); nil = default yellow.
    public var color: String?
    /// A PDF mark with a text anchor: shown in the text, but never merged or
    /// split (its rectangles or stroke cannot follow); removed as a whole.
    public var fixed: Bool
    public init(id: String, sectionId: String, start: Int, end: Int, color: String?, fixed: Bool = false) {
        self.id = id; self.sectionId = sectionId; self.start = start; self.end = end; self.color = color; self.fixed = fixed
    }
    public var length: Int { end - start }
    func overlaps(_ lo: Int, _ hi: Int) -> Bool { start < hi && end > lo }
}

/// One user action on the marks of a section.
public enum LawMarkEdit: Hashable, Sendable {
    /// Marks `start..<end`: same colour overlapping or adjacent merges, another
    /// colour gives way (is split), an exact duplicate changes nothing.
    case add(start: Int, end: Int, color: String?)
    /// Removes `start..<end` from every mark it touches (splitting them).
    case remove(start: Int, end: Int)
    /// Removes these marks completely.
    case removeMarks([String])
    /// New colour for these marks (delete + recreate, merging like `add`).
    case recolor([String], color: String?)
    /// „Bereich anpassen“: the mark gets the new bounds, keeping its colour.
    case resize(String, start: Int, end: Int)
}

/// Result of an edit: what to delete and what to create (with new IDs).
/// Creations are meant to be sent before deletions.
public struct LawMarkPlan: Hashable, Sendable {
    public var deletions: [LawMarkRange]
    public var additions: [LawMarkRange]
    public init(deletions: [LawMarkRange] = [], additions: [LawMarkRange] = []) { self.deletions = deletions; self.additions = additions }
    public var isEmpty: Bool { deletions.isEmpty && additions.isEmpty }
    public var deletedIDs: [String] { deletions.map(\.id) }
    /// Undo: the created marks are deleted, the deleted ones come back with
    /// new IDs (deleted IDs stay blocked forever on the server).
    public func inverse(newID: () -> String = LawMarkEditing.newID) -> LawMarkPlan {
        LawMarkPlan(deletions: additions, additions: deletions.map { var r = $0; r.id = newID(); return r })
    }
    /// This plan followed by `next`: marks created here and deleted by `next`
    /// are never written.
    public func then(_ next: LawMarkPlan) -> LawMarkPlan {
        let created = Set(additions.map(\.id))
        let cancelled = Set(next.deletions.map(\.id)).intersection(created)
        return LawMarkPlan(deletions: deletions + next.deletions.filter { !cancelled.contains($0.id) },
                           additions: additions.filter { !cancelled.contains($0.id) } + next.additions)
    }
}

public enum LawMarkError: Error, Equatable, LocalizedError {
    case invalidRange
    case tooLong(Int)
    case unknownMark
    public var errorDescription: String? {
        switch self {
        case .invalidRange: "Diese Auswahl lässt sich nicht eindeutig zuordnen."
        case .tooLong: "Bitte eine kürzere Textstelle markieren (höchstens \(LawMarkEditing.maxLength) Zeichen ohne Leer- und Satzzeichen)."
        case .unknownMark: "Diese Markierung gibt es nicht mehr."
        }
    }
}

public enum LawMarkEditing {
    /// App and website limit one mark to 4000 canonical characters (server: 12 000).
    public static let maxLength = 4000
    /// The website's yellow; nil and the earlier app yellow mean the same.
    public static let defaultColor = "#F3CC37"
    public static func newID() -> String { UUID().uuidString.lowercased() }

    /// Colour identity for merging: case-insensitive, nil and `#FFFF00` = yellow.
    public static func colorKey(_ color: String?) -> String {
        guard let color, color.count == 7, color.hasPrefix("#") else { return defaultColor }
        let upper = color.uppercased()
        return upper == "#FFFF00" ? defaultColor : upper
    }

    /// Plans `edit` for the marks of section `sectionId`. `existing` may hold
    /// marks of other sections; they are never touched. `textLength` is the
    /// canonical length of the section text.
    public static func plan(_ edit: LawMarkEdit, existing: [LawMarkRange], sectionId: String, textLength: Int,
                            newID: () -> String = LawMarkEditing.newID) throws -> LawMarkPlan {
        let marks = existing.filter { $0.sectionId == sectionId }
        switch edit {
        case let .add(start, end, color):
            try validate(start, end, textLength)
            return add(start, end, color, marks: marks, sectionId: sectionId, newID: newID)
        case let .remove(start, end):
            try validate(start, end, textLength, limit: Int.max)
            var plan = LawMarkPlan()
            for mark in marks where mark.overlaps(start, end) {
                plan.deletions.append(mark)
                guard !mark.fixed else { continue }
                if mark.start < start { plan.additions.append(piece(of: mark, mark.start, start, newID)) }
                if mark.end > end { plan.additions.append(piece(of: mark, end, mark.end, newID)) }
            }
            return plan
        case let .removeMarks(ids):
            let wanted = Set(ids)
            return LawMarkPlan(deletions: marks.filter { wanted.contains($0.id) })
        case let .recolor(ids, color):
            var current = marks, total = LawMarkPlan()
            for id in ids {
                guard let mark = current.first(where: { $0.id == id }) else { continue }
                guard colorKey(mark.color) != colorKey(color) else { continue }
                var step = LawMarkPlan(deletions: [mark])
                if mark.fixed {
                    var copy = mark; copy.id = newID(); copy.color = color
                    step.additions = [copy]
                } else {
                    step = step.then(add(mark.start, mark.end, color, marks: current.filter { $0.id != id }, sectionId: sectionId, newID: newID))
                }
                total = total.then(step)
                current = apply(step, to: current)
            }
            return total
        case let .resize(id, start, end):
            guard let mark = marks.first(where: { $0.id == id }) else { throw LawMarkError.unknownMark }
            try validate(start, end, textLength)
            guard mark.start != start || mark.end != end else { return LawMarkPlan() }
            if mark.fixed { throw LawMarkError.invalidRange }
            return LawMarkPlan(deletions: [mark]).then(add(start, end, mark.color, marks: marks.filter { $0.id != id }, sectionId: sectionId, newID: newID))
        }
    }

    /// The marks after `plan` (for tests and immediate display).
    public static func apply(_ plan: LawMarkPlan, to marks: [LawMarkRange]) -> [LawMarkRange] {
        let deleted = Set(plan.deletedIDs)
        return marks.filter { !deleted.contains($0.id) } + plan.additions
    }

    /// Marks of the section that share at least one character with `start..<end`.
    public static func touching(_ start: Int, _ end: Int, in marks: [LawMarkRange], sectionId: String) -> [LawMarkRange] {
        marks.filter { $0.sectionId == sectionId && $0.overlaps(start, end) }
    }

    /// The anchor to store for `range` in the canonical section text.
    public static func anchor(for range: LawMarkRange, canonical: String) -> LawAnchor? {
        let text = canonical as NSString
        guard range.start >= 0, range.end > range.start, range.end <= text.length else { return nil }
        return LawAnchor(sectionId: range.sectionId, start: range.start, end: range.end,
                         quote: text.substring(with: NSRange(location: range.start, length: range.length)))
    }

    private static func validate(_ start: Int, _ end: Int, _ textLength: Int, limit: Int = maxLength) throws {
        guard start >= 0, end > start, end <= textLength else { throw LawMarkError.invalidRange }
        guard end - start <= limit else { throw LawMarkError.tooLong(end - start) }
    }
    private static func piece(of mark: LawMarkRange, _ start: Int, _ end: Int, _ newID: () -> String) -> LawMarkRange {
        LawMarkRange(id: newID(), sectionId: mark.sectionId, start: start, end: end, color: mark.color, fixed: false)
    }
    private static func add(_ start: Int, _ end: Int, _ color: String?, marks: [LawMarkRange], sectionId: String, newID: () -> String) -> LawMarkPlan {
        let editable = marks.filter { !$0.fixed }, key = colorKey(color)
        let same = editable.filter { colorKey($0.color) == key }, other = editable.filter { colorKey($0.color) != key }
        // Exact duplicate (or inside one mark of the same colour): nothing to do.
        if same.contains(where: { $0.start <= start && $0.end >= end }), !other.contains(where: { $0.overlaps(start, end) }) { return LawMarkPlan() }
        // Same colour overlapping or adjacent merges, also transitively.
        var lo = start, hi = end, merged: [LawMarkRange] = [], changed = true
        while changed {
            changed = false
            for mark in same where !merged.contains(mark) && mark.start <= hi && mark.end >= lo {
                merged.append(mark); lo = min(lo, mark.start); hi = max(hi, mark.end); changed = true
            }
        }
        var plan = LawMarkPlan()
        // Another colour gives way only inside the new selection: its parts
        // before `start` and after `end` stay, even within the merged range.
        var remaining: [(Int, Int)] = []
        for mark in other {
            guard mark.overlaps(start, end) else { remaining.append((mark.start, mark.end)); continue }
            plan.deletions.append(mark)
            if mark.start < start { plan.additions.append(piece(of: mark, mark.start, start, newID)); remaining.append((mark.start, start)) }
            if mark.end > end { plan.additions.append(piece(of: mark, end, mark.end, newID)); remaining.append((end, mark.end)) }
        }
        // The same colour joins across lo…hi only where no other colour is
        // left; there it is stored as separate pieces.
        var spans: [(Int, Int)] = [], from = lo
        for (a, b) in remaining.filter({ $0.0 < hi && $0.1 > lo }).sorted(by: { $0.0 < $1.0 }) {
            if a > from { spans.append((from, a)) }
            from = max(from, b)
        }
        if from < hi { spans.append((from, hi)) }
        if merged.count == 1, spans.count == 1, merged[0].start == spans[0].0, merged[0].end == spans[0].1 { return plan }
        plan.deletions += merged
        // A merge beyond the contract's limit is stored as adjoining pieces.
        for (a, b) in spans {
            var from = a
            while from < b {
                let to = min(b, from + maxLength)
                plan.additions.append(LawMarkRange(id: newID(), sectionId: sectionId, start: from, end: to, color: color ?? merged.first?.color))
                from = to
            }
        }
        return plan
    }

    // MARK: Words (Pencil)

    /// `range` of `text` widened to whole words; nil if it touches no word.
    public static func wordRange(in text: String, covering range: NSRange) -> NSRange? {
        wordRange(covering: range, words: words(in: text, near: range))
    }
    /// The word at UTF-16 offset `index` (or right before it, at a word end).
    public static func word(in text: String, at index: Int) -> NSRange? {
        word(at: index, words: words(in: text, near: NSRange(location: max(0, index - 1), length: 2)))
    }
    /// Pure part of `wordRange`: `words` are the word ranges near `range`.
    public static func wordRange(covering range: NSRange, words: [NSRange]) -> NSRange? {
        let hit = words.filter { NSIntersectionRange($0, range).length > 0 }.sorted { $0.location < $1.location }
        guard let first = hit.first, let last = hit.last else { return nil }
        return NSRange(location: first.location, length: NSMaxRange(last) - first.location)
    }
    public static func word(at index: Int, words: [NSRange]) -> NSRange? {
        words.first { NSLocationInRange(index, $0) } ?? words.first { NSMaxRange($0) == index }
    }
    /// Word ranges in a window around `range`. On Apple platforms Foundation's
    /// word enumeration (the system tokenizer) decides; Linux Foundation has
    /// none, there letters, digits and marks of whole characters form words.
    public static func words(in text: String, near range: NSRange) -> [NSRange] {
        let string = text as NSString
        // Only a window around the range: strokes ask on every Pencil sample.
        let lo = max(0, range.location - 80), hi = min(string.length, NSMaxRange(range) + 80)
        guard hi > lo else { return [] }
        let window = string.rangeOfComposedCharacterSequences(for: NSRange(location: lo, length: hi - lo))
        var result: [NSRange] = []
        #if canImport(Darwin)
        string.enumerateSubstrings(in: window, options: [.byWords, .substringNotRequired]) { _, wordRange, _, _ in
            result.append(wordRange)
        }
        #else
        var current: NSRange?
        string.enumerateSubstrings(in: window, options: .byComposedCharacterSequences) { character, characterRange, _, _ in
            let isWord = character.map { !LawTextAnchor.canonical($0).isEmpty } ?? false
            if isWord { current = current.map { NSUnionRange($0, characterRange) } ?? characterRange }
            else if let word = current { result.append(word); current = nil }
        }
        if let current { result.append(current) }
        #endif
        // A word cut by the window edge is not a whole word.
        return result.filter { ($0.location > window.location || window.location == 0) && (NSMaxRange($0) < NSMaxRange(window) || NSMaxRange(window) == string.length) }
    }
}

// MARK: - Undo/redo of written changes

/// One written change of the current owner: the entries it removed (to bring
/// back) and the IDs it created (to delete again).
public struct LawMarkStep: Equatable, Sendable {
    public var owner: String?
    public var removed: [LawPersonalItem]
    public var created: [String]
    public init(owner: String?, removed: [LawPersonalItem], created: [String]) {
        self.owner = owner; self.removed = removed; self.created = created
    }
}

/// What replaying a step writes: the still live created entries go, the
/// removed ones come back with new IDs (deleted IDs stay blocked on the server).
public struct LawMarkReplay: Equatable, Sendable {
    public var removals: [LawPersonalItem]
    public var additions: [LawPersonalChange]
    /// Old ID → new ID of every entry brought back.
    public var renamed: [String: String]
    public var isEmpty: Bool { removals.isEmpty && additions.isEmpty }
}

/// The reader's own undo and redo stacks. Every replay gives the entries it
/// brings back new IDs; the older steps on both stacks follow them
/// (`didUndo`/`didRedo`), so several undos in a row keep working after
/// dependent steps (mark → extend → undo → undo). Steps belong to one
/// owner: another one (sign-in, sign-out, account switch) empties both
/// stacks, so an undo never writes one account's entries for another.
public struct LawMarkHistory: Equatable, Sendable {
    public static let limit = 100
    public private(set) var undo: [LawMarkStep] = []
    public private(set) var redo: [LawMarkStep] = []
    public private(set) var owner: String?
    public init(owner: String? = nil) { self.owner = owner }
    public var canUndo: Bool { !undo.isEmpty }
    public var canRedo: Bool { !redo.isEmpty }

    /// Another owner than the stacks': both are emptied.
    public mutating func align(owner: String?) {
        guard owner != self.owner else { return }
        undo = []; redo = []; self.owner = owner
    }
    /// A new change of the user: last undo step, redo is gone.
    public mutating func record(_ step: LawMarkStep) {
        align(owner: step.owner)
        undo.append(step)
        if undo.count > Self.limit { undo.removeFirst(undo.count - Self.limit) }
        redo = []
    }
    public mutating func popUndo() -> LawMarkStep? { undo.popLast() }
    public mutating func popRedo() -> LawMarkStep? { redo.popLast() }
    /// A popped step that could not be written goes back where it was.
    public mutating func putBack(_ step: LawMarkStep, undo isUndo: Bool) {
        guard step.owner == owner else { return }
        if isUndo { undo.append(step) } else { redo.append(step) }
    }
    /// An undo was written as `result`: it can be redone, and the remaining
    /// steps refer to the entries brought back by their new IDs.
    public mutating func didUndo(_ result: LawMarkStep, renamed: [String: String]) {
        follow(renamed)
        guard result.owner == owner else { return }
        redo.append(result)
    }
    public mutating func didRedo(_ result: LawMarkStep, renamed: [String: String]) {
        follow(renamed)
        guard result.owner == owner else { return }
        undo.append(result)
        if undo.count > Self.limit { undo.removeFirst(undo.count - Self.limit) }
    }
    private mutating func follow(_ renamed: [String: String]) {
        guard !renamed.isEmpty else { return }
        func map(_ step: LawMarkStep) -> LawMarkStep {
            var step = step
            step.created = step.created.map { renamed[$0] ?? $0 }
            step.removed = step.removed.map { item in
                guard let id = renamed[item.id] else { return item }
                var item = item; item.id = id
                if item.payload["id"] != nil { item.payload["id"] = .string(id) }
                return item
            }
            return step
        }
        undo = undo.map(map); redo = redo.map(map)
    }

    /// What replaying `step` writes now: `live` finds a live entry of the
    /// current owner by ID (others are gone and stay gone).
    public static func replay(_ step: LawMarkStep, live: (String) -> LawPersonalItem?,
                              newID: () -> String = LawMarkEditing.newID) -> LawMarkReplay {
        var renamed: [String: String] = [:], additions: [LawPersonalChange] = []
        for item in step.removed {
            var payload = item.payload
            payload["id"] = nil
            let id = newID()
            renamed[item.id] = id
            additions.append(LawPersonalChange(kind: item.kind, payload: payload, id: id))
        }
        return LawMarkReplay(removals: step.created.compactMap(live), additions: additions, renamed: renamed)
    }
}

/// Keeps a Pencil stroke on the line it started on: another line is taken
/// only when Pencil is more than `threshold` line heights away from the bound
/// line's middle.
public enum LawPencilLine {
    public static let threshold = 0.6
    public static func leaves(boundMidY: Double, lineHeight: Double, y: Double) -> Bool {
        lineHeight > 0 && abs(y - boundMidY) > threshold * lineHeight
    }
}

// MARK: - PDF (port of the website's lib/annotations.ts)

/// A rectangle normalised to the unrotated crop box, origin top left.
public struct LawPDFRect: Hashable, Sendable {
    public var x: Double, y: Double, width: Double, height: Double
    public init(x: Double, y: Double, width: Double, height: Double) { self.x = x; self.y = y; self.width = width; self.height = height }
    /// As stored in a `pdf-text` payload.
    public var json: LawJSON { .object(["x": .number(x), "y": .number(y), "width": .number(width), "height": .number(height)]) }
    public init?(json: LawJSON) {
        guard case let .object(r) = json, case let .number(x) = r["x"], case let .number(y) = r["y"],
              case let .number(w) = r["width"], case let .number(h) = r["height"] else { return nil }
        self.init(x: x, y: y, width: w, height: h)
    }
}
public struct LawPDFPoint: Hashable, Sendable {
    public var x: Double, y: Double
    public init(_ x: Double, _ y: Double) { self.x = x; self.y = y }
}
/// One UTF-16 unit of a page's text with its box (normalised, top left).
public struct LawPDFGlyph: Hashable, Sendable {
    public var unit: UInt16
    public var x: Double, y: Double, width: Double, height: Double
    public init(unit: UInt16, x: Double, y: Double, width: Double, height: Double) { self.unit = unit; self.x = x; self.y = y; self.width = width; self.height = height }
}
public struct LawPDFTextLayout: Sendable {
    public var glyphs: [LawPDFGlyph]
    /// Page height / page width.
    public var aspectRatio: Double
    public init(glyphs: [LawPDFGlyph], aspectRatio: Double) { self.glyphs = glyphs; self.aspectRatio = aspectRatio }
    public var text: String { String(utf16CodeUnits: glyphs.map(\.unit), count: glyphs.count) }
}

public enum LawPDFAnchoring {
    /// The server accepts 2…1500 points per stroke, 1…500 rectangles.
    public static let maxPoints = 1500
    public static let maxRectangles = 500
    /// Stroke width relative to the page width (as drawn by app and website).
    public static let strokeWidth = 0.018

    /// Index of the only occurrence of `quote` in `text` (UTF-16), else -1.
    public static func uniqueIndex(_ text: String, _ quote: String) -> Int {
        guard !quote.isEmpty else { return -1 }
        let string = text as NSString
        let first = string.range(of: quote, options: .literal)
        guard first.location != NSNotFound else { return -1 }
        let rest = NSRange(location: first.location + 1, length: string.length - first.location - 1)
        return string.range(of: quote, options: .literal, range: rest).location == NSNotFound ? first.location : -1
    }
    public static func anchorIsValid(_ section: LawSection, _ anchor: LawAnchor) -> Bool {
        let text = LawTextAnchor.canonical(section.text) as NSString
        return anchor.sectionId == section.id && anchor.start >= 0 && anchor.end > anchor.start && anchor.end <= text.length
            && text.substring(with: NSRange(location: anchor.start, length: anchor.end - anchor.start)) == anchor.quote
    }
    /// Whether section `index` physically covers `top…bottom` of `page`.
    public static func sectionCovers(_ sections: [LawSection], index: Int, page: Int, top: Double, bottom: Double) -> Bool {
        guard sections.indices.contains(index), let start = sections[index].pdf,
              page > start.page || (page == start.page && top >= start.top) else { return false }
        // An unmapped following provision leaves the boundary unknown.
        guard sections.indices.contains(index + 1) else { return true }
        guard let next = sections[index + 1].pdf else { return false }
        return page < next.page || (page == next.page && bottom < next.top)
    }
    /// The text anchor of a PDF quote, only if exactly one provision covering
    /// this part of the page contains it exactly once.
    public static func match(_ sections: [LawSection], page: Int, quote: String, top: Double, bottom: Double) -> LawAnchor? {
        let value = LawTextAnchor.canonical(quote), length = (value as NSString).length
        guard length >= 12, length <= LawMarkEditing.maxLength else { return nil }
        var result: LawAnchor?
        for index in sections.indices where sectionCovers(sections, index: index, page: page, top: top, bottom: bottom) {
            let start = uniqueIndex(LawTextAnchor.canonical(sections[index].text), value)
            guard start >= 0 else { continue }
            if result != nil { return nil }
            result = LawAnchor(sectionId: sections[index].id, start: start, end: start + length, quote: value)
        }
        return result
    }
    private static func canonicalUnit(_ unit: UInt16) -> Bool {
        guard let scalar = Unicode.Scalar(unit) else { return false }
        return !LawTextAnchor.canonical(String(Character(scalar))).isEmpty
    }
    private static func wordUnit(_ unit: UInt16) -> Bool {
        guard let scalar = Unicode.Scalar(unit) else { return false }
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
             .decimalNumber, .letterNumber, .otherNumber, .nonspacingMark, .spacingMark, .enclosingMark: return true
        default: return false
        }
    }
    private static func segmentHitsBox(_ a: LawPDFPoint, _ b: LawPDFPoint, left: Double, top: Double, right: Double, bottom: Double) -> Bool {
        var low = 0.0, high = 1.0
        let dx = b.x - a.x, dy = b.y - a.y
        let p = [-dx, dx, -dy, dy], q = [a.x - left, right - a.x, a.y - top, bottom - a.y]
        for i in 0..<4 {
            if p[i] == 0 { if q[i] < 0 { return false } } else {
                let ratio = q[i] / p[i]
                if p[i] < 0 { low = max(low, ratio) } else { high = min(high, ratio) }
                if low > high { return false }
            }
        }
        return true
    }
    /// The words a stroke covers: every word between its first and last hit
    /// must be hit itself (a scribble across phrases gives no quote).
    public static func quoteUnderStroke(_ layout: LawPDFTextLayout, points: [LawPDFPoint], width: Double = strokeWidth) -> (quote: String, top: Double, bottom: Double)? {
        let glyphs = layout.glyphs
        guard points.count >= 2, layout.aspectRatio > 0 else { return nil }
        let half = width / layout.aspectRatio / 2
        let hit = glyphs.map { glyph -> Bool in
            guard canonicalUnit(glyph.unit) else { return false }
            let left = glyph.x + glyph.width * 0.35, right = glyph.x + glyph.width * 0.65
            let top = glyph.y + glyph.height * 0.4 - half, bottom = glyph.y + glyph.height * 0.6 + half
            return zip(points, points.dropFirst()).contains { segmentHitsBox($0, $1, left: left, top: top, right: right, bottom: bottom) }
        }
        guard var start = hit.firstIndex(of: true), let last = hit.lastIndex(of: true) else { return nil }
        var end = last + 1
        if (start..<end).contains(where: { !hit[$0] && canonicalUnit(glyphs[$0].unit) }) { return nil }
        while start > 0, wordUnit(glyphs[start - 1].unit) { start -= 1 }
        while end < glyphs.count, wordUnit(glyphs[end].unit) { end += 1 }
        let covered = glyphs[start..<end].filter { canonicalUnit($0.unit) }
        guard !covered.isEmpty else { return nil }
        let text = String(utf16CodeUnits: glyphs[start..<end].map(\.unit), count: end - start)
        return (LawTextAnchor.canonical(text), covered.map(\.y).min()!, covered.map { $0.y + $0.height }.max()!)
    }
    /// Rectangles of a saved text mark on `page`, only when its whole unique
    /// quote is there and the right provision covers that place.
    public static func rectangles(for anchor: LawAnchor, layout: LawPDFTextLayout, sections: [LawSection], page: Int) -> [LawPDFRect] {
        guard let index = sections.firstIndex(where: { $0.id == anchor.sectionId }), anchorIsValid(sections[index], anchor),
              uniqueIndex(LawTextAnchor.canonical(sections[index].text), anchor.quote) == anchor.start else { return [] }
        let text = layout.text
        let start = uniqueIndex(LawTextAnchor.canonical(text), anchor.quote)
        guard start >= 0, let original = LawTextAnchor.originalRange(text: text, anchor: LawAnchor(sectionId: anchor.sectionId, start: start, end: start + (anchor.quote as NSString).length, quote: anchor.quote)),
              NSMaxRange(original) <= layout.glyphs.count else { return [] }
        let glyphs = layout.glyphs[original.location..<NSMaxRange(original)].filter { canonicalUnit($0.unit) }
        guard !glyphs.isEmpty, sectionCovers(sections, index: index, page: page, top: glyphs.map(\.y).min()!, bottom: glyphs.map { $0.y + $0.height }.max()!) else { return [] }
        return joined(glyphs)
    }
    /// Neighbouring glyphs of a line become one rectangle.
    static func joined(_ glyphs: [LawPDFGlyph]) -> [LawPDFRect] {
        var rectangles: [LawPDFRect] = []
        for glyph in glyphs {
            if var prior = rectangles.last, abs(prior.y - glyph.y) < glyph.height * 0.3, glyph.x >= prior.x, glyph.x - (prior.x + prior.width) < glyph.height {
                prior.width = max(prior.width, glyph.x + glyph.width - prior.x)
                prior.height = max(prior.height, glyph.height)
                rectangles[rectangles.count - 1] = prior
            } else {
                rectangles.append(LawPDFRect(x: glyph.x, y: glyph.y, width: glyph.width, height: glyph.height))
            }
        }
        return rectangles
    }
    /// The word under a Pencil tap: its canonical quote and rectangles.
    public static func word(at point: LawPDFPoint, layout: LawPDFTextLayout, slop: Double = 0.003) -> (quote: String, rectangles: [LawPDFRect], top: Double, bottom: Double)? {
        let glyphs = layout.glyphs
        guard let hit = glyphs.firstIndex(where: { canonicalUnit($0.unit) && point.x >= $0.x - slop && point.x <= $0.x + $0.width + slop && point.y >= $0.y - slop && point.y <= $0.y + $0.height + slop }) else { return nil }
        var start = hit, end = hit + 1
        while start > 0, wordUnit(glyphs[start - 1].unit) { start -= 1 }
        while end < glyphs.count, wordUnit(glyphs[end].unit) { end += 1 }
        let covered = glyphs[start..<end].filter { canonicalUnit($0.unit) }
        let text = String(utf16CodeUnits: glyphs[start..<end].map(\.unit), count: end - start)
        return (LawTextAnchor.canonical(text), joined(covered), covered.map(\.y).min()!, covered.map { $0.y + $0.height }.max()!)
    }
    /// Adds a stroke sample like the website: tiny moves are skipped, and at
    /// the limit every other point is dropped instead of ending the stroke.
    public static func append(_ point: LawPDFPoint, to points: inout [LawPDFPoint]) {
        if let last = points.last, hypot(point.x - last.x, point.y - last.y) < 0.0005 { return }
        if points.count >= maxPoints - 2 { points = points.enumerated().filter { $0.offset % 2 == 0 }.map(\.element) }
        points.append(point)
    }
    /// At most `limit` points, first and last kept, evenly thinned.
    public static func thinned(_ points: [LawPDFPoint], limit: Int = maxPoints) -> [LawPDFPoint] {
        guard points.count > limit, limit >= 2 else { return points }
        let step = Double(points.count - 1) / Double(limit - 1)
        return (0..<limit).map { points[min(points.count - 1, Int((Double($0) * step).rounded()))] }
    }
    /// The server takes a request body of at most 64 KiB.
    public static let maxBody = 65_536
    /// Stroke points as the server keeps them: 0…1, five decimals.
    public static func rounded(_ points: [LawPDFPoint]) -> [LawPDFPoint] {
        func unit(_ v: Double) -> Double { v.isFinite ? (min(1, max(0, v)) * 100_000).rounded() / 100_000 : 0 }
        return points.map { LawPDFPoint(unit($0.x), unit($0.y)) }
    }
    /// Rectangles inside the page (0…1; the server refuses anything beyond),
    /// six decimals like the server; empty ones are dropped.
    public static func clamped(_ rects: [LawPDFRect]) -> [LawPDFRect] {
        func unit(_ v: Double) -> Double { v.isFinite ? (min(1, max(0, v)) * 1_000_000).rounded() / 1_000_000 : 0 }
        return rects.compactMap { r in
            guard r.x.isFinite, r.y.isFinite, r.width.isFinite, r.height.isFinite else { return nil }
            let x = unit(r.x), y = unit(r.y), right = unit(r.x + r.width), bottom = unit(r.y + r.height)
            guard right > x, bottom > y else { return nil }
            return LawPDFRect(x: x, y: y, width: ((right - x) * 1_000_000).rounded() / 1_000_000, height: ((bottom - y) * 1_000_000).rounded() / 1_000_000)
        }
    }
    /// Bytes of `payload` as sent (JSON), with room for an `id` it gets later.
    public static func bodySize(_ payload: [String: LawJSON]) -> Int {
        var payload = payload
        if payload["id"] == nil { payload["id"] = .string(String(repeating: "0", count: 36)) }
        return (try? JSONEncoder().encode(payload).count) ?? Int.max
    }
    /// A `pdf`/`pdf-text` payload the server accepts: coordinates rounded and
    /// inside the page, at most 1500 points or 500 rectangles, and a body of
    /// at most 64 KiB including the anchor; a stroke is thinned further
    /// instead of being refused (413), rectangles of a line are joined.
    /// Other payloads come back unchanged; nil if nothing valid is left.
    public static func fitted(_ payload: [String: LawJSON]) -> [String: LawJSON]? {
        var payload = payload
        switch payload["kind"]?.string {
        case "pdf":
            guard case let .array(values) = payload["points"] else { return nil }
            var points = rounded(values.compactMap { value -> LawPDFPoint? in
                guard case let .array(xy) = value, xy.count == 2, case let .number(x) = xy[0], case let .number(y) = xy[1] else { return nil }
                return LawPDFPoint(x, y)
            })
            points = thinned(points)
            func encode() { payload["points"] = .array(points.map { .array([.number($0.x), .number($0.y)]) }) }
            encode()
            while bodySize(payload) > maxBody {
                guard points.count > 2 else { return nil }
                points = thinned(points, limit: max(2, points.count * 3 / 4))
                encode()
            }
            return points.count >= 2 ? payload : nil
        case "pdf-text":
            guard case let .array(values) = payload["rectangles"] else { return nil }
            var rects = clamped(limitedRectangles(values.compactMap(LawPDFRect.init(json:))))
            guard !rects.isEmpty else { return nil }
            payload["rectangles"] = .array(rects.map(\.json))
            if bodySize(payload) > maxBody {
                rects = clamped(joinedLines(rects))
                payload["rectangles"] = .array(rects.map(\.json))
            }
            return bodySize(payload) <= maxBody && !rects.isEmpty ? payload : nil
        default:
            return payload
        }
    }
    /// Every line's rectangles as one (`limitedRectangles` without the count limit).
    static func joinedLines(_ rects: [LawPDFRect]) -> [LawPDFRect] {
        var result: [LawPDFRect] = []
        for rect in rects {
            if var prior = result.last, abs(prior.y - rect.y) < rect.height * 0.3 {
                let right = max(prior.x + prior.width, rect.x + rect.width)
                prior.x = min(prior.x, rect.x); prior.width = right - prior.x
                prior.height = max(prior.height, rect.height); result[result.count - 1] = prior
            } else { result.append(rect) }
        }
        return Array(result.prefix(maxRectangles))
    }
    /// Merges line rectangles of one page and keeps at most `maxRectangles`.
    public static func limitedRectangles(_ rects: [LawPDFRect]) -> [LawPDFRect] {
        guard rects.count > maxRectangles else { return rects }
        // Rarely reached (a whole page in narrow columns): join neighbours per line.
        return joinedLines(rects)
    }
}
