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

    // MARK: Schnellmenü 20.10.2026: feste Reihenfolge, nur Tippen wählt, 10 s Gedächtnis

    private func paletteLayout(_ content: PencilPaletteContent, anchor: PagePoint = .init(x: 600, y: 500), leftHanded: Bool = false) -> PencilPaletteLayout {
        PencilPaletteLayout(anchor: anchor, bounds: screen, itemCount: content.items.count,
                            visibleSlots: PencilPaletteContent.visibleSlots, leftHanded: leftHanded)
    }

    func testStandardOrderShowsUndoAndTheMainToolsWithRedoHiddenBeforeUndo() {
        let standard: [PencilPaletteItem] = [.undo, .tool(.pen), .tool(.pencil), .tool(.marker), .tool(.strokeEraser), .tool(.text)]
        let defaults = PencilPaletteContent(preferences: ToolbarPreferences())
        XCTAssertEqual(PencilPaletteContent.visibleSlots, 6)
        XCTAssertEqual(PencilPaletteMemory.standardScroll, 1)
        XCTAssertEqual(defaults.items, [.redo] + standard + [.tool(.inkSelection), .tool(.shape), .tool(.image), .tool(.read), .tool(.laser),
                                                             .color, .width, .autoPen])
        XCTAssertEqual(defaults.dividers, [1.5, 6.5, 11.5])
        XCTAssertEqual(defaults.maximumScroll, 9)
        XCTAssertEqual(Set(defaults.items).count, defaults.items.count, "every item once")
        XCTAssertFalse(defaults.items.contains(.tool(.precisionEraser)))

        // A reordered toolbar changes only the scrolled-in tools, never the standard slots.
        var preferences = ToolbarPreferences()
        preferences.reorderTools([.image, .text, .shape, .marker, .inkSelection, .strokeEraser, .pencil, .pen])
        let reordered = PencilPaletteContent(preferences: preferences)
        XCTAssertEqual(Array(reordered.items.prefix(7)), [.redo] + standard)
        XCTAssertEqual(Array(reordered.items[7..<10]), [.tool(.image), .tool(.shape), .tool(.inkSelection)])
        XCTAssertEqual(reordered.items.last, .autoPen)
        // Legacy lasso ID and precision eraser map onto the visible entries.
        XCTAssertEqual(PencilPaletteContent(tools: [.precisionEraser, .selection, .inkSelection, .pen]).items,
                       [.redo] + standard + [.tool(.inkSelection), .color, .width, .autoPen])

        // Standard position: exactly undo and the main group are visible and tappable, redo is not.
        let layout = paletteLayout(defaults)
        let shown = defaults.items.indices.filter { layout.isInteractive(item: $0, scroll: PencilPaletteMemory.standardScroll) }
        XCTAssertEqual(shown.map { defaults.items[$0] }, standard)
        XCTAssertEqual(layout.maximumScroll, defaults.maximumScroll)
        // One slot back: redo appears before undo, text leaves.
        let back = defaults.items.indices.filter { layout.isInteractive(item: $0, scroll: 0) }
        XCTAssertEqual(back.map { defaults.items[$0] }, [.redo] + standard.dropLast())
        // Scrolled to the far end: colour, width and Autostift.
        let end = defaults.items.indices.filter { layout.isInteractive(item: $0, scroll: layout.maximumScroll) }
        XCTAssertEqual(Array(end.map { defaults.items[$0] }.suffix(3)), [.color, .width, .autoPen])
    }

    func testSixSlotArcStaysBesideTheTipAwayFromTheHand() {
        let content = PencilPaletteContent(preferences: ToolbarPreferences())
        let tip = PagePoint(x: 600, y: 500)
        for leftHanded in [false, true] {
            let layout = paletteLayout(content, anchor: tip, leftHanded: leftHanded)
            XCTAssertEqual(layout.visibleSlots, 6)
            XCTAssertLessThanOrEqual(layout.radius, 150)
            let points = visible(layout)
            XCTAssertTrue(points.allSatisfy { $0.y <= tip.y + 0.001 && (leftHanded ? $0.x >= tip.x - 0.001 : $0.x <= tip.x + 0.001) },
                          "nothing over the writing hand")
            for (a, b) in zip(points, points.dropFirst()) { XCTAssertGreaterThanOrEqual(hypot(a.x - b.x, a.y - b.y), 44) }
            assertInside(layout, screen)
        }
        for anchor in [PagePoint(x: 20, y: 20), PagePoint(x: 1180, y: 820), PagePoint(x: 20, y: 820), PagePoint(x: 1180, y: 20)] {
            assertInside(paletteLayout(content, anchor: anchor), screen)
        }
    }

    func testHitTestingFollowsTheScrollAndSkipsFadedItems() {
        let content = PencilPaletteContent(preferences: ToolbarPreferences())
        let layout = paletteLayout(content)
        XCTAssertEqual(layout.item(at: layout.point(item: 3, scroll: 0), scroll: 0), 3)
        // Slightly off-centre still hits; the item's own slot wins over its neighbour.
        let a = layout.point(item: 2, scroll: 0), b = layout.point(item: 3, scroll: 0)
        XCTAssertEqual(layout.item(at: .init(x: a.x + (b.x - a.x) * 0.4, y: a.y + (b.y - a.y) * 0.4), scroll: 0), 2)
        // After scrolling by two, the first slot shows item 2.
        XCTAssertEqual(layout.item(at: layout.point(item: 0, scroll: 0), scroll: 2), 2)
        // Faded items beyond the visible slots and points off the band take no touches.
        XCTAssertNil(layout.item(at: layout.point(item: 6, scroll: 0), scroll: 0))
        XCTAssertNil(layout.item(at: layout.center, scroll: 0))
        XCTAssertNil(layout.item(at: layout.point(item: 3, scroll: 0, radius: layout.radius + 40), scroll: 0))
        XCTAssertNil(layout.item(at: .init(x: .nan, y: 0), scroll: 0))
    }

    /// Simulates a drag along the arc in small steps, as the view's gesture does.
    private func drag(_ layout: PencilPaletteLayout, scroll: inout Double, from startSlot: Double, to endSlot: Double,
                      steps: Int = 30) -> Int? {
        let start = layout.point(item: startSlot, scroll: 0)
        var touch = PencilPaletteTouch(at: start, item: layout.item(at: start, scroll: scroll))
        for step in 1...steps {
            let slot = startSlot + (endSlot - startSlot) * Double(step) / Double(steps)
            scroll = touch.move(to: layout.point(item: slot, scroll: 0), scroll: scroll, in: layout)
        }
        let selected = touch.end(at: layout.point(item: endSlot, scroll: 0))
        scroll = layout.clampedScroll(scroll.rounded())
        return selected
    }

    func testScrollingNeverSelectsEvenWhenTheItemFollowsTheTouch() {
        let content = PencilPaletteContent(preferences: ToolbarPreferences())
        let layout = paletteLayout(content)
        var scroll = 0.0

        // First scroll: from the eraser slot two slots back; the items follow the touch.
        XCTAssertNil(drag(layout, scroll: &scroll, from: 4, to: 2))
        XCTAssertEqual(scroll, 2)
        // The lift lands on the very item the scroll started on (the Build 49 bug selected it).
        XCTAssertEqual(layout.item(at: layout.point(item: 2, scroll: 0), scroll: scroll), 4)
        // Second and further scrolls, both directions, short and long: never a selection.
        XCTAssertNil(drag(layout, scroll: &scroll, from: 3, to: 4))
        XCTAssertEqual(scroll, 1)
        XCTAssertNil(drag(layout, scroll: &scroll, from: 5, to: -5, steps: 60))
        XCTAssertEqual(scroll, layout.maximumScroll, "hard stop at the end")
        XCTAssertNil(drag(layout, scroll: &scroll, from: 1, to: 2))
        XCTAssertEqual(scroll, layout.maximumScroll - 1)
        // Out and back to the touch-down point is still a scroll.
        let start = layout.point(item: 2, scroll: 0)
        var back = PencilPaletteTouch(at: start, item: layout.item(at: start, scroll: scroll))
        XCTAssertEqual(back.pressedItem, back.item)
        let away = layout.point(item: 1.5, scroll: 0)
        _ = back.move(to: away, scroll: scroll, in: layout)
        XCTAssertTrue(back.isScrolling); XCTAssertNil(back.pressedItem)
        _ = back.move(to: start, scroll: scroll, in: layout)
        XCTAssertNil(back.end(at: start))
        // A drag where everything fits does not scroll and still selects nothing.
        let few = PencilPaletteLayout(anchor: .init(x: 600, y: 500), bounds: screen, itemCount: 4, visibleSlots: 6)
        var none = 0.0
        XCTAssertNil(drag(few, scroll: &none, from: 3, to: 1)); XCTAssertEqual(none, 0)
    }

    func testTapSelectsTheItemUnderTheTouch() {
        let content = PencilPaletteContent(preferences: ToolbarPreferences())
        let layout = paletteLayout(content)
        let scroll = 3.0
        let point = layout.point(item: 5, scroll: 0)
        var tap = PencilPaletteTouch(at: point, item: layout.item(at: point, scroll: scroll))
        XCTAssertEqual(tap.item, 8)
        // A slightly sliding Pencil tap (< 12 pt) stays a tap and does not scroll.
        let slid = PagePoint(x: point.x + 7, y: point.y - 5)
        XCTAssertEqual(tap.move(to: slid, scroll: scroll, in: layout), scroll)
        XCTAssertFalse(tap.isScrolling)
        XCTAssertEqual(tap.end(at: slid), 8)
        XCTAssertEqual(content.items[8], .tool(.shape))
        // A touch inside the arc, off the band, selects nothing.
        let off = layout.point(item: 2, scroll: 0, radius: layout.radius - 45)
        XCTAssertNil(PencilPaletteTouch(at: off, item: layout.item(at: off, scroll: scroll)).end(at: off))
    }

    func testReopensWithinTenSecondsWhereItClosedOtherwiseAtTheStandardPosition() {
        var memory = PencilPaletteMemory()
        XCTAssertEqual(PencilPaletteMemory.retention, 10)
        XCTAssertEqual(memory.openingScroll(at: 50), PencilPaletteMemory.standardScroll)
        memory.close(scroll: 4, at: 100)
        XCTAssertEqual(memory.openingScroll(at: 100), 4)
        XCTAssertEqual(memory.openingScroll(at: 105), 4)
        XCTAssertEqual(memory.openingScroll(at: 109.9), 4)
        XCTAssertEqual(memory.openingScroll(at: 110), PencilPaletteMemory.standardScroll)
        XCTAssertEqual(memory.openingScroll(at: 400), PencilPaletteMemory.standardScroll)
        XCTAssertEqual(memory.openingScroll(at: 99), PencilPaletteMemory.standardScroll, "clock went backwards")
        // Each close restarts the 10 s; a close at the standard position remembers that.
        memory.close(scroll: 7, at: 108)
        XCTAssertEqual(memory.openingScroll(at: 117.9), 7)
        memory.close(scroll: 0, at: 118)
        XCTAssertEqual(memory.openingScroll(at: 119), 0)
        // Closed mid-scroll: the nearest whole slot; invalid values fall back to the standard position.
        memory.close(scroll: 2.6, at: 200)
        XCTAssertEqual(memory.openingScroll(at: 201), 3)
        memory.close(scroll: -2, at: 300)
        XCTAssertEqual(memory.openingScroll(at: 301), 0)
        memory.close(scroll: .nan, at: 400)
        XCTAssertEqual(memory.openingScroll(at: 401), PencilPaletteMemory.standardScroll)
        memory.close(scroll: 5, at: 500)
        XCTAssertEqual(memory.openingScroll(at: .nan), PencilPaletteMemory.standardScroll)
        // The remembered offset is clamped by the layout when the item count shrank meanwhile.
        let layout = paletteLayout(PencilPaletteContent(tools: [.pen]))
        XCTAssertEqual(layout.clampedScroll(memory.openingScroll(at: 501)), layout.maximumScroll)
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
