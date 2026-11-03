import Foundation

// Text editor 2 (docs/TEXT-EDITOR-2.md): one input view and one text buffer
// over all pages of a text document. TextKit measures; everything that can be
// decided from its measurements is decided here, so it can be tested on Linux.

/// How a page takes lines. The rule of `TextFlowEditing.capacity`, asked
/// before a line is set instead of after: a line stays on the page while its
/// final bottom (after the ruling moved it) is at most 0.25 below `height`.
public struct DocumentPageRule: Equatable, Sendable {
    public static let slack = 0.25
    public var height: Double
    public var ruling: TextRuling?
    /// Page y of the container top (`Page.ruledTextOrigin`); nil: no ruling.
    public var origin: Double?
    /// `Page.ruledPageTop`: the first line may reach above the writing area.
    public var pageTop: Double?
    public init(height: Double, ruling: TextRuling? = nil, origin: Double? = nil, pageTop: Double? = nil) {
        self.height = height; self.ruling = ruling; self.origin = origin; self.pageTop = pageTop
    }
    /// Baseline in container coordinates; nil without ruling.
    public func baseline(top: Double, ascent: Double) -> Double? {
        guard let ruling, let origin else { return nil }
        return ruling.lineBaseline(top: top, ascent: ascent, origin: origin, pageTop: pageTop)
    }
    /// Bottom of a line of natural height `lineHeight` starting at `top`.
    public func lineBottom(top: Double, lineHeight: Double, ascent: Double) -> Double {
        guard let baseline = baseline(top: top, ascent: ascent) else { return top + lineHeight }
        return top + lineHeight + (baseline - top - ascent)
    }
    /// A page always takes its first line: text must go somewhere.
    public func fits(top: Double, lineHeight: Double, ascent: Double) -> Bool {
        top < 0.5 || lineBottom(top: top, lineHeight: lineHeight, ascent: ascent) <= height + Self.slack
    }
}

/// One laid-out line as TextKit measured it, in the coordinates of its page's
/// text container (no zoom, no page position).
public struct DocumentTextLine: Equatable, Sendable {
    public var page: Int
    /// Characters with the line break; empty for the line behind a final break.
    public var range: NSRange
    public var rect: PageRect
    public var used: PageRect
    public var baseline: Double
    public var ascent: Double
    public var descent: Double
    public init(page: Int, range: NSRange, rect: PageRect, used: PageRect, baseline: Double, ascent: Double, descent: Double) {
        self.page = page; self.range = range; self.rect = rect; self.used = used
        self.baseline = baseline; self.ascent = ascent; self.descent = descent
    }
    public var end: Int { NSMaxRange(range) }
    public var isExtra: Bool { range.length == 0 }
    public var bandTop: Double { baseline - ascent }
    public var bandHeight: Double { ascent + descent }

    /// The nearest caret place on this line: never behind a line break, and a
    /// wrapped line's end is the next line's start, so it stops before that.
    public func clamped(_ offset: Int, in text: NSString) -> Int {
        var last = end
        if range.length > 0, last < text.length || TextLines.isBreak(text.character(at: last - 1)) {
            last = max(range.location, text.previousBoundary(last))
        }
        return min(max(offset, range.location), last)
    }
}

/// Where a page's text stands on the viewport's zoomed surface.
public struct DocumentPageFrame: Equatable, Sendable {
    public var page: Int
    /// The sheet on the surface.
    public var sheet: PageRect
    /// Surface point of the text container's origin.
    public var origin: PagePoint
    public var scale: Double
    public init(page: Int, sheet: PageRect, origin: PagePoint, scale: Double) {
        self.page = page; self.sheet = sheet; self.origin = origin; self.scale = scale
    }
    /// `box`: the text area in page coordinates (`NotebookPagePlacement.surfaceRect`).
    public init(page: Int, placement: NotebookPagePlacement, box: PageRect) {
        let rect = placement.surfaceRect(for: box)
        self.init(page: page, sheet: placement.frame, origin: PagePoint(x: rect.x, y: rect.y), scale: placement.scale)
    }
    public func surface(_ point: PagePoint) -> PagePoint {
        PagePoint(x: origin.x + point.x * scale, y: origin.y + point.y * scale)
    }
    public func surface(_ rect: PageRect) -> PageRect {
        PageRect(x: origin.x + rect.x * scale, y: origin.y + rect.y * scale, width: rect.width * scale, height: rect.height * scale)
    }
    public func local(_ point: PagePoint) -> PagePoint {
        PagePoint(x: (point.x - origin.x) / scale, y: (point.y - origin.y) / scale)
    }
    /// Vertical distance of a surface y from the sheet; 0 on it.
    func distance(toY y: Double) -> Double {
        y < sheet.y ? sheet.y - y : max(0, y - (sheet.y + sheet.height))
    }
}

/// A rectangle of a selection on one page, in container coordinates.
public struct DocumentSelectionRect: Equatable, Sendable {
    public var page: Int
    public var rect: PageRect
    public var containsStart: Bool
    public var containsEnd: Bool
    public init(page: Int, rect: PageRect, containsStart: Bool, containsEnd: Bool) {
        self.page = page; self.rect = rect; self.containsStart = containsStart; self.containsEnd = containsEnd
    }
}

/// The caret on one page, in container coordinates.
public struct DocumentCaret: Equatable, Sendable {
    public var page: Int
    public var rect: PageRect
    public init(page: Int, rect: PageRect) { self.page = page; self.rect = rect }
}

/// What TextKit has to answer. Everything else follows from it (`extension`).
public protocol DocumentTextMetrics {
    var text: NSString { get }
    var pageCount: Int { get }
    /// The page of a caret at `offset`: a page boundary belongs to the
    /// following text, the end of the text to the last line.
    func page(of offset: Int) -> Int
    func lines(onPage page: Int) -> [DocumentTextLine]
    /// Left edge of the character at `offset`, container x.
    func x(of offset: Int, on line: DocumentTextLine) -> Double
    /// The caret place nearest to `x`.
    func offset(atX x: Double, on line: DocumentTextLine) -> Int
}

extension DocumentTextMetrics {
    public var textLength: Int { text.length }

    public func line(at offset: Int) -> DocumentTextLine? {
        let lines = lines(onPage: page(of: offset))
        return lines.first { offset >= $0.range.location && offset < $0.end } ?? lines.last
    }

    /// `band`: ascent and descent of the font at the caret, otherwise the line's.
    public func caret(at offset: Int, band: (ascent: Double, descent: Double)? = nil, width: Double = 2) -> DocumentCaret? {
        guard let line = line(at: offset) else { return nil }
        let ascent = band?.ascent ?? line.ascent, descent = band?.descent ?? line.descent
        return DocumentCaret(page: line.page, rect: PageRect(x: x(of: offset, on: line), y: line.baseline - ascent,
                                                             width: width, height: ascent + descent))
    }

    /// One rectangle per line, in text order. `pages`: limits the measuring
    /// to these pages; the first and the last page always count (the handles).
    public func selectionRects(_ range: NSRange, pages: Set<Int>? = nil) -> [DocumentSelectionRect] {
        guard range.length > 0 else { return [] }
        let first = page(of: range.location), last = max(first, page(of: NSMaxRange(range) - 1))
        var result: [DocumentSelectionRect] = []
        for index in first...last where pages == nil || index == first || index == last || pages?.contains(index) == true {
            for line in lines(onPage: index) {
                let part = NSIntersectionRange(range, line.range)
                guard part.length > 0 else { continue }
                let start = part.location == line.range.location ? line.used.x : x(of: part.location, on: line)
                let end = NSMaxRange(part) == line.end ? line.used.x + line.used.width : x(of: NSMaxRange(part), on: line)
                result.append(DocumentSelectionRect(page: index,
                    rect: PageRect(x: start, y: line.bandTop, width: max(end - start, 2), height: line.bandHeight),
                    containsStart: part.location == range.location, containsEnd: NSMaxRange(part) == NSMaxRange(range)))
            }
        }
        return result
    }

    /// The page nearest to a surface y.
    public func frame(nearest point: PagePoint, in frames: [DocumentPageFrame]) -> DocumentPageFrame? {
        frames.min { $0.distance(toY: point.y) < $1.distance(toY: point.y) }
    }

    /// The caret place at a surface point. A page behind the text gives the
    /// end of the text; below a page's last line the nearest place on it.
    public func offset(closestTo point: PagePoint, in frames: [DocumentPageFrame]) -> Int {
        guard let frame = frame(nearest: point, in: frames) else { return 0 }
        let local = frame.local(point), lines = lines(onPage: frame.page)
        guard let nearest = lines.min(by: { abs($0.rect.y + $0.rect.height / 2 - local.y) < abs($1.rect.y + $1.rect.height / 2 - local.y) }) else {
            return textLength
        }
        return offset(atX: local.x, on: nearest)
    }

    /// `lines` displayed lines away, over page changes; pages without text are
    /// skipped. `goal` is what this returned before (the x to keep). At the
    /// ends of the text it stays, with `overshoot` it goes to the very end.
    public func verticalTarget(from offset: Int, lines count: Int, goal: Double?, overshoot: Bool = false) -> (offset: Int, goal: Double) {
        var page = page(of: offset), onPage = lines(onPage: page)
        guard let start = onPage.firstIndex(where: { offset >= $0.range.location && offset < $0.end }) ?? onPage.indices.last else { return (offset, goal ?? 0) }
        var index = start
        let x = goal ?? self.x(of: offset, on: onPage[start])
        let step = count < 0 ? -1 : 1
        var moved = 0
        steps: for _ in 0..<abs(count) {
            if onPage.indices.contains(index + step) { index += step; moved += 1; continue }
            var next = page + step
            while (0..<pageCount).contains(next), lines(onPage: next).isEmpty { next += step }
            guard (0..<pageCount).contains(next) else { break steps }
            page = next; onPage = lines(onPage: page)
            index = step > 0 ? 0 : onPage.count - 1
            moved += 1
        }
        if moved < abs(count), overshoot { return (step > 0 ? textLength : 0, x) }
        return (moved == 0 ? offset : self.offset(atX: x, on: onPage[index]), x)
    }

    /// Start and end of the displayed line holding `offset`.
    public func lineBounds(at offset: Int) -> (start: Int, end: Int)? {
        line(at: offset).map { ($0.range.location, $0.clamped($0.end, in: text)) }
    }
}

/// Moves over the text itself (no layout).
public enum DocumentCaretMotion {
    public static func next(_ text: NSString, _ offset: Int) -> Int { text.nextBoundary(offset) }
    public static func previous(_ text: NSString, _ offset: Int) -> Int { text.previousBoundary(offset) }
    /// `offset` on a grapheme boundary (down).
    public static func aligned(_ text: NSString, _ offset: Int) -> Int { text.alignedDown(offset) }

    private static func isWord(_ text: NSString, _ index: Int) -> Bool {
        guard let scalar = UnicodeScalar(text.character(at: index)) else { return true } // a surrogate: emoji
        return CharacterSet.alphanumerics.contains(scalar)
    }
    /// ⌥→: behind the end of the next word.
    public static func wordForward(_ text: NSString, _ offset: Int) -> Int {
        var index = offset
        while index < text.length, !isWord(text, index) { index = text.nextBoundary(index) }
        while index < text.length, isWord(text, index) { index = text.nextBoundary(index) }
        return index
    }
    /// ⌥←: to the start of the previous word.
    public static func wordBackward(_ text: NSString, _ offset: Int) -> Int {
        var index = offset
        while index > 0, !isWord(text, text.previousBoundary(index)) { index = text.previousBoundary(index) }
        while index > 0, isWord(text, text.previousBoundary(index)) { index = text.previousBoundary(index) }
        return index
    }
    /// The selection after `range` became `length` long (autocorrection): a
    /// selection behind it moves along, one touching it goes behind the text.
    public static func selection(_ selection: NSRange, replacing range: NSRange, length: Int) -> NSRange {
        let delta = length - range.length
        if selection.location >= NSMaxRange(range) { return NSRange(location: selection.location + delta, length: selection.length) }
        if NSMaxRange(selection) <= range.location { return selection }
        return NSRange(location: range.location + length, length: 0)
    }
}

/// From the layout's page ranges to flow segments.
public enum DocumentPagination {
    /// Characters per page from measured lines: consecutive ranges, one per
    /// page; a page without lines holds nothing. A gap or an overlap in the
    /// measurement gives nil, such a result must not become segments.
    public static func pageRanges(lines: [DocumentTextLine], pageCount: Int, textLength: Int) -> [NSRange]? {
        var result: [NSRange] = [], offset = 0, line = 0
        for page in 0..<pageCount {
            var length = 0
            while line < lines.count, lines[line].page == page {
                guard lines[line].range.location == offset + length else { return nil }
                length += lines[line].range.length; line += 1
            }
            result.append(NSRange(location: offset, length: length))
            offset += length
        }
        guard line == lines.count, offset == textLength else { return nil }
        return result
    }

    /// The capacity of `TextFlowEditing.capacity` for a page that starts at
    /// `start`; nil: no page starts there, the layout is not this text.
    public static func capacity(start: Int, pages: [NSRange]) -> Int? {
        pages.first { $0.location == start }?.length
    }

    /// What `capacity` of the single-page layout takes: the end of the last
    /// line whose bottom fits. For comparing both ways of measuring.
    public static func capacity(lineBottoms lines: [(end: Int, bottom: Double)], height: Double) -> Int {
        var end = 0
        for line in lines {
            guard line.bottom <= height + DocumentPageRule.slack else { break }
            end = line.end
        }
        return end
    }

    public struct Deviation: Equatable, Sendable {
        public var page: Int
        public var layout: Int
        public var stored: Int
        public init(page: Int, layout: Int, stored: Int) { self.page = page; self.layout = layout; self.stored = stored }
    }
    /// Pages where the layout's length and the stored segment differ.
    public static func deviations(layout: [NSRange], stored: [Int]) -> [Deviation] {
        (0..<max(layout.count, stored.count)).compactMap { page in
            let measured = page < layout.count ? layout[page].length : 0
            let segment = page < stored.count ? stored[page] : 0
            return measured == segment ? nil : Deviation(page: page, layout: measured, stored: segment)
        }
    }
}

/// The pages the flow runs over: those holding a segment and every page behind
/// the last one (`reflowText` continues there). A page between segments
/// without one is skipped by the reflow, so it takes no text here either.
public enum DocumentPageSlots {
    public static func indices(in pages: [Page]) -> [Int] {
        let flow = pages.lazy.compactMap { $0.effectiveTextBoxes.first(where: { $0.flowID != nil })?.flowID }.first
        let carrying = pages.indices.filter { index in pages[index].effectiveTextBoxes.contains { $0.flowID == flow && flow != nil } }
        guard let last = carrying.last else { return [] }
        let behind = pages.indices.filter { $0 > last && pages[$0].pdfReference == nil && pages[$0].writingRect(.page) != nil }
        return carrying + behind
    }
}
