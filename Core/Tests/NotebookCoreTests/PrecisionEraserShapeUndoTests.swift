import Foundation
import XCTest
@testable import NotebookCore

/// The precision eraser cuts ink natively (published as ink changes of its
/// gesture) and removes touched shapes whole on lift. Recorded as ink with
/// the gesture's coalescing key, both undo as one step, in either order.
final class PrecisionEraserShapeUndoTests: XCTestCase {
    private func setUp(shapes: Int) throws -> (Notebook, UUID) {
        var book = Notebook.blank(title: "Radierer")
        let id = book.pages[0].id
        var content = PageContent(page: book.pages[0])
        content.shapes = (0..<shapes).map {
            ShapeObject(kind: .rectangle, start: .init(x: 50 + Double($0) * 60, y: 50), end: .init(x: 90 + Double($0) * 60, y: 90))
        }
        try book.replaceContent(content, pageID: id)
        return (book, id)
    }
    private func content(_ book: Notebook, _ id: UUID) -> PageContent { PageContent(page: book.pages.first { $0.id == id }!) }
    private func inkChange(_ book: inout Notebook, _ id: UUID, drawing: String) -> PageContentReplacement {
        let before = content(book, id)
        book.pages[book.pages.firstIndex { $0.id == id }!].drawing = Data(drawing.utf8)
        return PageContentReplacement(pageID: id, expected: before, replacement: content(book, id))
    }
    private func shapeRemoval(_ book: inout Notebook, _ id: UUID, keeping count: Int) throws -> PageContentReplacement {
        let before = content(book, id)
        var next = before; next.shapes = Array(before.shapes.prefix(count))
        try book.replaceContent(next, pageID: id)
        return PageContentReplacement(pageID: id, expected: before, replacement: content(book, id))
    }

    func testInkAndShapeRemovalOfOneGestureUndoTogether() throws {
        var (book, id) = try setUp(shapes: 2)
        let original = content(book, id)
        var history = NotebookUndoHistory()
        let gesture = NotebookUndoHistory.Coalescing(key: "ink-\(id)-7", window: 120)
        let start = Date(timeIntervalSinceReferenceDate: 0)
        history.record(.ink, changes: [inkChange(&book, id, drawing: "cut")], coalescing: gesture, now: start)
        history.record(.ink, changes: [try shapeRemoval(&book, id, keeping: 1)], coalescing: gesture, now: start + 0.1)
        // PencilKit's final eraser drawing may arrive after the lift.
        history.record(.ink, changes: [inkChange(&book, id, drawing: "cut2")], coalescing: gesture, now: start + 0.2)
        XCTAssertEqual(history.undoCount, 1)
        book = try XCTUnwrap(history.undo(book)).notebook
        XCTAssertEqual(content(book, id), original)
        book = try XCTUnwrap(history.redo(book)).notebook
        XCTAssertEqual(content(book, id).shapes.count, 1)
        XCTAssertEqual(content(book, id).drawing, Data("cut2".utf8))
    }

    func testShapeRemovalOfANewGestureIsItsOwnStep() throws {
        var (book, id) = try setUp(shapes: 1)
        var history = NotebookUndoHistory()
        let start = Date(timeIntervalSinceReferenceDate: 0)
        history.record(.ink, changes: [inkChange(&book, id, drawing: "stroke")], coalescing: .init(key: "ink-\(id)-1", window: 120), now: start)
        // Shape-only erase: the eraser gesture starts a fresh ink session.
        history.record(.ink, changes: [try shapeRemoval(&book, id, keeping: 0)], coalescing: .init(key: "ink-\(id)-2", window: 120), now: start + 1)
        XCTAssertEqual(history.undoCount, 2)
        book = try XCTUnwrap(history.undo(book)).notebook
        XCTAssertEqual(content(book, id).shapes.count, 1)
        XCTAssertEqual(content(book, id).drawing, Data("stroke".utf8))
    }
}
