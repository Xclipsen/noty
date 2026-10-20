import XCTest
@testable import NotebookCore

final class Feedback30Tests: XCTestCase {
    private let box = LassoRegion(points: [.init(x: -100, y: -80), .init(x: 200, y: -80), .init(x: 200, y: 250), .init(x: -100, y: 250)])
    func testOneVisibleLassoPreservesEveryLegacyToolAndCustomOrder() throws {
        var preferences = ToolbarPreferences(); preferences.order.reverse()
        let original = preferences.order
        let decoded = try ToolbarPreferences.decode(JSONEncoder().encode(preferences))
        XCTAssertEqual(decoded.order, original)
        XCTAssertEqual(decoded.mainTools.filter { $0 == .inkSelection }.count, 1)
        XCTAssertFalse(decoded.mainTools.contains(.selection)); XCTAssertFalse(decoded.mainTools.contains(.precisionEraser))
        XCTAssertEqual(Set(decoded.mainTools), [.pen, .pencil, .marker, .strokeEraser, .text, .inkSelection, .shape, .image, .read, .laser])
    }
    func testRectangleIncludesThinInkAndNegativeMarginCoordinatesButNotCrossingStroke() {
        XCTAssertTrue(box.containsPolyline([.init(x: -90, y: 0), .init(x: 100, y: 0)]))
        XCTAssertTrue(box.contains(.init(x: -100, y: -80)))
        XCTAssertFalse(box.containsPolyline([.init(x: -120, y: 0), .init(x: 220, y: 0)]))
        XCTAssertFalse(box.contains(.init(x: 180, y: 200, width: 40, height: 40)))
    }
    func testFreeformUsesActualInkPathInsteadOfBoundingBoxCorners() {
        let polygon = LassoRegion(points: [.init(x: 0, y: 50), .init(x: 50, y: 0), .init(x: 100, y: 50), .init(x: 50, y: 100)])
        XCTAssertTrue(polygon.containsPolyline([.init(x: 20, y: 50), .init(x: 50, y: 20), .init(x: 80, y: 50), .init(x: 50, y: 80)]))
        XCTAssertFalse(polygon.contains(.init(x: 20, y: 20, width: 60, height: 60)))
    }
    func testConcaveLassoRejectsSegmentsAndObjectsThatCrossItsNotch() {
        let polygon = LassoRegion(points: [.init(x: 0, y: 0), .init(x: 100, y: 0), .init(x: 100, y: 100),
            .init(x: 60, y: 100), .init(x: 60, y: 40), .init(x: 40, y: 40), .init(x: 40, y: 100), .init(x: 0, y: 100)])
        XCTAssertTrue(polygon.contains(.init(x: 20, y: 80))); XCTAssertTrue(polygon.contains(.init(x: 80, y: 80)))
        XCTAssertFalse(polygon.containsPolyline([.init(x: 20, y: 80), .init(x: 80, y: 80)]))
        XCTAssertFalse(polygon.contains(.init(x: 20, y: 20, width: 60, height: 60)))
    }
    func testCircularTaskRenderingMetadataKeepsStoredUnicodeAndWordFormattingRanges() {
        let text = "\t☐ 👨‍👩‍👧‍👦 offen\n  ☑ fertig\nNormal"
        let items = TextListEditing.taskItems(in: text)
        XCTAssertEqual(items.count, 2); XCTAssertFalse(items[0].checked); XCTAssertTrue(items[1].checked)
        XCTAssertEqual((text as NSString).substring(with: items[0].marker), "☐")
        XCTAssertEqual((text as NSString).substring(with: items[0].body), "👨‍👩‍👧‍👦 offen")
        XCTAssertEqual((text as NSString).substring(with: items[1].body), "fertig")
        XCTAssertTrue(TextListEditing.taskItems(in: "").isEmpty)
        XCTAssertEqual(TextListEditing.taskItems(in: "☑ ").first?.body.length, 0)
    }
    func testHoldAcceptsWavyLinesAndTwoSamplesButRejectsLoopsAndScribbles() {
        XCTAssertTrue(ShapeRecognition.lineAfterHold([.init(x: -50, y: 10), .init(x: 100, y: 10)]))
        XCTAssertTrue(ShapeRecognition.lineAfterHold((0...20).map { .init(x: Double($0) * 5, y: sin(Double($0)) * 7) }))
        XCTAssertFalse(ShapeRecognition.lineAfterHold([.init(x: 0, y: 0), .init(x: 10, y: 0)]))
        XCTAssertFalse(ShapeRecognition.lineAfterHold([.init(x: 0, y: 0), .init(x: 100, y: 100), .init(x: 0, y: 100), .init(x: 1, y: 1)]))
        XCTAssertFalse(ShapeRecognition.lineAfterHold([.init(x: 0, y: 0), .init(x: 40, y: 100), .init(x: 100, y: 0)]))
    }
    func testScrollingReusesViewportAndRebuildsOnlyWhenReserveRunsOutOrScaleChanges() {
        let size = PageSize(width: 14400, height: 14400)
        let visible = PageRect(x: 1000, y: 1000, width: 900, height: 900)
        let plan = InkRenderViewport(page: size, visible: visible, scale: 1)
        for delta in [0.0, 1, 10, 60, 100] {
            XCTAssertTrue(plan.covers(.init(x: 1000, y: 1000 + delta, width: 900, height: 900), page: size, scale: 1))
        }
        XCTAssertFalse(plan.covers(.init(x: 1000, y: 1500, width: 900, height: 900), page: size, scale: 1))
        XCTAssertFalse(plan.covers(visible, page: size, scale: 2))
        let edge = InkRenderViewport(page: .a4, visible: .init(x: -50, y: -50, width: 900, height: 1000), scale: 1)
        XCTAssertTrue(edge.covers(.init(x: -100, y: -100, width: 900, height: 1000), page: .a4, scale: 1))
    }
}
