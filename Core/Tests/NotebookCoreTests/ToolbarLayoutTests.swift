import Foundation
import XCTest
@testable import NotebookCore

final class ToolbarLayoutTests: XCTestCase {
    private let screen = PageSize(width: 1194, height: 834)

    func testContentDeterminesLengthAndBothLevelsStayCentered() {
        let main = ToolbarLayout.itemCount(more: false, presets: 0, secondView: true)
        let more = ToolbarLayout.itemCount(more: true, presets: 0, secondView: true)
        XCTAssertEqual(ToolbarLayout.length(items: main), 460)
        XCTAssertEqual(ToolbarLayout.length(items: more), 364)
        XCTAssertEqual(ToolbarLayout.itemCount(more: true, presets: 12, secondView: false), 6)
        for width in [744.0, 880, 1194] {
            for dock in [ToolbarDock.top, .bottom] {
                let first = ToolbarLayout(viewport: .init(width: width, height: 834), dock: dock, items: main, headerItems: main)
                let second = ToolbarLayout(viewport: first.viewport, dock: dock, items: more, headerItems: main)
                XCTAssertEqual(first.center.x, width / 2, accuracy: 0.001)
                XCTAssertEqual(second.center.x, width / 2, accuracy: 0.001)
                XCTAssertEqual(first.frame.y, second.frame.y)
                XCTAssertEqual(first.inlineHeader, second.inlineHeader)
                XCTAssertEqual(first.frame.width, width == 744 && dock == .top ? 428 : 460)
                XCTAssertEqual(second.frame.width, 364)
            }
        }
    }

    func testManyFavoritesScrollWithinScreenInsteadOfExtendingBeyondIt() {
        let count = ToolbarLayout.itemCount(more: false, presets: 12, secondView: true)
        for dock in ToolbarDock.allCases {
            let layout = ToolbarLayout(viewport: .init(width: 375, height: 667), dock: dock, items: count)
            XCTAssertGreaterThanOrEqual(layout.frame.x, 0)
            XCTAssertGreaterThanOrEqual(layout.frame.y, 0)
            XCTAssertLessThanOrEqual(layout.frame.x + layout.frame.width, 375)
            XCTAssertLessThanOrEqual(layout.frame.y + layout.frame.height, 667)
        }
    }

    func testSidesAreCenteredBelowHeaderAndDockControlsAxis() {
        let left = ToolbarLayout(viewport: screen, dock: .left, floatingAxis: .horizontal, items: 9)
        let right = ToolbarLayout(viewport: screen, dock: .right, floatingAxis: .horizontal, items: 9)
        XCTAssertEqual(left.axis, .vertical)
        XCTAssertEqual(left.center.y, (screen.height + 64) / 2)
        XCTAssertEqual(left.center.y, right.center.y)
        XCTAssertEqual(left.frame.x, 12)
        XCTAssertEqual(right.frame.x + right.frame.width, screen.width - 12)
        XCTAssertEqual(ToolbarLayout.axis(for: .top, floating: .vertical), .horizontal)
        XCTAssertEqual(ToolbarLayout.axis(for: .bottom, floating: .vertical), .horizontal)
        XCTAssertEqual(ToolbarLayout.axis(for: .floating, floating: .horizontal), .horizontal)
        XCTAssertEqual(ToolbarLayout.axis(for: .floating, floating: .vertical), .vertical)
    }

    func testFloatingRotationAndLevelSwitchPreserveCenter() {
        let first = ToolbarLayout(viewport: screen, dock: .floating, items: 9, floatingX: 0.5, floatingY: 0.5)
        for axis in [ToolbarAxis.horizontal, .vertical] {
            for count in [8, 9] {
                let target = ToolbarLayout(viewport: screen, dock: .floating, floatingAxis: axis, items: count)
                let normalized = target.floatingPosition(center: first.center)
                let placed = ToolbarLayout(viewport: screen, dock: .floating, floatingAxis: axis, items: count,
                    floatingX: normalized.x, floatingY: normalized.y)
                XCTAssertEqual(placed.center.x, first.center.x, accuracy: 0.001)
                XCTAssertEqual(placed.center.y, first.center.y, accuracy: 0.001)
            }
        }
    }

    func testOffscreenReleaseClampsToReachablePosition() {
        for axis in [ToolbarAxis.horizontal, .vertical] {
            let target = ToolbarLayout(viewport: screen, dock: .floating, floatingAxis: axis, items: 9)
            for point in [PagePoint(x: -500, y: -800), .init(x: 9000, y: 9000)] {
                let normalized = target.floatingPosition(center: point)
                let placed = ToolbarLayout(viewport: screen, dock: .floating, floatingAxis: axis, items: 9,
                    floatingX: normalized.x, floatingY: normalized.y)
                XCTAssertGreaterThanOrEqual(placed.frame.x, 12)
                XCTAssertGreaterThanOrEqual(placed.frame.y, 76)
                XCTAssertLessThanOrEqual(placed.frame.x + placed.frame.width, screen.width - 12)
                XCTAssertLessThanOrEqual(placed.frame.y + placed.frame.height, screen.height - 12)
            }
        }
    }

    func testEveryGuideMatchesActualDockCenterEvenInNarrowPane() {
        for width in [744.0, 880, 1194] {
            let layout = ToolbarLayout(viewport: .init(width: width, height: 834), dock: .floating, items: 8, headerItems: 9)
            for dock in [ToolbarDock.top, .bottom, .left, .right] {
                let guide = layout.guide(for: dock)
                let target = ToolbarLayout(viewport: layout.viewport, dock: dock, items: 8, headerItems: 9)
                XCTAssertEqual(guide.x + guide.width / 2, target.center.x)
                XCTAssertEqual(guide.y + guide.height / 2, target.center.y)
            }
        }
    }

    func testNearGuideSnapsFromPointerOrBarCenterAndAllowsFreeSpace() {
        let layout = ToolbarLayout(viewport: screen, dock: .floating, items: 9)
        let free = PagePoint(x: 550, y: 420)
        XCTAssertNil(layout.snapTarget(pointer: free, center: free))
        for dock in [ToolbarDock.top, .bottom, .left, .right] {
            let guide = layout.guide(for: dock)
            let near = PagePoint(x: guide.x + guide.width + 29, y: guide.y + guide.height / 2)
            XCTAssertEqual(layout.snapTarget(pointer: near, center: free), dock)
            XCTAssertEqual(layout.snapTarget(pointer: free, center: near), dock)
        }
    }

    func testSnapHysteresisAvoidsFlickeringAtBoundaryAndReleasesOutside() {
        let layout = ToolbarLayout(viewport: screen, dock: .floating, items: 9)
        let zone = layout.guide(for: .left)
        let insideHold = PagePoint(x: zone.x + zone.width + 47, y: zone.y + zone.height / 2)
        XCTAssertNil(layout.snapTarget(pointer: insideHold, center: insideHold))
        XCTAssertEqual(layout.snapTarget(pointer: insideHold, center: insideHold, previous: .left), .left)
        let outside = PagePoint(x: zone.x + zone.width + 49, y: insideHold.y)
        XCTAssertNil(layout.snapTarget(pointer: outside, center: outside, previous: .left))
    }

    func testVersionFourMigrationPreservesChoicesAndVersionFiveRoundTripsAxis() throws {
        var old = ToolbarPreferences(); old.formatVersion = 4; old.dock = .bottom
        old.order.reverse(); old.autoPen = true; old.pencilPreview = false; old.floatingX = 0.7
        var expected = old; expected.formatVersion = 7
        XCTAssertEqual(try ToolbarPreferences.decode(JSONEncoder().encode(old)), expected)
        expected.dock = .floating; expected.floatingAxis = .vertical
        XCTAssertEqual(try ToolbarPreferences.decode(JSONEncoder().encode(expected)), expected)
        old.floatingAxis = .horizontal
        XCTAssertThrowsError(try ToolbarPreferences.decode(JSONEncoder().encode(old)))
        expected.formatVersion = 8
        XCTAssertThrowsError(try ToolbarPreferences.decode(JSONEncoder().encode(expected)))
    }
}
