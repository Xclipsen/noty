import UIKit
import NotebookCore

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
        if highlighted == true { result[.backgroundColor] = UIColor.systemYellow.withAlphaComponent(0.35) }
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
        }
        if let paragraph = attributes[.paragraphStyle] as? NSParagraphStyle {
            alignment = switch paragraph.alignment { case .center: .center; case .right: .right; case .justified: .justified; default: .left }
            indent = min(240, max(0, paragraph.headIndent))
        }
        link = (attributes[.link] as? URL)?.absoluteString ?? attributes[.link] as? String
        if let value = link, value.utf8.count > 2048 || !["https", "http", "mailto"].contains(URL(string: value)?.scheme?.lowercased() ?? "") { link = nil }
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
    init(_ box: TextBox) {
        storage = NSTextStorage(attributedString: box.attributedText)
        manager = NSLayoutManager()
        container = NSTextContainer(size: CGSize(width: box.width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        storage.addLayoutManager(manager); manager.addTextContainer(container)
        manager.ensureLayout(for: container)
    }
    var usedHeight: CGFloat { ceil(manager.usedRect(for: container).height) }
    func links(at origin: CGPoint) -> [(URL, CGRect)] {
        var links: [(URL, CGRect)] = []
        storage.enumerateAttribute(.link, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard let value = value as? String, let url = URL(string: value) else { return }
            let glyphs = manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            manager.enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: container) { rect, _ in
                links.append((url, rect.offsetBy(dx: origin.x, dy: origin.y)))
            }
        }
        return links
    }
    func draw(at origin: CGPoint) {
        manager.drawBackground(forGlyphRange: NSRange(location: 0, length: manager.numberOfGlyphs), at: origin)
        manager.drawGlyphs(forGlyphRange: NSRange(location: 0, length: manager.numberOfGlyphs), at: origin)
    }
}
