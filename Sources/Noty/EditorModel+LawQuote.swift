// „Als Zitat einfügen“ aus der Vorschaukarte (docs/PARAGRAPH-LINKS.md, P2):
// ein gewöhnliches freies Textfeld mit dem Gesetzestext und einer kleineren,
// kursiven Quellenzeile, direkt unter dem Verweis. Derselbe Weg wie jede
// Textfeldänderung (`updateTextBoxes`): rückgängig machbar, automatisch
// gesichert, auswählbar. Nie außerhalb der Seite, nie still abgeschnitten.
import UIKit
import NotebookCore

extension EditorModel {
    /// Inserts the quote on its page; nil when done, otherwise a message for the user.
    func insertLawQuote(_ request: LawQuoteRequest) -> String? {
        guard writable, !busy, !mutationsPaused else { return "Das Heft kann gerade nicht bearbeitet werden. Das Zitat wurde nicht eingefügt." }
        // A free field in a text document would lie over the flow and could not be edited there.
        guard !notebook.isTextDocument else { return "In Textdokumenten lässt sich noch kein Zitat einfügen. Den Text bitte in der Gesetzessammlung kopieren." }
        guard let index = notebook.pages.firstIndex(where: { $0.id == request.pageID }) else { return "Die Seite gibt es nicht mehr. Das Zitat wurde nicht eingefügt." }
        let page = notebook.pages[index]
        let existing = page.effectiveTextBoxes
        guard existing.count < 200 else { return "Höchstens 200 Textfelder pro Seite. Das Zitat wurde nicht eingefügt." }
        let source = sourcePage(for: page)
        let layout = (try? PageLayout(page: page, source: source?.pageRef)) ?? pageLayout
        guard let box = LawQuotePlacement.box(request, page: page, layout: layout, hasPDF: source != nil) else {
            return "Das Zitat ist zu lang für diese Seite und wurde nicht eingefügt. Ein kürzerer Ausschnitt lässt sich in der Gesetzessammlung kopieren."
        }
        // A step of its own: undo takes the quote, not text typed just before.
        separateUndoStep()
        updateTextBoxes(existing + [box], pageID: request.pageID)
        separateUndoStep()
        guard notebook.pages.first(where: { $0.id == request.pageID })?.effectiveTextBoxes.contains(where: { $0.id == box.id }) == true else {
            return error ?? "Das Zitat konnte nicht eingefügt werden."
        }
        return nil
    }
}

/// Size and place of a quote field, in canonical page coordinates.
@MainActor
enum LawQuotePlacement {
    /// Distance to the page edge and to the citation.
    static let inset = 12.0
    static let gap = 6.0

    static func box(_ request: LawQuoteRequest, page: Page, layout: PageLayout, hasPDF: Bool) -> TextBox? {
        let content = layout.contentCanvas
        let area = PageRect(x: inset, y: inset, width: content.width - 2 * inset, height: content.height - 2 * inset)
        guard area.width > 40, area.height > 20 else { return nil }
        let quote = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let sourceLine = request.source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !quote.isEmpty else { return nil }

        // Remembered style (colour that stays readable on this paper), a
        // little smaller for a quote; the source line smaller and italic.
        let pdfArea = hasPDF && !layout.sourceFrame.cgRect.contains(CGPoint(x: request.below.x + layout.contentOrigin.x, y: request.below.y + layout.contentOrigin.y))
        let dark = hasPDF ? (pdfArea && page.margins?.color == .dark) : page.paperColor == .dark
        let units = TextSizeUnits(pageWidth: content.width, hasPDF: hasPDF)
        var style = TextStyleMemory.style(light: dark)
        let visible = min(style.fontSize, 14)
        style.fontSize = clampSize(units.stored(visible))
        style.bold = false; style.italic = false; style.underline = false
        style.highlighted = nil; style.highlightColor = nil; style.link = nil; style.strikethrough = nil; style.baseline = nil
        style.alignment = nil; style.indent = nil
        var small = style
        small.fontSize = clampSize(units.stored(max(9, visible - 3)))
        small.italic = true

        let text = sourceLine.isEmpty ? quote : quote + "\n" + sourceLine
        var box = TextBox(x: area.x, y: area.y, width: area.width, height: 20, text: text, style: style)
        if !sourceLine.isEmpty {
            let quoteLength = (quote as NSString).length + 1
            box.runs = [TextRun(location: 0, length: quoteLength, style: style),
                        TextRun(location: quoteLength, length: (sourceLine as NSString).length, style: small)]
        }
        guard (try? box.validate()) != nil else { return nil }

        // Width: most of the text area, from the citation's left edge on.
        let preferred = min(area.width, max(320, area.width * 0.62))
        for width in [preferred, area.width] {
            box.width = width
            box.x = min(max(request.below.x, area.x), area.x + area.width - width)
            box.height = ceil(Double(TextObjectLayout(box, paper: page.linePaper, hanging: .never).usedHeight)) + 2
            if box.rotatedBounds.height <= area.height { break }
        }
        guard box.rotatedBounds.height <= area.height else { return nil }

        // Below the citation, else above it, else the nearest free place on
        // the page; with none free the nearest place inside the page.
        let obstacles = page.effectiveTextBoxes.map(\.rotatedBounds) + (page.images ?? []).map(\.rotatedBounds)
        func free(_ candidate: TextBox) -> Bool {
            candidate.fits(in: area) && !obstacles.contains { intersects($0, candidate.rotatedBounds) }
        }
        func at(_ y: Double) -> TextBox { var b = box; b.y = y; return b }
        let below = at(request.below.y + request.below.height + gap)
        if free(below) { return below }
        let above = at(request.below.y - gap - box.height)
        if free(above) { return above }
        let top = area.y, bottom = area.y + area.height - box.height
        let wanted = min(max(below.y, top), bottom)
        var candidates: [Double] = []
        var y = top
        while y <= bottom { candidates.append(y); y += 8 }
        candidates.append(bottom)
        for y in candidates.sorted(by: { abs($0 - wanted) < abs($1 - wanted) }) where free(at(y)) { return at(y) }
        let fallback = at(wanted)
        return fallback.fits(in: area) ? fallback : nil
    }

    private static func clampSize(_ size: Double) -> Double { min(96, max(8, size)) }
    private static func intersects(_ a: PageRect, _ b: PageRect) -> Bool {
        a.x < b.x + b.width && b.x < a.x + a.width && a.y < b.y + b.height && b.y < a.y + a.height
    }
}
