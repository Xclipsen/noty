import Foundation
import XCTest
@testable import NotebookCore

final class NotebookRepositoryTests: XCTestCase {
    func testConcurrentSavesCommitHighestRevisionRegardlessOfArrivalOrder() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = NotebookRepository(directory: directory)
        let base = Notebook()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for revision in 1...40 {
                var document = base
                document.pages[0].text = "Revision \(revision)"
                let snapshot = document
                group.addTask { try await repository.save(snapshot, revision: revision) }
            }
            try await group.waitForAll()
        }
        let (loaded, _) = try await repository.load()
        XCTAssertEqual(loaded.id, base.id)
        XCTAssertEqual(loaded.pages[0].text, "Revision 40")
        // Verify a fresh reader too, rather than only the actor's cached state.
        XCTAssertEqual(try RevisionStore(directory: directory).load(), loaded)
    }

    func testOlderAutosaveCannotOverwriteNewerSnapshot() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = NotebookRepository(directory: directory)
        var old = Notebook()
        old.pages[0].text = "alt"
        var new = old
        new.pages[0].text = "neu"
        try await repository.save(new, revision: 2)
        try await repository.save(old, revision: 1)
        let (loaded, _) = try await repository.load()
        XCTAssertEqual(loaded, new)
    }

    func testSaveCannotOverwriteFuturePackageFormat() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let manifest = directory.appendingPathComponent("manifest.json")
        let bytes = Data("{\"formatVersion\":99}".utf8)
        try bytes.write(to: manifest)
        let repository = NotebookRepository(directory: directory)
        do {
            try await repository.save(Notebook(), revision: 1)
            XCTFail("Future package must remain protected")
        } catch RevisionError.unsupportedFormat(99) { }
        XCTAssertEqual(try Data(contentsOf: manifest), bytes)
    }

    func testRestoredCopyListingDecodesAgainOnlyAfterANewCommit() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let main = NotebookRepository(directory: root)
        var original = Notebook()
        original.pages[0].text = "Original"
        try await main.save(original, revision: 1)
        let history = try await main.localHistory()
        let revisionID = try XCTUnwrap(history.revisions.first?.id)
        let prepared = try await main.prepareLocalRecovery(id: revisionID)
        let copy = try await main.commitRestore(prepared)
        let listing = NotebookRepository(directory: root)
        let first = try await listing.restoredCopies()
        XCTAssertEqual(first.notebooks.map(\.id), [copy.id])
        XCTAssertEqual(first.notebooks.first?.textPages.first?.text, "Original")
        // A commit replaces manifest.json: the entry is decoded again.
        let store = RevisionStore(directory: copy.directory)
        var edited = try store.load()
        edited.pages[0].text = "In der Kopie bearbeitet"
        try store.save(edited)
        let second = try await listing.restoredCopies()
        XCTAssertEqual(second.notebooks.first?.textPages.first?.text, "In der Kopie bearbeitet")
        // Without a commit nothing is read again (damage shows on a fresh listing or on opening).
        let revisions = copy.directory.appendingPathComponent("Revisions")
        for name in try FileManager.default.contentsOfDirectory(atPath: revisions.path) {
            try Data("beschädigt".utf8).write(to: revisions.appendingPathComponent(name))
        }
        let cached = try await listing.restoredCopies()
        XCTAssertEqual(cached.notebooks.map(\.id), [copy.id])
        XCTAssertEqual(cached.unreadableCount, 0)
        let fresh = try await NotebookRepository(directory: root).restoredCopies()
        XCTAssertEqual(fresh.notebooks.count, 0)
        XCTAssertEqual(fresh.unreadableCount, 1)
        // Removed copies leave the listing.
        try FileManager.default.removeItem(at: copy.directory)
        let empty = try await listing.restoredCopies()
        XCTAssertTrue(empty.notebooks.isEmpty)
    }
}
