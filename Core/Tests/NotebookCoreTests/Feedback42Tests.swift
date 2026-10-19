import Foundation
import XCTest
@testable import NotebookCore

/// Build 42 feedback: page jumps centre the PDF beside a writing space.
final class Feedback42Tests: XCTestCase {
    private func placed(margins: PageMargins?, normalized: Bool = false) throws -> NotebookPagePlacement {
        var page = Page()
        let box = PageRect(x: 0, y: 0, width: 595, height: 842)
        page.geometry = try PDFPageGeometry(mediaBox: box, cropBox: box, rotation: 0)
        page.margins = margins
        let paper = Page()
        let layout = NotebookViewportLayout(pages: [paper, page], selectedPageID: page.id, paging: false, normalizeWidths: normalized)
        return try XCTUnwrap(layout.pages.last)
    }
    private func centre(_ placement: NotebookPagePlacement) -> Double {
        placement.contentFrame.x + placement.contentFrame.width / 2
    }

    func testJumpCentresPDFAndFitCentresWholeSheet() throws {
        let width = 1024.0
        for margins in [PageMargins(right: 595), PageMargins(left: 200, right: 400)] {
            let page = try placed(margins: margins)
            for scale in [0.6, 0.86, 1.5, 3] {
                let jump = NotebookViewportGeometry.jumpOffsetX(page, scale: scale, viewportWidth: width, wholeSheet: false)
                XCTAssertEqual(jump + width / 2, centre(page) * scale, accuracy: 0.0001, "PDF in the middle of the screen")
                let fit = NotebookViewportGeometry.jumpOffsetX(page, scale: scale, viewportWidth: width, wholeSheet: true)
                XCTAssertEqual(fit + width / 2, (page.frame.x + page.frame.width / 2) * scale, accuracy: 0.0001)
                // The horizontal clamp keeps the jump position in both scroll modes.
                for anchors in [nil, page.writingScrollAnchors] as [(left: Double, right: Double)?] {
                    XCTAssertEqual(NotebookViewportGeometry.horizontalOffset(jump, viewportWidth: width, page: page.frame,
                        scale: scale, anchors: anchors, centre: centre(page)), jump, accuracy: 0.0001)
                }
            }
        }
    }

    func testWholeSheetFitStillCentresTheSheetUnlessAJumpAskedForThePDF() throws {
        let page = try placed(margins: PageMargins(right: 595))
        let width = 1024.0
        let fit = (width - 32) / page.frame.width
        let whole = (page.frame.x * fit + (page.frame.x + page.frame.width) * fit - width) / 2
        // Without the PDF centre the old rule holds: a fitting sheet is centred.
        XCTAssertEqual(NotebookViewportGeometry.horizontalOffset(-500, viewportWidth: width, page: page.frame, scale: fit), whole, accuracy: 0.0001)
        // With it, the range spans exactly whole-sheet centre ... PDF centre.
        let jump = NotebookViewportGeometry.jumpOffsetX(page, scale: fit, viewportWidth: width, wholeSheet: false)
        let low = NotebookViewportGeometry.horizontalOffset(-10_000, viewportWidth: width, page: page.frame, scale: fit, centre: centre(page))
        let high = NotebookViewportGeometry.horizontalOffset(10_000, viewportWidth: width, page: page.frame, scale: fit, centre: centre(page))
        XCTAssertEqual(low, min(whole, jump), accuracy: 0.0001)
        XCTAssertEqual(high, max(whole, jump), accuracy: 0.0001)
    }

    func testPagesWithoutWritingSpaceKeepTheirClamp() throws {
        let page = try placed(margins: nil, normalized: true)
        for scale in [0.5, 1.0, 2.5] {
            for requested in [-2000.0, -10, 0, 150, 900, 5000] {
                XCTAssertEqual(
                    NotebookViewportGeometry.horizontalOffset(requested, viewportWidth: 800, page: page.frame, scale: scale, centre: centre(page)),
                    NotebookViewportGeometry.horizontalOffset(requested, viewportWidth: 800, page: page.frame, scale: scale), accuracy: 0.0001)
            }
            XCTAssertEqual(NotebookViewportGeometry.jumpOffsetX(page, scale: scale, viewportWidth: 800, wholeSheet: false),
                           NotebookViewportGeometry.jumpOffsetX(page, scale: scale, viewportWidth: 800, wholeSheet: true), accuracy: 0.0001)
        }
    }
}
