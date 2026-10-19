import Foundation

public enum TextFlowRegion: String, Codable, Sendable { case page, left, right, top, bottom }

public struct TextFlowFocus: Equatable, Sendable {
    public var requestID = UUID()
    public var pageID: UUID
    public var boxID: UUID
    public var selection: NSRange
    public var typingStyle: TextBoxStyle
    public init(pageID: UUID, boxID: UUID, selection: NSRange, typingStyle: TextBoxStyle) {
        self.pageID = pageID; self.boxID = boxID; self.selection = selection; self.typingStyle = typingStyle
    }
}

public enum TextFlowError: Error, LocalizedError {
    case stale, noSpace
    public var errorDescription: String? {
        switch self {
        case .stale: "Der Text wurde inzwischen geändert. Bitte das Feld erneut öffnen."
        case .noSpace: "Der Text passt nicht in den Schreibbereich. Er bleibt erhalten; bitte Schrift verkleinern oder Schreibraum vergrößern."
        }
    }
}

extension Page {
    /// Each writing margin is its own page-like text area. The PDF itself has
    /// no body area: a tap there creates an independent floating annotation.
    /// Text starts and ends where the ruled strokes do (32 pt left/right,
    /// `PDFExporter.drawPaper`); top and bottom keep 16 pt.
    public func writingRect(_ region: TextFlowRegion) -> PageRect? { writingRect(region, sideInset: 32) }
    /// Frame of flowing text created before Build 46 (16 pt on every side).
    /// Such boxes move to `writingRect` on their next edit.
    public func legacyWritingRect(_ region: TextFlowRegion) -> PageRect? { writingRect(region, sideInset: nil) }
    private func writingRect(_ region: TextFlowRegion, sideInset: Double?) -> PageRect? {
        let size = geometry?.displaySize ?? .a4
        let m = margins ?? PageMargins()
        let raw: PageRect = switch region {
        case .page: .init(x: 0, y: 0, width: size.width, height: size.height)
        case .left: .init(x: -m.left, y: 0, width: m.left, height: size.height)
        case .right: .init(x: size.width, y: 0, width: m.right, height: size.height)
        case .top: .init(x: 0, y: -m.top, width: size.width, height: m.top)
        case .bottom: .init(x: 0, y: size.height, width: size.width, height: m.bottom)
        }
        let scale = region == .page ? 1 : writingCoordinateScale
        let inset = min(16 * scale, raw.width * 0.06, raw.height * 0.06)
        guard raw.width - 2 * inset >= max(1, 40 * scale), raw.height - 2 * inset >= max(1, 24 * scale) else { return nil }
        // Narrow regions where the line start leaves too little room keep the old inset.
        let side = sideInset.map { max(inset, $0 * scale) }.flatMap { raw.width - 2 * $0 >= 40 * scale ? $0 : nil } ?? inset
        return .init(x: raw.x + side, y: raw.y + inset, width: raw.width - 2 * side, height: raw.height - 2 * inset)
    }
    public func writingRegion(at point: PagePoint, hasPDF: Bool) -> TextFlowRegion? {
        let size = geometry?.displaySize ?? .a4
        let region: TextFlowRegion
        if point.x < 0 { region = .left }
        else if point.x >= size.width { region = .right }
        else if point.y < 0 { region = .top }
        else if point.y >= size.height { region = .bottom }
        else if !hasPDF { region = .page }
        else { return nil }
        return writingRect(region) == nil ? nil : region
    }
}

extension TextBox {
    /// Slice UTF-16 runs while preserving grapheme clusters and all formatting.
    public func fragment(_ range: NSRange) throws -> TextBox {
        let source = text as NSString
        guard range.location >= 0, range.length >= 0, range.location <= source.length,
              range.length <= source.length - range.location else { throw TextFlowError.noSpace }
        let safe = source.rangeOfComposedCharacterSequences(for: range)
        guard range.length == 0 || safe == range else { throw TextFlowError.noSpace }
        var result = self; result.text = source.substring(with: range)
        result.runs = runs.map { runs in runs.compactMap { run in
            let part = NSIntersectionRange(range, NSRange(location: run.location, length: run.length))
            return part.length == 0 ? nil : TextRun(location: part.location - range.location, length: part.length, style: run.style)
        } }
        return result
    }
    public func appending(_ other: TextBox) -> TextBox {
        var result = self
        let offset = (text as NSString).length
        func completeRuns(_ box: TextBox) -> [TextRun] {
            let length = (box.text as NSString).length
            var result: [TextRun] = [], end = 0
            for run in box.runs ?? [] {
                if run.location > end { result.append(TextRun(location: end, length: run.location - end, style: box.style)) }
                result.append(run); end = run.location + run.length
            }
            if end < length { result.append(TextRun(location: end, length: length - end, style: box.style)) }
            return result
        }
        let first = completeRuns(self), second = completeRuns(other)
        result.text += other.text
        result.runs = first + second.map { TextRun(location: offset + $0.location, length: $0.length, style: $0.style) }
        return result
    }
}

extension Notebook {
    public func writingDraft(id: UUID = UUID()) -> Page {
        let defaults = appearance ?? NotebookAppearance()
        var page = Page(); page.id = id; page.paper = defaults.paper
        page.paperColor = defaults.color; page.geometry = defaults.geometry
        if appearance == nil, let previous = pages.last(where: { $0.pdfReference == nil && $0.paper != .legacyTest }), let style = previous.paper {
            page.paper = style; page.paperColor = previous.paperColor ?? .white
            page.geometry = previous.geometry ?? defaults.geometry
        }
        return page
    }
    public mutating func materializeWritingDraft(_ page: Page) throws {
        if pages.contains(where: { $0.id == page.id }) { return }
        guard page.pdfReference == nil, page.paper != nil, page.margins == nil else { throw StorageError.invalidDocument }
        guard pages.count < 500 else { throw PageOperationError.pageLimit }
        var next = try preparedForTextEditing(); next.schemaVersion = max(7, next.schemaVersion)
        next.pages.append(page)
        if page.effectiveTextBoxes.contains(where: \.usesTextFlowFormat) { next.schemaVersion = max(8, next.schemaVersion) }
        next.raiseSchemaForTextColors(page.effectiveTextBoxes)
        try next.validate(); self = next
    }

    /// Reflows only the edited segment and its following linked segments. The
    /// caller supplies native glyph capacity; the complete candidate validates
    /// before publication. No existing page or other content is ever deleted.
    public func reflowText(pageID: UUID, previous: TextBox, replacement: TextBox, selection: NSRange,
                           trailingDraft: Page? = nil, capacity: (TextBox) throws -> Int) throws -> (Notebook, TextFlowFocus) {
        try reflowText(pageID: pageID, previous: previous, replacement: replacement, selection: selection,
            trailingDraft: trailingDraft, pageCapacity: { _, box in try capacity(box) })
    }

    public func reflowText(pageID: UUID, previous: TextBox, replacement: TextBox, selection: NSRange,
                           trailingDraft: Page? = nil, pageCapacity: (Page, TextBox) throws -> Int) throws -> (Notebook, TextFlowFocus) {
        guard let start = pages.firstIndex(where: { $0.id == pageID }),
              pages[start].effectiveTextBoxes.contains(previous), previous.id == replacement.id,
              let flow = replacement.flowID, let region = replacement.flowRegion,
              flow == previous.flowID, region == previous.flowRegion else { throw TextFlowError.stale }
        var next = try preparedForTextEditing(); next.schemaVersion = max(8, next.schemaVersion)
        var text = replacement
        let existing = next.pages.indices.filter { $0 >= start }.compactMap { index -> (UUID, TextBox)? in
            guard let box = next.pages[index].effectiveTextBoxes.first(where: { $0.flowID == flow }) else { return nil }
            return (next.pages[index].id, box)
        }
        for (_, box) in existing.dropFirst() { text = text.appending(box) }
        guard selection.location >= 0, selection.length >= 0, selection.location <= (replacement.text as NSString).length,
              selection.length <= (replacement.text as NSString).length - selection.location else { throw TextFlowError.stale }
        var selection = selection
        // Numbering continues across pages: earlier segments give the open runs.
        if let changed = TextListEditing.changedRange(from: previous.text, to: replacement.text) {
            let earlier = next.pages[..<start].compactMap { $0.effectiveTextBoxes.first { $0.flowID == flow } }
            func ends(_ box: TextBox) -> Bool? {
                let value = box.text as NSString
                return value.length == 0 ? nil : [10, 13, 0x2028, 0x2029].contains(value.character(at: value.length - 1))
            }
            let continuation = earlier.last(where: { ends($0) != nil }).map { ends($0) == false } ?? false
            func earlierContext() -> TextListEditing.ListContext {
                var context = TextListEditing.ListContext(), open = false
                for box in earlier {
                    context = TextListEditing.context(after: box.text, level: box.listLevel(at:), continuation: open, from: context)
                    if let ended = ends(box) { open = !ended }
                }
                return context
            }
            let edits = TextListEditing.normalize(text.text, level: text.listLevel(at:), changed: changed,
                restart: TextListEditing.numberedItem(in: previous.text, at: changed.location, level: previous.listLevel(at:), continuation: continuation),
                context: earlierContext(), continuation: continuation)
            if !edits.isEmpty { text = text.applying(edits); selection = TextListEditing.selection(selection, after: edits) }
        }
        let total = (text.text as NSString).length
        var consumed = 0, nodeIndex = 0, currentIndex = start
        var continuationRegion = region
        var focus: TextFlowFocus?
        repeat {
            var box: TextBox
            if nodeIndex < existing.count {
                guard let index = next.pages.firstIndex(where: { $0.id == existing[nodeIndex].0 }) else { throw TextFlowError.stale }
                currentIndex = index; box = existing[nodeIndex].1
                continuationRegion = box.flowRegion ?? .page
                // Older flow text started 16 pt left of the ruled lines: align it.
                if let legacy = next.pages[index].legacyWritingRect(continuationRegion),
                   let rect = next.pages[index].writingRect(continuationRegion), legacy != rect,
                   abs(box.x - legacy.x) < 0.01, abs(box.width - legacy.width) < 0.01 {
                    box.x = rect.x; box.width = rect.width
                }
            } else {
                let after = currentIndex + 1
                let canReuse = next.pages.indices.contains(after) && next.pages[after].drawing.isEmpty
                    && (next.pages[after].images ?? []).isEmpty && (next.pages[after].shapes ?? []).isEmpty
                    && next.pages[after].effectiveTextBoxes.isEmpty
                    && (continuationRegion != .page || next.pages[after].pdfReference == nil)
                    && next.pages[after].writingRect(continuationRegion) != nil
                if canReuse { currentIndex = after }
                else {
                    guard next.pages.count < 500 else { throw PageOperationError.pageLimit }
                    // Continue beside the next worksheet when it has that margin;
                    // otherwise insert a clean writing page without changing PDFs.
                    let draftID = trailingDraft?.id
                    let mayUseDraft = after == next.pages.count && draftID.map { id in !next.pages.contains(where: { $0.id == id }) } == true
                    var page = next.writingDraft(id: mayUseDraft ? draftID! : UUID())
                    // A margin without a matching next margin continues onto a
                    // normal writing page. Paper pages cannot have PDF margins.
                    continuationRegion = .page
                    if continuationRegion == region, let previousPaper = next.pages[currentIndex].paper,
                       previousPaper != .legacyTest {
                        page.paper = previousPaper; page.paperColor = next.pages[currentIndex].paperColor
                        page.geometry = next.pages[currentIndex].geometry
                    }
                    next.pages.insert(page, at: after); currentIndex = after
                }
                guard let rect = next.pages[currentIndex].writingRect(continuationRegion) else { throw TextFlowError.noSpace }
                box = TextBox(x: rect.x, y: rect.y, width: rect.width, height: rect.height, style: replacement.style)
                box.flowID = flow; box.flowRegion = continuationRegion
            }
            let remainder = try text.fragment(NSRange(location: consumed, length: total - consumed))
            var candidate = box; candidate.text = remainder.text; candidate.runs = remainder.runs
            let count = min(total - consumed, max(0, try pageCapacity(next.pages[currentIndex], candidate)))
            guard count > 0 || consumed == total else { throw TextFlowError.noSpace }
            let part = try remainder.fragment(NSRange(location: 0, length: count))
            box.text = part.text; box.runs = part.runs
            // Keep the chosen insertion attributes for an empty continuation.
            if box.text.isEmpty { box.style = replacement.style }
            var boxes = next.pages[currentIndex].effectiveTextBoxes
            if let i = boxes.firstIndex(where: { $0.id == box.id }) { boxes[i] = box } else { boxes.append(box) }
            next.pages[currentIndex].textBoxes = boxes
            let caret = selection.location
            if focus == nil, caret < consumed + count || (caret == total && consumed + count == total) {
                focus = TextFlowFocus(pageID: next.pages[currentIndex].id, boxID: box.id,
                    selection: NSRange(location: min(count, max(0, caret - consumed)),
                        length: min(selection.length, max(0, consumed + count - caret))), typingStyle: replacement.style)
            }
            consumed += count; nodeIndex += 1
        } while consumed < total || nodeIndex < existing.count
        next.raiseSchemaForTextColors(next.pages.flatMap { $0.textBoxes ?? [] })
        try next.validate()
        return (next, focus ?? TextFlowFocus(pageID: pageID, boxID: replacement.id, selection: .init(location: 0, length: 0), typingStyle: replacement.style))
    }
}
