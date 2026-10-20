import Foundation
import XCTest
@testable import NotebookCore

/// Schema 11: writing space beside paper pages (right/below, seamless paper).
final class PaperWritingSpaceTests: XCTestCase {
    private func a5Notebook() throws -> Notebook {
        var settings = NotebookAppearance(); settings.format = .a5; settings.paper = .lined
        var book = try Notebook.blank(title: "A5", appearance: settings)
        book.pages[0].drawing = Data([7, 8, 9])
        return book
    }

    func testPaperPageGrowsRightAndDownInItsOwnPaperAndRaisesSchemaToEleven() throws {
        var book = Notebook.blank(title: "Papier")
        book.pages[0].paper = .lined
        XCTAssertEqual(book.schemaVersion, 3)
        let id = book.pages[0].id
        // Requested style/colour are replaced by the page's own paper.
        try book.applyMargins(PageMargins(right: 595, bottom: 421, style: .grid, color: .dark), pageIDs: [id])
        XCTAssertEqual(book.schemaVersion, 11)
        XCTAssertEqual(book.pages[0].margins, PageMargins(right: 595, bottom: 421, style: .lined, color: .white))
        XCTAssertEqual(book.pages[0].geometry, PaperStyle.geometry)
        XCTAssertEqual(try Notebook.decode(JSONEncoder().encode(book)), book)
        XCTAssertEqual(try BackupArchive.decode(BackupArchive.encode(book)).document, book)
        // Removing it again keeps the newer schema (never downgraded).
        try book.setMargins(PageMargins(), pageIDs: [id])
        XCTAssertNil(book.pages[0].margins)
        XCTAssertEqual(book.schemaVersion, 11)
    }

    func testPaperWritingSpaceNeverMovesContentLinesOrUnits() throws {
        var book = try a5Notebook()
        let id = book.pages[0].id
        try book.applyMargins(PageMargins(right: 420, bottom: 100), pageIDs: [id])
        let page = book.pages[0]
        // A5 beside a PDF would use 420/595; paper continues in its own units.
        XCTAssertEqual(page.writingCoordinateScale, 1)
        XCTAssertEqual(page.inkWidthScale, 420.0 / 595.0, accuracy: 1e-9)
        let layout = PageLayout(source: page.geometry!, legacyA4: false, margins: page.margins, extendsPaper: page.writingSpaceExtendsPaper)
        XCTAssertEqual(layout.writingCoordinateScale, 1)
        XCTAssertEqual(layout.contentOrigin, PagePoint(x: 0, y: 0))
        XCTAssertEqual(layout.canvas, PageSize(width: 840, height: 695))
        XCTAssertEqual(page.textBounds, PageRect(x: 0, y: 0, width: 840, height: 695))
        XCTAssertEqual(page.drawing, Data([7, 8, 9]))
        // The page column stays; the extra space is its own text region at the same inset.
        XCTAssertEqual(page.writingRect(.page), PageRect(x: 32, y: 16, width: 356, height: 563))
        XCTAssertEqual(page.writingRect(.right), PageRect(x: 452, y: 16, width: 356, height: 563))
        XCTAssertEqual(page.writingRegion(at: PagePoint(x: 500, y: 100), hasPDF: false), .right)
        XCTAssertEqual(page.writingRegion(at: PagePoint(x: 100, y: 100), hasPDF: false), .page)
    }

    func testOnlyRightAndBottomInMatchingPaperValidate() throws {
        var book = Notebook.blank(title: "Papier")
        let id = book.pages[0].id
        for invalid in [PageMargins(left: 40), PageMargins(top: 40)] {
            XCTAssertThrowsError(try book.applyMargins(invalid, pageIDs: [id]))
            XCTAssertThrowsError(try book.setMargins(invalid, pageIDs: [id]))
        }
        XCTAssertNil(book.pages[0].margins)
        var stored = book; stored.schemaVersion = 11
        stored.pages[0].margins = PageMargins(right: 100, style: .grid)
        XCTAssertThrowsError(try stored.validate(), "foreign paper style")
        stored.pages[0].margins = PageMargins(right: 100, color: .dark)
        XCTAssertThrowsError(try stored.validate(), "foreign paper colour")
        stored.pages[0].margins = PageMargins(right: 100)
        XCTAssertNoThrow(try stored.validate())
        stored.schemaVersion = 10
        XCTAssertThrowsError(try stored.validate(), "schema 10 builds never wrote paper writing space")
        var legacy = Notebook.blank(title: "Test"); legacy.pages[0].paper = .legacyTest; legacy.pages[0].geometry = nil
        XCTAssertThrowsError(try legacy.applyMargins(PageMargins(right: 100), pageIDs: [legacy.pages[0].id]))
    }

    func testAllPaperPagesScopeSkipsPDFsAndKeepsEachPagesPaper() throws {
        var book = Notebook.blank(title: "Gemischt")
        let a4 = book.pages[0].id
        var a5 = NotebookAppearance(); a5.format = .a5
        let small = try book.insertPaper(.grid, color: .dark, at: 1, geometry: a5.geometry)
        _ = try book.insertPDF(Data([1, 2, 3]), geometries: [PaperStyle.geometry], at: 2)
        let assignments = try book.marginsByPage(PageMargins(right: 595), relativeTo: a4, wholeImport: true)
        XCTAssertEqual(Set(assignments.keys), [a4, small])
        XCTAssertEqual(assignments[a4], PageMargins(right: 595))
        XCTAssertEqual(assignments[small], PageMargins(right: 420, style: .grid, color: .dark))
        try book.applyMargins(assignments)
        XCTAssertNil(book.pages[2].margins)
        XCTAssertEqual(try Notebook.decode(JSONEncoder().encode(book)), book)
    }

    func testReductionSnapshotOfPaperPageRestoresInPlace() throws {
        var book = Notebook.blank(title: "Papier")
        let id = book.pages[0].id
        try book.applyMargins(PageMargins(right: 300), pageIDs: [id])
        book.pages[0].drawing = Data([1, 1, 1])
        try book.applyMargins([id: PageMargins(right: 100)], trimmedDrawings: [id: Data([2])])
        let entry = try XCTUnwrap(book.deletedPages?.first)
        XCTAssertEqual(entry.reason, .marginReduction)
        XCTAssertEqual(entry.page.margins?.right, 300)
        XCTAssertEqual(book.marginRestoreTarget(for: entry), id)
        XCTAssertEqual(try book.restorePage(entry.id), id)
        XCTAssertEqual(book.pages[0].id, id)
        XCTAssertEqual(book.pages[0].margins?.right, 300)
        XCTAssertEqual(book.pages[0].drawing, Data([1, 1, 1]))
        XCTAssertEqual(book.deletedPages?.first?.page.margins?.right, 100)
    }

    func testWholeNotebookPaperChangeKeepsWritingSpaceSeamless() throws {
        var book = Notebook.blank(title: "Papier")
        try book.applyMargins(PageMargins(right: 200, bottom: 50), pageIDs: [book.pages[0].id])
        try book.setPageDefaults(paper: .grid, color: .dark, scope: .wholeNotebook)
        XCTAssertEqual(book.pages[0].margins, PageMargins(right: 200, bottom: 50, style: .grid, color: .dark))
        XCTAssertNoThrow(try book.validate())
    }

    func testOnePagesPaperChangesWithItsWritingSpaceAndInvertsNeutralText() throws {
        var book = Notebook.blank(title: "Papier")
        let other = try book.insertPaper(.blank, at: 1)
        let id = book.pages[0].id
        try book.applyMargins(PageMargins(right: 200), pageIDs: [id])
        var box = TextBox(x: 40, y: 40, width: 200, height: 40, text: "Notiz"); box.style.color = .black
        try book.replaceTextBoxes([box], pageID: id)
        let defaults = book.appearance
        try book.setPaper(.lined, color: .dark, pageID: id)
        XCTAssertEqual(book.pages[0].paper, .lined)
        XCTAssertEqual(book.pages[0].paperColor, .dark)
        XCTAssertEqual(book.pages[0].margins, PageMargins(right: 200, style: .lined, color: .dark))
        XCTAssertEqual(book.pages[0].effectiveTextBoxes.first?.style.color, .white)
        XCTAssertEqual(book.pages.first(where: { $0.id == other })?.paper, .blank)
        XCTAssertEqual(book.appearance, defaults)
        XCTAssertEqual(try Notebook.decode(JSONEncoder().encode(book)), book)
        // Handwriting needs the app's PencilKit step; never half converted.
        book.pages[0].drawing = Data([1])
        XCTAssertThrowsError(try book.setPaper(.lined, color: .white, pageID: id))
        XCTAssertEqual(book.pages[0].paperColor, .dark)
        _ = try book.insertPDF(Data([1, 2, 3]), geometries: [PaperStyle.geometry], at: 2)
        XCTAssertThrowsError(try book.setPaper(.grid, color: .white, pageID: book.pages[2].id))
        XCTAssertThrowsError(try book.setPaper(.legacyTest, color: .white, pageID: other))
    }

    func testLinesBesidePDFStartInEachMarginButPaperIsOneSheet() throws {
        let source = PaperStyle.geometry
        let pdf = PageLayout(source: source, legacyA4: false, margins: PageMargins(left: 100, right: 300, style: .lined))
        XCTAssertEqual(pdf.ruledColumnsBesidePDF, [0...100, 100...695, 695...995])
        let right = PageLayout(source: source, legacyA4: false, margins: PageMargins(right: 300, style: .lined))
        XCTAssertEqual(right.ruledColumnsBesidePDF, [0...595, 595...895])
        XCTAssertEqual(PageLayout(source: source, legacyA4: false).ruledColumnsBesidePDF, [0...595])
    }

    func testDraftAndContinuationPagesStayNormalSheets() throws {
        var book = Notebook.blank(title: "Papier")
        try book.applyMargins(PageMargins(right: 595), pageIDs: [book.pages[0].id])
        XCTAssertNil(book.writingDraft().margins)
        let page = book.pages[0]
        let rect = try XCTUnwrap(page.writingRect(.right))
        var box = TextBox(x: rect.x, y: rect.y, width: rect.width, height: rect.height)
        box.flowID = UUID(); box.flowRegion = .right
        try book.replaceTextBoxes([box], pageID: page.id)
        let stored = try XCTUnwrap(book.pages[0].effectiveTextBoxes.first)
        var replacement = stored; replacement.text = "Rand und weiter"
        let (next, _) = try book.reflowText(pageID: page.id, previous: stored, replacement: replacement,
            selection: NSRange(location: 0, length: 0), capacity: { $0.flowRegion == .right ? 5 : 1_000 })
        XCTAssertEqual(next.pages.count, 2)
        XCTAssertNil(next.pages[1].margins)
        XCTAssertEqual(next.pages[1].effectiveTextBoxes.first?.flowRegion, .page)
        XCTAssertEqual(next.pages[1].effectiveTextBoxes.first?.text, "und weiter")
    }

    func testFirstSchemaElevenCommitArchivesExactConfirmedOldBytes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RevisionStore(directory: root)
        var book = try a5Notebook()
        XCTAssertEqual(book.schemaVersion, 7)
        try store.save(book)
        let revision = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("Revisions"), includingPropertiesForKeys: nil)[0]
        let bytes = try Data(contentsOf: revision)
        try book.applyMargins(PageMargins(right: 420), pageIDs: [book.pages[0].id])
        try store.save(book)
        let folder = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("Migrations"), includingPropertiesForKeys: nil)[0]
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("notebook-v7.json")), bytes)
        XCTAssertEqual(try store.load(), book)
    }
}
