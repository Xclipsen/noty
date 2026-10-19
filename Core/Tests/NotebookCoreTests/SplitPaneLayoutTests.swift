import Foundation
import XCTest
@testable import NotebookCore

final class SplitPaneLayoutTests: XCTestCase {
    private let landscape = PageSize(width: 1194, height: 790)
    private let portrait = PageSize(width: 834, height: 1150)

    func testDefaultKeepsPrimaryLeftAtHalf() {
        let arrangement = SplitPaneArrangement()
        XCTAssertEqual(arrangement.order, [.primary, .secondary])
        XCTAssertEqual(arrangement.slot(of: .primary), .first)
        XCTAssertEqual(arrangement.pane(in: .second), .secondary)
        XCTAssertEqual(arrangement.fraction, 0.5)
    }

    func testDropSlotFollowsHalfAlongAxisAndRejectsInvalidInput() {
        XCTAssertEqual(SplitPaneArrangement.dropSlot(at: 100, extent: 1000), .first)
        XCTAssertEqual(SplitPaneArrangement.dropSlot(at: 499.9, extent: 1000), .first)
        XCTAssertEqual(SplitPaneArrangement.dropSlot(at: 500, extent: 1000), .second)
        // Dragged beyond the container still lands on the nearer side.
        XCTAssertEqual(SplitPaneArrangement.dropSlot(at: -40, extent: 1000), .first)
        XCTAssertEqual(SplitPaneArrangement.dropSlot(at: 1300, extent: 1000), .second)
        XCTAssertNil(SplitPaneArrangement.dropSlot(at: 10, extent: 0))
        XCTAssertNil(SplitPaneArrangement.dropSlot(at: .nan, extent: 1000))

        var stacked = SplitPaneArrangement(vertical: true)
        // Stacked: only the vertical position counts.
        XCTAssertEqual(stacked.dropSlot(at: PagePoint(x: 1100, y: 100), in: landscape), .first)
        XCTAssertEqual(stacked.dropSlot(at: PagePoint(x: 10, y: 700), in: landscape), .second)
        stacked.vertical = false
        XCTAssertEqual(stacked.dropSlot(at: PagePoint(x: 1100, y: 100), in: landscape), .second)
    }

    func testPlacingSwapsOnlyWhenTargetDiffersAndPaneKeepsItsSize() {
        var arrangement = SplitPaneArrangement(fraction: 2.0 / 3)
        let primaryWidth = arrangement.frame(of: .primary, in: landscape).width
        XCTAssertFalse(arrangement.place(.primary, in: .first))
        XCTAssertFalse(arrangement.place(.secondary, in: .second))
        XCTAssertTrue(arrangement.place(.secondary, in: .first))
        XCTAssertEqual(arrangement.order, [.secondary, .primary])
        XCTAssertEqual(arrangement.fraction, 1.0 / 3, accuracy: 1e-9)
        XCTAssertEqual(arrangement.frame(of: .primary, in: landscape).width, primaryWidth)
        XCTAssertEqual(arrangement.slot(of: .primary), .second)
        // Moving the primary back restores the original arrangement.
        XCTAssertTrue(arrangement.place(.primary, in: .first))
        XCTAssertEqual(arrangement, SplitPaneArrangement(fraction: 2.0 / 3))
        XCTAssertEqual(SplitPaneArrangement().placing(.primary, in: .second).order, [.secondary, .primary])
    }

    func testFramesTileContainerWithGap() {
        for vertical in [false, true] {
            for fraction in SplitPaneArrangement.snapFractions {
                let arrangement = SplitPaneArrangement(secondaryFirst: true, vertical: vertical, fraction: fraction)
                let first = arrangement.frame(of: .first, in: landscape)
                let second = arrangement.frame(of: .second, in: landscape)
                if vertical {
                    XCTAssertEqual(first.y, 0); XCTAssertEqual(first.width, landscape.width)
                    XCTAssertEqual(second.y, first.height + SplitPaneArrangement.gap, accuracy: 1e-9)
                    XCTAssertEqual(second.y + second.height, landscape.height, accuracy: 1e-9)
                    XCTAssertEqual(arrangement.dividerPosition(in: landscape), first.height + SplitPaneArrangement.gap / 2, accuracy: 1e-9)
                } else {
                    XCTAssertEqual(first.x, 0); XCTAssertEqual(first.height, landscape.height)
                    XCTAssertEqual(second.x, first.width + SplitPaneArrangement.gap, accuracy: 1e-9)
                    XCTAssertEqual(second.x + second.width, landscape.width, accuracy: 1e-9)
                }
                XCTAssertEqual(arrangement.frame(of: .secondary, in: landscape), first)
            }
        }
    }

    func testDividerSnapsToThirdsHalfAndRespectsMinimumPane() {
        let width = landscape.width
        XCTAssertEqual(SplitPaneArrangement.snappedFraction(location: 300, extent: width), 1.0 / 3, accuracy: 1e-9)
        XCTAssertEqual(SplitPaneArrangement.snappedFraction(location: 560, extent: width), 0.5)
        XCTAssertEqual(SplitPaneArrangement.snappedFraction(location: 1100, extent: width), 2.0 / 3, accuracy: 1e-9)
        // Portrait side by side: a third would be < 320 pt, only halves remain.
        XCTAssertEqual(SplitPaneArrangement.allowedFractions(extent: portrait.width), [0.5])
        XCTAssertEqual(SplitPaneArrangement.snappedFraction(location: 50, extent: portrait.width), 0.5)
        XCTAssertEqual(SplitPaneArrangement.snappedFraction(location: .infinity, extent: width), 0.5)
        // The stored third survives but is shown as half where it does not fit.
        let third = SplitPaneArrangement(fraction: 1.0 / 3)
        XCTAssertEqual(third.effectiveFraction(extent: portrait.width), 0.5)
        XCTAssertEqual(third.effectiveFraction(extent: width), 1.0 / 3, accuracy: 1e-9)
        XCTAssertEqual(third.frame(of: .first, in: portrait).width, ((portrait.width - SplitPaneArrangement.gap) / 2).rounded())
        for size in [landscape, portrait] {
            for fraction in SplitPaneArrangement.snapFractions {
                let arrangement = SplitPaneArrangement(fraction: fraction)
                XCTAssertGreaterThanOrEqual(arrangement.frame(of: .first, in: size).width, SplitPaneArrangement.minimumPane - 1)
                XCTAssertGreaterThanOrEqual(arrangement.frame(of: .second, in: size).width, SplitPaneArrangement.minimumPane - 1)
            }
        }
        // Arbitrary values are normalised to a snap point.
        XCTAssertEqual(SplitPaneArrangement(fraction: 0.9).fraction, 2.0 / 3, accuracy: 1e-9)
        XCTAssertEqual(SplitPaneArrangement(fraction: .nan).fraction, 0.5)
    }

    func testStorageRoundTripAndTolerantFallback() {
        for secondaryFirst in [false, true] {
            for vertical in [false, true] {
                for fraction in SplitPaneArrangement.snapFractions {
                    let arrangement = SplitPaneArrangement(secondaryFirst: secondaryFirst, vertical: vertical, fraction: fraction)
                    XCTAssertEqual(SplitPaneArrangement(storageValue: arrangement.storageValue), arrangement)
                }
            }
        }
        XCTAssertEqual(SplitPaneArrangement(storageValue: ""), SplitPaneArrangement())
        XCTAssertEqual(SplitPaneArrangement(storageValue: "v9;s=1"), SplitPaneArrangement())
        XCTAssertEqual(SplitPaneArrangement(storageValue: "v1;s=7;v=1;f=9;x=1;garbage"),
                       SplitPaneArrangement(vertical: true))
        XCTAssertEqual(SplitPaneArrangement(storageValue: "v1;s=1;f=0"),
                       SplitPaneArrangement(secondaryFirst: true, fraction: 1.0 / 3))
    }
}
