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
        return text.paragraphRange(for: range)
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

    /// Writes `content` as the whole flow. Pages before the change keep their
    /// segment untouched; the later segments are emptied and filled again.
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
        var next = self
        for segment in segments[(start + 1)...] {
            guard let page = next.pages.firstIndex(where: { $0.id == segment.pageID }) else { throw TextFlowError.stale }
            var boxes = next.pages[page].effectiveTextBoxes
            guard let box = boxes.firstIndex(where: { $0.id == segment.box.id }) else { throw TextFlowError.stale }
            boxes[box].text = ""; boxes[box].runs = nil
            next.pages[page].textBoxes = boxes
        }
        let previous = segments[start].box
        let total = (content.text as NSString).length
        let tail = try content.fragment(NSRange(location: consumed, length: total - consumed))
        var replacement = previous
        replacement.text = tail.text; replacement.runs = tail.runs
        if tail.text.isEmpty { replacement.style = content.style }
        let local = NSRange(location: max(0, selection.location - consumed), length: selection.length)
        return try next.reflowText(pageID: segments[start].pageID, previous: previous, replacement: replacement, selection: local,
            trailingDraft: layout.trailingDraft, drawingIsEmpty: layout.drawingIsEmpty,
            trailingLineFits: layout.trailingLineFits, pageCapacity: layout.capacity)
    }
}
