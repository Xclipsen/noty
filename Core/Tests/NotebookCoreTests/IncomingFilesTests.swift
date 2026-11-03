import Foundation
import XCTest
@testable import NotebookCore

/// PDFs and pictures shared to noty: type by content, queue, name proposal,
/// target lists, placement and the closed-notebook append.
final class IncomingFilesTests: XCTestCase {
    private func directory() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    private let box = PageRect(x: 0, y: 0, width: 300, height: 400)
    private var geometry: PDFPageGeometry { try! PDFPageGeometry(mediaBox: box, cropBox: box, rotation: 0) }
    private let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13])
    private func heic() -> Data {
        var data = Data([0, 0, 0, 24]); data += Data("ftypheic".utf8); data += Data([0, 0, 0, 0]); data += Data("mif1heic".utf8)
        return data
    }
    private func movie() -> Data {
        var data = Data([0, 0, 0, 20]); data += Data("ftypqt  ".utf8); data += Data([0, 0, 0, 0]); data += Data("qt  ".utf8)
        return data
    }

    // MARK: Type by content

    func testTypeIsDecidedByContentNotByName() {
        XCTAssertEqual(IncomingFileType.decide(header: Data("%PDF-1.7\n".utf8), byteCount: 9), .pdf)
        // Some writers put bytes in front of the signature.
        XCTAssertEqual(IncomingFileType.decide(header: Data(repeating: 0x20, count: 300) + Data("%PDF-1.4".utf8), byteCount: 308), .pdf)
        XCTAssertEqual(IncomingFileType.decide(header: png, byteCount: png.count), .image(.png))
        XCTAssertEqual(IncomingFileType.decide(header: Data([0xFF, 0xD8, 0xFF, 0xE0]), byteCount: 4), .image(.jpeg))
        XCTAssertEqual(IncomingFileType.decide(header: heic(), byteCount: 24), .image(.heif))
        XCTAssertEqual(IncomingFileType.decide(header: movie(), byteCount: 20), .unsupported(.video))
        XCTAssertEqual(IncomingFileType.decide(header: Data("Hallo Welt".utf8), byteCount: 10), .unsupported(.unknown))
        XCTAssertEqual(IncomingFileType.decide(header: Data(), byteCount: 0), .unsupported(.empty))
        XCTAssertEqual(IncomingFileType.decide(header: Data("%PDF-1.7".utf8), byteCount: PDFSource.maximumBytes + 1), .unsupported(.tooLarge))
        XCTAssertEqual(IncomingFileType.decide(header: Data("%PDF-1.7".utf8), byteCount: PDFSource.maximumBytes), .pdf)
    }

    func testTypeLabels() {
        XCTAssertEqual(IncomingItem(originalName: "a", kind: .pdf, byteCount: 1, receivedAt: Date()).typeLabel, "PDF")
        XCTAssertEqual(IncomingItem(originalName: "a", kind: .image, imageFormat: "heif", byteCount: 1, receivedAt: Date()).typeLabel, "Bild (HEIC)")
        XCTAssertEqual(IncomingItem(originalName: "a", kind: .image, imageFormat: "png", byteCount: 1, receivedAt: Date()).typeLabel, "Bild (PNG)")
    }

    // MARK: Name proposal

    func testNameProposalDropsOnlyTheFileExtensionAndAvoidsCollisions() {
        XCTAssertEqual(IncomingNaming.stem(of: "Arbeitsblatt 3.pdf"), "Arbeitsblatt 3")
        XCTAssertEqual(IncomingNaming.stem(of: "IMG_1234.HEIC"), "IMG_1234")
        XCTAssertEqual(IncomingNaming.stem(of: "Kapitel 3.2"), "Kapitel 3.2", "no file extension")
        XCTAssertEqual(IncomingNaming.stem(of: "Bericht.final.pdf"), "Bericht.final")
        XCTAssertEqual(IncomingNaming.stem(of: ".pdf"), ".pdf", "a dot file keeps its name")
        XCTAssertEqual(IncomingNaming.stem(of: "../../geheim.pdf"), "geheim")
        XCTAssertEqual(IncomingNaming.stem(of: "Zeile\neins.pdf"), "Zeile eins")
        XCTAssertEqual(IncomingNaming.stem(of: ""), NotebookTitles.fallback)
        XCTAssertEqual(IncomingNaming.suggestedTitle(fileName: "Bio.pdf", taken: ["Mathe"]), "Bio")
        XCTAssertEqual(IncomingNaming.suggestedTitle(fileName: "Bio.pdf", taken: ["bio", "Bio (1)"]), "Bio (2)")
        XCTAssertEqual(IncomingNaming.suggestedTitle(fileName: String(repeating: "x", count: 200) + ".pdf", taken: []).count, 120)
    }

    // MARK: Queue

    func testQueueOffersOneFileAtATimeInArrivalOrder() {
        let now = Date()
        let first = IncomingItem(originalName: "1.pdf", kind: .pdf, byteCount: 1, receivedAt: now)
        let second = IncomingItem(originalName: "2.png", kind: .image, imageFormat: "png", byteCount: 1, receivedAt: now.addingTimeInterval(1))
        let older = IncomingItem(originalName: "0.pdf", kind: .pdf, byteCount: 1, receivedAt: now.addingTimeInterval(-60))
        var queue = IncomingQueue()
        XCTAssertTrue(queue.isEmpty)
        XCTAssertNil(queue.next())
        XCTAssertTrue(queue.enqueue(first))
        XCTAssertFalse(queue.enqueue(first), "relisted at launch")
        XCTAssertEqual(queue.next(), first)
        XCTAssertTrue(queue.enqueue(second))
        XCTAssertFalse(queue.enqueue(first), "current is not queued twice")
        XCTAssertNil(queue.next(), "the open offer stays until finished")
        XCTAssertTrue(queue.enqueue(older))
        queue.finish(first.id)
        XCTAssertEqual(queue.next(), older, "a leftover of an earlier run comes first")
        queue.postponeCurrent()
        XCTAssertEqual(queue.waiting.map(\.id), [older.id, second.id])
        XCTAssertEqual(queue.next(), older)
        queue.finish(older.id)
        queue.finish(UUID())
        XCTAssertEqual(queue.next(), second)
        queue.finish(second.id)
        XCTAssertTrue(queue.isEmpty)
    }

    // MARK: Placement

    func testPlacementAppendsAtTheEndOrBehindThePageWithNewIDsAndUnchangedSource() throws {
        var book = Notebook.blank(title: "Heft")
        let existing = try book.insertPDF(Data("%PDF-alt".utf8), geometries: [geometry, geometry], at: 1)
        let before = book.pages.map(\.id)
        let bytes = Data("%PDF-neu-unverändert".utf8)
        var end = book
        let added = try end.insertIncomingPDF(bytes, geometries: [geometry, geometry], placement: .end, writingArea: nil)
        XCTAssertEqual(end.pages.map(\.id), before + added)
        XCTAssertTrue(Set(added).isDisjoint(with: before))
        let source = try XCTUnwrap(end.pdfSources?.last)
        XCTAssertEqual(source.data, bytes)
        XCTAssertEqual(end.pages.suffix(2).map(\.pdfReference), [PDFPageReference(sourceID: source.id, pageIndex: 0), PDFPageReference(sourceID: source.id, pageIndex: 1)])

        var middle = book
        let inserted = try middle.insertIncomingPDF(bytes, geometries: [geometry], placement: .after(existing[0]), writingArea: nil)
        XCTAssertEqual(middle.pages.map(\.id), [before[0], existing[0]] + inserted + [existing[1]])

        var missing = book
        XCTAssertThrowsError(try missing.insertIncomingPDF(bytes, geometries: [geometry], placement: .after(UUID()), writingArea: nil))
        XCTAssertEqual(missing, book, "a failed placement changes nothing")
    }

    func testWritingSpaceIsScaledToEveryNewPage() throws {
        var book = Notebook.blank(title: "Heft")
        let wide = try PDFPageGeometry(mediaBox: PageRect(x: 0, y: 0, width: 800, height: 400), cropBox: PageRect(x: 0, y: 0, width: 800, height: 400), rotation: 0)
        let area = PageMargins(left: 0, right: 0.5, style: .lined, color: .white)
        let ids = try book.insertIncomingPDF(Data("%PDF-x".utf8), geometries: [geometry, wide], placement: .end, writingArea: area)
        let pages = ids.compactMap { id in book.pages.first { $0.id == id } }
        XCTAssertEqual(pages.count, 2)
        XCTAssertEqual(pages[0].margins?.right ?? 0, 150, accuracy: 0.001)
        XCTAssertEqual(pages[1].margins?.right ?? 0, 400, accuracy: 0.001)
    }

    func testTextDocumentsTakeNoPDFPages() throws {
        var document = try Notebook.textDocument(title: "Text", landscape: false, paper: .blank)
        let before = document
        XCTAssertThrowsError(try document.insertIncomingPDF(Data("%PDF-x".utf8), geometries: [geometry], placement: .end, writingArea: nil)) {
            XCTAssertEqual($0 as? IncomingFileError, .notAppendable)
        }
        XCTAssertEqual(document, before)
    }

    // MARK: Targets

    func testTargetListsShowActiveFoldersAndNotebooksOnly() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(root: root); _ = try await store.load()
        let bio = try await store.createFolder(title: "Bio", parentID: nil).items.last!.id
        let exams = try await store.createFolder(title: "Klausuren", parentID: bio).items.last!.id
        let old = try await store.createFolder(title: "Alt", parentID: nil).items.last!.id
        let math = try await store.createFolder(title: "Mathe", parentID: nil).items.last!.id
        var book = Notebook.blank(title: "Zellen"); _ = try await store.createDocument(book, parentID: exams)
        let zellen = book.id
        book = Notebook.blank(title: "Algebra"); _ = try await store.createDocument(book, parentID: math)
        let algebra = book.id
        let text = try Notebook.textDocument(title: "Aufsatz", landscape: false, paper: .blank)
        _ = try await store.createDocument(text, parentID: nil)
        book = Notebook.blank(title: "Weg"); _ = try await store.createDocument(book, parentID: old)
        _ = try await store.trash(old)
        _ = try await store.setFavorite(math, value: true)
        _ = try await store.setFavorite(algebra, value: true)
        _ = try await store.markOpened(zellen)
        let snapshot = try await store.markOpened(algebra)

        let tree = IncomingTargets.folderTree(snapshot)
        XCTAssertEqual(tree.map(\.title), ["Alle Unterlagen", "Bio", "Klausuren", "Mathe"])
        XCTAssertEqual(tree.map(\.depth), [0, 1, 2, 1])
        XCTAssertEqual(tree[2].path, "Alle Unterlagen / Bio / Klausuren")
        XCTAssertEqual(IncomingTargets.folderTree(snapshot, expanded: []).map(\.title), ["Alle Unterlagen", "Bio", "Mathe"])
        XCTAssertEqual(IncomingTargets.folders(snapshot, matching: "klaus").map(\.id), [exams])
        XCTAssertEqual(IncomingTargets.folders(snapshot, matching: "alt").map(\.id), [], "trashed folder")
        XCTAssertEqual(IncomingTargets.favoriteFolders(snapshot, pinOrder: []).map(\.id), [math])
        XCTAssertEqual(IncomingTargets.recentFolders(snapshot, remembered: [bio, nil, old]).map(\.id), [bio, nil, math, exams],
                       "filed into first, then folders of recently opened notebooks; trashed ones never")

        XCTAssertEqual(IncomingTargets.notebooks(snapshot, matching: "").map(\.title), ["Algebra", "Zellen"], "no text document, nothing from the trash")
        XCTAssertEqual(IncomingTargets.notebooks(snapshot, matching: "zel").map(\.id), [zellen])
        XCTAssertEqual(IncomingTargets.recentNotebooks(snapshot).map(\.id), [algebra, zellen])
        XCTAssertEqual(IncomingTargets.favoriteNotebooks(snapshot, pinOrder: []).map(\.id), [algebra])
    }

    func testRememberedFoldersRoundTrip() {
        let a = UUID(), b = UUID()
        let list = IncomingTargets.remember(a, in: IncomingTargets.remember(nil, in: [b, a], limit: 3), limit: 3)
        XCTAssertEqual(list, [a, nil, b])
        XCTAssertEqual(IncomingTargets.decode(IncomingTargets.encode(list)), list)
        XCTAssertEqual(IncomingTargets.decode(["kaputt", "root"]), [nil])
    }

    // MARK: Incoming folder

    func testInboxKeepsCheckedCopiesUntilRemovedAndRefusesOtherFiles() throws {
        let folder = directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let inbox = IncomingInbox(directory: folder)
        let pdf = Data("%PDF-1.7\nInhalt".utf8)
        let stage = try inbox.newStage()
        try pdf.write(to: stage)
        let item = try inbox.adopt(stage: stage, originalName: "Blatt.pdf", now: Date(timeIntervalSince1970: 1_000))
        XCTAssertEqual(item.kind, .pdf)
        XCTAssertEqual(item.byteCount, pdf.count)
        XCTAssertEqual(try Data(contentsOf: inbox.contentURL(item)), pdf, "exact bytes")
        XCTAssertFalse(FileManager.default.fileExists(atPath: stage.path))

        let picture = try inbox.newStage()
        try heic().write(to: picture)
        let photo = try inbox.adopt(stage: picture, originalName: "IMG_1.HEIC", now: Date(timeIntervalSince1970: 500))
        XCTAssertEqual(photo.imageFormat, "heif")

        let video = try inbox.newStage()
        try movie().write(to: video)
        XCTAssertThrowsError(try inbox.adopt(stage: video, originalName: "film.pdf")) {
            XCTAssertEqual($0 as? IncomingFileError, .unsupported(.video), "the name does not decide")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: video.path), "refused copy removed")

        // A fresh instance (next launch) lists both, oldest first.
        XCTAssertEqual(IncomingInbox(directory: folder).items().map(\.id), [photo.id, item.id])
        inbox.remove(photo.id)
        XCTAssertEqual(inbox.items().map(\.id), [item.id])

        // Interrupted receipts: removed only after a day.
        let leftover = try inbox.newStage()
        try pdf.write(to: leftover)
        let broken = folder.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: false)
        XCTAssertEqual(inbox.items().map(\.id), [item.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: leftover.path))
        XCTAssertEqual(inbox.items(now: Date().addingTimeInterval(2 * 24 * 3600)).map(\.id), [item.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: leftover.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: broken.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: inbox.contentURL(item).path), "a complete copy stays")
    }

    // MARK: Closed notebook

    func testAppendToClosedNotebookCommitsOneCompleteRevision() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(root: root); _ = try await store.load()
        var book = Notebook.blank(title: "Physik"); book.pages[0].drawing = Data([7, 8, 9])
        _ = try await store.createDocument(book, parentID: nil)
        let url = try await store.documentURL(id: book.id)
        let bytes = Data("%PDF-1.7 Arbeitsblatt".utf8)
        let result = try await store.appendIncomingPDF(to: book.id, data: bytes, geometries: [geometry, geometry], placement: .end,
                                                       writingArea: PageMargins(left: 0, right: 1, style: .blank, color: .dark))
        XCTAssertEqual(result.title, "Physik")
        let stored = try RevisionStore(directory: url, readOnly: true).load()
        XCTAssertEqual(stored.pages.count, 3)
        XCTAssertEqual(stored.pages[0], book.pages[0], "existing page unchanged")
        XCTAssertEqual(Array(stored.pages.suffix(2).map(\.id)), result.pageIDs)
        XCTAssertEqual(stored.pdfSources?.last?.data, bytes)
        XCTAssertEqual(stored.pages[1].margins?.right ?? 0, 300, accuracy: 0.001)
        let index = try await store.committedSnapshot()
        XCTAssertEqual(index.items.count, 1, "the index is unchanged")
    }

    func testAppendFailuresLeaveTheNotebookUnchanged() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(root: root); _ = try await store.load()
        let book = Notebook.blank(title: "Chemie")
        _ = try await store.createDocument(book, parentID: nil)
        let url = try await store.documentURL(id: book.id)
        let manifest = try Data(contentsOf: url.appendingPathComponent("manifest.json"))
        do {
            _ = try await store.appendIncomingPDF(to: book.id, data: Data("%PDF-x".utf8), geometries: [geometry],
                                                  placement: .after(UUID()), writingArea: nil)
            XCTFail("unknown page accepted")
        } catch PageOperationError.missingPage { }
        let large = Data(count: PDFSource.maximumTotalBytes + 1)
        do {
            _ = try await store.appendIncomingPDF(to: book.id, data: large, geometries: [geometry], placement: .end, writingArea: nil)
            XCTFail("source limit ignored")
        } catch PageOperationError.sourceLimit { }
        XCTAssertEqual(try Data(contentsOf: url.appendingPathComponent("manifest.json")), manifest)

        let text = try Notebook.textDocument(title: "Text", landscape: false, paper: .blank)
        _ = try await store.createDocument(text, parentID: nil)
        do {
            _ = try await store.appendIncomingPDF(to: text.id, data: Data("%PDF-x".utf8), geometries: [geometry], placement: .end, writingArea: nil)
            XCTFail("text document accepted")
        } catch IncomingFileError.notAppendable { }

        _ = try await store.trash(book.id)
        do {
            _ = try await store.appendIncomingPDF(to: book.id, data: Data("%PDF-x".utf8), geometries: [geometry], placement: .end, writingArea: nil)
            XCTFail("trashed notebook accepted")
        } catch LibraryError.unavailable { }
    }
}
