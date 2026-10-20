import Foundation
import XCTest
@testable import NotebookCore

/// PDF originals up to 100 MB each, 100 MB per notebook including the page trash.
final class PDFSourceLimitTests: XCTestCase {
    private func geometry() throws -> PDFPageGeometry {
        let box = PageRect(x: 0, y: 0, width: 300, height: 400)
        return try PDFPageGeometry(mediaBox: box, cropBox: box, rotation: 0)
    }

    func testSourcesAbove20MBAreAcceptedUpTo100MB() throws {
        var book = Notebook.blank(title: "Großes Skript")
        _ = try book.insertPDF(Data(count: 25_000_000), geometries: [try geometry()], at: 1)
        try book.validate()
        XCTAssertEqual(book.schemaVersion, 10)
        var full = Notebook.blank(title: "Maximum")
        _ = try full.insertPDF(Data(count: PDFSource.maximumBytes), geometries: [try geometry()], at: 1)
        try full.validate()
        XCTAssertEqual(full.schemaVersion, 10)
        // ~133 MB as Base64 plus page data: one revision/backup (200 MB) still fits.
        let encoded = try JSONEncoder().encode(full)
        XCTAssertLessThan(encoded.count, 200_000_000)
        XCTAssertGreaterThan(encoded.count, 133_000_000)
        XCTAssertEqual(try Notebook.decode(encoded).pdfSources?.first?.data.count, PDFSource.maximumBytes)
    }

    func testPerSourceAndTotalLimitsAreReportedBeforeInsertion() throws {
        var book = Notebook.blank(title: "Zu groß")
        let original = book
        XCTAssertThrowsError(try book.insertPDF(Data(count: PDFSource.maximumBytes + 1), geometries: [try geometry()], at: 1)) { error in
            guard case PageOperationError.sourceLimit = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(book, original)
        let first = try book.insertPDF(Data(count: 60_000_000), geometries: [try geometry()], at: 1)
        // Trashed pages keep their source: it still counts towards the total.
        try book.trashPage(first[0])
        XCTAssertThrowsError(try book.insertPDF(Data(count: 50_000_000), geometries: [try geometry()], at: 1)) { error in
            guard case PageOperationError.sourceLimit = error else { return XCTFail("\(error)") }
        }
        try book.emptyPageTrash()
        _ = try book.insertPDF(Data(count: 50_000_000), geometries: [try geometry()], at: 1)
        XCTAssertEqual(book.pdfSources?.count, 1)
    }

    func testValidationRejectsOversizedSourcesFromFiles() throws {
        var book = Notebook.blank(title: "Datei")
        book.schemaVersion = 10
        book.pdfSources = [PDFSource(data: Data(count: PDFSource.maximumBytes + 1), pageCount: 1)]
        XCTAssertThrowsError(try book.validate())
        book.pdfSources = [PDFSource(data: Data(count: 60_000_000), pageCount: 1),
                           PDFSource(data: Data(count: 41_000_000), pageCount: 1)]
        XCTAssertThrowsError(try book.validate())
        book.pdfSources = [PDFSource(data: Data(count: 60_000_000), pageCount: 1),
                           PDFSource(data: Data(count: 40_000_000), pageCount: 1)]
        XCTAssertNoThrow(try book.validate())
    }

    // MARK: Build 46 compatibility (schema 10)

    /// Replica of Build 46 `Notebook.decode`: the header is checked against
    /// schema 1…9 before any validation, so a newer notebook is refused with
    /// unsupportedSchema (Build 46 then neither falls back nor saves).
    private func build46Decode(_ data: Data) throws {
        struct Header: Decodable { var schemaVersion: Int }
        let version = try JSONDecoder().decode(Header.self, from: data).schemaVersion
        guard (1...9).contains(version) else { throw StorageError.unsupportedSchema(version) }
        try Notebook.decode(data).validate()
    }

    func testOnlyLargeSourcesRaiseTheSchemaAndBuild46RefusesThem() throws {
        var small = Notebook.blank(title: "20 MB")
        _ = try small.insertPDF(Data(count: PDFSource.legacyMaximumBytes), geometries: [try geometry()], at: 1)
        XCTAssertEqual(small.schemaVersion, 3)
        XCTAssertNoThrow(try build46Decode(JSONEncoder().encode(small)))
        var large = small
        _ = try large.insertPDF(Data(count: PDFSource.legacyMaximumBytes + 1), geometries: [try geometry()], at: 1)
        XCTAssertEqual(large.schemaVersion, 10)
        XCTAssertThrowsError(try build46Decode(JSONEncoder().encode(large))) { error in
            guard case StorageError.unsupportedSchema(10) = error else { return XCTFail("\(error)") }
        }
        var lowered = large
        lowered.schemaVersion = 9
        XCTAssertThrowsError(try lowered.validate())
        XCTAssertThrowsError(try Notebook.decode(JSONEncoder().encode(lowered)))
    }

    func testEveryEntryPathRaisesAndNoEditLowersTheSchema() throws {
        // Legacy single PDF converted for page editing.
        var legacy = Notebook()
        legacy.pdf = Data(count: 21_000_000)
        XCTAssertEqual(legacy.schemaVersion, 2)
        XCTAssertEqual(try legacy.preparedForPageEditing().schemaVersion, 10)
        // Pasting a page with such a source into a small notebook.
        var large = Notebook.blank(title: "Groß")
        let ids = try large.insertPDF(Data(count: 21_000_000), geometries: [try geometry()], at: 1)
        var target = Notebook.blank(title: "Ziel")
        _ = try target.pastePage(large.copyPage(ids[0]), after: target.pages[0].id)
        XCTAssertEqual(target.schemaVersion, 10)
        // Undo of the insertion and removing the source keep schema 10.
        var history = NotebookUndoHistory()
        var book = Notebook.blank(title: "Undo")
        let before = book
        let inserted = try book.insertPDF(Data(count: 21_000_000), geometries: [try geometry()], at: 1)
        XCTAssertTrue(history.recordPages(before: before, after: book, undoPageID: book.pages[0].id, redoPageID: book.pages[0].id))
        let undone = try XCTUnwrap(history.undo(book)).notebook
        XCTAssertEqual(undone.pdfSources, [])
        XCTAssertEqual(undone.schemaVersion, 10)
        try book.trashPage(inserted[0])
        try book.emptyPageTrash()
        XCTAssertEqual(book.pdfSources, [])
        XCTAssertEqual(book.schemaVersion, 10)
        // Text and margin edits start from the current schema.
        var text = large
        try text.replaceTextBoxes([TextBox(x: 10, y: 10, width: 100, height: 40, text: "Notiz")], pageID: ids[0])
        XCTAssertEqual(text.schemaVersion, 10)
        try text.setMargins(PageMargins(right: 30), pageIDs: [ids[0]])
        XCTAssertEqual(text.schemaVersion, 10)
    }

    func testCopiesAndRestoresKeepSchemaTenAndMigrationArchivesExactOldBytes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = NotebookRepository(directory: root)
        var book = Notebook.blank(title: "Skript")
        try await repository.save(book, revision: 1)
        let acknowledged = try Data(contentsOf: root.appendingPathComponent("Revisions/" + (try await repository.localHistory()).revisions[0].id.uuidString + ".json"))
        _ = try book.insertPDF(Data(count: 20_000_001), geometries: [try geometry()], at: 1)
        try await repository.save(book, revision: 2)
        // The first schema-10 commit archived the exact acknowledged schema-3 bytes.
        let migrations = root.appendingPathComponent("Migrations")
        let folders = try FileManager.default.contentsOfDirectory(atPath: migrations.path)
        XCTAssertEqual(folders.count, 1)
        XCTAssertEqual(try Data(contentsOf: migrations.appendingPathComponent(folders[0] + "/notebook-v3.json")), acknowledged)
        // Local-revision copies keep the schema (library duplicates copy the value too).
        let history = try await repository.localHistory()
        let prepared = try await repository.prepareLocalRecovery(id: history.revisions[0].id)
        XCTAssertEqual(prepared.document.schemaVersion, 10)
        XCTAssertNotEqual(prepared.document.id, book.id)
    }
}
