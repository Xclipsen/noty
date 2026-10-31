import Foundation
import XCTest
@testable import NotebookCore

/// Rückgängig muss für jede Operation greifen (Nutzer: „einen Text mit dem
/// Lasso verschoben und konnte das nicht reverten“).
final class UndoReliabilityTests: XCTestCase {
    private func notebook(pages count: Int) throws -> Notebook {
        var book = try Notebook.blank(title: "Undo").preparedForTextEditing()
        while book.pages.count < count { _ = try book.insertPaper(.blank, at: book.pages.count) }
        return book
    }
    private func field(x: Double, y: Double, text: String = "Text") -> TextBox {
        TextBox(x: x, y: y, width: 120, height: 24, text: text, style: TextBoxStyle())
    }
    private func content(_ book: Notebook, _ id: UUID) -> PageContent { PageContent(page: book.pages.first { $0.id == id }!) }

    /// The way `EditorModel.updateContent` records a lasso move on one page.
    private func move(_ book: inout Notebook, _ history: inout NotebookUndoHistory, _ id: UUID, to x: Double, y: Double) throws {
        let before = content(book, id)
        var next = before
        next.textBoxes[0].x = x; next.textBoxes[0].y = y
        try book.replaceContent(next, pageID: id)
        history.record(.objects, changes: [PageContentReplacement(pageID: id, expected: before, replacement: content(book, id))])
    }

    func testLassoMoveOnOnePageUndoesAndRedoes() throws {
        var book = try notebook(pages: 1)
        let id = book.pages[0].id
        try book.replaceTextBoxes([field(x: 100, y: 100)], pageID: id)
        let start = content(book, id)
        var history = NotebookUndoHistory()
        try move(&book, &history, id, to: 200, y: 300)
        let moved = content(book, id)
        let undone = try XCTUnwrap(history.undo(book))
        XCTAssertEqual(content(undone.notebook, id), start)
        let redone = try XCTUnwrap(history.redo(undone.notebook))
        XCTAssertEqual(content(redone.notebook, id), moved)
    }

    func testMovingAFieldBackOntoThePageUndoes() throws {
        var book = try notebook(pages: 1)
        let id = book.pages[0].id
        // A field partly beside the sheet (older builds, restored notebooks):
        // the document is valid, and moving it on the page is what one does.
        book.pages[0].textBoxes = [field(x: 560, y: 100)]
        try book.validate()
        let start = content(book, id)
        var history = NotebookUndoHistory()
        try move(&book, &history, id, to: 100, y: 100)
        let undone = try XCTUnwrap(history.undo(book), "the move must be undoable")
        XCTAssertEqual(content(undone.notebook, id), start)
        XCTAssertTrue(history.canRedo)
    }

    func testTransferOfAFieldThatDidNotFitUndoesAcrossPages() throws {
        var book = try notebook(pages: 2)
        let a = book.pages[0].id, b = book.pages[1].id
        book.pages[0].textBoxes = [field(x: 560, y: 100)]
        let source = content(book, a), target = content(book, b)
        var moved = target; moved.textBoxes = [field(x: 100, y: 100)]
        moved.textBoxes[0].id = source.textBoxes[0].id
        var remainder = source; remainder.textBoxes = []
        let changes = [PageContentReplacement(pageID: a, expected: source, replacement: remainder),
                       PageContentReplacement(pageID: b, expected: target, replacement: moved)]
        try book.replaceContents(changes)
        var history = NotebookUndoHistory()
        history.record(.transfer, changes: changes)
        let undone = try XCTUnwrap(history.undo(book), "the transfer must be undoable")
        XCTAssertEqual(undone.pageID, a)
        XCTAssertEqual(content(undone.notebook, a), source)
        XCTAssertEqual(content(undone.notebook, b), target)
    }
}

extension UndoReliabilityTests {
    func testStaleStepsAreReportedAndNeverOverwriteNewerContent() throws {
        var book = try notebook(pages: 2)
        let a = book.pages[0].id, b = book.pages[1].id
        try book.replaceTextBoxes([field(x: 100, y: 100)], pageID: a)
        try book.replaceTextBoxes([field(x: 100, y: 100)], pageID: b)
        var history = NotebookUndoHistory()
        try move(&book, &history, a, to: 150, y: 150)
        try move(&book, &history, b, to: 150, y: 150)
        // Written outside the history: b's step no longer applies.
        book.pages[1].drawing = Data("fremd".utf8)
        let outcome = try XCTUnwrap(history.undo(book))
        XCTAssertEqual(outcome.skipped, 1)
        XCTAssertEqual(history.lastSkipped, 1)
        XCTAssertEqual(outcome.pageID, a)
        XCTAssertEqual(content(outcome.notebook, b).drawing, Data("fremd".utf8))
        XCTAssertEqual(content(outcome.notebook, b).textBoxes[0].x, 150)

        // Nothing applicable left: nil, and the caller learns why.
        var other = try notebook(pages: 1)
        let id = other.pages[0].id
        try other.replaceTextBoxes([field(x: 100, y: 100)], pageID: id)
        var stale = NotebookUndoHistory()
        try move(&other, &stale, id, to: 150, y: 150)
        other.pages[0].drawing = Data("fremd".utf8)
        XCTAssertTrue(stale.canUndo)
        XCTAssertNil(stale.undo(other))
        XCTAssertEqual(stale.lastSkipped, 1)
        XCTAssertFalse(stale.canUndo)
        // An empty history is no skipped step.
        XCTAssertNil(stale.undo(other))
        XCTAssertEqual(stale.lastSkipped, 0)
    }

    func testBlankFieldIsRecognized() {
        let keep = field(x: 10, y: 10), blank = field(x: 50, y: 50, text: "")
        XCTAssertEqual(NotebookUndoHistory.blankField(before: [keep], after: [keep, blank]), .added)
        XCTAssertEqual(NotebookUndoHistory.blankField(before: [keep, blank], after: [keep]), .removed)
        XCTAssertNil(NotebookUndoHistory.blankField(before: [keep], after: [keep, field(x: 50, y: 50)]), "written field")
        XCTAssertNil(NotebookUndoHistory.blankField(before: [keep], after: []), "written field removed")
        var moved = keep; moved.x += 5
        XCTAssertNil(NotebookUndoHistory.blankField(before: [keep], after: [moved, blank]), "another change at the same time")
        var styled = blank; styled.border = .text
        XCTAssertNil(NotebookUndoHistory.blankField(before: [keep], after: [keep, styled]), "a framed field is visible")
    }

    /// `EditorModel.updateTextBoxes`: the same key, the longer window for a blank field.
    private func recordText(_ book: inout Notebook, _ history: inout NotebookUndoHistory, _ id: UUID, boxes: [TextBox], at time: TimeInterval) throws {
        let before = content(book, id)
        let blank = NotebookUndoHistory.blankField(before: before.textBoxes, after: boxes)
        if blank == .added { history.separateNextStep() }
        try book.replaceTextBoxes(boxes, pageID: id)
        history.record(.text, changes: [PageContentReplacement(pageID: id, expected: before, replacement: content(book, id))],
                       coalescing: .init(key: "text-\(id)", window: blank == nil ? 1.5 : NotebookUndoHistory.blankFieldWindow),
                       now: Date(timeIntervalSinceReferenceDate: time))
    }

    func testFieldOpenedAndLeftEmptyLeavesNoStep() throws {
        var book = try notebook(pages: 1)
        let id = book.pages[0].id
        var history = NotebookUndoHistory()
        try move(&book, &history, id, keeping: [field(x: 100, y: 100)])
        let moved = history.undoCount
        let blank = field(x: 300, y: 300, text: "")
        try recordText(&book, &history, id, boxes: content(book, id).textBoxes + [blank], at: 0)
        XCTAssertEqual(history.undoCount, moved + 1)
        try recordText(&book, &history, id, boxes: content(book, id).textBoxes.filter { $0.id != blank.id }, at: 60)
        XCTAssertEqual(history.undoCount, moved, "opened and left empty: the next undo reaches the real step")
    }

    func testFirstCharactersJoinTheirBlankFieldAfterAPause() throws {
        var book = try notebook(pages: 1)
        let id = book.pages[0].id
        var history = NotebookUndoHistory()
        let start = content(book, id)
        var box = field(x: 100, y: 100, text: "")
        try recordText(&book, &history, id, boxes: [box], at: 0)
        box.text = "a"
        try recordText(&book, &history, id, boxes: [box], at: 20)
        XCTAssertEqual(history.undoCount, 1, "the pause before typing leaves no invisible step")
        // From now on typing keeps its normal window again.
        box.text = "ab"
        try recordText(&book, &history, id, boxes: [box], at: 40)
        XCTAssertEqual(history.undoCount, 2)
        var outcome = try XCTUnwrap(history.undo(book))
        outcome = try XCTUnwrap(history.undo(outcome.notebook))
        XCTAssertEqual(content(outcome.notebook, id), start)
    }

    private func move(_ book: inout Notebook, _ history: inout NotebookUndoHistory, _ id: UUID, keeping boxes: [TextBox]) throws {
        let before = content(book, id)
        var next = before; next.textBoxes = boxes
        try book.replaceContent(next, pageID: id)
        history.record(.objects, changes: [PageContentReplacement(pageID: id, expected: before, replacement: content(book, id))])
    }

    func testTransferOntoTheWritingDraftUndoesWithThePageAndRevealsTheSource() throws {
        var book = try notebook(pages: 1)
        let source = book.pages[0].id
        try book.replaceTextBoxes([field(x: 100, y: 100)], pageID: source)
        let start = book
        var history = NotebookUndoHistory()
        let draft = book.writingDraft()
        try book.materializeWritingDraft(draft)
        XCTAssertTrue(history.recordMaterialization(.pages, before: start, after: book, pageID: draft.id))
        let from = content(book, source), to = content(book, draft.id)
        var moved = to; moved.textBoxes = from.textBoxes
        var remainder = from; remainder.textBoxes = []
        try book.replaceContents([PageContentReplacement(pageID: source, expected: from, replacement: remainder),
                                  PageContentReplacement(pageID: draft.id, expected: to, replacement: moved)])
        XCTAssertTrue(history.continuesMaterialization(of: draft.id, kind: .transfer, coalescing: nil))
        XCTAssertTrue(history.recordMaterialization(.transfer, before: start, after: book, pageID: draft.id,
                                                    touching: [source, draft.id], undoPageID: source))
        XCTAssertEqual(history.undoCount, 1)
        let undone = try XCTUnwrap(history.undo(book))
        XCTAssertEqual(undone.pageID, source, "the moved text comes back there")
        XCTAssertEqual(undone.notebook.pages.map(\.id), [source])
        XCTAssertEqual(content(undone.notebook, source), from)
        let redone = try XCTUnwrap(history.redo(undone.notebook))
        XCTAssertEqual(redone.pageID, draft.id)
        XCTAssertEqual(content(redone.notebook, draft.id), moved)
    }

    func testMovedTextInATextDocumentUndoesWithoutTouchingTheFlow() throws {
        var book = try Notebook.textDocument(title: "Text")
        let id = book.pages[0].id
        var boxes = content(book, id).textBoxes
        boxes.append(field(x: 100, y: 100))
        try book.replaceTextBoxes(boxes, pageID: id)
        let start = content(book, id)
        var history = NotebookUndoHistory()
        var next = start
        let index = next.textBoxes.firstIndex { $0.flowID == nil }!
        next.textBoxes[index].x = 220
        try book.replaceContent(next, pageID: id)
        history.record(.objects, changes: [PageContentReplacement(pageID: id, expected: start, replacement: content(book, id))])
        let undone = try XCTUnwrap(history.undo(book))
        XCTAssertEqual(content(undone.notebook, id), start)
        XCTAssertNoThrow(try undone.notebook.validate())
        XCTAssertGreaterThanOrEqual(undone.notebook.schemaVersion, book.schemaVersion)
    }

    func testStepsOnAPageFullOfInkDoNotPushOlderStepsOut() throws {
        var book = try notebook(pages: 2)
        let a = book.pages[0].id, b = book.pages[1].id
        try book.replaceTextBoxes([field(x: 100, y: 100)], pageID: a)
        book.pages[0].drawing = Data(repeating: 7, count: 30_000_000)
        var history = NotebookUndoHistory()
        // The oldest step, on another page.
        let before = content(book, b)
        book.pages[1].drawing = Data("alt".utf8)
        history.record(.ink, changes: [PageContentReplacement(pageID: b, expected: before, replacement: content(book, b))])
        for step in 1...5 { try move(&book, &history, a, to: 100 + Double(step), y: 100) }
        XCTAssertEqual(history.undoCount, 6, "unchanged ink costs nothing: it is the page's own buffer")
    }
}
