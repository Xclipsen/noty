import Foundation

/// Text documents (Textneubau Stufe 3, docs/TEXT-REBUILD-62.md §4): a library
/// document of its own kind with one text flow (the former word mode:
/// `TextFlow.swift`, `reflowText`) over paper pages. Pages only come from the
/// text; the editor shows one empty reserve page after them (the unsaved
/// writing draft). Handwriting, free text fields, images and shapes stay on
/// their page like in a notebook; the flow never moves them.
///
/// Stored with schema 15 and `kind: "textDocument"`. Rules (also
/// `scripts/notebook_format.py`): only paper pages (blank/lined/grid, own
/// geometry, no writing space, no PDF), no PDF originals, flow segments only
/// in the page region, at most one flow over the active pages.
extension Notebook {
    /// A new text document: A4 portrait or landscape, blank paper by default,
    /// one page with an empty flow in the writing area of former page text
    /// (`Page.writingRect(.page)`), body text in automatic colour.
    public static func textDocument(title: String, landscape: Bool = false, paper: PaperStyle = .blank,
                                    color: PaperColor = .white) throws -> Notebook {
        guard paper != .legacyTest else { throw StorageError.invalidDocument }
        var appearance = NotebookAppearance()
        appearance.coverEnabled = false; appearance.format = .a4; appearance.landscape = landscape
        appearance.paper = paper; appearance.color = color
        var result = try blank(title: title, appearance: appearance)
        result.kind = .textDocument
        result.schemaVersion = textDocumentSchemaVersion
        result.pages[0].textBoxes = [try result.pages[0].emptyTextFlow(id: UUID(), dark: color == .dark)]
        try result.validate()
        return result
    }

    func validateTextDocument() throws {
        guard pdf == nil, let sources = pdfSources, sources.isEmpty else { throw StorageError.invalidDocument }
        for page in pages + (deletedPages ?? []).map(\.page) {
            guard page.pdfReference == nil, page.margins == nil, page.geometry != nil, page.text.isEmpty,
                  let paper = page.paper, paper != .legacyTest else { throw StorageError.invalidDocument }
            for box in page.textBoxes ?? [] where box.flowID != nil {
                guard box.flowRegion == .page else { throw StorageError.invalidDocument }
            }
        }
        let flows = Set(pages.flatMap { ($0.textBoxes ?? []).compactMap(\.flowID) })
        guard flows.count <= 1 else { throw StorageError.invalidDocument }
    }

    /// The flow of a text document: its segments in page order (active pages).
    public var textFlowSegments: [(pageID: UUID, box: TextBox)] {
        guard let flow = pages.lazy.compactMap({ $0.effectiveTextBoxes.first(where: { $0.flowID != nil })?.flowID }).first else { return [] }
        return pages.compactMap { page in page.effectiveTextBoxes.first { $0.flowID == flow }.map { (page.id, $0) } }
    }

    /// The whole flow as one box (runs and styles of every segment).
    public var textFlowContent: TextBox? {
        let segments = textFlowSegments
        guard var result = segments.first?.box else { return nil }
        for segment in segments.dropFirst() { result = result.appending(segment.box) }
        return result
    }

    /// Caret behind the last written character of the flow: a tap below the
    /// text, on a page after it or on the reserve page. Empty segments after
    /// the text (pages kept for their handwriting) are skipped.
    public var textFlowEndFocus: TextFlowFocus? {
        let segments = textFlowSegments
        guard let target = segments.last(where: { !$0.box.text.isEmpty }) ?? segments.first else { return nil }
        let length = (target.box.text as NSString).length
        let style = length > 0 ? target.box.style(at: length - 1) : target.box.style
        return TextFlowFocus(pageID: target.pageID, boxID: target.box.id,
                             selection: NSRange(location: length, length: 0), typingStyle: style)
    }

    /// A text document without a flow (not written by this build) gets an
    /// empty one on its first page; nil if it has one or is no text document.
    public func addingTextFlow(dark: Bool = false) throws -> (Notebook, TextFlowFocus)? {
        guard isTextDocument, textFlowSegments.isEmpty else { return nil }
        var next = try preparedForTextEditing()
        let box = try next.pages[0].emptyTextFlow(id: UUID(), dark: dark || next.pages[0].paperColor == .dark)
        next.pages[0].textBoxes = (next.pages[0].textBoxes ?? []) + [box]
        next.raiseSchemaForTextColors([box])
        try next.validate()
        return (next, TextFlowFocus(pageID: next.pages[0].id, boxID: box.id, selection: NSRange(location: 0, length: 0), typingStyle: box.style))
    }

    /// Text documents: pages after the text that hold nothing (no flow text,
    /// no ink, no field, image or shape) are removed – pages only come from
    /// the text. Never the first page, never one in `keeping`, never the page
    /// of the first flow segment; written pages (also handwriting after the
    /// text) stay. `drawingIsEmpty`: the app decodes PencilKit data; Core only
    /// knows empty bytes.
    public func trimmingEmptyTrailingPages(keeping: Set<UUID> = [], drawingIsEmpty: (Data) -> Bool = { $0.isEmpty }) -> Notebook {
        guard isTextDocument else { return self }
        var next = self
        let first = textFlowSegments.first?.pageID
        while next.pages.count > 1, let last = next.pages.last, !keeping.contains(last.id), last.id != first,
              last.holdsNothingInTextDocument(drawingIsEmpty: drawingIsEmpty) {
            next.pages.removeLast()
        }
        return next
    }

    /// Pages a text document exports (PDF): without trailing pages that hold
    /// nothing, never fewer than the first page. Notebooks: every page.
    public func exportedPageIDs(drawingIsEmpty: (Data) -> Bool = { $0.isEmpty }) -> [UUID] {
        trimmingEmptyTrailingPages(drawingIsEmpty: drawingIsEmpty).pages.map(\.id)
    }
}

extension Page {
    /// An empty flow segment in the page's writing area (the region of former page text).
    func emptyTextFlow(id: UUID, dark: Bool) throws -> TextBox {
        guard let rect = writingRect(.page) else { throw StorageError.invalidDocument }
        var style = TextBoxStyle(fontSize: TextStylePreset.body.fontSize, color: dark ? .white : .black)
        style.automaticColor = true
        var box = TextBox(x: rect.x, y: rect.y, width: rect.width, height: rect.height, style: style)
        box.flowID = id; box.flowRegion = .page
        return box
    }

    func holdsNothingInTextDocument(drawingIsEmpty: (Data) -> Bool) -> Bool {
        pdfReference == nil && drawingIsEmpty(drawing) && (images ?? []).isEmpty && (shapes ?? []).isEmpty
            && effectiveTextBoxes.allSatisfy { $0.flowID != nil && $0.text.isEmpty }
    }
}

/// Text/Markdown export of a text document's flow (Teilen-Menü). Only the
/// flow is exported; handwriting, free fields, images and shapes are in the
/// PDF. Paragraph styles become headings (Titel `#`, Überschrift `##`,
/// Unterüberschrift `###`), list markers Markdown lists (`-`, `1.`,
/// `- [ ]`, `- [x]`, nesting four spaces per level), bold `**`, italic `*`
/// (unlike `_` it also works inside a word).
public enum TextDocumentExport {
    public enum Format: Sendable { case plainText, markdown
        public var fileExtension: String { self == .markdown ? "md" : "txt" }
    }

    public static func export(_ notebook: Notebook, as format: Format) -> String {
        format == .markdown ? markdown(notebook) : plainText(notebook)
    }

    /// The flow's text as written (list markers stay), line separators as
    /// line breaks, ending with one line break.
    public static func plainText(_ notebook: Notebook) -> String {
        guard let box = notebook.textFlowContent else { return "" }
        let lines = paragraphs(box.text).map { (box.text as NSString).substring(with: $0) }
        var text = lines.joined(separator: "\n")
        while text.hasSuffix("\n") { text.removeLast() }
        return text.isEmpty ? "" : text + "\n"
    }

    public static func markdown(_ notebook: Notebook) -> String {
        guard let box = notebook.textFlowContent else { return "" }
        return markdown(box)
    }

    /// One paragraph per line of the flow; blocks are separated by an empty
    /// line, consecutive list items by a line break. Empty paragraphs vanish.
    static func markdown(_ box: TextBox) -> String {
        let source = box.text as NSString
        var blocks: [(text: String, list: Bool)] = []
        for range in paragraphs(box.text) {
            let line = source.substring(with: range)
            // Indentation characters before a marker belong to the structure.
            let leading = line.prefix { $0 == " " || $0 == "\t" }
            let rest = String(line.dropFirst(leading.count))
            let leadingLength = (String(leading) as NSString).length
            if let marker = TextListEditing.prefix(rest) {
                let level = box.listLevel(at: range.location)
                let indentation = String(repeating: "    ", count: level)
                let content = NSRange(location: range.location + leadingLength + (marker as NSString).length,
                                      length: range.length - leadingLength - (marker as NSString).length)
                let item: String
                switch marker {
                case "☐ ": item = "- [ ] "
                case "☑ ": item = "- [x] "
                case "• ", "- ", "◦ ", "▪ ": item = "- "
                default: item = marker // "12. "
                }
                blocks.append((indentation + item + inline(box, content, emphasis: true), true))
                continue
            }
            guard !rest.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            let preset = TextStylePreset.matching(box.style(at: range.location + leadingLength))
            let content = NSRange(location: range.location + leadingLength, length: range.length - leadingLength)
            switch preset {
            case .title: blocks.append(("# " + inline(box, content, emphasis: false), false))
            case .heading: blocks.append(("## " + inline(box, content, emphasis: false), false))
            case .subheading: blocks.append(("### " + inline(box, content, emphasis: false), false))
            case .body, .caption: blocks.append((escapeLineStart(inline(box, content, emphasis: true)), false))
            }
        }
        var result = ""
        for (index, block) in blocks.enumerated() {
            if index > 0 { result += block.list && blocks[index - 1].list ? "\n" : "\n\n" }
            result += block.text
        }
        return result.isEmpty ? "" : result + "\n"
    }

    /// Paragraph ranges without their terminator (LF, CR, CRLF, U+2028, U+2029).
    static func paragraphs(_ text: String) -> [NSRange] {
        let value = text as NSString
        var result: [NSRange] = [], start = 0, index = 0
        while index < value.length {
            let unit = value.character(at: index)
            if [10, 13, 0x2028, 0x2029].contains(unit) {
                result.append(NSRange(location: start, length: index - start))
                if unit == 13, index + 1 < value.length, value.character(at: index + 1) == 10 { index += 1 }
                start = index + 1
            }
            index += 1
        }
        if start < value.length { result.append(NSRange(location: start, length: value.length - start)) }
        return result
    }

    /// Text of `range` with Markdown escapes; bold/italic runs wrapped in
    /// `**`/`*` (headings are bold by their preset: `emphasis == false`
    /// keeps only italics). White space stays outside the markers.
    static func inline(_ box: TextBox, _ range: NSRange, emphasis: Bool) -> String {
        guard range.length > 0 else { return "" }
        let source = box.text as NSString
        // Neighbouring runs that differ only in other attributes (marker,
        // colour) form one emphasis span, so no „**a****b**“ appears.
        var spans: [(text: String, bold: Bool, italic: Bool)] = []
        for run in box.styleRuns {
            let part = NSIntersectionRange(range, NSRange(location: run.location, length: run.length))
            guard part.length > 0 else { continue }
            let text = source.substring(with: part), bold = emphasis && run.style.bold, italic = run.style.italic
            if let last = spans.last, last.bold == bold, last.italic == italic { spans[spans.count - 1].text += text }
            else { spans.append((text, bold, italic)) }
        }
        var result = ""
        for span in spans {
            let core = span.text.trimmingCharacters(in: .whitespaces)
            guard span.bold || span.italic, !core.isEmpty else { result += escape(span.text); continue }
            let head = span.text.prefix { $0 == " " || $0 == "\t" }
            let tail = String(span.text.reversed().prefix { $0 == " " || $0 == "\t" })
            var text = escape(core)
            if span.italic { text = "*" + text + "*" }
            if span.bold { text = "**" + text + "**" }
            result += String(head) + text + tail
        }
        return result
    }

    static func escape(_ text: String) -> String {
        var result = ""
        for character in text {
            if "\\`*_[]<>".contains(character) { result.append("\\") }
            result.append(character)
        }
        return result
    }

    /// A body paragraph must not start a heading, quote, list or rule by accident.
    static func escapeLineStart(_ text: String) -> String {
        guard let first = text.first else { return text }
        if "#+-=|".contains(first) { return "\\" + text }
        let digits = text.prefix { $0.isASCII && $0.isNumber }
        if !digits.isEmpty, digits.count <= 9 {
            let after = text.dropFirst(digits.count)
            if after.hasPrefix(". ") || after.hasPrefix(") ") || after == "." || after == ")" {
                return String(digits) + "\\" + after
            }
        }
        return text
    }
}
