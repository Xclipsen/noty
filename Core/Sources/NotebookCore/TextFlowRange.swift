import Foundation

/// A place in a text document's flow: one text view per page shows one
/// segment, while ⌘A, the keyboard mode and paragraph styles work on the
/// whole text. Offsets are UTF-16 units of `Notebook.textFlowContent`.
public struct TextFlowPlace: Equatable, Sendable {
    public var pageID: UUID
    public var boxID: UUID
    public var location: Int
    public init(pageID: UUID, boxID: UUID, location: Int) { self.pageID = pageID; self.boxID = boxID; self.location = location }
}

/// What a whole-flow edit needs from the app (`reflowText` parameters).
public struct TextFlowLayout {
    public var capacity: (Page, TextBox) throws -> Int
    public var trailingDraft: Page?
    public var drawingIsEmpty: (Data) -> Bool
    public var trailingLineFits: ((Page, TextBox) -> Bool)?
    public init(capacity: @escaping (Page, TextBox) throws -> Int, trailingDraft: Page? = nil,
                drawingIsEmpty: @escaping (Data) -> Bool = { $0.isEmpty }, trailingLineFits: ((Page, TextBox) -> Bool)? = nil) {
        self.capacity = capacity; self.trailingDraft = trailingDraft
        self.drawingIsEmpty = drawingIsEmpty; self.trailingLineFits = trailingLineFits
    }
}

/// Text editor 2: one change of the whole text, one undo step (or part of
/// one, while typing). Offsets are UTF-16 units of `Notebook.textFlowContent`.
public struct TextFlowChange: Equatable, Sendable {
    /// Ascending, in offsets of the text before the change.
    public var edits: [TextListEditing.Edit]
    public var style: TextBoxStyle?
    public var selection: NSRange
    public var selectionBefore: NSRange
    /// A step of its own; otherwise it joins the typing before it.
    public var separateStep: Bool
    public init(edits: [TextListEditing.Edit], style: TextBoxStyle? = nil, selection: NSRange, selectionBefore: NSRange, separateStep: Bool = false) {
        self.edits = edits; self.style = style; self.selection = selection
        self.selectionBefore = selectionBefore; self.separateStep = separateStep
    }
}

extension Notebook {
    /// The flow offset of `location` in the segment `boxID`.
    public func textFlowOffset(boxID: UUID, location: Int) -> Int? {
        var consumed = 0
        for segment in textFlowSegments {
            let length = (segment.box.text as NSString).length
            if segment.box.id == boxID { return consumed + min(max(0, location), length) }
            consumed += length
        }
        return nil
    }

    /// Segment and local place of a flow offset. A segment boundary belongs to
    /// the following text; behind the last character to the last written segment.
    public func textFlowPlace(at offset: Int) -> TextFlowPlace? {
        let segments = textFlowSegments
        var consumed = 0
        for segment in segments {
            let length = (segment.box.text as NSString).length
            if offset < consumed + length { return TextFlowPlace(pageID: segment.pageID, boxID: segment.box.id, location: max(0, offset - consumed)) }
            consumed += length
        }
        if let opened = pageAfterFinalBreak { return TextFlowPlace(pageID: opened.pageID, boxID: opened.box.id, location: 0) }
        guard let last = segments.last(where: { !$0.box.text.isEmpty }) ?? segments.first else { return nil }
        return TextFlowPlace(pageID: last.pageID, boxID: last.box.id, location: (last.box.text as NSString).length)
    }

    /// The local part of a flow range in every segment it touches, by box ID.
    public func textFlowParts(of range: NSRange) -> [UUID: NSRange] {
        var result: [UUID: NSRange] = [:], consumed = 0
        for segment in textFlowSegments {
            let length = (segment.box.text as NSString).length
            let part = NSIntersectionRange(range, NSRange(location: consumed, length: length))
            if part.length > 0 { result[segment.box.id] = NSRange(location: part.location - consumed, length: part.length) }
            consumed += length
        }
        return result
    }

    /// The complete paragraph(s) of a flow range, also across a page change.
    public func textFlowParagraph(of range: NSRange) -> NSRange? {
        guard let whole = textFlowContent else { return nil }
        let text = whole.text as NSString
        guard NSMaxRange(range) <= text.length else { return nil }
        return TextLines.paragraphRange(text, range)
    }

    /// Replaces a flow range (delete, type over, paste) and reflows from the
    /// page before it, so text moves back up over a page change. `caret`:
    /// flow offset afterwards, by default behind the replacement.
    public func editingTextFlow(range: NSRange, replacement: String, caret: Int? = nil,
                                layout: TextFlowLayout) throws -> (Notebook, TextFlowFocus) {
        try editingTextFlow([TextListEditing.Edit(range: range, replacement: replacement)], caret: caret, layout: layout)
    }

    /// Several replacements in ascending order as one change, formats between
    /// them stay (keyboard mode: `>`, `ms(` or several selections over pages).
    /// By default the caret goes behind the last replacement.
    public func editingTextFlow(_ edits: [TextListEditing.Edit], caret: Int? = nil,
                                layout: TextFlowLayout) throws -> (Notebook, TextFlowFocus) {
        let length = textFlowContent.map { ($0.text as NSString).length } ?? -1
        guard let whole = textFlowContent, let first = edits.first, let last = edits.last,
              edits.allSatisfy({ NSMaxRange($0.range) <= length }) else { throw TextFlowError.stale }
        let shift = edits.dropLast().reduce(0) { $0 + ($1.replacement as NSString).length - $1.range.length }
        let end = caret ?? (last.range.location + shift + (last.replacement as NSString).length)
        return try rewritingTextFlow(whole.applying(edits), from: first.range.location, selection: NSRange(location: end, length: 0), layout: layout)
    }

    /// Applies a format to a flow range over any number of pages; the text
    /// stays, a changed size reflows it.
    public func restylingTextFlow(range: NSRange, layout: TextFlowLayout,
                                  change: (inout TextBoxStyle) -> Void) throws -> (Notebook, TextFlowFocus) {
        guard let whole = textFlowContent, NSMaxRange(range) <= (whole.text as NSString).length else { throw TextFlowError.stale }
        var content = whole.restyled([range], change)
        if range.length == whole.text.utf16.count { change(&content.style) }
        return try rewritingTextFlow(content, from: range.location, selection: NSRange(location: range.location, length: 0), layout: layout)
    }

    /// Text editor 2: the buffer changed, the model follows. `style` is what
    /// typing wrote, without it the replacements take over their neighbour's
    /// format. The layout's page ranges come in through `layout.capacity`.
    public func changingTextFlow(_ change: TextFlowChange, layout: TextFlowLayout) throws -> (Notebook, TextFlowFocus) {
        let content = try changedTextFlow(change)
        return try rewritingTextFlow(content, from: change.edits[0].range.location, selection: change.selection, layout: layout)
    }

    /// The whole text with `change` in it.
    private func changedTextFlow(_ change: TextFlowChange) throws -> TextBox {
        let length = textFlowContent.map { ($0.text as NSString).length } ?? -1
        guard let whole = textFlowContent, !change.edits.isEmpty,
              change.edits.allSatisfy({ NSMaxRange($0.range) <= length }) else { throw TextFlowError.stale }
        var content = whole.applying(change.edits)
        if let style = change.style {
            var ranges: [NSRange] = [], shift = 0
            for edit in change.edits {
                let inserted = (edit.replacement as NSString).length
                if inserted > 0 { ranges.append(NSRange(location: edit.range.location + shift, length: inserted)) }
                shift += inserted - edit.range.length
            }
            content = content.restyled(ranges) { $0 = style }
            if content.text.isEmpty { content.style = style }
        }
        return content
    }

    /// Text editor 2: `changingTextFlow` found no room (page limit, no space).
    /// What was typed must not get lost: it stays where it was written, in the
    /// segments it touches, as an overflowing page does on the old path
    /// (`EditorModel.updateFlowText`); the text before and behind stays as it is.
    public func keepingTextFlowChange(_ change: TextFlowChange) throws -> (Notebook, TextFlowFocus) {
        let content = try changedTextFlow(change)
        let segments = textFlowSegments
        guard let edit = change.edits.first, let end = change.edits.map({ NSMaxRange($0.range) }).max(),
              !segments.isEmpty else { throw TextFlowError.stale }
        var first: Int?, last = segments.count - 1, firstStart = 0, lastEnd = 0, consumed = 0
        for (index, segment) in segments.enumerated() {
            let length = (segment.box.text as NSString).length
            if first == nil, edit.range.location < consumed + length || index == segments.count - 1 { first = index; firstStart = consumed }
            consumed += length; lastEnd = consumed
            if first != nil, end <= consumed { last = index; break }
        }
        guard let first else { throw TextFlowError.stale }
        let delta = (content.text as NSString).length - segments.reduce(0) { $0 + ($1.box.text as NSString).length }
        let kept = try content.fragment(NSRange(location: firstStart, length: lastEnd + delta - firstStart))
        var next = try editableForText(); next.schemaVersion = max(8, next.schemaVersion)
        for (index, segment) in segments.enumerated() where index >= first && index <= last {
            guard let page = next.pages.firstIndex(where: { $0.id == segment.pageID }) else { throw TextFlowError.stale }
            var boxes = next.pages[page].effectiveTextBoxes
            guard let box = boxes.firstIndex(where: { $0.id == segment.box.id }) else { throw TextFlowError.stale }
            boxes[box].text = index == first ? kept.text : ""
            boxes[box].runs = index == first ? kept.runs : nil
            next.pages[page].textBoxes = boxes
        }
        let touched = next.pages.flatMap { $0.textBoxes ?? [] }
        next.raiseSchemaForTextColors(touched)
        next.raiseSchemaForTextFields(touched)
        try next.validate()
        guard let focus = next.textFlowFocus(selection: change.selection) else { throw TextFlowError.stale }
        return (next, focus)
    }

    /// A caret at a flow offset as a focus (undo returns there).
    public func textFlowFocus(selection: NSRange) -> TextFlowFocus? {
        guard let place = textFlowPlace(at: selection.location), let content = textFlowContent else { return nil }
        let length = (content.text as NSString).length
        return TextFlowFocus(pageID: place.pageID, boxID: place.boxID, selection: NSRange(location: place.location, length: 0),
                             typingStyle: length == 0 ? content.style : content.style(at: min(selection.location, length - 1)))
    }

    /// An edit brings text back onto the page before only by changing the
    /// first word of a segment: that word was what no longer fit. Every other
    /// keystroke measures nothing for it.
    public static func reachesFirstWord(from old: String, to new: String) -> Bool {
        func wordEnd(_ text: NSString) -> Int {
            func space(_ index: Int) -> Bool {
                UnicodeScalar(text.character(at: index)).map(CharacterSet.whitespacesAndNewlines.contains) ?? false
            }
            var index = 0
            while index < text.length, space(index) { index += 1 }
            while index < text.length, !space(index) { index += 1 }
            return index
        }
        guard let changed = TextListEditing.changedRange(from: old, to: new) else { return false }
        return changed.location <= max(wordEnd(old as NSString), wordEnd(new as NSString))
    }

    /// The start of the segment `boxID` moves back onto the page before it, if
    /// it fits there now. Only that page is measured for this; nil: nothing
    /// moves. `selection`: flow offsets, the caret stays with its text.
    public func settlingTextFlow(boxID: UUID, selection: NSRange?, layout: TextFlowLayout) throws -> (Notebook, TextFlowFocus)? {
        let segments = textFlowSegments
        guard let index = segments.firstIndex(where: { $0.box.id == boxID }), index > 0, !segments[index].box.text.isEmpty,
              let page = pages.first(where: { $0.id == segments[index - 1].pageID }),
              let start = textFlowOffset(boxID: segments[index - 1].box.id, location: 0), let content = textFlowContent else { return nil }
        let previous = segments[index - 1].box, text = previous.text as NSString
        // A page break ends the page whatever room it has.
        guard text.length == 0 || text.character(at: text.length - 1) != TextLines.pageBreak,
              try layout.capacity(page, previous.appending(segments[index].box)) > text.length else { return nil }
        let tail = try content.fragment(NSRange(location: start, length: (content.text as NSString).length - start))
        var replacement = previous
        replacement.text = tail.text; replacement.runs = tail.runs
        let local = selection.map { NSRange(location: max(0, $0.location - start), length: $0.length) } ?? NSRange(location: 0, length: 0)
        let settled = try reflowText(pageID: segments[index - 1].pageID, previous: previous, replacement: replacement, selection: local,
            trailingDraft: layout.trailingDraft, drawingIsEmpty: layout.drawingIsEmpty,
            trailingLineFits: layout.trailingLineFits, holdsTail: true, pageCapacity: layout.capacity)
        // The caret left for a place before the rewritten part: it stays there.
        guard let selection, selection.location < start else { return settled }
        return (settled.0, settled.0.textFlowFocus(selection: selection) ?? settled.1)
    }

    /// Writes `content` as the whole flow. Pages before the change keep their
    /// segment untouched; the reflow stops where the stored segments fit again,
    /// so only the pages the change reaches are measured.
    private func rewritingTextFlow(_ content: TextBox, from offset: Int, selection: NSRange,
                                   layout: TextFlowLayout) throws -> (Notebook, TextFlowFocus) {
        let segments = textFlowSegments
        guard !segments.isEmpty else { throw TextFlowError.stale }
        var start = 0, consumed = 0
        for (index, segment) in segments.enumerated() {
            let length = (segment.box.text as NSString).length
            if offset < consumed + length || index == segments.count - 1 { start = index; break }
            consumed += length
        }
        if start > 0 { start -= 1; consumed -= (segments[start].box.text as NSString).length }
        let previous = segments[start].box
        let total = (content.text as NSString).length
        let tail = try content.fragment(NSRange(location: consumed, length: total - consumed))
        var replacement = previous
        replacement.text = tail.text; replacement.runs = tail.runs
        if tail.text.isEmpty { replacement.style = content.style }
        let local = NSRange(location: max(0, selection.location - consumed), length: selection.length)
        return try reflowText(pageID: segments[start].pageID, previous: previous, replacement: replacement, selection: local,
            trailingDraft: layout.trailingDraft, drawingIsEmpty: layout.drawingIsEmpty,
            trailingLineFits: layout.trailingLineFits, holdsTail: true, pageCapacity: layout.capacity)
    }
}
