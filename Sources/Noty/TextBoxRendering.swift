import UIKit
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
        guard let storage = textStorage, let container = textContainers.first,
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

/// Snap native glyph baselines without changing persisted text attributes.
@MainActor
final class RuledTextLayout: NSObject, @preconcurrency NSLayoutManagerDelegate {
    var originY: CGFloat?
    var lines = TextRuling.lined
    func layoutManager(_ layoutManager: NSLayoutManager, shouldSetLineFragmentRect rect: UnsafeMutablePointer<CGRect>,
                       lineFragmentUsedRect used: UnsafeMutablePointer<CGRect>, baselineOffset: UnsafeMutablePointer<CGFloat>,
                       in textContainer: NSTextContainer, forGlyphRange glyphRange: NSRange) -> Bool {
        guard let originY else { return false }
        let current = originY + rect.pointee.minY + baselineOffset.pointee
        // Grid rows may tighten a line slightly, never the first one (no clipping).
        var delta = CGFloat(lines.baseline(forNatural: Double(current))) - current
        if rect.pointee.minY < 0.5 { delta = max(0, delta) }
        rect.pointee.size.height += delta
        used.pointee.size.height += delta
        baselineOffset.pointee += delta
        return true
    }
}

extension Page {
    /// Page-bound text stands on lined rows and on grid rows (same baselines
    /// in editor, previews, PDF and flow capacity).
    func textRuling(for box: TextBox) -> TextRuling? {
        guard box.flowID != nil else { return nil }
        return TextRuling(paper: box.flowRegion == .page ? paper : margins?.style)
    }
    func ruledTextOrigin(for box: TextBox) -> CGFloat? {
        textRuling(for: box) == nil ? nil : (box.y + (margins?.top ?? 0)) / writingCoordinateScale(for: box)
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
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            value.getRed(&r, green: &g, blue: &b, alpha: &a)
            ink = distance(nearest) < 0.000001 && a == 1 ? nil : InkColor(r, g, b, a)
            if automaticColor == true { color = r + g + b > 1.5 ? .white : .black; ink = nil }
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

/// Shared native glyph layout for PDF and thumbnails; editor uses the same
/// attributes and zero-inset text container. No screenshot export of text.
@MainActor
struct TextObjectLayout {
    let storage: NSTextStorage
    let manager: NSLayoutManager
    let container: NSTextContainer
    private let ruling: RuledTextLayout
    let coordinateScale: CGFloat
    init(_ box: TextBox, on page: Page) {
        self.init(box, ruledOrigin: page.ruledTextOrigin(for: box), ruling: page.textRuling(for: box) ?? .lined,
            coordinateScale: page.writingCoordinateScale(for: box))
    }
    init(_ box: TextBox, ruledOrigin: CGFloat? = nil, ruling lines: TextRuling = .lined, coordinateScale: CGFloat = 1) {
        self.coordinateScale = coordinateScale
        storage = NSTextStorage(attributedString: box.attributedText)
        manager = TaskLayoutManager()
        ruling = RuledTextLayout(); ruling.originY = ruledOrigin; ruling.lines = lines; manager.delegate = ruling
        container = NSTextContainer(size: CGSize(width: box.width / coordinateScale, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        storage.addLayoutManager(manager); manager.addTextContainer(container)
        manager.ensureLayout(for: container)
    }
    var usedHeight: CGFloat { ceil(manager.usedRect(for: container).height * coordinateScale) }
    func links(at origin: CGPoint) -> [(URL, CGRect)] {
        var links: [(URL, CGRect)] = []
        storage.enumerateAttribute(.link, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard let value = value as? String, let url = URL(string: value) else { return }
            let glyphs = manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            manager.enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: container) { rect, _ in
                links.append((url, rect.applying(CGAffineTransform(scaleX: coordinateScale, y: coordinateScale)).offsetBy(dx: origin.x, dy: origin.y)))
            }
        }
        return links
    }
    func draw(at origin: CGPoint) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        context.saveGState(); defer { context.restoreGState() }
        context.translateBy(x: origin.x, y: origin.y); context.scaleBy(x: coordinateScale, y: coordinateScale)
        manager.drawBackground(forGlyphRange: NSRange(location: 0, length: manager.numberOfGlyphs), at: .zero)
        manager.drawGlyphs(forGlyphRange: NSRange(location: 0, length: manager.numberOfGlyphs), at: .zero)
    }
}
