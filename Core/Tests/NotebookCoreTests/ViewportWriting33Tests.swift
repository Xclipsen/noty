import Foundation
import XCTest
@testable import NotebookCore

final class ViewportWriting33Tests: XCTestCase {
    func testZoomOutLimitIsThreePageWidthsAndOverZoomSpringsBackCentred() throws {
        let viewport = PageSize(width: 1194, height: 760)
        let range = NotebookViewportGeometry.zoomRange(viewport: viewport, page: .a4)
        XCTAssertEqual(range.minimum * 595 * 3, 1194, accuracy: 0.001)
        XCTAssertGreaterThan(range.maximum, range.fit * 5)
        let page = PageRect(x: 0, y: 1000, width: 595, height: 842)
        let target = try XCTUnwrap(NotebookViewportGeometry.zoomDestination(scale: NotebookViewportGeometry.elasticMinimum(range),
            range: range, page: page, widthRegion: page, viewport: viewport, center: .init(x: -400, y: 1300)))
        XCTAssertEqual(target.scale, range.minimum)
        XCTAssertEqual(target.offset.x + viewport.width / 2, 297.5 * range.minimum, accuracy: 0.0001)
        XCTAssertEqual(target.offset.y + viewport.height / 2, 1300 * range.minimum, accuracy: 0.0001)
        // Between the limit and the width fit zoom stays free.
        XCTAssertNil(NotebookViewportGeometry.zoomDestination(scale: range.fit * 0.6, range: range,
            page: page, widthRegion: page, viewport: viewport, center: .init(x: 0, y: 0)))
    }

    func testNormalModeKeepsZoomedOutSheetCentred() {
        let page = PageRect(x: 0, y: 0, width: 595, height: 842)
        let scale = 0.5, width = 1000.0
        let centred = (297.5 * scale) - width / 2
        for requested in [-2000.0, -300, 0, 600] {
            XCTAssertEqual(NotebookViewportGeometry.horizontalOffset(requested, viewportWidth: width, page: page, scale: scale), centred)
        }
    }

    func testWritingScrollStopsAtSheetCentreForNormalPage() throws {
        let paper = Notebook.blank(title: "W").pages[0]
        let layout = NotebookViewportLayout(pages: [paper], selectedPageID: paper.id, paging: false, normalizeWidths: false)
        let placed = try XCTUnwrap(layout.pages.first)
        let anchors = placed.writingScrollAnchors
        XCTAssertEqual(anchors.left, 297.5); XCTAssertEqual(anchors.right, 297.5)
        let scale = 2.0, width = 1000.0
        let far = NotebookViewportGeometry.horizontalOffset(99_999, viewportWidth: width, page: placed.frame, scale: scale, anchors: anchors)
        XCTAssertEqual(far, 297.5 * scale) // sheet centre exactly at the left screen edge
        let back = NotebookViewportGeometry.horizontalOffset(-99_999, viewportWidth: width, page: placed.frame, scale: scale, anchors: anchors)
        XCTAssertEqual(back + width, 297.5 * scale) // sheet centre exactly at the right screen edge
        XCTAssertEqual(NotebookViewportGeometry.horizontalOffset(300, viewportWidth: width, page: placed.frame, scale: scale, anchors: anchors), 300)
    }

    func testWritingScrollKeepsHalfOfWritingMarginVisible() throws {
        var page = Notebook.blank(title: "M").pages[0]
        page.margins = PageMargins(right: 595)
        let layout = NotebookViewportLayout(pages: [page], selectedPageID: page.id, paging: false, normalizeWidths: true)
        let placed = try XCTUnwrap(layout.pages.first)
        let anchors = placed.writingScrollAnchors
        XCTAssertEqual(anchors.left, placed.contentFrame.x + placed.contentFrame.width / 2, accuracy: 0.001)
        XCTAssertEqual(anchors.right, placed.frame.x + placed.frame.width - 595.0 * placed.scale / 2, accuracy: 0.001)
        let x = NotebookViewportGeometry.horizontalOffset(99_999, viewportWidth: 800, page: placed.frame, scale: 1, anchors: anchors)
        let visibleMargin = placed.frame.x + placed.frame.width - x
        XCTAssertEqual(visibleMargin, 595.0 * placed.scale / 2, accuracy: 0.001)
    }

    func testPagesSitCloseTogether() {
        let notebook = Notebook.blank(title: "G")
        var second = notebook.pages[0]; second.id = UUID()
        let layout = NotebookViewportLayout(pages: [notebook.pages[0], second], selectedPageID: second.id, paging: false, normalizeWidths: false)
        XCTAssertEqual(layout.pages[1].frame.y - layout.pages[0].frame.y - layout.pages[0].frame.height, NotebookViewportLayout.pageGap)
        XCTAssertLessThanOrEqual(NotebookViewportLayout.pageGap, 8)
    }

    func testInkWidthFollowsSheetWidthSoWideScansAndMarginsMatchPaper() throws {
        let paper = Notebook.blank(title: "P").pages[0]
        XCTAssertEqual(paper.inkWidthScale, 1)
        var scan = paper
        scan.geometry = try PDFPageGeometry(mediaBox: .init(x: 0, y: 0, width: 1190, height: 1684),
                                            cropBox: .init(x: 0, y: 0, width: 1190, height: 1684), rotation: 0)
        scan.margins = .normalPageBesidePDF(PageSize(width: 1190, height: 1684))
        XCTAssertEqual(scan.inkWidthScale, 2, accuracy: 0.0001)
        let layout = NotebookViewportLayout(pages: [paper, scan], selectedPageID: paper.id, paging: false, normalizeWidths: true)
        // Displayed width = canonical width × sheet scale; equal for both pages.
        XCTAssertEqual(2 * paper.inkWidthScale * layout.pages[0].scale, 2 * scan.inkWidthScale * layout.pages[1].scale, accuracy: 0.0001)
    }

    func testLivePinchKeepsCoveredInkRasterAndResolutionIsCapped() {
        let page = PageSize(width: 595, height: 842)
        let visible = PageRect(x: 200, y: 300, width: 100, height: 80)
        let plan = InkRenderViewport(page: page, visible: visible, scale: 4)
        let zoomedIn = PageRect(x: 220, y: 310, width: 60, height: 50)
        XCTAssertFalse(plan.covers(zoomedIn, page: page, scale: 5.66))
        XCTAssertTrue(plan.covers(zoomedIn, page: page, scale: 5.66, ignoringScale: true))
        // Zooming out past the raster still forces a new viewport mid-gesture.
        XCTAssertFalse(plan.covers(.init(x: 0, y: 0, width: 595, height: 842), page: page, scale: 2, ignoringScale: true))
        XCTAssertLessThan(EditorRenderGeometry.maximumInkScale, 8)
    }
}

final class PageSeamBlendTests: XCTestCase {
    func testOffsetGlidesBetweenNarrowAndWideSheetInsteadOfJumping() {
        let narrow = PageRect(x: 0, y: 0, width: 595, height: 842)
        let wide = PageRect(x: 0, y: 850, width: 1190, height: 842)
        let pages = [narrow, wide]
        func limit(_ i: Int, _ x: Double) -> Double {
            NotebookViewportGeometry.horizontalOffset(x, viewportWidth: 1000, page: pages[i], scale: 1)
        }
        let seam = (842.0 + 850) / 2, band = 200.0
        func offset(_ y: Double) -> Double {
            NotebookViewportGeometry.blendedHorizontalOffset(500, referenceY: y, band: band, pages: pages, range: {
                NotebookViewportGeometry.horizontalRange(viewportWidth: 1000, page: pages[$0], scale: 1)
            })!
        }
        XCTAssertEqual(offset(seam - band - 1), limit(0, 500))
        XCTAssertEqual(offset(seam + band + 1), limit(1, 500))
        XCTAssertEqual(offset(seam), (limit(0, 500) + limit(1, 500)) / 2, accuracy: 0.0001)
        // Monotonic and continuous: no single scroll step moves more than a sliver sideways.
        var previous = offset(seam - band)
        for step in 1...400 {
            let value = offset(seam - band + Double(step))
            XCTAssertLessThan(abs(value - previous), 5)
            previous = value
        }
    }
}
