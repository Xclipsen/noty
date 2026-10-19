import Foundation
import XCTest
@testable import NotebookCore

final class HeaderAndInputTests: XCTestCase {
    func testReported874PointEditorKeepsAllMainToolsInTopRow() {
        let layout = ToolbarLayout(viewport: .init(width: 874, height: 760), dock: .top, items: 9)
        XCTAssertTrue(layout.inlineHeader); XCTAssertTrue(layout.compactHeader)
        XCTAssertEqual(layout.frame.width, 480)
        XCTAssertEqual(layout.frame.y, 4)
        XCTAssertEqual(layout.topInset, 64)
        XCTAssertEqual(layout.center.x, 437)
        XCTAssertEqual(layout.headerActionsFrame.width, 140)
        XCTAssertLessThanOrEqual(layout.headerLeadingFrame.x + layout.headerLeadingFrame.width + 10, layout.frame.x)
        XCTAssertGreaterThanOrEqual(layout.headerActionsFrame.x, layout.frame.x + layout.frame.width + 10)
    }

    func testOpening320PointSidebarDoesNotMovePaletteDown() {
        let closed = ToolbarLayout(viewport: .init(width: 1194, height: 760), dock: .top, items: 9)
        let opened = ToolbarLayout(viewport: .init(width: 1194 - 320, height: 760), dock: .top, items: 9)
        XCTAssertFalse(closed.compactHeader); XCTAssertTrue(opened.compactHeader)
        XCTAssertEqual(closed.frame.y, opened.frame.y)
        XCTAssertEqual(closed.topInset, opened.topInset)
        XCTAssertEqual(closed.headerActionsFrame.width, 272)
        XCTAssertEqual(closed.headerActionCount, 6)
    }

    func testBiggerCellsFillOldGapsWithoutGrowingPaletteAndHeadersStayStable() {
        XCTAssertEqual(ToolbarLayout.cell, 48)
        XCTAssertEqual(ToolbarLayout.spacing, 0)
        XCTAssertEqual(ToolbarLayout.length(items: 9), 480)
        let main = ToolbarLayout(viewport: .init(width: 744, height: 760), dock: .top, items: 9, headerItems: 9)
        let more = ToolbarLayout(viewport: main.viewport, dock: .top, items: 7, headerItems: 9)
        XCTAssertTrue(main.inlineHeader)
        XCTAssertEqual(main.frame.width, 428)
        XCTAssertEqual(main.headerLeadingFrame, more.headerLeadingFrame)
        XCTAssertEqual(main.headerActionsFrame, more.headerActionsFrame)
    }

    func testTrulyNarrowWindowStillHasUsableSeparateRow() {
        let layout = ToolbarLayout(viewport: .init(width: 375, height: 667), dock: .top, items: 9)
        XCTAssertFalse(layout.inlineHeader)
        XCTAssertEqual(layout.frame.y, 76)
        XCTAssertGreaterThanOrEqual(layout.frame.width, 320)
        XCTAssertLessThanOrEqual(layout.headerLeadingFrame.x + layout.headerLeadingFrame.width, layout.headerActionsFrame.x - 8)
    }

    func testMinimumZoomShowsAboutThreePageWidthsAndStillWholeSheet() {
        for size in [PageSize(width: 595, height: 842), .init(width: 1190, height: 842), .init(width: 842, height: 300)] {
            let range = NotebookViewportGeometry.zoomRange(viewport: .init(width: 874, height: 700), page: size, contentWidth: 595)
            XCTAssertLessThanOrEqual(range.minimum * size.width, 842.001)
            XCTAssertLessThanOrEqual(range.minimum * size.height, 668.001)
            XCTAssertEqual(range.minimum * 595 * 3, 874, accuracy: 0.001)
        }
    }

    func testRotationSnapsAtEveryRightAngleIncludingWraparound() {
        for angle in [-180.0, -90, 0, 90, 180] {
            for delta in [-7.9, 0, 7.9] {
                let snap = ImageObject.rotationSnap(angle + delta)
                XCTAssertNotNil(snap)
                if let snap { XCTAssertEqual(ImageObject.normalizedRotation(snap - angle), 0, accuracy: 0.001) }
            }
        }
    }

    func testRotationHoldsStraightUntilReleaseAndFreeRotationStillWorks() {
        XCTAssertEqual(ImageObject.rotationSnap(84), 90)
        XCTAssertNil(ImageObject.rotationSnap(100))
        XCTAssertEqual(ImageObject.rotationSnap(100, previous: 90), 90)
        XCTAssertNil(ImageObject.rotationSnap(103, previous: 90))
        XCTAssertEqual(ImageObject.rotationSnap(-175, previous: 180), 180)
        XCTAssertNil(ImageObject.rotationSnap(37))
    }

    func testTurnButtonLandsExactlyOnNextStraightAngle() {
        for (start, target) in [(0.0,90.0),(33,90),(90,180),(179,180),(180,-90),(-33,0),(-90,0)] {
            XCTAssertEqual(ImageObject.nextRightAngle(after: start), target)
        }
    }

    func testWidthSnapIsNearOnlyAndDoesNotStealWholePageLimit() {
        let range = NotebookViewportGeometry.zoomRange(viewport: .init(width: 744, height: 700), page: .a4)
        for relative in [0.92, 0.98, 1.0, 1.08] {
            XCTAssertEqual(NotebookViewportGeometry.widthSnap(scale: range.fit * relative, range: range), range.fit)
        }
        XCTAssertNil(NotebookViewportGeometry.widthSnap(scale: range.fit * 0.90, range: range))
        XCTAssertNil(NotebookViewportGeometry.widthSnap(scale: range.fit * 1.10, range: range))
        XCTAssertNil(NotebookViewportGeometry.widthSnap(scale: range.minimum, range: range))
        XCTAssertNil(NotebookViewportGeometry.widthSnap(scale: .nan, range: range))
    }
}
