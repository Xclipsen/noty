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
        var full = Notebook.blank(title: "Maximum")
        _ = try full.insertPDF(Data(count: PDFSource.maximumBytes), geometries: [try geometry()], at: 1)
        try full.validate()
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
        book.pdfSources = [PDFSource(data: Data(count: PDFSource.maximumBytes + 1), pageCount: 1)]
        XCTAssertThrowsError(try book.validate())
        book.pdfSources = [PDFSource(data: Data(count: 60_000_000), pageCount: 1),
                           PDFSource(data: Data(count: 41_000_000), pageCount: 1)]
        XCTAssertThrowsError(try book.validate())
        book.pdfSources = [PDFSource(data: Data(count: 60_000_000), pageCount: 1),
                           PDFSource(data: Data(count: 40_000_000), pageCount: 1)]
        XCTAssertNoThrow(try book.validate())
    }
}
