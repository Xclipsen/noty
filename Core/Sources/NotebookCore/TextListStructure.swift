import Foundation

/// Nested lists on top of the existing format: list markers stay text prefixes,
/// the nesting level is the paragraph indent (20-pt steps, at most 240 pt).
/// Bullets cycle • ◦ ▪ per level; numbering restarts at every level with
/// decimal numbers (no a./i. markers, which German text like „z. B.“ would hit).
extension TextListEditing {
    public static let bulletGlyphs = ["•", "◦", "▪"]
    public static func bullet(forLevel level: Int) -> String { bulletGlyphs[max(0, level) % bulletGlyphs.count] + " " }
    public static func level(forIndent indent: Double?) -> Int {
        max(0, Int(((indent ?? 0) / TextPlacement.indentStep).rounded()))
    }
    static func lineStart(_ text: String, _ location: Int) -> Int {
        let source = text as NSString
        return source.lineRange(for: NSRange(location: min(max(0, location), source.length), length: 0)).location
    }

    // MARK: Automatic lists

    static let autoTriggers: [(String, Kind)] = [("- ", .bullet), ("* ", .bullet), ("• ", .bullet),
        ("1. ", .numbered), ("1) ", .numbered), ("[] ", .checkbox), ("[ ] ", .checkbox)]

    /// Typing a trigger at the start of a paragraph (after its space) converts
    /// it to the list marker. nil when the typed text already is that marker.
    public static func autoList(in text: String, caret: Int, level: Int = 0) -> Edit? {
        let source = text as NSString
        guard caret > 0, caret <= source.length else { return nil }
        let start = lineStart(text, caret - 1)
        let typed = source.substring(with: NSRange(location: start, length: caret - start))
        let body = String(typed.drop { $0 == " " || $0 == "\t" })
        guard let (trigger, kind) = autoTriggers.first(where: { $0.0 == body }) else { return nil }
        let marker = switch kind { case .bullet: bullet(forLevel: level); case .checkbox: "☐ "; case .numbered: "1. " }
        guard marker != trigger else { return nil }
        let length = (trigger as NSString).length
        return Edit(range: NSRange(location: caret - length, length: length), replacement: marker)
    }

    // MARK: Paragraph structure

    public struct NumberedItem: Equatable, Sendable {
        public let depth: Int
        public let number: Int
    }
    /// Open list runs at the end of earlier flow segments (previous pages).
    public struct ListContext: Equatable, Sendable {
        struct Open: Equatable, Sendable { var depth: Int; var kind: Kind; var next: Int }
        var open: [Open] = []
        public init() {}
    }
    struct Paragraph {
        var start: Int
        var prefixLocation: Int
        var prefix: String
        var kind: Kind?
        var number: Int?
        var depth: Int
        var level: Int
        var empty: Bool
        var continuation: Bool
    }

    static func paragraph(_ source: NSString, line: NSRange, level: (Int) -> Int, continuation: Bool) -> Paragraph {
        let value = source.substring(with: line)
        let space = value.prefix { $0 == " " || $0 == "\t" }
        let marker = continuation ? nil : prefix(String(value.dropFirst(space.count)))
        let kind = marker.flatMap { value in [Kind.checkbox, .bullet, .numbered].first { matches($0, value) } }
        let tabs = space.filter { $0 == "\t" }.count
        let nesting = level(line.location)
        return Paragraph(start: line.location, prefixLocation: line.location + (String(space) as NSString).length,
            prefix: marker ?? "", kind: kind, number: kind == .numbered ? Int(marker!.dropLast(2)) : nil,
            depth: nesting * 1000 + tabs * 4 + (space.count - tabs), level: nesting,
            empty: value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, continuation: continuation)
    }
    static func paragraphs(in text: String, level: (Int) -> Int, continuation: Bool) -> [Paragraph] {
        let source = text as NSString
        var result: [Paragraph] = [], cursor = 0
        while cursor < source.length {
            let line = source.lineRange(for: NSRange(location: cursor, length: 0))
            result.append(paragraph(source, line: line, level: level, continuation: continuation && line.location == 0))
            guard NSMaxRange(line) > cursor else { break }
            cursor = NSMaxRange(line)
        }
        return result
    }

    /// Number and depth of a numbered item at `location` (state before an edit).
    public static func numberedItem(in text: String, at location: Int, level: (Int) -> Int, continuation: Bool = false) -> NumberedItem? {
        let source = text as NSString
        guard location >= 0, location < source.length else { return nil }
        let line = source.lineRange(for: NSRange(location: location, length: 0))
        let item = paragraph(source, line: line, level: level, continuation: continuation && line.location == 0)
        guard item.kind == .numbered, let number = item.number else { return nil }
        return NumberedItem(depth: item.depth, number: number)
    }

    /// Smallest changed UTF-16 range, in the coordinates of `new`.
    public static func changedRange(from old: String, to new: String) -> NSRange? {
        let a = Array(old.utf16), b = Array(new.utf16)
        guard a != b else { return nil }
        var head = 0
        while head < a.count, head < b.count, a[head] == b[head] { head += 1 }
        var tail = 0
        while tail < a.count - head, tail < b.count - head, a[a.count - 1 - tail] == b[b.count - 1 - tail] { tail += 1 }
        return NSRange(location: head, length: b.count - head - tail)
    }

    /// Caret position in the text before an edit (undo restores it there).
    public static func caret(before old: String, after new: String, selection: Int) -> Int {
        let oldLength = (old as NSString).length
        guard let changed = changedRange(from: old, to: new) else { return min(max(0, selection), oldLength) }
        let removed = oldLength - ((new as NSString).length - changed.length)
        if selection <= changed.location { return min(max(0, selection), oldLength) }
        return min(oldLength, max(changed.location, selection - changed.length + removed))
    }

    private struct Walk {
        var open: [(item: ListContext.Open, run: Int)] = []
        var runs: [(touched: Bool, items: [(index: Int, number: Int)])] = []
    }
    /// Runs of list items: deeper items and indented paragraphs stay inside the
    /// outer run, a normal paragraph ends runs at its depth, a blank line all.
    private static func walk(_ list: [Paragraph], context: ListContext, touched: (Int) -> Bool,
                             start: (Int, Paragraph) -> Int) -> Walk {
        var state = Walk(); state.open = context.open.map { ($0, -1) }
        for (index, item) in list.enumerated() where !item.continuation {
            guard let kind = item.kind else {
                let depth = item.empty ? 0 : item.depth
                state.open.removeAll { $0.item.depth >= depth }
                continue
            }
            state.open.removeAll { $0.item.depth > item.depth }
            if let top = state.open.last, top.item.depth == item.depth, top.item.kind != kind { state.open.removeLast() }
            if state.open.last?.item.depth != item.depth {
                state.open.append((ListContext.Open(depth: item.depth, kind: kind, next: start(index, item)), -1))
            }
            var top = state.open.removeLast()
            if top.run < 0 { state.runs.append((false, [])); top.run = state.runs.count - 1 }
            state.runs[top.run].items.append((index, top.item.next))
            if touched(index) { state.runs[top.run].touched = true }
            top.item.next = min(999_999, top.item.next + 1)
            state.open.append(top)
        }
        return state
    }

    public static func context(after text: String, level: (Int) -> Int, continuation: Bool = false,
                               from context: ListContext = ListContext()) -> ListContext {
        let state = walk(paragraphs(in: text, level: level, continuation: continuation), context: context,
            touched: { _ in false }, start: { $1.number ?? 1 })
        var result = ListContext(); result.open = state.open.map(\.item)
        return result
    }

    /// Renumbers the runs touched by an edit (the changed paragraphs and the
    /// one after): each run counts on from its first item, which keeps its own
    /// number — unless the edit removed the previous first item, whose number
    /// (`restart`) is then reused. After nesting (`freshStarts`) runs beginning
    /// at a moved item start at 1. Bullets of touched items follow their level.
    public static func normalize(_ text: String, level: (Int) -> Int, changed: NSRange, restart: NumberedItem? = nil,
                                 context: @autoclosure () -> ListContext = ListContext(), continuation: Bool = false,
                                 freshStarts: Bool = false) -> [Edit] {
        let source = text as NSString
        guard changed.location >= 0, changed.length >= 0, NSMaxRange(changed) <= source.length else { return [] }
        // Cheap exit for ordinary typing away from lists.
        let first = source.lineRange(for: NSRange(location: changed.location, length: 0))
        var end = NSMaxRange(source.lineRange(for: NSRange(location: NSMaxRange(changed), length: 0)))
        if end < source.length { end = NSMaxRange(source.lineRange(for: NSRange(location: end, length: 0))) }
        let window = NSRange(location: first.location, length: end - first.location)
        let local = paragraphs(in: source.substring(with: window), level: { level(window.location + $0) },
            continuation: continuation && window.location == 0)
        guard local.contains(where: { $0.kind != nil }) else { return [] }

        let list = paragraphs(in: text, level: level, continuation: continuation)
        let touchedRange = window.location..<max(window.location + 1, NSMaxRange(window))
        func touched(_ index: Int) -> Bool { touchedRange.contains(list[index].start) }
        func prefixEdited(_ item: Paragraph) -> Bool {
            let end = item.prefixLocation + (item.prefix as NSString).length
            if changed.length == 0 { return changed.location > item.prefixLocation && changed.location <= end }
            return changed.location < end && NSMaxRange(changed) > item.prefixLocation
        }
        let state = walk(list, context: context(), touched: touched) { index, item in
            if item.kind == .numbered, touched(index), freshStarts { return 1 }
            if item.kind == .numbered, touched(index), let restart, restart.depth == item.depth, !prefixEdited(item) { return restart.number }
            return item.number ?? 1
        }
        var edits: [Edit] = []
        for run in state.runs where run.touched {
            for (index, number) in run.items where list[index].kind == .numbered && list[index].number != number {
                edits.append(Edit(range: NSRange(location: list[index].prefixLocation, length: (list[index].prefix as NSString).length),
                    replacement: "\(number). "))
            }
        }
        for (index, item) in list.enumerated() where touched(index) && item.kind == .bullet
            && bulletGlyphs.contains(String(item.prefix.prefix(1))) && item.prefix != bullet(forLevel: item.level) {
            edits.append(Edit(range: NSRange(location: item.prefixLocation, length: (item.prefix as NSString).length),
                replacement: bullet(forLevel: item.level)))
        }
        return edits.sorted { $0.range.location < $1.range.location }
    }
}

extension TextBox {
    /// Style at a UTF-16 location (runs are sorted and nonoverlapping).
    public func style(at location: Int) -> TextBoxStyle {
        guard let runs, !runs.isEmpty else { return style }
        var low = 0, high = runs.count - 1
        while low <= high {
            let middle = (low + high) / 2, run = runs[middle]
            if location < run.location { high = middle - 1 }
            else if location >= run.location + run.length { low = middle + 1 }
            else { return run.style }
        }
        return style
    }
    public func listLevel(at location: Int) -> Int { TextListEditing.level(forIndent: style(at: location).indent) }

    private var completeRuns: [TextRun] {
        let length = (text as NSString).length
        var result: [TextRun] = [], end = 0
        for run in runs ?? [] {
            if run.location > end { result.append(TextRun(location: end, length: run.location - end, style: style)) }
            result.append(run); end = run.location + run.length
        }
        if end < length { result.append(TextRun(location: end, length: length - end, style: style)) }
        return result
    }
    private static func merged(_ runs: [TextRun]) -> [TextRun] {
        var result: [TextRun] = []
        for run in runs where run.length > 0 {
            if let last = result.last, last.style == run.style, last.location + last.length == run.location {
                result[result.count - 1].length += run.length
            } else { result.append(run) }
        }
        return result
    }

    /// Replaces UTF-16 ranges; inserted text takes the style of the replaced
    /// text (or of the character before an insertion). Formatting elsewhere stays.
    public func applying(_ edits: [TextListEditing.Edit]) -> TextBox {
        guard !edits.isEmpty else { return self }
        let source = text as NSString, sorted = edits.sorted { $0.range.location < $1.range.location }
        let old = completeRuns
        var output: [TextRun] = [], delta = 0, cursor = 0, index = 0
        func copy(_ from: Int, _ to: Int) {
            while index < old.count, old[index].location + old[index].length <= from { index += 1 }
            var i = index
            while i < old.count, old[i].location < to {
                let start = max(from, old[i].location), stop = min(to, old[i].location + old[i].length)
                if stop > start { output.append(TextRun(location: start + delta, length: stop - start, style: old[i].style)) }
                i += 1
            }
        }
        let result = NSMutableString(string: text)
        for edit in sorted {
            guard edit.range.location >= cursor, NSMaxRange(edit.range) <= source.length else { continue }
            copy(cursor, edit.range.location)
            let anchor = edit.range.length > 0 || edit.range.location == 0 ? edit.range.location : edit.range.location - 1
            let inserted = (edit.replacement as NSString).length
            output.append(TextRun(location: edit.range.location + delta, length: inserted,
                style: source.length == 0 ? style : style(at: min(anchor, source.length - 1))))
            result.replaceCharacters(in: NSRange(location: edit.range.location + delta, length: edit.range.length), with: edit.replacement)
            delta += inserted - edit.range.length; cursor = NSMaxRange(edit.range)
        }
        copy(cursor, source.length)
        var box = self; box.text = result as String; box.runs = Self.merged(output)
        return box
    }

    /// Applies `change` to the styles of the given UTF-16 ranges.
    public func restyled(_ ranges: [NSRange], _ change: (inout TextBoxStyle) -> Void) -> TextBox {
        var output: [TextRun] = []
        for run in completeRuns {
            var cuts = [run.location, run.location + run.length]
            for range in ranges {
                for edge in [range.location, NSMaxRange(range)] where edge > run.location && edge < run.location + run.length { cuts.append(edge) }
            }
            cuts = Array(Set(cuts)).sorted()
            for (start, stop) in zip(cuts, cuts.dropFirst()) {
                var value = run.style
                if ranges.contains(where: { $0.location <= start && NSMaxRange($0) >= stop }) { change(&value) }
                output.append(TextRun(location: start, length: stop - start, style: value))
            }
        }
        var box = self; box.runs = Self.merged(output)
        return box
    }

    public struct ListNesting: Equatable, Sendable {
        /// Line ranges and their new paragraph indents (format points).
        public var paragraphs: [NSRange]
        public var indents: [Double]
        /// Marker changes, then renumbering in the coordinates after them.
        public var markers: [TextListEditing.Edit]
        public var renumbering: [TextListEditing.Edit]
    }
    /// Tab/⇧Tab or the indent buttons on list items: one nesting level per
    /// step, bullets change glyph, numbering restarts in the new level. nil if
    /// the selection contains no list item or nothing can move.
    public func listNesting(selection: NSRange, outdent: Bool, context: TextListEditing.ListContext = .init(),
                            continuation: Bool = false) -> ListNesting? {
        let source = text as NSString
        guard selection.location >= 0, selection.length >= 0, NSMaxRange(selection) <= source.length else { return nil }
        var plan = ListNesting(paragraphs: [], indents: [], markers: [], renumbering: [])
        for line in TextListEditing.selectedLines(in: text, range: selection) {
            let range = source.lineRange(for: NSRange(location: line.location, length: 0))
            guard !(continuation && range.location == 0),
                  let kind = [TextListEditing.Kind.checkbox, .bullet, .numbered].first(where: { TextListEditing.matches($0, line.prefix) }) else { continue }
            let level = listLevel(at: range.location) + (outdent ? -1 : 1)
            guard level >= 0, Double(level) * TextPlacement.indentStep <= TextPlacement.maximumIndent else { continue }
            plan.paragraphs.append(range); plan.indents.append(Double(level) * TextPlacement.indentStep)
            let marker = NSRange(location: line.location, length: (line.prefix as NSString).length)
            if kind == .numbered, line.prefix != "1. " { plan.markers.append(.init(range: marker, replacement: "1. ")) }
            if kind == .bullet, TextListEditing.bulletGlyphs.contains(String(line.prefix.prefix(1))), line.prefix != TextListEditing.bullet(forLevel: level) {
                plan.markers.append(.init(range: marker, replacement: TextListEditing.bullet(forLevel: level)))
            }
        }
        guard let first = plan.paragraphs.first, let last = plan.paragraphs.last else { return nil }
        var box = self
        for (range, indent) in zip(plan.paragraphs, plan.indents) { box = box.restyled([range]) { $0.indent = indent } }
        box = box.applying(plan.markers)
        let end = NSMaxRange(TextListEditing.selection(last, after: plan.markers))
        plan.renumbering = TextListEditing.normalize(box.text, level: box.listLevel(at:),
            changed: NSRange(location: first.location, length: max(0, end - first.location - 1)), context: context,
            continuation: continuation, freshStarts: true)
        return plan
    }
}

extension Notebook {
    public struct OpenTask: Equatable, Sendable {
        public let pageID: UUID
        public let pageIndex: Int
        public let boxID: UUID
        public let text: String
        public let body: NSRange
    }
    /// Unchecked checkbox items in page order (all text layers, flows per page).
    public var openTasks: [OpenTask] {
        pages.enumerated().flatMap { index, page in
            page.effectiveTextBoxes.flatMap { box in
                TextListEditing.taskItems(in: box.text).filter { !$0.checked }.map { item in
                    OpenTask(pageID: page.id, pageIndex: index, boxID: box.id,
                        text: (box.text as NSString).substring(with: item.body).trimmingCharacters(in: .whitespaces), body: item.body)
                }
            }
        }
    }
}
