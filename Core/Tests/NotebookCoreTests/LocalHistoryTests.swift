import Foundation
import XCTest
@testable import NotebookCore

final class LocalHistoryTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: url) }
        return url
    }

    private func manifest(_ root: URL) throws -> RevisionManifest {
        try JSONDecoder().decode(RevisionManifest.self, from: Data(contentsOf: root.appendingPathComponent("manifest.json")))
    }

    func testSelectionUsesStableRevisionIdentityAfterNewCommit() throws {
        let root = try directory()
        let store = RevisionStore(directory: root)
        var old = Notebook()
        old.pages[0].text = "alt"
        try store.save(old)
        var current = old
        current.pages[0].text = "neu"
        try store.save(current)
        let history = try store.localHistory()
        XCTAssertEqual(history.revisions.count, 2)
        XCTAssertTrue(history.revisions[0].isLatest)
        XCTAssertFalse(history.revisions[1].isLatest)
        XCTAssertNotNil(history.revisions[0].savedAt)
        let selected = history.revisions[0].id
        var newer = current
        newer.pages[0].text = "noch neuer"
        try store.save(newer)
        XCTAssertEqual(try store.localRevision(id: selected), current)
        XCTAssertEqual(try store.localRevision(id: history.revisions[1].id), old)
        XCTAssertEqual(try RevisionStore(directory: root).load(), newer)
    }

    func testOldManifestWithoutTimestampsStillLoadsAndListsHistory() throws {
        let root = try directory()
        let store = RevisionStore(directory: root)
        let document = Notebook()
        try store.save(document)
        let primary = root.appendingPathComponent("manifest.json")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: primary)) as? [String: Any])
        var entries = try XCTUnwrap(object["revisions"] as? [[String: Any]])
        entries[0].removeValue(forKey: "savedAtUnix")
        object["revisions"] = entries
        try JSONSerialization.data(withJSONObject: object).write(to: primary)
        let reopened = RevisionStore(directory: root)
        XCTAssertEqual(try reopened.load(), document)
        let history = try reopened.localHistory()
        XCTAssertEqual(history.revisions.count, 1)
        XCTAssertNotNil(history.revisions[0].savedAt)
    }

    func testCorruptOlderRevisionIsReportedAndCannotBeSelected() throws {
        let root = try directory()
        let store = RevisionStore(directory: root)
        let old = Notebook()
        try store.save(old)
        let oldID = try XCTUnwrap(store.localHistory().revisions.first?.id)
        var current = old
        current.pages[0].text = "aktuell"
        try store.save(current)
        let file = root.appendingPathComponent("Revisions/" + oldID.uuidString + ".json")
        let corrupt = Data("broken".utf8)
        try corrupt.write(to: file)
        let history = try store.localHistory()
        XCTAssertEqual(history.unreadableCount, 1)
        XCTAssertEqual(history.revisions.count, 1)
        XCTAssertTrue(history.revisions[0].isLatest)
        XCTAssertThrowsError(try store.localRevision(id: oldID))
        XCTAssertEqual(try Data(contentsOf: file), corrupt)
        XCTAssertEqual(try RevisionStore(directory: root).load(), current)
    }

    func testEvictedSelectionFailsWithoutCreatingRestoreOrChangingMain() async throws {
        let root = try directory()
        let repository = NotebookRepository(directory: root)
        var document = Notebook()
        try await repository.save(document, revision: 1)
        let history = try await repository.localHistory()
        let oldID = try XCTUnwrap(history.revisions.first?.id)
        for revision in 2...6 {
            document.pages[0].text = "Stand \(revision)"
            try await repository.save(document, revision: revision)
        }
        do {
            _ = try await repository.prepareLocalRecovery(id: oldID)
            XCTFail("An evicted token must fail, not select by current array position")
        } catch RevisionError.revisionUnavailable { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("BackupStaging").path))
        let (loaded, _) = try await repository.load()
        XCTAssertEqual(loaded, document)
    }

    func testOlderLocalRevisionRestoresAsEditableCopyWithoutChangingCurrentCommit() async throws {
        let root = try directory()
        let repository = NotebookRepository(directory: root)
        var old = Notebook()
        old.pages[0].text = "alter Text"
        old.pages[0].drawing = Data([1, 2, 3])
        try await repository.save(old, revision: 1)
        var current = old
        current.pages[0].text = "aktueller Text"
        current.pages[0].drawing.append(4)
        try await repository.save(current, revision: 2)
        let primary = root.appendingPathComponent("manifest.json")
        let originalBytes = try Data(contentsOf: primary)
        let history = try await repository.localHistory()
        let selected = try XCTUnwrap(history.revisions.last?.id)
        let prepared = try await repository.prepareLocalRecovery(id: selected)
        XCTAssertEqual(prepared.document.pages, old.pages)
        XCTAssertNotEqual(prepared.document.id, current.id)
        let destination = try await repository.commitRestore(prepared)
        var edited = try RevisionStore(directory: destination.directory).load()
        edited.pages[0].text += " · in Kopie bearbeitet"
        edited.pages[0].drawing.append(5)
        try RevisionStore(directory: destination.directory).save(edited)
        XCTAssertEqual(try RevisionStore(directory: destination.directory).load(), edited)
        XCTAssertEqual(try Data(contentsOf: primary), originalBytes)
        let (unchanged, _) = try await repository.load()
        XCTAssertEqual(unchanged, current)
    }

    func testUnknownOlderSchemaIsNotSilentlyHiddenOrOverwritten() throws {
        let root = try directory()
        let store = RevisionStore(directory: root)
        let old = Notebook()
        try store.save(old)
        var current = old
        current.pages[0].text = "neu"
        try store.save(current)
        var index = try manifest(root)
        let future = Data("{\"schemaVersion\":99}".utf8)
        index.revisions[1].byteCount = future.count
        index.revisions[1].crc32 = SnapshotChecksum.crc32(future)
        try future.write(to: root.appendingPathComponent("Revisions/" + index.revisions[1].file))
        let primary = root.appendingPathComponent("manifest.json")
        let originalBytes = try JSONEncoder().encode(index)
        try originalBytes.write(to: primary)
        let reopened = RevisionStore(directory: root)
        XCTAssertEqual(try reopened.load(), current)
        XCTAssertThrowsError(try reopened.localHistory()) { error in
            guard case StorageError.unsupportedSchema(99) = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(try Data(contentsOf: primary), originalBytes)
    }

    func testOutOfRangeTimestampMakesManifestInvalidAndUsesPrevious() throws {
        let root = try directory()
        let store = RevisionStore(directory: root)
        let old = Notebook()
        try store.save(old)
        var current = old
        current.pages[0].text = "neu"
        try store.save(current)
        var index = try manifest(root)
        index.revisions[0].savedAtUnix = 1e100
        try JSONEncoder().encode(index).write(to: root.appendingPathComponent("manifest.json"))
        let reopened = RevisionStore(directory: root)
        XCTAssertEqual(try reopened.load(), old)
        XCTAssertTrue(reopened.recovered)
    }

    func testListingLegacyHistoryDoesNotMigrateOrModifyOriginal() throws {
        let root = try directory()
        let document = Notebook()
        try NotebookStore(directory: root).save(document)
        let original = try Data(contentsOf: root.appendingPathComponent("notebook.json"))
        let history = try RevisionStore(directory: root).localHistory()
        XCTAssertTrue(history.revisions.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("manifest.json").path))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("notebook.json")), original)
    }

    func testRecoveryFromRestoredCopyRemainsInSharedCollectionAfterReopening() async throws {
        let root = try directory()
        let main = NotebookRepository(directory: root)
        let original = Notebook()
        try await main.save(original, revision: 1)
        let originalHistory = try await main.localHistory()
        let originalID = try XCTUnwrap(originalHistory.revisions.first?.id)
        let firstPreparation = try await main.prepareLocalRecovery(id: originalID)
        let firstCopy = try await main.commitRestore(firstPreparation)
        let copyRepository = NotebookRepository(directory: firstCopy.directory, restoreDirectory: firstCopy.collectionDirectory)
        var editedCopy = try RevisionStore(directory: firstCopy.directory).load()
        editedCopy.pages[0].text = "Kopie bearbeitet"
        try await copyRepository.save(editedCopy, revision: 1)
        let copyHistory = try await copyRepository.localHistory()
        let priorCopyID = try XCTUnwrap(copyHistory.revisions.last?.id)
        let secondPreparation = try await copyRepository.prepareLocalRecovery(id: priorCopyID)
        let secondCopy = try await copyRepository.commitRestore(secondPreparation)
        XCTAssertEqual(secondCopy.directory.deletingLastPathComponent(), firstCopy.directory.deletingLastPathComponent())
        XCTAssertEqual(secondCopy.collectionDirectory, firstCopy.collectionDirectory)
        let reopenedMain = NotebookRepository(directory: root)
        let catalog = try await reopenedMain.restoredCopies()
        XCTAssertEqual(Set(catalog.notebooks.map(\.id)), Set([firstCopy.id, secondCopy.id]))
        XCTAssertEqual(try RevisionStore(directory: firstCopy.directory).load(), editedCopy)
        XCTAssertEqual(try RevisionStore(directory: root).load(), original)
    }
}
