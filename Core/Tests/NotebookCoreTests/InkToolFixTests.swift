import Foundation
import XCTest
@testable import NotebookCore

/// Fixes from the pen/pencil/highlighter audit: held strokes that ended
/// before PencilKit's final callback, out-of-gamut picker colours and the
/// pencil following „Ganzes Notizbuch umstellen“.
final class InkToolFixTests: XCTestCase {
    // MARK: Held stroke whose drawing arrived before the tool end

    func testEarlyDrawingThenToolEndAndLiftAwaitsFinalDrawing() {
        // drawing → tool end → lift: no further change comes.
        var gate = StrokeCompletionGate()
        gate.drawingChanged(); gate.endNative(); XCTAssertFalse(gate.awaitsFinalDrawing, "not lifted yet")
        gate.lift()
        XCTAssertFalse(gate.canCommit)
        XCTAssertTrue(gate.awaitsFinalDrawing)
        // A final change still arriving commits at once and ends the wait.
        gate.drawingChanged()
        XCTAssertTrue(gate.canCommit); XCTAssertFalse(gate.awaitsFinalDrawing)
    }
    func testEveryEarlyOrderAwaitsAndRegularOrdersCommitDirectly() {
        // lift → drawing → tool end and drawing → lift → tool end.
        for order in [["lift", "draw", "end"], ["draw", "lift", "end"], ["draw", "end", "lift"]] {
            var gate = StrokeCompletionGate()
            for step in order { apply(step, to: &gate) }
            XCTAssertFalse(gate.canCommit, "\(order)"); XCTAssertTrue(gate.awaitsFinalDrawing, "\(order)")
        }
        for order in [["end", "draw", "lift"], ["lift", "end", "draw"], ["end", "lift", "draw"]] {
            var gate = StrokeCompletionGate()
            for step in order { apply(step, to: &gate) }
            XCTAssertTrue(gate.canCommit, "\(order)"); XCTAssertFalse(gate.awaitsFinalDrawing, "\(order)")
        }
    }
    func testNoDrawingOrNoLiftNeverAwaits() {
        var gate = StrokeCompletionGate()
        gate.endNative(); gate.lift()
        XCTAssertFalse(gate.awaitsFinalDrawing, "a cancelled stroke without drawing keeps its freehand path")
        gate = StrokeCompletionGate(); gate.drawingChanged(); gate.endNative()
        XCTAssertFalse(gate.awaitsFinalDrawing, "Pencil still down (observer)")
    }
    private func apply(_ step: String, to gate: inout StrokeCompletionGate) {
        switch step {
        case "lift": gate.lift()
        case "end": gate.endNative()
        default: gate.drawingChanged()
        }
    }

    // MARK: Out-of-gamut colours

    func testClampedKeepsRangeAndRepairsOutOfGamutValues() {
        XCTAssertEqual(InkColor(0.2, 0.4, 0.6, 0.5).clamped, InkColor(0.2, 0.4, 0.6, 0.5))
        // Extended sRGB of a saturated P3 red/green from the system picker.
        XCTAssertEqual(InkColor(1.09, -0.23, -0.15).clamped, InkColor(1, 0, 0))
        XCTAssertEqual(InkColor(-0.1, 1.05, 0.2, 1.2).clamped, InkColor(0, 1, 0.2, 1))
        XCTAssertEqual(InkColor(.nan, .infinity, -.infinity, .nan).clamped, InkColor(0, 0, 0, 1))
    }
    func testPreferencesWithOutOfGamutColoursSaveAndLoadClamped() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ink-fix-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var preferences = ToolbarPreferences()
        preferences.penColor = InkColor(1.08, -0.2, -0.1)
        preferences.pencilColor = InkColor(-0.05, 1.04, 0.3)
        preferences.markerColor = InkColor(1.1, 1.02, -0.3, 1)
        preferences.shapeFillColor = InkColor(0.2, -0.01, 1.3)
        preferences.laserColor = InkColor(1.2, 0.1, 0.1)
        preferences.presets = [InkPreset(tool: .pen, color: InkColor(0.1, 1.2, -0.4), width: 2)]
        XCTAssertThrowsError(try preferences.validate(), "the strict check itself stays")
        let store = ToolbarPreferenceStore(root: root)
        _ = try await store.load()
        try await store.save(preferences, revision: 1)
        let data = try Data(contentsOf: root.appendingPathComponent("toolbar.json"))
        let loaded = try ToolbarPreferences.decode(data)
        XCTAssertEqual(loaded.penColor, InkColor(1, 0, 0))
        XCTAssertEqual(loaded.pencilColor, InkColor(0, 1, 0.3))
        XCTAssertEqual(loaded.markerColor, InkColor(1, 1, 0, 1))
        XCTAssertEqual(loaded.shapeFillColor, InkColor(0.2, 0, 1))
        XCTAssertEqual(loaded.laserColor, InkColor(1, 0.1, 0.1))
        XCTAssertEqual(loaded.presets.first?.color, InkColor(0.1, 1, 0))
        // Every stored value is what the independent archive check accepts.
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for key in ["penColor", "pencilColor", "markerColor", "shapeFillColor", "laserColor"] {
            let color = try XCTUnwrap(json[key] as? [String: Double], key)
            XCTAssertTrue(color.values.allSatisfy { (0...1).contains($0) }, key)
        }
    }
    func testLoadingToleratesOutOfRangeColoursButNotOtherDefects() throws {
        var preferences = ToolbarPreferences()
        preferences.penColor = InkColor(0.5, 0.5, 0.5)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(preferences)) as? [String: Any])
        json["penColor"] = ["red": 1.07, "green": -0.2, "blue": 0.5, "alpha": 1]
        let tolerated = try ToolbarPreferences.decode(JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(tolerated.penColor, InkColor(1, 0, 0.5))
        json["penWidth"] = 99
        XCTAssertThrowsError(try ToolbarPreferences.decode(JSONSerialization.data(withJSONObject: json)), "widths stay strict")
    }
    func testNotebookShapesStayStrict() {
        // Shapes/text in notebooks are normalised by the app before they enter
        // the model; the format check keeps refusing out-of-range colours.
        let shape = ShapeObject(kind: .line, start: PagePoint(x: 10, y: 10), end: PagePoint(x: 100, y: 10),
                                color: InkColor(1.1, -0.1, 0), lineWidth: 2)
        XCTAssertThrowsError(try shape.validate())
        var fixed = shape; fixed.color = shape.color.clamped
        XCTAssertNoThrow(try fixed.validate())
    }

    // MARK: Pencil follows „Ganzes Notizbuch umstellen“

    func testPencilFollowsPaperLikePenAndMarker() {
        var preferences = ToolbarPreferences()
        preferences.pencilColor = InkColor(0, 0, 0)
        preferences.followPaper(.dark)
        XCTAssertEqual(preferences.penColor, InkColor(1, 1, 1))
        XCTAssertEqual(preferences.pencilColor, InkColor(1, 1, 1), "black pencil would write black on black")
        preferences.followPaper(.white)
        XCTAssertEqual(preferences.penColor, InkColor(0, 0, 0))
        XCTAssertEqual(preferences.effectivePencilColor, ToolbarPreferences.defaultPencilColor, "back to graphite")
    }
    func testDefaultGraphiteTurnsWhiteOnDarkPaperAndColouredPencilStays() {
        var preferences = ToolbarPreferences()
        XCTAssertNil(preferences.pencilColor)
        preferences.followPaper(.dark)
        XCTAssertEqual(preferences.effectivePencilColor, InkColor(1, 1, 1), "graphite 0.23 is too dark on dark paper")
        preferences.followPaper(.dark)
        XCTAssertEqual(preferences.effectivePencilColor, InkColor(1, 1, 1), "idempotent")
        var blue = ToolbarPreferences(); blue.pencilColor = InkColor(0.1, 0.35, 0.8)
        blue.followPaper(.dark); XCTAssertEqual(blue.pencilColor, InkColor(0.1, 0.35, 0.8))
        blue.followPaper(.white); XCTAssertEqual(blue.pencilColor, InkColor(0.1, 0.35, 0.8))
        var graphite = ToolbarPreferences()
        graphite.followPaper(.white)
        XCTAssertNil(graphite.pencilColor, "white paper leaves the default graphite alone")
    }
}
