import XCTest
import NotebookCore

/// A selection flush with a page edge: rounding in the page coordinates
/// (339.1 + 255.9, 470.8 + 124.2 against 595) must not act as a limit.
final class SelectionTransformEdgeTests: XCTestCase {
    private let page = PageRect(x: 0, y: 0, width: 595, height: 842)
    private let zero = PagePoint(x: 0, y: 0)

    func testScalingFromTheHandleOppositeAFlushRightEdge() {
        let frame = PageRect(x: 339.1, y: 100, width: 255.9, height: 50)
        let anchor = PagePoint(x: 339.1 + 255.9, y: 100 + 50)
        for requested in [1.2, 0.9] {
            let change = SelectionTransform(frame: frame, anchor: anchor, translation: zero, scale: requested,
                                            limits: page, minimumScale: 0.01, maximumScale: 100)
            XCTAssertEqual(change.scale, requested)
            XCTAssertEqual(change.translation.x, 0, accuracy: 1e-6)
            XCTAssertEqual(change.translation.y, 0, accuracy: 1e-6)
        }
        // The same frame 30 pt away from the edge never had the problem.
        let control = PageRect(x: 309.1, y: 100, width: 255.9, height: 50)
        XCTAssertEqual(SelectionTransform(frame: control, anchor: .init(x: 309.1 + 255.9, y: 150), translation: zero,
                                          scale: 1.2, limits: page).scale, 1.2)
    }

    func testScalingFromTheHandleOppositeAFlushBottomEdge() {
        let frame = PageRect(x: 100, y: 542.2, width: 80, height: 299.8)
        for requested in [1.2, 0.9] {
            XCTAssertEqual(SelectionTransform(frame: frame, anchor: .init(x: 100, y: 542.2 + 299.8), translation: zero,
                                              scale: requested, limits: page).scale, requested)
        }
    }

    /// The scale goes into font size, stroke width and image size: a move
    /// must hand out exactly 1, not 0.9999999999999999.
    func testMovingAFlushSelectionKeepsScaleExactlyOne() {
        let frame = PageRect(x: 470.8, y: 108.88, width: 124.2, height: 47.15)
        let change = SelectionTransform(frame: frame, anchor: .init(x: frame.x, y: frame.y), translation: .init(x: 0, y: 12),
                                        scale: 1, limits: page, minimumScale: 8.0 / 12, maximumScale: 8)
        XCTAssertEqual(change.scale, 1)
        XCTAssertEqual(change.translation, .init(x: 0, y: 12))
        // Every corner anchor, every edge of the page.
        for flush in [frame, PageRect(x: 0, y: 0, width: 124.2, height: 47.15),
                      PageRect(x: 470.8, y: 794.85, width: 124.2, height: 47.15), PageRect(x: 0.1, y: 0.3, width: 594.9, height: 841.7)] {
            for anchor in [PagePoint(x: flush.x, y: flush.y), .init(x: flush.x + flush.width, y: flush.y),
                           .init(x: flush.x + flush.width, y: flush.y + flush.height), .init(x: flush.x, y: flush.y + flush.height)] {
                let still = SelectionTransform(frame: flush, anchor: anchor, translation: zero, scale: 1, limits: page,
                                               minimumScale: 8.0 / 12, maximumScale: 8)
                XCTAssertEqual(still.scale, 1, "\(flush) \(anchor)")
                XCTAssertEqual(still.translation, zero, "\(flush) \(anchor)")
            }
        }
    }

    /// Growing towards the edge the selection already touches is a real limit: exactly 1.
    func testGrowingIntoTheFlushEdgeStopsAtExactlyOne() {
        let frame = PageRect(x: 470.8, y: 108.88, width: 124.2, height: 47.15)
        let change = SelectionTransform(frame: frame, anchor: .init(x: frame.x, y: frame.y), translation: zero,
                                        scale: 1.2, limits: page, minimumScale: 8.0 / 12, maximumScale: 8)
        XCTAssertEqual(change.scale, 1)
        // Shrinking away from it is free.
        XCTAssertEqual(SelectionTransform(frame: frame, anchor: .init(x: frame.x, y: frame.y), translation: zero,
                                          scale: 0.8, limits: page, minimumScale: 8.0 / 12, maximumScale: 8).scale, 0.8)
    }

    func testRealPageLimitsStillHoldTheContentInside() {
        let frame = PageRect(x: 100, y: 100, width: 200, height: 100)
        // From the top left corner the right edge is reached first: (595 - 100) / 200.
        let grown = SelectionTransform(frame: frame, anchor: .init(x: 100, y: 100), translation: zero, scale: 5, limits: page)
        XCTAssertEqual(grown.scale, 2.475, accuracy: 1e-12)
        // From the bottom right corner the left edge: 300 / 200.
        let back = SelectionTransform(frame: frame, anchor: .init(x: 300, y: 200), translation: zero, scale: 5, limits: page)
        XCTAssertEqual(back.scale, 1.5, accuracy: 1e-12)
        for change in [grown, back] {
            let a = change.apply(.init(x: frame.x, y: frame.y)), b = change.apply(.init(x: frame.x + frame.width, y: frame.y + frame.height))
            XCTAssertGreaterThanOrEqual(a.x, -1e-6); XCTAssertGreaterThanOrEqual(a.y, -1e-6)
            XCTAssertLessThanOrEqual(b.x, 595 + 1e-6); XCTAssertLessThanOrEqual(b.y, 842 + 1e-6)
        }
        // A frame 0.5 pt from the edge is limited by that half point, not let through as rounding.
        let near = PageRect(x: 339.1, y: 100, width: 255.4, height: 50)
        let limited = SelectionTransform(frame: near, anchor: .init(x: 339.1, y: 100), translation: zero, scale: 1.2, limits: page)
        XCTAssertEqual(limited.scale, 255.9 / 255.4, accuracy: 1e-9)
        // The format limits stay as they were.
        XCTAssertEqual(SelectionTransform(frame: frame, anchor: .init(x: 100, y: 100), translation: zero, scale: 5,
                                          limits: page, minimumScale: 0.5, maximumScale: 2).scale, 2)
        XCTAssertEqual(SelectionTransform(frame: frame, anchor: .init(x: 100, y: 100), translation: zero, scale: 0.1,
                                          limits: page, minimumScale: 0.5, maximumScale: 2).scale, 0.5)
    }

    func testMovesOfAFlushSelectionStillStopAtThePage() {
        let frame = PageRect(x: 470.8, y: 108.88, width: 124.2, height: 47.15)
        let out = SelectionTransform(frame: frame, anchor: .init(x: frame.x, y: frame.y), translation: .init(x: 5, y: 900),
                                     scale: 1, limits: page)
        XCTAssertEqual(out.scale, 1)
        XCTAssertEqual(out.translation.x, 0, accuracy: 1e-6)
        XCTAssertEqual(out.translation.y, 842 - 108.88 - 47.15, accuracy: 1e-6)
        let back = SelectionTransform(frame: frame, anchor: .init(x: frame.x, y: frame.y), translation: .init(x: -500, y: -200),
                                      scale: 1, limits: page)
        XCTAssertEqual(back.translation.x, -470.8, accuracy: 1e-6)
        XCTAssertEqual(back.translation.y, -108.88, accuracy: 1e-6)
    }
}
