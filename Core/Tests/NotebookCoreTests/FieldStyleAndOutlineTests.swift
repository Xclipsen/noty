import Foundation
import XCTest
@testable import NotebookCore

/// Textneubau Stufe 4 (docs/TEXT-REBUILD-62.md): Feldstil of free text
/// fields (fill, frame, padding; schema 14) and the Gliederung of text documents.
final class FieldStyleAndOutlineTests: XCTestCase {
    private func p(_ x: Double, _ y: Double) -> PagePoint { PagePoint(x: x, y: y) }

    // MARK: Feldstil · format

    func testFieldStyleIsSchemaFourteenOnlyRaisesWhenUsedAndRoundTrips() throws {
        var book = try Notebook.blank(title: "Feldstil", appearance: NotebookAppearance())
        let id = book.pages[0].id
        var field = TextBox(x: 40, y: 40, width: 200, height: 30, text: "Merke")
        try book.replaceTextBoxes([field], pageID: id)
        let lower = book.schemaVersion
        XCTAssertLessThan(lower, 14, "unstyled fields keep the older format")
        let plain = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(field)) as? [String: Any])
        XCTAssertNil(plain["fill"]); XCTAssertNil(plain["border"])

        field.fill = .yellow
        try book.replaceTextBoxes([field], pageID: id)
        XCTAssertEqual(book.schemaVersion, 14)
        var stale = book; stale.schemaVersion = lower
        XCTAssertThrowsError(try stale.validate(), "a fill under schema 13 or lower")
        field.fill = nil; field.border = .accent
        var framed = try Notebook.blank(title: "Rahmen", appearance: NotebookAppearance())
        try framed.replaceTextBoxes([field], pageID: framed.pages[0].id)
        XCTAssertEqual(framed.schemaVersion, 14)
        // Removing the style never lowers the schema.
        field.border = nil
        try book.replaceTextBoxes([field], pageID: id)
        XCTAssertEqual(book.schemaVersion, 14)

        // Stored as plain strings, decoded unchanged (also in the page trash).
        var styled = TextBox(x: 300, y: 300, width: 120, height: 24, text: "Kasten")
        styled.fill = .purple; styled.border = .text
        try book.replaceTextBoxes([styled], pageID: id)
        let data = try JSONEncoder().encode(book)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let pages = try XCTUnwrap(object["pages"] as? [[String: Any]])
        let stored = try XCTUnwrap((pages[0]["textBoxes"] as? [[String: Any]])?.first)
        XCTAssertEqual(stored["fill"] as? String, "purple")
        XCTAssertEqual(stored["border"] as? String, "text")
        XCTAssertEqual(try Notebook.decode(data), book)
        let copy = book.pages[0].independentCopy()
        XCTAssertEqual(copy.textBoxes?.first?.fill, .purple, "restore copies and duplicated pages keep the style")
        XCTAssertNotEqual(copy.textBoxes?.first?.id, styled.id)

        // Unknown values and flow segments with a style are refused.
        var json = object
        var badPages = pages
        var badBoxes = try XCTUnwrap(badPages[0]["textBoxes"] as? [[String: Any]])
        badBoxes[0]["fill"] = "orange"
        badPages[0]["textBoxes"] = badBoxes; json["pages"] = badPages
        XCTAssertThrowsError(try Notebook.decode(JSONSerialization.data(withJSONObject: json)))
        var flow = TextBox(text: "Fluss"); flow.flowID = UUID(); flow.flowRegion = .page
        XCTAssertNoThrow(try flow.validate())
        flow.fill = .blue; XCTAssertThrowsError(try flow.validate(), "flow segments carry no field style")
        flow.fill = nil; flow.border = .text; XCTAssertThrowsError(try flow.validate())
    }

    func testTextDocumentFieldsTakeTheStyleWithinSchemaFifteen() throws {
        var document = try Notebook.textDocument(title: "Referat")
        let page = document.pages[0]
        var field = TextBox(x: 300, y: 600, width: 120, height: 24, text: "Hinweis"); field.fill = .green
        try document.replaceTextBoxes(page.effectiveTextBoxes + [field], pageID: page.id)
        XCTAssertEqual(document.schemaVersion, 15)
        XCTAssertEqual(try NotebookDecoding.decode(JSONEncoder().encode(document)).notebook, document)
    }

    // MARK: Feldstil · geometry

    func testPaddingWidensTheVisibleFrameEverywhereButNotTheText() throws {
        var box = TextBox(x: 100, y: 100, width: 200, height: 40, text: "Feld")
        XCTAssertEqual(box.fieldPadding, 0)
        XCTAssertEqual(box.rotatedBounds, box.rect)
        box.border = .text
        let p = TextBox.fieldStylePadding
        XCTAssertEqual(box.fieldPadding, p)
        XCTAssertEqual(box.rotatedBounds, PageRect(x: 100 - p, y: 100 - p, width: 200 + 2 * p, height: 40 + 2 * p))
        XCTAssertEqual(box.textCorners.first, self.p(100, 100), "the text frame stays")
        XCTAssertEqual(box.corners.first, self.p(100 - p, 100 - p))
        XCTAssertTrue(box.contains(self.p(100 - p + 0.5, 120)))
        XCTAssertFalse(box.contains(self.p(100 - p - 0.5, 120)))
        // Rotated: the padded corners turn with the field about the text's top-left corner.
        box.rotation = 90
        XCTAssertEqual(box.corners[0].x, 100 + p, accuracy: 1e-9)
        XCTAssertEqual(box.corners[0].y, 100 - p, accuracy: 1e-9)
        XCTAssertEqual(box.rotated(to: 0).center.x, box.center.x, accuracy: 1e-9, "rotation keeps the centre")

        // The page limit counts the padding; widths stop earlier.
        let limits = PageRect(x: 0, y: 0, width: 595, height: 842)
        var edge = TextBox(x: 0, y: 0, width: 200, height: 30, text: "Rand")
        XCTAssertTrue(edge.fits(in: limits))
        edge.fill = .yellow
        XCTAssertFalse(edge.fits(in: limits))
        var auto = TextBox(x: 100, y: 100, width: 50, height: 30, text: "x"); auto.fill = .gray
        XCTAssertEqual(auto.maximumWidth(in: limits), 595 - 100 - p, accuracy: 0.001)
    }

    func testApplyingAStyleKeepsTheTextOrMovesTheFieldInwards() throws {
        let limits = PageRect(x: 0, y: 0, width: 595, height: 842)
        let p = TextBox.fieldStylePadding
        let middle = TextBox(x: 100, y: 100, width: 200, height: 30, text: "Mitte")
        let styled = try XCTUnwrap(middle.styled(fill: .blue, border: nil, in: limits))
        XCTAssertEqual(styled.rect, middle.rect, "room for the padding: the text does not move")
        XCTAssertEqual(styled.fill, .blue)
        let unstyled = try XCTUnwrap(styled.styled(fill: nil, border: nil, in: limits))
        XCTAssertEqual(unstyled.rect, middle.rect, "removing never moves the text")
        XCTAssertFalse(unstyled.hasFieldStyle)

        let corner = TextBox(x: 0, y: 0, width: 200, height: 30, text: "Ecke")
        let moved = try XCTUnwrap(corner.styled(fill: nil, border: .accent, in: limits))
        XCTAssertEqual(moved.x, p, accuracy: 1e-9); XCTAssertEqual(moved.y, p, accuracy: 1e-9)
        XCTAssertTrue(moved.fits(in: limits))

        // As wide as the page: the visible field takes exactly the former frame.
        let wide = TextBox(x: 0, y: 100, width: 595, height: 60, text: "breit")
        let narrowed = try XCTUnwrap(wide.styled(fill: .pink, border: .text, in: limits))
        XCTAssertEqual(narrowed.rotatedBounds.x, 0, accuracy: 1e-9)
        XCTAssertEqual(narrowed.rotatedBounds.width, 595, accuracy: 1e-9)
        XCTAssertEqual(narrowed.width, 595 - 2 * p, accuracy: 1e-9)
        XCTAssertTrue(narrowed.fits(in: limits))
        // Restyling (other colour) of a styled field changes nothing else.
        XCTAssertEqual(try XCTUnwrap(narrowed.styled(fill: .gray, border: nil, in: limits)).rect, narrowed.rect)

        var flow = TextBox(text: "f"); flow.flowID = UUID(); flow.flowRegion = .page
        XCTAssertNil(flow.styled(fill: .yellow, border: nil, in: limits))
    }

    // MARK: Feldstil · taps and automatic colour

    func testFilledFieldsAreHitOnTheirWholeSurfaceFramesOnTheirLine() {
        var page = Page()
        var filled = TextBox(x: 40, y: 40, width: 300, height: 200, text: "gefüllt"); filled.fill = .yellow
        var framed = TextBox(x: 40, y: 300, width: 300, height: 200, text: "Rahmen"); framed.border = .accent
        let plain = TextBox(x: 40, y: 600, width: 300, height: 200, text: "ohne")
        var shape = ShapeObject(kind: .rectangle, start: p(30, 30), end: p(350, 820)); shape.fill = InkColor(0, 0, 0, 0.2)
        page.textBoxes = [filled, framed, plain]; page.shapes = [shape]
        let content = PageContent(page: page)
        // Only the first line of each field carries text.
        let lines: (TextBox, PagePoint) -> Bool = { box, point in
            let local = box.localPoint(point); return local.x >= 0 && local.x <= 120 && local.y >= 0 && local.y <= 20
        }
        // Filled: empty part of the frame and the padding take the tap.
        XCTAssertEqual(PageObjectHitTest.topmost(at: p(200, 200), in: content, textHit: lines), .text(filled.id))
        XCTAssertEqual(PageObjectHitTest.topmost(at: p(40 - 4, 100), in: content, textHit: lines), .text(filled.id))
        // Frame only: its line (± tolerance) takes the tap, the inside reaches through.
        XCTAssertEqual(PageObjectHitTest.topmost(at: p(200, 400), in: content, textHit: lines), .shape(shape.id))
        XCTAssertEqual(PageObjectHitTest.topmost(at: p(40 - TextBox.fieldStylePadding, 400), in: content, textHit: lines), .text(framed.id))
        XCTAssertEqual(PageObjectHitTest.topmost(at: p(40 - TextBox.fieldStylePadding + 3, 400), in: content, tolerance: 4, textHit: lines),
                       .text(framed.id))
        XCTAssertEqual(PageObjectHitTest.topmost(at: p(60, 310), in: content, textHit: lines), .text(framed.id), "text lines still hit")
        // Unstyled: unchanged Stufe-1 rule.
        XCTAssertEqual(PageObjectHitTest.topmost(at: p(200, 700), in: content, textHit: lines), .shape(shape.id))
        XCTAssertEqual(PageObjectHitTest.topmost(at: p(60, 610), in: content, textHit: lines), .text(plain.id))
        XCTAssertFalse(plain.fieldStyleHit(p(200, 700)))
        // Rotated filled field: the turned surface.
        var turned = TextBox(x: 400, y: 100, width: 100, height: 20, text: "schräg"); turned.rotation = 90; turned.fill = .green
        XCTAssertTrue(turned.fieldStyleHit(p(390, 150)))
        XCTAssertFalse(turned.fieldStyleHit(p(450, 110)))
    }

    func testAutomaticTextColourResolvesAgainstTheFill() throws {
        var page = Page(); page.paperColor = .dark
        var style = TextBoxStyle(color: .white); style.automaticColor = true
        var box = TextBox(x: 40, y: 40, width: 200, height: 30, text: "auto", style: style)
        XCTAssertTrue(page.automaticTextIsLight(box), "dark paper: light text")
        box.fill = .yellow
        XCTAssertFalse(page.automaticTextIsLight(box), "light fill: dark text, also on dark paper")
        box.fill = nil; box.border = .text
        XCTAssertTrue(page.automaticTextIsLight(box), "a frame alone leaves the paper visible")
        box.fill = .gray; page.textBoxes = [box]
        XCTAssertEqual(page.resolvedTextBoxes.first?.style.color, .black)
        XCTAssertEqual(page.resolvedTextBoxes.first?.style.automaticColor, true, "the automatic flag stays")
        XCTAssertFalse(EditorInteractionPolicy.automaticTextIsLight(box: box, pageSize: .a4, hasPDF: true, darkPaper: false, darkMargins: true))
    }

    // MARK: Gliederung

    private func outlineDocument(_ segments: [(String, [TextRun])]) throws -> Notebook {
        var document = try Notebook.textDocument(title: "Gliederung")
        let template = try XCTUnwrap(document.pages[0].textBoxes?.first)
        let flow = try XCTUnwrap(template.flowID)
        var pages: [Page] = []
        for (index, segment) in segments.enumerated() {
            var page = index == 0 ? document.pages[0] : document.pages[0].independentCopy()
            var box = template; box.id = UUID(); box.flowID = flow
            box.text = segment.0; box.runs = segment.1.isEmpty ? nil : segment.1
            page.textBoxes = [box]
            pages.append(page)
        }
        document.pages = pages
        try document.validate()
        return document
    }

    private func run(_ text: String, _ substring: String, _ preset: TextStylePreset) -> TextRun {
        let range = (text as NSString).range(of: substring)
        var style = TextBoxStyle(fontSize: 14); preset.apply(to: &style)
        return TextRun(location: range.location, length: range.length, style: style)
    }

    func testOutlineListsTitlesHeadingsAndSubheadingsHierarchically() throws {
        let first = "Referat\nEinleitung\nText der Einleitung.\nHintergrund\n\nKapitel zwei\nFortsetzung über die Sei"
        let second = "te hinweg\nUnterpunkt\nNoch Text\n"
        let document = try outlineDocument([
            (first, [run(first, "Referat", .title), run(first, "Einleitung\n", .heading), run(first, "Hintergrund", .subheading),
                     run(first, "Kapitel zwei", .heading)]),
            (second, [run(second, "te hinweg", .heading), run(second, "Unterpunkt", .subheading)])
        ])
        let outline = document.textOutline
        XCTAssertEqual(outline.map(\.text), ["Referat", "Einleitung", "Hintergrund", "Kapitel zwei", "Unterpunkt"],
                       "a paragraph continuing on the next page is not a new entry; body text is not listed")
        XCTAssertEqual(outline.map(\.preset), [.title, .heading, .subheading, .heading, .subheading])
        XCTAssertEqual(outline.map(\.depth), [0, 1, 2, 1, 2])
        XCTAssertEqual(outline.map(\.pageIndex), [0, 0, 0, 0, 1])
        let unterpunkt = outline[4]
        XCTAssertEqual(unterpunkt.boxID, document.pages[1].textBoxes?.first?.id)
        XCTAssertEqual(unterpunkt.range, (second as NSString).range(of: "Unterpunkt"))
        let focus = unterpunkt.focus
        XCTAssertEqual(focus.pageID, document.pages[1].id)
        XCTAssertEqual(focus.selection, NSRange(location: NSMaxRange(unterpunkt.range), length: 0), "caret behind the heading")
        XCTAssertEqual(TextStylePreset.matching(focus.typingStyle), .subheading)
        XCTAssertEqual(Set(outline.map(\.id)).count, outline.count, "stable, unique identities")
    }

    func testOutlineDepthStartsAtTheHighestUsedLevelAndShortensLongHeadings() throws {
        let long = String(repeating: "Wort ", count: 30)
        let text = "Überschrift A\nUnter A\n\(long)\n  Überschrift\tB  \nTitel spät\nUnter C"
        let document = try outlineDocument([(text, [run(text, "Überschrift A", .heading), run(text, "Unter A", .subheading),
                                                    run(text, long, .subheading), run(text, "  Überschrift\tB  ", .heading),
                                                    run(text, "Titel spät", .title), run(text, "Unter C", .subheading)])])
        let outline = document.textOutline
        XCTAssertEqual(outline.map(\.depth), [0, 1, 1, 0, 0, 1], "no title above: headings start at 0; a later title resets")
        XCTAssertEqual(outline[3].text, "Überschrift B", "white space collapsed")
        XCTAssertEqual(outline[2].text.count, Notebook.outlineTextLimit)
        XCTAssertTrue(outline[2].text.hasSuffix("…"))
        XCTAssertEqual(Notebook.outlineText("kurz", limit: 60), "kurz")
    }

    func testOutlineIsEmptyForNotebooksAndPlainText() throws {
        XCTAssertTrue(try outlineDocument([("Nur Text\nohne Überschriften", [])]).textOutline.isEmpty)
        XCTAssertTrue(try outlineDocument([("", [])]).textOutline.isEmpty)
        var book = try Notebook.blank(title: "Heft", appearance: NotebookAppearance())
        var heading = TextBoxStyle(); TextStylePreset.title.apply(to: &heading)
        try book.replaceTextBoxes([TextBox(x: 40, y: 40, width: 200, height: 40, text: "Titel", style: heading)], pageID: book.pages[0].id)
        XCTAssertTrue(book.textOutline.isEmpty, "notebooks have no outline (free fields only)")
    }
}
