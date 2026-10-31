import UIKit
import NotebookCore
import OSLog

/// One page of the shared layout. TextKit moves a line to the next container
/// when this returns an empty rectangle, before the ruling has moved the line;
/// `DocumentPageRule` therefore asks with the moved bottom, the height of the
/// container itself never decides. On a line of mixed fonts the ascent is an
/// estimate from the proposed height: a bigger font proposes again.
final class DocumentPageContainer: NSTextContainer {
    nonisolated(unsafe) var index = 0
    nonisolated(unsafe) var rule = DocumentPageRule(height: 0)
    /// Room for a line that the rule refuses, not the container (largest font).
    static let spare: CGFloat = 240
    override var isSimpleRectangularTextContainer: Bool { false }
    override func lineFragmentRect(forProposedRect proposedRect: CGRect, at characterIndex: Int, writingDirection baseWritingDirection: NSWritingDirection,
                                   remaining remainingRect: UnsafeMutablePointer<CGRect>?) -> CGRect {
        let rect = super.lineFragmentRect(forProposedRect: proposedRect, at: characterIndex, writingDirection: baseWritingDirection, remaining: remainingRect)
        guard !rect.isEmpty else { return rect }
        var descender: CGFloat = -3, ascender: CGFloat = 11
        if let storage = layoutManager?.textStorage, storage.length > 0,
           let font = storage.attribute(.font, at: min(characterIndex, storage.length - 1), effectiveRange: nil) as? UIFont {
            descender = font.descender; ascender = font.ascender
        }
        let ascent = max(ascender, proposedRect.height + descender)
        return rule.fits(top: Double(proposedRect.minY), lineHeight: Double(proposedRect.height), ascent: Double(ascent)) ? rect : .zero
    }
}

/// `RuledTextLayout` over many pages: each container has its own ruling.
@MainActor
final class DocumentRuledLayout: NSObject, @preconcurrency NSLayoutManagerDelegate {
    func layoutManager(_ layoutManager: NSLayoutManager, shouldSetLineFragmentRect rect: UnsafeMutablePointer<CGRect>,
                       lineFragmentUsedRect used: UnsafeMutablePointer<CGRect>, baselineOffset: UnsafeMutablePointer<CGFloat>,
                       in textContainer: NSTextContainer, forGlyphRange glyphRange: NSRange) -> Bool {
        guard let page = textContainer as? DocumentPageContainer,
              let baseline = page.rule.baseline(top: Double(rect.pointee.minY), ascent: Double(baselineOffset.pointee)) else { return false }
        let delta = CGFloat(baseline) - rect.pointee.minY - baselineOffset.pointee
        rect.pointee.size.height += delta
        used.pointee.size.height += delta
        baselineOffset.pointee += delta
        return true
    }
    /// The next page's container takes the text behind a page break.
    func layoutManager(_ layoutManager: NSLayoutManager, shouldUse action: NSLayoutManager.ControlCharacterAction,
                       forControlCharacterAt charIndex: Int) -> NSLayoutManager.ControlCharacterAction {
        guard let storage = layoutManager.textStorage, charIndex < storage.length,
              (storage.string as NSString).character(at: charIndex) == TextLines.pageBreak else { return action }
        return .containerBreak
    }
}

/// A page the flow can stand on.
struct DocumentPageSlot: Equatable {
    var pageID: UUID
    var rule: DocumentPageRule
    /// The text area on the page (page coordinates).
    var box: PageRect
    /// Nil until the viewport has placed the page (a page the text just opened).
    var frame: DocumentPageFrame?

    init(page: Page, index: Int, placement: NotebookPagePlacement?) {
        // A page behind the text has no segment yet: the one the reflow would write.
        var segment = page.effectiveTextBoxes.first(where: { $0.flowID != nil }) ?? {
            let rect = page.writingRect(.page) ?? PageRect(x: 32, y: 16, width: 531, height: 810)
            var box = TextBox(x: rect.x, y: rect.y, width: rect.width, height: rect.height, style: TextBoxStyle())
            box.flowID = UUID(); box.flowRegion = .page
            return box
        }()
        segment.text = ""
        pageID = page.id
        box = PageRect(x: segment.x, y: segment.y, width: segment.width, height: segment.height)
        rule = DocumentPageRule(height: segment.height, ruling: page.textRuling(for: segment),
                                origin: page.ruledTextOrigin(for: segment).map { Double($0) },
                                pageTop: page.ruledPageTop(for: segment).map { Double($0) })
        frame = placement.map { DocumentPageFrame(page: index, placement: $0, box: box) }
    }
}

/// The whole text of a text document: one storage, one layout manager and one
/// container per page. `Notebook` stays what is saved; this is its working copy
/// for layout and input. Only measures and draws, the rules are in Core.
@MainActor
final class DocumentTextStore: @preconcurrency DocumentTextMetrics {
    let storage = NSTextStorage()
    let manager = TaskLayoutManager()
    private let ruling = DocumentRuledLayout()
    private(set) var containers: [DocumentPageContainer] = []
    private(set) var slots: [DocumentPageSlot] = []
    /// Fonts of the empty line behind a final break (typing attributes).
    var typingFont: UIFont = .systemFont(ofSize: 14)
    private var lineCache: [Int: [DocumentTextLine]] = [:]
    private let rasters = NSHashTable<DocumentPageRaster>.weakObjects()
    private static let log = Logger(subsystem: "de.la.noty", category: "text-editor2")

    init() {
        storage.addLayoutManager(manager)
        manager.delegate = ruling
        manager.drawsNatively = false // only the rasters draw
        manager.onDisplayChange = { [weak self] in self?.redraw() }
    }

    func add(_ raster: DocumentPageRaster) { rasters.add(raster) }
    func redraw() { rasters.allObjects.forEach { $0.setNeedsDisplay() } }

    // MARK: Pages

    private func size(of slot: DocumentPageSlot) -> CGSize {
        CGSize(width: slot.box.width, height: slot.box.height + DocumentPageContainer.spare)
    }
    func configure(_ slots: [DocumentPageSlot]) {
        guard slots != self.slots else { return }
        var firstChanged: Int?
        for (index, slot) in slots.enumerated() {
            if index < containers.count {
                let container = containers[index]
                guard container.rule != slot.rule || container.size != size(of: slot) else { continue }
                // Everything from this page on stands elsewhere now.
                firstChanged = firstChanged ?? index
                container.rule = slot.rule; container.size = size(of: slot)
            } else { addContainer(slot) }
        }
        while containers.count > slots.count {
            manager.removeTextContainer(at: containers.count - 1)
            containers.removeLast()
        }
        self.slots = slots
        if firstChanged != nil {
            manager.invalidateLayout(forCharacterRange: NSRange(location: 0, length: storage.length), actualCharacterRange: nil)
        }
        lineCache.removeAll()
    }
    private func addContainer(_ slot: DocumentPageSlot) {
        let container = DocumentPageContainer(size: size(of: slot))
        container.lineFragmentPadding = 0
        container.index = containers.count
        container.rule = slot.rule
        manager.addTextContainer(container)
        containers.append(container)
    }
    func slot(of offset: Int) -> DocumentPageSlot? {
        let index = page(of: offset)
        return slots.indices.contains(index) ? slots[index] : nil
    }
    var frames: [DocumentPageFrame] { slots.compactMap(\.frame) }

    // MARK: Text

    var string: String { storage.string }
    func load(_ value: NSAttributedString) {
        storage.setAttributedString(value)
        lineCache.removeAll()
    }
    func replace(_ range: NSRange, with value: NSAttributedString) {
        storage.replaceCharacters(in: range, with: value)
        lineCache.removeAll()
    }
    func setAttributes(_ attributes: [NSAttributedString.Key: Any], range: NSRange) {
        storage.setAttributes(attributes, range: range)
        lineCache.removeAll()
    }
    /// Keyboard mode: `edits` in text order, each in the format at its place.
    func apply(_ edits: [TextListEditing.Edit], fallback: [NSAttributedString.Key: Any]) {
        storage.beginEditing()
        for edit in edits.reversed() {
            // The neighbour `TextBox.applying` takes the format from.
            let anchor = edit.range.length > 0 || edit.range.location == 0 ? edit.range.location : edit.range.location - 1
            let attributes = storage.length > 0 ? storage.attributes(at: min(anchor, storage.length - 1), effectiveRange: nil) : fallback
            storage.replaceCharacters(in: edit.range, with: NSAttributedString(string: edit.replacement, attributes: attributes))
        }
        storage.endEditing()
        lineCache.removeAll()
    }
    /// The format typing continues in at a caret.
    func attributes(at offset: Int) -> [NSAttributedString.Key: Any]? {
        let text = storage.string as NSString
        if offset > 0, offset <= text.length, !TextLines.isBreak(text.character(at: offset - 1)) {
            return storage.attributes(at: offset - 1, effectiveRange: nil)
        }
        return offset < text.length ? storage.attributes(at: offset, effectiveRange: nil) : nil
    }

    // MARK: DocumentTextMetrics

    var text: NSString { storage.string as NSString }
    var pageCount: Int { containers.count }

    func page(of offset: Int) -> Int {
        guard !containers.isEmpty else { return 0 }
        let length = storage.length
        if offset >= length {
            // The line behind a final break exists only after the end was laid out.
            if length == 0 { manager.ensureLayout(for: containers[0]) }
            else { manager.ensureLayout(forCharacterRange: NSRange(location: length - 1, length: 1)) }
            if let extra = manager.extraLineFragmentTextContainer as? DocumentPageContainer { return extra.index }
            if let opened = pageAfterFinalBreak { return opened }
        }
        guard length > 0, manager.numberOfGlyphs > 0 else { return 0 }
        let glyph = manager.glyphIndexForCharacter(at: min(offset, length - 1))
        return (manager.textContainer(forGlyphAt: min(glyph, manager.numberOfGlyphs - 1), effectiveRange: nil) as? DocumentPageContainer)?.index ?? containers.count - 1
    }

    func lines(onPage page: Int) -> [DocumentTextLine] {
        guard containers.indices.contains(page) else { return [] }
        if let cached = lineCache[page] { return cached }
        let container = containers[page]
        let opened = pageAfterFinalBreak
        let glyphs = manager.glyphRange(for: container)
        var result: [DocumentTextLine] = []
        if glyphs.length > 0 {
            manager.enumerateLineFragments(forGlyphRange: glyphs) { [self] rect, used, _, lineGlyphs, _ in
                result.append(measuredLine(page: page, rect: rect, used: used, glyphs: lineGlyphs))
            }
        }
        if manager.extraLineFragmentTextContainer === container {
            let extra = manager.extraLineFragmentRect, font = typingFont
            let ascent = Double(font.ascender), descent = Double(-font.descender)
            let baseline = container.rule.baseline(top: Double(extra.minY), ascent: ascent) ?? Double(extra.minY) + ascent
            result.append(DocumentTextLine(page: page, range: NSRange(location: storage.length, length: 0),
                rect: PageRect(extra), used: PageRect(x: Double(extra.minX), y: Double(extra.minY), width: 0, height: Double(extra.height)),
                baseline: baseline, ascent: ascent, descent: descent))
        } else if page == opened {
            // The caret's line behind a final page break, where TextKit knows none.
            let font = typingFont, height = Double(font.lineHeight)
            let ascent = Double(font.ascender), descent = Double(-font.descender)
            result.append(DocumentTextLine(page: page, range: NSRange(location: storage.length, length: 0),
                rect: PageRect(x: 0, y: 0, width: Double(container.size.width), height: height),
                used: PageRect(x: 0, y: 0, width: 0, height: height),
                baseline: container.rule.baseline(top: 0, ascent: ascent) ?? ascent, ascent: ascent, descent: descent))
        }
        lineCache[page] = result
        return result
    }
    /// The page a final page break opens, if the layout has it.
    private var pageAfterFinalBreak: Int? {
        let length = storage.length
        guard length > 0, (storage.string as NSString).character(at: length - 1) == TextLines.pageBreak else { return nil }
        let glyph = manager.glyphIndexForCharacter(at: length - 1)
        guard let page = (manager.textContainer(forGlyphAt: glyph, effectiveRange: nil) as? DocumentPageContainer)?.index,
              page + 1 < containers.count else { return nil }
        return page + 1
    }
    /// TextKit spans a fragment over the gap up to the previous ruled line:
    /// the band runs ascender to descender around the baseline, as in `PageTextView`.
    private func measuredLine(page: Int, rect: CGRect, used: CGRect, glyphs: NSRange) -> DocumentTextLine {
        let characters = manager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        var reference = glyphs.location
        storage.enumerateAttribute(.baselineOffset, in: characters) { value, range, stop in
            guard ((value as? NSNumber)?.doubleValue ?? 0) == 0 else { return }
            reference = manager.glyphIndexForCharacter(at: range.location); stop.pointee = true
        }
        var ascender: CGFloat = 0, descender: CGFloat = 0
        storage.enumerateAttribute(.font, in: characters) { value, _, _ in
            guard let font = value as? UIFont else { return }
            ascender = max(ascender, font.ascender); descender = max(descender, -font.descender)
        }
        return DocumentTextLine(page: page, range: characters, rect: PageRect(rect), used: PageRect(used),
            baseline: Double(rect.minY + manager.location(forGlyphAt: reference).y), ascent: Double(ascender), descent: Double(descender))
    }
    func x(of offset: Int, on line: DocumentTextLine) -> Double {
        guard !line.isExtra else { return line.rect.x }
        guard offset < line.end, offset < storage.length else { return line.used.x + line.used.width }
        let glyph = manager.glyphIndexForCharacter(at: offset)
        return Double(manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minX + manager.location(forGlyphAt: glyph).x)
    }
    func offset(atX x: Double, on line: DocumentTextLine) -> Int {
        guard !line.isExtra, containers.indices.contains(line.page) else { return line.range.location }
        var fraction: CGFloat = 0
        let index = manager.characterIndex(for: CGPoint(x: x, y: line.baseline), in: containers[line.page],
                                           fractionOfDistanceBetweenInsertionPoints: &fraction)
        let text = self.text, target = fraction > 0.5 ? index + 1 : index
        return line.clamped(DocumentCaretMotion.aligned(text, target), in: text)
    }

    // MARK: Layout as the model's pagination

    func pageRange(_ page: Int) -> NSRange {
        manager.characterRange(forGlyphRange: manager.glyphRange(for: containers[page]), actualGlyphRange: nil)
    }
    /// `TextFlowEditing.capacity` from the shared layout: `box` holds all the
    /// text from its page on, so its length says where that page starts. Nil
    /// when this is not the layout's text (a reflow renumbered a list): the
    /// model then measures itself. A page the layout does not have yet joins here.
    func capacity(page: Page, box: TextBox) -> Int? {
        let length = storage.length, start = length - (box.text as NSString).length
        guard start >= 0 else { return nil }
        guard start < length else { return 0 }
        let glyph = manager.glyphIndexForCharacter(at: start)
        var container = manager.textContainer(forGlyphAt: glyph, effectiveRange: nil) as? DocumentPageContainer
        if container == nil {
            slots.append(DocumentPageSlot(page: page, index: containers.count, placement: nil))
            addContainer(slots[slots.count - 1])
            container = manager.textContainer(forGlyphAt: glyph, effectiveRange: nil) as? DocumentPageContainer
        }
        guard let container, DocumentPagination.capacity(start: start, pages: [pageRange(container.index)]) != nil else { return nil }
        // The measured lines decide, by the rule of `TextFlowEditing.capacity`:
        // the container's rule estimated a mixed line, a segment must never overflow.
        let lines = lines(onPage: container.index).filter { !$0.isExtra }.map { (end: $0.end - start, bottom: $0.rect.y + $0.rect.height) }
        var count = DocumentPagination.capacity(lineBottoms: lines, height: container.rule.height)
        let text = self.text
        if start + count < length, count > 0 {
            let cluster = text.rangeOfComposedCharacterSequence(at: start + count)
            if cluster.location < start + count { count = cluster.location - start }
        }
        return count
    }
    /// Diagnose: where the shared layout breaks elsewhere than the stored segments.
    func logDeviations(_ boxes: [TextBox]) {
        guard HangProbe.isInstalled else { return }
        let stored = boxes.map { ($0.text as NSString).length }
        let measured = stored.indices.filter(containers.indices.contains).map(pageRange)
        for item in DocumentPagination.deviations(layout: measured, stored: stored) {
            Self.log.notice("[noty.editor2] page=\(item.page, privacy: .public) layout=\(item.layout, privacy: .public) stored=\(item.stored, privacy: .public)")
        }
    }

    // MARK: Drawing

    /// `area`: part of the page in container coordinates; `origin`: the
    /// container's origin in the drawing coordinates.
    func draw(page: Int, area: CGRect, origin: CGPoint) {
        guard containers.indices.contains(page) else { return }
        manager.rasterPass = true
        defer { manager.rasterPass = false; manager.lastRaster = CACurrentMediaTime() }
        let glyphs = manager.glyphRange(forBoundingRect: area, in: containers[page])
        guard glyphs.length > 0 else { return }
        manager.drawBackground(forGlyphRange: glyphs, at: origin)
        manager.drawGlyphs(forGlyphRange: glyphs, at: origin)
    }
}

/// A page's text at the zoomed resolution, inside the sheet's text layer: above
/// the ink and below the free fields, as `TextRasterView` is. Selection and
/// caret are not drawn here but on `DocumentTextSurface`, over all pages.
@MainActor
final class DocumentPageRaster: UIView {
    weak var store: DocumentTextStore?
    var page: Int?
    /// The container's origin in the superview.
    var textOrigin = CGPoint.zero
    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false; isOpaque = false; backgroundColor = .clear
        // Same appearance as the text views (dynamic marker colours, `.label`).
        overrideUserInterfaceStyle = .dark
        isAccessibilityElement = false
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ rect: CGRect) {
        guard let store, let page else { return }
        store.draw(page: page, area: rect.offsetBy(dx: frame.minX - textOrigin.x, dy: frame.minY - textOrigin.y),
                   origin: CGPoint(x: textOrigin.x - frame.minX, y: textOrigin.y - frame.minY))
    }
}
