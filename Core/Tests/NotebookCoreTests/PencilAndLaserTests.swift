import Foundation
import XCTest
@testable import NotebookCore

final class PencilAndLaserTests: XCTestCase {
    private func root() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }

    /// Literal format-7 file as written by earlier builds (custom order, preset, options).
    private let format7 = Data("""
    {"formatVersion":7,"dock":"left","order":["marker","pen","strokeEraser","text","read","selection","shape","image","precisionEraser","inkSelection"],
     "penColor":{"red":0,"green":0,"blue":1,"alpha":1},"markerColor":{"red":1,"green":1,"blue":0,"alpha":1},
     "penWidth":3,"markerWidth":14,"eraserWidth":16,"fingerDrawing":true,"autoPen":true,"scribbleErase":false,
     "floatingX":0,"floatingY":0,"presets":[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","tool":"pen","color":{"red":1,"green":0,"blue":0,"alpha":1},"width":4}]}
    """.utf8)

    func testFormatSevenGainsPencilAfterPenAndLaserAfterReadKeepingEverythingElse() throws {
        let value = try ToolbarPreferences.decode(format7)
        XCTAssertEqual(value.formatVersion, 8)
        XCTAssertEqual(value.order, [.marker, .pen, .pencil, .strokeEraser, .text, .read, .laser, .selection, .shape, .image, .precisionEraser, .inkSelection])
        XCTAssertEqual(value.mainTools, [.marker, .pen, .pencil, .strokeEraser, .text, .read, .laser, .inkSelection, .shape, .image])
        XCTAssertEqual(value.dock, .left); XCTAssertEqual(value.penWidth, 3); XCTAssertEqual(value.autoPen, true)
        XCTAssertEqual(value.scribbleErase, false); XCTAssertTrue(value.fingerDrawing); XCTAssertEqual(value.presets.count, 1)
        XCTAssertNil(value.pencilColor); XCTAssertNil(value.laserMode)
        XCTAssertEqual(value.effectivePencilColor, ToolbarPreferences.defaultPencilColor)
        XCTAssertEqual(value.laserStyle, LaserPointerStyle(color: ToolbarPreferences.defaultLaserColor, mode: .trail, fade: .medium))
        XCTAssertEqual(try ToolbarPreferences.decode(JSONEncoder().encode(value)), value)
        XCTAssertEqual(ToolbarPreferences().mainTools, [.pen, .pencil, .marker, .strokeEraser, .text, .inkSelection, .shape, .image, .read, .laser])
    }

    func testNewFieldsCannotMasqueradeAsFormatSevenAndNewerFormatsStayLocked() throws {
        func patched(_ old: String, _ new: String) -> Data { Data(String(decoding: format7, as: UTF8.self).replacingOccurrences(of: old, with: new).utf8) }
        XCTAssertThrowsError(try ToolbarPreferences.decode(patched("\"autoPen\":true", "\"autoPen\":true,\"laserMode\":\"dot\"")))
        XCTAssertThrowsError(try ToolbarPreferences.decode(patched("\"autoPen\":true", "\"autoPen\":true,\"pencilWidth\":3")))
        XCTAssertThrowsError(try ToolbarPreferences.decode(patched("\"marker\",\"pen\"", "\"marker\",\"pen\",\"pencil\"")))
        XCTAssertThrowsError(try ToolbarPreferences.decode(patched("\"tool\":\"pen\"", "\"tool\":\"pencil\"")))
        XCTAssertThrowsError(try ToolbarPreferences.decode(patched("\"formatVersion\":7", "\"formatVersion\":9"))) { error in
            guard case ToolbarError.unsupported(9) = error else { return XCTFail("\(error)") }
        }
        // Format 8 itself must contain both new tools exactly once.
        var value = ToolbarPreferences(); value.order.removeAll { $0 == .laser }
        XCTAssertThrowsError(try value.validate())
    }

    func testPencilAndLaserSettingsValidateAndRoundTrip() throws {
        var value = ToolbarPreferences()
        value.pencilColor = InkColor(0.3, 0.3, 0.3); value.pencilWidth = 6; value.autoPencil = true
        value.laserColor = InkColor(0.2, 1, 0.3); value.laserMode = .dot; value.laserFade = .untilLift
        value.presets = [InkPreset(tool: .pencil, color: InkColor(0.1, 0.1, 0.1), width: 14)]
        XCTAssertEqual(try ToolbarPreferences.decode(JSONEncoder().encode(value)), value)
        value.presets[0].width = 17
        XCTAssertThrowsError(try value.validate())
        value.presets = [InkPreset(tool: .laser, color: InkColor(1, 0, 0), width: 4)]
        XCTAssertThrowsError(try value.validate())
        value.presets = []; value.pencilWidth = 0.5
        XCTAssertThrowsError(try value.validate())
        value.pencilWidth = 2; value.laserColor = InkColor(1.2, 0, 0)
        XCTAssertThrowsError(try value.validate())
    }

    func testFirstFormatEightSaveKeepsExactFormatSevenBytes() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try format7.write(to: root.appendingPathComponent("toolbar.json"))
        let store = ToolbarPreferenceStore(root: root)
        var (value, recovered) = try await store.load()
        XCTAssertFalse(recovered)
        // Loading alone migrates only in memory.
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("toolbar.json")), format7)
        value.laserMode = .dot
        try await store.save(value, revision: 1)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("toolbar-format7.json")), format7)
        let reloaded = try await ToolbarPreferenceStore(root: root).load().0
        XCTAssertEqual(reloaded, value)
        value.laserMode = .trail
        try await store.save(value, revision: 2)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("toolbar-format7.json")), format7)
    }

    func testFailedLegacyCopyPreventsTheFormatEightCommit() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let blocker = root.appendingPathComponent("toolbar-format7.json/blocker")
        try FileManager.default.createDirectory(at: blocker, withIntermediateDirectories: true)
        try format7.write(to: root.appendingPathComponent("toolbar.json"))
        let store = ToolbarPreferenceStore(root: root)
        var value = try await store.load().0
        value.pencilWidth = 5
        do { try await store.save(value, revision: 1); XCTFail("committed without a copy of the format-7 bytes") } catch { }
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("toolbar.json")), format7)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("toolbar-previous.json").path))
        try FileManager.default.removeItem(at: blocker.deletingLastPathComponent())
        try await store.save(value, revision: 1)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("toolbar-format7.json")), format7)
        let reloaded = try await ToolbarPreferenceStore(root: root).load().0
        XCTAssertEqual(reloaded, value)
    }

    func testToolbarLengthCountsTheVisibleTools() {
        XCTAssertEqual(ToolbarLayout.itemCount(more: false, presets: 2, secondView: true, tools: ToolbarPreferences().mainTools.count), 13)
        XCTAssertEqual(ToolbarLayout.itemCount(more: true, presets: 2, secondView: true, tools: 10), 6)
    }

    // MARK: Laser trail

    func testTrailFadesFromItsOldEndAndDisappearsCompletely() {
        var trail = LaserTrail(mode: .trail, fade: .short)
        XCTAssertTrue(trail.begin(at: .init(x: 0, y: 0), time: 0))
        for step in 1...10 { trail.move(to: .init(x: Double(step) * 10, y: 0), time: Double(step) * 0.05) }
        let levels = trail.segments(at: 0.5, levels: 4)
        XCTAssertEqual(levels.flatMap { $0 }.count, 10)
        // Newest segments are the most opaque level, the oldest the faintest.
        XCTAssertTrue(levels[0].contains { $0.end == .init(x: 100, y: 0) })
        let oldest = levels.firstIndex { $0.contains { $0.start == .init(x: 0, y: 0) } }
        XCTAssertEqual(oldest, 2) // opacity 1 - 0.5 / 0.7
        trail.end(time: 0.5)
        XCTAssertFalse(trail.isEmpty(at: 0.6))
        trail.prune(at: 0.9)
        XCTAssertTrue(trail.samples.allSatisfy { $0.time > 0.2 - 1e-9 })
        XCTAssertTrue(trail.isEmpty(at: 1.3)); trail.prune(at: 1.3)
        XCTAssertTrue(trail.samples.isEmpty); XCTAssertNil(trail.pointer)
    }

    func testUntilLiftKeepsWholeStrokeThenFadesItTogether() {
        var trail = LaserTrail(mode: .trail, fade: .untilLift)
        trail.begin(at: .init(x: 0, y: 0), time: 0)
        trail.move(to: .init(x: 50, y: 0), time: 30)
        XCTAssertEqual(trail.segments(at: 60, levels: 3)[0].count, 1)
        trail.end(time: 60)
        XCTAssertEqual(trail.pointerOpacity(at: 60), 1)
        XCTAssertEqual(trail.segments(at: 60 + LaserTrail.liftFade * 0.6, levels: 2)[1].count, 1)
        XCTAssertTrue(trail.isEmpty(at: 60 + LaserTrail.liftFade))
    }

    func testStrokesNeverConnectAndATapLeavesADot() {
        var trail = LaserTrail(mode: .trail, fade: .long)
        trail.begin(at: .init(x: 0, y: 0), time: 0)
        trail.move(to: .init(x: 10, y: 0), time: 0.1)
        trail.end(time: 0.1)
        XCTAssertFalse(trail.begin(at: .init(x: 100, y: 100), time: 0.2), "trail still visible: no new session tick")
        trail.end(time: 0.2)
        let segments = trail.segments(at: 0.3, levels: 1)[0]
        XCTAssertEqual(segments, [LaserSegment(start: .init(x: 0, y: 0), end: .init(x: 10, y: 0)),
                                  LaserSegment(start: .init(x: 100, y: 100), end: .init(x: 100, y: 100))])
        XCTAssertTrue(trail.begin(at: .init(x: 0, y: 0), time: 10), "after everything faded a new session starts")
    }

    func testDotModeOnlyKeepsAShortTailAndSamplesAreBounded() {
        var trail = LaserTrail(mode: .dot, fade: .long)
        trail.begin(at: .init(x: 0, y: 0), time: 0)
        for step in 1...(LaserTrail.maximumSamples + 50) { trail.move(to: .init(x: Double(step), y: 0), time: Double(step) * 0.001) }
        XCTAssertEqual(trail.samples.count, LaserTrail.maximumSamples)
        let now = Double(LaserTrail.maximumSamples + 50) * 0.001
        trail.prune(at: now)
        XCTAssertTrue(trail.samples.allSatisfy { now - $0.time < LaserTrail.dotTail })
        XCTAssertEqual(trail.pointer, .init(x: Double(LaserTrail.maximumSamples + 50), y: 0))
        XCTAssertEqual(trail.pointerOpacity(at: now + 100), 1, "dot stays while touching")
    }
}
