import Foundation
import XCTest
@testable import NotebookCore

final class NotebookPageImportTests: XCTestCase {
    private func pdfNotebook(_ bytes: String, pages: Int) throws -> Notebook {
        var value = Notebook.blank(title: "Ziel")
        try value.insertPDF(Data(bytes.utf8), geometries: Array(repeating: PaperStyle.geometry, count: pages), at: 1)
        return value
    }

    /// Like the generated Probeklausur: lined dark paper, fields on the lines, a bookmark.
    private func file() throws -> Notebook {
        var value = Notebook.blank(title: "Probeklausur")
        try value.insertPaper(.lined, color: .dark, at: 1)
        var box = TextBox(x: 40, y: 22, width: 515, height: 72, text: "Aufgabe 1")
        box.alignsToLines = true
        try value.replaceTextBoxes([box], pageID: value.pages[1].id)
        try value.toggleBookmark(value.pages[1].id)
        try value.insertPDF(Data("Arbeitsblatt".utf8), geometries: [PaperStyle.geometry, PaperStyle.geometry], at: 2)
        value.pages[0].drawing = Data([7, 7, 7])
        try value.validate()
        return value
    }

    func testCopiesActivePagesWithNewIDsAndKeepsTheFileUntouched() throws {
        let source = try file()
        var target = try pdfNotebook("Skript", pages: 2)
        let before = target
        let result = try target.insertPages(of: source, at: 1)

        XCTAssertEqual(result.pageIDs.count, source.pages.count)
        XCTAssertEqual(target.pages.count, before.pages.count + source.pages.count)
        XCTAssertEqual(target.pages.map(\.id), [before.pages[0].id] + result.pageIDs + before.pages.dropFirst().map(\.id))
        XCTAssertTrue(Set(result.pageIDs).isDisjoint(with: Set(source.pages.map(\.id))))
        let inserted = Array(target.pages[1...source.pages.count])
        XCTAssertEqual(inserted.map(\.drawing), source.pages.map(\.drawing))
        XCTAssertEqual(inserted.map(\.paper), source.pages.map(\.paper))
        XCTAssertEqual(inserted.map(\.bookmarked), source.pages.map(\.bookmarked))
        XCTAssertEqual(inserted[1].textBoxes?.first?.text, "Aufgabe 1")
        XCTAssertEqual(inserted[1].textBoxes?.first?.alignsToLines, true)
        XCTAssertNotEqual(inserted[1].textBoxes?.first?.id, source.pages[1].textBoxes?.first?.id)
        // The PDF original came along under a new ID, the target's own stays.
        let imported = try XCTUnwrap(inserted[2].pdfReference)
        XCTAssertNotEqual(imported.sourceID, source.pages[2].pdfReference?.sourceID)
        XCTAssertEqual(target.pdfSources?.first(where: { $0.id == imported.sourceID })?.data, Data("Arbeitsblatt".utf8))
        XCTAssertEqual(inserted.map { $0.pdfReference?.pageIndex }, source.pages.map { $0.pdfReference?.pageIndex })
        XCTAssertEqual(target.pdfSources?.count, 2)
        XCTAssertGreaterThanOrEqual(target.schemaVersion, TextBox.lineAlignmentSchemaVersion)
        XCTAssertEqual(target.title, "Ziel")
        XCTAssertEqual(try Notebook.decode(JSONEncoder().encode(target)), target)
        XCTAssertTrue(result.newAssets.isEmpty)
    }

    func testIdenticalOriginalIsSharedAndImportingTwiceStaysValid() throws {
        let source = try file()
        var target = try pdfNotebook("Arbeitsblatt", pages: 2)
        try target.insertPages(of: source, at: target.pages.count)
        XCTAssertEqual(target.pdfSources?.count, 1)
        try target.insertPages(of: source, at: 0)
        XCTAssertEqual(target.pdfSources?.count, 1)
        XCTAssertEqual(Set(target.pages.map(\.id)).count, target.pages.count)
        try target.validate()
    }

    func testOnlyOriginalsOfActivePagesComeAlongAndPageTrashStaysOut() throws {
        var source = try file()
        try source.insertPDF(Data("Nur im Papierkorb".utf8), geometries: [PaperStyle.geometry], at: 0)
        try source.trashPage(source.pages[0].id)
        var target = Notebook.blank(title: "Ziel")
        try target.insertPages(of: source, at: 1)
        XCTAssertFalse(target.pdfSources?.contains { $0.data == Data("Nur im Papierkorb".utf8) } ?? true)
        XCTAssertEqual(target.deletedPages?.count ?? 0, 0)
        XCTAssertEqual(target.pages.count, 1 + source.pages.count)
    }

    func testNewImageOriginalsAreReportedOnceAndPresentOnesAreNot() throws {
        let shared = ImageAssetReference.declared(1_000, seed: 1)
        let fresh = ImageAssetReference.declared(2_000, seed: 2)
        var source = Notebook.blank(title: "Bilder")
        try source.insertPaper(.blank, at: 1)
        source.schemaVersion = Notebook.imageAssetSchemaVersion
        source.pages[0].images = [ImageObject(asset: shared, pixelWidth: 8, pixelHeight: 6), ImageObject(asset: fresh, pixelWidth: 8, pixelHeight: 6, x: 60)]
        source.pages[1].images = [ImageObject(asset: fresh, pixelWidth: 8, pixelHeight: 6)]
        try source.validate()
        var target = Notebook.blank(title: "Ziel")
        target.schemaVersion = Notebook.imageAssetSchemaVersion
        target.pages[0].images = [ImageObject(asset: shared, pixelWidth: 8, pixelHeight: 6)]
        let result = try target.insertPages(of: source, at: 1)
        XCTAssertEqual(result.newAssets, [fresh])
        let ids = target.allImages.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
    }

    func testRefusalsChangeNothing() throws {
        var target = try pdfNotebook("Skript", pages: 1)
        let before = target
        var text = Notebook.blank(title: "Text")
        text.schemaVersion = Notebook.textDocumentSchemaVersion
        text.kind = .textDocument
        XCTAssertThrowsError(try target.insertPages(of: text, at: 1)) { XCTAssertEqual($0 as? PageImportError, .textDocument) }
        XCTAssertThrowsError(try target.insertPages(of: try file(), at: 99))
        var big = Notebook.blank(title: "Groß")
        for _ in 0..<499 { try big.insertPaper(.blank, at: 1) }
        XCTAssertThrowsError(try target.insertPages(of: big, at: 0)) { XCTAssertEqual($0 as? PageOperationError, .pageLimit) }
        var heavy = Notebook.blank(title: "Bilder")
        heavy.schemaVersion = Notebook.imageAssetSchemaVersion
        heavy.pages[0].images = (0..<25).map { ImageObject(asset: .declared(ImageLimits.maximumNotebookBytes / 25, seed: 100 + $0), pixelWidth: 8, pixelHeight: 6, x: 40 + Double($0)) }
        target.schemaVersion = Notebook.imageAssetSchemaVersion
        target.pages[0].images = [ImageObject(asset: .declared(10, seed: 6), pixelWidth: 8, pixelHeight: 6)]
        let withImage = target
        XCTAssertThrowsError(try target.insertPages(of: heavy, at: 0)) {
            guard case .imagesFull = $0 as? PageImportError else { return XCTFail("\($0)") }
        }
        XCTAssertEqual(target, withImage)
        XCTAssertNotEqual(target, before)
    }

    func testLegacyFileWithEmbeddedPDFAndPageText() throws {
        var legacy = Notebook()
        legacy.pdf = Data("alt".utf8)
        var first = Page(); first.text = "Notiz"; legacy.pages = [first, Page()]
        var target = Notebook.blank(title: "Ziel")
        try target.insertPages(of: legacy, at: 1)
        XCTAssertEqual(target.pages.count, 3)
        XCTAssertEqual(target.pages[1].textBoxes?.first?.text, "Notiz")
        XCTAssertEqual(target.pages[1].text, "")
        XCTAssertEqual(target.pages[2].pdfReference?.pageIndex, 1)
        try target.validate()
    }

    func testThroughTheRealArchive() throws {
        let decoded = try BackupArchive.decode(BackupArchive.encode(try file()))
        var target = try pdfNotebook("Skript", pages: 1)
        let result = try target.insertPages(of: decoded.document, at: 0)
        XCTAssertEqual(result.pageIDs.count, decoded.document.pages.count)
        XCTAssertEqual(target.pages.first?.id, result.pageIDs.first)
    }
}
