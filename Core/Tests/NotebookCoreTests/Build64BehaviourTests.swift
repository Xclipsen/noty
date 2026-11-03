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

extension Build64BehaviourTests {
    /// Writing on the reserve page materialises it; undo of that first content
    /// removes the page again in the same step, redo restores both.
    func testUndoOfFirstContentOnTheWritingDraftRemovesThePage() throws {
        var notebook = try Notebook.blank(title: "Reserve").preparedForPageEditing()
        let start = notebook
        var history = NotebookUndoHistory()
        let now = Date()
        // First stroke: the draft becomes a page (bare step), then its ink joins.
        let draft = notebook.writingDraft()
        try notebook.materializeWritingDraft(draft)
        XCTAssertTrue(history.recordMaterialization(.pages, before: start, after: notebook, pageID: draft.id, now: now))
        let key = NotebookUndoHistory.Coalescing(key: "ink-\(draft.id.uuidString)-1", window: 120)
        XCTAssertTrue(history.continuesMaterialization(of: draft.id, kind: .ink, coalescing: key, now: now))
        let index = try XCTUnwrap(notebook.pages.firstIndex { $0.id == draft.id })
        notebook.pages[index].drawing = Data([1, 2, 3])
        XCTAssertTrue(history.recordMaterialization(.ink, before: start, after: notebook, pageID: draft.id, coalescing: key, now: now))
        XCTAssertEqual(history.undoCount, 1)
        // A second stroke (new ink session) is its own step.
        XCTAssertFalse(history.continuesMaterialization(of: draft.id, kind: .ink,
            coalescing: .init(key: "ink-\(draft.id.uuidString)-2", window: 120), now: now))
        let written = notebook

        let undone = try XCTUnwrap(history.undo(notebook))
        XCTAssertEqual(undone.notebook.pages.map(\.id), start.pages.map(\.id))
        XCTAssertEqual(undone.pageID, draft.id)
        let redone = try XCTUnwrap(history.redo(undone.notebook))
        XCTAssertEqual(redone.notebook.pages.map(\.id), written.pages.map(\.id))
        XCTAssertEqual(redone.notebook.pages.last?.drawing, Data([1, 2, 3]))
        XCTAssertGreaterThanOrEqual(redone.notebook.schemaVersion, written.schemaVersion)
    }

    func testBarePageStepStopsWaitingAfterItsWindow() throws {
        var notebook = try Notebook.blank(title: "Reserve").preparedForPageEditing()
        let start = notebook
        var history = NotebookUndoHistory()
        let draft = notebook.writingDraft()
        try notebook.materializeWritingDraft(draft)
        let now = Date()
        XCTAssertTrue(history.recordMaterialization(.pages, before: start, after: notebook, pageID: draft.id, now: now))
        XCTAssertTrue(history.continuesMaterialization(of: draft.id, kind: .objects, coalescing: nil, now: now.addingTimeInterval(5)))
        XCTAssertFalse(history.continuesMaterialization(of: draft.id, kind: .objects, coalescing: nil,
            now: now.addingTimeInterval(NotebookUndoHistory.materializationWindow + 1)))
        // Another step in between ends it.
        history.separateNextStep()
        XCTAssertFalse(history.continuesMaterialization(of: draft.id, kind: .objects, coalescing: nil, now: now))
    }
}

extension Build64BehaviourTests {
    func testMaterializationStepNeverCoversOtherPagesChangedMeanwhile() throws {
        var notebook = try Notebook.blank(title: "Reserve").preparedForPageEditing()
        let start = notebook
        var history = NotebookUndoHistory()
        let draft = notebook.writingDraft()
        try notebook.materializeWritingDraft(draft)
        XCTAssertTrue(history.recordMaterialization(.pages, before: start, after: notebook, pageID: draft.id))
        notebook.pages[0].drawing = Data([9])
        XCTAssertFalse(history.recordMaterialization(.ink, before: start, after: notebook, pageID: draft.id))
        XCTAssertTrue(history.recordMaterialization(.transfer, before: start, after: notebook, pageID: draft.id,
                                                    touching: [notebook.pages[0].id]))
    }
}
