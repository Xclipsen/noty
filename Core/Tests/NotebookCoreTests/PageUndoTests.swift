import Foundation
import XCTest
@testable import NotebookCore

/// Stand-in for PencilKit data: the app applies the same per-stroke decision.
private struct UndoStroke: Codable, Equatable { var bounds: PageRect; var color: InkColor }
private func undoDrawing(_ strokes: [UndoStroke]) -> Data { try! JSONEncoder().encode(strokes) }
private func undoRecolor(_ data: Data, _ convert: (PageRect, InkColor) -> InkColor?) throws -> Data {
    let old = try JSONDecoder().decode([UndoStroke].self, from: data)
    let new = old.map { UndoStroke(bounds: $0.bounds, color: convert($0.bounds, $0.color) ?? $0.color) }
    return new == old ? data : try JSONEncoder().encode(new)
}

/// User feedback: undo must also take back page changes (paper style,
/// defaults, whole-notebook restyle) and page operations, by stable page ID.
final class PageUndoTests: XCTestCase {
    private func notebook(pages count: Int) throws -> Notebook {
        var book = Notebook.blank(title: "Seiten")
        while book.pages.count < count { _ = try book.insertPaper(.blank, at: book.pages.count) }
        return book
    }

    /// Runs one page operation the way `EditorModel.editPages` does and records it.
    @discardableResult
    private func perform(_ book: inout Notebook, _ history: inout NotebookUndoHistory, focus: UUID? = nil,
                         _ action: (inout Notebook) throws -> Void) throws -> Notebook {
        let before = book
        try action(&book)
        XCTAssertTrue(history.recordPages(before: before, after: book, undoPageID: focus ?? before.pages[0].id,
                                          redoPageID: focus ?? book.pages[0].id))
        return before
    }

    private func undo(_ book: inout Notebook, _ history: inout NotebookUndoHistory, file: StaticString = #filePath, line: UInt = #line) throws -> NotebookUndoHistory.Outcome {
        let outcome = try XCTUnwrap(history.undo(book), file: file, line: line)
        try outcome.notebook.validate(); book = outcome.notebook; return outcome
    }
    private func redo(_ book: inout Notebook, _ history: inout NotebookUndoHistory, file: StaticString = #filePath, line: UInt = #line) throws -> NotebookUndoHistory.Outcome {
        let outcome = try XCTUnwrap(history.redo(book), file: file, line: line)
        try outcome.notebook.validate(); book = outcome.notebook; return outcome
    }
    /// Undo never lowers the format; everything else must match exactly.
    private func assertSame(_ a: Notebook, _ b: Notebook, file: StaticString = #filePath, line: UInt = #line) {
        var a = a, b = b
        a.schemaVersion = 0; b.schemaVersion = 0
        XCTAssertEqual(a, b, file: file, line: line)
    }

    // MARK: Paper style and defaults

    func testPageDefaultsWithEmptyPagesIsOneUndoStep() throws {
        var book = try notebook(pages: 3)
        let ids = book.pages.map(\.id)
        book.pages[1].drawing = undoDrawing([UndoStroke(bounds: .init(x: 10, y: 10, width: 5, height: 5), color: .init(0, 0, 0))])
        var history = NotebookUndoHistory()
        let before = try perform(&book, &history, focus: ids[1]) {
            try $0.setPageDefaults(paper: .grid, color: .dark, scope: .emptyPages, emptyPageIDs: [ids[0], ids[2]])
        }
        let after = book
        XCTAssertEqual(book.pages.map(\.paper), [.grid, .blank, .grid])
        XCTAssertEqual(history.undoCount, 1)

        let outcome = try undo(&book, &history)
        XCTAssertEqual(outcome.kind, .pages); XCTAssertEqual(outcome.pageID, ids[1])
        assertSame(book, before)
        XCTAssertEqual(book.pages.map(\.paper), [.blank, .blank, .blank])
        XCTAssertEqual(book.pages.map { $0.paperColor ?? .white }, [.white, .white, .white])
        XCTAssertEqual(book.appearance, before.appearance)
        XCTAssertGreaterThanOrEqual(book.schemaVersion, after.schemaVersion, "format is never lowered")
        try redo(&book, &history)
        XCTAssertEqual(book, after)
    }

    func testWholeNotebookRestyleUndoRestoresExactInkAndText() throws {
        var book = try notebook(pages: 2)
        let black = InkColor(0, 0, 0), red = InkColor(0.8, 0.1, 0.1)
        book.pages[0].drawing = undoDrawing([UndoStroke(bounds: .init(x: 10, y: 10, width: 50, height: 5), color: black),
                                             UndoStroke(bounds: .init(x: 10, y: 30, width: 50, height: 5), color: red)])
        try book.replaceTextBoxes([TextBox(x: 20, y: 100, width: 200, height: 40, text: "Hallo")], pageID: book.pages[1].id)
        var history = NotebookUndoHistory()
        let before = try perform(&book, &history) {
            try $0.setPageDefaults(paper: .lined, color: .dark, scope: .wholeNotebook, recolorDrawing: undoRecolor)
        }
        let after = book
        XCTAssertNotEqual(book.pages[0].drawing, before.pages[0].drawing, "black ink was inverted")
        XCTAssertEqual(book.pages[1].effectiveTextBoxes.first?.style.color, .white)

        try undo(&book, &history)
        assertSame(book, before)
        XCTAssertEqual(book.pages[0].drawing, before.pages[0].drawing, "exact original ink bytes")
        XCTAssertEqual(book.pages[1].effectiveTextBoxes, before.pages[1].effectiveTextBoxes)
        XCTAssertEqual(book.pages.map { $0.paperColor ?? .white }, [.white, .white])
        try redo(&book, &history)
        XCTAssertEqual(book, after)
        // Undo again, then a further restyle: the redo branch is discarded.
        try undo(&book, &history)
        try perform(&book, &history) { try $0.setPageDefaults(paper: .grid, color: .white, scope: .newPagesOnly) }
        XCTAssertFalse(history.canRedo)
    }

    // MARK: Structural page operations

    func testAddDuplicateAndMoveUndoAndRedoByStableID() throws {
        var book = try notebook(pages: 2)
        let a = book.pages[0].id, b = book.pages[1].id
        book.pages[0].drawing = Data("a".utf8)
        var history = NotebookUndoHistory()
        var added = UUID(), copy = UUID()
        let start = book
        try perform(&book, &history) { added = try $0.insertPaper(.lined, color: .dark, at: 1) }
        try perform(&book, &history) { copy = try $0.duplicatePage(a) }
        try perform(&book, &history) { try $0.movePage(b, to: 0) }
        try perform(&book, &history) { try $0.reorderPages($0.pages.map(\.id).reversed()) }
        let end = book
        XCTAssertEqual(book.pages.map(\.id), [added, copy, a, b])
        XCTAssertNotEqual(copy, a); XCTAssertEqual(book.pages.first { $0.id == copy }?.drawing, Data("a".utf8))

        try undo(&book, &history)
        XCTAssertEqual(book.pages.map(\.id), [b, a, copy, added])
        try undo(&book, &history)
        XCTAssertEqual(book.pages.map(\.id), [a, copy, added, b])
        try undo(&book, &history)
        XCTAssertEqual(book.pages.map(\.id), [a, added, b])
        try undo(&book, &history)
        XCTAssertEqual(book, start)
        XCTAssertNil(history.undo(book))

        for _ in 0..<4 { try redo(&book, &history) }
        XCTAssertEqual(book, end, "redo re-creates the same page IDs")
    }

    func testDeleteUndoRestoresFromTrashAtSamePositionAndRedoTrashesAgain() throws {
        var book = try notebook(pages: 3)
        let a = book.pages[0].id, b = book.pages[1].id, c = book.pages[2].id
        var history = NotebookUndoHistory()
        // A content step on b before the deletion stays reachable afterwards.
        let content = PageContent(page: book.pages[1])
        book.pages[1].drawing = Data("written".utf8)
        history.record(.ink, changes: [PageContentReplacement(pageID: b, expected: content, replacement: PageContent(page: book.pages[1]))])
        let written = book
        try perform(&book, &history, focus: b) { try $0.trashPage(b, at: Date(timeIntervalSince1970: 1_000)) }
        let deleted = book
        XCTAssertEqual(book.deletedPages?.first?.page.id, b)
        // The page operation on top keeps older steps from being pruned.
        history.prune(book)
        XCTAssertEqual(history.undoCount, 2)

        let outcome = try undo(&book, &history)
        XCTAssertEqual(outcome.pageID, b)
        XCTAssertEqual(book, written, "same ID, same position, same content, trash entry gone")
        XCTAssertEqual(book.pages.map(\.id), [a, b, c])
        XCTAssertEqual(book.deletedPages, [])

        try redo(&book, &history)
        XCTAssertEqual(book, deleted, "redo moves the page to the trash again")
        try undo(&book, &history)
        try undo(&book, &history)
        XCTAssertEqual(book.pages[1].drawing, Data())
    }

    func testRestoreFromTrashClearAndBookmarkAreUndoable() throws {
        var book = try notebook(pages: 2)
        let a = book.pages[0].id, b = book.pages[1].id
        book.pages[0].drawing = Data("ink".utf8)
        try book.trashPage(b)
        var history = NotebookUndoHistory()
        let trashed = book
        try perform(&book, &history) { _ = try $0.restorePage(b) }
        try perform(&book, &history) { try $0.clearPage(a) }
        XCTAssertEqual(book.pages[0].drawing, Data())
        try perform(&book, &history) { try $0.toggleBookmark(a) }

        try undo(&book, &history)
        XCTAssertNil(book.pages[0].bookmarked)
        try undo(&book, &history)
        XCTAssertEqual(book.pages[0].drawing, Data("ink".utf8))
        XCTAssertEqual(book.deletedPages?.count, 0, "the clear snapshot leaves the trash again")
        try undo(&book, &history)
        assertSame(book, trashed)
    }

    func testPDFInsertionUndoRemovesPagesAndUnreferencedSource() throws {
        var book = try notebook(pages: 1)
        let box = PageRect(x: 0, y: 0, width: 300, height: 400)
        let geometry = try PDFPageGeometry(mediaBox: box, cropBox: box, rotation: 0)
        var history = NotebookUndoHistory()
        let start = book
        var ids: [UUID] = []
        try perform(&book, &history) { ids = try $0.insertPDF(Data("%PDF".utf8), geometries: [geometry, geometry], at: 0) }
        let inserted = book
        XCTAssertEqual(book.pdfSources?.count, 1)

        try undo(&book, &history)
        XCTAssertEqual(book, start)
        XCTAssertEqual(book.pdfSources, [])
        try redo(&book, &history)
        XCTAssertEqual(book, inserted)
        XCTAssertEqual(Array(book.pages.map(\.id).prefix(2)), ids)
    }

    // MARK: Stale steps, limits

    func testStalePageStepsAreSkippedNeverOverwriteNewerContent() throws {
        var book = try notebook(pages: 2)
        let a = book.pages[0].id
        var history = NotebookUndoHistory()
        try perform(&book, &history) { try $0.toggleBookmark(a) }
        var added = UUID()
        try perform(&book, &history) { added = try $0.insertPaper(.grid, at: 2) }
        // Written outside the history: undoing the insertion would discard it.
        book.pages[2].drawing = Data("neu".utf8)
        let outcome = try undo(&book, &history)
        XCTAssertEqual(outcome.pageID, a)
        XCTAssertTrue(book.pages.contains { $0.id == added && $0.drawing == Data("neu".utf8) }, "written page kept")
        XCTAssertNil(book.pages[0].bookmarked, "older applicable step was undone instead")

        // Trash entry gone meanwhile: undo of the deletion is stale and skipped.
        var other = try notebook(pages: 3)
        let victim = other.pages[1].id
        var otherHistory = NotebookUndoHistory()
        try perform(&other, &otherHistory) { try $0.trashPage(victim) }
        other.deletedPages = []
        otherHistory.prune(other)
        XCTAssertFalse(otherHistory.canUndo)
        XCTAssertNil(otherHistory.undo(other))
    }

    func testPagesCreatedOutsideHistoryKeepTheirPlace() throws {
        var book = try notebook(pages: 2)
        let a = book.pages[0].id, b = book.pages[1].id
        var history = NotebookUndoHistory()
        try perform(&book, &history) { try $0.setPageDefaults(paper: .lined, color: .white, scope: .emptyPages, emptyPageIDs: [a, b]) }
        try perform(&book, &history) { try $0.movePage(a, to: 1) }
        // The writing draft at the end is materialised without its own step.
        let draft = book.writingDraft()
        try book.materializeWritingDraft(draft)
        XCTAssertEqual(book.pages.map(\.id), [b, a, draft.id])

        try undo(&book, &history)
        XCTAssertEqual(book.pages.map(\.id), [a, draft.id, b], "draft stays behind the page it followed")
        try undo(&book, &history)
        XCTAssertEqual(book.pages.first { $0.id == a }?.paper, .blank)
        XCTAssertEqual(book.pages.first { $0.id == draft.id }?.paper, .lined, "untouched page unchanged")
    }

    func testLegacyNotebookIsNotRecordedAndNothingIsRecordedForNoChange() throws {
        let legacy = Notebook()
        var migrated = legacy
        try migrated.toggleBookmark(legacy.pages[0].id)
        var history = NotebookUndoHistory()
        XCTAssertFalse(history.recordPages(before: legacy, after: migrated, undoPageID: legacy.pages[0].id, redoPageID: legacy.pages[0].id))
        XCTAssertTrue(history.recordPages(before: migrated, after: migrated, undoPageID: legacy.pages[0].id, redoPageID: legacy.pages[0].id))
        XCTAssertFalse(history.canUndo)
    }

    func testLargePDFStepsRespectTheMemoryCap() throws {
        var book = try notebook(pages: 1)
        let box = PageRect(x: 0, y: 0, width: 300, height: 400)
        let geometry = try PDFPageGeometry(mediaBox: box, cropBox: box, rotation: 0)
        var history = NotebookUndoHistory()
        for index in 0..<5 {
            var data = Data(count: 17_000_000); data[0] = UInt8(index)
            try perform(&book, &history) { _ = try $0.insertPDF(data, geometries: [geometry], at: 0) }
        }
        XCTAssertEqual(history.undoCount, 4, "oldest step dropped above ≈80 MB")
        for _ in 0..<4 { try undo(&book, &history) }
        XCTAssertEqual(book.pdfSources?.count, 1, "the first import stays (its step was dropped)")
        XCTAssertNil(history.undo(book))
    }
}
