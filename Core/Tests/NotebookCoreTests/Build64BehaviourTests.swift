import XCTest
@testable import NotebookCore

/// Build 64 (docs/TEXT-REBUILD-62.md, „Verhalten und Objektbedienung
/// vereinheitlicht“): shared rules the editor, previews and export use alike.
final class Build64BehaviourTests: XCTestCase {
    func testOverflowUsesOneToleranceForEditorPreviewAndExport() {
        let box = TextBox(x: 10, y: 10, width: 100, height: 40, text: "Text")
        XCTAssertFalse(box.overflows(textHeight: 40))
        XCTAssertFalse(box.overflows(textHeight: 40 + TextBox.overflowTolerance))
        XCTAssertTrue(box.overflows(textHeight: 40 + TextBox.overflowTolerance + 0.01))
        XCTAssertTrue(box.overflows(textHeight: 80))
        XCTAssertFalse(box.overflows(textHeight: .nan))
        XCTAssertFalse(box.overflows(textHeight: .infinity))
    }
}

extension Build64BehaviourTests {
    /// A dense back-and-forth scribble across a line and a rectangle outline.
    private func scribble(over x: ClosedRange<Double>, y: ClosedRange<Double>) -> [PagePoint] {
        var points: [PagePoint] = []
        let rows = 14
        for row in 0...rows {
            let py = y.lowerBound + (y.upperBound - y.lowerBound) * Double(row) / Double(rows)
            let from = row.isMultiple(of: 2) ? x.lowerBound : x.upperBound, to = row.isMultiple(of: 2) ? x.upperBound : x.lowerBound
            for step in 0...6 { points.append(PagePoint(x: from + (to - from) * Double(step) / 6, y: py)) }
        }
        return points
    }

    func testScribbleRemovesCoveredShapesLikeStrokes() {
        let line = ShapeObject(kind: .line, start: PagePoint(x: 110, y: 120), end: PagePoint(x: 190, y: 130))
        let box = ShapeObject(kind: .rectangle, start: PagePoint(x: 120, y: 110), end: PagePoint(x: 180, y: 140))
        let far = ShapeObject(kind: .ellipse, start: PagePoint(x: 400, y: 400), end: PagePoint(x: 460, y: 440))
        let half = ShapeObject(kind: .line, start: PagePoint(x: 150, y: 125), end: PagePoint(x: 450, y: 125))
        let points = scribble(over: 100...200, y: 100...150)
        XCTAssertTrue(ScribbleErase.isScribble(points))
        let covered = Set(ScribbleErase.coveredShapes(scribble: points, shapes: [line, box, far, half], padding: 4))
        XCTAssertEqual(covered, [line.id, box.id])
    }
}
