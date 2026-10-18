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
            XCTAssertEqual(NotebookViewportGeometry.horizontalInset(viewportWidth: width, contentWidth: content * 6), width * 0.65)
        }
    }

    func testVerySmallContentStillAllowsCenteredView() {
        let width = 1194.0, content = 100.0
        let inset = NotebookViewportGeometry.horizontalInset(viewportWidth: width, contentWidth: content)
        XCTAssertGreaterThanOrEqual(inset, (width - content) / 2)
    }
}
