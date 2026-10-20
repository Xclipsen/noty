import Foundation
import XCTest
@testable import NotebookCore

/// Permanent deletion from the page trash and PDF source cleanup.
final class PageTrashPurgeTests: XCTestCase {
    private let box = PageRect(x: 0, y: 0, width: 300, height: 400)
    private func sorted(_ sources: [PDFSource]?) -> [PDFSource] {
        (sources ?? []).sorted { $0.id.uuidString < $1.id.uuidString }
    }

    /// Paper page + two imported PDFs (2 and 1 pages).
    private func notebook() throws -> (Notebook, first: [UUID], second: [UUID]) {
        let geometry = try PDFPageGeometry(mediaBox: box, cropBox: box, rotation: 0)
        var book = Notebook.blank(title: "Papierkorb")
        let first = try book.insertPDF(Data("%PDF-erste".utf8), geometries: [geometry, geometry], at: 1)
        let second = try book.insertPDF(Data("%PDF-zweite".utf8), geometries: [geometry], at: 3)
        return (book, first, second)
    }

    func testDeletingLastReferenceRemovesOnlyThatSourceAndKeepsOtherBytes() throws {
        var (book, first, second) = try notebook()
        let sources = try XCTUnwrap(book.pdfSources)
        try book.trashPage(first[0])
        try book.trashPage(second[0])
        try book.deleteTrashedPage(second[0])
        // The first PDF is still used by an active page; the second by nothing.
        XCTAssertEqual(book.pdfSources, [sources[0]])
        XCTAssertEqual(book.deletedPages?.map(\.id), [first[0]])
        try book.deleteTrashedPage(first[0])
        XCTAssertEqual(book.pdfSources, [sources[0]])
        XCTAssertEqual(book.deletedPages, [])
        XCTAssertThrowsError(try book.deleteTrashedPage(first[0])) { error in
            guard case PageOperationError.missingPage = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(try Notebook.decode(JSONEncoder().encode(book)), book)
    }

    /// C6: deleting a trashed page with an image drops only the reference.
    /// The asset file stays (older revisions still name it); freeing it is the
    /// asset GC's job (C7), never a commit's.
    func testPermanentDeletionKeepsTheImageAssetFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("purge-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let photo = Data((0..<800).map { UInt8(truncatingIfNeeded: $0 &* 3) })
        let store = RevisionStore(directory: root)
        var (book, first, _) = try notebook()
        _ = try store.assets.stage(photo)
        try book.replaceImages([.test(bytes: photo)], pageID: first[0])
        try store.save(book)
        try book.trashPage(first[0])
        XCTAssertEqual(book.uniqueImageAssetBytes, photo.count, "the page trash counts")
        try book.deleteTrashedPage(first[0])
        XCTAssertEqual(book.uniqueImageAssetBytes, 0)
        XCTAssertEqual(book.schemaVersion, 12, "removing images never lowers the schema")
        try store.save(book)
        XCTAssertEqual(try RevisionStore(directory: root).load(), book)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("Assets/\(ImageAssetReference(of: photo).sha256)")), photo)
    }

    func testTrashedReferenceKeepsSourceAndEmptyTrashRemovesMarginSnapshotsToo() throws {
        var (book, first, _) = try notebook()
        let sources = try XCTUnwrap(book.pdfSources)
        book.pages[1].drawing = Data([1, 2, 3])
        try book.applyMargins(PageMargins(right: 40), pageIDs: [first[0]], trimmedDrawings: [first[0]: Data([1])])
        let snapshot = try XCTUnwrap(book.deletedPages?.first)
        XCTAssertEqual(snapshot.reason, .marginReduction)
        try book.trashPage(first[1])
        try book.trashPage(first[0])
        // Only trash entries still reference the first PDF: it must stay.
        XCTAssertFalse(book.pages.contains { $0.pdfReference?.sourceID == sources[0].id })
        try book.deleteTrashedPage(first[1])
        XCTAssertTrue(book.pdfSources?.contains(sources[0]) == true)
        let schema = book.schemaVersion
        try book.emptyPageTrash()
        XCTAssertEqual(book.deletedPages, [])
        XCTAssertEqual(book.pdfSources, [sources[1]])
        XCTAssertEqual(book.schemaVersion, schema)
        XCTAssertEqual(try Notebook.decode(JSONEncoder().encode(book)), book)
        let unchanged = book
        try book.emptyPageTrash()
        XCTAssertEqual(book, unchanged)
    }

    func testFullTrashCanBeEmptiedAndAcceptsDeletedPagesAgain() throws {
        var book = Notebook.blank(title: "Viele Seiten")
        let anchor = book.pages[0].id
        book.deletedPages = (0..<500).map { _ in
            var page = Page(); page.paper = .lined; page.geometry = PaperStyle.geometry
            return DeletedPage(page: page, originalIndex: 1, deletedAt: Date(), nextPageID: nil, previousPageID: anchor)
        }
        try book.validate()
        let extra = try book.insertPaper(.grid, at: 1)
        XCTAssertThrowsError(try book.trashPage(extra)) { error in
            guard case PageOperationError.trashLimit = error else { return XCTFail("\(error)") }
        }
        try book.emptyPageTrash()
        try book.trashPage(extra)
        XCTAssertEqual(book.deletedPages?.map(\.id), [extra])
    }

    func testPermanentDeletionIsOneUndoStepRestoringEntriesAndSourceBytes() throws {
        var (book, first, second) = try notebook()
        try book.trashPage(second[0])
        try book.trashPage(first[1])
        var history = NotebookUndoHistory()
        let before = book
        try book.emptyPageTrash()
        XCTAssertTrue(history.recordPages(before: before, after: book, undoPageID: book.pages[0].id, redoPageID: book.pages[0].id))
        let emptied = book
        XCTAssertEqual(book.pdfSources?.count, 1)

        let undone = try XCTUnwrap(history.undo(book))
        try undone.notebook.validate()
        XCTAssertEqual(undone.notebook.deletedPages, before.deletedPages)
        XCTAssertEqual(sorted(undone.notebook.pdfSources), sorted(before.pdfSources))
        XCTAssertEqual(undone.notebook.pages, before.pages)
        let redone = try XCTUnwrap(history.redo(undone.notebook))
        XCTAssertEqual(redone.notebook, emptied)

        var single = before
        try single.deleteTrashedPage(second[0])
        var step = NotebookUndoHistory()
        XCTAssertTrue(step.recordPages(before: before, after: single, undoPageID: single.pages[0].id, redoPageID: single.pages[0].id))
        let restored = try XCTUnwrap(step.undo(single)).notebook
        XCTAssertEqual(restored.deletedPages, before.deletedPages)
        XCTAssertEqual(sorted(restored.pdfSources), sorted(before.pdfSources))
    }

    func testLegacyNotebookWithoutTrashIsLeftUntouched() throws {
        var legacy = Notebook()
        legacy.pdf = Data("alt".utf8)
        let original = legacy
        try legacy.emptyPageTrash()
        XCTAssertEqual(legacy, original)
        XCTAssertThrowsError(try legacy.deleteTrashedPage(UUID()))
        XCTAssertEqual(legacy, original)
    }
}
