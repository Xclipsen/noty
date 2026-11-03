import Foundation
import XCTest
@testable import NotebookCore

/// One writer per notebook package: a second store on the same package (an
/// editor that loaded before a library append finished) must neither replace
/// the newer manifest nor clean up the other writer's revision.
final class WriterExclusionTests: XCTestCase {
    private func directory() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    private let box = PageRect(x: 0, y: 0, width: 300, height: 400)
    private var geometry: PDFPageGeometry { try! PDFPageGeometry(mediaBox: box, cropBox: box, rotation: 0) }
    static func isConcurrentChange(_ error: Error) -> Bool {
        if case .concurrentChange? = error as? RevisionError { return true }
        return false
    }
    private func revisionFiles(_ package: URL) -> Set<String> {
        Set((try? FileManager.default.contentsOfDirectory(atPath: package.appendingPathComponent("Revisions").path)) ?? [])
    }

    func testStaleStoreRefusesToCommitOverAnotherWritersRevision() throws {
        let package = directory(); defer { try? FileManager.default.removeItem(at: package) }
        var book = Notebook.blank(title: "Bio")
        try RevisionStore(directory: package).save(book)

        // The editor loaded before the append.
        let editor = RevisionStore(directory: package)
        var stale = try editor.load()
        // The append commits on its own store.
        let appender = RevisionStore(directory: package)
        book = try appender.load()
        let added = try book.insertIncomingPDF(Data("%PDF-1.7 neu".utf8), geometries: [geometry], placement: .end, writingArea: nil)
        try appender.save(book)
        let appendedManifest = try Data(contentsOf: package.appendingPathComponent("manifest.json"))
        let afterAppend = revisionFiles(package)

        // The editor saves its old state with a change: refused, nothing replaced or removed.
        stale.pages[0].drawing = Data([1, 2, 3])
        XCTAssertThrowsError(try editor.save(stale)) { XCTAssertTrue(Self.isConcurrentChange($0), "\($0)") }
        XCTAssertEqual(try Data(contentsOf: package.appendingPathComponent("manifest.json")), appendedManifest)
        XCTAssertEqual(revisionFiles(package), afterAppend, "the refused attempt leaves no file and removes none")
        let stored = try RevisionStore(directory: package, readOnly: true).load()
        XCTAssertEqual(stored, book)
        XCTAssertTrue(added.allSatisfy { id in stored.pages.contains { $0.id == id } }, "appended pages stay")
        // Refused again on every retry; the appender may continue.
        XCTAssertThrowsError(try editor.save(stale))
        book.title = "Biologie"
        XCTAssertNoThrow(try appender.save(book))
    }

    func testCleanupKeepsRevisionsThatAppearedAfterLoading() throws {
        let package = directory(); defer { try? FileManager.default.removeItem(at: package) }
        var book = Notebook.blank(title: "Chemie")
        let store = RevisionStore(directory: package)
        try store.save(book)
        // Another writer is between writing its revision and its manifest.
        let foreign = package.appendingPathComponent("Revisions/\(UUID().uuidString).json")
        try JSONEncoder().encode(Notebook.blank(title: "fremd")).write(to: foreign)
        book.title = "Chemie 2"
        try store.save(book)
        book.title = "Chemie 3"
        try store.save(book)
        XCTAssertTrue(FileManager.default.fileExists(atPath: foreign.path), "never removed by this store's cleanup")
    }

    func testRestsPresentAtLoadAreStillCleanedUp() throws {
        let package = directory(); defer { try? FileManager.default.removeItem(at: package) }
        var book = Notebook.blank(title: "Kunst")
        try RevisionStore(directory: package).save(book)
        let rest = package.appendingPathComponent("Revisions/\(UUID().uuidString).json")
        try JSONEncoder().encode(Notebook.blank(title: "Rest")).write(to: rest)
        let store = RevisionStore(directory: package)
        _ = try store.load()
        book.title = "Kunst 2"
        try store.save(book)
        XCTAssertFalse(FileManager.default.fileExists(atPath: rest.path), "an interrupted commit's rest from before still goes")
    }

    func testWriteLockAdmitsOneClaimPerPackage() async throws {
        let lock = PackageWriteLock()
        let package = directory()
        var first = lock.claim(package)
        XCTAssertNotNil(first)
        XCTAssertNil(lock.claim(package))
        XCTAssertNil(lock.claim(URL(fileURLWithPath: package.path + "/")), "same package with a trailing slash")
        XCTAssertNil(lock.claim(package.appendingPathComponent("x").appendingPathComponent("..")), "same package via ..")
        XCTAssertTrue(lock.isHeld(package))
        XCTAssertNotNil(lock.claim(directory()), "another package is independent")
        first?.release(); first?.release()
        XCTAssertFalse(lock.isHeld(package))
        var second = lock.claim(package)
        XCTAssertNotNil(second)
        second = nil // released with the claim object
        XCTAssertFalse(lock.isHeld(package))
        _ = second

        let held = lock.claim(package)!
        Task { try? await Task.sleep(nanoseconds: 150_000_000); held.release() }
        let waited = await lock.claim(package, waitingUpTo: 5)
        XCTAssertNotNil(waited, "waits for a running writer")
        let refused = await lock.claim(package, waitingUpTo: 0.1)
        XCTAssertNil(refused)
        first = nil
    }

    /// The reported race: an editor model loads while the library appends a
    /// shared file, then autosaves. The append must survive.
    func testEditorThatLoadedBeforeAnAppendCannotDropTheAppendedPages() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let library = LibraryStore(root: root); _ = try await library.load()
        let book = Notebook.blank(title: "Physik")
        _ = try await library.createDocument(book, parentID: nil)
        let url = try await library.documentURL(id: book.id)

        let editor = NotebookRepository(directory: url)
        var (loaded, _) = try await editor.load()
        let result = try await library.appendIncomingPDF(to: book.id, data: Data("%PDF-1.7 Blatt".utf8), geometries: [geometry, geometry],
                                                         placement: .end, writingArea: nil)
        XCTAssertTrue(result.verified)
        loaded.pages[0].drawing = Data([4, 5])
        do { try await editor.save(loaded, revision: 1); XCTFail("stale editor committed") }
        catch RevisionError.concurrentChange {}
        let stored = try RevisionStore(directory: url, readOnly: true).load()
        XCTAssertEqual(stored.pages.count, 3)
        XCTAssertEqual(Array(stored.pages.suffix(2).map(\.id)), result.pageIDs)
    }

    func testAppendIsRefusedWhileAWriterHoldsThePackage() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let library = LibraryStore(root: root); _ = try await library.load()
        let book = Notebook.blank(title: "Mathe")
        _ = try await library.createDocument(book, parentID: nil)
        let url = try await library.documentURL(id: book.id)
        let manifest = try Data(contentsOf: url.appendingPathComponent("manifest.json"))
        // An editor (or restore copy editor) holds it for its lifetime.
        var editorClaim = PackageWriteLock.shared.claim(url)
        XCTAssertNotNil(editorClaim)
        do {
            _ = try await library.appendIncomingPDF(to: book.id, data: Data("%PDF-x".utf8), geometries: [geometry], placement: .end, writingArea: nil)
            XCTFail("appended into a held package")
        } catch IncomingFileError.notebookInUse {}
        XCTAssertEqual(try Data(contentsOf: url.appendingPathComponent("manifest.json")), manifest)
        editorClaim = nil
        let result = try await library.appendIncomingPDF(to: book.id, data: Data("%PDF-x".utf8), geometries: [geometry], placement: .end, writingArea: nil)
        XCTAssertEqual(result.pageIDs.count, 1)
        XCTAssertFalse(PackageWriteLock.shared.isHeld(url), "the append releases its claim")
        _ = editorClaim
    }

    func testFailedReadBackAfterCommitIsReportedAsUnverifiedNotAsUnchanged() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let library = LibraryStore(root: root); _ = try await library.load()
        let book = Notebook.blank(title: "Erdkunde")
        _ = try await library.createDocument(book, parentID: nil)
        let url = try await library.documentURL(id: book.id)
        LibraryStore.incomingReadBackFault = { throw RevisionError.noCompleteRevision }
        defer { LibraryStore.incomingReadBackFault = {} }
        let result = try await library.appendIncomingPDF(to: book.id, data: Data("%PDF-x".utf8), geometries: [geometry], placement: .end, writingArea: nil)
        XCTAssertFalse(result.verified)
        let stored = try RevisionStore(directory: url, readOnly: true).load()
        XCTAssertEqual(stored.pages.last?.id, result.pageIDs.first, "the pages are committed")
    }
}
