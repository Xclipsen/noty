import Foundation
import XCTest
@testable import NotebookCore

final class PencilPaletteTests: XCTestCase {
    private let screen = PageRect(x: 0, y: 0, width: 1194, height: 834)
    private let count = 11

    private func visible(_ layout: PencilPaletteLayout) -> [PagePoint] {
        (0..<layout.visibleSlots).map { layout.point(item: Double($0), scroll: 0) }
    }
    private func assertInside(_ layout: PencilPaletteLayout, _ bounds: PageRect, file: StaticString = #filePath, line: UInt = #line) {
        for point in visible(layout) {
            XCTAssertGreaterThanOrEqual(point.x - 20, bounds.x - 0.001, file: file, line: line)
            XCTAssertGreaterThanOrEqual(point.y - 20, bounds.y - 0.001, file: file, line: line)
            XCTAssertLessThanOrEqual(point.x + 20, bounds.x + bounds.width + 0.001, file: file, line: line)
            XCTAssertLessThanOrEqual(point.y + 20, bounds.y + bounds.height + 0.001, file: file, line: line)
        }
    }

    func testCompactArcUpperLeftOfTipForRightHandedWriters() {
        let tip = PagePoint(x: 600, y: 500)
        let layout = PencilPaletteLayout(anchor: tip, bounds: screen, itemCount: count)
        XCTAssertEqual(layout.visibleSlots, 5)
        XCTAssertEqual(layout.maximumScroll, 6)
        XCTAssertEqual(layout.direction, -.pi * 3 / 4, accuracy: 0.0001)
        XCTAssertEqual(layout.center, tip)
        XCTAssertLessThanOrEqual(layout.radius, 120)
        let points = visible(layout)
        XCTAssertTrue(points.allSatisfy { $0.x <= tip.x + 0.001 && $0.y <= tip.y + 0.001 }, "nothing over the writing hand")
        for (a, b) in zip(points, points.dropFirst()) { XCTAssertGreaterThanOrEqual(hypot(a.x - b.x, a.y - b.y), 40) }
        assertInside(layout, screen)

        let left = PencilPaletteLayout(anchor: tip, bounds: screen, itemCount: count, leftHanded: true)
        XCTAssertEqual(left.direction, -.pi / 4, accuracy: 0.0001)
        XCTAssertTrue(visible(left).allSatisfy { $0.x >= tip.x - 0.001 && $0.y <= tip.y + 0.001 })
    }

    func testTurnsAwayFromEdgesInsteadOfLeavingTheScreen() {
        for anchor in [PagePoint(x: 600, y: 30), PagePoint(x: 30, y: 400), PagePoint(x: 1170, y: 400), PagePoint(x: 600, y: 820)] {
            for leftHanded in [false, true] {
                let layout = PencilPaletteLayout(anchor: anchor, bounds: screen, itemCount: count, leftHanded: leftHanded)
                assertInside(layout, screen)
                XCTAssertEqual(layout.center, anchor, "rotation alone fits at \(anchor)")
            }
        }
        // Corners: rotate away and shift only slightly.
        for anchor in [PagePoint(x: 20, y: 20), PagePoint(x: 1180, y: 820), PagePoint(x: 20, y: 820), PagePoint(x: 1180, y: 20)] {
            let layout = PencilPaletteLayout(anchor: anchor, bounds: screen, itemCount: count)
            assertInside(layout, screen)
            XCTAssertLessThan(hypot(layout.center.x - anchor.x, layout.center.y - anchor.y), 40)
        }
        XCTAssertGreaterThan(PencilPaletteLayout(anchor: .init(x: 600, y: 30), bounds: screen, itemCount: count).point(item: 0, scroll: 0).y, 30)
    }

    func testShiftsInsideSmallBounds() {
        let small = PageRect(x: 100, y: 50, width: 300, height: 250)
        let layout = PencilPaletteLayout(anchor: .init(x: 105, y: 55), bounds: small, itemCount: count)
        assertInside(layout, small)
        XCTAssertNotEqual(layout.center, .init(x: 105, y: 55))
    }

    func testScrollsAlongTheArc() {
        let layout = PencilPaletteLayout(anchor: .init(x: 600, y: 500), bounds: screen, itemCount: count)
        XCTAssertEqual(layout.visibility(item: 0, scroll: 0), 1)
        XCTAssertEqual(layout.visibility(item: 4, scroll: 0), 1)
        XCTAssertEqual(layout.visibility(item: 5, scroll: 0), 0)
        XCTAssertEqual(layout.visibility(item: 5, scroll: 0.75), 0.5, accuracy: 0.0001)
        XCTAssertEqual(layout.visibility(item: 10, scroll: 6), 1)
        // Item 3 at scroll 1 sits where item 2 was at scroll 0.
        let a = layout.point(item: 2, scroll: 0), b = layout.point(item: 3, scroll: 1)
        XCTAssertEqual(a.x, b.x, accuracy: 0.0001); XCTAssertEqual(a.y, b.y, accuracy: 0.0001)
        // Dragging from slot 3 to slot 2 brings the next items in by one.
        let delta = layout.scrollDelta(from: layout.point(item: 3, scroll: 0), to: layout.point(item: 2, scroll: 0))
        XCTAssertEqual(delta, 1, accuracy: 0.0001)
        XCTAssertEqual(layout.clampedScroll(-2), 0); XCTAssertEqual(layout.clampedScroll(9), 6)
        XCTAssertEqual(layout.scroll(centering: 2), 0)
        XCTAssertEqual(layout.scroll(centering: 7), 5)
        XCTAssertEqual(layout.scroll(centering: 10), 6)
        let few = PencilPaletteLayout(anchor: .init(x: 600, y: 500), bounds: screen, itemCount: 4)
        XCTAssertEqual(few.visibleSlots, 4); XCTAssertEqual(few.maximumScroll, 0)
    }

    func testSingleSqueezeShowsOnlyAfterTheDoubleWindow() {
        var tracker = PencilSqueezeTracker()
        XCTAssertEqual(tracker.handle(.began, at: 10, showing: false), PencilSqueezeTracker.Outcome.none)
        XCTAssertEqual(tracker.handle(.ended, at: 10.1, showing: false), .schedule(1))
        XCTAssertTrue(tracker.fire(1))
        XCTAssertFalse(tracker.fire(1))
        // While open, a squeeze closes it.
        XCTAssertEqual(tracker.handle(.began, at: 12, showing: true), PencilSqueezeTracker.Outcome.none)
        XCTAssertEqual(tracker.handle(.ended, at: 12.1, showing: true), .dismiss)
    }

    func testDoubleSqueezeTogglesWithoutEverShowingThePalette() {
        var tracker = PencilSqueezeTracker()
        XCTAssertEqual(tracker.handle(.ended, at: 10, showing: false), .schedule(1))
        XCTAssertEqual(tracker.handle(.began, at: 10.2, showing: false), PencilSqueezeTracker.Outcome.none)
        XCTAssertFalse(tracker.fire(1), "pending show cancelled by the second squeeze")
        XCTAssertEqual(tracker.handle(.ended, at: 10.35, showing: false), .toggle)
        XCTAssertFalse(tracker.fire(1))
        // Discrete ends without began.
        XCTAssertEqual(tracker.handle(.ended, at: 20, showing: false), .schedule(2))
        XCTAssertEqual(tracker.handle(.ended, at: 20.25, showing: false), .toggle)
        XCTAssertFalse(tracker.fire(2))
        // A slow second squeeze is a new single squeeze.
        XCTAssertEqual(tracker.handle(.ended, at: 30, showing: false), .schedule(3))
        XCTAssertEqual(tracker.handle(.began, at: 30.5, showing: false), PencilSqueezeTracker.Outcome.none)
        XCTAssertEqual(tracker.handle(.ended, at: 30.6, showing: false), .schedule(4))
        XCTAssertFalse(tracker.fire(3)); XCTAssertTrue(tracker.fire(4))
    }

    func testSystemSqueezePreferenceIsHonoured() {
        var tracker = PencilSqueezeTracker()
        XCTAssertEqual(tracker.handle(.ended, at: 1, showing: false, preference: .ignore), PencilSqueezeTracker.Outcome.none)
        XCTAssertEqual(tracker.handle(.began, at: 2, showing: false, preference: .toggle), PencilSqueezeTracker.Outcome.none)
        XCTAssertEqual(tracker.handle(.ended, at: 2.1, showing: false, preference: .toggle), .toggle)
    }
}
