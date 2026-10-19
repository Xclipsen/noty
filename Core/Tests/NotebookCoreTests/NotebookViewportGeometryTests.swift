import Foundation
import XCTest
@testable import NotebookCore

final class NotebookViewportGeometryTests: XCTestCase {
    private func rect(_ value: PageRect) -> CGRect {
        CGRect(x: value.x, y: value.y, width: value.width, height: value.height)
    }

    func testVisibleBottomOfNextPageAndTopOfPreviousRemainLoaded() {
        let pages = (0..<4).map { CGRect(x: 0, y: Double($0) * 866, width: 595, height: 842) }
        // Active page one is visible, plus the first 50 points of page two.
        let visible = PageRect(x: -16, y: 500, width: 627, height: 416)
        let preload = rect(NotebookViewportGeometry.preloadRect(visible: visible))
        XCTAssertTrue(preload.contains(rect(visible)))
        XCTAssertTrue(preload.intersects(pages[0]))
        XCTAssertTrue(preload.intersects(pages[1]))
        XCTAssertFalse(preload.intersects(pages[3]))
        // Looking back across a page boundary must keep both pages too.
        let back = NotebookViewportGeometry.preloadRect(visible: .init(x: -16, y: 830, width: 627, height: 416))
        XCTAssertTrue(rect(back).intersects(pages[0]))
        XCTAssertTrue(rect(back).intersects(pages[1]))
    }

    func testPreloadingAlwaysContainsEntireViewportAtEveryZoom() {
        for zoom in [0.15, 0.5, 1.0, 2.5, 6] {
            let visible = PageRect(x: -80 / zoom, y: 1300 / zoom, width: 1024 / zoom, height: 768 / zoom)
            let preload = NotebookViewportGeometry.preloadRect(visible: visible)
            XCTAssertLessThanOrEqual(preload.x, visible.x)
            XCTAssertLessThanOrEqual(preload.y, visible.y)
            XCTAssertGreaterThanOrEqual(preload.x + preload.width, visible.x + visible.width)
            XCTAssertGreaterThanOrEqual(preload.y + preload.height, visible.y + visible.height)
            XCTAssertGreaterThan(preload.height, visible.height)
            XCTAssertLessThanOrEqual(visible.y - preload.y, 1000)
            XCTAssertLessThanOrEqual(preload.y + preload.height - visible.y - visible.height, 1000.001)
        }
    }

    func testZoomedOutViewportRetainsAllVisibleSmallMixedPages() {
        let pages = [CGRect(x: 0, y: 0, width: 842, height: 300),
                     CGRect(x: 123, y: 324, width: 595, height: 400),
                     CGRect(x: 221, y: 748, width: 400, height: 300),
                     CGRect(x: 0, y: 1072, width: 842, height: 595)]
        let visible = PageRect(x: -50, y: 290, width: 942, height: 1500)
        let preload = rect(NotebookViewportGeometry.preloadRect(visible: visible))
        XCTAssertTrue(pages.allSatisfy { preload.intersects($0) })
    }

    func testHorizontalRoomIsAvailableAtFitAndHighZoom() {
        for width in [375.0, 744, 1194] {
            let content = width - 32 // Default fit leaves 16 points on each side.
            let inset = NotebookViewportGeometry.horizontalInset(viewportWidth: width, contentWidth: content)
            let centeredOffset = (content - width) / 2
            let minimumOffset = -inset
            let maximumOffset = content - width + inset
            XCTAssertGreaterThan(centeredOffset - minimumOffset, width * 0.6)
            XCTAssertEqual(centeredOffset - minimumOffset, maximumOffset - centeredOffset, accuracy: 0.001)
            XCTAssertEqual(NotebookViewportGeometry.horizontalInset(viewportWidth: width, contentWidth: content * 6), width)
        }
    }

    func testVerySmallContentStillAllowsCenteredView() {
        let width = 1194.0, content = 100.0
        let inset = NotebookViewportGeometry.horizontalInset(viewportWidth: width, contentWidth: content)
        XCTAssertGreaterThanOrEqual(inset, (width - content) / 2)
    }
}

/// Build 45 device feedback: zoomed to screen width, every pen stroke scrolled
/// the view a little to the left. Each stroke publishes the drawing, the
/// viewport relayouts and re-applies the horizontal limit at the same scroll
/// position; that limit must therefore be idempotent.
final class StrokeHorizontalDriftTests: XCTestCase {
    /// Plain paper above a PDF page with a right writing space, as in the editor.
    private func layout() -> NotebookViewportLayout {
        let plain = Page()
        var pdf = Page()
        pdf.margins = PageMargins(right: 300)
        return NotebookViewportLayout(pages: [plain, pdf], selectedPageID: pdf.id, paging: false, normalizeWidths: true)
    }

    private func constrain(_ x: Double, referenceY: Double, band: Double, pages: [NotebookPagePlacement],
                           viewportWidth: Double, scale: Double, writing: Bool = false) -> Double {
        NotebookViewportGeometry.blendedHorizontalOffset(x, referenceY: referenceY, band: band,
            pages: pages.map(\.frame), range: { i in
                NotebookViewportGeometry.horizontalRange(viewportWidth: viewportWidth, page: pages[i].frame, scale: scale,
                    anchors: writing ? pages[i].writingScrollAnchors : nil,
                    centre: pages[i].contentFrame.x + pages[i].contentFrame.width / 2)
            })!
    }

    func testRepeatedLayoutAtFitWidthNeverMovesTheView() {
        let pages = layout().pages
        let viewport = PageSize(width: 820, height: 1180)
        let range = NotebookViewportGeometry.zoomRange(viewport: viewport, placement: pages[1])
        let seam = (pages[0].frame.y + pages[0].frame.height + pages[1].frame.y) / 2
        // Fit, nearby fractional scales and arbitrary zooms.
        for scale in [range.fit, range.fit * 1.0371, range.fit * 0.9613, 0.7311, 1.913] {
            let band = viewport.height * 0.35 / scale
            for writing in [false, true] {
                for step in -12...12 {
                    let referenceY = seam + Double(step) / 10 * band
                    // Start from the fit/snap target (whole sheet centred) and other positions.
                    let fitX = NotebookViewportGeometry.jumpOffsetX(pages[1], scale: scale, viewportWidth: viewport.width, wholeSheet: true)
                    for start in [fitX, fitX - 37.3, fitX + 81.9, -500, 900] {
                        let settled = constrain(start, referenceY: referenceY, band: band, pages: pages,
                            viewportWidth: viewport.width, scale: scale, writing: writing)
                        var x = settled
                        for _ in 0..<50 {
                            x = constrain(x, referenceY: referenceY, band: band, pages: pages,
                                          viewportWidth: viewport.width, scale: scale, writing: writing)
                        }
                        XCTAssertEqual(x, settled, accuracy: 1e-9, "scale \(scale) step \(step) start \(start) writing \(writing)")
                    }
                }
            }
        }
    }

    func testOffsetAllowedOnBothSheetsIsKeptAcrossTheSeam() {
        let pages = layout().pages
        let viewport = PageSize(width: 820, height: 1180)
        let scale = NotebookViewportGeometry.zoomRange(viewport: viewport, placement: pages[1]).fit * 1.5
        let a = NotebookViewportGeometry.horizontalRange(viewportWidth: viewport.width, page: pages[0].frame, scale: scale,
            centre: pages[0].contentFrame.x + pages[0].contentFrame.width / 2)
        let b = NotebookViewportGeometry.horizontalRange(viewportWidth: viewport.width, page: pages[1].frame, scale: scale,
            centre: pages[1].contentFrame.x + pages[1].contentFrame.width / 2)
        let shared = max(a.lowerBound, b.lowerBound)...min(a.upperBound, b.upperBound)
        XCTAssertFalse(shared.isEmpty)
        let seam = (pages[0].frame.y + pages[0].frame.height + pages[1].frame.y) / 2
        let band = viewport.height * 0.35 / scale
        for x in [shared.lowerBound, (shared.lowerBound + shared.upperBound) / 2, shared.upperBound] {
            for step in -10...10 {
                XCTAssertEqual(constrain(x, referenceY: seam + Double(step) / 10 * band, band: band, pages: pages,
                                         viewportWidth: viewport.width, scale: scale), x, accuracy: 1e-9)
            }
        }
    }

    func testBlendedRangeStillGlidesContinuouslyOverTheSeam() {
        let pages = layout().pages
        let viewport = PageSize(width: 820, height: 1180)
        let scale = NotebookViewportGeometry.zoomRange(viewport: viewport, placement: pages[1]).fit
        let seam = (pages[0].frame.y + pages[0].frame.height + pages[1].frame.y) / 2
        let band = viewport.height * 0.35 / scale
        // Scrolling down from the plain page (centred) into the wide sheet.
        var x = constrain(10_000, referenceY: seam - band - 1, band: band, pages: pages, viewportWidth: viewport.width, scale: scale)
        var previous = x
        for step in 0...400 {
            x = constrain(x, referenceY: seam - band + Double(step) * band / 200, band: band, pages: pages,
                          viewportWidth: viewport.width, scale: scale)
            XCTAssertLessThan(abs(x - previous), 5)
            previous = x
        }
    }

    func testHorizontalOffsetIsAClampIntoHorizontalRange() {
        let page = PageRect(x: 12, y: 0, width: 895, height: 842)
        for scale in [0.5, 0.88, 1, 2.37] {
            for anchors in [nil, (left: 160.0, right: 745.0)] as [(left: Double, right: Double)?] {
                let range = NotebookViewportGeometry.horizontalRange(viewportWidth: 820, page: page, scale: scale,
                                                                      anchors: anchors, centre: 309.5)
                for requested in [-5000.0, range.lowerBound, (range.lowerBound + range.upperBound) / 2, range.upperBound, 5000] {
                    let x = NotebookViewportGeometry.horizontalOffset(requested, viewportWidth: 820, page: page, scale: scale,
                                                                      anchors: anchors, centre: 309.5)
                    XCTAssertTrue(range.contains(x))
                    XCTAssertEqual(NotebookViewportGeometry.horizontalOffset(x, viewportWidth: 820, page: page, scale: scale,
                                                                             anchors: anchors, centre: 309.5), x)
                }
            }
        }
    }
}
