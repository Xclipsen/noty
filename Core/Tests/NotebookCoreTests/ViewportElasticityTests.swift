import XCTest
@testable import NotebookCore

final class ViewportElasticityTests: XCTestCase {
    func testRubberBandResistsAndNeverReachesDimension() {
        XCTAssertEqual(NotebookViewportGeometry.rubberBand(0, dimension: 800), 0)
        let small = NotebookViewportGeometry.rubberBand(40, dimension: 800)
        XCTAssertGreaterThan(small, 0); XCTAssertLessThan(small, 40)
        XCTAssertEqual(NotebookViewportGeometry.rubberBand(-40, dimension: 800), -small, accuracy: 1e-9)
        let huge = NotebookViewportGeometry.rubberBand(100_000, dimension: 800)
        XCTAssertLessThan(huge, 800)
        // Monotonic: pulling further always shows a little more.
        XCTAssertGreaterThan(NotebookViewportGeometry.rubberBand(400, dimension: 800), NotebookViewportGeometry.rubberBand(200, dimension: 800))
        XCTAssertEqual(NotebookViewportGeometry.rubberBand(.nan, dimension: 800), 0)
        XCTAssertEqual(NotebookViewportGeometry.rubberBand(20, dimension: 0), 0)
    }

    func testRubberBandExcessInvertsDisplayedOvershoot() {
        for excess in [-600.0, -35, 3, 120, 900] {
            let shown = NotebookViewportGeometry.rubberBand(excess, dimension: 1024)
            XCTAssertEqual(NotebookViewportGeometry.rubberBandExcess(displayed: shown, dimension: 1024), excess, accuracy: 1e-6)
        }
        XCTAssertEqual(NotebookViewportGeometry.rubberBandExcess(displayed: 0, dimension: 1024), 0)
    }

    func testFittingPageOnlyMovesByFingerAndKeepsCentreAsBase() {
        // Page fits: the allowed range is the single centred offset.
        let range = 100.0...100.0
        var state = (base: 100.0, excess: 0.0)
        state = NotebookViewportGeometry.elasticDragStep(base: state.base, excess: state.excess, delta: -60, range: range)
        XCTAssertEqual(state.base, 100); XCTAssertEqual(state.excess, -60)
        state = NotebookViewportGeometry.elasticDragStep(base: state.base, excess: state.excess, delta: 20, range: range)
        XCTAssertEqual(state.excess, -40)
        // Back to the centre and beyond on the other side.
        state = NotebookViewportGeometry.elasticDragStep(base: state.base, excess: state.excess, delta: 70, range: range)
        XCTAssertEqual(state.base, 100); XCTAssertEqual(state.excess, 30)
    }

    func testWideZoomScrollsNormallyInsideAndElasticOnlyBeyondEdge() {
        let range = 0.0...500.0
        var state = NotebookViewportGeometry.elasticDragStep(base: 250, excess: 0, delta: 200, range: range)
        XCTAssertEqual(state.base, 450); XCTAssertEqual(state.excess, 0)
        state = NotebookViewportGeometry.elasticDragStep(base: state.base, excess: state.excess, delta: 100, range: range)
        XCTAssertEqual(state.base, 500); XCTAssertEqual(state.excess, 50)
    }

    func testRangeMovedByVerticalScrollingCreatesNoOvershoot() {
        // Scrolling from a wide sheet onto a narrow one: the base glides along.
        let state = NotebookViewportGeometry.elasticDragStep(base: 480, excess: 0, delta: 0, range: 120...120)
        XCTAssertEqual(state.base, 120); XCTAssertEqual(state.excess, 0)
    }

    func testReturnFractionEndsExactlyWithoutSwingingPast() {
        XCTAssertEqual(NotebookViewportGeometry.elasticReturnFraction(elapsed: 0, duration: 0.45), 1)
        XCTAssertEqual(NotebookViewportGeometry.elasticReturnFraction(elapsed: 0.45, duration: 0.45), 0)
        XCTAssertEqual(NotebookViewportGeometry.elasticReturnFraction(elapsed: 3, duration: 0.45), 0)
        var previous = 1.0
        for step in 1..<45 {
            let value = NotebookViewportGeometry.elasticReturnFraction(elapsed: Double(step) / 100, duration: 0.45)
            XCTAssertGreaterThanOrEqual(value, 0); XCTAssertLessThan(value, previous)
            previous = value
        }
    }

    func testBottomToolbarOptionsLiftOnlyCoveredPageContent() {
        let bar = PageRect(x: 200, y: 640, width: 450, height: 52)
        // Page reaches down to the bottom of the free area: lift by the bar and gap.
        let full = NotebookViewportGeometry.chromeAvoidanceShift(edge: .bottom, bar: bar,
            pages: [PageRect(x: 16, y: -300, width: 990, height: 2000)], freeTop: 72, freeBottom: 700)
        XCTAssertEqual(full, 52 + 8)
        // Page ends inside the bar's band: only that part.
        let partial = NotebookViewportGeometry.chromeAvoidanceShift(edge: .bottom, bar: bar,
            pages: [PageRect(x: 16, y: 0, width: 990, height: 660)], freeTop: 72, freeBottom: 700)
        XCTAssertEqual(partial, 20 + 8)
        // Page ends above the bar or lies beside it: nothing moves.
        XCTAssertEqual(NotebookViewportGeometry.chromeAvoidanceShift(edge: .bottom, bar: bar,
            pages: [PageRect(x: 16, y: 0, width: 990, height: 600)], freeTop: 72, freeBottom: 700), 0)
        XCTAssertEqual(NotebookViewportGeometry.chromeAvoidanceShift(edge: .bottom, bar: bar,
            pages: [PageRect(x: 700, y: 0, width: 300, height: 2000)], freeTop: 72, freeBottom: 700), 0)
    }

    func testClosingTheOptionsRestoresExactlyTheOffsetBeforeOpening() {
        // Nutzer zu Build 62 (top toolbar, one page, document start): closing
        // put the page ~one options bar too high, under the toolbar.
        let before = PagePoint(x: -16, y: -84)           // document start: −contentInset.top
        let shift = -56.0                                 // top bar: pages slide down
        let after = PagePoint(x: before.x, y: before.y + shift)
        // Read before the inset shrinks: exactly back.
        XCTAssertEqual(NotebookViewportGeometry.avoidanceReleaseOffset(current: after, after: after, shift: shift,
                                                                       minY: -84, maxY: 400), before)
        // The clamped value UIKit would report after removing the inset is not
        // "untouched"; the old code took the shift back from it a second time.
        let clamped = PagePoint(x: after.x, y: -84)
        XCTAssertEqual(NotebookViewportGeometry.avoidanceReleaseOffset(current: clamped, after: after, shift: shift,
                                                                       minY: -84, maxY: 400).y, -28, "the former double take-back")
        // Bottom toolbar at the document end: back to the end, not beyond.
        let end = PagePoint(x: 0, y: 1200), lift = 60.0
        XCTAssertEqual(NotebookViewportGeometry.avoidanceReleaseOffset(current: PagePoint(x: 0, y: 1260), after: PagePoint(x: 0, y: 1260),
                                                                       shift: lift, minY: -84, maxY: 1200), end)
        // Scrolled meanwhile: the shift is taken back from where the user is, within the limits.
        XCTAssertEqual(NotebookViewportGeometry.avoidanceReleaseOffset(current: PagePoint(x: 0, y: 500), after: PagePoint(x: 0, y: 300),
                                                                       shift: -56, minY: -84, maxY: 1200), PagePoint(x: 0, y: 556))
        XCTAssertEqual(NotebookViewportGeometry.avoidanceReleaseOffset(current: PagePoint(x: 0, y: -120), after: PagePoint(x: 0, y: 300),
                                                                       shift: 56, minY: -84, maxY: 1200).y, -84)
    }

    func testTopToolbarOptionsPushPagesDown() {
        let bar = PageRect(x: 200, y: 124, width: 450, height: 52)
        let shift = NotebookViewportGeometry.chromeAvoidanceShift(edge: .top, bar: bar,
            pages: [PageRect(x: 16, y: -500, width: 990, height: 2000)], freeTop: 128, freeBottom: 900)
        // Content below the free top moves down until the bar no longer covers it.
        XCTAssertEqual(shift, -(176 - 128 + 8))
        // A page starting below the bar stays where it is.
        XCTAssertEqual(NotebookViewportGeometry.chromeAvoidanceShift(edge: .top, bar: bar,
            pages: [PageRect(x: 16, y: 190, width: 990, height: 800)], freeTop: 128, freeBottom: 900), 0)
    }

    func testOnlyTopAndBottomDocksAvoid() {
        XCTAssertEqual(ToolbarAvoidanceEdge(dock: .top), .top)
        XCTAssertEqual(ToolbarAvoidanceEdge(dock: .bottom), .bottom)
        XCTAssertNil(ToolbarAvoidanceEdge(dock: .left))
        XCTAssertNil(ToolbarAvoidanceEdge(dock: .right))
        XCTAssertNil(ToolbarAvoidanceEdge(dock: .floating))
    }
}

final class LawPanelLayoutTests: XCTestCase {
    private let size = PageSize(width: 1180, height: 820)

    func testSideAndBottomFramesAndNotebookArea() {
        let right = LawPanelLayout(size: size, width: 380, height: 360, docked: true, edge: .right)
        XCTAssertEqual(right.frame, PageRect(x: 800, y: 0, width: 380, height: 820))
        XCTAssertEqual(right.notebookFrame, PageRect(x: 0, y: 0, width: 794, height: 820))
        let left = LawPanelLayout(size: size, width: 380, height: 360, docked: true, edge: .left)
        XCTAssertEqual(left.notebookFrame.x, 386)
        let bottom = LawPanelLayout(size: size, width: 380, height: 360, docked: true, edge: .bottom)
        XCTAssertEqual(bottom.frame, PageRect(x: 0, y: 460, width: 1180, height: 360))
        XCTAssertEqual(bottom.notebookFrame, PageRect(x: 0, y: 0, width: 1180, height: 454))
        XCTAssertEqual(bottom.outward, PagePoint(x: 0, y: 1))
        XCTAssertEqual(bottom.hiddenShift, 360)
        let floating = LawPanelLayout(size: size, width: 380, height: 360, docked: false, edge: .bottom)
        XCTAssertEqual(floating.frame, PageRect(x: 10, y: 450, width: 1160, height: 360))
        XCTAssertEqual(floating.notebookFrame, PageRect(x: 0, y: 0, width: 1180, height: 820))
    }

    func testDockedBottomKeepsRoomForTheNotebookAndFloatsWhenTooLow() {
        let tall = LawPanelLayout(size: size, width: 380, height: 900, docked: true, edge: .bottom)
        XCTAssertEqual(tall.dockHeight, 820 - LawPanelLayout.notebookHeight)
        let low = LawPanelLayout(size: PageSize(width: 1180, height: 500), width: 380, height: 360, docked: true, edge: .bottom)
        XCTAssertFalse(low.docked)
        let narrow = LawPanelLayout(size: PageSize(width: 600, height: 820), width: 380, height: 360, docked: true, edge: .right)
        XCTAssertFalse(narrow.docked)
        XCTAssertTrue(LawPanelLayout(size: PageSize(width: 600, height: 820), width: 380, height: 360, docked: true, edge: .bottom).docked)
    }

    func testDropTargets() {
        let right = LawPanelLayout(size: size, width: 380, height: 360, docked: false, edge: .right)
        XCTAssertEqual(right.drop(translation: .init(x: 10, y: 10), location: .init(x: 900, y: 40)), .stay)
        XCTAssertEqual(right.drop(translation: .init(x: -700, y: 10), location: .init(x: 40, y: 40)), .dock(.left))
        XCTAssertEqual(right.drop(translation: .init(x: -300, y: 600), location: .init(x: 600, y: 770)), .dock(.bottom))
        XCTAssertEqual(right.drop(translation: .init(x: -300, y: 500), location: .init(x: 600, y: 600)), .float(.bottom))
        XCTAssertEqual(right.drop(translation: .init(x: -500, y: 100), location: .init(x: 400, y: 300)), .float(.left))
        XCTAssertEqual(right.drop(translation: .init(x: 300, y: 0), location: .init(x: 1150, y: 40)), .stash(.right))
        // A side window pulled down stays a window; only a flick stashes it downwards.
        XCTAssertNotEqual(right.drop(translation: .init(x: 0, y: 500), location: .init(x: 900, y: 600)), .stash(.bottom))
        XCTAssertEqual(right.drop(translation: .init(x: 0, y: 300), location: .init(x: 900, y: 400),
                                  predictedTranslation: .init(x: 0, y: 900), predictedLocation: .init(x: 900, y: 1000)), .stash(.bottom))
        let bottom = LawPanelLayout(size: size, width: 380, height: 360, docked: false, edge: .bottom)
        XCTAssertEqual(bottom.drop(translation: .init(x: 0, y: 200), location: .init(x: 500, y: 660)), .stash(.bottom))
        XCTAssertEqual(bottom.drop(translation: .init(x: 400, y: -400), location: .init(x: 900, y: 60)), .float(.right))
        // Pushed far sideways a bottom window never turns into a side window.
        XCTAssertEqual(bottom.drop(translation: .init(x: 900, y: 0), location: .init(x: 1100, y: 500)), .dock(.right))
        XCTAssertEqual(bottom.drop(translation: .init(x: 200, y: 0), location: .init(x: 900, y: 600),
                                   predictedTranslation: .init(x: 900, y: 0), predictedLocation: .init(x: 1600, y: 600)), .stash(.bottom))
        XCTAssertTrue(bottom.changes(.float(.right)))
        XCTAssertFalse(bottom.changes(.float(.bottom)))
        XCTAssertTrue(bottom.changes(.dock(.bottom)))
    }

    func testDragOffsetKeepsPartOfTheWindowInTheWorkspace() {
        let bottom = LawPanelLayout(size: size, width: 380, height: 360, docked: false, edge: .bottom)
        let offset = bottom.dragOffset(.init(x: 0, y: -2000))
        XCTAssertEqual(offset.y, -450)
        XCTAssertEqual(bottom.dragOffset(.init(x: 5000, y: 0)).x, 1170)
    }
}
