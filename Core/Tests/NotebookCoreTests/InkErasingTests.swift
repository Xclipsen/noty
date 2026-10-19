import Foundation
import XCTest
@testable import NotebookCore

final class InkErasingTests: XCTestCase {
    /// Back-and-forth passes along x between `from` and `to`, drifting slowly downwards.
    private func scribble(from: Double = 100, to: Double = 200, y: Double = 100, passes: Int = 8, drift: Double = 2) -> [PagePoint] {
        var points: [PagePoint] = []
        for pass in 0..<passes {
            let forward = pass % 2 == 0
            for i in 0...25 {
                let t = Double(i) / 25
                points.append(.init(x: forward ? from + (to - from) * t : to - (to - from) * t, y: y + Double(pass) * drift + sin(t * .pi) * 3))
            }
        }
        return points
    }
    private func stroke(_ corners: [PagePoint]) -> [PagePoint] {
        zip(corners, corners.dropFirst()).flatMap { a, b in (0..<10).map { i -> PagePoint in
            let t = Double(i) / 10; return PagePoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t) } } + [corners.last!]
    }
    private func word(_ x: Double, _ y: Double) -> [PagePoint] {
        (0...30).map { i -> PagePoint in let t = Double(i); return .init(x: x + t * 2, y: y + sin(t / 3) * 6) }
    }

    func testScribbleIsRecognisedAndErasesTheWordBelow() {
        let stroke = scribble()
        XCTAssertTrue(ScribbleErase.isScribble(stroke))
        XCTAssertTrue(ScribbleErase.isScribble(scribble(from: 300, to: 100, passes: 6)))
        let below = word(120, 105), elsewhere = word(400, 300)
        let underline = (0...60).map { PagePoint(x: 20 + Double($0) * 6, y: 112) }
        XCTAssertEqual(ScribbleErase.coveredStrokes(scribble: stroke, strokes: [below, elsewhere, underline], padding: 4), [0])
    }
    func testWritingAndLinesAreNoScribbles() {
        // "mmm": arches progressing along the line.
        XCTAssertFalse(ScribbleErase.isScribble((0...90).map { i -> PagePoint in PagePoint(x: Double(i) * 2, y: 100 - abs(sin(Double(i) / 10)) * 30) }))
        // "www": V shapes progressing along the line.
        XCTAssertFalse(ScribbleErase.isScribble((0...120).map { i -> PagePoint in
            let t = Double(i); return PagePoint(x: t * 1.5, y: 100 + abs((t.truncatingRemainder(dividingBy: 20)) - 10) * 2.5)
        }))
        // Cursive loops "llll".
        XCTAssertFalse(ScribbleErase.isScribble((0...160).map { i -> PagePoint in
            let t = Double(i) / 160 * 8 * .pi; return PagePoint(x: 100 + t * 4 + 6 * sin(t), y: 100 - 15 * (1 - cos(t)))
        }))
        // Letters with up/down strokes: "N", wide "M", "W", a wave "~~~" and an "e"-chain.
        XCTAssertFalse(ScribbleErase.isScribble(stroke([.init(x: 100, y: 130), .init(x: 100, y: 100), .init(x: 120, y: 130), .init(x: 120, y: 100)])))
        XCTAssertFalse(ScribbleErase.isScribble(stroke([.init(x: 100, y: 130), .init(x: 110, y: 100), .init(x: 125, y: 125), .init(x: 140, y: 100), .init(x: 150, y: 130)])))
        XCTAssertFalse(ScribbleErase.isScribble(stroke([.init(x: 100, y: 100), .init(x: 112, y: 130), .init(x: 125, y: 105), .init(x: 138, y: 130), .init(x: 150, y: 100)])))
        XCTAssertFalse(ScribbleErase.isScribble((0...150).map { i -> PagePoint in PagePoint(x: 100 + Double(i), y: 100 + sin(Double(i) / 8) * 10) }))
        XCTAssertFalse(ScribbleErase.isScribble((0...160).map { i -> PagePoint in
            let t = Double(i) / 160 * 6 * .pi; return PagePoint(x: 100 + t * 5 - 7 * sin(t), y: 100 - 8 * (1 - cos(t)))
        }))
        // Three quick passes are enough for a real scribble.
        XCTAssertTrue(ScribbleErase.isScribble(scribble(passes: 4)))
        // A single back-and-forth line and a long zig-zag line across the page.
        XCTAssertFalse(ScribbleErase.isScribble(scribble(passes: 2)))
        XCTAssertFalse(ScribbleErase.isScribble(scribble(passes: 3)))
        XCTAssertFalse(ScribbleErase.isScribble((0...200).map { i -> PagePoint in PagePoint(x: Double(i) * 3, y: 100 + (i % 10 < 5 ? 0 : 20)) }))
        XCTAssertFalse(ScribbleErase.isScribble([]))
    }
    func testShadingOverEmptyPaperErasesNothing() {
        let hatch = scribble(from: 300, to: 380, y: 400, passes: 12, drift: 3)
        XCTAssertTrue(ScribbleErase.isScribble(hatch))
        XCTAssertEqual(ScribbleErase.coveredStrokes(scribble: hatch, strokes: [word(100, 100)], padding: 4), [])
        XCTAssertEqual(ScribbleErase.coveredStrokes(scribble: hatch, strokes: [], padding: 4), [])
    }
    func testSweptEraserCapsuleHitsStrokes() {
        let stroke = [PagePoint(x: 0, y: 0), .init(x: 100, y: 0)]
        XCTAssertTrue(StrokeHitTest.hits(sweep: .init(x: 50, y: -20), .init(x: 50, y: 20), radius: 1, stroke: stroke), "crossing")
        XCTAssertTrue(StrokeHitTest.hits(sweep: .init(x: 50, y: 5), .init(x: 60, y: 5), radius: 6, stroke: stroke))
        XCTAssertFalse(StrokeHitTest.hits(sweep: .init(x: 50, y: 8), .init(x: 60, y: 8), radius: 6, stroke: stroke))
        XCTAssertTrue(StrokeHitTest.hits(sweep: .init(x: 103, y: 0), .init(x: 103, y: 0), radius: 4, stroke: stroke), "tap near the end")
        XCTAssertTrue(StrokeHitTest.hits(sweep: .init(x: 0, y: 3), .init(x: 0, y: 3), radius: 4, stroke: [.init(x: 0, y: 0)]), "dot")
        XCTAssertFalse(StrokeHitTest.hits(sweep: .init(x: 0, y: 3), .init(x: 0, y: 3), radius: 4, stroke: []))
    }
}
