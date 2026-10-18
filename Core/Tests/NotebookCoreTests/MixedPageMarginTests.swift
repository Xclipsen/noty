import Foundation
import XCTest
@testable import NotebookCore

final class MixedPageMarginTests: XCTestCase {
    private func mixedPDF() throws -> Notebook {
        var document = Notebook(); document.pdf = Data([1, 2, 3])
        let large = try PDFPageGeometry(mediaBox: .init(x: 0, y: 0, width: 595, height: 842),
            cropBox: .init(x: 40, y: 60, width: 515, height: 742), rotation: 0)
        let small = try PDFPageGeometry(mediaBox: .init(x: 0, y: 0, width: 400, height: 300),
            cropBox: .init(x: 20, y: 30, width: 330, height: 240), rotation: 270)
        document.pages = [large, small].enumerated().map { index, geometry in
            var page = Page(); page.geometry = geometry; page.text = "Seite \(index)"; page.drawing = Data([UInt8(index + 1)])
            return page
        }
        return document
    }

    func testHundredPercentDoesNotBecome215PercentOnSmallRotatedPage() throws {
        var value = try mixedPDF()
        let original = value
        // Old whole-import behavior: 515pt / 240pt rounds to 215%.
        XCTAssertEqual((515.0 / 240 * 100).rounded(), 215)
        let margins = PageMargins(left: 515 * 0.25, right: 515, top: 742 * 0.6, bottom: 742,
                                  style: .grid, color: .dark)
        let assignments = try value.marginsByPage(margins, relativeTo: value.pages[0].id, wholeImport: true)
        try value.applyMargins(assignments)
        let small = try XCTUnwrap(value.pages[1].margins)
        XCTAssertEqual(small.left, 60, accuracy: 1e-9)
        XCTAssertEqual(small.right, 240, accuracy: 1e-9)
        XCTAssertEqual(small.top, 198, accuracy: 1e-9)
        XCTAssertEqual(small.bottom, 330, accuracy: 1e-9)
        XCTAssertEqual(small.style, .grid); XCTAssertEqual(small.color, .dark)
        XCTAssertEqual(value.pages.map(\.drawing), original.pages.map(\.drawing))
        XCTAssertEqual(value.pages.map(\.text), original.pages.map(\.text))
        XCTAssertEqual(value.pages.map(\.geometry), original.pages.map(\.geometry))
        XCTAssertEqual(value.pdfSources?.first?.data, original.pdf)
        XCTAssertEqual(try BackupArchive.decode(BackupArchive.encode(value)).document, value)
    }

    func testApplyingFromSmallPageToLargePreservesSamePercentages() throws {
        let value = try mixedPDF()
        let assignments = try value.marginsByPage(PageMargins(right: 240 * 0.6, bottom: 330 * 0.25),
            relativeTo: value.pages[1].id, wholeImport: true)
        XCTAssertEqual(assignments[value.pages[0].id]!.right, 309, accuracy: 1e-9)
        XCTAssertEqual(assignments[value.pages[0].id]!.bottom, 185.5, accuracy: 1e-9)
        XCTAssertEqual(assignments[value.pages[1].id]!.right, 144, accuracy: 1e-9)
    }

    func testScopeExcludesOtherImportsPaperAndDeletedPages() throws {
        var value = try mixedPDF()
        let originalID = value.pages[0].id
        let deletedID = value.pages[1].id
        let other = try value.insertPDF(Data([7, 8]), geometries: [PaperStyle.geometry], at: 2)[0]
        _ = try value.insertPaper(.lined, at: 3)
        try value.trashPage(deletedID)
        let deleted = value.deletedPages
        let one = try value.marginsByPage(PageMargins(right: 100), relativeTo: originalID, wholeImport: false)
        XCTAssertEqual(Set(one.keys), [originalID])
        let all = try value.marginsByPage(PageMargins(right: 100), relativeTo: originalID, wholeImport: true)
        XCTAssertEqual(Set(all.keys), [originalID])
        try value.applyMargins(all)
        XCTAssertNil(value.pages.first { $0.id == other }?.margins)
        XCTAssertEqual(value.deletedPages, deleted)
        XCTAssertNil(value.pages.last?.margins)
    }

    func testLegacyNilGeometryUsesFixedA4RatherThanSourceCropSize() throws {
        var value = try mixedPDF(); value.pages[0].geometry = nil
        let assignments = try value.marginsByPage(PageMargins(right: 595, top: 842 * 0.25),
            relativeTo: value.pages[0].id, wholeImport: true)
        XCTAssertEqual(assignments[value.pages[1].id]!.right, 240, accuracy: 1e-9)
        XCTAssertEqual(assignments[value.pages[1].id]!.top, 82.5, accuracy: 1e-9)
    }

    func testPerPageTrimSnapshotKeepsPreviousOversizedMarginAndSource() throws {
        var value = try mixedPDF()
        let id = value.pages[1].id
        try value.setMargins(PageMargins(right: 515), pageIDs: [id])
        let oldPage = value.pages[1]
        let assignments = try value.marginsByPage(PageMargins(right: 515), relativeTo: value.pages[0].id, wholeImport: true)
        try value.applyMargins(assignments, trimmedDrawings: [id: Data([99])])
        XCTAssertEqual(value.pages[1].margins?.right, 240)
        let saved = try XCTUnwrap(value.deletedPages?.first)
        XCTAssertEqual(saved.page.margins?.right, 515)
        XCTAssertEqual(saved.page.drawing, oldPage.drawing)
        try value.restorePage(saved.id)
        XCTAssertNil(value.pages.first { $0.id == saved.id })
        XCTAssertEqual(value.pages.first { $0.id == id }, oldPage)
        XCTAssertEqual(value.deletedPages?.first?.page.margins?.right, 240)
    }

    func testInvalidScalingOrAssignmentAbortsWithoutChangingExistingDocument() throws {
        for bad in [PageSize(width: 0, height: 1), PageSize(width: .nan, height: 1), PageSize(width: 1, height: .infinity)] {
            XCTAssertThrowsError(try PageMargins(right: 1).scaled(from: bad, to: .a4))
            XCTAssertThrowsError(try PageMargins(right: 1).scaled(from: .a4, to: bad))
        }
        var value = try mixedPDF(); let original = value
        XCTAssertThrowsError(try value.applyMargins([value.pages[0].id: PageMargins(right: 14_400)]))
        XCTAssertEqual(value, original)
        XCTAssertThrowsError(try value.applyMargins([UUID(): PageMargins(right: 100)]))
        XCTAssertEqual(value, original)
        XCTAssertThrowsError(try value.applyMargins(PageMargins(right: 10), pageIDs: [value.pages[0].id, value.pages[0].id]))
        XCTAssertEqual(value, original)
    }
}
