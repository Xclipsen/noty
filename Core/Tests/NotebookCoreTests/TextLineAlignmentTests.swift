import XCTest
@testable import NotebookCore

/// „An Linien ausrichten“ (schema 16, docs/TEXT-FIELDS.md): free fields on
/// the paper lines with the text document's rule; snapping, capacity,
/// format, migration and copies.
final class TextLineAlignmentTests: XCTestCase {
    private func p(_ x: Double, _ y: Double) -> PagePoint { PagePoint(x: x, y: y) }
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func paperPage(_ style: PaperStyle) -> Page {
        var page = Page(); page.paper = style; page.geometry = PaperStyle.geometry
        return page
    }
    private func aligned(x: Double = 60, y: Double, text: String = "Zeile") -> TextBox {
        var box = TextBox(x: x, y: y, width: 200, height: 20, text: text)
        box.alignsToLines = true
        return box
    }
    /// 14-pt body text as TextKit measures it (ascent, descent, line height).
    private let body = (ascent: 13.3, descent: 3.4, line: 16.7)
    /// 30-pt title.
    private let title = (ascent: 28.6, descent: 7.2, line: 35.8)

    /// Baselines (container coordinates) of `count` lines laid out one below
    /// the other like TextKit does with the ruling delegate: each line starts
    /// at the previous one's bottom (moved by the ruling).
    private func baselines(_ rule: DocumentPageRule, count: Int, ascent: Double, descent: Double, line: Double) -> [Double] {
        var top = 0.0, result: [Double] = []
        for _ in 0..<count {
            let baseline = rule.baseline(top: top, ascent: ascent) ?? top + ascent
            result.append(baseline)
            top = rule.lineBottom(top: top, lineHeight: line, ascent: ascent)
        }
        return result
    }

    // MARK: Where it takes effect

    func testStateFollowsPaperRotationAndFlow() {
        let lined = paperPage(.lined).linePaper, blank = paperPage(.blank).linePaper
        XCTAssertEqual(lined.lineAlignment(for: aligned(y: 100)), .aligned)
        XCTAssertEqual(paperPage(.grid).linePaper.lineAlignment(for: aligned(y: 100)), .aligned)
        XCTAssertEqual(blank.lineAlignment(for: aligned(y: 100)), .noLines, "blank paper: the switch has no effect")
        XCTAssertEqual(paperPage(.legacyTest).linePaper.lineAlignment(for: aligned(y: 100)), .noLines)
        var turned = aligned(y: 100); turned.rotation = 15
        XCTAssertEqual(lined.lineAlignment(for: turned), .rotated)
        XCTAssertEqual(lined.lineAlignment(for: TextBox(x: 60, y: 100, text: "alt")), .off, "existing fields stay off")
        XCTAssertNil(blank.grid(for: aligned(y: 100)))
        XCTAssertNil(lined.grid(for: turned))
        XCTAssertNil(lined.grid(for: TextBox(x: 60, y: 100, text: "alt")), "plain fields keep their free layout")
    }

    func testPDFSheetHasNoLinesItsRuledWritingSpaceHas() throws {
        var book = Notebook.blank(title: "PDF")
        let wide = try PDFPageGeometry(mediaBox: PageRect(x: 0, y: 0, width: 1190, height: 842),
                                       cropBox: PageRect(x: 0, y: 0, width: 1190, height: 842), rotation: 0)
        _ = try book.insertPDF(Data([1, 2, 3]), geometries: [wide], at: 0)
        var page = book.pages[0]
        page.margins = PageMargins(left: 0, right: 600, top: 120, bottom: 0, style: .lined, color: .white)
        let paper = page.linePaper
        XCTAssertEqual(paper.scale, 2, "lines beside a twice A4-wide PDF use its writing-space units")
        XCTAssertEqual(paper.lineAlignment(for: aligned(x: 300, y: 300)), .noLines, "on the PDF itself")
        let side = aligned(x: 1250, y: 300)
        XCTAssertEqual(paper.lineAlignment(for: side), .aligned)
        XCTAssertEqual(paper.lineAlignment(for: aligned(x: 300, y: -60)), .aligned, "writing space above the PDF")
        // A free field keeps page units: the lines come to it scaled (48 pt apart), origin includes the top space.
        let grid = try XCTUnwrap(paper.grid(for: side))
        XCTAssertEqual(grid.ruling, TextRuling.lined.scaled(by: 2))
        XCTAssertEqual(grid.origin, 420)
        XCTAssertNil(grid.pageTop)
        // A blank writing space: no effect.
        page.margins?.style = .blank
        XCTAssertEqual(page.linePaper.lineAlignment(for: side), .noLines)
    }

    func testFlowsAndMigratedFieldsKeepTheirGrid() throws {
        var page = paperPage(.lined)
        let rect = try XCTUnwrap(page.writingRect(.page))
        var segment = TextBox(x: rect.x, y: rect.y, width: rect.width, height: rect.height, text: "Fluss")
        segment.flowID = UUID(); segment.flowRegion = .page
        XCTAssertEqual(page.linePaper.grid(for: segment), TextLineGrid(ruling: .lined, origin: rect.y, pageTop: 0))
        XCTAssertEqual(page.linePaper.lineAlignment(for: segment), .off)
        var migrated = TextBox(x: 100, y: 300, width: 200, height: 40, text: "alt"); migrated.flowRegion = .page
        XCTAssertEqual(page.linePaper.grid(for: migrated), TextLineGrid(ruling: .lined, origin: rect.y),
                       "migrated fields stay anchored at their former region (lines move with them)")
        // Switched on, a migrated field stands on the paper lines from its own top.
        migrated.alignsToLines = true
        XCTAssertEqual(page.linePaper.grid(for: migrated), TextLineGrid(ruling: .lined, origin: 300))
        page.paper = .grid
        XCTAssertEqual(page.linePaper.grid(for: migrated)?.ruling, .grid)
    }

    // MARK: Baselines, line height, capacity

    func testSnappedFieldPutsEveryBaselineOnAPaperLine() throws {
        let paper = paperPage(.lined).linePaper
        var box = aligned(y: 100)
        box.y = try XCTUnwrap(paper.snappedY(for: box, firstAscent: body.ascent))
        // Natural first baseline 113.3 lies nearest to the line at 112 (+ lift): the field moves up.
        XCTAssertEqual(box.y, 112 - PaperRuling.baselineLift - body.ascent, accuracy: 1e-9)
        let rule = DocumentPageRule(height: 400, grid: try XCTUnwrap(paper.grid(for: box)))
        let lines = baselines(rule, count: 5, ascent: body.ascent, descent: body.descent, line: body.line)
        for (index, baseline) in lines.enumerated() {
            XCTAssertEqual(box.y + baseline, 112 + Double(index) * 24 - PaperRuling.baselineLift, accuracy: 1e-9,
                           "line \(index): one paper line per line, 2.5 pt above the stroke")
        }
    }

    func testGridPaperTakesOneRowPerBodyLine() throws {
        let paper = paperPage(.grid).linePaper
        var box = aligned(y: 203)
        box.y = try XCTUnwrap(paper.snappedY(for: box, firstAscent: body.ascent))
        let rule = DocumentPageRule(height: 400, grid: try XCTUnwrap(paper.grid(for: box)))
        let lines = baselines(rule, count: 4, ascent: body.ascent, descent: body.descent, line: body.line)
        let first = box.y + lines[0]
        XCTAssertEqual((first + TextRuling.grid.lift - 40).truncatingRemainder(dividingBy: 16), 0, accuracy: 1e-9)
        XCTAssertEqual(zip(lines, lines.dropFirst()).map { $1 - $0 }, [16, 16, 16])
    }

    func testLargeTextTakesSeveralLinesLikeTheTextDocument() throws {
        let page = paperPage(.lined)
        let paper = page.linePaper
        var box = aligned(y: 300)
        box.y = try XCTUnwrap(paper.snappedY(for: box, firstAscent: title.ascent))
        let field = baselines(DocumentPageRule(height: 600, grid: try XCTUnwrap(paper.grid(for: box))),
                              count: 3, ascent: title.ascent, descent: title.descent, line: title.line)
        XCTAssertEqual(zip(field, field.dropFirst()).map { $1 - $0 }, [48, 48], "30 pt takes two lines per line")
        // The text document's flow on the same paper spaces its lines the same way.
        let rect = try XCTUnwrap(page.writingRect(.page))
        var segment = TextBox(x: rect.x, y: rect.y, width: rect.width, height: rect.height, text: "Fluss")
        segment.flowID = UUID(); segment.flowRegion = .page
        let flow = baselines(DocumentPageRule(height: rect.height, grid: try XCTUnwrap(paper.grid(for: segment))),
                             count: 4, ascent: title.ascent, descent: title.descent, line: title.line)
        XCTAssertEqual(zip(flow.dropFirst(), flow.dropFirst(2)).map { $1 - $0 }, [48, 48])
        XCTAssertEqual(TextStylePreset.rulingLines(fontSize: 30), 2)
    }

    func testCapacityIsLinesOfTheField() throws {
        let paper = paperPage(.lined).linePaper
        var box = aligned(y: 100)
        box.y = try XCTUnwrap(paper.snappedY(for: box, firstAscent: body.ascent))
        let grid = try XCTUnwrap(paper.grid(for: box))
        // Height of n laid-out lines (TextKit: bottom of the last fragment).
        func height(_ n: Int) -> Double {
            let rule = DocumentPageRule(height: 10_000, grid: grid)
            var top = 0.0
            for _ in 0..<n { top = rule.lineBottom(top: top, lineHeight: body.line, ascent: body.ascent) }
            return top
        }
        for n in 1...6 { XCTAssertEqual(height(n + 1) - height(n), 24, accuracy: 1e-9, "each further line costs one paper line") }
        // A field of that height holds exactly n lines; one more overflows.
        let rule = DocumentPageRule(height: height(4), grid: grid)
        var top = 0.0, fitting = 0
        while fitting < 10, rule.fits(top: top, lineHeight: body.line, ascent: body.ascent) {
            top = rule.lineBottom(top: top, lineHeight: body.line, ascent: body.ascent); fitting += 1
        }
        XCTAssertEqual(fitting, 4)
        box.height = height(4)
        XCTAssertFalse(box.overflows(textHeight: height(4)))
        XCTAssertTrue(box.overflows(textHeight: height(5)))
    }

    // MARK: Snapping

    func testSnappingIsIdempotentAndPicksTheNearestLine() throws {
        let paper = paperPage(.lined).linePaper
        for y in stride(from: 40.0, through: 700, by: 3.7) {
            let box = aligned(y: y)
            let snapped = try XCTUnwrap(paper.snappedY(for: box, firstAscent: body.ascent))
            XCTAssertLessThanOrEqual(abs(snapped - y), 12 + 1e-9, "never further than half a line")
            var again = box; again.y = snapped
            XCTAssertEqual(try XCTUnwrap(paper.snappedY(for: again, firstAscent: body.ascent)), snapped, accuracy: 1e-9)
        }
        // A larger first line keeps its text on the same paper line: the field grows upwards.
        var box = aligned(y: 300)
        box.y = try XCTUnwrap(paper.snappedY(for: box, firstAscent: body.ascent))
        let line = box.y + body.ascent + PaperRuling.baselineLift
        let larger = try XCTUnwrap(paper.snappedY(for: box, firstAscent: body.ascent + 6))
        XCTAssertEqual(larger + body.ascent + 6 + PaperRuling.baselineLift, line, accuracy: 1e-9)
    }

    func testSnappingStaysOnThePage() throws {
        let page = paperPage(.lined)
        let limits = page.textBounds
        // Near the top: never above the first line, never off the page.
        let top = try XCTUnwrap(page.linePaper.snappedY(for: aligned(y: 0), firstAscent: body.ascent, within: limits))
        XCTAssertEqual(top + body.ascent + PaperRuling.baselineLift, PaperRuling.firstBaseline, accuracy: 1e-9)
        // At the bottom the nearest line would push the field off: the next one up is taken.
        var low = aligned(y: 820); low.height = 20
        let bottom = try XCTUnwrap(page.linePaper.snappedY(for: low, firstAscent: body.ascent, within: limits))
        low.y = bottom
        XCTAssertTrue(low.fits(in: limits))
        XCTAssertEqual((bottom + body.ascent + PaperRuling.baselineLift - 40).truncatingRemainder(dividingBy: 24), 0, accuracy: 1e-9)
        // Nothing to snap without effect.
        XCTAssertNil(paperPage(.blank).linePaper.snappedY(for: aligned(y: 100), firstAscent: body.ascent, within: limits))
        XCTAssertNil(page.linePaper.snappedY(for: TextBox(x: 60, y: 100, text: "alt"), firstAscent: body.ascent))
    }

    func testSnappingInPDFWritingSpaceUsesItsLines() throws {
        var book = Notebook.blank(title: "PDF")
        let wide = try PDFPageGeometry(mediaBox: PageRect(x: 0, y: 0, width: 1190, height: 842),
                                       cropBox: PageRect(x: 0, y: 0, width: 1190, height: 842), rotation: 0)
        _ = try book.insertPDF(Data([1, 2, 3]), geometries: [wide], at: 0)
        var page = book.pages[0]
        page.margins = PageMargins(left: 0, right: 600, top: 120, bottom: 0, style: .grid, color: .dark)
        var box = aligned(x: 1250, y: 300)
        box.y = try XCTUnwrap(page.linePaper.snappedY(for: box, firstAscent: body.ascent, within: page.textBounds))
        // Canvas y of the baseline: 40·2 + k·32, 1.5·2 above the stroke.
        let canvas = box.y + 120 + body.ascent + 3
        XCTAssertEqual((canvas - 80).truncatingRemainder(dividingBy: 32), 0, accuracy: 1e-9)
    }

    // MARK: Format

    func testPlainFieldsStayInTheirFormat() throws {
        let data = try JSONEncoder().encode(TextBox(text: "alt"))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("alignsToLines"), "nil is never stored")
        var book = Notebook.blank(title: "Heft")
        try book.replaceTextBoxes([TextBox(text: "alt")], pageID: book.pages[0].id)
        XCTAssertLessThan(book.schemaVersion, 16, "plain fields keep their older schema")
    }

    func testAlignedFieldRaisesToSixteenOnEveryWritePath() throws {
        var book = Notebook.blank(title: "Heft")
        try book.replaceTextBoxes([aligned(y: 100)], pageID: book.pages[0].id)
        XCTAssertEqual(book.schemaVersion, TextBox.lineAlignmentSchemaVersion)
        var other = Notebook.blank(title: "Inhalt")
        try other.replaceContent(PageContent(page: { var page = other.pages[0]; page.textBoxes = [aligned(y: 100)]; return page }()),
                                 pageID: other.pages[0].id)
        XCTAssertEqual(other.schemaVersion, 16)
        // Switching off never lowers it.
        try book.replaceTextBoxes([TextBox(text: "aus")], pageID: book.pages[0].id)
        XCTAssertEqual(book.schemaVersion, 16)
        let decoded = try Notebook.decode(JSONEncoder().encode(book))
        XCTAssertEqual(decoded, book)
    }

    func testValidationRefusesOldSchemaFalseAndFlows() throws {
        var book = Notebook.blank(title: "Heft")
        try book.replaceTextBoxes([aligned(y: 100)], pageID: book.pages[0].id)
        let data = try JSONEncoder().encode(book)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(try Notebook.decode(data).pages[0].textBoxes?[0].alignsToLines, true)
        json["schemaVersion"] = 15
        XCTAssertThrowsError(try Notebook.decode(JSONSerialization.data(withJSONObject: json)), "alignment under schema 15")
        json["schemaVersion"] = 17
        XCTAssertThrowsError(try Notebook.decode(JSONSerialization.data(withJSONObject: json))) { error in
            guard case StorageError.unsupportedSchema(17) = error else { return XCTFail("\(error)") }
        }
        var off = aligned(y: 100); off.alignsToLines = false
        XCTAssertThrowsError(try off.validate(), "only true is stored")
        var flow = aligned(y: 100); flow.flowID = UUID(); flow.flowRegion = .page
        XCTAssertThrowsError(try flow.validate(), "flow segments stand on the lines anyway")
    }

    func testTextDocumentFieldRaisesToSixteen() throws {
        var document = try Notebook.textDocument(title: "Dokument", paper: .lined)
        XCTAssertEqual(document.schemaVersion, 15)
        let page = document.pages[0]
        try document.replaceTextBoxes(page.effectiveTextBoxes + [aligned(y: 400)], pageID: page.id)
        XCTAssertEqual(document.schemaVersion, 16)
        XCTAssertTrue(document.isTextDocument)
        XCTAssertEqual(try Notebook.decode(JSONEncoder().encode(document)), document)
    }

    func testFirstSchemaSixteenCommitArchivesExactConfirmedOldBytes() throws {
        let root = try directory()
        let store = RevisionStore(directory: root)
        var appearance = NotebookAppearance(); appearance.paper = .lined
        var book = try Notebook.blank(title: "Liniert", appearance: appearance)
        var turned = TextBox(x: 60, y: 200, width: 120, height: 24, text: "alt"); turned.rotation = 10
        try book.replaceTextBoxes([turned], pageID: book.pages[0].id)
        XCTAssertEqual(book.schemaVersion, 14)
        try store.save(book)
        let revision = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("Revisions"), includingPropertiesForKeys: nil)[0]
        let bytes = try Data(contentsOf: revision)
        var boxes = book.pages[0].effectiveTextBoxes
        boxes.append(aligned(y: 300))
        try book.replaceTextBoxes(boxes, pageID: book.pages[0].id)
        XCTAssertEqual(book.schemaVersion, 16)
        XCTAssertEqual(book.pages[0].textBoxes?[0], turned, "the existing field is unchanged")
        try store.save(book)
        let folder = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("Migrations"), includingPropertiesForKeys: nil)[0]
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("notebook-v14.json")), bytes)
        XCTAssertEqual(try store.load(), book)
    }

    // MARK: Copies, trash, undo

    func testCopiesTrashAndUndoKeepTheSwitch() throws {
        var appearance = NotebookAppearance(); appearance.paper = .lined
        var book = try Notebook.blank(title: "Kopien", appearance: appearance)
        let field = aligned(y: 300)
        try book.replaceTextBoxes([field], pageID: book.pages[0].id)
        let copyID = try book.duplicatePage(book.pages[0].id)
        let copy = try XCTUnwrap(book.pages.first { $0.id == copyID }?.textBoxes?.first)
        XCTAssertNotEqual(copy.id, field.id, "a duplicated page gets new field identities")
        XCTAssertEqual(copy.alignsToLines, true)
        try book.trashPage(copyID)
        XCTAssertEqual(book.deletedPages?.first?.page.textBoxes?.first?.alignsToLines, true)
        let restored = try book.restorePage(try XCTUnwrap(book.deletedPages?.first?.id))
        XCTAssertEqual(book.pages.first { $0.id == restored }?.textBoxes?.first?.alignsToLines, true)
        XCTAssertEqual(book.pages[0].independentCopy().textBoxes?.first?.alignsToLines, true)
        // Undo of the switch restores the earlier state without lowering the schema.
        let before = book
        var off = field; off.alignsToLines = nil
        try book.replaceTextBoxes([off], pageID: book.pages[0].id)
        try book.replaceTextBoxes(before.pages[0].textBoxes!, pageID: book.pages[0].id, restoring: true)
        XCTAssertEqual(book.pages[0].textBoxes, before.pages[0].textBoxes)
        XCTAssertEqual(book.schemaVersion, 16)
    }
}
