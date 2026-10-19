import XCTest
@testable import NotebookCore

final class WritingAndStroke32Tests: XCTestCase {
    private func pdf(width: Double, rotation: Int = 0) throws -> Page {
        var page = Page()
        let rect = PageRect(x: 20, y: 30, width: width, height: width * 842 / 595)
        page.geometry = try PDFPageGeometry(mediaBox: rect, cropBox: rect, rotation: rotation)
        page.pdfReference = PDFPageReference(sourceID: UUID(), pageIndex: 0)
        page.margins = .normalPageBesidePDF(page.geometry!.displaySize, style: .lined)
        return page
    }
    func testPDFWithWritingAreaHasSameBaseWidthAsPaperAtEverySourceSize() throws {
        let paper = Page()
        for width in [240.0, 595, 1668, 2380] {
            let pdf = try pdf(width: width)
            let layout = NotebookViewportLayout(pages: [paper, pdf], selectedPageID: paper.id, paging: false, normalizeWidths: true)
            XCTAssertEqual(layout.pages[0].contentFrame.width, 595)
            XCTAssertEqual(layout.pages[1].contentFrame.width, 595, accuracy: 0.000001)
            XCTAssertEqual(layout.pages[1].frame.width, 1190, accuracy: 0.000001)
            XCTAssertEqual(layout.pages[1].readingFrame.width, 595, accuracy: 0.000001)
            XCTAssertEqual(layout.pages[0].contentFrame.x, layout.pages[1].contentFrame.x, accuracy: 0.000001)
        }
    }
    func testTextAndRulingUseNormalUnitsWithoutChangingStoredFontSizes() throws {
        for width in [240.0, 595, 1668, 2380] {
            var pdf = try pdf(width: width)
            let rect = try XCTUnwrap(pdf.writingRect(.right))
            var box = TextBox(x: rect.x, y: rect.y, width: rect.width, height: rect.height, text: "Hallo", style: .init(fontSize: 14))
            box.flowID = UUID(); box.flowRegion = .right; pdf.textBoxes = [box]
            let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
            let before = try encoder.encode(pdf)
            let placement = NotebookViewportLayout(pages: [pdf], selectedPageID: pdf.id, paging: false, normalizeWidths: true).pages[0]
            let unit = pdf.writingCoordinateScale(for: box)
            XCTAssertEqual(14 * unit * placement.scale, 14, accuracy: 0.000001)
            XCTAssertEqual(PaperRuling.spacing * unit * placement.scale, 24, accuracy: 0.000001)
            XCTAssertEqual(rect.width / unit, 595 - 64, accuracy: 0.000001) // text starts/ends with the ruled lines (32)
            XCTAssertEqual(rect.height / unit, 842 - 32, accuracy: 0.000001)
            XCTAssertEqual(box.style.fontSize, 14)
            XCTAssertEqual(try encoder.encode(pdf), before)
            XCTAssertEqual(pdf.textBoxes?.first, box)
        }
    }
    func testRotatedCropAndNegativeMarginsUseTheDisplayedWidth() throws {
        var pdf = try pdf(width: 1668, rotation: 90)
        let size = pdf.geometry!.displaySize
        pdf.margins = PageMargins(left: size.width, right: size.width, top: size.width * 0.5, style: .lined)
        let left = try XCTUnwrap(pdf.writingRect(.left))
        XCTAssertLessThan(left.x, 0)
        XCTAssertEqual(left.width / pdf.writingCoordinateScale, 531, accuracy: 0.000001)
        let layout = PageLayout(source: pdf.geometry!, legacyA4: false, margins: pdf.margins)
        XCTAssertEqual(layout.writingCoordinateScale, pdf.writingCoordinateScale)
        XCTAssertEqual(layout.sourceFrame.width, size.width)
        let p = PagePoint(x: 25, y: 40)
        let result = layout.pdfToCanvas.inverse.apply(layout.pdfToCanvas.apply(p))
        XCTAssertEqual(result.x, p.x, accuracy: 0.000001); XCTAssertEqual(result.y, p.y, accuracy: 0.000001)
    }
    func testFloatingPDFAnnotationsAndPaperKeepTheirOriginalFontUnits() throws {
        let pdf = try pdf(width: 2380)
        let annotation = TextBox(text: "Anmerkung", style: .init(fontSize: 14))
        XCTAssertEqual(pdf.writingCoordinateScale(for: annotation), 1)
        var body = annotation; body.flowID = UUID(); body.flowRegion = .page
        XCTAssertEqual(Page().writingCoordinateScale(for: body), 1)
        XCTAssertEqual(pdf.writingCoordinateScale(for: body), 1)
    }
    func testExistingNarrowMarginIsNotSilentlyExpandedOrClipped() throws {
        var pdf = try pdf(width: 1668); pdf.margins?.right = 595
        let stored = pdf.margins
        _ = NotebookViewportLayout(pages: [pdf], selectedPageID: pdf.id, paging: false, normalizeWidths: true)
        _ = pdf.writingRect(.right)
        XCTAssertEqual(pdf.margins, stored)
        let full = PageMargins.normalPageBesidePDF(pdf.geometry!.displaySize)
        XCTAssertEqual(full.right, 1668)
        XCTAssertGreaterThan(full.right, pdf.margins!.right)
    }
    func testLiftAndNativeEndAloneCannotCommitUnfinishedPressure() {
        var gate = StrokeCompletionGate()
        gate.drawingChanged(); gate.drawingChanged()
        gate.lift(); XCTAssertFalse(gate.canCommit)
        gate.endNative(); XCTAssertFalse(gate.canCommit)
        gate.drawingChanged(); XCTAssertTrue(gate.canCommit)
    }
    func testFinalDrawingBeforeObserverLiftWaitsForLiftAndNewStrokeResets() {
        var gate = StrokeCompletionGate()
        gate.endNative(); gate.drawingChanged(); XCTAssertFalse(gate.canCommit)
        gate.lift(); XCTAssertTrue(gate.canCommit)
        gate = StrokeCompletionGate(); XCTAssertFalse(gate.canCommit)
        gate.lift(); gate.drawingChanged(); XCTAssertFalse(gate.canCommit)
    }
}
