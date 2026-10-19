import Foundation
import XCTest
@testable import NotebookCore

/// Stand-in for PencilKit data (same per-stroke decision as the app's step).
private struct Stroke: Codable, Equatable { var bounds: PageRect; var color: InkColor }
private func drawing(_ strokes: [Stroke]) -> Data { try! JSONEncoder().encode(strokes) }
private func strokes(_ data: Data) -> [Stroke] { (try? JSONDecoder().decode([Stroke].self, from: data)) ?? [] }

/// Regression for "Ganzes Notizbuch umstellen" (Build 41 feedback): black↔white
/// may swap only on pages or writing spaces whose paper colour really changes.
final class PageDefaultsConversionTests: XCTestCase {
    private let black = InkColor(0, 0, 0)
    private let white = InkColor(1, 1, 1)
    private let red = InkColor(0.8, 0.1, 0.1)
    /// Counts drawing conversions: unchanged pages must not even be visited.
    private var recolorCalls = 0
    private func recolor(_ data: Data, _ convert: (PageRect, InkColor) -> InkColor?) throws -> Data {
        recolorCalls += 1
        let old = try JSONDecoder().decode([Stroke].self, from: data)
        let new = old.map { Stroke(bounds: $0.bounds, color: convert($0.bounds, $0.color) ?? $0.color) }
        return new == old ? data : try JSONEncoder().encode(new)
    }

    /// One written paper page in `color`: neutral ink of both kinds, red ink,
    /// text in black and white, a neutral shape.
    private func writtenNotebook(_ color: PaperColor, paper: PaperStyle = .lined) throws -> Notebook {
        var appearance = NotebookAppearance(); appearance.paper = paper; appearance.color = color
        var notebook = try Notebook.blank(title: "Heft", appearance: appearance)
        notebook.schemaVersion = 8
        notebook.pages[0].drawing = drawing([Stroke(bounds: .init(x: 10, y: 10, width: 50, height: 5), color: black),
                                             Stroke(bounds: .init(x: 10, y: 20, width: 50, height: 5), color: white),
                                             Stroke(bounds: .init(x: 10, y: 30, width: 50, height: 5), color: red)])
        notebook.pages[0].textBoxes = [TextBox(x: 40, y: 80, width: 200, height: 30, text: "schwarz", style: TextBoxStyle(color: .black)),
                                       TextBox(x: 40, y: 120, width: 200, height: 30, text: "weiß", style: TextBoxStyle(color: .white))]
        notebook.pages[0].shapes = [ShapeObject(kind: .line, start: .init(x: 50, y: 200), end: .init(x: 150, y: 200), color: black)]
        try notebook.validate()
        return notebook
    }

    func testLightToLightKeepsEveryInkColour() throws {
        var notebook = try writtenNotebook(.white, paper: .lined)
        let before = notebook
        recolorCalls = 0
        let changed = try notebook.setPageDefaults(paper: .blank, color: .white, scope: .wholeNotebook, recolorDrawing: recolor)
        XCTAssertEqual(changed, 1, "only the pattern changed")
        XCTAssertEqual(recolorCalls, 0, "no ink conversion when the colour stays")
        XCTAssertEqual(notebook.pages[0].paper, .blank); XCTAssertEqual(notebook.pages[0].paperColor, .white)
        XCTAssertEqual(notebook.pages[0].drawing, before.pages[0].drawing)
        XCTAssertEqual(notebook.pages[0].textBoxes, before.pages[0].textBoxes)
        XCTAssertEqual(notebook.pages[0].shapes, before.pages[0].shapes)
        // The very same choice again is a complete no-op for the pages.
        recolorCalls = 0
        XCTAssertEqual(try notebook.setPageDefaults(paper: .blank, color: .white, scope: .wholeNotebook, recolorDrawing: recolor), 0)
        XCTAssertEqual(recolorCalls, 0)
        XCTAssertEqual(notebook.pages, { var p = before.pages; p[0].paper = .blank; return p }())
    }

    func testLegacyPageWithoutStoredColourCountsAsWhite() throws {
        var notebook = try writtenNotebook(.white)
        notebook.pages[0].paperColor = nil
        let before = notebook
        recolorCalls = 0
        XCTAssertEqual(try notebook.setPageDefaults(paper: .lined, color: .white, scope: .wholeNotebook, recolorDrawing: recolor), 0)
        XCTAssertEqual(recolorCalls, 0)
        XCTAssertEqual(notebook.pages, before.pages)
    }

    func testDarkToDarkKeepsEveryInkColour() throws {
        var notebook = try writtenNotebook(.dark, paper: .lined)
        let before = notebook
        recolorCalls = 0
        let changed = try notebook.setPageDefaults(paper: .grid, color: .dark, scope: .wholeNotebook, recolorDrawing: recolor)
        XCTAssertEqual(changed, 1)
        XCTAssertEqual(recolorCalls, 0)
        XCTAssertEqual(notebook.pages[0].paperColor, .dark)
        XCTAssertEqual(notebook.pages[0].drawing, before.pages[0].drawing)
        XCTAssertEqual(notebook.pages[0].textBoxes, before.pages[0].textBoxes)
        XCTAssertEqual(notebook.pages[0].shapes, before.pages[0].shapes)
    }

    func testLightToDarkTurnsBlackWhite() throws {
        var notebook = try writtenNotebook(.white)
        XCTAssertEqual(try notebook.setPageDefaults(paper: .blank, color: .dark, scope: .wholeNotebook, recolorDrawing: recolor), 1)
        let page = notebook.pages[0]
        XCTAssertEqual(page.paperColor, .dark)
        XCTAssertEqual(strokes(page.drawing).map(\.color), [white, white, red], "black → white; white and red stay")
        XCTAssertEqual(page.textBoxes?.map(\.style.color), [.white, .white])
        XCTAssertEqual(page.shapes?.map(\.color), [white])
    }

    func testDarkToLightTurnsWhiteBlack() throws {
        var notebook = try writtenNotebook(.dark)
        XCTAssertEqual(try notebook.setPageDefaults(paper: .blank, color: .white, scope: .wholeNotebook, recolorDrawing: recolor), 1)
        let page = notebook.pages[0]
        XCTAssertEqual(page.paperColor, .white); XCTAssertEqual(page.paper, .blank)
        XCTAssertEqual(strokes(page.drawing).map(\.color), [black, black, red], "white → black; black and red stay")
        XCTAssertEqual(page.textBoxes?.map(\.style.color), [.black, .black])
        XCTAssertEqual(page.shapes?.map(\.color), [black])
        XCTAssertEqual(notebook.appearance?.paper, .blank); XCTAssertEqual(notebook.appearance?.color, .white)
    }

    /// White and dark paper pages, PDF pages with dark / white / no writing space.
    private func mixedNotebook() throws -> Notebook {
        var notebook = try writtenNotebook(.white)
        _ = try notebook.insertPaper(.lined, color: .dark, at: 1)
        notebook.pages[1].drawing = drawing([Stroke(bounds: .init(x: 10, y: 10, width: 50, height: 5), color: white)])
        notebook.pages[1].textBoxes = [TextBox(x: 40, y: 80, width: 200, height: 30, text: "hell", style: TextBoxStyle(color: .white))]
        let source = PDFSource(data: Data([1, 2, 3]), pageCount: 3)
        notebook.pdfSources = [source]
        let geometry = try PDFPageGeometry(mediaBox: .init(x: 0, y: 0, width: 400, height: 600),
                                           cropBox: .init(x: 0, y: 0, width: 400, height: 600), rotation: 0)
        func pdf(_ index: Int, margin: PaperColor?) -> Page {
            var page = Page(); page.geometry = geometry
            page.pdfReference = PDFPageReference(sourceID: source.id, pageIndex: index)
            if let margin { page.margins = PageMargins(right: 300, style: .lined, color: margin) }
            page.drawing = drawing([Stroke(bounds: .init(x: 420, y: 10, width: 100, height: 5), color: margin == .dark ? white : black), // writing space
                                    Stroke(bounds: .init(x: 50, y: 10, width: 100, height: 5), color: black)])                         // on the scan
            return page
        }
        notebook.pages += [pdf(0, margin: .dark), pdf(1, margin: .white), pdf(2, margin: nil)]
        try notebook.validate()
        return notebook
    }

    func testMixedNotebookToWhiteConvertsOnlyPagesThatWereDark() throws {
        var notebook = try mixedNotebook()
        let before = notebook
        let changed = try notebook.setPageDefaults(paper: .lined, color: .white, scope: .wholeNotebook, recolorDrawing: recolor)
        XCTAssertEqual(changed, 2, "the dark paper page and the dark writing space")
        XCTAssertEqual(notebook.pages[0], before.pages[0], "white lined page: already the target")
        XCTAssertEqual(notebook.pages[1].paperColor, .white)
        XCTAssertEqual(strokes(notebook.pages[1].drawing).map(\.color), [black])
        XCTAssertEqual(notebook.pages[1].textBoxes?.map(\.style.color), [.black])
        XCTAssertEqual(notebook.pages[2].margins?.color, .white)
        XCTAssertEqual(strokes(notebook.pages[2].drawing).map(\.color), [black, black], "margin ink white → black, scan ink unchanged")
        XCTAssertNil(notebook.pages[2].paper, "PDF page itself unchanged"); XCTAssertNil(notebook.pages[2].paperColor)
        XCTAssertEqual(notebook.pages[2].pdfReference, before.pages[2].pdfReference)
        XCTAssertEqual(notebook.pages[3], before.pages[3], "white writing space stays")
        XCTAssertEqual(notebook.pages[4], before.pages[4], "PDF without writing space stays")
        XCTAssertEqual(notebook.pdfSources, before.pdfSources)
        XCTAssertNoThrow(try notebook.validate())
    }

    func testMixedNotebookToDarkConvertsOnlyPagesThatWereLight() throws {
        var notebook = try mixedNotebook()
        let before = notebook
        let changed = try notebook.setPageDefaults(paper: .lined, color: .dark, scope: .wholeNotebook, recolorDrawing: recolor)
        XCTAssertEqual(changed, 2, "the white paper page and the white writing space")
        XCTAssertEqual(strokes(notebook.pages[0].drawing).map(\.color), [white, white, red])
        XCTAssertEqual(notebook.pages[1], before.pages[1], "dark lined page: already the target")
        XCTAssertEqual(notebook.pages[2], before.pages[2], "dark writing space stays")
        XCTAssertEqual(notebook.pages[3].margins?.color, .dark)
        XCTAssertEqual(strokes(notebook.pages[3].drawing).map(\.color), [white, black], "margin ink black → white, scan ink unchanged")
        XCTAssertEqual(notebook.pages[4], before.pages[4])
    }

    // MARK: Current default shown by "Seitenstandard ändern"

    func testPageDefaultsUseStoredAppearance() throws {
        let notebook = try writtenNotebook(.dark, paper: .grid)
        XCTAssertEqual(notebook.pageDefaults.paper, .grid)
        XCTAssertEqual(notebook.pageDefaults.color, .dark)
        XCTAssertEqual(notebook.pageDefaults, notebook.appearance)
    }

    func testPageDefaultsOfOlderNotebookFollowLatestPaperPageLikeTheDraft() throws {
        var notebook = try Notebook.blank(title: "Alt")
        notebook.schemaVersion = 7
        _ = try notebook.insertPaper(.grid, color: .dark, at: 1)
        XCTAssertNil(notebook.appearance)
        XCTAssertEqual(notebook.pageDefaults.paper, .grid)
        XCTAssertEqual(notebook.pageDefaults.color, .dark)
        XCTAssertFalse(notebook.pageDefaults.coverEnabled, "older notebooks keep their page preview")
        let draft = notebook.writingDraft()
        XCTAssertEqual(draft.paper, notebook.pageDefaults.paper)
        XCTAssertEqual(draft.paperColor, notebook.pageDefaults.color)
    }

    func testPageDefaultsOfPrototypeAreNeverTheTestSheet() throws {
        let legacy = try Notebook.blank(title: "Alt").preparedForPageEditing()
        XCTAssertEqual(legacy.pages[0].paper, .blank)
        var prototype = Notebook()
        prototype = try prototype.preparedForPageEditing()
        XCTAssertEqual(prototype.pages[0].paper, .legacyTest)
        XCTAssertEqual(prototype.pageDefaults.paper, .blank)
        XCTAssertEqual(prototype.pageDefaults.color, .white)
    }
}
