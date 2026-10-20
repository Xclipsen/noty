import Foundation
import XCTest
@testable import NotebookCore

/// Build 49 regression: the PDF export lost images and typed text. Every page
/// kind composes background, images, shapes, ink and text, in that order.
final class PageCompositionTests: XCTestCase {
    private let content: [PageLayer] = [.images, .shapes, .ink, .text]

    private func pdfPage(width: Double = 842, height: Double = 1191) throws -> Page {
        var page = Page()
        page.pdfReference = PDFPageReference(sourceID: UUID(), pageIndex: 0)
        page.geometry = try PDFPageGeometry(mediaBox: .init(x: 0, y: 0, width: width, height: height),
                                            cropBox: .init(x: 0, y: 0, width: width, height: height), rotation: 0)
        return page
    }

    func testPaperPageComposesItsPaperThenAllContent() {
        var book = Notebook.blank(title: "Papier")
        book.pages[0].paper = .lined
        XCTAssertEqual(book.pages[0].exportLayers(hasSource: false), [.paper(.lined, .white, coordinateScale: 1)] + content)
        book.pages[0].paper = .grid; book.pages[0].paperColor = .dark
        XCTAssertEqual(book.pages[0].exportLayers(hasSource: false), [.paper(.grid, .dark, coordinateScale: 1)] + content)
    }

    func testPaperWritingSpaceContinuesThePaperAndKeepsAllContent() throws {
        var book = Notebook.blank(title: "Schreibplatz")
        book.pages[0].paper = .grid; book.pages[0].paperColor = .dark
        try book.applyMargins(PageMargins(right: 595, bottom: 421), pageIDs: [book.pages[0].id])
        XCTAssertEqual(book.schemaVersion, 11)
        XCTAssertEqual(book.pages[0].exportLayers(hasSource: false), [.paper(.grid, .dark, coordinateScale: 1)] + content)
    }

    func testPDFPageComposesSourceOnBlankSheetThenAllContent() throws {
        let page = try pdfPage()
        XCTAssertEqual(page.exportLayers(hasSource: true), [.paper(.blank, .white, coordinateScale: 1), .sourcePDF] + content)
    }

    func testPDFWritingMarginsUseMarginPaperAndNormalPageUnits() throws {
        var page = try pdfPage()
        page.margins = PageMargins(left: 40, right: 842, top: 20, style: .lined, color: .dark)
        XCTAssertEqual(page.exportLayers(hasSource: true),
                       [.paper(.lined, .dark, coordinateScale: 842.0 / 595.0), .sourcePDF] + content)
    }

    func testLegacyPagesKeepTheirBackgroundAndAllContent() throws {
        // Prototype page: no paper, no geometry, no source.
        XCTAssertEqual(Page().exportLayers(hasSource: false), [.paper(.blank, .white, coordinateScale: 1), .testPaper] + content)
        // Legacy single-PDF notebook: no stored paper, source from `Notebook.pdf`.
        var legacy = Page(); legacy.geometry = try pdfPage(width: 595, height: 842).geometry
        XCTAssertEqual(legacy.exportLayers(hasSource: true), [.paper(.blank, .white, coordinateScale: 1), .sourcePDF] + content)
    }

    func testEveryPageKindEndsWithEachContentLayerExactlyOnce() throws {
        var margin = try pdfPage(); margin.margins = PageMargins(right: 300, style: .grid)
        var paper = Page(); paper.paper = .lined
        let cases: [(Page, Bool)] = [(Page(), false), (paper, false), (try pdfPage(), true), (margin, true)]
        for (page, hasSource) in cases {
            let layers = page.exportLayers(hasSource: hasSource)
            XCTAssertEqual(Array(layers.suffix(content.count)), content)
            for layer in content { XCTAssertEqual(layers.filter { $0 == layer }.count, 1) }
            guard case .paper = layers.first else { return XCTFail("Hintergrund zuerst: \(layers)") }
            XCTAssertEqual(layers.contains(.sourcePDF), hasSource)
        }
    }
}
