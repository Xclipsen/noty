import Foundation
import XCTest
@testable import NotebookCore

final class ContentSearchIndexTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func pdfNotebook(pages: Int = 2) -> Notebook {
        var notebook = Notebook(); notebook.schemaVersion = Notebook.currentSchemaVersion
        let source = PDFSource(data: Data(repeating: 7, count: 600_000), pageCount: pages)
        notebook.pdfSources = [source]
        notebook.pages = (0..<pages).map { index in
            var page = Page(); page.pdfReference = PDFPageReference(sourceID: source.id, pageIndex: index)
            page.geometry = PaperStyle.geometry
            return page
        }
        return notebook
    }

    private func image(_ byte: UInt8 = 1) -> ImageObject {
        ImageObject.test(bytes: Data(repeating: byte, count: 64), pixelWidth: 8, pixelHeight: 8)
    }

    func testDigestIsDeterministicAndSensitiveToEveryByte() {
        let data = Data((0..<1_027).map { UInt8($0 % 251) })
        XCTAssertEqual(ContentFingerprint.digest(data), ContentFingerprint.digest(Data(data)))
        for position in [0, 7, 8, 1_000, 1_026] {
            var changed = data; changed[position] ^= 1
            XCTAssertNotEqual(ContentFingerprint.digest(changed), ContentFingerprint.digest(data), "byte \(position)")
        }
        XCTAssertNotEqual(ContentFingerprint.digest(Data([0])), ContentFingerprint.digest(Data([0, 0])))
        XCTAssertNotEqual(ContentFingerprint.digest(Data()), ContentFingerprint.digest(Data([0])))
        var a = ContentFingerprint("x"); a.add("ab"); a.add("c")
        var b = ContentFingerprint("x"); b.add("a"); b.add("bc")
        XCTAssertNotEqual(a.value, b.value)
        let large = Data(repeating: 3, count: 2_000_000)
        var tail = large; tail[1_999_999] = 4
        XCTAssertNotEqual(ContentFingerprint.sampledDigest(large), ContentFingerprint.sampledDigest(tail))
    }

    func testLayersAreInvalidatedIndependently() throws {
        var notebook = pdfNotebook()
        notebook.pages[0].drawing = Data([1, 2, 3])
        notebook.pages[0].images = [image()]
        let before = ContentSearchPlanner.prepare(notebook)
        XCTAssertNotNil(before[0].fingerprints.pdfText); XCTAssertNotNil(before[0].fingerprints.imageOCR)
        XCTAssertNotNil(before[0].fingerprints.handwriting); XCTAssertNil(before[1].fingerprints.handwriting)
        XCTAssertNotEqual(before[0].fingerprints.pdfText, before[1].fingerprints.pdfText, "different PDF page index")

        var ink = notebook; ink.pages[0].drawing = Data([1, 2, 4])
        let afterInk = ContentSearchPlanner.prepare(ink)[0].fingerprints
        XCTAssertEqual(afterInk.pdfText, before[0].fingerprints.pdfText)
        XCTAssertEqual(afterInk.imageOCR, before[0].fingerprints.imageOCR)
        XCTAssertNotEqual(afterInk.handwriting, before[0].fingerprints.handwriting)

        var typed = notebook; typed.pages[0].textBoxes = [TextBox(text: "Hallo")]
        let afterText = ContentSearchPlanner.prepare(typed)[0]
        XCTAssertEqual(afterText.fingerprints, before[0].fingerprints)
        XCTAssertEqual(afterText.text.map(\.text), ["Hallo"])

        var moved = notebook; moved.pages[0].images![0].x += 10
        let afterMove = ContentSearchPlanner.prepare(moved)[0].fingerprints
        XCTAssertNotEqual(afterMove.imageOCR, before[0].fingerprints.imageOCR)
        XCTAssertEqual(afterMove.handwriting, before[0].fingerprints.handwriting)

        var margins = notebook; margins.pages[0].margins = PageMargins(left: 100)
        let afterMargins = ContentSearchPlanner.prepare(margins)[0].fingerprints
        for layer in SearchLayer.allCases { XCTAssertNotEqual(afterMargins[layer], before[0].fingerprints[layer], "\(layer)") }

        let paper = ContentSearchPlanner.prepare(Notebook.blank(title: "Papier"))[0]
        XCTAssertEqual(paper.fingerprints, SearchPageFingerprints())
        XCTAssertFalse(paper.hasPDF)
    }

    func testReconcileKeepsValidLayersAndFollowsCurrentPages() {
        var notebook = pdfNotebook(pages: 3)
        notebook.pages[1].drawing = Data([9])
        let prepared = ContentSearchPlanner.prepare(notebook)
        var index = ContentSearchPlanner.reconcile(nil, documentID: notebook.id, pages: prepared)
        XCTAssertEqual(ContentSearchPlanner.pending(prepared[1], index.pages[1]), [.pdfText, .imageOCR, .handwriting])
        for (offset, page) in prepared.enumerated() {
            for layer in ContentSearchPlanner.pending(page, index.pages[offset]) {
                index.pages[offset][layer] = SearchLayerRecord(fingerprint: page.fingerprints[layer]!,
                    lines: [SearchLine(text: "\(layer) \(offset)", kind: .pdf, bounds: .init(x: 0, y: 0, width: 1, height: 1))])
            }
        }
        XCTAssertTrue(ContentSearchPlanner.isComplete(index, prepared))
        index.revisionStamp = "r1"

        // Reorder, delete the last page and change handwriting of the moved page.
        var edited = notebook
        edited.pages = [notebook.pages[1], notebook.pages[0]]
        edited.pages[0].drawing = Data([10])
        let next = ContentSearchPlanner.prepare(edited)
        let merged = ContentSearchPlanner.reconcile(index, documentID: notebook.id, pages: next)
        XCTAssertNil(merged.revisionStamp)
        XCTAssertEqual(merged.pages.map(\.pageID), [notebook.pages[1].id, notebook.pages[0].id])
        XCTAssertEqual(merged.pages[0].pdfText?.lines.first?.text, "pdfText 1")
        XCTAssertNil(merged.pages[0].handwriting)
        XCTAssertEqual(ContentSearchPlanner.pending(next[0], merged.pages[0]), [.handwriting])
        XCTAssertEqual(ContentSearchPlanner.pending(next[1], merged.pages[1]), [])
        XCTAssertFalse(ContentSearchPlanner.isComplete(merged, next))

        // Another document's index is never reused.
        let foreign = ContentSearchPlanner.reconcile(index, documentID: UUID(), pages: prepared)
        XCTAssertTrue(foreign.pages.allSatisfy { $0.pdfText == nil })
    }

    func testTextChunksAndHitsPreferExactPDFText() {
        var page = Page()
        page.textBoxes = [TextBox(text: String(repeating: "a", count: 4_500))]
        let chunks = ContentSearchPlanner.textLines(page)
        XCTAssertEqual(chunks.map(\.text.count), [2_000, 2_000, 820])
        XCTAssertEqual(ContentSearchPlanner.textLines(Page()), [])

        let box = PageRect(x: 1, y: 2, width: 3, height: 4)
        var record = SearchPageRecord(pageID: page.id, text: [SearchLine(text: "getippt", kind: .text, bounds: box)])
        record.pdfText = SearchLayerRecord(fingerprint: "p", lines: [SearchLine(text: "Satz", kind: .pdf, bounds: box)])
        record.imageOCR = SearchLayerRecord(fingerprint: "i", lines: [SearchLine(text: "Satz", kind: .image, bounds: box),
                                                                      SearchLine(text: "Bildtext", kind: .image, bounds: box)])
        record.handwriting = SearchLayerRecord(fingerprint: "h", lines: [SearchLine(text: "Notiz", kind: .handwriting, bounds: box)])
        let document = UUID()
        let hits = ContentSearchPlanner.hits(record, pageNumber: 4, documentID: document, title: "Mathe")
        XCTAssertEqual(hits.map(\.text), ["getippt", "Satz", "Bildtext", "Notiz"])
        XCTAssertEqual(hits.map(\.kind), [.text, .pdf, .image, .handwriting])
        XCTAssertTrue(hits.allSatisfy { $0.pageNumber == 4 && $0.documentID == document && $0.bounds == box && $0.title == "Mathe" })
    }

    func testMeaningfulTextLayerThreshold() {
        func lines(_ texts: [String]) -> [SearchLine] { texts.map { SearchLine(text: $0, kind: .pdf, bounds: .init(x: 0, y: 0, width: 1, height: 1)) } }
        XCTAssertFalse(ContentSearchPlanner.hasMeaningfulTextLayer([]))
        XCTAssertFalse(ContentSearchPlanner.hasMeaningfulTextLayer(lines(["3", "— · —", "Seite 3 von 4"])))
        XCTAssertTrue(ContentSearchPlanner.hasMeaningfulTextLayer(lines(["Aufgabe 1: Berechne die Fläche", "des Dreiecks ABC."])))
        let ocr = [SearchLine(text: String(repeating: "Wort ", count: 20), kind: .image, bounds: .init(x: 0, y: 0, width: 1, height: 1))]
        XCTAssertFalse(ContentSearchPlanner.hasMeaningfulTextLayer(ocr))
    }

    func testStoreRoundTripDiscardsStaleOrForeignFilesAndPrunes() async throws {
        let root = try directory().appendingPathComponent("Area", isDirectory: true)
        let store = ContentSearchIndexStore(directory: root)
        let id = UUID(), other = UUID()
        var index = SearchDocumentIndex(documentID: id, revisionStamp: "r", pages: [SearchPageRecord(pageID: UUID(),
            text: [SearchLine(text: "Hallo", kind: .text, bounds: .init(x: -10, y: 0, width: 5, height: 5))])])
        let missing = await store.load(id)
        XCTAssertNil(missing)
        let saved = await store.save(index)
        XCTAssertTrue(saved)
        let loaded = await store.load(id)
        XCTAssertEqual(loaded, index)

        index.formatVersion = ContentSearchIndexFormat.version + 1
        try JSONEncoder().encode(index).write(to: root.appendingPathComponent("\(id.uuidString).json"))
        let stale = await store.load(id)
        XCTAssertNil(stale)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("\(id.uuidString).json").path))

        try Data("kaputt".utf8).write(to: root.appendingPathComponent("\(id.uuidString).json"))
        let corrupt = await store.load(id)
        XCTAssertNil(corrupt)
        index.formatVersion = ContentSearchIndexFormat.version
        try JSONEncoder().encode(index).write(to: root.appendingPathComponent("\(other.uuidString).json"))
        let foreign = await store.load(other)
        XCTAssertNil(foreign, "file name and document ID must agree")

        index.documentID = id; await store.save(index)
        var second = index; second.documentID = other; await store.save(second)
        try Data().write(to: root.appendingPathComponent(".tmp-leftover"))
        let removed = await store.prune(keeping: [id])
        XCTAssertEqual(removed, 2)
        let remaining = await store.ids()
        XCTAssertEqual(remaining, [id])
        await store.remove([id])
        let empty = await store.ids()
        XCTAssertEqual(empty, [])
    }

    func testRevisionStampFollowsCommittedRevisions() throws {
        let root = try directory()
        XCTAssertNil(NotebookRevisionStamp.read(directory: root))
        let store = RevisionStore(directory: root)
        var notebook = Notebook()
        try store.save(notebook)
        let first = try XCTUnwrap(NotebookRevisionStamp.read(directory: root))
        _ = try RevisionStore(directory: root).load()
        XCTAssertEqual(NotebookRevisionStamp.read(directory: root), first)
        try store.save(notebook)
        XCTAssertEqual(NotebookRevisionStamp.read(directory: root), first, "unchanged save is no new revision")
        notebook.pages[0].text = "neu"
        try store.save(notebook)
        XCTAssertNotEqual(NotebookRevisionStamp.read(directory: root), first)
    }
}
