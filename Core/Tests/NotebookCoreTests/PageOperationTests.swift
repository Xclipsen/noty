import Foundation
import XCTest
@testable import NotebookCore

final class PageOperationTests: XCTestCase {
    private func legacy() throws -> Notebook {
        var value = Notebook()
        value.pdf = Data("unveränderte Original-PDF".utf8) // Binary semantics are checked with PDFKit on iPad.
        value.pages = try [0, 90, 180, 270].enumerated().map { index, rotation in
            var page = Page(); page.text = "Seite \(index)"; page.drawing = Data([UInt8(index), 20, 30])
            if index != 0 {
                page.geometry = try PDFPageGeometry(mediaBox: .init(x: 10, y: 20, width: 700, height: 900),
                    cropBox: .init(x: 30, y: 40, width: 600, height: 800), rotation: rotation)
            }
            return page
        }
        return value
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return root
    }

    func testMigrationRetainsAllIDsPositionsLayersAndOriginalBytes() throws {
        let original = try legacy()
        let upgraded = try original.preparedForPageEditing()
        XCTAssertEqual(original.schemaVersion, 2)
        XCTAssertEqual(upgraded.schemaVersion, 3)
        XCTAssertEqual(upgraded.id, original.id)
        XCTAssertNil(upgraded.pdf)
        XCTAssertEqual(upgraded.pdfSources?.first?.data, original.pdf)
        XCTAssertEqual(upgraded.pdfSources?.first?.pageCount, 4)
        for (index, page) in upgraded.pages.enumerated() {
            XCTAssertEqual(page.id, original.pages[index].id)
            XCTAssertEqual(page.geometry, original.pages[index].geometry)
            XCTAssertEqual(page.drawing, original.pages[index].drawing)
            XCTAssertEqual(page.text, original.pages[index].text)
            XCTAssertEqual(page.pdfReference?.pageIndex, index)
        }
        XCTAssertEqual(try Notebook.decode(JSONEncoder().encode(upgraded)), upgraded)
        XCTAssertEqual(try upgraded.preparedForPageEditing(), upgraded)
    }

    func testReorderKeepsInkTextAndPDFPageTogether() throws {
        var document = try legacy()
        let ids = document.pages.map(\.id)
        try document.reorderPages([ids[3], ids[0], ids[2], ids[1]])
        XCTAssertEqual(document.pages.map(\.text), ["Seite 3", "Seite 0", "Seite 2", "Seite 1"])
        XCTAssertEqual(document.pages.map { $0.pdfReference?.pageIndex }, [3, 0, 2, 1])
        XCTAssertEqual(document.pages.map { $0.drawing.first }, [3, 0, 2, 1])
        XCTAssertNil(document.pages[1].geometry) // Fixed legacy A4 remains fixed after reorder.
        try document.movePage(ids[3], to: 3)
        XCTAssertEqual(document.pages.last?.pdfReference?.pageIndex, 3)
    }

    func testDuplicateCopiesEditableLayersAndSharesOnlyImmutableSource() throws {
        var document = try legacy()
        let original = document.pages[1]
        let copyID = try document.duplicatePage(original.id)
        XCTAssertNotEqual(copyID, original.id)
        XCTAssertEqual(document.pages[1].pdfReference, document.pages[2].pdfReference)
        document.pages[2].text = "Nur Kopie"; document.pages[2].drawing.append(99)
        XCTAssertEqual(document.pages[1].text, original.text)
        XCTAssertEqual(document.pages[1].drawing, original.drawing)
        XCTAssertEqual(document.pdfSources?.count, 1)
    }

    func testInsertMixedPaperAndSecondPDFWithoutRewritingFirstSource() throws {
        var document = try legacy()
        let bytes = document.pdf
        let oldIDs = document.pages.map(\.id)
        let grid = try document.insertPaper(.grid, at: 2)
        let other = Data("Zweite PDF".utf8)
        let added = try document.insertPDF(other, geometries: [PaperStyle.geometry, PaperStyle.geometry], at: 1)
        XCTAssertEqual(document.pages.map(\.id), [oldIDs[0]] + added + [oldIDs[1], grid, oldIDs[2], oldIDs[3]])
        XCTAssertEqual(document.pdfSources?.map(\.data), [bytes!, other])
        XCTAssertEqual(document.pages[4].paper, .grid)
        XCTAssertEqual(document.pages[4].geometry?.displaySize, .a4)
        XCTAssertEqual(document.pages[5].pdfReference?.pageIndex, 2)
        XCTAssertNotEqual(document.pages[1].pdfReference?.sourceID, document.pages[0].pdfReference?.sourceID)
    }

    func testTrashRestoreUsesStableNeighborsAndKeepsSourceAndLayers() throws {
        var document = try legacy()
        let id = document.pages[1].id
        let next = document.pages[2].id
        let original = document.pages[1]
        try document.trashPage(id, at: Date(timeIntervalSince1970: 123))
        try document.movePage(next, to: 0)
        let archived = try BackupArchive.decode(BackupArchive.encode(document)).document
        XCTAssertEqual(archived, document)
        try document.restorePage(id)
        XCTAssertEqual(document.pages[0].id, id)
        XCTAssertEqual(document.pages[1].id, next)
        XCTAssertEqual(document.pages[0].text, original.text)
        XCTAssertEqual(document.pages[0].drawing, original.drawing)
        XCTAssertTrue(document.deletedPages?.isEmpty == true)
        XCTAssertEqual(document.pdfSources?.count, 1)
    }

    func testRestoreWhenBothNeighborsDeletedFallsBackToBoundedOriginalPosition() throws {
        var document = try legacy()
        let ids = document.pages.map(\.id)
        try document.trashPage(ids[1]); try document.trashPage(ids[0]); try document.trashPage(ids[2])
        try document.restorePage(ids[1])
        XCTAssertEqual(document.pages.map(\.id), [ids[3], ids[1]])
        XCTAssertEqual(document.deletedPages?.count, 2)
    }

    func testRejectedOperationsNeverPartiallyMigrateOrChangeCurrentDocument() throws {
        var document = try legacy()
        let original = document
        XCTAssertThrowsError(try document.reorderPages([UUID()]))
        XCTAssertThrowsError(try document.insertPaper(.grid, at: -1))
        XCTAssertThrowsError(try document.duplicatePage(UUID()))
        XCTAssertThrowsError(try document.movePage(document.pages[0].id, to: 4))
        XCTAssertThrowsError(try document.insertPDF(Data(), geometries: [PaperStyle.geometry], at: 0))
        XCTAssertEqual(document, original)
        var single = Notebook()
        XCTAssertThrowsError(try single.trashPage(single.pages[0].id))
        XCTAssertEqual(single.schemaVersion, 2)
    }

    func testInvalidSourceReferencesAmbiguousLayersAndDuplicateIDsAreRejected() throws {
        let valid = try legacy().preparedForPageEditing()
        var bad = valid; bad.pages[0].pdfReference?.sourceID = UUID()
        XCTAssertThrowsError(try Notebook.decode(JSONEncoder().encode(bad)))
        bad = valid; bad.pages[0].pdfReference?.pageIndex = 4
        XCTAssertThrowsError(try bad.validate())
        bad = valid; bad.pages[0].pdfReference?.pageIndex = -1
        XCTAssertThrowsError(try bad.validate())
        bad = valid; bad.pages[0].paper = .blank
        XCTAssertThrowsError(try bad.validate())
        bad = valid; bad.pdfSources?.append(valid.pdfSources![0])
        XCTAssertThrowsError(try bad.validate())
        bad = valid; bad.pdf = Data([1])
        XCTAssertThrowsError(try bad.validate())
        bad = valid; bad.schemaVersion = 2
        XCTAssertThrowsError(try bad.validate())
        bad = valid; try bad.trashPage(bad.pages[0].id)
        bad.pages[0].id = bad.deletedPages![0].page.id
        XCTAssertThrowsError(try bad.validate())
    }

    func testPaperGeometryCannotPretendToBeImportedPDF() throws {
        var value = Notebook.blank(title: "Blanko")
        XCTAssertNoThrow(try value.validate())
        value.pages[0].geometry = nil
        XCTAssertThrowsError(try value.validate())
        let legacy = try Notebook().preparedForPageEditing()
        XCTAssertEqual(legacy.pages[0].paper, .legacyTest)
        XCTAssertNil(legacy.pages[0].geometry)
    }

    func testPageLimitFailureIsTransactionalAndRestoreStillAvailableAfterDeleting() throws {
        var value = Notebook.blank(title: "Grenze")
        let template = value.pages[0]
        value.pages = (0..<500).map { _ in var page = template; page.id = UUID(); return page }
        let original = value
        XCTAssertThrowsError(try value.duplicatePage(value.pages[0].id))
        XCTAssertThrowsError(try value.insertPaper(.lined, at: 0))
        XCTAssertEqual(value, original)
        let id = value.pages[42].id
        try value.trashPage(id); try value.restorePage(id)
        XCTAssertEqual(value.pages, original.pages)
    }

    func testSchemaMigrationArchiveSurvivesRevisionGarbageCollection() throws {
        let root = try temporaryRoot()
        let store = RevisionStore(directory: root)
        let original = try legacy()
        try store.save(original)
        let manifest = try JSONDecoder().decode(RevisionManifest.self, from: Data(contentsOf: root.appendingPathComponent("manifest.json")))
        let bytes = try Data(contentsOf: root.appendingPathComponent("Revisions/" + manifest.revisions[0].file))
        var edited = try store.load()
        _ = try edited.insertPaper(.lined, at: 1)
        try store.save(edited)
        for index in 0..<8 { edited.pages[1].text = "Stand \(index)"; try store.save(edited) }
        let migrations = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("Migrations"), includingPropertiesForKeys: nil)
        XCTAssertEqual(migrations.count, 1)
        let preserved = migrations[0].appendingPathComponent("notebook-v2.json")
        XCTAssertEqual(try Data(contentsOf: preserved), bytes)
        XCTAssertEqual(try Notebook.decode(Data(contentsOf: preserved)), original)
        XCTAssertEqual(try RevisionStore(directory: root).load(), edited)
    }

    func testMigrationArchiveFailureLeavesAcknowledgedManifestAndRevisionUntouched() throws {
        let root = try temporaryRoot(); let store = RevisionStore(directory: root)
        let original = try legacy(); try store.save(original)
        let manifest = try Data(contentsOf: root.appendingPathComponent("manifest.json"))
        try Data([1]).write(to: root.appendingPathComponent("Migrations"))
        var edited = original; try edited.movePage(edited.pages[0].id, to: 3)
        XCTAssertThrowsError(try store.save(edited))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("manifest.json")), manifest)
        XCTAssertEqual(try RevisionStore(directory: root).load(), original)
    }

    func testWholeLibraryAndHeftRestoreKeepTrashSourceReferencesAndIndependentCopies() async throws {
        let root = try temporaryRoot()
        var original = try legacy()
        let removed = original.pages[2].id
        try original.trashPage(removed)
        _ = try original.insertPaper(.grid, at: 1)
        let library = LibraryStore(root: root.appendingPathComponent("LibrarySource"))
        _ = try await library.load()
        _ = try await library.createDocument(original, parentID: nil)
        let exported = try await library.backupBundle()
        let decoded = try LibraryArchive.decode(LibraryArchive.encode(exported))
        XCTAssertEqual(decoded.documents, [original])
        let archive = root.appendingPathComponent("notebook.notybackup")
        try BackupArchive.encode(original).write(to: archive)
        let repository = NotebookRepository(directory: root.appendingPathComponent("Repository"))
        let prepared = try await repository.prepareRestore(from: archive)
        let entry = try await repository.commitRestore(prepared)
        var copy = try RevisionStore(directory: entry.directory).load()
        XCTAssertEqual(copy.deletedPages, original.deletedPages)
        XCTAssertEqual(copy.pdfSources, original.pdfSources)
        try copy.restorePage(removed)
        copy.pages[0].drawing.append(44)
        XCTAssertNotEqual(copy.id, original.id)
        XCTAssertFalse(original.pages.contains(where: { $0.id == removed }))
        XCTAssertNotEqual(copy.pages[0].drawing, original.pages[0].drawing)
    }
}
