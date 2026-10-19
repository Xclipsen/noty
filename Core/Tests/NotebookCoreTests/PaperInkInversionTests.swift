import Foundation
import XCTest
@testable import NotebookCore

/// Stand-in for PencilKit data: the app applies the same per-stroke decision.
private struct FakeStroke: Codable, Equatable { var bounds: PageRect; var color: InkColor }
private func fakeDrawing(_ strokes: [FakeStroke]) -> Data { try! JSONEncoder().encode(strokes) }
private func strokes(_ data: Data) -> [FakeStroke] { (try? JSONDecoder().decode([FakeStroke].self, from: data)) ?? [] }
private func fakeRecolor(_ data: Data, _ convert: (PageRect, InkColor) -> InkColor?) throws -> Data {
    let old = try JSONDecoder().decode([FakeStroke].self, from: data)
    let new = old.map { stroke in FakeStroke(bounds: stroke.bounds, color: convert(stroke.bounds, stroke.color) ?? stroke.color) }
    return new == old ? data : try JSONEncoder().encode(new)
}

final class PaperInkInversionTests: XCTestCase {
    private let black = InkColor(0, 0, 0)
    private let white = InkColor(1, 1, 1)
    private let red = InkColor(0.8, 0.12, 0.12)
    private let blue = InkColor(0.1, 0.35, 0.8)
    private let yellowMarker = InkColor(1, 1, 0, 0.35)

    func testNeutralInkSwapsDirectionAwareAndKeepsAlpha() {
        XCTAssertEqual(PaperInkInversion.converted(black, to: .dark), white)
        XCTAssertEqual(PaperInkInversion.converted(InkColor(0.1, 0.12, 0.08), to: .dark), white, "near black")
        XCTAssertEqual(PaperInkInversion.converted(InkColor(0, 0, 0, 0.4), to: .dark), InkColor(1, 1, 1, 0.4))
        XCTAssertEqual(PaperInkInversion.converted(white, to: .white), black)
        XCTAssertEqual(PaperInkInversion.converted(InkColor(0.93, 0.95, 0.9, 0.5), to: .white), InkColor(0, 0, 0, 0.5))
        // Direction-aware: nothing to do in the opposite direction.
        XCTAssertNil(PaperInkInversion.converted(black, to: .white))
        XCTAssertNil(PaperInkInversion.converted(white, to: .dark))
        // Mid greys and saturated colours stay.
        XCTAssertNil(PaperInkInversion.converted(InkColor(0.5, 0.5, 0.5), to: .dark))
        XCTAssertNil(PaperInkInversion.converted(InkColor(0.5, 0.5, 0.5), to: .white))
        for color in [red, blue, yellowMarker, InkColor(0.2, 0, 0), InkColor(0.75, 1, 1)] {
            XCTAssertNil(PaperInkInversion.converted(color, to: .dark))
            XCTAssertNil(PaperInkInversion.converted(color, to: .white))
        }
    }

    func testTextStyleUsesInkWhenPresentOtherwiseNamedColour() {
        var plain = TextBoxStyle(color: .black)
        XCTAssertEqual(PaperInkInversion.converted(plain, to: .dark).color, .white)
        XCTAssertNil(PaperInkInversion.converted(plain, to: .dark).ink, "no extended style introduced")
        plain.color = .red
        XCTAssertEqual(PaperInkInversion.converted(plain, to: .dark), plain)
        var custom = TextBoxStyle(color: .black); custom.ink = InkColor(0.1, 0.1, 0.1, 0.9)
        let converted = PaperInkInversion.converted(custom, to: .dark)
        XCTAssertEqual(converted.ink, InkColor(1, 1, 1, 0.9)); XCTAssertEqual(converted.color, .white)
        custom.ink = blue
        XCTAssertEqual(PaperInkInversion.converted(custom, to: .dark), custom)
        XCTAssertEqual(PaperInkInversion.converted(TextBoxStyle(color: .white), to: .white).color, .black)
    }

    // MARK: Notebook conversion

    private func mixedNotebook() throws -> Notebook {
        var appearance = NotebookAppearance(); appearance.paper = .lined; appearance.color = .white
        var notebook = try Notebook.blank(title: "Bio", appearance: appearance)
        notebook.schemaVersion = 8
        // Written paper page: black ink, red ink, black text with a blue run, black shape with fill, image.
        var box = TextBox(x: 40, y: 40, width: 300, height: 40, text: "Zelle und Kern")
        box.runs = [TextRun(location: 0, length: 5, style: TextBoxStyle(color: .black)),
                    TextRun(location: 6, length: 3, style: TextBoxStyle(color: .blue))]
        notebook.pages[0].textBoxes = [box]
        notebook.pages[0].drawing = fakeDrawing([FakeStroke(bounds: .init(x: 10, y: 10, width: 50, height: 5), color: black),
                                                  FakeStroke(bounds: .init(x: 10, y: 30, width: 50, height: 5), color: red)])
        notebook.pages[0].shapes = [ShapeObject(kind: .rectangle, start: .init(x: 100, y: 100), end: .init(x: 200, y: 200),
                                                color: black, fill: InkColor(0, 0, 0, 0.2))]
        // Empty paper page.
        _ = try notebook.insertPaper(.blank, color: .white, at: 1)
        // PDF page with a right writing space, and one without margins.
        let source = PDFSource(data: Data([1, 2, 3]), pageCount: 2)
        notebook.pdfSources = [source]
        let geometry = try PDFPageGeometry(mediaBox: .init(x: 0, y: 0, width: 400, height: 600),
                                           cropBox: .init(x: 0, y: 0, width: 400, height: 600), rotation: 0)
        var pdf = Page(); pdf.geometry = geometry; pdf.pdfReference = PDFPageReference(sourceID: source.id, pageIndex: 0)
        pdf.margins = PageMargins(right: 400, style: .lined, color: .white)
        pdf.drawing = fakeDrawing([FakeStroke(bounds: .init(x: 420, y: 10, width: 100, height: 5), color: black),   // margin
                                   FakeStroke(bounds: .init(x: 50, y: 10, width: 100, height: 5), color: black),    // over scan
                                   FakeStroke(bounds: .init(x: 380, y: 10, width: 60, height: 5), color: black)])   // crosses edge
        var flow = TextBox(x: 420, y: 20, width: 300, height: 30, text: "Randnotiz")
        flow.flowID = UUID(); flow.flowRegion = .right
        let annotation = TextBox(x: 20, y: 300, width: 100, height: 30, text: "Auf dem Scan")
        let marginFree = TextBox(x: 450, y: 400, width: 100, height: 30, text: "frei im Rand")
        pdf.textBoxes = [flow, annotation, marginFree]
        pdf.shapes = [ShapeObject(kind: .line, start: .init(x: 450, y: 100), end: .init(x: 600, y: 100)),
                      ShapeObject(kind: .line, start: .init(x: 50, y: 100), end: .init(x: 200, y: 100))]
        var plainPDF = Page(); plainPDF.geometry = geometry; plainPDF.pdfReference = PDFPageReference(sourceID: source.id, pageIndex: 1)
        plainPDF.drawing = fakeDrawing([FakeStroke(bounds: .init(x: 50, y: 10, width: 100, height: 5), color: black)])
        notebook.pages += [pdf, plainPDF]
        // A trashed written page keeps its exact state.
        _ = try notebook.insertPaper(.grid, color: .white, at: 4)
        notebook.pages[4].drawing = fakeDrawing([FakeStroke(bounds: .init(x: 1, y: 1, width: 5, height: 5), color: black)])
        try notebook.trashPage(notebook.pages[4].id)
        try notebook.validate()
        return notebook
    }

    func testWholeNotebookToDarkSwapsNeutralContentAndLeavesScanAndTrash() throws {
        var notebook = try mixedNotebook()
        let before = notebook
        let changed = try notebook.setPageDefaults(paper: .grid, color: .dark, scope: .wholeNotebook, recolorDrawing: fakeRecolor)
        XCTAssertEqual(changed, 3, "two paper pages and the PDF page with writing space")
        XCTAssertEqual(notebook.deletedPages, before.deletedPages, "trash untouched")
        XCTAssertEqual(notebook.pdfSources, before.pdfSources)
        XCTAssertEqual(notebook.pages.map(\.id), before.pages.map(\.id), "stable IDs and order")
        XCTAssertEqual(notebook.appearance?.paper, .grid); XCTAssertEqual(notebook.appearance?.color, .dark)

        let written = notebook.pages[0]
        XCTAssertEqual(written.paper, .grid); XCTAssertEqual(written.paperColor, .dark)
        XCTAssertEqual(strokes(written.drawing).map(\.color), [white, red])
        XCTAssertEqual(strokes(written.drawing).map(\.bounds), strokes(before.pages[0].drawing).map(\.bounds))
        let box = try XCTUnwrap(written.textBoxes?.first)
        XCTAssertEqual(box.style.color, .white); XCTAssertEqual(box.runs?.map(\.style.color), [.white, .blue])
        XCTAssertEqual(box.text, "Zelle und Kern")
        XCTAssertEqual(written.shapes?.first?.color, white); XCTAssertEqual(written.shapes?.first?.fill, InkColor(1, 1, 1, 0.2))
        XCTAssertEqual(notebook.pages[1].paperColor, .dark); XCTAssertEqual(notebook.pages[1].paper, .grid)

        let pdf = notebook.pages[2]
        XCTAssertEqual(pdf.margins?.color, .dark); XCTAssertEqual(pdf.margins?.style, .lined, "margin pattern keeps its own style")
        XCTAssertNil(pdf.paperColor); XCTAssertNil(pdf.paper)
        XCTAssertEqual(strokes(pdf.drawing).map(\.color), [white, black, black], "only strokes fully in the margin")
        XCTAssertEqual(pdf.textBoxes?.map(\.style.color), [.white, .black, .white])
        XCTAssertEqual(pdf.shapes?.map(\.color), [white, black])
        XCTAssertEqual(notebook.pages[3], before.pages[3], "PDF without writing space unchanged")
        XCTAssertNoThrow(try notebook.validate())
        XCTAssertEqual(try Notebook.decode(JSONEncoder().encode(notebook)), notebook)

        // And back: white ink becomes black again, red stays.
        let back = try notebook.setPageDefaults(paper: .lined, color: .white, scope: .wholeNotebook, recolorDrawing: fakeRecolor)
        XCTAssertEqual(back, 3)
        XCTAssertEqual(strokes(notebook.pages[0].drawing).map(\.color), [black, red])
        XCTAssertEqual(notebook.pages[0].textBoxes, before.pages[0].textBoxes)
        XCTAssertEqual(notebook.pages[0].shapes, before.pages[0].shapes)
        // Fake JSON key order is not stable on Linux: compare decoded strokes.
        var roundTrip = notebook.pages[2]; roundTrip.drawing = before.pages[2].drawing
        XCTAssertEqual(roundTrip, before.pages[2])
        XCTAssertEqual(strokes(notebook.pages[2].drawing), strokes(before.pages[2].drawing))
        XCTAssertEqual(notebook.deletedPages, before.deletedPages)
    }

    func testSameColourOnlyChangesPatternAndKeepsInk() throws {
        var notebook = try mixedNotebook()
        let before = notebook
        let changed = try notebook.setPageDefaults(paper: .grid, color: .white, scope: .wholeNotebook, recolorDrawing: fakeRecolor)
        XCTAssertEqual(changed, 2)
        XCTAssertEqual(notebook.pages[0].paper, .grid)
        XCTAssertEqual(notebook.pages[0].drawing, before.pages[0].drawing)
        XCTAssertEqual(notebook.pages[0].textBoxes, before.pages[0].textBoxes)
        XCTAssertEqual(notebook.pages[2], before.pages[2])
    }

    func testOtherScopesNeverTouchWrittenPagesOrPDFs() throws {
        let base = try mixedNotebook()
        var defaultsOnly = base
        XCTAssertEqual(try defaultsOnly.setPageDefaults(paper: .grid, color: .dark, scope: .newPagesOnly), 0)
        XCTAssertEqual(defaultsOnly.pages, base.pages); XCTAssertEqual(defaultsOnly.appearance?.color, .dark)
        var empty = base
        let ids = Set(base.pages.map(\.id))
        XCTAssertEqual(try empty.setPageDefaults(paper: .grid, color: .dark, scope: .emptyPages, emptyPageIDs: ids), 1)
        XCTAssertEqual(empty.pages[1].paperColor, .dark)
        XCTAssertEqual(Array(empty.pages[2...]), Array(base.pages[2...]))
        XCTAssertEqual(empty.pages[0], base.pages[0])
        XCTAssertEqual(empty.deletedPages, base.deletedPages)
    }

    func testWrittenConversionWithoutDrawingStepFailsWithoutChanges() throws {
        var notebook = try mixedNotebook()
        let before = notebook
        XCTAssertThrowsError(try notebook.setPageDefaults(paper: .grid, color: .dark, scope: .wholeNotebook))
        XCTAssertEqual(notebook, before)
        let failing: Notebook.InkRecolor = { _, _ in throw StorageError.invalidDocument }
        XCTAssertThrowsError(try notebook.setPageDefaults(paper: .grid, color: .dark, scope: .wholeNotebook, recolorDrawing: failing))
        XCTAssertEqual(notebook, before)
    }

    func testMarginDetectionUsesCanonicalBaseSheet() throws {
        var page = Page(); page.geometry = try PDFPageGeometry(mediaBox: .init(x: 0, y: 0, width: 400, height: 600),
                                                               cropBox: .init(x: 0, y: 0, width: 400, height: 600), rotation: 90)
        page.margins = PageMargins(left: 100, right: 100, top: 100, bottom: 100)
        // Rotated: displayed size 600 × 400.
        XCTAssertTrue(page.liesInMargins(.init(x: -90, y: 10, width: 80, height: 10)))
        XCTAssertTrue(page.liesInMargins(.init(x: 10, y: -50, width: 80, height: 49.8)), "touching edge within tolerance")
        XCTAssertTrue(page.liesInMargins(.init(x: 601, y: 10, width: 50, height: 10)))
        XCTAssertTrue(page.liesInMargins(.init(x: 10, y: 400, width: 50, height: 10)))
        XCTAssertFalse(page.liesInMargins(.init(x: 450, y: 10, width: 50, height: 10)), "inside rotated scan")
        XCTAssertFalse(page.liesInMargins(.init(x: -20, y: 10, width: 30, height: 10)), "crosses into scan")
    }

    func testLegacyNotebookConvertsToSchemaSevenWithVirtualTextFollowingPaper() throws {
        var notebook = try Notebook.blank(title: "Alt").preparedForPageEditing()
        notebook.pages[0].drawing = Data()
        XCTAssertNil(notebook.appearance)
        let changed = try notebook.setPageDefaults(paper: .lined, color: .dark, scope: .wholeNotebook)
        XCTAssertEqual(changed, 1)
        XCTAssertGreaterThanOrEqual(notebook.schemaVersion, 7)
        XCTAssertEqual(notebook.appearance?.coverEnabled, false)
        XCTAssertNoThrow(try notebook.validate())
    }
}
