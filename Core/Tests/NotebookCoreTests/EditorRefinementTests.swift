import Foundation
import XCTest
@testable import NotebookCore

final class EditorRefinementTests: XCTestCase {
    func testZoomStopsAtCompletePageFit() {
        for viewport in [375.0, 744, 1194] {
            for page in [240.0, 595, 842, 1400] {
                let height = page * 842 / 595
                let range = NotebookViewportGeometry.zoomRange(viewport: .init(width: viewport, height: 800), page: .init(width: page, height: height))
                XCTAssertEqual(range.fit * page, viewport - 32, accuracy: 0.001)
                XCTAssertLessThanOrEqual(range.minimum * page, viewport - 32 + 0.001)
                XCTAssertLessThanOrEqual(range.minimum * height, 768.001)
                XCTAssertEqual(max(range.minimum * page / (viewport - 32), range.minimum * height / 768), 1, accuracy: 0.001)
                XCTAssertGreaterThan(range.maximum, range.fit)
            }
        }
    }

    func testEachPagingSizeHasItsOwnFitIncludingSmallerFollowingPage() {
        let sizes = [842.0, 240, 595, 1000, 240]
        let fits = sizes.map { NotebookViewportGeometry.zoomRange(viewport: .init(width: 744, height: 800), page: .init(width: $0, height: 842)).fit }
        XCTAssertGreaterThan(fits[1], fits[0] * 3)
        XCTAssertEqual(fits[1], fits[4])
        for (size, fit) in zip(sizes, fits) { XCTAssertEqual(size * fit, 712, accuracy: 0.001) }
    }

    func testOptionsAttachBelowTopAndAboveBottomWithNoClipping() {
        let viewport = PageSize(width: 1194, height: 834)
        for dock in [ToolbarDock.top, .bottom] {
            let layout = ToolbarLayout(viewport: viewport, dock: dock, items: 9)
            let options = layout.optionsFrame(preferredWidth: 450)
            XCTAssertEqual(options.x + options.width / 2, layout.center.x)
            if dock == .top { XCTAssertEqual(options.y, layout.frame.y + layout.frame.height + 8) }
            else { XCTAssertEqual(options.y + options.height, layout.frame.y - 8) }
            XCTAssertGreaterThanOrEqual(options.y, 12)
            XCTAssertLessThanOrEqual(options.y + options.height, 822)
        }
    }

    func testVerticalAndNarrowFloatingOptionsStayReachable() {
        for dock in [ToolbarDock.left, .right, .floating] {
            let layout = ToolbarLayout(viewport: .init(width: 375, height: 667), dock: dock,
                items: 9, floatingX: 1, floatingY: 1)
            let options = layout.optionsFrame(preferredWidth: 450)
            XCTAssertGreaterThanOrEqual(options.x, 12)
            XCTAssertGreaterThanOrEqual(options.y, 12)
            XCTAssertLessThanOrEqual(options.x + options.width, 363)
            XCTAssertLessThanOrEqual(options.y + options.height, 655)
            if dock == .left { XCTAssertGreaterThan(options.x, layout.frame.x + layout.frame.width) }
            if dock == .right { XCTAssertLessThan(options.x + options.width, layout.frame.x) }
        }
    }

    func testDefaultDockOnlyRejectsFreeDropButAllowsAllFourTargets() {
        var preferences = ToolbarPreferences(); preferences.dock = .left
        XCTAssertEqual(preferences.dropDestination(near: nil), .left)
        for dock in [ToolbarDock.top, .bottom, .left, .right] {
            XCTAssertEqual(preferences.dropDestination(near: dock), dock)
        }
        preferences.dockOnly = false
        XCTAssertEqual(preferences.dropDestination(near: nil), .floating)
        preferences.dock = .floating
        XCTAssertEqual(preferences.effectiveDock, .floating)
        preferences.dockOnly = true
        XCTAssertEqual(preferences.effectiveDock, .top)
        XCTAssertEqual(preferences.dropDestination(near: nil), .top)
    }

    func testOldFloatingChoiceIsPreservedButDefaultRestrictsEffectivePosition() throws {
        var old = ToolbarPreferences(); old.formatVersion = 5; old.dock = .floating
        old.floatingAxis = .vertical; old.floatingX = 0.8; old.order.reverse()
        let migrated = try ToolbarPreferences.decode(JSONEncoder().encode(old))
        var expected = old; expected.formatVersion = 7
        XCTAssertEqual(migrated, expected)
        XCTAssertEqual(migrated.effectiveDock, .top)
        old.dockOnly = false
        XCTAssertThrowsError(try ToolbarPreferences.decode(JSONEncoder().encode(old)))
    }

    func testFreePlacementChoiceSurvivesPreferenceStoreRestart() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var value = ToolbarPreferences(); value.dockOnly = false; value.dock = .floating; value.floatingAxis = .vertical
        try await ToolbarPreferenceStore(root: root).save(value, revision: 1)
        let loaded = try await ToolbarPreferenceStore(root: root).load()
        XCTAssertEqual(loaded.0, value)
        XCTAssertEqual(loaded.0.effectiveDock, .floating)
    }
}
