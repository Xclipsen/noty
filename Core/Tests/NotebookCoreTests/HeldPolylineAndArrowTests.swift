import Foundation
import XCTest
@testable import NotebookCore

/// Nutzer nach dem ersten Tag: Pfeile mit dem Stift (auch mit Haken als
/// Spitze), Formen mit Ecken (Polylinien, Knickpfeile), einzeln ziehbare
/// Ankerpunkte; Schema 13 für Polylinien/Polygone.
final class HeldPolylineAndArrowTests: XCTestCase {
    /// Hand-like open stroke through `corners`: dense samples plus a small deterministic wobble.
    private func stroke(_ corners: [PagePoint], wobble: Double = 1.2, step: Double = 3) -> [PagePoint] {
        var result: [PagePoint] = [], index = 0
        for (a, b) in zip(corners, corners.dropFirst()) {
            let count = max(1, Int(hypot(b.x - a.x, b.y - a.y) / step))
            for i in 0..<count {
                let t = Double(i) / Double(count); index += 1
                result.append(.init(x: a.x + (b.x - a.x) * t + sin(Double(index) * 1.7) * wobble,
                                    y: a.y + (b.y - a.y) * t + cos(Double(index) * 2.3) * wobble))
            }
        }
        return result + [corners.last!]
    }
    private func p(_ x: Double, _ y: Double) -> PagePoint { .init(x: x, y: y) }

    // MARK: Pfeile

    func testArrowWithTwoWingsDrawnThroughTheTip() throws {
        let points = stroke([p(100, 300), p(300, 304), p(282, 290), p(300, 304), p(283, 318)])
        guard case let .arrow(start, tip)? = ShapeRecognition.shape(points) else { return XCTFail("\(String(describing: ShapeRecognition.shape(points)))") }
        XCTAssertEqual(start.x, 100, accuracy: 3)
        XCTAssertEqual(tip.y, start.y, accuracy: 1e-9, "snapped level")
        XCTAssertEqual(tip.x, 300, accuracy: 4)
    }

    func testArrowWithASingleHook() throws {
        // Shaft upwards, then one barb back down-left: the hook in the same stroke.
        let points = stroke([p(200, 400), p(203, 180), p(188, 200)])
        guard case let .arrow(start, tip)? = ShapeRecognition.shape(points) else { return XCTFail("\(String(describing: ShapeRecognition.shape(points)))") }
        XCTAssertEqual(start.y, 400, accuracy: 3)
        XCTAssertEqual(tip.x, start.x, accuracy: 1e-9, "snapped plumb")
        XCTAssertEqual(tip.y, 180, accuracy: 4)
    }

    func testArrowWithAnOpenHeadAndDiagonalShaft() throws {
        // Tip, then wing, then across to the other wing ("<" without returning).
        let points = stroke([p(100, 100), p(250, 250), p(222, 248), p(248, 222)])
        guard case let .arrow(start, tip)? = ShapeRecognition.shape(points) else { return XCTFail("\(String(describing: ShapeRecognition.shape(points)))") }
        XCTAssertEqual(tip.x - start.x, tip.y - start.y, accuracy: 1e-6, "45° snap")
        XCTAssertEqual(tip.x, 250, accuracy: 5)
    }

    func testArrowWithItsHeadDrawnFirst() throws {
        // Wing, tip, other wing, back to the tip, then the shaft away from it.
        let points = stroke([p(282, 286), p(300, 300), p(282, 315), p(300, 300), p(100, 300)])
        guard case let .arrow(start, tip)? = ShapeRecognition.shape(points) else { return XCTFail("\(String(describing: ShapeRecognition.shape(points)))") }
        XCTAssertEqual(start.x, 100, accuracy: 3)
        XCTAssertEqual(tip.x, 300, accuracy: 4)
    }

    func testBentArrowBecomesAPolylineWithItsHead() throws {
        let points = stroke([p(100, 100), p(102, 300), p(330, 297), p(312, 284), p(330, 297), p(312, 312)])
        guard case let .polyline(vertices, arrow)? = ShapeRecognition.shape(points) else { return XCTFail("\(String(describing: ShapeRecognition.shape(points)))") }
        XCTAssertTrue(arrow)
        XCTAssertEqual(vertices.count, 3)
        XCTAssertEqual(vertices[0].x, vertices[1].x, accuracy: 1e-6, "first leg plumb")
        XCTAssertEqual(vertices[1].y, vertices[2].y, accuracy: 1e-6, "second leg level")
        XCTAssertEqual(vertices[1].x, 101, accuracy: 4); XCTAssertEqual(vertices[1].y, 298, accuracy: 4)
        XCTAssertEqual(vertices[2].x, 330, accuracy: 5)
        let object = try XCTUnwrap(ShapeRecognition.shape(points)?.object(color: InkColor(0, 0, 0), lineWidth: 2))
        XCTAssertEqual(object.kind, .arrow); XCTAssertEqual(object.points, vertices)
        XCTAssertNoThrow(try object.validate())
        XCTAssertTrue(object.usesVertexFormat)
        XCTAssertEqual(ShapeRecognition.recognize(points), .arrow)
    }

    func testArrowsInEveryDirectionAndHeadStyle() {
        for angle in stride(from: 0.0, to: 360, by: 30) {
            for (shaft, ratio) in [(120.0, 0.2), (250, 0.3), (400, 0.12)] {
                let r = angle * .pi / 180, u = (x: cos(r), y: sin(r)), n = (x: -sin(r), y: cos(r))
                let s = p(300, 300), t = p(300 + u.x * shaft, 300 + u.y * shaft)
                let w = shaft * ratio, back = cos(0.5) * w, side = sin(0.5) * w
                let w1 = p(t.x - u.x * back + n.x * side, t.y - u.y * back + n.y * side)
                let w2 = p(t.x - u.x * back - n.x * side, t.y - u.y * back - n.y * side)
                for (name, corners) in [("wings", [s, t, w1, t, w2]), ("hook", [s, t, w1]), ("open", [s, t, w1, w2]), ("head first", [w1, t, w2, t, s])] {
                    guard case let .arrow(start, tip)? = ShapeRecognition.shape(stroke(corners, wobble: 1, step: 2.5)) else {
                        XCTFail("\(name) \(angle)° \(shaft)"); continue
                    }
                    XCTAssertEqual(hypot(tip.x - t.x, tip.y - t.y), 0, accuracy: 6, "\(name) \(angle)° tip")
                    XCTAssertEqual(hypot(start.x - s.x, start.y - s.y), 0, accuracy: 3, "\(name) \(angle)° start")
                }
            }
        }
    }

    func testClosedShapesInEveryDirectionStayClosed() {
        for angle in stride(from: 0.0, to: 360, by: 30) {
            let r = angle * .pi / 180
            func turned(_ q: PagePoint) -> PagePoint { p(300 + (q.x - 300) * cos(r) - (q.y - 300) * sin(r), 300 + (q.x - 300) * sin(r) + (q.y - 300) * cos(r)) }
            for over in [0.0, 0.3] {
                let triangle = [p(200, 380), p(400, 380), p(300, 207)].map(turned)
                let a = p(triangle[0].x + (triangle[1].x - triangle[0].x) * over, triangle[0].y + (triangle[1].y - triangle[0].y) * over)
                guard case .polygon? = ShapeRecognition.shape(stroke(triangle + [triangle[0], a], wobble: 2)) else { XCTFail("triangle \(angle)° \(over)"); continue }
                let square = [p(200, 200), p(400, 200), p(400, 400), p(200, 400)].map(turned)
                let b = p(square[0].x + (square[1].x - square[0].x) * over, square[0].y + (square[1].y - square[0].y) * over)
                guard case .polygon? = ShapeRecognition.shape(stroke(square + [square[0], b], wobble: 2)) else { XCTFail("square \(angle)° \(over)"); continue }
            }
            if case .polygon? = ShapeRecognition.shape(stroke([p(150, 200), p(400, 200), p(150, 380), p(400, 380)].map(turned), wobble: 2)) {
                XCTFail("open Z \(angle)° closed")
            }
        }
    }

    // MARK: Polylinien

    func testOpenStrokesWithCornersBecomePolylines() throws {
        guard case let .polyline(l, false)? = ShapeRecognition.shape(stroke([p(100, 100), p(100, 300), p(260, 300)])) else { return XCTFail("L") }
        XCTAssertEqual(l.count, 3)
        XCTAssertEqual(l[1].x, 100, accuracy: 3); XCTAssertEqual(l[1].y, 300, accuracy: 3)
        XCTAssertEqual(l[0].x, l[1].x, accuracy: 1e-6); XCTAssertEqual(l[1].y, l[2].y, accuracy: 1e-6)
        guard case let .polyline(z, false)? = ShapeRecognition.shape(stroke([p(100, 100), p(300, 100), p(100, 260), p(300, 260)])) else { return XCTFail("Z") }
        XCTAssertEqual(z.count, 4)
        // An open "V" with an acute angle.
        guard case let .polyline(v, false)? = ShapeRecognition.shape(stroke([p(100, 100), p(160, 300), p(220, 110)])) else { return XCTFail("V") }
        XCTAssertEqual(v.count, 3)
        // A "U" whose opening is too wide to close.
        guard case let .polyline(u, false)? = ShapeRecognition.shape(stroke([p(100, 100), p(100, 260), p(300, 260), p(300, 100)])) else { return XCTFail("U") }
        XCTAssertEqual(u.count, 4)
        let object = try XCTUnwrap(RecognizedShape.polyline(u, arrow: false).object(color: InkColor(0, 0, 0), lineWidth: 2))
        XCTAssertEqual(object.kind, .line); XCTAssertEqual(object.vertices, u)
    }

    func testStraightAndWavyLinesStayLinesAndCurvesStayFreehand() {
        if case .polyline? = ShapeRecognition.shape(stroke([p(100, 100), p(400, 112)], wobble: 3)) { XCTFail("wavy line") }
        // A gentle bend (< 40°) of a line-like stroke stays a straight line (hold fallback).
        let bent = stroke([p(100, 100), p(250, 100), p(400, 140)])
        if case .polyline? = ShapeRecognition.shape(bent) { XCTFail("gentle bend") }
        XCTAssertTrue(ShapeRecognition.lineAfterHold(bent))
        // An arc is no polyline.
        let arc = (0...60).map { i -> PagePoint in let t = Double(i) / 60 * .pi; return p(200 + 100 * cos(t), 300 - 100 * sin(t)) }
        XCTAssertNil(ShapeRecognition.shape(arc))
    }

    func testClosedShapesWithOvershootStayClosed() {
        // Triangle drawn closed with a 25 % overshoot along its first side.
        let a = p(100, 300), b = p(300, 300), c = p(200, 127)
        let overshoot = p(a.x + (b.x - a.x) * 0.25, a.y + (b.y - a.y) * 0.25)
        guard case .polygon? = ShapeRecognition.shape(stroke([a, b, c, a, overshoot], wobble: 1.5)) else { return XCTFail("triangle") }
        let square = stroke([p(100, 100), p(250, 100), p(250, 250), p(100, 250), p(100, 100), p(140, 100)])
        guard case .polygon? = ShapeRecognition.shape(square) else { return XCTFail("square") }
    }

    func testRotatedPolygonsBecomeEditablePolygons() throws {
        let corners = [(-100.0, -40.0), (100, -40), (100, 40), (-100, 40)], r = 20 * Double.pi / 180
        let rotated = corners.map { c in p(300 + c.0 * cos(r) - c.1 * sin(r), 300 + c.0 * sin(r) + c.1 * cos(r)) }
        let shape = ShapeRecognition.shape(stroke(rotated + [rotated[0]]))
        guard case let .polygon(_, vertices)? = shape else { return XCTFail("rotated rectangle") }
        let object = try XCTUnwrap(shape?.object(color: InkColor(0, 0, 0), lineWidth: 2))
        XCTAssertEqual(object.kind, .polygon); XCTAssertEqual(object.vertices, vertices)
        XCTAssertNoThrow(try object.validate())
        XCTAssertEqual(object.strokeLines.count, 1); XCTAssertTrue(object.strokeLines[0].closed)
    }

    // MARK: Halten und Nachziehen

    func testHeldPolylineMovesItsLastVertexWithTheTip() {
        let base = RecognizedShape.polyline([p(0, 0), p(0, 100), p(100, 100)], arrow: true)
        // The tip rested 10 pt behind the head; the end moves by the offset and snaps level.
        let held = HeldShapeAdjustment(shape: base, grab: p(90, 108))
        XCTAssertEqual(held.shape(at: p(91, 108)), base)
        guard case let .polyline(moved, true) = held.shape(at: p(150, 111)) else { return XCTFail() }
        XCTAssertEqual(Array(moved.prefix(2)), [p(0, 0), p(0, 100)])
        XCTAssertEqual(moved[2].y, 100, "snapped level"); XCTAssertEqual(moved[2].x, hypot(160, 3), accuracy: 1e-9)
        // Collapsing the last segment keeps the shape.
        XCTAssertEqual(held.shape(at: p(-8, 108)), base)
        XCTAssertEqual(HeldShapeFitting.fit(base, in: PageRect(x: 10, y: 10, width: 500, height: 500), padding: 2),
                       .polyline([p(12, 12), p(12, 112), p(112, 112)], arrow: true))
    }

    func testInkOutlineOfArrowsCarriesTheHead() {
        let outline = RecognizedShape.arrow(start: p(0, 0), tip: p(100, 0)).outline(spacing: 10, headLength: 20)
        XCTAssertTrue(outline.contains { $0.x < 100 && $0.y > 5 }, "lower wing")
        XCTAssertTrue(outline.contains { $0.x < 100 && $0.y < -5 }, "upper wing")
        let bent = RecognizedShape.polyline([p(0, 0), p(0, 100), p(100, 100)], arrow: true).outline(spacing: 10, headLength: 20)
        XCTAssertEqual(bent.first, p(0, 0))
        XCTAssertEqual(bent.filter { $0 == p(0, 100) }.count, 3, "sharp corner")
        XCTAssertTrue(bent.contains { $0.x < 100 && $0.y > 105 })
    }

    // MARK: Ankerpunkte

    func testAnchorsOfEveryKindMoveOnTheirOwn() throws {
        let line = ShapeObject(kind: .line, start: p(0, 0), end: p(100, 0))
        XCTAssertEqual(line.anchors, [p(0, 0), p(100, 0)])
        XCTAssertEqual(line.movingAnchor(1, to: p(80, 40))?.end, p(80, 40))
        XCTAssertFalse(line.movingAnchor(1, to: p(80, 40))!.usesVertexFormat, "a moved end stays schema 6")
        XCTAssertNil(line.movingAnchor(0, to: p(100, 0)), "zero length")

        let polyline = ShapeObject(kind: .arrow, vertices: [p(0, 0), p(0, 100), p(100, 100)])
        XCTAssertEqual(polyline.anchors.count, 3)
        let bent = try XCTUnwrap(polyline.movingAnchor(1, to: p(30, 120)))
        XCTAssertEqual(bent.points, [p(0, 0), p(30, 120), p(100, 100)]); XCTAssertEqual(bent.start, p(0, 0))
        let tip = try XCTUnwrap(polyline.movingAnchor(2, to: p(200, 50)))
        XCTAssertEqual(tip.end, p(200, 50)); XCTAssertEqual(tip.points?.last, p(200, 50))
        XCTAssertNil(polyline.movingAnchor(2, to: p(0, 100)), "a head needs a direction")

        let rectangle = ShapeObject(kind: .rectangle, start: p(100, 100), end: p(200, 150))
        XCTAssertEqual(rectangle.anchors, [p(100, 100), p(200, 100), p(200, 150), p(100, 150)])
        let wider = try XCTUnwrap(rectangle.movingAnchor(1, to: p(260, 80)))
        XCTAssertEqual(wider.frame, PageRect(x: 100, y: 80, width: 160, height: 70), "opposite corner stays")
        let flipped = try XCTUnwrap(rectangle.movingAnchor(2, to: p(50, 120)))
        XCTAssertEqual(flipped.frame, PageRect(x: 50, y: 100, width: 50, height: 20))

        let circle = ShapeObject(kind: .ellipse, start: p(100, 100), end: p(200, 200))
        XCTAssertEqual(circle.anchors, [p(150, 100), p(200, 150), p(150, 200), p(100, 150)])
        XCTAssertEqual(circle.movingAnchor(1, to: p(260, 170))?.frame, PageRect(x: 100, y: 100, width: 160, height: 100))
        XCTAssertEqual(circle.movingAnchor(0, to: p(130, 60))?.frame, PageRect(x: 100, y: 60, width: 100, height: 140))
        XCTAssertNil(circle.movingAnchor(4, to: p(0, 0)))

        let triangle = ShapeObject(kind: .polygon, vertices: [p(0, 0), p(100, 0), p(50, 80)])
        let moved = try XCTUnwrap(triangle.movingAnchor(2, to: p(50, 120)))
        XCTAssertEqual(moved.points?[2], p(50, 120)); XCTAssertEqual(moved.end, p(50, 120))
    }

    // MARK: Format

    func testVertexShapesValidateStrictly() {
        let good = ShapeObject(kind: .line, vertices: [p(0, 0), p(0, 100), p(100, 100)])
        XCTAssertNoThrow(try good.validate())
        var mismatch = good; mismatch.start = p(1, 0)
        XCTAssertThrowsError(try mismatch.validate(), "start must be the first vertex")
        var two = good; two.points = [p(0, 0), p(100, 100)]; two.end = p(100, 100)
        XCTAssertThrowsError(try two.validate(), "two vertices are the schema-6 form")
        var rectangle = ShapeObject(kind: .rectangle, start: p(0, 0), end: p(10, 10)); rectangle.points = [p(0, 0), p(5, 5), p(10, 10)]
        XCTAssertThrowsError(try rectangle.validate())
        XCTAssertThrowsError(try ShapeObject(kind: .polygon, start: p(0, 0), end: p(10, 10)).validate(), "polygon needs vertices")
        XCTAssertThrowsError(try ShapeObject(kind: .polygon, vertices: [p(0, 0), p(10, 0), p(20, 0)]).validate(), "flat polygon")
        let many = (0...ShapeObject.maximumVertices).map { p(Double($0) * 2, Double($0 % 2) * 5) }
        XCTAssertThrowsError(try ShapeObject(kind: .line, vertices: many).validate())
        XCTAssertEqual(good.translated(x: 5, y: 7).points, [p(5, 7), p(5, 107), p(105, 107)])
        XCTAssertEqual(good.bounds, PageRect(x: -1, y: -1, width: 102, height: 102))
    }

    func testPolylinesRaiseTheSchemaToThirteenAndOlderSchemasRejectThem() throws {
        var book = Notebook(); book.schemaVersion = 12
        let polyline = ShapeObject(kind: .arrow, vertices: [p(50, 50), p(50, 200), p(200, 200)])
        try book.replaceShapes([ShapeObject(kind: .line, start: p(10, 10), end: p(90, 10))], pageID: book.pages[0].id)
        XCTAssertEqual(book.schemaVersion, 12, "straight shapes keep the schema")
        try book.replaceShapes([polyline], pageID: book.pages[0].id)
        XCTAssertEqual(book.schemaVersion, 13)
        try book.replaceShapes([], pageID: book.pages[0].id)
        XCTAssertEqual(book.schemaVersion, 13, "never lowered")
        var content = PageContent(page: book.pages[0]); content.shapes = [polyline]
        var other = Notebook(); other.schemaVersion = 12
        try other.replaceContent(content, pageID: other.pages[0].id)
        XCTAssertEqual(other.schemaVersion, 13)
        var old = other; old.schemaVersion = 12
        XCTAssertThrowsError(try old.validate())
        // Stored schema-12 bytes with a polygon are invalid, schema 16 stays locked.
        let data = try JSONEncoder().encode(other)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json["schemaVersion"] = 12
        XCTAssertThrowsError(try Notebook.decode(JSONSerialization.data(withJSONObject: json)))
        json["schemaVersion"] = 16
        XCTAssertThrowsError(try Notebook.decode(JSONSerialization.data(withJSONObject: json))) { error in
            guard case StorageError.unsupportedSchema(16) = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(try Notebook.decode(data), other)
    }

    func testStraightShapesKeepTheirExactStoredBytes() throws {
        let shape = ShapeObject(id: UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!, kind: .arrow, start: p(1, 2), end: p(30, 4))
        let json = String(decoding: try JSONEncoder().encode(shape), as: UTF8.self)
        XCTAssertFalse(json.contains("points"))
    }

    func testFirstSchemaThirteenCommitArchivesExactConfirmedOldBytes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RevisionStore(directory: root)
        var book = Notebook(); book.schemaVersion = 6
        try book.replaceShapes([ShapeObject(kind: .rectangle, start: p(10, 10), end: p(90, 60))], pageID: book.pages[0].id)
        try store.save(book)
        let revision = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("Revisions"), includingPropertiesForKeys: nil)[0]
        let bytes = try Data(contentsOf: revision)
        try book.replaceShapes(book.pages[0].shapes! + [ShapeObject(kind: .polygon, vertices: [p(100, 100), p(200, 100), p(150, 180)])],
                               pageID: book.pages[0].id)
        XCTAssertEqual(book.schemaVersion, 13)
        try store.save(book)
        let folder = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("Migrations"), includingPropertiesForKeys: nil)[0]
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("notebook-v6.json")), bytes)
        XCTAssertEqual(try store.load(), book)
    }

    func testCrossPageMoveAndEraseFollowTheVertices() throws {
        let polygon = ShapeObject(kind: .polygon, vertices: [p(0, 0), p(100, 0), p(50, 80)])
        let moved = try CrossPageTransfer.move(MovedObjects(shapes: [polygon]), by: CrossPageMove(scale: 2, translation: p(10, 20)))
        XCTAssertEqual(moved.shapes[0].points, [p(10, 20), p(210, 20), p(110, 180)])
        XCTAssertEqual(moved.shapes[0].start, p(10, 20)); XCTAssertEqual(moved.shapes[0].end, p(110, 180))
        var mask = ShapeEraseMask(polygon)
        XCTAssertEqual(mask.runs.first?.first, p(0, 0))
        mask.erase(from: p(50, -5), to: p(50, 5), radius: 2)
        XCTAssertEqual(mask.runs.count, 1, "a cut closed outline is one open piece")
    }
}
