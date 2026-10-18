import Foundation
import XCTest
@testable import NotebookCore

final class NotebookViewportLayoutTests: XCTestCase {
    private func page(_ width: Double, _ height: Double, rotation: Int = 0) throws -> Page {
        var page = Page()
        let box = PageRect(x: 20, y: 30, width: width, height: height)
        page.geometry = try PDFPageGeometry(mediaBox: box, cropBox: box, rotation: rotation)
        return page
    }

    func testMixedPointSizesShareReadableBaseWidthAndKeepAspectRatio() throws {
        let pages = try [page(595, 842), page(2380, 3368), page(240, 340), page(800, 600, rotation: 90)]
        let layout = NotebookViewportLayout(pages: pages, selectedPageID: pages[0].id, paging: false, normalizeWidths: true)
        XCTAssertEqual(layout.pages.count, 4)
        for (page, placed) in zip(pages, layout.pages) {
            let original = try XCTUnwrap(page.geometry?.displaySize)
            XCTAssertEqual(placed.contentFrame.width, 595, accuracy: 0.001)
            XCTAssertEqual(placed.contentFrame.height / placed.contentFrame.width, original.height / original.width, accuracy: 0.001)
            XCTAssertEqual(placed.canvas, page.textBounds.size)
        }
        XCTAssertEqual(layout.pages[0].frame.height, layout.pages[1].frame.height)
    }

    func testMarginsRemainSeparateAndWorksheetEdgesAlign() throws {
        var a = try page(2380, 3368); a.margins = PageMargins(left: 238, right: 1428, top: 100, bottom: 200)
        var b = try page(240, 340); b.margins = PageMargins(right: 240)
        let layout = NotebookViewportLayout(pages: [a,b], selectedPageID: a.id, paging: false, normalizeWidths: true)
        XCTAssertEqual(layout.pages[0].contentFrame.x, layout.pages[1].contentFrame.x, accuracy: 0.001)
        XCTAssertEqual(layout.pages[0].contentFrame.width, layout.pages[1].contentFrame.width, accuracy: 0.001)
        for item in layout.pages {
            XCTAssertGreaterThanOrEqual(item.frame.x, 0)
            XCTAssertLessThanOrEqual(item.frame.x + item.frame.width, layout.size.width + 0.001)
            XCTAssertGreaterThan(item.frame.width, item.contentFrame.width)
        }
        XCTAssertEqual(layout.pages[1].frame.y - layout.pages[0].frame.y - layout.pages[0].frame.height, 24, accuracy: 0.001)
    }

    func testSearchAndNegativeMarginCoordinatesShareOneTransform() throws {
        var page = try page(2380, 3368); page.margins = PageMargins(left: 200, right: 500, top: 300)
        let layout = NotebookViewportLayout(pages: [page], selectedPageID: page.id, paging: false, normalizeWidths: true)
        let placed = try XCTUnwrap(layout.pages.first)
        let whole = placed.surfaceRect(for: page.textBounds)
        XCTAssertEqual(whole.x, placed.frame.x, accuracy: 0.001)
        XCTAssertEqual(whole.y, placed.frame.y, accuracy: 0.001)
        XCTAssertEqual(whole.width, placed.frame.width, accuracy: 0.001)
        let hit = placed.surfaceRect(for: .init(x: 40, y: 80, width: 200, height: 40))
        XCTAssertEqual(hit.x, placed.contentFrame.x + 10, accuracy: 0.001)
        XCTAssertEqual(hit.y, placed.contentFrame.y + 20, accuracy: 0.001)
        XCTAssertEqual(hit.width, 50)
        XCTAssertEqual(hit.height, 10)
    }

    func testDisabledModeKeepsOriginalPointSizesAndCentersWholePages() throws {
        let pages = try [page(595,842), page(2380,3368)]
        let layout = NotebookViewportLayout(pages: pages, selectedPageID: pages[0].id, paging: false, normalizeWidths: false)
        XCTAssertEqual(layout.size.width, 2380)
        for item in layout.pages {
            XCTAssertEqual(item.scale, 1)
            XCTAssertEqual(item.frame.size, item.canvas)
            XCTAssertEqual(item.frame.x + item.frame.width / 2, 1190)
        }
    }

    func testPagingFitsWorksheetRatherThanShrinkingForWritingMargin() throws {
        var page = try page(2380,3368); page.margins = PageMargins(right: 2380)
        let layout = NotebookViewportLayout(pages: [try self.page(595,842),page], selectedPageID: page.id, paging: true, normalizeWidths: true)
        XCTAssertEqual(layout.pages.count, 1)
        let placed = try XCTUnwrap(layout.pages.first)
        let range = NotebookViewportGeometry.zoomRange(viewport: .init(width: 1024, height: 768), page: placed.frame.size, contentWidth: placed.contentFrame.width)
        XCTAssertEqual(placed.contentFrame.width * range.fit, 992, accuracy: 0.001)
        XCTAssertEqual(placed.frame.width * range.fit, 1984, accuracy: 0.001)
    }

    func testNormalizingAndSwitchingBackDoesNotChangeAnyStoredContent() throws {
        var book = Notebook.blank(title: "Nur Anzeige")
        let pdf = Data([1,2,3,4,5])
        let id = try book.insertPDF(pdf, geometries: [try page(2380,3368).geometry!], at: 1)[0]
        try book.replaceTextBoxes([TextBox(x: 200, y: 300, width: 600, height: 100, text: "Scharfer Text")], pageID: id)
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let before = try encoder.encode(book)
        for normalized in [true,false,true,false] {
            _ = NotebookViewportLayout(pages: book.pages, selectedPageID: id, paging: false, normalizeWidths: normalized)
        }
        XCTAssertEqual(try encoder.encode(book), before)
        XCTAssertEqual(book.pdfSources?.first?.data, pdf)
    }

    func testLegacyA4RemainsA4AndEmptyLayoutIsSafe() {
        let page = Page()
        let layout = NotebookViewportLayout(pages: [page], selectedPageID: page.id, paging: false, normalizeWidths: true)
        XCTAssertEqual(layout.pages.first?.scale, 1)
        XCTAssertEqual(layout.pages.first?.canvas, .a4)
        XCTAssertTrue(NotebookViewportLayout(pages: [], selectedPageID: UUID(), paging: false, normalizeWidths: true).pages.isEmpty)
    }

    func testVersionSixMigrationLeavesModeOffAndRejectsHiddenNewSetting() throws {
        var old = ToolbarPreferences(); old.formatVersion = 6; old.dockOnly = false
        var expected = old; expected.formatVersion = 7
        let decoded = try ToolbarPreferences.decode(JSONEncoder().encode(old))
        XCTAssertEqual(decoded, expected); XCTAssertNil(decoded.normalizePageWidths)
        old.normalizePageWidths = true
        XCTAssertThrowsError(try ToolbarPreferences.decode(JSONEncoder().encode(old)))
        expected.normalizePageWidths = true
        XCTAssertEqual(try ToolbarPreferences.decode(JSONEncoder().encode(expected)), expected)
    }
}
