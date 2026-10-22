import XCTest
@testable import NotebookCore

final class LassoTouchAndHighZoomTests: XCTestCase {
    private let region = LassoRegion(points: [.init(x: 0, y: 0), .init(x: 100, y: 0), .init(x: 100, y: 100), .init(x: 0, y: 100)])
    func testTouchedObjectsAndCrossingInkAreSelectedWithoutCompleteEnclosure() {
        XCTAssertTrue(region.intersects(.init(x: 90, y: 50, width: 30, height: 40)))
        XCTAssertTrue(region.intersects(.init(x: 100, y: 50, width: 30, height: 40)))
        XCTAssertTrue(region.intersects(.init(x: -50, y: -50, width: 200, height: 200)))
        XCTAssertTrue(region.intersectsPolyline([.init(x: -20, y: 50), .init(x: 120, y: 50)]))
        XCTAssertTrue(region.intersectsPolyline([.init(x: 50, y: -3)], radius: 4))
        XCTAssertFalse(region.intersectsPolyline([.init(x: 50, y: -5)], radius: 4))
        XCTAssertFalse(region.intersects(.init(x: 105, y: 50, width: 30, height: 40)))
    }
    func testFreeformDoesNotSelectEmptyBoundingBoxCorners() {
        let diamond = LassoRegion(points: [.init(x: 0, y: 50), .init(x: 50, y: 0), .init(x: 100, y: 50), .init(x: 50, y: 100)])
        XCTAssertFalse(diamond.intersects(.init(x: 0, y: 0, width: 10, height: 10)))
        XCTAssertFalse(diamond.intersectsPolyline([.init(x: 0, y: 0), .init(x: 8, y: 8)], radius: 2))
        XCTAssertTrue(diamond.intersectsPolyline([.init(x: -10, y: 50), .init(x: 110, y: 50)]))
    }
    func testConcaveNotchAndNegativeMarginsRemainUnselectedUntilActuallyTouched() {
        let concave = LassoRegion(points: [.init(x: -100, y: -100), .init(x: 100, y: -100), .init(x: 100, y: 100),
            .init(x: 20, y: 100), .init(x: 20, y: 0), .init(x: -20, y: 0), .init(x: -20, y: 100), .init(x: -100, y: 100)])
        XCTAssertFalse(concave.intersects(.init(x: -10, y: 10, width: 20, height: 60)))
        XCTAssertTrue(concave.intersects(.init(x: -30, y: 10, width: 20, height: 60)))
        XCTAssertTrue(concave.intersectsPolyline([.init(x: -120, y: -30), .init(x: -90, y: -30)]))
    }
    func testMixedMoveClampsAtPageInsteadOfDroppingEverything() {
        let frame = PageRect(x: 80, y: 20, width: 20, height: 40)
        let change = SelectionTransform(frame: frame, anchor: .init(x: 80, y: 20), translation: .init(x: 50, y: 12), scale: 1,
            limits: .init(x: 0, y: 0, width: 100, height: 100))
        XCTAssertEqual(change.translation, .init(x: 0, y: 12))
        XCTAssertEqual(change.apply(.init(x: 90, y: 40)), .init(x: 90, y: 52))
        let edge = SelectionTransform(frame: .init(x: -2, y: -2, width: 102, height: 20), anchor: .init(x: 0, y: 0),
            translation: .init(x: -50, y: 20), scale: 1, limits: .init(x: 0, y: 0, width: 100, height: 100))
        XCTAssertEqual(edge.translation, .init(x: 0, y: 20))
    }
    func testFourCornerScalingKeepsOppositeCornerFixedAndRespectsFontLimits() {
        let frame = PageRect(x: 20, y: 20, width: 40, height: 40)
        for anchor in [PagePoint(x: 20, y: 20), .init(x: 60, y: 20), .init(x: 60, y: 60), .init(x: 20, y: 60)] {
            let change = SelectionTransform(frame: frame, anchor: anchor, translation: .init(x: 0, y: 0), scale: 0.1,
                limits: .init(x: 0, y: 0, width: 100, height: 100), minimumScale: 0.5, maximumScale: 2)
            XCTAssertEqual(change.scale, 0.5); XCTAssertEqual(change.apply(anchor), anchor)
        }
        let start = PagePoint(x: 60, y: 60), anchor = PagePoint(x: 20, y: 20)
        XCTAssertEqual(SelectionTransform.projectedScale(start: start, current: .init(x: 40, y: 40), anchor: anchor), 0.5)
        XCTAssertLessThan(SelectionTransform.projectedScale(start: start, current: .init(x: 0, y: 0), anchor: anchor), 0.01)
    }
    func testHandwritingOutlineFollowsStrokeShapeRatherThanItsRectangle() {
        let hull = SelectionOutline.hull([.init(x: 0, y: 50), .init(x: 50, y: 0), .init(x: 100, y: 50), .init(x: 50, y: 100),
            .init(x: 50, y: 50), .init(x: 50, y: 50)])
        XCTAssertEqual(hull.count, 4)
        XCTAssertTrue(LassoRegion(points: hull).contains(.init(x: 50, y: 50)))
        XCTAssertFalse(LassoRegion(points: hull).contains(.init(x: 0, y: 0)))
    }
    func testSeveralMembersShareOneRoundedHullWithoutHoles() {
        // Nutzer zu Build 62: one contour around everything, with some room.
        let discs: [(center: PagePoint, radius: Double)] = [(.init(x: 0, y: 0), 7), (.init(x: 300, y: 0), 7), (.init(x: 150, y: 200), 10)]
        let hull = SelectionOutline.roundedHull(discs)
        let region = LassoRegion(points: hull)
        for disc in discs {
            for angle in stride(from: 0.0, to: 2 * .pi, by: .pi / 8) {
                let edge = PagePoint(x: disc.center.x + disc.radius * 0.98 * cos(angle), y: disc.center.y + disc.radius * 0.98 * sin(angle))
                XCTAssertTrue(region.contains(edge), "every widened member inside")
            }
        }
        XCTAssertTrue(region.contains(.init(x: 150, y: 50)), "the space between members is inside: one piece, no holes")
        XCTAssertFalse(region.contains(.init(x: 0, y: 200)))
        // Convex: every turn has the same sign (one simple closed outline).
        let turns = hull.indices.map { index -> Double in
            let a = hull[index], b = hull[(index + 1) % hull.count], c = hull[(index + 2) % hull.count]
            return (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
        }
        XCTAssertTrue(turns.allSatisfy { $0 > 0 } || turns.allSatisfy { $0 < 0 })
        XCTAssertGreaterThan(hull.count, 12, "rounded, not a triangle")
        XCTAssertTrue(SelectionOutline.roundedHull([]).isEmpty)
    }
    func testSelectionContourGapStaysConstantOnScreenInZoomSteps() {
        XCTAssertEqual(SelectionOutline.gap(displayScale: 1), 7)
        XCTAssertEqual(SelectionOutline.zoomBucket(0), 1)
        XCTAssertEqual(SelectionOutline.zoomBucket(.nan), 1)
        // Small pinch movements share one bucket, so the cached contour is reused.
        XCTAssertEqual(SelectionOutline.zoomBucket(2.0), SelectionOutline.zoomBucket(2.05))
        for scale in [0.3, 0.8, 1.0, 2.5, 6, 16] {
            let onScreen = SelectionOutline.gap(displayScale: scale) * scale
            XCTAssertGreaterThan(onScreen, 7 / 1.1); XCTAssertLessThan(onScreen, 7 * 1.1)
            XCTAssertGreaterThanOrEqual(SelectionOutline.sampleSpacing(gap: SelectionOutline.gap(displayScale: scale)), 1)
        }
        XCTAssertLessThan(SelectionOutline.sampleSpacing(gap: 7), 7)
    }
    func testNarrowPageCannotScrollIntoWritingAreaOfNextPage() {
        let narrow = PageRect(x: 0, y: 0, width: 595, height: 842)
        let wide = PageRect(x: 0, y: 866, width: 1190, height: 842)
        XCTAssertEqual(NotebookViewportGeometry.horizontalOffset(900, viewportWidth: 800, page: narrow, scale: 1), -102.5)
        XCTAssertEqual(NotebookViewportGeometry.horizontalOffset(900, viewportWidth: 800, page: wide, scale: 1), 406)
        XCTAssertEqual(NotebookViewportGeometry.horizontalOffset(3000, viewportWidth: 800, page: narrow, scale: 4), 1596)
        XCTAssertEqual(NotebookViewportGeometry.verticalDistance(700, page: narrow), 0)
        XCTAssertGreaterThan(NotebookViewportGeometry.verticalDistance(700, page: wide), 0)
    }
    func testHighZoomBackingStoresStayBoundedAcrossLargePages() {
        for scale in [1.0, 4, 8, 16, 32] {
            let viewport = InkRenderViewport(page: .init(width: 14400, height: 14400),
                visible: .init(x: 4000, y: 4000, width: 1100 / scale, height: 800 / scale), scale: scale)
            let resolution = EditorRenderGeometry.viewportScale(size: viewport.frame.size, displayScale: scale, screenScale: 2)
            XCTAssertLessThanOrEqual(viewport.frame.width * viewport.frame.height * resolution * resolution, 6_000_001)
        }
    }
    func testStandardWritingAreaKeepsPointAndTextSizeAcrossMixedImports() throws {
        var book = Notebook.blank(title: "Test")
        let geometries = try [PageSize(width: 240, height: 330), .init(width: 2380, height: 3368)].map {
            try PDFPageGeometry(mediaBox: .init(x: 0, y: 0, width: $0.width, height: $0.height), cropBox: .init(x: 0, y: 0, width: $0.width, height: $0.height), rotation: 0)
        }
        let ids = try book.insertPDF(Data([1]), geometries: geometries, at: 1)
        let margins = PageMargins.normalPageBesidePDF(geometries[0].displaySize)
        let assignment = try book.marginsByPage(margins, relativeTo: ids[0], wholeImport: true)
        XCTAssertEqual(assignment[ids[0]]?.right, 240); XCTAssertEqual(assignment[ids[1]]?.right, 2380)
        try book.applyMargins(assignment)
        let layout = NotebookViewportLayout(pages: book.pages, selectedPageID: ids[0], paging: false, normalizeWidths: true)
        for (page, placed) in zip(book.pages, layout.pages) {
            XCTAssertEqual(placed.readingFrame.width, 595, accuracy: 0.000001)
            XCTAssertEqual(14 * placed.scale * page.writingCoordinateScale, 14, accuracy: 0.000001)
        }
        XCTAssertEqual(book.pages[1].geometry, geometries[0]); XCTAssertEqual(book.pages[2].geometry, geometries[1])
    }
}
