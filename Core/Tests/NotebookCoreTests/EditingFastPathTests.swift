import Foundation
import XCTest
@testable import NotebookCore

/// Audit S1/S15/S19: hot editing paths skip only redundant passes. Results and
/// errors stay those of the validating path; the final validation still sees
/// the whole notebook.
final class EditingFastPathTests: XCTestCase {
    private func prepared() throws -> Notebook {
        var book = try Notebook.blank(title: "Schnellweg").preparedForTextEditing()
        _ = try book.insertPaper(.lined, at: 1)
        _ = try book.insertPaper(.grid, at: 2)
        try book.replaceTextBoxes([TextBox(x: 40, y: 40, text: "Seite zwei")], pageID: book.pages[1].id)
        try book.trashPage(book.pages[2].id)
        return book
    }

    private func trashEntry(_ entry: DeletedPage, _ change: (inout Page) -> Void) -> DeletedPage {
        var page = entry.page; change(&page)
        return DeletedPage(page: page, originalIndex: entry.originalIndex, deletedAt: entry.deletedAt,
            nextPageID: entry.nextPageID, previousPageID: entry.previousPageID, reason: entry.reason)
    }

    private func describe(_ body: () throws -> Void) -> String? {
        do { try body(); return nil } catch { return String(describing: error) }
    }

    func testPreparedNotebooksTakeOnlyAnIdentityMigration() throws {
        let book = try prepared()
        XCTAssertTrue(book.isPreparedForTextEditing)
        XCTAssertEqual(try book.preparedForTextEditing(), book, "skipping returns exactly what the migration would")
        XCTAssertEqual(try book.preparedForPageEditing(), book)
        XCTAssertEqual(try book.editableForText(), book)

        var legacyText = Notebook(); legacyText.pages[0].text = "Altes Feld"
        XCTAssertFalse(legacyText.isPreparedForTextEditing)
        let migrated = try legacyText.editableForText()
        XCTAssertEqual(migrated, try legacyText.preparedForTextEditing(), "legacy notebooks still migrate")
        XCTAssertTrue(migrated.isPreparedForTextEditing)

        var legacyPDF = Notebook(); legacyPDF.pdf = Data([1, 2])
        XCTAssertFalse(legacyPDF.isPreparedForTextEditing)
        let pagePrepared = try legacyPDF.editableForPages()
        XCTAssertEqual(pagePrepared.pdfSources?.count, 1, "legacy PDF notebooks still migrate")
        XCTAssertEqual(try pagePrepared.editableForPages(), pagePrepared)

        // A legacy text in the page trash still needs the migration.
        var trashed = book
        trashed.deletedPages![0] = trashEntry(trashed.deletedPages![0]) { $0.textBoxes = nil; $0.text = "Im Papierkorb" }
        XCTAssertFalse(trashed.isPreparedForTextEditing)
    }

    func testEditsMatchTheValidatingPath() throws {
        let book = try prepared()
        let id = book.pages[0].id
        let boxes = [TextBox(x: 60, y: 80, text: "Neu", style: TextBoxStyle(color: .blue))]
        var fast = book
        try fast.replaceTextBoxes(boxes, pageID: id)
        var reference = try book.preparedForTextEditing()
        reference.raiseSchemaForTextColors(boxes); reference.raiseSchemaForTextFields(boxes)
        reference.pages[0].textBoxes = boxes
        try reference.validate()
        XCTAssertEqual(fast, reference)

        var images = book
        let image = ImageObject.test(bytes: Data((0..<64).map { UInt8($0) }))
        try images.replaceImages([image], pageID: id)
        XCTAssertEqual(images.pages[0].images, [image])
        XCTAssertEqual(images.schemaVersion, max(Notebook.imageAssetSchemaVersion, book.schemaVersion))

        var shapes = book
        let shape = ShapeObject(kind: .rectangle, start: PagePoint(x: 50, y: 50), end: PagePoint(x: 150, y: 120))
        try shapes.replaceShapes([shape], pageID: id)
        XCTAssertEqual(shapes.pages[0].shapes, [shape])
        XCTAssertEqual(shapes.schemaVersion, max(6, book.schemaVersion))
    }

    /// The leading validation is gone, so a damaged state elsewhere must still
    /// be refused by the final one, with the same error and `self` untouched.
    func testDamageElsewhereIsStillRejectedWithTheSameError() throws {
        let valid = try prepared()
        let target = valid.pages[0].id
        var damagedActive = valid; damagedActive.pages[1].textBoxes = [TextBox(width: 0)]
        var damagedTrash = valid
        damagedTrash.deletedPages![0] = trashEntry(damagedTrash.deletedPages![0]) { $0.textBoxes = [TextBox(height: .nan)] }
        var unsupported = valid; unsupported.schemaVersion = Notebook.currentSchemaVersion + 1

        let field = TextBox(x: 60, y: 80, text: "Neu")
        // A valid notebook, but the new field reuses an ID from another page.
        var sharedField = field; sharedField.id = valid.pages[1].textBoxes![0].id
        let cases: [(Notebook, [TextBox], textOnly: Bool)] = [(damagedActive, [field], false), (damagedTrash, [field], false),
                                                             (valid, [sharedField], true), (unsupported, [field], false)]
        for (book, boxes, textOnly) in cases {
            XCTAssertTrue(book.isPreparedForTextEditing)
            let before = book
            let content = PageContent(page: book.pages[0])
            var withBoxes = content; withBoxes.textBoxes = boxes
            let operations: [(inout Notebook) throws -> Void] = [
                { try $0.replaceTextBoxes(boxes, pageID: target) },
                { try $0.replaceImages([], pageID: target) },
                { try $0.replaceShapes([], pageID: target) },
                { try $0.replaceContent(withBoxes, pageID: target) },
                { try $0.replaceContents([PageContentReplacement(pageID: target, expected: content, replacement: withBoxes)]) },
            ]
            for (index, operation) in operations.enumerated() where !textOnly || ![1, 2].contains(index) {
                var copy = book
                let error = describe { try operation(&copy) }
                XCTAssertNotNil(error)
                XCTAssertEqual(copy, before, "nothing is published")
                var old = book
                // The validating path reaches the same verdict.
                let expected = describe { old = try old.preparedForTextEditing(); try operation(&old) }
                XCTAssertEqual(error, expected)
            }
        }
    }

    // MARK: S15

    private func pdfNotebook() throws -> Notebook {
        var book = Notebook()
        book.pdf = Data([1, 2, 3])
        let sizes: [(Double, Double, Int)] = [(595, 842, 0), (842, 595, 0), (420, 595, 90), (595, 842, 0)]
        book.pages = try sizes.map { width, height, rotation in
            var page = Page()
            page.geometry = try PDFPageGeometry(mediaBox: .init(x: 0, y: 0, width: width, height: height),
                                                cropBox: .init(x: 0, y: 0, width: width, height: height), rotation: rotation)
            return page
        }
        return book
    }

    func testBatchMarginsEqualThePerPageLoop() throws {
        let area = PageMargins(left: 0.1, right: 0.3, top: 0.05, bottom: 0.2)
        for legacy in [true, false] {
            let book = legacy ? try pdfNotebook() : try pdfNotebook().preparedForPageEditing()
            var looped = book, batched = book
            var assignments: [UUID: PageMargins] = [:]
            for page in book.pages {
                let margins = try area.scaled(from: .init(width: 1, height: 1), to: page.geometry?.displaySize ?? .a4)
                try looped.setMargins(margins, pageIDs: [page.id])
                assignments[page.id] = margins
            }
            try batched.setMargins(assignments)
            XCTAssertEqual(batched.pdfSources?.count, 1)
            // The migration creates a new source ID; everything else must agree.
            batched.pdfSources = looped.pdfSources
            for index in batched.pages.indices { batched.pages[index].pdfReference = looped.pages[index].pdfReference }
            XCTAssertEqual(batched, looped)
        }

        var paper = Notebook.blank(title: "Papier"); paper.pages[0].paper = .lined
        _ = try paper.insertPaper(.grid, color: .dark, at: 1)
        var looped = paper, batched = paper
        let wide = PageMargins(right: 300, bottom: 200, style: .blank, color: .white)
        for page in paper.pages { try looped.setMargins(wide, pageIDs: [page.id]) }
        try batched.setMargins(Dictionary(uniqueKeysWithValues: paper.pages.map { ($0.id, wide) }))
        XCTAssertEqual(batched, looped)
        XCTAssertEqual(batched.schemaVersion, 11)
        XCTAssertEqual(batched.pages[1].margins?.style, .grid, "each page keeps its own paper")
    }

    func testBatchMarginsAreAllOrNothing() throws {
        let book = try pdfNotebook().preparedForPageEditing()
        let good = PageMargins(right: 50)
        for assignments in [[:], [book.pages[0].id: good, UUID(): good],
                            [book.pages[0].id: good, book.pages[1].id: PageMargins(right: -.infinity)]] as [[UUID: PageMargins]] {
            var copy = book
            XCTAssertThrowsError(try copy.setMargins(assignments))
            XCTAssertEqual(copy, book)
        }
        var legacy = Notebook()
        let before = legacy
        XCTAssertThrowsError(try legacy.setMargins([legacy.pages[0].id: good]), "legacy test sheet takes no writing space")
        XCTAssertEqual(legacy, before)
    }

    // MARK: S19

    func testCancelledWaiterGivesUpAtOnce() async throws {
        let lock = PackageWriteLock()
        let package = FileManager.default.temporaryDirectory.appendingPathComponent("wait-\(UUID().uuidString)")
        let held = try XCTUnwrap(lock.claim(package))
        let started = Date()
        let waiter = Task { await lock.claim(package, waitingUpTo: 10) }
        waiter.cancel()
        let result = await waiter.value
        XCTAssertNil(result)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2, "no spinning until the deadline")
        XCTAssertTrue(lock.isHeld(package))
        held.release()
    }
}
