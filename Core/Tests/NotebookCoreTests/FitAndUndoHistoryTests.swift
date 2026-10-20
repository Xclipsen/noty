import Foundation
import XCTest
@testable import NotebookCore

/// Build 41 device feedback: fit with writing space, notebook-wide undo,
/// focus after deleting the selected page.
final class FitAndUndoHistoryTests: XCTestCase {
    private func pdfPage(_ width: Double, _ height: Double, margins: PageMargins? = nil) throws -> Page {
        var page = Page()
        let box = PageRect(x: 0, y: 0, width: width, height: height)
        page.geometry = try PDFPageGeometry(mediaBox: box, cropBox: box, rotation: 0)
        page.margins = margins
        return page
    }

    // MARK: Fit includes the writing space

    func testFitSnapShowsPDFAndWritingSpaceCentred() throws {
        let viewport = PageSize(width: 1024, height: 768)
        for margins in [PageMargins(right: 595), PageMargins(left: 200, right: 400)] {
            for normalized in [false, true] {
                let paper = try pdfPage(595, 842)
                let page = try pdfPage(595, 842, margins: margins)
                let layout = NotebookViewportLayout(pages: [paper, page], selectedPageID: page.id, paging: false, normalizeWidths: normalized)
                let placed = try XCTUnwrap(layout.pages.last)
                XCTAssertGreaterThan(placed.frame.width, placed.contentFrame.width)
                let range = NotebookViewportGeometry.zoomRange(viewport: viewport, placement: placed)
                // Exact fit: the complete sheet (PDF + writing space) spans the viewport minus 16 pt per side.
                XCTAssertEqual(placed.frame.width * range.fit, viewport.width - 32, accuracy: 0.0001)
                let target = try XCTUnwrap(NotebookViewportGeometry.zoomDestination(scale: range.fit * 0.96, range: range,
                    page: placed.frame, widthRegion: placed.frame, viewport: viewport,
                    center: .init(x: placed.contentFrame.x + 100, y: placed.frame.y + 300)))
                XCTAssertEqual(target.scale, range.fit, accuracy: 0.0000001)
                let left = placed.frame.x * target.scale - target.offset.x
                let right = target.offset.x + viewport.width - (placed.frame.x + placed.frame.width) * target.scale
                XCTAssertEqual(left, 16, accuracy: 0.0001); XCTAssertEqual(right, 16, accuracy: 0.0001)
                // The horizontal clamp keeps that centred position in both scroll modes.
                for anchors in [nil, placed.writingScrollAnchors] as [(left: Double, right: Double)?] {
                    let clamped = NotebookViewportGeometry.horizontalOffset(target.offset.x, viewportWidth: viewport.width,
                        page: placed.frame, scale: target.scale, anchors: anchors)
                    XCTAssertEqual(clamped, target.offset.x, accuracy: 0.0001)
                }
            }
        }
    }

    func testZoomOutLimitStillFollowsBaseSheet() throws {
        let page = try pdfPage(595, 842, margins: PageMargins(right: 595))
        let layout = NotebookViewportLayout(pages: [page], selectedPageID: page.id, paging: false, normalizeWidths: false)
        let placed = try XCTUnwrap(layout.pages.first)
        let range = NotebookViewportGeometry.zoomRange(viewport: .init(width: 900, height: 800), placement: placed)
        XCTAssertEqual(range.minimum * 595 * 3, 900, accuracy: 0.0001)
        XCTAssertLessThan(range.minimum, range.fit)
    }

    // MARK: Notebook-wide undo history

    private func notebook(pages count: Int) throws -> Notebook {
        var book = Notebook.blank(title: "Undo")
        while book.pages.count < count { _ = try book.insertPaper(.blank, at: book.pages.count) }
        return book
    }
    private func content(_ book: Notebook, _ id: UUID) -> PageContent { PageContent(page: book.pages.first { $0.id == id }!) }
    private func change(_ book: inout Notebook, _ id: UUID, drawing: String) -> PageContentReplacement {
        let before = content(book, id)
        let index = book.pages.firstIndex { $0.id == id }!
        book.pages[index].drawing = Data(drawing.utf8)
        return PageContentReplacement(pageID: id, expected: before, replacement: content(book, id))
    }

    func testUndoAndRedoFollowChronologyAcrossPagesByStableID() throws {
        var book = try notebook(pages: 3)
        let a = book.pages[0].id, b = book.pages[2].id
        var history = NotebookUndoHistory()
        history.record(.ink, changes: [change(&book, a, drawing: "a1")])
        history.record(.ink, changes: [change(&book, b, drawing: "b1")])
        history.record(.ink, changes: [change(&book, a, drawing: "a2")])
        // Moving pages around does not matter: steps use IDs, not positions.
        try book.movePage(b, to: 0)

        var outcome = try XCTUnwrap(history.undo(book)); book = outcome.notebook
        XCTAssertEqual(outcome.pageID, a); XCTAssertEqual(content(book, a).drawing, Data("a1".utf8))
        outcome = try XCTUnwrap(history.undo(book)); book = outcome.notebook
        XCTAssertEqual(outcome.pageID, b); XCTAssertEqual(content(book, b).drawing, Data())
        outcome = try XCTUnwrap(history.undo(book)); book = outcome.notebook
        XCTAssertEqual(outcome.pageID, a); XCTAssertEqual(content(book, a).drawing, Data())
        XCTAssertNil(history.undo(book))
        XCTAssertTrue(history.canRedo)

        outcome = try XCTUnwrap(history.redo(book)); book = outcome.notebook
        XCTAssertEqual(outcome.pageID, a); XCTAssertEqual(content(book, a).drawing, Data("a1".utf8))
        outcome = try XCTUnwrap(history.redo(book)); book = outcome.notebook
        XCTAssertEqual(outcome.pageID, b); XCTAssertEqual(content(book, b).drawing, Data("b1".utf8))
        // A new edit discards the redo branch.
        history.record(.ink, changes: [change(&book, b, drawing: "b2")])
        XCTAssertFalse(history.canRedo)
        XCTAssertEqual(book.pages.map(\.id).firstIndex(of: b), 0)
    }

    func testStepsForDeletedOrReplacedPagesAreDroppedNotApplied() throws {
        var book = try notebook(pages: 3)
        let a = book.pages[0].id, b = book.pages[1].id, c = book.pages[2].id
        var history = NotebookUndoHistory()
        history.record(.ink, changes: [change(&book, a, drawing: "a1")])
        history.record(.ink, changes: [change(&book, b, drawing: "b1")])
        history.record(.ink, changes: [change(&book, c, drawing: "c1")])
        try book.trashPage(c)
        // Page b changed outside the history (e.g. cleared/restored): its step is stale.
        book.pages[book.pages.firstIndex { $0.id == b }!].drawing = Data("other".utf8)
        let before = book
        history.prune(book)
        XCTAssertEqual(history.undoCount, 1, "stale steps on top (deleted page, changed page) are pruned")
        let outcome = try XCTUnwrap(history.undo(book))
        XCTAssertEqual(outcome.pageID, a)
        XCTAssertEqual(content(outcome.notebook, a).drawing, Data())
        XCTAssertEqual(content(outcome.notebook, b).drawing, Data("other".utf8))
        XCTAssertEqual(outcome.notebook.deletedPages, before.deletedPages)
        XCTAssertFalse(history.canUndo)
    }

    func testInkUndoKeepsSchemaAndTransferIsOneStep() throws {
        var book = try notebook(pages: 2)
        let a = book.pages[0].id, b = book.pages[1].id
        var history = NotebookUndoHistory()
        history.record(.ink, changes: [change(&book, a, drawing: "ink")])
        // Cross-page move of a shape: source first, target last, applied atomically.
        let shape = ShapeObject(kind: .rectangle, start: .init(x: 10, y: 10), end: .init(x: 60, y: 60))
        var sourceBefore = content(book, a); sourceBefore.shapes = [shape]
        try book.replaceContent(sourceBefore, pageID: a)
        let targetBefore = content(book, b)
        var targetAfter = targetBefore; targetAfter.shapes = [shape]
        var sourceAfter = sourceBefore; sourceAfter.shapes = []
        let changes = [PageContentReplacement(pageID: a, expected: sourceBefore, replacement: sourceAfter),
                       PageContentReplacement(pageID: b, expected: targetBefore, replacement: targetAfter)]
        try book.replaceContents(changes)
        history.record(.transfer, changes: changes)
        let transferred = book

        var outcome = try XCTUnwrap(history.undo(book)); book = outcome.notebook
        XCTAssertEqual(outcome.kind, .transfer); XCTAssertEqual(outcome.pageID, a)
        XCTAssertEqual(content(book, a).shapes, [shape]); XCTAssertEqual(content(book, b).shapes, [])
        outcome = try XCTUnwrap(history.redo(book)); book = outcome.notebook
        XCTAssertEqual(outcome.pageID, b); XCTAssertEqual(book, transferred)
        outcome = try XCTUnwrap(history.undo(book)); book = outcome.notebook
        // Ink-only: the step before the transfer is not reachable while the
        // shape still sits on page a (unrecorded replaceContent) — dropped.
        XCTAssertNil(history.undo(book))

        var plain = try notebook(pages: 1)
        let schema = plain.schemaVersion
        var inkHistory = NotebookUndoHistory()
        inkHistory.record(.ink, changes: [change(&plain, plain.pages[0].id, drawing: "x")])
        let undone = try XCTUnwrap(inkHistory.undo(plain))
        XCTAssertEqual(undone.notebook.schemaVersion, schema)
    }

    func testCoalescingMergesOnlyUnbrokenSameKeyChains() throws {
        var book = try notebook(pages: 2)
        let a = book.pages[0].id, b = book.pages[1].id
        var history = NotebookUndoHistory()
        let start = Date(timeIntervalSinceReferenceDate: 0)
        let eraser = NotebookUndoHistory.Coalescing(key: "ink-a-1", window: 60)
        history.record(.ink, changes: [change(&book, a, drawing: "1")], coalescing: eraser, now: start)
        history.record(.ink, changes: [change(&book, a, drawing: "12")], coalescing: eraser, now: start + 1)
        history.record(.ink, changes: [change(&book, a, drawing: "123")], coalescing: eraser, now: start + 2)
        XCTAssertEqual(history.undoCount, 1)
        // A new session key starts a new step.
        history.record(.ink, changes: [change(&book, a, drawing: "1234")],
                       coalescing: .init(key: "ink-a-2", window: 60), now: start + 3)
        XCTAssertEqual(history.undoCount, 2)
        // Text bursts merge only inside their time window.
        let typing = NotebookUndoHistory.Coalescing(key: "text-b", window: 1.5)
        history.record(.text, changes: [change(&book, b, drawing: "t1")], coalescing: typing, now: start + 10)
        history.record(.text, changes: [change(&book, b, drawing: "t2")], coalescing: typing, now: start + 11)
        history.record(.text, changes: [change(&book, b, drawing: "t3")], coalescing: typing, now: start + 20)
        XCTAssertEqual(history.undoCount, 4)
        // After an undo nothing merges into the reverted step.
        book = try XCTUnwrap(history.undo(book)).notebook
        history.record(.text, changes: [change(&book, b, drawing: "t9")], coalescing: typing, now: start + 20.5)
        XCTAssertEqual(history.undoCount, 4)
        book = try XCTUnwrap(history.undo(book)).notebook
        book = try XCTUnwrap(history.undo(book)).notebook
        XCTAssertEqual(content(book, b).drawing, Data())
        book = try XCTUnwrap(history.undo(book)).notebook
        XCTAssertEqual(content(book, a).drawing, Data("123".utf8))
        book = try XCTUnwrap(history.undo(book)).notebook
        XCTAssertEqual(content(book, a).drawing, Data())
    }

    func testFlowSnapshotWithAddedPageUndoesWholeNotebook() throws {
        let before = try notebook(pages: 1)
        var after = before
        _ = try after.insertPaper(.lined, at: 1)
        var history = NotebookUndoHistory()
        let focus = TextFlowFocus(pageID: before.pages[0].id, boxID: UUID(), selection: NSRange(location: 0, length: 0), typingStyle: TextBoxStyle())
        history.record(.textFlow, before: before, after: after, beforeFocus: focus, afterFocus: focus)
        let outcome = try XCTUnwrap(history.undo(after))
        XCTAssertEqual(outcome.notebook, before)
        XCTAssertEqual(outcome.focus, focus)
        XCTAssertEqual(try XCTUnwrap(history.redo(before)).notebook, after)
        // Any other change makes a snapshot step stale.
        var other = before; other.title = "Neu"
        XCTAssertNil(history.redo(other))
    }

    func testGestureEndingWhereItStartedLeavesNoStep() throws {
        var book = try notebook(pages: 1)
        let a = book.pages[0].id
        var history = NotebookUndoHistory()
        history.record(.ink, changes: [change(&book, a, drawing: "ink")])
        let drag = NotebookUndoHistory.Coalescing(key: "images-a", window: 0.8)
        let start = Date()
        history.record(.images, changes: [change(&book, a, drawing: "moved")], coalescing: drag, now: start)
        history.record(.images, changes: [change(&book, a, drawing: "ink")], coalescing: drag, now: start + 0.1)
        XCTAssertEqual(history.undoCount, 1)
        let outcome = try XCTUnwrap(history.undo(book))
        XCTAssertEqual(outcome.kind, .ink)
        XCTAssertEqual(content(outcome.notebook, a).drawing, Data())
    }

    func testHistoryIsBoundedByStepCount() throws {
        var book = try notebook(pages: 1)
        var history = NotebookUndoHistory()
        for index in 0..<(NotebookUndoHistory.maximumSteps + 20) {
            history.record(.ink, changes: [change(&book, book.pages[0].id, drawing: "\(index)")])
        }
        XCTAssertEqual(history.undoCount, NotebookUndoHistory.maximumSteps)
    }

    // MARK: Focus after deleting the selected page

    func testDeletedSelectionFocusesPreviousPageOtherwiseNext() {
        let ids = (0..<4).map { _ in UUID() }
        XCTAssertEqual(PageRemovalFocus.focus(removed: ids[2], before: ids, after: [ids[0], ids[1], ids[3]]), ids[1])
        XCTAssertEqual(PageRemovalFocus.focus(removed: ids[0], before: ids, after: Array(ids.dropFirst())), ids[1])
        XCTAssertEqual(PageRemovalFocus.focus(removed: ids[3], before: ids, after: Array(ids.dropLast())), ids[2])
        // The previous page was removed at the same time: the next earlier survivor.
        XCTAssertEqual(PageRemovalFocus.focus(removed: ids[2], before: ids, after: [ids[0], ids[3]]), ids[0])
        XCTAssertEqual(PageRemovalFocus.focus(removed: ids[1], before: ids, after: ids), ids[1])
        XCTAssertNil(PageRemovalFocus.focus(removed: ids[1], before: ids, after: []))
    }
}
