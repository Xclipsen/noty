import UIKit
import CoreText
import NotebookCore

/// Draw task markers as vectors without changing stored text or typing attributes.
/// In the editor the text is drawn by `TextRasterView` at the zoomed resolution;
/// the native text view then draws nothing itself (`drawsNatively == false`).
@MainActor
final class TaskLayoutManager: NSLayoutManager {
    // NSLayoutManager calls its overrides outside Swift's actor checking; the
    // editor and all renderers use it on the main thread only.
    nonisolated(unsafe) var drawsNatively = true
    /// Set while `TextRasterView` draws; `lastRaster` when it finished.
    nonisolated(unsafe) var rasterPass = false
    nonisolated(unsafe) var lastRaster: CFTimeInterval = 0
    /// Text, attributes or layout changed: the raster must redraw.
    nonisolated(unsafe) var onDisplayChange: (@MainActor () -> Void)?
    nonisolated private var suppressed: Bool { !drawsNatively && !rasterPass }
    nonisolated private func displayChanged() {
        guard !drawsNatively, !rasterPass, Thread.isMainThread, let callback = onDisplayChange else { return }
        MainActor.assumeIsolated { callback() }
    }
    override func processEditing(for textStorage: NSTextStorage, edited editMask: NSTextStorage.EditActions, range newCharRange: NSRange,
                                 changeInLength delta: Int, invalidatedRange invalidatedCharRange: NSRange) {
        // Before the layout of the edit: a prefix may have changed (`HangingTextContainer`).
        for case let container as HangingTextContainer in textContainers { container.resetHangingIndents() }
        super.processEditing(for: textStorage, edited: editMask, range: newCharRange, changeInLength: delta, invalidatedRange: invalidatedCharRange)
        displayChanged()
    }
    override func invalidateDisplay(forGlyphRange glyphRange: NSRange) {
        super.invalidateDisplay(forGlyphRange: glyphRange); displayChanged()
    }
    /// The native view still asks to draw after each change. Normally the raster
    /// (below it, same display pass) has just redrawn; otherwise this is a
    /// change no other hook saw, and the raster follows in the next frame.
    nonisolated private func nativeDrawRequested() {
        if CACurrentMediaTime() - lastRaster > 0.004 { displayChanged() }
    }
    nonisolated(unsafe) private var backgroundOrigin = CGPoint.zero
    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: CGPoint) {
        if suppressed { nativeDrawRequested(); return }
        backgroundOrigin = origin
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
    }
    /// Highlights cover the glyphs (ascender to descender), not the whole line
    /// fragment: ruled paper and large styles add space above the text.
    override func fillBackgroundRectArray(_ rectArray: UnsafePointer<CGRect>, count rectCount: Int,
                                          forCharacterRange charRange: NSRange, color: UIColor) {
        guard let storage = textStorage, rectCount > 0, charRange.length > 0, NSMaxRange(charRange) <= storage.length else {
            super.fillBackgroundRectArray(rectArray, count: rectCount, forCharacterRange: charRange, color: color); return
        }
        // One band per laid-out line of the range, in drawing coordinates.
        var bands: [(top: CGFloat, bottom: CGFloat)] = []
        let glyphs = glyphRange(forCharacterRange: charRange, actualCharacterRange: nil)
        var index = glyphs.location
        while index < NSMaxRange(glyphs) {
            var lineRange = NSRange()
            _ = lineFragmentRect(forGlyphAt: index, effectiveRange: &lineRange)
            let part = NSIntersectionRange(lineRange, glyphs)
            index = max(index + 1, NSMaxRange(lineRange))
            guard part.length > 0 else { continue }
            var ascender: CGFloat = 0, descender: CGFloat = 0
            storage.enumerateAttribute(.font, in: characterRange(forGlyphRange: part, actualGlyphRange: nil)) { value, _, _ in
                let font = value as? UIFont ?? .systemFont(ofSize: 14)
                ascender = max(ascender, font.ascender); descender = min(descender, font.descender)
            }
            let line = backgroundOrigin.y + baseline(forGlyphAt: part.location)
            bands.append((line - ascender, line - descender))
        }
        var clipped: [CGRect] = []
        for i in 0..<rectCount {
            let rect = rectArray[i]
            // The band of the line this rectangle belongs to (largest overlap).
            let best = bands.max { a, b in
                min(rect.maxY, a.bottom) - max(rect.minY, a.top) < min(rect.maxY, b.bottom) - max(rect.minY, b.top)
            }
            guard let band = best, band.bottom > rect.minY, band.top < rect.maxY else { clipped.append(rect); continue }
            clipped.append(CGRect(x: rect.minX, y: max(rect.minY, band.top), width: rect.width,
                                  height: min(rect.maxY, band.bottom) - max(rect.minY, band.top)))
        }
        clipped.withUnsafeBufferPointer { buffer in
            super.fillBackgroundRectArray(buffer.baseAddress!, count: buffer.count, forCharacterRange: charRange, color: color)
        }
    }
    /// Baseline (in container coordinates) of the line holding `glyph`.
    nonisolated private func baseline(forGlyphAt glyph: Int) -> CGFloat {
        lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY + location(forGlyphAt: glyph).y
    }
    override func drawGlyphs(forGlyphRange requested: NSRange, at origin: CGPoint) {
        if suppressed { nativeDrawRequested(); return }
        if rasterPass { drawPageBreaks(requested, at: origin) }
        // Several containers: text editor 2, one per page of a document.
        let page = textContainers.count > 1 ? textContainer(forGlyphAt: requested.location, effectiveRange: nil) : nil
        guard let storage = textStorage, let container = page ?? textContainers.first,
              let context = UIGraphicsGetCurrentContext() else { super.drawGlyphs(forGlyphRange: requested, at: origin); return }
        var cursor = requested.location
        for item in TextListEditing.taskItems(in: storage.string) {
            let characters = NSRange(location: item.marker.location, length: NSMaxRange(item.body) - item.marker.location)
            let taskGlyphs = glyphRange(forCharacterRange: characters, actualCharacterRange: nil)
            let part = NSIntersectionRange(requested, taskGlyphs)
            guard part.length > 0 else { continue }
            if cursor < part.location { super.drawGlyphs(forGlyphRange: .init(location: cursor, length: part.location - cursor), at: origin) }
            let markerGlyphs = glyphRange(forCharacterRange: item.marker, actualCharacterRange: nil)
            // Body text metrics (the ☐/☑ glyph may come from a fallback font).
            let bodyFont = item.body.length > 0 ? storage.attribute(.font, at: item.body.location, effectiveRange: nil) as? UIFont : nil
            if NSIntersectionRange(requested, markerGlyphs).length > 0, markerGlyphs.length > 0 {
                let font = bodyFont ?? storage.attribute(.font, at: item.marker.location, effectiveRange: nil) as? UIFont ?? .systemFont(ofSize: 14)
                let ink = storage.attribute(.foregroundColor, at: item.marker.location, effectiveRange: nil) as? UIColor ?? .label
                let bounds = boundingRect(forGlyphRange: markerGlyphs, in: container).offsetBy(dx: origin.x, dy: origin.y)
                let diameter = min(font.pointSize * 1.02, max(1, bounds.width - 1.5))
                // Centred on the middle of the capitals at the line's baseline, not
                // on the line fragment (ruled paper adds space above the glyphs).
                let centerY = origin.y + baseline(forGlyphAt: markerGlyphs.location) - font.capHeight / 2
                let circle = CGRect(x: bounds.midX - diameter / 2, y: centerY - diameter / 2, width: diameter, height: diameter)
                let path = UIBezierPath(ovalIn: circle); path.lineWidth = max(0.7, font.pointSize * 0.045)
                ink.setStroke()
                if item.checked {
                    ink.setFill(); path.fill()
                    var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                    ink.getRed(&r, green: &g, blue: &b, alpha: &a)
                    (r + g + b > 1.5 ? UIColor.black : .white).setStroke()
                    let tick = UIBezierPath(); tick.lineWidth = max(1.2, diameter * 0.1); tick.lineCapStyle = .round; tick.lineJoinStyle = .round
                    tick.move(to: CGPoint(x: circle.minX + diameter * 0.25, y: circle.minY + diameter * 0.52))
                    tick.addLine(to: CGPoint(x: circle.minX + diameter * 0.44, y: circle.minY + diameter * 0.7))
                    tick.addLine(to: CGPoint(x: circle.minX + diameter * 0.76, y: circle.minY + diameter * 0.32)); tick.stroke()
                } else { path.stroke() }
            }
            let start = max(part.location, NSMaxRange(markerGlyphs))
            let body = NSRange(location: start, length: max(0, NSMaxRange(part) - start))
            if body.length > 0 {
                context.saveGState()
                if item.checked { context.setAlpha(0.45) }
                super.drawGlyphs(forGlyphRange: body, at: origin)
                context.restoreGState()
                if item.checked, item.body.length > 0 { strikeThrough(body, at: origin, in: container) }
            }
            cursor = NSMaxRange(part)
        }
        if cursor < NSMaxRange(requested) { super.drawGlyphs(forGlyphRange: .init(location: cursor, length: NSMaxRange(requested) - cursor), at: origin) }
    }
    /// A manual page break, on its line behind the text. Only the editor's
    /// raster draws it: previews and the PDF show the break by the page itself.
    nonisolated private func drawPageBreaks(_ glyphs: NSRange, at origin: CGPoint) {
        guard let storage = textStorage else { return }
        let text = storage.string as NSString
        var search = characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        while search.length > 0 {
            let found = text.range(of: TextLines.pageBreakText, options: .literal, range: search)
            guard found.location != NSNotFound else { return }
            search = NSRange(location: NSMaxRange(found), length: NSMaxRange(search) - NSMaxRange(found))
            let glyph = glyphIndexForCharacter(at: found.location)
            let line = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let font = storage.attribute(.font, at: found.location, effectiveRange: nil) as? UIFont ?? .systemFont(ofSize: 14)
            let y = origin.y + baseline(forGlyphAt: glyph) - font.xHeight / 2
            let ink = UIColor.gray.withAlphaComponent(0.7)
            let name = NSAttributedString(string: "Seitenumbruch", attributes: [.font: UIFont.systemFont(ofSize: 8), .foregroundColor: ink])
            let label = name.size()
            let start = origin.x + line.minX + location(forGlyphAt: glyph).x + 4, end = origin.x + line.maxX - label.width - 4
            if end > start {
                let mark = UIBezierPath(); mark.lineWidth = 0.6
                mark.setLineDash([3, 2], count: 2, phase: 0)
                mark.move(to: CGPoint(x: start, y: y)); mark.addLine(to: CGPoint(x: end, y: y))
                ink.setStroke(); mark.stroke()
            }
            name.draw(at: CGPoint(x: max(start, end + 4), y: y - label.height / 2))
        }
    }
    /// Done tasks: one line per laid-out line through the middle of the
    /// lowercase letters (x-height), from the first to the last visible glyph.
    nonisolated private func strikeThrough(_ glyphs: NSRange, at origin: CGPoint, in container: NSTextContainer) {
        guard let storage = textStorage else { return }
        UIColor.gray.setStroke()
        var index = glyphs.location
        while index < NSMaxRange(glyphs) {
            var lineRange = NSRange()
            _ = lineFragmentRect(forGlyphAt: index, effectiveRange: &lineRange)
            var visible = NSIntersectionRange(lineRange, glyphs)
            guard visible.length > 0 else { break }
            index = NSMaxRange(lineRange)
            // Trailing spaces/line breaks are not crossed out.
            let characters = characterRange(forGlyphRange: visible, actualGlyphRange: nil)
            let text = storage.string as NSString
            var last = NSMaxRange(characters)
            while last > characters.location, let scalar = UnicodeScalar(text.character(at: last - 1)),
                  CharacterSet.whitespacesAndNewlines.contains(scalar) { last -= 1 }
            guard last > characters.location else { continue }
            visible = glyphRange(forCharacterRange: NSRange(location: characters.location, length: last - characters.location), actualCharacterRange: nil)
            let rect = boundingRect(forGlyphRange: visible, in: container)
            let font = storage.attribute(.font, at: characters.location, effectiveRange: nil) as? UIFont ?? .systemFont(ofSize: 14)
            let y = origin.y + baseline(forGlyphAt: visible.location) - font.xHeight / 2
            let line = UIBezierPath(); line.lineWidth = max(0.8, font.pointSize * 0.06)
            line.move(to: CGPoint(x: origin.x + rect.minX, y: y))
            line.addLine(to: CGPoint(x: origin.x + rect.maxX, y: y)); line.stroke()
        }
    }
}

/// The text container of every text layout (editor, previews, PDF, flow
/// capacity, text editor 2): the wrapped lines of a paragraph with a prefix
/// („•“, „->“, „a)“, leading tabs) start where its text starts on the first
/// line (`TextHangingIndent`). Computed while laying out, from the text and
/// its format alone: nothing is stored and no attribute changes, so all
/// layouts wrap alike. The paragraph's own indent stays the stored one.
class HangingTextContainer: NSTextContainer {
    /// The paragraph measured last: layout runs through a paragraph line by
    /// line, a long one is not searched again for each of them.
    nonisolated(unsafe) private var measured: (start: Int, end: Int, width: CGFloat, extra: CGFloat)?
    /// The text changed (`TaskLayoutManager.processEditing`).
    nonisolated func resetHangingIndents() { measured = nil }
    override var isSimpleRectangularTextContainer: Bool { false }
    override func lineFragmentRect(forProposedRect proposedRect: CGRect, at characterIndex: Int, writingDirection baseWritingDirection: NSWritingDirection,
                                   remaining remainingRect: UnsafeMutablePointer<CGRect>?) -> CGRect {
        var rect = super.lineFragmentRect(forProposedRect: proposedRect, at: characterIndex, writingDirection: baseWritingDirection, remaining: remainingRect)
        guard !rect.isEmpty, baseWritingDirection != .rightToLeft else { return rect }
        let extra = hangingExtra(at: characterIndex)
        guard extra > 0, extra < rect.width else { return rect }
        // The paragraph's head indent applies inside this rect on top of the shift.
        rect.origin.x += extra; rect.size.width -= extra
        return rect
    }
    /// How far a line starting at `index` (inside a paragraph, not its first
    /// line) stands right of the paragraph's head indent.
    nonisolated private func hangingExtra(at index: Int) -> CGFloat {
        guard let storage = layoutManager?.textStorage, index > 0, index < storage.length else { return 0 }
        let width = size.width
        if let measured, index > measured.start, index <= measured.end, measured.width == width { return measured.extra }
        // `mutableString`: `string` would copy the whole text for every line.
        let text: NSString = storage.mutableString
        let start = TextLines.start(text, index)
        guard start < index else { return 0 }
        let extra = Self.hangingExtra(storage, paragraphStart: start, width: width)
        measured = (start, TextLines.end(text, index), width, extra)
        return extra
    }
    nonisolated static func hangingExtra(_ storage: NSTextStorage, paragraphStart start: Int, width: CGFloat) -> CGFloat {
        let paragraph = storage.attribute(.paragraphStyle, at: start, effectiveRange: nil) as? NSParagraphStyle ?? .default
        // Centred or right-aligned text has no edge to hang from.
        guard [.left, .natural, .justified].contains(paragraph.alignment), paragraph.baseWritingDirection != .rightToLeft else { return 0 }
        let interval = paragraph.defaultTabInterval > 0 ? paragraph.defaultTabInterval : CGFloat(TextTabs.interval(fontSize: 14))
        let body = TextHangingIndent.bodyStart(in: storage.mutableString, paragraphStart: start,
            firstLineIndent: Double(paragraph.firstLineHeadIndent), tabInterval: Double(interval), width: Double(width)) { range in
            // Typographic width with trailing white space, in the text's own format.
            let line = CTLineCreateWithAttributedString(storage.attributedSubstring(from: range) as CFAttributedString)
            return CTLineGetTypographicBounds(line, nil, nil, nil)
        }
        return body.map { max(0, CGFloat($0) - paragraph.headIndent) } ?? 0
    }
}

/// Snap native glyph baselines without changing persisted text attributes.
@MainActor
final class RuledTextLayout: NSObject, @preconcurrency NSLayoutManagerDelegate {
    /// The lines of the laid-out box (`TextLinePaper.grid(for:)`); nil: free layout.
    /// A flow segment's first line may reach above the writing area (`pageTop`).
    var grid: TextLineGrid?
    /// Baseline in container coordinates of a line starting at `top`; the one
    /// rule of editor, previews, PDF and flow capacity. Nil without ruling.
    func baseline(top: CGFloat, ascent: CGFloat) -> CGFloat? {
        grid.map { CGFloat($0.baseline(top: Double(top), ascent: Double(ascent))) }
    }
    func layoutManager(_ layoutManager: NSLayoutManager, shouldSetLineFragmentRect rect: UnsafeMutablePointer<CGRect>,
                       lineFragmentUsedRect used: UnsafeMutablePointer<CGRect>, baselineOffset: UnsafeMutablePointer<CGFloat>,
                       in textContainer: NSTextContainer, forGlyphRange glyphRange: NSRange) -> Bool {
        guard let baseline = baseline(top: rect.pointee.minY, ascent: baselineOffset.pointee) else { return false }
        let delta = baseline - rect.pointee.minY - baselineOffset.pointee
        rect.pointee.size.height += delta
        used.pointee.size.height += delta
        baselineOffset.pointee += delta
        return true
    }
    /// A page break takes no room in a page's own layout: it ends a segment,
    /// and text behind it (a field, a kept overflow) must stay visible.
    func layoutManager(_ layoutManager: NSLayoutManager, shouldUse action: NSLayoutManager.ControlCharacterAction,
                       forControlCharacterAt charIndex: Int) -> NSLayoutManager.ControlCharacterAction {
        guard let storage = layoutManager.textStorage, charIndex < storage.length,
              (storage.string as NSString).character(at: charIndex) == TextLines.pageBreak else { return action }
        return .zeroAdvancement
    }
}

extension TextBoxStyle {
    @MainActor var attributes: [NSAttributedString.Key: Any] {
        var descriptor = (fontName.flatMap { UIFont(name: $0, size: fontSize) } ?? UIFont.systemFont(ofSize: fontSize)).fontDescriptor
        if font == .serif { descriptor = descriptor.withDesign(.serif) ?? descriptor }
        if font == .monospaced { descriptor = descriptor.withDesign(.monospaced) ?? descriptor }
        var traits: UIFontDescriptor.SymbolicTraits = []
        if bold { traits.insert(.traitBold) }
        if italic { traits.insert(.traitItalic) }
        descriptor = descriptor.withSymbolicTraits(traits) ?? descriptor
        let defaultInk: UIColor = switch color {
        case .black: .black
        case .white: .white
        case .blue: UIColor(red: 0.10, green: 0.35, blue: 0.80, alpha: 1)
        case .red: UIColor(red: 0.80, green: 0.12, blue: 0.12, alpha: 1)
        }
        let ink = self.ink.map { UIColor(red: $0.red, green: $0.green, blue: $0.blue, alpha: $0.alpha) } ?? defaultInk
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = switch alignment ?? .left {
        case .left: .left
        case .center: .center
        case .right: .right
        case .justified: .justified
        }
        paragraph.headIndent = indent ?? 0; paragraph.firstLineHeadIndent = indent ?? 0
        // The system's twelve stops end after 336 pt, a tab behind them wrapped
        // the line. One endless grid instead (`TextTabs`).
        paragraph.tabStops = []; paragraph.defaultTabInterval = TextTabs.interval(fontSize: fontSize)
        var result: [NSAttributedString.Key: Any] = [.font: UIFont(descriptor: descriptor, size: fontSize), .foregroundColor: ink,
                .underlineStyle: underline ? NSUnderlineStyle.single.rawValue : 0,
                .paragraphStyle: paragraph, NSAttributedString.Key("noty.font"): font.rawValue]
        if let fontName { result[NSAttributedString.Key("noty.fontName")] = fontName }
        if strikethrough == true { result[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        if let baseline, baseline != 0 { result[.baselineOffset] = Double(baseline) * fontSize * 0.3 }
        if highlighted == true {
            result[.backgroundColor] = (highlightColor?.uiColor ?? .systemYellow).withAlphaComponent(0.35)
            if let highlightColor { result[NSAttributedString.Key("noty.highlight")] = highlightColor.rawValue }
        }
        if automaticColor == true { result[NSAttributedString.Key("noty.autoInk")] = true }
        if let link { result[.link] = link }
        return result
    }

    @MainActor init(attributes: [NSAttributedString.Key: Any], fallback: TextBoxStyle) {
        self = fallback
        if let value = attributes[.font] as? UIFont {
            fontSize = min(96, max(8, Double(value.pointSize)))
            bold = value.fontDescriptor.symbolicTraits.contains(.traitBold)
            italic = value.fontDescriptor.symbolicTraits.contains(.traitItalic)
            if let name = attributes[NSAttributedString.Key("noty.font")] as? String, let family = TextFont(rawValue: name) { font = family }
            else if value.fontDescriptor.symbolicTraits.contains(.traitMonoSpace) { font = .monospaced }
            else { font = value.familyName.lowercased().contains("serif") ? .serif : .system }
        }
        fontName = attributes[NSAttributedString.Key("noty.fontName")] as? String
        strikethrough = (attributes[.strikethroughStyle] as? Int ?? 0) == 0 ? nil : true
        let offset = (attributes[.baselineOffset] as? NSNumber)?.doubleValue ?? 0
        baseline = offset == 0 ? nil : (offset > 0 ? 1 : -1)
        underline = (attributes[.underlineStyle] as? Int ?? 0) != 0
        highlighted = attributes[.backgroundColor] != nil
        // UIKit derives typing attributes from the typed text and need not keep
        // app keys such as "noty.highlight": the visible marker colour decides,
        // otherwise a chosen colour fell back to yellow after one character.
        highlightColor = highlighted == true ? ((attributes[NSAttributedString.Key("noty.highlight")] as? String).flatMap(HighlightColor.init(rawValue:))
            ?? (attributes[.backgroundColor] as? UIColor).map(HighlightColor.nearest)) : nil
        if highlightColor == .yellow { highlightColor = nil }
        automaticColor = (attributes[NSAttributedString.Key("noty.autoInk")] as? Bool) == true ? true : nil
        if let value = attributes[.foregroundColor] as? UIColor {
            let choices: [TextColor] = [.black, .white, .blue, .red]
            func components(_ c: UIColor) -> [CGFloat] { var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0; c.getRed(&r, green: &g, blue: &b, alpha: &a); return [r,g,b] }
            let rgb = components(value)
            func distance(_ candidate: TextColor) -> CGFloat {
                let ink: UIColor = switch candidate {
                case .black: .black
                case .white: .white
                case .blue: UIColor(red: 0.10, green: 0.35, blue: 0.80, alpha: 1)
                case .red: UIColor(red: 0.80, green: 0.12, blue: 0.12, alpha: 1)
                }
                return zip(rgb, components(ink)).reduce(0) { total, pair in total + (pair.0-pair.1)*(pair.0-pair.1) }
            }
            let nearest = choices.min { distance($0) < distance($1) } ?? fallback.color
            color = nearest
            let custom = InkColor(value) // sRGB, clamped: a P3 text colour stays storable
            ink = distance(nearest) < 0.000001 && custom.alpha == 1 ? nil : custom
            if automaticColor == true { color = custom.red + custom.green + custom.blue > 1.5 ? .white : .black; ink = nil }
        }
        if let paragraph = attributes[.paragraphStyle] as? NSParagraphStyle {
            alignment = switch paragraph.alignment { case .center: .center; case .right: .right; case .justified: .justified; default: .left }
            indent = min(240, max(0, paragraph.headIndent))
        }
        link = (attributes[.link] as? URL)?.absoluteString ?? attributes[.link] as? String
        if let value = link, value.utf8.count > 2048 || !["https", "http", "mailto"].contains(URL(string: value)?.scheme?.lowercased() ?? "") { link = nil }
    }
}

extension HighlightColor {
    var uiColor: UIColor {
        switch self {
        case .yellow: .systemYellow
        case .green: UIColor(red: 0.30, green: 0.85, blue: 0.35, alpha: 1)
        case .blue: UIColor(red: 0.30, green: 0.65, blue: 1, alpha: 1)
        case .pink: UIColor(red: 1, green: 0.40, blue: 0.70, alpha: 1)
        case .orange: UIColor(red: 1, green: 0.60, blue: 0.15, alpha: 1)
        case .purple: UIColor(red: 0.70, green: 0.45, blue: 1, alpha: 1)
        }
    }
    /// Palette colour closest to a stored marker background (alpha ignored).
    @MainActor static func nearest(_ color: UIColor) -> HighlightColor {
        func rgb(_ value: UIColor) -> [CGFloat] {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            value.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light)).getRed(&r, green: &g, blue: &b, alpha: &a)
            return [r, g, b]
        }
        let target = rgb(color)
        return allCases.min { a, b in
            zip(rgb(a.uiColor), target).reduce(0) { $0 + ($1.0 - $1.1) * ($1.0 - $1.1) }
                < zip(rgb(b.uiColor), target).reduce(0) { $0 + ($1.0 - $1.1) * ($1.0 - $1.1) }
        } ?? .yellow
    }
    var title: String {
        switch self { case .yellow: "Gelb"; case .green: "Grün"; case .blue: "Blau"; case .pink: "Pink"; case .orange: "Orange"; case .purple: "Violett" }
    }
}

extension TextBox {
    @MainActor var attributedText: NSAttributedString {
        let value = NSMutableAttributedString(string: text, attributes: style.attributes)
        for run in runs ?? [] where run.location >= 0 && run.length > 0 && run.location <= value.length && run.length <= value.length-run.location {
            value.setAttributes(run.style.attributes, range: NSRange(location: run.location, length: run.length))
        }
        value.applyTabGrid(CGFloat(TextTabs.interval(self)))
        return value
    }
    @MainActor mutating func capture(_ value: NSAttributedString) {
        text = value.string
        var collected: [TextRun] = []
        value.enumerateAttributes(in: NSRange(location: 0, length: value.length)) { attributes, range, _ in
            collected.append(TextRun(location: range.location, length: range.length, style: TextBoxStyle(attributes: attributes, fallback: style)))
        }
        runs = collected
    }
}

extension NSMutableAttributedString {
    /// Every paragraph on the same endless grid (`TextTabs`). True if anything changed.
    @discardableResult
    func applyTabGrid(_ interval: CGFloat) -> Bool {
        var changed = false
        beginEditing()
        enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: length)) { value, range, _ in
            let style = value as? NSParagraphStyle
            guard style?.defaultTabInterval != interval || style?.tabStops.isEmpty != true else { return }
            let next = (style?.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
            next.tabStops = []; next.defaultTabInterval = interval
            addAttribute(.paragraphStyle, value: next, range: range)
            changed = true
        }
        endEditing()
        return changed
    }
}

/// Shared native glyph layout for PDF and thumbnails; editor uses the same
/// attributes and zero-inset text container. No screenshot export of text.
@MainActor
struct TextObjectLayout {
    let storage: NSTextStorage
    let manager: NSLayoutManager
    let container: NSTextContainer
    private let ruling: RuledTextLayout
    let coordinateScale: CGFloat
    /// The field's rotation (radians) about its top-left corner, the drawing origin.
    let rotation: CGFloat
    /// `limitedTo`: only as many lines as this height (page units) holds, for
    /// measuring a page of a long flow; the rest stays without layout.
    init(_ box: TextBox, on page: Page, limitedTo limit: Double? = nil) {
        self.init(box, paper: page.linePaper, limitedTo: limit)
    }
    /// The line layout of `paper` (`TextLinePaper.grid(for:)`): flow segments,
    /// migrated fields and fields aligned to the paper lines stand on them.
    init(_ box: TextBox, paper: TextLinePaper, limitedTo limit: Double? = nil) {
        self.init(box, grid: paper.grid(for: box), coordinateScale: CGFloat(paper.coordinateScale(for: box)), limitedTo: limit)
    }
    init(_ box: TextBox, grid: TextLineGrid? = nil, coordinateScale: CGFloat = 1, limitedTo limit: Double? = nil) {
        self.coordinateScale = coordinateScale
        rotation = CGFloat(box.angle * .pi / 180)
        storage = NSTextStorage(attributedString: box.attributedText)
        manager = TaskLayoutManager()
        ruling = RuledTextLayout(); ruling.grid = grid; manager.delegate = ruling
        // A line of the largest size more than the page, so the last one is never cut off by the container.
        let height = limit.map { CGFloat($0) / coordinateScale + Self.glyphOverhang(box) * 4 } ?? .greatestFiniteMagnitude
        container = HangingTextContainer(size: CGSize(width: box.width / coordinateScale, height: height))
        container.lineFragmentPadding = 0
        storage.addLayoutManager(manager); manager.addTextContainer(container)
        manager.ensureLayout(for: container)
    }
    var usedHeight: CGFloat { ceil(manager.usedRect(for: container).height * coordinateScale) }
    /// `usedHeight` without the empty line behind a final line break: in a
    /// flow that line belongs to the next page, it is no overflow.
    func contentHeight(_ box: TextBox) -> CGFloat {
        let extra = manager.extraLineFragmentRect
        return box.flowID != nil && extra.height > 0 ? min(usedHeight, ceil(extra.minY * coordinateScale)) : usedHeight
    }
    /// Room beyond a field's text frame where glyphs still draw (italics, „J“,
    /// the caret at the left edge), in the field's own units: the editor's
    /// zoom raster and the previews clip the same way.
    static func glyphOverhang(_ box: TextBox) -> CGFloat {
        let largest = ([box.style.fontSize] + (box.runs ?? []).map(\.style.fontSize)).max() ?? box.style.fontSize
        let reach = CGFloat(largest) * 0.35 + 2
        // A page's first line reaches up to the page edge (`firstLineBaseline`).
        return box.flowID == nil ? reach : max(reach, CGFloat(box.y) + 2)
    }
    /// The field's text does not fit its height on `page` (`TextBox.overflows`):
    /// previews mark it red like the editor, the PDF export refuses it.
    static func overflows(_ box: TextBox, on page: Page) -> Bool {
        box.overflows(textHeight: Double(TextObjectLayout(box, on: page).contentHeight(box)))
    }
    /// Widest laid-out line in canonical units (automatic field width).
    var usedWidth: CGFloat { max(manager.usedRect(for: container).width, trailingTabEnd) * coordinateScale }
    /// The used area may end before a tab at the end of a line. An automatic
    /// field must reach that tab's stop: otherwise the caret wraps instead of
    /// standing at the stop.
    private var trailingTabEnd: CGFloat {
        let text = storage.string as NSString
        guard text.range(of: "\t").location != NSNotFound, manager.numberOfGlyphs > 0 else { return 0 }
        var end: CGFloat = 0
        manager.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: manager.numberOfGlyphs)) { fragment, _, _, glyphs, _ in
            var last = NSMaxRange(glyphs) - 1
            while last >= glyphs.location, TextLines.isBreak(text.character(at: manager.characterIndexForGlyph(at: last))) { last -= 1 }
            guard last >= glyphs.location else { return }
            let character = manager.characterIndexForGlyph(at: last)
            guard text.character(at: character) == 9,
                  let paragraph = storage.attribute(.paragraphStyle, at: character, effectiveRange: nil) as? NSParagraphStyle else { return }
            let start = Double(fragment.minX + manager.location(forGlyphAt: last).x)
            end = max(end, CGFloat(TextTabs.nextStop(after: start, interval: Double(paragraph.defaultTabInterval))))
        }
        return end
    }
    /// Local (unrotated, unscaled) → drawing coordinates for a field at `origin`.
    func transform(at origin: CGPoint) -> CGAffineTransform {
        CGAffineTransform(translationX: origin.x, y: origin.y).rotated(by: rotation).scaledBy(x: coordinateScale, y: coordinateScale)
    }
    func links(at origin: CGPoint) -> [(URL, CGRect)] {
        var links: [(URL, CGRect)] = []
        let transform = transform(at: origin)
        storage.enumerateAttribute(.link, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard let value = value as? String, let url = URL(string: value) else { return }
            let glyphs = manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            manager.enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: container) { rect, _ in
                // A rotated field's link area is the bounding box of its turned rectangle.
                links.append((url, rect.applying(transform)))
            }
        }
        return links
    }
    /// `origin`: the field's top-left corner (its rotation pivot) in drawing coordinates.
    func draw(at origin: CGPoint) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        context.saveGState(); defer { context.restoreGState() }
        context.concatenate(transform(at: origin))
        manager.drawBackground(forGlyphRange: NSRange(location: 0, length: manager.numberOfGlyphs), at: .zero)
        manager.drawGlyphs(forGlyphRange: NSRange(location: 0, length: manager.numberOfGlyphs), at: .zero)
    }
}

extension TextBoxStyle {
    /// The visible text colour of this style (palette colour or own ink).
    var foregroundUIColor: UIColor {
        if let ink { return UIColor(red: ink.red, green: ink.green, blue: ink.blue, alpha: ink.alpha) }
        return switch color {
        case .black: .black
        case .white: .white
        case .blue: UIColor(red: 0.10, green: 0.35, blue: 0.80, alpha: 1)
        case .red: UIColor(red: 0.80, green: 0.12, blue: 0.12, alpha: 1)
        }
    }
}

extension TextFieldFill {
    var uiColor: UIColor { UIColor(red: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1) }
}

/// Feldstil (Textneubau Stufe 4): fill and frame of a free field, drawn
/// below its text by the one geometry of `TextBox.fieldStyleRect` (page
/// points, rounded corners, turned about the text's top-left corner). PDF,
/// thumbnails and lifted selections draw through `draw`; the editor's field
/// view uses `path`/`borderColor` for its layer (same values).
@MainActor
enum TextFieldStyleRendering {
    /// Rounded visible field in the field's own unrotated page units
    /// (origin: text top-left), divided by `unitScale` (margin text units).
    static func localPath(_ box: TextBox, unitScale: CGFloat = 1) -> CGPath? {
        guard box.hasFieldStyle else { return nil }
        let frame = box.fieldStyleRect
        let rect = CGRect(x: frame.x / unitScale, y: frame.y / unitScale, width: frame.width / unitScale, height: frame.height / unitScale)
        let radius = min(TextBox.fieldCornerRadius / unitScale, rect.width / 2, rect.height / 2)
        return CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    }

    /// Frame colour: the field's (resolved) base text colour or the accent blue.
    static func borderColor(_ resolved: TextBox) -> UIColor? {
        switch resolved.border {
        case nil: nil
        case .text: resolved.style.foregroundUIColor
        case .accent: UIColor(red: TextFieldBorder.accentRGB.red, green: TextFieldBorder.accentRGB.green,
                              blue: TextFieldBorder.accentRGB.blue, alpha: 1)
        }
    }

    /// `resolved`: automatic colours already resolved for the page
    /// (`Page.resolvedTextBoxes`). `origin`: the text's top-left corner in
    /// drawing coordinates (as for `TextObjectLayout.draw`).
    static func draw(_ resolved: TextBox, at origin: CGPoint, context: CGContext) {
        guard let path = localPath(resolved) else { return }
        context.saveGState(); defer { context.restoreGState() }
        context.translateBy(x: origin.x, y: origin.y)
        context.rotate(by: CGFloat(resolved.angle * .pi / 180))
        if let fill = resolved.fill {
            context.addPath(path); context.setFillColor(fill.uiColor.cgColor); context.fillPath()
        }
        if let stroke = borderColor(resolved) {
            // Stroked inside the visible edge, so the frame never leaves the page.
            let inset = CGFloat(TextBox.fieldBorderWidth) / 2
            let frame = path.boundingBoxOfPath.insetBy(dx: inset, dy: inset)
            let radius = max(0, min(CGFloat(TextBox.fieldCornerRadius) - inset, frame.width / 2, frame.height / 2))
            context.addPath(CGPath(roundedRect: frame, cornerWidth: radius, cornerHeight: radius, transform: nil))
            context.setStrokeColor(stroke.cgColor); context.setLineWidth(CGFloat(TextBox.fieldBorderWidth)); context.strokePath()
        }
    }
}
