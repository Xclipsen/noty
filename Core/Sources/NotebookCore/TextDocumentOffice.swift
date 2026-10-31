import Foundation

/// Word (`.docx`) and RTF export: the same text as `plainText`, in the same
/// order, as formatted paragraphs (`blocks`). Handwriting, images and shapes
/// stay in the PDF export: the flow holds no images, its neighbours on the
/// page have no place between its paragraphs.
extension TextDocumentExport {
    struct Block {
        enum Marker: Equatable { case bullet, number(Int), open, done }
        var preset: TextStylePreset
        var style: TextBoxStyle
        var marker: Marker?
        var level = 0
        var spans: [(text: String, style: TextBoxStyle)]
        var pageBreak: Bool
        /// A new text (free field) starts here.
        var separated = false
    }

    /// Every text as paragraphs, list markers as structure, empty end lines gone.
    static func blocks(of notebook: Notebook) -> [Block] {
        var result: [Block] = []
        for box in texts(of: notebook) {
            var blocks = blocks(box)
            while let last = blocks.last, last.spans.isEmpty, !last.pageBreak { blocks.removeLast() }
            guard !blocks.isEmpty else { continue }
            if !result.isEmpty { blocks[0].separated = true }
            result += blocks
        }
        return result
    }

    static func blocks(_ box: TextBox) -> [Block] {
        let source = box.text as NSString
        return paragraphs(box.text).map { range in
            let line = source.substring(with: range)
            let leading = line.prefix { $0 == " " || $0 == "\t" }
            let rest = String(line.dropFirst(leading.count))
            var content = range, marker: Block.Marker?
            if let prefix = TextListEditing.prefix(rest) {
                let skipped = (String(leading) as NSString).length + (prefix as NSString).length
                content = NSRange(location: range.location + skipped, length: range.length - skipped)
                switch prefix {
                case "☐ ": marker = .open
                case "☑ ": marker = .done
                case "• ", "- ", "◦ ", "▪ ": marker = .bullet
                default: marker = .number(Int(prefix.prefix { $0.isNumber }) ?? 1)
                }
            }
            let first = box.style(at: min(content.location, max(0, source.length - 1)))
            let spans: [(text: String, style: TextBoxStyle)] = box.styleRuns.compactMap { run in
                let part = NSIntersectionRange(content, NSRange(location: run.location, length: run.length))
                return part.length > 0 ? (source.substring(with: part), run.style) : nil
            }
            let end = NSMaxRange(range)
            return Block(preset: TextStylePreset.matching(first), style: first, marker: marker,
                         level: marker == nil ? 0 : box.listLevel(at: range.location), spans: spans,
                         pageBreak: end < source.length && source.character(at: end) == TextLines.pageBreak)
        }
    }

    /// Text that the paper does not carry: white text belongs to dark paper,
    /// a Word page is white. nil: the automatic colour.
    static func visibleColor(_ style: TextBoxStyle) -> String? {
        if style.automaticColor == true { return nil }
        if let ink = style.ink {
            if PaperInkInversion.isNeutral(ink), PaperInkInversion.luminance(ink) >= PaperInkInversion.lightLuminance { return nil }
            return hex(ink.red, ink.green, ink.blue)
        }
        switch style.color {
        case .black, .white: return nil
        case .blue: return hex(0.10, 0.35, 0.80)
        case .red: return hex(0.80, 0.12, 0.12)
        }
    }
    private static func hex(_ red: Double, _ green: Double, _ blue: Double) -> String {
        [red, green, blue].map { value in
            let byte = Int((min(1, max(0, value)) * 255).rounded())
            return (byte < 16 ? "0" : "") + String(byte, radix: 16, uppercase: true)
        }.joined()
    }
    /// The marker as stored colour; yellow is the original marker.
    static func markerColor(_ style: TextBoxStyle) -> String? {
        guard style.highlighted == true else { return nil }
        return switch style.highlightColor ?? .yellow {
        case .yellow: "FFFF00"
        case .green: "00FF00"
        case .blue: "00FFFF"
        case .pink: "FF00FF"
        case .orange: "FFA726"
        case .purple: "B388FF"
        }
    }
    static func fontName(_ style: TextBoxStyle) -> String? {
        if let name = style.fontName { return name }
        return switch style.font { case .system: nil; case .serif: "Times New Roman"; case .monospaced: "Courier New" }
    }
    /// A4 or the document's own page; margins of the writing area, in twips.
    static func page(of notebook: Notebook) -> (width: Int, height: Int, side: Int, top: Int) {
        let size = notebook.pages.first?.geometry?.displaySize ?? .a4
        let margin = notebook.pages.first?.writingRect(.page)
        return (Int(size.width * 20), Int(size.height * 20), Int((margin?.x ?? 57) * 20), Int((margin?.y ?? 57) * 20))
    }

    // MARK: Word

    /// A link as typed can hold spaces; a relationship target must be a URI.
    private static func uri(_ link: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.insert(charactersIn: "#[]%")
        return link.addingPercentEncoding(withAllowedCharacters: allowed) ?? link
    }
    private static func xml(_ text: String) -> String {
        var result = ""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            case "'": result += "&apos;"
            default:
                // XML 1.0 has no other control characters.
                guard scalar.value >= 0x20 || scalar.value == 9, scalar.value != 0xFFFE, scalar.value != 0xFFFF else { continue }
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }

    /// Word's own names: its paragraph styles show up as such in the app.
    private static func styleID(_ preset: TextStylePreset) -> String? {
        switch preset {
        case .title: "Title"; case .heading: "Heading1"; case .subheading: "Heading2"; case .body: nil; case .caption: "Caption"
        }
    }

    private static func runProperties(_ style: TextBoxStyle, preset: TextStylePreset, link: Bool) -> String {
        var result = link ? "<w:rStyle w:val=\"Hyperlink\"/>" : ""
        if let font = fontName(style) { let name = xml(font); result += "<w:rFonts w:ascii=\"\(name)\" w:hAnsi=\"\(name)\" w:cs=\"\(name)\"/>" }
        if style.bold != preset.bold { result += style.bold ? "<w:b/>" : "<w:b w:val=\"0\"/>" }
        if style.italic { result += "<w:i/>" }
        if style.strikethrough == true { result += "<w:strike/>" }
        if let color = visibleColor(style) { result += "<w:color w:val=\"\(color)\"/>" }
        if style.fontSize != preset.fontSize { result += "<w:sz w:val=\"\(Int((style.fontSize * 2).rounded()))\"/>" }
        if let marker = markerColor(style) {
            let named = ["FFFF00": "yellow", "00FF00": "green", "00FFFF": "cyan", "FF00FF": "magenta"][marker]
            if let named { result += "<w:highlight w:val=\"\(named)\"/>" }
        }
        if style.underline { result += "<w:u w:val=\"single\"/>" }
        if let marker = markerColor(style), !["FFFF00", "00FF00", "00FFFF", "FF00FF"].contains(marker) {
            result += "<w:shd w:val=\"clear\" w:color=\"auto\" w:fill=\"\(marker)\"/>"
        }
        if let baseline = style.baseline, baseline != 0 { result += "<w:vertAlign w:val=\"\(baseline > 0 ? "superscript" : "subscript")\"/>" }
        return result.isEmpty ? "" : "<w:rPr>\(result)</w:rPr>"
    }

    private static func run(_ text: String, _ style: TextBoxStyle, preset: TextStylePreset, link: Bool) -> String {
        var content = ""
        for (index, part) in text.split(separator: "\t", omittingEmptySubsequences: false).enumerated() {
            if index > 0 { content += "<w:tab/>" }
            if !part.isEmpty { content += "<w:t xml:space=\"preserve\">\(xml(String(part)))</w:t>" }
        }
        return "<w:r>\(runProperties(style, preset: preset, link: link))\(content)</w:r>"
    }

    /// `numbers`: `w:num` entries behind the four fixed lists; a numbered run
    /// keeps its first number, as a page of a list continues the one before it.
    private struct Numbering {
        var runs: [(id: Int, level: Int, start: Int)] = []
        var current: Int?
        var expected: [Int: Int] = [:]
        mutating func id(for marker: Block.Marker, level: Int) -> Int {
            switch marker {
            case .bullet: return 1
            case .open: return 3
            case .done: return 4
            case .number(let number):
                if current == nil || expected[level, default: 1] != number {
                    current = 5 + runs.count
                    runs.append((current!, level, number))
                }
                expected[level] = number + 1
                for deeper in expected.keys where deeper > level { expected[deeper] = nil }
                return current!
            }
        }
        mutating func paragraphEnded() { current = nil; expected = [:] }
    }

    private static let namespaces = "xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\""
        + " xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\""
    private static let header = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"

    private static func documentXML(_ blocks: [Block], notebook: Notebook, links: inout [String], numbering: inout Numbering) -> String {
        var body = ""
        for block in blocks {
            if block.separated { body += "<w:p/>"; numbering.paragraphEnded() }
            var properties = styleID(block.preset).map { "<w:pStyle w:val=\"\($0)\"/>" } ?? ""
            let level = min(8, block.level)
            if let marker = block.marker {
                properties += "<w:numPr><w:ilvl w:val=\"\(level)\"/><w:numId w:val=\"\(numbering.id(for: marker, level: level))\"/></w:numPr>"
            } else {
                numbering.paragraphEnded()
                if let indent = block.style.indent, indent > 0 { properties += "<w:ind w:left=\"\(Int(indent * 20))\"/>" }
            }
            switch block.style.alignment ?? .left {
            case .left: break
            case .center: properties += "<w:jc w:val=\"center\"/>"
            case .right: properties += "<w:jc w:val=\"right\"/>"
            case .justified: properties += "<w:jc w:val=\"both\"/>"
            }
            var runs = "", index = 0
            while index < block.spans.count {
                let span = block.spans[index]
                guard let link = span.style.link else {
                    runs += run(span.text, span.style, preset: block.preset, link: false); index += 1; continue
                }
                var inner = ""
                while index < block.spans.count, block.spans[index].style.link == link {
                    inner += run(block.spans[index].text, block.spans[index].style, preset: block.preset, link: true); index += 1
                }
                if !links.contains(link) { links.append(link) }
                runs += "<w:hyperlink r:id=\"rIdLink\(links.firstIndex(of: link)! + 1)\" w:history=\"1\">\(inner)</w:hyperlink>"
            }
            if block.pageBreak { runs += "<w:r><w:br w:type=\"page\"/></w:r>" }
            body += "<w:p>" + (properties.isEmpty ? "" : "<w:pPr>\(properties)</w:pPr>") + runs + "</w:p>"
        }
        let page = page(of: notebook)
        let landscape = page.width > page.height ? " w:orient=\"landscape\"" : ""
        return header + "<w:document \(namespaces)><w:body>\(body)<w:sectPr><w:pgSz w:w=\"\(page.width)\" w:h=\"\(page.height)\"\(landscape)/>"
            + "<w:pgMar w:top=\"\(page.top)\" w:right=\"\(page.side)\" w:bottom=\"\(page.top)\" w:left=\"\(page.side)\" w:header=\"0\" w:footer=\"0\" w:gutter=\"0\"/>"
            + "</w:sectPr></w:body></w:document>"
    }

    private static var stylesXML: String {
        func paragraph(_ id: String, _ name: String, _ preset: TextStylePreset, heading: Int? = nil) -> String {
            let outline = heading.map { "<w:keepNext/><w:outlineLvl w:val=\"\($0)\"/>" } ?? ""
            return "<w:style w:type=\"paragraph\" w:styleId=\"\(id)\"><w:name w:val=\"\(name)\"/><w:basedOn w:val=\"Normal\"/><w:next w:val=\"Normal\"/><w:qFormat/>"
                + (outline.isEmpty ? "" : "<w:pPr>\(outline)</w:pPr>")
                + "<w:rPr>\(preset.bold ? "<w:b/>" : "")<w:sz w:val=\"\(Int(preset.fontSize * 2))\"/></w:rPr></w:style>"
        }
        return header + "<w:styles \(namespaces)><w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii=\"Arial\" w:hAnsi=\"Arial\" w:cs=\"Arial\"/>"
            + "<w:sz w:val=\"\(Int(TextStylePreset.body.fontSize * 2))\"/><w:lang w:val=\"de-DE\"/></w:rPr></w:rPrDefault><w:pPrDefault><w:pPr><w:spacing w:after=\"0\"/></w:pPr></w:pPrDefault></w:docDefaults>"
            + "<w:style w:type=\"paragraph\" w:default=\"1\" w:styleId=\"Normal\"><w:name w:val=\"Normal\"/><w:qFormat/></w:style>"
            + paragraph("Title", "Title", .title) + paragraph("Heading1", "heading 1", .heading, heading: 0)
            + paragraph("Heading2", "heading 2", .subheading, heading: 1) + paragraph("Caption", "caption", .caption)
            + "<w:style w:type=\"character\" w:styleId=\"Hyperlink\"><w:name w:val=\"Hyperlink\"/><w:rPr><w:color w:val=\"0563C1\"/><w:u w:val=\"single\"/></w:rPr></w:style>"
            + "</w:styles>"
    }

    private static func numberingXML(_ numbering: Numbering) -> String {
        func list(_ id: Int, format: String, text: (Int) -> String) -> String {
            let levels = (0...8).map { level in
                "<w:lvl w:ilvl=\"\(level)\"><w:start w:val=\"1\"/><w:numFmt w:val=\"\(format)\"/><w:lvlText w:val=\"\(xml(text(level)))\"/><w:lvlJc w:val=\"left\"/>"
                    + "<w:pPr><w:ind w:left=\"\(400 * (level + 1))\" w:hanging=\"320\"/></w:pPr></w:lvl>"
            }.joined()
            return "<w:abstractNum w:abstractNumId=\"\(id)\"><w:multiLevelType w:val=\"hybridMultilevel\"/>\(levels)</w:abstractNum>"
        }
        let fixed = (1...4).map { "<w:num w:numId=\"\($0)\"><w:abstractNumId w:val=\"\($0 - 1)\"/></w:num>" }.joined()
        let numbered = numbering.runs.map { run in
            "<w:num w:numId=\"\(run.id)\"><w:abstractNumId w:val=\"1\"/><w:lvlOverride w:ilvl=\"\(run.level)\"><w:startOverride w:val=\"\(run.start)\"/></w:lvlOverride></w:num>"
        }.joined()
        return header + "<w:numbering \(namespaces)>"
            + list(0, format: "bullet") { TextListEditing.bulletGlyphs[$0 % TextListEditing.bulletGlyphs.count] }
            + list(1, format: "decimal") { "%\($0 + 1)." } + list(2, format: "bullet") { _ in "☐" } + list(3, format: "bullet") { _ in "☑" }
            + fixed + numbered + "</w:numbering>"
    }

    /// The `.docx` file; empty without text.
    public static func word(_ notebook: Notebook) -> Data {
        let blocks = blocks(of: notebook)
        guard !blocks.isEmpty else { return Data() }
        var links: [String] = [], numbering = Numbering()
        let document = documentXML(blocks, notebook: notebook, links: &links, numbering: &numbering)
        let package = "http://schemas.openxmlformats.org/package/2006"
        let office = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
        let wordType = "application/vnd.openxmlformats-officedocument.wordprocessingml"
        let parts: [(String, String)] = [
            ("[Content_Types].xml", header + "<Types xmlns=\"\(package)/content-types\">"
                + "<Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/>"
                + "<Override PartName=\"/word/document.xml\" ContentType=\"\(wordType).document.main+xml\"/>"
                + "<Override PartName=\"/word/styles.xml\" ContentType=\"\(wordType).styles+xml\"/>"
                + "<Override PartName=\"/word/numbering.xml\" ContentType=\"\(wordType).numbering+xml\"/>"
                + "<Override PartName=\"/word/settings.xml\" ContentType=\"\(wordType).settings+xml\"/>"
                + "<Override PartName=\"/docProps/core.xml\" ContentType=\"application/vnd.openxmlformats-package.core-properties+xml\"/></Types>"),
            ("_rels/.rels", header + "<Relationships xmlns=\"\(package)/relationships\">"
                + "<Relationship Id=\"rId1\" Type=\"\(office)/officeDocument\" Target=\"word/document.xml\"/>"
                + "<Relationship Id=\"rId2\" Type=\"http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties\" Target=\"docProps/core.xml\"/></Relationships>"),
            ("docProps/core.xml", header + "<cp:coreProperties xmlns:cp=\"http://schemas.openxmlformats.org/package/2006/metadata/core-properties\" xmlns:dc=\"http://purl.org/dc/elements/1.1/\">"
                + "<dc:title>\(xml(notebook.title))</dc:title></cp:coreProperties>"),
            ("word/_rels/document.xml.rels", header + "<Relationships xmlns=\"\(package)/relationships\">"
                + "<Relationship Id=\"rId1\" Type=\"\(office)/styles\" Target=\"styles.xml\"/>"
                + "<Relationship Id=\"rId2\" Type=\"\(office)/numbering\" Target=\"numbering.xml\"/>"
                + "<Relationship Id=\"rId3\" Type=\"\(office)/settings\" Target=\"settings.xml\"/>"
                + links.enumerated().map { "<Relationship Id=\"rIdLink\($0.offset + 1)\" Type=\"\(office)/hyperlink\" Target=\"\(xml(uri($0.element)))\" TargetMode=\"External\"/>" }.joined()
                + "</Relationships>"),
            ("word/document.xml", document),
            ("word/styles.xml", stylesXML),
            ("word/numbering.xml", numberingXML(numbering)),
            ("word/settings.xml", header + "<w:settings \(namespaces)><w:compat><w:compatSetting w:name=\"compatibilityMode\" w:uri=\"http://schemas.microsoft.com/office/word\" w:val=\"15\"/></w:compat></w:settings>")]
        return ZipStore.archive(parts.map { ($0.0, Data($0.1.utf8)) })
    }

    // MARK: RTF

    private static func rtfText(_ text: String) -> String {
        var result = ""
        for unit in text.utf16 {
            switch unit {
            case 0x5C: result += "\\\\"
            case 0x7B: result += "\\{"
            case 0x7D: result += "\\}"
            case 9: result += "\\tab "
            case 0x20...0x7E: result.unicodeScalars.append(Unicode.Scalar(UInt8(unit)))
            case 0..<0x20: break
            default: result += "\\u\(Int(Int16(truncatingIfNeeded: unit)))?"
            }
        }
        return result
    }

    /// The same paragraphs as Word; list markers stay text, the indent carries the nesting.
    public static func rtf(_ notebook: Notebook) -> String {
        let blocks = blocks(of: notebook)
        guard !blocks.isEmpty else { return "" }
        var colors: [String] = [], fonts = ["Arial"]
        func color(_ value: String) -> Int {
            if !colors.contains(value) { colors.append(value) }
            return colors.firstIndex(of: value)! + 1
        }
        func font(_ value: String?) -> Int {
            guard let value else { return 0 }
            if !fonts.contains(value) { fonts.append(value) }
            return fonts.firstIndex(of: value)!
        }
        func span(_ text: String, _ style: TextBoxStyle) -> String {
            var codes = "\\f\(font(fontName(style)))\\fs\(Int((style.fontSize * 2).rounded()))"
            if style.bold { codes += "\\b" }
            if style.italic { codes += "\\i" }
            if style.underline { codes += "\\ul" }
            if style.strikethrough == true { codes += "\\strike" }
            if let value = visibleColor(style) { codes += "\\cf\(color(value))" }
            if let value = markerColor(style) { codes += "\\highlight\(color(value))" }
            if style.baseline == 1 { codes += "\\super" } else if style.baseline == -1 { codes += "\\sub" }
            let body = "{\(codes) \(rtfText(text))}"
            guard let link = style.link else { return body }
            return "{\\field{\\*\\fldinst{HYPERLINK \"\(rtfText(link).replacingOccurrences(of: "\"", with: "\\\""))\"}}{\\fldrslt\(body)}}"
        }
        var body = ""
        for block in blocks {
            if block.separated { body += "\\pard\\par\n" }
            var paragraph = "\\pard"
            switch block.style.alignment ?? .left {
            case .left: break
            case .center: paragraph += "\\qc"
            case .right: paragraph += "\\qr"
            case .justified: paragraph += "\\qj"
            }
            let indent = block.marker != nil ? (block.level + 1) * 400 : Int((block.style.indent ?? 0) * 20)
            if indent > 0 { paragraph += "\\li\(indent)" }
            paragraph += " "
            if let marker = block.marker {
                let text: String = switch marker {
                case .bullet: TextListEditing.bullet(forLevel: block.level)
                case .number(let number): "\(number). "
                case .open: "☐ "
                case .done: "☑ "
                }
                paragraph += span(text, block.style)
            }
            paragraph += block.spans.map { span($0.text, $0.style) }.joined()
            body += paragraph + (block.pageBreak ? "\\par\\page\n" : "\\par\n")
        }
        let page = page(of: notebook)
        let table = colors.map { value -> String in
            let number = Int(value, radix: 16) ?? 0
            return "\\red\(number >> 16)\\green\((number >> 8) & 255)\\blue\(number & 255);"
        }.joined()
        let fontTable = fonts.enumerated().map { "{\\f\($0.offset) \(rtfText($0.element));}" }.joined()
        return "{\\rtf1\\ansi\\ansicpg1252\\deff0\\uc1{\\fonttbl\(fontTable)}{\\colortbl;\(table)}"
            + "\\paperw\(page.width)\\paperh\(page.height)\\margl\(page.side)\\margr\(page.side)\\margt\(page.top)\\margb\(page.top)\n\(body)}\n"
    }
}
