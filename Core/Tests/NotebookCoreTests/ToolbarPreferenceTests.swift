import Foundation
import XCTest
@testable import NotebookCore

final class ToolbarPreferenceTests: XCTestCase {
    func testLegacyOrderAddsImageWithoutLosingCustomOrderOrSettings() throws {
        var old = ToolbarPreferences(); old.formatVersion = 1
        old.order = WritingTool.format7Tools.filter { ![.image, .shape, .selection].contains($0) }.reversed()
        old.dock = .right; old.penWidth = 7
        let migrated = try ToolbarPreferences.decode(JSONEncoder().encode(old))
        XCTAssertEqual(migrated.order.filter { ![.image, .shape, .selection, .pencil, .laser].contains($0) }, old.order)
        XCTAssertEqual(migrated.dock, .right); XCTAssertEqual(migrated.penWidth, 7)
        XCTAssertEqual(migrated.formatVersion, 8); try migrated.validate()
        old.order.append(.pen)
        XCTAssertThrowsError(try ToolbarPreferences.decode(JSONEncoder().encode(old)))
    }
    private func root() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }

    func testFullSettingsRoundtripAndOldWriteCannotOverrideNewerChoice() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = ToolbarPreferenceStore(root: root)
        var preferences = ToolbarPreferences()
        preferences.dock = .floating; preferences.order.reverse(); preferences.floatingX = 0.8; preferences.floatingY = 0.9
        preferences.penColor = InkColor(0.1, 0.2, 0.3); preferences.penWidth = 7
        preferences.fingerDrawing = true
        preferences.presets = [InkPreset(tool: .marker, color: InkColor(1, 0, 0, 0.4), width: 24)]
        try await store.save(preferences, revision: 2)
        try await store.save(ToolbarPreferences(), revision: 1)
        let loaded = try await ToolbarPreferenceStore(root: root).load()
        XCTAssertEqual(loaded.0, preferences); XCTAssertFalse(loaded.1)
    }

    func testInvalidOrderWidthsColorsAndOffsetsAreRejected() throws {
        var value = ToolbarPreferences(); value.order[0] = .marker
        XCTAssertThrowsError(try value.validate())
        value = ToolbarPreferences(); value.penWidth = .infinity
        XCTAssertThrowsError(try value.validate())
        value = ToolbarPreferences(); value.penColor.red = -0.1
        XCTAssertThrowsError(try value.validate())
        value = ToolbarPreferences(); value.floatingY = 1.1
        XCTAssertThrowsError(try value.validate())
        value = ToolbarPreferences(); value.presets = [InkPreset(tool: .read, color: InkColor(0, 0, 0), width: 3)]
        XCTAssertThrowsError(try value.validate())
    }

    func testFutureFormatBlocksSaveAndCorruptPrimaryRecoversPrevious() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = ToolbarPreferenceStore(root: root)
        try await store.save(ToolbarPreferences(), revision: 1)
        var next = ToolbarPreferences(); next.dock = .left
        try await store.save(next, revision: 2)
        let primary = root.appendingPathComponent("toolbar.json")
        try Data("broken".utf8).write(to: primary)
        let fallback = try await ToolbarPreferenceStore(root: root).load()
        XCTAssertTrue(fallback.1); XCTAssertEqual(fallback.0, ToolbarPreferences())
        let future = Data("{\"formatVersion\":99}".utf8); try future.write(to: primary)
        do { try await ToolbarPreferenceStore(root: root).save(next, revision: 3); XCTFail("future overwritten") }
        catch ToolbarError.unsupported(99) { }
        XCTAssertEqual(try Data(contentsOf: primary), future)
    }

    func testFailedWriteRetainsPreviousAndCanBeRetried() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = ToolbarPreferenceStore(root: root)
        try await store.save(ToolbarPreferences(), revision: 1)
        let primary = root.appendingPathComponent("toolbar.json")
        try FileManager.default.removeItem(at: primary)
        try FileManager.default.createDirectory(at: primary, withIntermediateDirectories: false)
        var next = ToolbarPreferences(); next.dock = .right
        do { try await store.save(next, revision: 2); XCTFail("write should fail") } catch { }
        let fallback = try await ToolbarPreferenceStore(root: root).load()
        XCTAssertEqual(fallback.0, ToolbarPreferences()); XCTAssertTrue(fallback.1)
        try FileManager.default.removeItem(at: primary)
        try await store.save(next, revision: 2)
        let retried = try await ToolbarPreferenceStore(root: root).load()
        XCTAssertEqual(retried.0, next)
    }
}
