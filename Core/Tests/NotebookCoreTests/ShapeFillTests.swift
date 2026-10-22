import Foundation
import XCTest
@testable import NotebookCore

/// 22.10.2026: Füllfarbe unabhängig von der Strichfarbe und einstellbare
/// Deckkraft. Beides steckt im bestehenden `fill` (InkColor mit Alpha, Schema 6).
final class ShapeFillTests: XCTestCase {
    private func p(_ x: Double, _ y: Double) -> PagePoint { .init(x: x, y: y) }
    private let blue = InkColor(0, 0.48, 1)

    func testOwnFillColourAndStrengthKeepTheSchemaAndRoundtrip() throws {
        var book = Notebook(); book.schemaVersion = 12
        let stroke = InkColor(0, 0, 0)
        let rectangle = ShapeObject(kind: .rectangle, start: p(10, 10), end: p(90, 60), color: stroke)
            .filled(color: blue, opacity: 0.65)
        XCTAssertEqual(rectangle.fill, InkColor(0, 0.48, 1, 0.65))
        try book.replaceShapes([rectangle, ShapeObject(kind: .ellipse, start: p(100, 10), end: p(190, 60)).filled(color: nil, opacity: 1)],
                               pageID: book.pages[0].id)
        XCTAssertEqual(book.schemaVersion, 12, "fill needs no new schema")
        XCTAssertEqual(try Notebook.decode(JSONEncoder().encode(book)), book)
        var six = Notebook(); six.schemaVersion = 6
        try six.replaceShapes([rectangle], pageID: six.pages[0].id)
        XCTAssertEqual(six.schemaVersion, 6)
    }

    func testStrengthIsClampedAndRounded() {
        XCTAssertEqual(ShapeFill.color(blue, opacity: 0).alpha, 0.1)
        XCTAssertEqual(ShapeFill.color(blue, opacity: 3).alpha, 1)
        XCTAssertEqual(ShapeFill.color(blue, opacity: .nan).alpha, ShapeFill.defaultOpacity)
        XCTAssertEqual(ShapeFill.rounded(0.347), 0.35)
        XCTAssertEqual(ShapeFill.rounded(0.01), 0.1)
    }

    func testLinesAndArrowsStayUnfilled() {
        let line = ShapeObject(kind: .arrow, start: p(0, 0), end: p(50, 0))
        XCTAssertNil(line.filled(color: blue, opacity: 0.5).fill)
        XCTAssertFalse(line.isFillable)
        XCTAssertTrue(ShapeObject(kind: .polygon, vertices: [p(0, 0), p(40, 0), p(20, 30)]).isFillable)
    }

    func testStrokeColourChangeMovesOnlyAFollowingFill() {
        let black = InkColor(0, 0, 0), red = InkColor(1, 0.2, 0.2)
        // Older shapes: fill = stroke colour at 20 %. It follows, keeping its strength.
        let old = ShapeObject(kind: .rectangle, start: p(0, 0), end: p(40, 40), color: black, fill: InkColor(0, 0, 0, 0.2))
        XCTAssertTrue(old.fillFollowsStroke)
        XCTAssertEqual(old.recolored(red).fill, InkColor(1, 0.2, 0.2, 0.2))
        // Own fill colour stays when the stroke changes.
        let own = old.filled(color: blue, opacity: 0.5)
        XCTAssertFalse(own.fillFollowsStroke)
        XCTAssertEqual(own.recolored(red).fill, InkColor(0, 0.48, 1, 0.5))
        XCTAssertEqual(own.recolored(red).color, red)
        // Without own colour the strength is kept.
        XCTAssertEqual(own.filled(color: nil, opacity: nil).fill, InkColor(0, 0, 0, 0.5))
        XCTAssertNil(own.unfilled().fill)
    }

    func testVisibleFillNeedsStrengthAboveZero() {
        var shape = ShapeObject(kind: .ellipse, start: p(0, 0), end: p(40, 40), fill: InkColor(1, 0, 0, 0))
        XCTAssertFalse(shape.hasVisibleFill)
        shape.fill?.alpha = 0.1
        XCTAssertTrue(shape.hasVisibleFill)
        XCTAssertFalse(ShapeObject(kind: .line, start: p(0, 0), end: p(40, 0), fill: InkColor(1, 0, 0, 1)).hasVisibleFill)
    }

    func testToolbarFillPreferencesAreOptionalAndValidated() throws {
        let plain = ToolbarPreferences()
        let json = String(decoding: try JSONEncoder().encode(plain), as: UTF8.self)
        XCTAssertFalse(json.contains("shapeFill"), "untouched preferences keep their keys")
        XCTAssertEqual(plain.shapeFillColor(stroke: blue), InkColor(0, 0.48, 1, 0.2))
        var value = plain
        value.shapeFillColor = InkColor(1, 0.5, 0); value.shapeFillOpacity = 0.75
        try value.validate()
        XCTAssertEqual(try ToolbarPreferences.decode(JSONEncoder().encode(value)), value)
        XCTAssertEqual(value.shapeFillColor(stroke: blue), InkColor(1, 0.5, 0, 0.75))
        value.shapeFillOpacity = 0.05
        XCTAssertThrowsError(try value.validate())
        value.shapeFillOpacity = 1; value.shapeFillColor = InkColor(2, 0, 0)
        XCTAssertThrowsError(try value.validate())
    }
}
