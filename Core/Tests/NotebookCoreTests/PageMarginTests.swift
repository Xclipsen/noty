import Foundation
import XCTest
@testable import NotebookCore

final class PageMarginTests: XCTestCase {
    private func pdfNotebook() throws -> Notebook {
        var value = Notebook()
        value.pdf = Data([1, 2, 3])
        value.pages[0].text = "Unverändert"
        value.pages[0].drawing = Data([20, 30, 40])
        value.pages[0].geometry = try PDFPageGeometry(mediaBox: .init(x: 10, y: 20, width: 600, height: 800),
            cropBox: .init(x: 30, y: 50, width: 500, height: 700), rotation: 90)
        return value
    }

    func testExpandedCanvasTranslatesSourceButNeverChangesItsScaleOrCanonicalLayers() throws {
        let original = try pdfNotebook()
        var value = original
        let margins = PageMargins(left: 120, right: 240, top: 80, bottom: 160, style: .grid, color: .dark)
        try value.setMargins(margins, pageIDs: [value.pages[0].id])
        XCTAssertEqual(value.pages[0].drawing, original.pages[0].drawing)
        XCTAssertEqual(value.pages[0].text, original.pages[0].text)
        XCTAssertEqual(value.pages[0].geometry, original.pages[0].geometry)
        XCTAssertEqual(value.pdfSources?.first?.data, original.pdf)
        let geometry = original.pages[0].geometry!
        let before = PageLayout(source: geometry, legacyA4: false)
        let after = PageLayout(source: geometry, legacyA4: false, margins: margins)
        XCTAssertEqual(after.canvas, PageSize(width: 1_060, height: 740))
        XCTAssertEqual(after.contentCanvas, before.canvas)
        XCTAssertEqual(after.sourceFrame.width, before.sourceFrame.width)
        XCTAssertEqual(after.sourceFrame.height, before.sourceFrame.height)
        let point = PagePoint(x: 70, y: 90)
        let oldPoint = before.pdfToCanvas.apply(point)
        let newPoint = after.pdfToCanvas.apply(point)
        XCTAssertEqual(newPoint.x, oldPoint.x + 120, accuracy: 1e-9)
        XCTAssertEqual(newPoint.y, oldPoint.y + 80, accuracy: 1e-9)
        XCTAssertEqual(after.pdfToCanvas.inverse.apply(newPoint).x, point.x, accuracy: 1e-9)
        XCTAssertEqual(try BackupArchive.decode(BackupArchive.encode(value)).document, value)
    }

    func testEveryRotationAndLegacyCanvasKeepIdenticalPDFContentSizeWithInsets() throws {
        for rotation in [0, 90, 180, 270] {
            let geometry = try PDFPageGeometry(mediaBox: .init(x: -40, y: 20, width: 800, height: 900),
                cropBox: .init(x: 10, y: 70, width: 500, height: 600), rotation: rotation)
            for legacy in [false, true] {
                let old = PageLayout(source: geometry, legacyA4: legacy)
                let new = PageLayout(source: geometry, legacyA4: legacy, margins: PageMargins(left: 90, top: 50))
                XCTAssertEqual(new.contentCanvas, old.canvas)
                XCTAssertEqual(new.sourceFrame.width, old.sourceFrame.width)
                XCTAssertEqual(new.sourceFrame.height, old.sourceFrame.height)
                XCTAssertEqual(new.pdfToCanvas.a, old.pdfToCanvas.a)
                XCTAssertEqual(new.pdfToCanvas.b, old.pdfToCanvas.b)
                XCTAssertEqual(new.pdfToCanvas.c, old.pdfToCanvas.c)
                XCTAssertEqual(new.pdfToCanvas.d, old.pdfToCanvas.d)
                XCTAssertEqual(new.pdfToCanvas.tx, old.pdfToCanvas.tx + 90)
                XCTAssertEqual(new.pdfToCanvas.ty, old.pdfToCanvas.ty + 50)
            }
        }
    }

    func testConfirmedTrimRestoresOriginalPageAndSavesResizedState() throws {
        var value = try pdfNotebook()
        let pageID = value.pages[0].id
        let oldMargins = PageMargins(left: 220, right: 310, top: 90, style: .lined, color: .dark)
        try value.setMargins(oldMargins, pageIDs: [pageID])
        let oldPage = value.pages[0]
        try value.applyMargins(PageMargins(right: 100), pageIDs: [pageID], trimmedDrawings: [pageID: Data([99])])
        XCTAssertEqual(value.pages[0].id, pageID)
        XCTAssertEqual(value.pages[0].drawing, Data([99]))
        let snapshot = try XCTUnwrap(value.deletedPages?.first)
        XCTAssertEqual(snapshot.reason, .marginReduction)
        XCTAssertNotEqual(snapshot.page.id, pageID)
        XCTAssertEqual(snapshot.page.margins, oldMargins)
        XCTAssertEqual(snapshot.page.drawing, oldPage.drawing)
        XCTAssertEqual(snapshot.page.text, oldPage.text)
        XCTAssertEqual(snapshot.page.geometry, oldPage.geometry)
        var restored = try Notebook.decode(JSONEncoder().encode(value))
        XCTAssertEqual(try restored.restorePage(snapshot.page.id), pageID)
        XCTAssertEqual(restored.pages.count, 1)
        XCTAssertEqual(restored.pages[0], oldPage)
        XCTAssertEqual(restored.deletedPages?.first?.page.drawing, Data([99]))
        XCTAssertEqual(restored.deletedPages?.first?.page.margins?.right, 100)
        XCTAssertEqual(restored.deletedPages?.first?.previousPageID, pageID)
    }

    func testExpansionAndSafeShrinkDoNotCreateTrashOrRewriteInk() throws {
        var value = try pdfNotebook()
        let drawing = value.pages[0].drawing; let id = value.pages[0].id
        try value.applyMargins(PageMargins(right: 200), pageIDs: [id])
        try value.applyMargins(PageMargins(), pageIDs: [id])
        XCTAssertNil(value.pages[0].margins)
        XCTAssertEqual(value.pages[0].drawing, drawing)
        XCTAssertTrue(value.deletedPages?.isEmpty == true)
    }

    func testInvalidMarginsPaperTargetsAndForeignTrimIDsCannotChangeDocument() throws {
        var value = try pdfNotebook()
        let original = value; let id = value.pages[0].id
        for invalid in [PageMargins(left: -1), PageMargins(top: .nan), PageMargins(right: .infinity),
                        PageMargins(bottom: 14_400), PageMargins(style: .legacyTest)] {
            XCTAssertThrowsError(try value.applyMargins(invalid, pageIDs: [id]))
            XCTAssertEqual(value, original)
        }
        XCTAssertThrowsError(try value.applyMargins(PageMargins(right: 50), pageIDs: [id], trimmedDrawings: [UUID(): Data([1])]))
        XCTAssertEqual(value, original)
        var paper = Notebook.blank(title: "Papier")
        XCTAssertThrowsError(try paper.setMargins(PageMargins(left: 50), pageIDs: [paper.pages[0].id]))
    }

    func testBookmarkAndDarkPaperSurviveDuplicationTrashAndHeftBackup() throws {
        var value = Notebook.blank(title: "Dunkles Heft")
        let id = try value.insertPaper(.grid, color: .dark, at: 1)
        try value.toggleBookmark(id)
        let copy = try value.duplicatePage(id)
        try value.toggleBookmark(copy)
        try value.trashPage(id)
        var decoded = try BackupArchive.decode(BackupArchive.encode(value)).document
        try decoded.restorePage(id)
        XCTAssertEqual(decoded.pages.first { $0.id == id }?.paperColor, .dark)
        XCTAssertEqual(decoded.pages.first { $0.id == id }?.bookmarked, true)
        XCTAssertEqual(decoded.pages.first { $0.id == copy }?.bookmarked, false)
    }
}
