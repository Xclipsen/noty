import XCTest
@testable import NotebookCore

final class TextCursorGeometryTests: XCTestCase {
    func testBeamFollowsVisibleTextHeight() {
        // 12 pt body text (about 14.3 pt glyphs) at fit zoom 1.6.
        XCTAssertEqual(TextCursorGeometry.beamLength(textHeight: 14.3, screenScale: 1.6), 22.88, accuracy: 0.001)
    }

    func testBeamIsLimited() {
        // Title at maximum zoom, margin text in tiny units, broken values.
        XCTAssertEqual(TextCursorGeometry.beamLength(textHeight: 33, screenScale: 6), TextCursorGeometry.maximumBeam)
        XCTAssertEqual(TextCursorGeometry.beamLength(textHeight: 9, screenScale: 0.5), TextCursorGeometry.minimumBeam)
        XCTAssertEqual(TextCursorGeometry.beamLength(textHeight: .nan, screenScale: 2), TextCursorGeometry.minimumBeam)
        XCTAssertEqual(TextCursorGeometry.beamLength(textHeight: 14, screenScale: .infinity), TextCursorGeometry.minimumBeam)
    }

    func testRegionContainsPointerAndHoldsTheBeam() {
        for scale in [0.4, 1, 1.7, 6] {
            for point in [PagePoint(x: 0, y: 0), PagePoint(x: 123.4, y: 56.7), PagePoint(x: -20.5, y: -3)] {
                let length = TextCursorGeometry.beamLength(textHeight: 14, screenScale: scale)
                let region = TextCursorGeometry.beamRegion(containing: point, length: length, screenScale: scale)
                XCTAssertTrue(point.x >= region.x && point.x < region.x + region.width, "x \(point) \(scale)")
                XCTAssertTrue(point.y >= region.y && point.y < region.y + region.height, "y \(point) \(scale)")
                XCTAssertGreaterThanOrEqual(region.height * scale, length)
            }
        }
    }

    func testRegionIsStableWithinItsCell() {
        let a = TextCursorGeometry.beamRegion(containing: PagePoint(x: 10.2, y: 10.1), length: 20, screenScale: 2)
        let b = TextCursorGeometry.beamRegion(containing: PagePoint(x: 10.9, y: 11.4), length: 20, screenScale: 2)
        XCTAssertEqual(a, b)
    }

    func testCaretKeepsGlyphBandAndLimitsLineFragment() {
        // Ruled paper: a fragment two rulings tall, the text at its bottom.
        let limited = TextCursorGeometry.limitedCaret(top: 100, height: 48, fontHeight: 14)
        XCTAssertEqual(limited.top, 134); XCTAssertEqual(limited.height, 14)
        // A caret about as tall as the font stays.
        let normal = TextCursorGeometry.limitedCaret(top: 100, height: 16.5, fontHeight: 14)
        XCTAssertEqual(normal.top, 100); XCTAssertEqual(normal.height, 16.5)
        let unknown = TextCursorGeometry.limitedCaret(top: 5, height: 40, fontHeight: 0)
        XCTAssertEqual(unknown.top, 5); XCTAssertEqual(unknown.height, 40)
    }
}
