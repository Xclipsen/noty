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
        let store = RevisionStore(directory: root)
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        store.clock = { now }
        var document = Notebook()
        try store.save(document)
        let oldID = try XCTUnwrap(store.localHistory().revisions.first?.id)
        // Every save 11 minutes later: 3 newest + 5 checkpoints push out the first.
        for revision in 2...10 {
            now += 660
            document.pages[0].text = "Stand \(revision)"
            try store.save(document)
        }
        let repository = NotebookRepository(directory: root)
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
        try LegacyFixture.write(document, to: root)
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

    // MARK: Tiered retention

    private func record(_ time: Double?, bytes: Int = 1_000) -> RevisionRecord {
        RevisionRecord(file: UUID().uuidString + ".json", byteCount: bytes, crc32: 0, savedAtUnix: time)
    }

    private func physicalFiles(_ root: URL) throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Revisions").path))
    }

    private func previousManifest(_ root: URL) throws -> RevisionManifest {
        try JSONDecoder().decode(RevisionManifest.self, from: Data(contentsOf: root.appendingPathComponent("manifest-previous.json")))
    }

    private func checkpointList(_ root: URL) throws -> CheckpointList {
        try JSONDecoder().decode(CheckpointList.self, from: Data(contentsOf: root.appendingPathComponent("checkpoints.json")))
    }

    /// Replica of Build 46 `RevisionStore.validate`: anything else makes it
    /// fall back to an older revision, auto-save and delete the newer one.
    private func build46Accepts(_ url: URL) throws -> Bool {
        let manifest = try JSONDecoder().decode(RevisionManifest.self, from: Data(contentsOf: url))
        return manifest.formatVersion == 1 && manifest.checksumAlgorithm == "crc32-iso-hdlc"
            && (1...3).contains(manifest.revisions.count)
            && Set(manifest.revisions.map(\.file)).count == manifest.revisions.count
            && manifest.revisions.allSatisfy { record in
                UUID(uuidString: String(record.file.dropLast(5)))?.uuidString == String(record.file.dropLast(5))
                    && record.file.hasSuffix(".json") && (1...200_000_000).contains(record.byteCount)
                    && (record.savedAtUnix.map { $0.isFinite && (-62_135_596_800...253_402_300_799).contains($0) } ?? true)
            }
    }

    /// Continuous editing, one save per minute for 90 minutes.
    private func editForNinetyMinutes(_ root: URL) throws -> (RevisionStore, Notebook, [Double: Notebook], Date) {
        let store = RevisionStore(directory: root)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var now = start
        store.clock = { now }
        var document = Notebook()
        var states: [Double: Notebook] = [:]
        for minute in 0...90 {
            now = start + Double(minute) * 60
            document.pages[0].text = "Minute \(minute)"
            try store.save(document)
            states[now.timeIntervalSince1970] = document
        }
        return (store, document, states, start)
    }

    func testContinuousEditingKeepsCheckpointsTenMinutesApartForAboutAnHour() throws {
        let root = try directory()
        let (store, document, states, start) = try editForNinetyMinutes(root)
        // Manifests keep the Build 46 format: the three newest states only.
        let entries = try manifest(root).revisions
        XCTAssertEqual(entries.compactMap(\.savedAtUnix), [90, 89, 88].map { start.timeIntervalSince1970 + Double($0) * 60 })
        XCTAssertTrue(try build46Accepts(root.appendingPathComponent("manifest.json")))
        XCTAssertTrue(try build46Accepts(root.appendingPathComponent("manifest-previous.json")))
        let checkpoints = try checkpointList(root).checkpoints
        XCTAssertEqual(checkpoints.count, 5)
        let times = checkpoints.compactMap(\.savedAtUnix)
        XCTAssertEqual(times, [80, 70, 60, 50, 40].map { start.timeIntervalSince1970 + Double($0) * 60 })
        let history = try store.localHistory()
        XCTAssertEqual(history.revisions.count, 8)
        XCTAssertEqual(history.unreadableCount, 0)
        XCTAssertEqual(history.revisions.map { $0.savedAt?.timeIntervalSince1970 }, entries.compactMap(\.savedAtUnix) + times)
        XCTAssertEqual(history.revisions.filter(\.isLatest).count, 1)
        for revision in history.revisions {
            XCTAssertEqual(try store.localRevision(id: revision.id), states[revision.savedAt!.timeIntervalSince1970])
        }
        // GC keeps manifest ∪ previous ∪ checkpoints; checkpoints are never quarantined.
        let union = Set((entries + (try previousManifest(root)).revisions + checkpoints).map(\.file))
        XCTAssertEqual(try physicalFiles(root), union)
        XCTAssertLessThanOrEqual(union.count, 9)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Quarantine").path))
        // A fresh store reads the same eight states.
        let reopened = RevisionStore(directory: root)
        XCTAssertEqual(try reopened.load(), document)
        XCTAssertEqual(try reopened.localHistory().revisions.map(\.id), history.revisions.map(\.id))
    }

    func testCheckpointsSurviveWhereBuild46CollectedTheirFiles() throws {
        let root = try directory()
        let (_, document, _, _) = try editForNinetyMinutes(root)
        // Build 46 commits: it only knows both manifests and deletes every other revision.
        let referenced = Set((try manifest(root).revisions + (try previousManifest(root)).revisions).map(\.file))
        for file in try physicalFiles(root) where !referenced.contains(file) {
            try FileManager.default.removeItem(at: root.appendingPathComponent("Revisions/" + file))
        }
        let reopened = RevisionStore(directory: root)
        XCTAssertEqual(try reopened.load(), document)
        XCTAssertFalse(reopened.recovered)
        let history = try reopened.localHistory()
        XCTAssertEqual(history.revisions.count, 3)
        XCTAssertEqual(history.unreadableCount, 0)
        var edited = document
        edited.pages[0].text = "nach Build 46"
        try reopened.save(edited)
        // No dangling entries are written back; nothing moves to quarantine.
        let checkpoints = try checkpointList(root).checkpoints
        XCTAssertTrue(Set(checkpoints.map(\.file)).isSubset(of: try physicalFiles(root)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Quarantine").path))
        XCTAssertEqual(try RevisionStore(directory: root).load(), edited)
    }

    func testDamagedOrFutureCheckpointListNeverBlocksLoadingOrSaving() throws {
        let root = try directory()
        let (_, document, _, _) = try editForNinetyMinutes(root)
        let file = root.appendingPathComponent("checkpoints.json")
        try Data("{\"formatVersion\":1,".utf8).write(to: file)
        let damaged = RevisionStore(directory: root)
        XCTAssertEqual(try damaged.load(), document)
        XCTAssertFalse(damaged.recovered)
        XCTAssertEqual(try damaged.localHistory().revisions.count, 3)
        var edited = document
        edited.pages[0].text = "trotz defekter Checkpoints"
        try damaged.save(edited)
        XCTAssertEqual(try RevisionStore(directory: root).load(), edited)
        XCTAssertNoThrow(try checkpointList(root))

        // A newer list format is left untouched and only ignored.
        let future = Data("{\"formatVersion\":2,\"checkpoints\":[]}".utf8)
        try future.write(to: file)
        let newer = RevisionStore(directory: root)
        XCTAssertEqual(try newer.load(), edited)
        edited.pages[0].text = "mit neuerem Checkpoint-Format"
        try newer.save(edited)
        XCTAssertEqual(try Data(contentsOf: file), future)
        XCTAssertEqual(try RevisionStore(directory: root).load(), edited)
    }

    func testCheckpointSpacingCapAndTimestampRules() {
        let base = 1_800_000_000.0
        // Newest three always, regardless of time; then spacing from the older side.
        let candidates = [record(base + 5_000), record(base + 4_999), record(base + 4_998),
                          record(base + 4_990), record(base + 4_000), record(base + 3_500), record(nil),
                          record(base + 3_300), record(base)]
        let kept = RevisionStore.retained(candidates)
        // Oldest first: +0 anchors, +3300 kept, +3500 too close, +4000 and +4990 kept.
        XCTAssertEqual(kept.map(\.file), [0, 1, 2, 3, 4, 7, 8].map { candidates[$0].file })
        // Cap: at most 8 entries in total, oldest checkpoints dropped first.
        let many = (0..<20).map { record(base + Double(20 - $0) * 700) }
        let capped = RevisionStore.retained(many)
        XCTAssertEqual(capped.map(\.file), many.prefix(8).map(\.file))
        // Old manifests without timestamps keep only the newest three.
        XCTAssertEqual(RevisionStore.retained((0..<5).map { _ in record(nil) }).count, 3)
    }

    func testCheckpointSizeCapDropsOldestCheckpointsFirst() {
        let base = 1_800_000_000.0
        let candidates = [record(base + 10_000, bytes: 190_000_000), record(base + 9_999, bytes: 190_000_000),
                          record(base + 9_998, bytes: 190_000_000),
                          record(base + 8_000, bytes: 120_000_000), record(base + 6_000, bytes: 120_000_000),
                          record(base + 4_000, bytes: 120_000_000), record(base + 2_000, bytes: 50_000_000)]
        let kept = RevisionStore.retained(candidates)
        // The newest three do not count; checkpoints together stay ≤ 300 MB.
        XCTAssertEqual(kept.map(\.file), candidates.prefix(5).map(\.file))
        XCTAssertLessThanOrEqual(kept.dropFirst(3).reduce(0) { $0 + $1.byteCount }, 300_000_000)
        let small = candidates.prefix(3) + [record(base + 8_000, bytes: 100_000_000), record(base + 6_000, bytes: 100_000_000),
                                            record(base + 4_000, bytes: 100_000_000)]
        XCTAssertEqual(RevisionStore.retained(Array(small)).count, 6)
    }

    func testTieredHistorySurvivesReopenAndOlderTimestamplessEntries() throws {
        let root = try directory()
        let store = RevisionStore(directory: root)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var now = start
        store.clock = { now }
        var document = Notebook()
        for step in 0..<6 {
            now = start + Double(step) * 900
            document.pages[0].text = "Stand \(step)"
            try store.save(document)
        }
        XCTAssertEqual(try manifest(root).revisions.count, 3)
        XCTAssertEqual(try checkpointList(root).checkpoints.count, 3)
        let reopened = RevisionStore(directory: root)
        reopened.clock = { now }
        XCTAssertEqual(try reopened.load(), document)
        now += 30
        document.pages[0].text = "nach dem Öffnen"
        try reopened.save(document)
        let entries = try manifest(root).revisions
        let checkpoints = try checkpointList(root).checkpoints
        XCTAssertEqual(entries.count + checkpoints.count, 7)
        XCTAssertEqual(try physicalFiles(root), Set((entries + (try previousManifest(root)).revisions + checkpoints).map(\.file)))
        XCTAssertEqual(try reopened.localHistory().revisions.count, 7)
    }
}
