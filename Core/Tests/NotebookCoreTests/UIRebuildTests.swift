import Foundation
import XCTest
@testable import NotebookCore

final class UIRebuildTests: XCTestCase {
    private func richBox() -> TextBox {
        var box = TextBox(x: 0, y: 20, width: 200, height: 80, text: "A🖊️ Wort")
        var style = TextBoxStyle(font: .serif, fontSize: 24, bold: true, color: .blue)
        style.highlighted = true; style.link = "https://example.org"; style.alignment = .center; style.indent = 20
        box.runs = [TextRun(location: 5, length: 4, style: style)]
        return box
    }
    func testRichUnicodeFormattingSurvivesArchiveDuplicationAndClearRestore() throws {
        var book = Notebook.blank(title: "Formatierung")
        let id = book.pages[0].id, box = richBox()
        try book.replaceTextBoxes([box], pageID: id)
        XCTAssertEqual(book.schemaVersion, 7)
        let copy = try book.duplicatePage(id)
        let duplicated = try XCTUnwrap(book.pages.first { $0.id == copy }?.textBoxes?.first)
        XCTAssertNotEqual(duplicated.id, box.id); XCTAssertEqual(duplicated.runs, box.runs)
        try book.clearPage(id)
        let archived = try XCTUnwrap(book.deletedPages?.first)
        XCTAssertEqual(archived.reason, .cleared)
        XCTAssertTrue(book.pages.first { $0.id == id }!.effectiveTextBoxes.isEmpty)
        XCTAssertEqual(try book.restorePage(archived.id), id)
        XCTAssertEqual(book.pages.first { $0.id == id }?.textBoxes?.first?.runs, box.runs)
        XCTAssertEqual(try BackupArchive.decode(BackupArchive.encode(book)).document, book)
    }
    func testInvalidRunsRejectSurrogateSplitsOverlapAndOutOfBoundsWithoutMutation() throws {
        var book = Notebook.blank(title: "Original")
        let original = book, id = book.pages[0].id
        for runs in [
            [TextRun(location: 2, length: 1, style: TextBoxStyle())],
            [TextRun(location: 1, length: 1, style: TextBoxStyle())],
            [TextRun(location: -1, length: 2, style: TextBoxStyle())],
            [TextRun(location: 0, length: Int.max, style: TextBoxStyle())],
            [TextRun(location: 0, length: 5, style: TextBoxStyle()), TextRun(location: 4, length: 1, style: TextBoxStyle())]
        ] {
            var box = richBox(); box.runs = runs
            XCTAssertThrowsError(try book.replaceTextBoxes([box], pageID: id))
            XCTAssertEqual(book, original)
        }
    }
    func testNewFormattingCannotHideInOldSchemaAndInvalidLinksFail() throws {
        var book = Notebook.blank(title: "Schema")
        try book.replaceTextBoxes([richBox()], pageID: book.pages[0].id)
        book.schemaVersion = 6
        XCTAssertThrowsError(try Notebook.decode(JSONEncoder().encode(book)))
        var box = richBox(); box.runs![0].style.link = "javascript:alert(1)"
        XCTAssertThrowsError(try box.validate())
        box = richBox(); box.runs![0].style.indent = .infinity
        XCTAssertThrowsError(try box.validate())
    }
    func testNotebookDefaultsDoNotCreateCoverPageAndAreRetainedByOtherEditPaths() throws {
        var settings = NotebookAppearance(); settings.cover = .purple; settings.format = .a5
        settings.landscape = true; settings.paper = .grid; settings.color = .dark
        var book = try Notebook.blank(title: "Schule", appearance: settings)
        XCTAssertEqual(book.pages.count, 1)
        XCTAssertEqual(book.pages[0].geometry?.displaySize, PageSize(width: 595, height: 420))
        let next = try book.insertPaper(settings.paper, color: settings.color, at: 1)
        XCTAssertEqual(book.pages[1].geometry, settings.geometry)
        try book.replaceTextBoxes([richBox()], pageID: next)
        try book.replaceImages([], pageID: next)
        XCTAssertEqual(book.schemaVersion, 7); XCTAssertEqual(book.appearance, settings)
        XCTAssertEqual(try Notebook.decode(JSONEncoder().encode(book)), book)
    }
    func testCopyAcrossNotebooksKeepsPDFBytesAndRegeneratesAllObjectIdentities() throws {
        var source = Notebook.blank(title: "Quelle")
        let bytes = Data([1,2,3,4])
        let id = try source.insertPDF(bytes, geometries: [PaperStyle.geometry], at: 1)[0]
        try source.replaceTextBoxes([richBox()], pageID: id)
        let payload = try source.copyPage(id)
        let original = source
        var target = Notebook.blank(title: "Ziel")
        let inserted = try target.pastePage(payload, after: target.pages[0].id)
        XCTAssertNotEqual(inserted, id)
        XCTAssertNotEqual(target.pages[1].textBoxes?.first?.id, source.pages[1].textBoxes?.first?.id)
        XCTAssertEqual(target.pdfSources?.first?.data, bytes)
        XCTAssertEqual(target.pages[1].textBoxes?.first?.runs, source.pages[1].textBoxes?.first?.runs)
        XCTAssertEqual(source, original)
        _ = try target.pastePage(payload, after: inserted)
        XCTAssertEqual(target.pdfSources?.count, 1)
    }
    func testCutMovesLatestPageOnlyAfterPasteAndHandlesSourceBeforeDestination() throws {
        var book = Notebook.blank(title: "Reihenfolge")
        let a = book.pages[0].id
        let b = try book.insertPaper(.lined, at: 1), c = try book.insertPaper(.grid, at: 2)
        let snapshot = try book.copyPage(a)
        XCTAssertEqual(book.pages.map(\.id), [a,b,c])
        book.pages[0].drawing = Data([8,9])
        try book.movePage(a, after: c)
        XCTAssertEqual(book.pages.map(\.id), [b,c,a]); XCTAssertEqual(book.pages[2].drawing, Data([8,9]))
        XCTAssertEqual(snapshot.page.drawing, Data())
        try book.movePage(a, after: a); XCTAssertEqual(book.pages.map(\.id), [b,c,a])
        let before = book
        XCTAssertThrowsError(try book.movePage(a, after: UUID())); XCTAssertEqual(book, before)
    }
    func testClearPreservesOriginalBackgroundAndRestoreSavesInterveningWork() throws {
        var book = Notebook.blank(title: "Leeren")
        let id = try book.insertPDF(Data([1,2]), geometries: [PaperStyle.geometry], at: 1)[0]
        try book.setMargins(PageMargins(right: 100, style: .grid, color: .dark), pageIDs: [id])
        book.pages[1].drawing = Data([5]); let background = book.pages[1]
        try book.clearPage(id)
        let archived = book.deletedPages!.first!.id
        XCTAssertEqual(book.pages[1].pdfReference, background.pdfReference)
        XCTAssertEqual(book.pages[1].margins, background.margins)
        book.pages[1].drawing = Data([6])
        _ = try book.restorePage(archived)
        XCTAssertEqual(book.pages[1].drawing, Data([5]))
        XCTAssertEqual(book.deletedPages?.first?.page.drawing, Data([6]))
        XCTAssertEqual(book.pages.count, 2)
    }
    func testSchemaUpgradeArchivesExactConfirmedOldBytes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RevisionStore(directory: root)
        var old = Notebook.blank(title: "Alt")
        try store.save(old)
        let revision = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("Revisions"), includingPropertiesForKeys: nil)[0]
        let bytes = try Data(contentsOf: revision)
        try old.replaceTextBoxes([richBox()], pageID: old.pages[0].id)
        try store.save(old)
        let migrations = root.appendingPathComponent("Migrations")
        let folder = try FileManager.default.contentsOfDirectory(at: migrations, includingPropertiesForKeys: nil)[0]
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("notebook-v3.json")), bytes)
        XCTAssertEqual(try store.load(), old)
    }
    func testLibraryBackupRetainsCoverPaperDefaultsAndBottomDock() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(root: root); _ = try await store.load()
        var settings = NotebookAppearance(); settings.cover = .coral; settings.format = .letter
        let book = try Notebook.blank(title: "Umschlag", appearance: settings)
        _ = try await store.createDocument(book, parentID: nil)
        let preview = try await store.previewDocument(id: book.id)
        XCTAssertEqual(preview.appearance, settings)
        var tools = ToolbarPreferences(); tools.dock = .bottom; tools.autoPen = true; tools.pencilPreview = false; tools.paging = true
        try await ToolbarPreferenceStore(root: root).save(tools, revision: 1)
        let bundle = try await store.backupBundle()
        let decoded = try LibraryArchive.decode(LibraryArchive.encode(bundle))
        XCTAssertEqual(decoded.documents.first?.appearance, settings)
        XCTAssertEqual(decoded.toolbar, tools)
    }
    func testNewToolbarFieldsCannotMasqueradeAsAnOldFormat() throws {
        var value = ToolbarPreferences(); value.formatVersion = 3; value.order = WritingTool.format7Tools; value.autoPen = true
        XCTAssertThrowsError(try ToolbarPreferences.decode(JSONEncoder().encode(value)))
        value.autoPen = nil; value.dock = .bottom
        XCTAssertThrowsError(try ToolbarPreferences.decode(JSONEncoder().encode(value)))
        value.dock = .right
        let migrated = try ToolbarPreferences.decode(JSONEncoder().encode(value))
        XCTAssertEqual(migrated.formatVersion, 8); XCTAssertEqual(migrated.order, ToolbarPreferences().order)
    }
    func testRotationSnapsOnlyNearRightAngles() {
        XCTAssertEqual(ImageObject.snappedRotation(88), 90)
        XCTAssertEqual(ImageObject.snappedRotation(-178), -180)
        XCTAssertEqual(ImageObject.snappedRotation(4), 0)
        XCTAssertEqual(ImageObject.snappedRotation(78), 78)
    }
}
