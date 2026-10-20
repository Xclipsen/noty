import Foundation
import XCTest
@testable import NotebookCore

/// Build 45: round highlighter tip as an optional format-8 field.
final class MarkerTipTests: XCTestCase {
    /// Literal format-8 file as written by Build 44 (no tip key).
    private let build44 = Data("""
    {"formatVersion":8,"dock":"top","order":["pen","pencil","marker","strokeEraser","text","selection","shape","image","read","laser","precisionEraser","inkSelection"],
     "penColor":{"red":0,"green":0,"blue":0,"alpha":1},"markerColor":{"red":1,"green":0.5,"blue":0,"alpha":0.8},
     "penWidth":2,"markerWidth":20,"eraserWidth":16,"fingerDrawing":false,"markerStraight":true,
     "floatingX":0,"floatingY":0,"presets":[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","tool":"marker","color":{"red":1,"green":1,"blue":0,"alpha":1},"width":14}]}
    """.utf8)

    func testBuild44PreferencesHighlightRoundByDefaultWithoutChangingTheFile() throws {
        let value = try ToolbarPreferences.decode(build44)
        XCTAssertEqual(value.formatVersion, 8)
        XCTAssertNil(value.markerTip); XCTAssertNil(value.presets[0].markerTip)
        XCTAssertEqual(value.effectiveMarkerTip, .round)
        XCTAssertEqual(value.markerStraight, true)
        XCTAssertEqual(value.markerStrokeColor.red, 1); XCTAssertEqual(value.markerStrokeColor.green, 0.5)
        XCTAssertEqual(value.markerStrokeColor.alpha, 0.8 * MarkerInk.roundOpacity, accuracy: 1e-12)
        // Untouched, the key is never written (older format-8 builds see the same file).
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(value), as: UTF8.self).contains("markerTip"))
        XCTAssertEqual(ToolbarPreferences().effectiveMarkerTip, .round)
    }

    /// Build 50: the highlighter's hold switch is its own key; pen shapes stay on.
    func testMarkerHoldStraightenIsSeparateFromPenShapeRecognition() throws {
        var value = try ToolbarPreferences.decode(build44)
        XCTAssertNil(value.markerHoldStraighten); XCTAssertNil(value.recognizeShapes)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(value), as: UTF8.self).contains("markerHoldStraighten"))
        value.markerHoldStraighten = false
        let decoded = try ToolbarPreferences.decode(JSONEncoder().encode(value))
        XCTAssertEqual(decoded.markerHoldStraighten, false)
        XCTAssertNil(decoded.recognizeShapes)
    }

    func testChiselTipKeepsTheNativeMarkerOpacityAndRoundTrips() throws {
        var value = try ToolbarPreferences.decode(build44)
        value.markerTip = .chisel
        XCTAssertEqual(value.markerStrokeColor.alpha, 0.8 * MarkerStraightening.opacityFactor, accuracy: 1e-12)
        XCTAssertEqual(MarkerInk.opacity(for: .chisel), MarkerStraightening.opacityFactor)
        XCTAssertLessThan(MarkerInk.roundOpacity, 0.5, "round strokes composite normally: text below must stay readable")
        value.presets.append(InkPreset(tool: .marker, color: InkColor(0.45, 0.8, 1), width: 22, markerTip: .round))
        let data = try JSONEncoder().encode(value)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("\"markerTip\":\"chisel\""))
        let decoded = try ToolbarPreferences.decode(data)
        XCTAssertEqual(decoded, value)
        XCTAssertEqual(decoded.formatVersion, 8, "optional field, no format change")
        XCTAssertEqual(decoded.presets.map(\.markerTip), [nil, .round])
    }

    func testTipIsRejectedOutsideFormatEightMarkersAndUnknownTipsAreNotGuessed() throws {
        let text = String(decoding: build44, as: UTF8.self)
        func patched(_ old: String, _ new: String) -> Data { Data(text.replacingOccurrences(of: old, with: new).utf8) }
        XCTAssertNoThrow(try ToolbarPreferences.decode(patched("\"markerStraight\":true", "\"markerStraight\":true,\"markerTip\":\"chisel\"")))
        XCTAssertThrowsError(try ToolbarPreferences.decode(patched("\"markerStraight\":true", "\"markerStraight\":true,\"markerTip\":\"brush\"")))
        XCTAssertThrowsError(try ToolbarPreferences.decode(patched("\"width\":14}", "\"width\":14,\"markerTip\":\"felt\"}")))
        // A pen favourite has no highlighter tip.
        XCTAssertThrowsError(try ToolbarPreferences.decode(patched("\"tool\":\"marker\"", "\"tool\":\"pen\"")
            .replacingTip()))
        var value = ToolbarPreferences()
        value.presets = [InkPreset(tool: .pencil, color: InkColor(0, 0, 0), width: 3, markerTip: .round)]
        XCTAssertThrowsError(try value.validate())
        // Format 7 never had the field; it cannot masquerade as an older file.
        let format7 = """
        {"formatVersion":7,"dock":"top","order":["pen","marker","strokeEraser","text","selection","shape","image","read","precisionEraser","inkSelection"],
         "penColor":{"red":0,"green":0,"blue":0,"alpha":1},"markerColor":{"red":1,"green":1,"blue":0,"alpha":1},
         "penWidth":2,"markerWidth":14,"eraserWidth":16,"fingerDrawing":false,"floatingX":0,"floatingY":0,"presets":[]}
        """
        XCTAssertNoThrow(try ToolbarPreferences.decode(Data(format7.utf8)))
        XCTAssertThrowsError(try ToolbarPreferences.decode(Data(format7.replacingOccurrences(of: "\"fingerDrawing\":false", with: "\"fingerDrawing\":false,\"markerTip\":\"round\"").utf8)))
    }

    func testChangingTheTipCommitsInPlaceKeepingThePreviousFile() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try build44.write(to: root.appendingPathComponent("toolbar.json"))
        let store = ToolbarPreferenceStore(root: root)
        var value = try await store.load().0
        value.markerTip = .chisel
        try await store.save(value, revision: 1)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("toolbar-previous.json")), build44)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("toolbar-format8.json").path))
        let reloaded = try await ToolbarPreferenceStore(root: root).load().0
        XCTAssertEqual(reloaded.effectiveMarkerTip, .chisel)
    }
}

private extension Data {
    /// Gives the (now pen) favourite of the Build-44 sample a highlighter tip.
    func replacingTip() -> Data {
        Data(String(decoding: self, as: UTF8.self).replacingOccurrences(of: "\"width\":14}", with: "\"width\":10,\"markerTip\":\"round\"}").utf8)
    }
}
