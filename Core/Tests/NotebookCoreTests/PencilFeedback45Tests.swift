import Foundation
import XCTest
@testable import NotebookCore

/// Rückmeldung zu Build 44: Bleistift folgt dem Autostift, Laserpointer und
/// „PDF lesen“ auf der zweiten Leistenebene, häufige Lasso-Haptik, Formen beim
/// Halten skalieren, Squeeze-Palette schneller und mit festem Ende.
final class PencilFeedback45Tests: XCTestCase {

    // MARK: Autostift

    func testPencilFollowsThePenAutostiftUnlessSetApart() throws {
        var value = ToolbarPreferences()
        XCTAssertFalse(value.automaticInk(for: .pencil))
        value.autoPen = true
        XCTAssertTrue(value.automaticInk(for: .pencil), "pencil follows the pen's Autostift")
        XCTAssertTrue(value.automaticInk(for: .shape))
        // Picking a pencil colour sets it apart.
        value.setInkColor(InkColor(0.2, 0.2, 0.2), for: .pencil)
        XCTAssertFalse(value.automaticInk(for: .pencil)); XCTAssertTrue(value.automaticInk(for: .pen))
        // Toggling the pen's Autostift links the pencil again (on and off).
        value.setAutomaticInk(true, for: .pen)
        XCTAssertNil(value.autoPencil); XCTAssertTrue(value.automaticInk(for: .pencil))
        value.setAutomaticInk(false, for: .pen)
        XCTAssertFalse(value.automaticInk(for: .pencil))
        // The pencil's own toggle stays separate only while it differs.
        value.setAutomaticInk(true, for: .pencil)
        XCTAssertEqual(value.autoPencil, true); XCTAssertFalse(value.automaticInk(for: .pen))
        value.setAutomaticInk(false, for: .pencil)
        XCTAssertNil(value.autoPencil)
        // Picking a pen colour leaves the pencil's automatic ink as it was.
        var linked = ToolbarPreferences(); linked.autoPen = true
        linked.setInkColor(InkColor(0, 0, 1), for: .pen)
        XCTAssertFalse(linked.automaticInk(for: .pen)); XCTAssertTrue(linked.automaticInk(for: .pencil))
        // Build-44 files with an explicit pencil setting keep it.
        var stored = ToolbarPreferences(); stored.autoPen = true; stored.autoPencil = false
        let decoded = try ToolbarPreferences.decode(JSONEncoder().encode(stored))
        XCTAssertFalse(decoded.automaticInk(for: .pencil)); XCTAssertTrue(decoded.automaticInk(for: .pen))
        XCTAssertEqual(decoded, stored)
    }

    // MARK: Leistenebenen

    func testLaserAndReadMoveToTheSecondLevelWithoutChangingTheStoredOrder() throws {
        let value = ToolbarPreferences()
        XCTAssertEqual(value.primaryTools, [.pen, .pencil, .marker, .strokeEraser, .text, .inkSelection, .shape, .image])
        XCTAssertEqual(value.secondaryTools, [.read, .laser])
        XCTAssertEqual(value.mainTools, value.primaryTools + value.secondaryTools)
        // A customised format-7 order keeps its relative order on both levels.
        let format7 = Data("""
        {"formatVersion":7,"dock":"left","order":["marker","pen","strokeEraser","text","read","selection","shape","image","precisionEraser","inkSelection"],
         "penColor":{"red":0,"green":0,"blue":1,"alpha":1},"markerColor":{"red":1,"green":1,"blue":0,"alpha":1},
         "penWidth":3,"markerWidth":14,"eraserWidth":16,"fingerDrawing":true,"floatingX":0,"floatingY":0,"presets":[]}
        """.utf8)
        let migrated = try ToolbarPreferences.decode(format7)
        XCTAssertEqual(migrated.primaryTools, [.marker, .pen, .pencil, .strokeEraser, .text, .inkSelection, .shape, .image])
        XCTAssertEqual(migrated.secondaryTools, [.read, .laser])
        XCTAssertEqual(migrated.formatVersion, ToolbarPreferences.currentFormat)
    }

    func testReorderingOneLevelLeavesTheOtherAndHiddenSlotsAlone() throws {
        var value = ToolbarPreferences()
        let before = value.order
        value.reorderTools([.marker, .pen, .pencil, .strokeEraser, .text, .shape, .inkSelection, .image])
        XCTAssertEqual(value.primaryTools, [.marker, .pen, .pencil, .strokeEraser, .text, .shape, .inkSelection, .image])
        XCTAssertEqual(value.secondaryTools, [.read, .laser])
        XCTAssertEqual(value.order.firstIndex(of: .precisionEraser), before.firstIndex(of: .precisionEraser))
        XCTAssertEqual(value.order.firstIndex(of: .inkSelection), before.firstIndex(of: .inkSelection))
        XCTAssertTrue(value.order.contains(.selection))
        value.reorderTools([.laser, .read])
        XCTAssertEqual(value.secondaryTools, [.laser, .read])
        XCTAssertEqual(value.primaryTools, [.marker, .pen, .pencil, .strokeEraser, .text, .shape, .inkSelection, .image])
        XCTAssertNoThrow(try value.validate())
        // Invalid requests change nothing.
        let valid = value.order
        value.reorderTools([.laser, .laser]); value.reorderTools([.laser, .precisionEraser])
        XCTAssertEqual(value.order, valid)
    }

    func testToolbarLengthCountsBothLevels() {
        var value = ToolbarPreferences(); value.presets = [InkPreset(tool: .pen, color: InkColor(0, 0, 0), width: 2)]
        // 8 tools + 1 preset + arrow; second level: 5 utilities + 2 tools + arrow.
        XCTAssertEqual(ToolbarLayout.itemCount(more: false, preferences: value, secondView: true), 10)
        XCTAssertEqual(ToolbarLayout.itemCount(more: true, preferences: value, secondView: true), 8)
        XCTAssertEqual(ToolbarLayout.itemCount(more: true, preferences: value, secondView: false), 7)
    }

    // MARK: Haptik

    func testMotionTicksAreFrequentButThrottled() {
        var ticks = MotionTicks(spacing: 44, minimumInterval: 0.08)
        ticks.begin(at: .init(x: 0, y: 0), time: 0)
        var count = 0
        // Slow, steady drag: 500 pt over 2 s → one tick per 45 pt (18 steps of 2.5 pt).
        for step in 1...200 { if ticks.move(to: .init(x: Double(step) * 2.5, y: 0), at: Double(step) * 0.01) { count += 1 } }
        XCTAssertEqual(count, 11)
        // Very fast flick: 1000 pt in 0.1 s ticks at most twice, no backlog afterwards.
        count = 0
        ticks.begin(at: .init(x: 0, y: 0), time: 10)
        for step in 1...10 { if ticks.move(to: .init(x: Double(step) * 100, y: 0), at: 10 + Double(step) * 0.01) { count += 1 } }
        XCTAssertLessThanOrEqual(count, 2)
        _ = ticks.move(to: .init(x: 1001, y: 0), at: 11)
        XCTAssertFalse(ticks.move(to: .init(x: 1002, y: 0), at: 11.2), "no backlog of owed ticks")
        XCTAssertFalse(ticks.move(to: .init(x: .nan, y: 0), at: 11.1))
    }

    // MARK: Formen beim Halten skalieren

    func testHeldCircleScalesAboutItsCentreAndStaysACircle() {
        let circle = RecognizedShape.ellipse(center: .init(x: 200, y: 200), radiusX: 50, radiusY: 50, degrees: 0)
        let adjustment = HeldShapeAdjustment(shape: circle, grab: .init(x: 250, y: 200))
        XCTAssertEqual(adjustment.anchor, .init(x: 200, y: 200))
        XCTAssertEqual(adjustment.shape(at: .init(x: 251, y: 200)), circle, "resting tip keeps the shape")
        XCTAssertEqual(adjustment.shape(at: .init(x: 300, y: 200)), .ellipse(center: .init(x: 200, y: 200), radiusX: 100, radiusY: 100, degrees: 0))
        guard case let .ellipse(_, rx, ry, _) = adjustment.shape(at: .init(x: 200, y: 225)) else { return XCTFail() }
        XCTAssertEqual(rx, 25, accuracy: 1e-9); XCTAssertEqual(ry, 25, accuracy: 1e-9)
        // Never collapses: the tip on the centre keeps a minimum size.
        guard case let .ellipse(_, small, _, _) = adjustment.shape(at: .init(x: 200, y: 200)) else { return XCTFail() }
        XCTAssertEqual(small * 2, HeldShapeAdjustment.minimumExtent, accuracy: 1e-9)
        XCTAssertEqual(adjustment.shape(at: .init(x: 200, y: 200)).object(color: InkColor(0, 0, 0), lineWidth: 2)?.kind, .ellipse)
    }

    func testHeldRectangleStaysAnEditableRectangleWhileScaling() throws {
        let square = RecognizedShape.polygon(.square, [.init(x: 100, y: 100), .init(x: 200, y: 100), .init(x: 200, y: 200), .init(x: 100, y: 200)])
        let adjustment = HeldShapeAdjustment(shape: square, grab: .init(x: 200, y: 200))
        XCTAssertEqual(adjustment.anchor, .init(x: 150, y: 150))
        let bigger = adjustment.shape(at: .init(x: 250, y: 250))
        let object = try XCTUnwrap(bigger.object(color: InkColor(0, 0, 0), lineWidth: 2))
        XCTAssertEqual(object.kind, .rectangle)
        XCTAssertEqual(object.start.x, 50, accuracy: 1e-9); XCTAssertEqual(object.end.x, 250, accuracy: 1e-9)
        XCTAssertEqual(object.start.y, 50, accuracy: 1e-9); XCTAssertEqual(object.end.y, 250, accuracy: 1e-9)
        guard case let .polygon(kind, _) = bigger else { return XCTFail() }
        XCTAssertEqual(kind, .square)
    }

    func testHeldLineEndFollowsTheTipAndArrowScalesFromItsStart() {
        let line = RecognizedShape.line(start: .init(x: 0, y: 0), end: .init(x: 100, y: 0))
        let held = HeldShapeAdjustment(shape: line, grab: .init(x: 100, y: 0))
        XCTAssertEqual(held.shape(at: .init(x: 160, y: 3)), .line(start: .init(x: 0, y: 0), end: LineSnapping.end(from: .init(x: 0, y: 0), to: .init(x: 160, y: 3))))
        let arrow = RecognizedShape.arrow(start: .init(x: 0, y: 0), tip: .init(x: 100, y: 0))
        let scaled = HeldShapeAdjustment(shape: arrow, grab: .init(x: 90, y: 10)).shape(at: .init(x: 45, y: 5))
        guard case let .arrow(start, tip) = scaled else { return XCTFail() }
        XCTAssertEqual(start, .init(x: 0, y: 0)); XCTAssertEqual(tip.x, 50, accuracy: 1e-9); XCTAssertEqual(tip.y, 0, accuracy: 1e-9)
        // Invalid input keeps the recognised shape.
        XCTAssertEqual(HeldShapeAdjustment(shape: arrow, grab: .init(x: 90, y: 10)).shape(at: .init(x: .infinity, y: 0)), arrow)
    }

    // MARK: Squeeze-Palette

    func testSingleSqueezeOpensAfterAShortDelayAndALateSecondSqueezeStillToggles() {
        XCTAssertLessThanOrEqual(PencilSqueezeTracker.showDelay, 0.2)
        XCTAssertGreaterThan(PencilSqueezeTracker.doubleInterval, PencilSqueezeTracker.showDelay)
        var tracker = PencilSqueezeTracker()
        XCTAssertEqual(tracker.handle(.began, at: 10, showing: false), PencilSqueezeTracker.Outcome.none)
        XCTAssertEqual(tracker.handle(.ended, at: 10.1, showing: false), .schedule(1))
        XCTAssertTrue(tracker.fire(1))
        // Second press 0.25 s after the release: the palette had appeared; it closes at once, the release toggles.
        XCTAssertEqual(tracker.handle(.began, at: 10.35, showing: true), .dismiss)
        XCTAssertEqual(tracker.handle(.ended, at: 10.45, showing: false), .toggle)
        // Discrete events without began behave the same.
        XCTAssertEqual(tracker.handle(.ended, at: 20, showing: false), .schedule(2))
        XCTAssertTrue(tracker.fire(2))
        XCTAssertEqual(tracker.handle(.ended, at: 20.3, showing: true), .toggle)
        // Later squeezes while open only close it.
        XCTAssertEqual(tracker.handle(.ended, at: 30, showing: false), .schedule(3))
        XCTAssertTrue(tracker.fire(3))
        XCTAssertEqual(tracker.handle(.began, at: 31, showing: true), PencilSqueezeTracker.Outcome.none)
        XCTAssertEqual(tracker.handle(.ended, at: 31.1, showing: true), .dismiss)
        // A triple squeeze does not re-open: third press is a new single squeeze after the toggle.
        XCTAssertEqual(tracker.handle(.ended, at: 40, showing: false), .schedule(4))
        XCTAssertEqual(tracker.handle(.ended, at: 40.1, showing: false), .toggle)
        XCTAssertFalse(tracker.fire(4))
    }

    func testPaletteScrollHasAFirmEndAndNeverWraps() {
        let layout = PencilPaletteLayout(anchor: .init(x: 600, y: 500), bounds: PageRect(x: 0, y: 0, width: 1194, height: 834), itemCount: 14)
        XCTAssertEqual(layout.maximumScroll, 9)
        // Circle the tip twice around the arc in small steps: the scroll stops at an end and stays there.
        var scroll = 0.0, angle = layout.firstAngle
        func point(_ a: Double) -> PagePoint { .init(x: layout.center.x + layout.radius * cos(a), y: layout.center.y + layout.radius * sin(a)) }
        var values: [Double] = []
        for _ in 0..<400 {
            let next = angle - 0.05
            scroll = layout.scrolled(scroll, from: point(angle), to: point(next)); angle = next
            values.append(scroll)
        }
        XCTAssertEqual(scroll, layout.maximumScroll)
        XCTAssertTrue(values.allSatisfy { (0...layout.maximumScroll).contains($0) })
        XCTAssertEqual(zip(values, values.dropFirst()).filter { $1 < $0 }.count, 0, "monotonic: no jump back to the start")
        for _ in 0..<400 { let next = angle + 0.05; scroll = layout.scrolled(scroll, from: point(angle), to: point(next)); angle = next }
        XCTAssertEqual(scroll, 0)
        // Movement through the centre is ignored.
        XCTAssertEqual(layout.scrolled(3, from: layout.center, to: point(layout.firstAngle)), 3)
    }
}
