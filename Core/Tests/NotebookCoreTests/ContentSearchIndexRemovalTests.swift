import XCTest
@testable import NotebookCore

/// The index holds the notebooks' text in plain form; it must not outlive a
/// permanently deleted notebook or a removed area.
final class ContentSearchIndexRemovalTests: XCTestCase {
    private var base: URL!
    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("search-removal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: base) }

    private func index(_ id: UUID, _ text: String) -> SearchDocumentIndex {
        SearchDocumentIndex(documentID: id, revisionStamp: "r", pages: [SearchPageRecord(pageID: UUID(),
            text: [SearchLine(text: text, kind: .text, bounds: .init(x: 0, y: 0, width: 5, height: 5))])])
    }
    private func store(_ area: String, _ ids: [UUID]) async -> ContentSearchIndexStore {
        let store = ContentSearchIndexStore(directory: base.appendingPathComponent(area, isDirectory: true))
        for id in ids {
            let saved = await store.save(index(id, "Geheim \(id.uuidString)"))
            XCTAssertTrue(saved)
        }
        return store
    }

    func testRemovingPurgedNotebooksDeletesExactlyTheirIndexFiles() async throws {
        let purged = UUID(), alsoPurged = UUID(), kept = UUID(), folder = UUID()
        let store = await store("Area", [purged, alsoPurged, kept])
        // A purge result also names folders and notebooks that were never indexed.
        await store.remove([purged, alsoPurged, folder, UUID()])
        let ids = await store.ids()
        XCTAssertEqual(ids, [kept])
        let directory = await store.directory
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(files, ["\(kept.uuidString).json"])
        let gone = await store.load(purged)
        XCTAssertNil(gone)
        let remaining = await store.load(kept)
        XCTAssertEqual(remaining?.documentID, kept)
    }

    func testRemovingAnAreaDeletesItsDirectoryAndLeavesOtherAreas() async throws {
        let first = UUID(), second = UUID(), other = UUID()
        let removed = await store("Removed", [first, second])
        let neighbour = await store("Neighbour", [other])
        // Atomic-write leftovers and foreign files are derived data of the area, too.
        let directory = await removed.directory
        try Data("rest".utf8).write(to: directory.appendingPathComponent("leftover.tmp"))
        await removed.removeAll()
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        let none = await removed.ids()
        XCTAssertEqual(none, [])
        let others = await neighbour.ids()
        XCTAssertEqual(others, [other])
    }

    func testRemovalWithoutAnIndexIsHarmlessAndTheStoreStaysUsable() async throws {
        let id = UUID()
        let store = ContentSearchIndexStore(directory: base.appendingPathComponent("Never", isDirectory: true))
        await store.remove([id])
        await store.removeAll()
        let saved = await store.save(index(id, "neu"))
        XCTAssertTrue(saved)
        let ids = await store.ids()
        XCTAssertEqual(ids, [id])
    }
}
