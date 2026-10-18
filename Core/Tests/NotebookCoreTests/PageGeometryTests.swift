import XCTest
@testable import NotebookCore

final class PageGeometryTests: XCTestCase {
    private let box = PageRect(x: 40, y: 70, width: 200, height: 300)

    func testCornerAnchorsForEveryPDFRotation() throws {
        let pdfCorners = [PagePoint(x: 40, y: 70), PagePoint(x: 240, y: 70),
                          PagePoint(x: 40, y: 370), PagePoint(x: 240, y: 370)]
        let expected: [[PagePoint]] = [
            [.init(x: 0, y: 300), .init(x: 200, y: 300), .init(x: 0, y: 0), .init(x: 200, y: 0)],
            [.init(x: 0, y: 0), .init(x: 0, y: 200), .init(x: 300, y: 0), .init(x: 300, y: 200)],
            [.init(x: 200, y: 0), .init(x: 0, y: 0), .init(x: 200, y: 300), .init(x: 0, y: 300)],
            [.init(x: 300, y: 200), .init(x: 300, y: 0), .init(x: 0, y: 200), .init(x: 0, y: 0)]
        ]
        for (i, rotation) in [0, 90, 180, 270].enumerated() {
            let geometry = try PDFPageGeometry(mediaBox: box, cropBox: box, rotation: rotation)
            XCTAssertEqual(pdfCorners.map(geometry.pdfToPage.apply), expected[i])
        }
    }

    func testCroppedRotatedPageRoundTripsThroughLegacyAndNativeLayouts() throws {
        let media = PageRect(x: -100, y: -100, width: 800, height: 1000)
        for rotation in [-90, 0, 90, 180, 270, 450] {
            let source = try PDFPageGeometry(mediaBox: media, cropBox: box, rotation: rotation)
            for legacy in [true, false] {
                let layout = PageLayout(source: source, legacyA4: legacy)
                for point in [PagePoint(x: 40, y: 70), PagePoint(x: 136.25, y: 242.75)] {
                    let restored = layout.pdfToCanvas.inverse.apply(layout.pdfToCanvas.apply(point))
                    XCTAssertEqual(restored.x, point.x, accuracy: 1e-9)
                    XCTAssertEqual(restored.y, point.y, accuracy: 1e-9)
                }
            }
        }
    }

    func testCropBoxIsClippedToMediaBoxBeforeRotation() throws {
        let media = PageRect(x: 10, y: 20, width: 100, height: 200)
        let crop = PageRect(x: -50, y: 50, width: 300, height: 300)
        let geometry = try PDFPageGeometry(mediaBox: media, cropBox: crop, rotation: 90)
        XCTAssertEqual(geometry.effectiveCrop, PageRect(x: 10, y: 50, width: 100, height: 170))
        XCTAssertEqual(geometry.displaySize, PageSize(width: 170, height: 100))
    }

    func testLegacyA4KeepsLetterboxMarginsAndNativePageKeepsItsSize() throws {
        let geometry = try PDFPageGeometry(mediaBox: box, cropBox: box, rotation: 90)
        let native = PageLayout(source: geometry, legacyA4: false)
        XCTAssertEqual(native.canvas, PageSize(width: 300, height: 200))
        let legacy = PageLayout(source: geometry, legacyA4: true)
        XCTAssertEqual(legacy.canvas, .a4)
        XCTAssertEqual(legacy.sourceFrame.width, 595, accuracy: 1e-9)
        XCTAssertEqual(legacy.sourceFrame.x, 0, accuracy: 1e-9)
        XCTAssertEqual(legacy.sourceFrame.y, (842 - 200 * 595.0 / 300) / 2, accuracy: 1e-9)
    }

    func testMalformedOrExcessivelyLargeGeometryIsRejected() {
        for bad in [PageRect(x: 0, y: 0, width: .infinity, height: 200),
                    PageRect(x: 0, y: 0, width: 0, height: 200),
                    PageRect(x: 0, y: 0, width: 20_000, height: 200)] {
            XCTAssertThrowsError(try PDFPageGeometry(mediaBox: bad, cropBox: bad, rotation: 0))
        }
        XCTAssertThrowsError(try PDFPageGeometry(mediaBox: box, cropBox: box, rotation: 45))
    }
}
