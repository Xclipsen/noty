import Foundation
import XCTest
@testable import NotebookCore

final class RevisionStoreTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: url) }
        return url
    }

    private func manifest(_ root: URL) throws -> RevisionManifest {
        try JSONDecoder().decode(RevisionManifest.self, from: Data(contentsOf: root.appendingPathComponent("manifest.json")))
    }

    func testChecksumKnownVectors() {
        XCTAssertEqual(SnapshotChecksum.crc32(Data()), 0)
        XCTAssertEqual(SnapshotChecksum.crc32(Data("123456789".utf8)), 0xcbf43926)
        XCTAssertEqual(SnapshotChecksum.crc32(Data("The quick brown fox jumps over the lazy dog".utf8)), 0x414fa339)
    }

    func testImmutableRevisionsKeepNewestThreePlusFirstCheckpointAndBoundPhysicalHistory() throws {
        let root = try directory()
        let store = RevisionStore(directory: root)
        var document = Notebook()
        try store.save(document)
        let first = try manifest(root).revisions[0]
        let firstURL = root.appendingPathComponent("Revisions/" + first.file)
        let firstBytes = try Data(contentsOf: firstURL)
        document.pages[0].text = "zweiter Stand"
        try store.save(document)
        XCTAssertEqual(try Data(contentsOf: firstURL), firstBytes)
        for revision in 3...12 {
            document.pages[0].text = "Stand \(revision)"
            try store.save(document)
        }
        // Rapid saves: the newest three in the manifest (Build 46 format), the
        // oldest state as only checkpoint in checkpoints.json.
        XCTAssertEqual(try manifest(root).revisions.count, 3)
        let checkpoints = try JSONDecoder().decode(CheckpointList.self, from: Data(contentsOf: root.appendingPathComponent("checkpoints.json")))
        XCTAssertEqual(checkpoints.checkpoints, [first])
        XCTAssertEqual(try Data(contentsOf: firstURL), firstBytes)
        XCTAssertLessThanOrEqual(contents(root.appendingPathComponent("Revisions")).count, 5)
        XCTAssertEqual(try RevisionStore(directory: root).load(), document)
    }

    private func referenced(_ root: URL) throws -> Set<String> {
        var files = Set(try manifest(root).revisions.map(\.file))
        let previous = root.appendingPathComponent("manifest-previous.json")
        if FileManager.default.fileExists(atPath: previous.path) {
            files.formUnion(try JSONDecoder().decode(RevisionManifest.self, from: Data(contentsOf: previous)).revisions.map(\.file))
        }
        let checkpoints = root.appendingPathComponent("checkpoints.json")
        if FileManager.default.fileExists(atPath: checkpoints.path) {
            files.formUnion(try JSONDecoder().decode(CheckpointList.self, from: Data(contentsOf: checkpoints)).checkpoints.map(\.file))
        }
        return files
    }

    private func contents(_ folder: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
    }

    func testValidJSONWithChangedBytesFailsChecksumAndRecoversOlderState() throws {
        let root = try directory()
        let store = RevisionStore(directory: root)
        var first = Notebook()
        first.pages[0].text = "AAA"
        try store.save(first)
        var second = first
        second.pages[0].text = "BBB"
        try store.save(second)
        let newest = try manifest(root).revisions[0].file
        let latest = root.appendingPathComponent("Revisions/" + newest)
        let damaged = Data(try String(contentsOf: latest, encoding: .utf8).replacingOccurrences(of: "BBB", with: "CCC").utf8)
        try damaged.write(to: latest)
        let recovered = RevisionStore(directory: root)
        XCTAssertEqual(try recovered.load(), first)
        XCTAssertTrue(recovered.recovered)
        // The recovered state is committed with the next edit. The damaged newer
        // revision is neither referenced nor deleted: it moves to Quarantine.
        var edited = first
        edited.pages[0].text = "AAA · weiter bearbeitet"
        try recovered.save(edited)
        XCTAssertFalse(recovered.recovered)
        XCTAssertEqual(try RevisionStore(directory: root).load(), edited)
        XCTAssertFalse(try referenced(root).contains(newest))
        XCTAssertFalse(FileManager.default.fileExists(atPath: latest.path))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("Quarantine/" + newest)), damaged)
        for revision in 1...4 {
            edited.pages[0].text = "Stand \(revision)"
            try recovered.save(edited)
        }
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("Quarantine/" + newest)), damaged)
        XCTAssertTrue(try referenced(root).isDisjoint(with: contents(root.appendingPathComponent("Quarantine"))))
        XCTAssertEqual(try RevisionStore(directory: root).load(), edited)
    }

    func testDamagedManifestKeepsIntactNewestRevisionInQuarantineAfterRecoveredEdit() throws {
        let root = try directory()
        let store = RevisionStore(directory: root)
        var first = Notebook()
        first.pages[0].text = "bestätigt"
        try store.save(first)
        var newest = first
        newest.pages[0].text = "neuester, intakter Stand"
        try store.save(newest)
        let newestFile = try manifest(root).revisions[0].file
        let newestBytes = try Data(contentsOf: root.appendingPathComponent("Revisions/" + newestFile))
        let damagedManifest = Data("{\"formatVersion\":1,".utf8)
        try damagedManifest.write(to: root.appendingPathComponent("manifest.json"))
        let reopened = RevisionStore(directory: root)
        XCTAssertEqual(try reopened.load(), first)
        XCTAssertTrue(reopened.recovered)
        // Unchanged flushes are no-ops only in EditorModel; here the edit commits.
        var edited = first
        edited.pages[0].text = "nach Wiederherstellung bearbeitet"
        try reopened.save(edited)
        XCTAssertEqual(try RevisionStore(directory: root).load(), edited)
        XCTAssertFalse(try referenced(root).contains(newestFile))
        let quarantine = root.appendingPathComponent("Quarantine")
        XCTAssertEqual(try Data(contentsOf: quarantine.appendingPathComponent(newestFile)), newestBytes)
        XCTAssertEqual(try Notebook.decode(Data(contentsOf: quarantine.appendingPathComponent(newestFile))), newest)
        let manifests = contents(quarantine).filter { $0.hasPrefix("manifest-") }
        XCTAssertEqual(manifests.count, 1)
        XCTAssertEqual(try Data(contentsOf: quarantine.appendingPathComponent(manifests[0])), damagedManifest)
        // Nothing the acknowledged chain referenced was lost.
        let revisions = Set(contents(root.appendingPathComponent("Revisions")))
        XCTAssertTrue(try referenced(root).isSubset(of: revisions))
        for revision in 1...4 {
            edited.pages[0].text = "Stand \(revision)"
            try reopened.save(edited)
        }
        XCTAssertEqual(contents(quarantine).filter { $0.hasPrefix("manifest-") }.count, 1)
        XCTAssertEqual(try Data(contentsOf: quarantine.appendingPathComponent(newestFile)), newestBytes)
        XCTAssertEqual(try RevisionStore(directory: root).load(), edited)
    }

    func testNormalCommitsDeleteOwnDroppedRevisionsWithoutQuarantine() throws {
        let root = try directory()
        let store = RevisionStore(directory: root)
        var document = Notebook()
        for revision in 1...8 {
            document.pages[0].text = "Stand \(revision)"
            try store.save(document)
        }
        let reopened = RevisionStore(directory: root)
        XCTAssertEqual(try reopened.load(), document)
        for revision in 9...12 {
            document.pages[0].text = "Stand \(revision)"
            try reopened.save(document)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Quarantine").path))
        XCTAssertEqual(Set(contents(root.appendingPathComponent("Revisions"))), try referenced(root))
    }

    func testRepeatedFailedCommitsLeaveNoUncommittedRevisionFiles() throws {
        let root = try directory()
        let store = RevisionStore(directory: root)
        let acknowledged = Notebook()
        try store.save(acknowledged)
        let before = contents(root.appendingPathComponent("Revisions"))
        let primary = root.appendingPathComponent("manifest.json")
        try FileManager.default.moveItem(at: primary, to: root.appendingPathComponent("kept-manifest.json"))
        try FileManager.default.createDirectory(at: primary, withIntermediateDirectories: false)
        var edited = acknowledged
        for attempt in 1...5 {
            edited.pages[0].text = "Versuch \(attempt)"
            XCTAssertThrowsError(try store.save(edited))
        }
        XCTAssertEqual(contents(root.appendingPathComponent("Revisions")), before)
        try FileManager.default.removeItem(at: primary)
        try store.save(edited)
        XCTAssertEqual(try RevisionStore(directory: root).load(), edited)
    }

    func testTruncatedManifestUsesPreviousCompleteManifest() throws {
        let root = try directory()
        let store = RevisionStore(directory: root)
        let first = Notebook()
        try store.save(first)
        var second = first
        second.pages[0].text = "neuer"
        try store.save(second)
        try Data("{".utf8).write(to: root.appendingPathComponent("manifest.json"))
        let recovered = RevisionStore(directory: root)
        XCTAssertEqual(try recovered.load(), first)
        XCTAssertTrue(recovered.recovered)
    }

    func testRepeatedFailedMigrationCommitsReuseOneExactArchive() throws {
        let root = try directory()
        let acknowledged = Notebook.blank(title: "Schema 3")
        try RevisionStore(directory: root).save(acknowledged)
        let acknowledgedBytes = try Data(contentsOf: root.appendingPathComponent("Revisions/" + (try manifest(root).revisions[0].file)))
        let primary = root.appendingPathComponent("manifest.json")
        try FileManager.default.moveItem(at: primary, to: root.appendingPathComponent("kept-manifest.json"))
        try FileManager.default.createDirectory(at: primary, withIntermediateDirectories: false)
        try FileManager.default.copyItem(at: root.appendingPathComponent("kept-manifest.json"),
                                         to: root.appendingPathComponent("manifest-previous.json"))
        var upgraded = acknowledged
        upgraded.schemaVersion = 7
        upgraded.title = "Schema 7"
        let migrations = root.appendingPathComponent("Migrations")
        for _ in 0..<2 {
            // Also across restarts: a fresh store finds the identical archive.
            let store = RevisionStore(directory: root)
            XCTAssertEqual(try store.load(), acknowledged)
            for _ in 0..<3 { XCTAssertThrowsError(try store.save(upgraded)) }
            XCTAssertEqual(contents(migrations).count, 1)
        }
        try FileManager.default.removeItem(at: primary)
        let store = RevisionStore(directory: root)
        XCTAssertEqual(try store.load(), acknowledged)
        try store.save(upgraded)
        let folders = contents(migrations)
        XCTAssertEqual(folders.count, 1)
        XCTAssertEqual(try Data(contentsOf: migrations.appendingPathComponent(folders[0] + "/notebook-v3.json")), acknowledgedBytes)
        XCTAssertEqual(try RevisionStore(directory: root).load(), upgraded)
        // A different acknowledged state still gets its own archive.
        var next = upgraded
        next.schemaVersion = 8
        try store.save(next)
        XCTAssertEqual(contents(migrations).count, 2)
    }

    func testUncommittedRevisionDoesNotBecomeCurrentAndIsQuarantinedAfterCommit() throws {
        let root = try directory()
        let store = RevisionStore(directory: root)
        let first = Notebook()
        try store.save(first)
        var uncommitted = first
        uncommitted.pages[0].text = "nie bestätigter Stand"
        let name = UUID().uuidString + ".json"
        let orphan = root.appendingPathComponent("Revisions/" + name)
        let bytes = try JSONEncoder().encode(uncommitted)
        try bytes.write(to: orphan)
        let reopened = RevisionStore(directory: root)
        XCTAssertEqual(try reopened.load(), first)
        XCTAssertFalse(reopened.recovered)
        var next = first
        next.pages[0].text = "nächster bestätigter Stand"
        try reopened.save(next)
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
        // Never acknowledged by this store: kept, not deleted, and never referenced.
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("Quarantine/" + name)), bytes)
        XCTAssertFalse(try referenced(root).contains(name))
        XCTAssertEqual(try RevisionStore(directory: root).load(), next)
    }

    func testFailedManifestCommitKeepsAcknowledgedStateAndRetryWorks() throws {
        let root = try directory()
        let store = RevisionStore(directory: root)
        let acknowledged = Notebook()
        try store.save(acknowledged)
        let primary = root.appendingPathComponent("manifest.json")
        try FileManager.default.moveItem(at: primary, to: root.appendingPathComponent("preserved-manifest.json"))
        try FileManager.default.createDirectory(at: primary, withIntermediateDirectories: false)
        var edited = acknowledged
        edited.pages[0].text = "ungesichert"
        XCTAssertThrowsError(try store.save(edited))
        let reopened = RevisionStore(directory: root)
        XCTAssertEqual(try reopened.load(), acknowledged)
        XCTAssertTrue(reopened.recovered)
        try FileManager.default.removeItem(at: primary)
        try store.save(edited)
        XCTAssertEqual(try RevisionStore(directory: root).load(), edited)
    }

    func testLegacyMigrationLeavesExactOriginalFilesAndKeepsIDsAndGeometry() throws {
        let root = try directory()
        var legacy = Notebook()
        legacy.schemaVersion = 1
        legacy.pages[0].drawing = Data([1, 2, 3])
        legacy.pages[0].text = "Ältere Notiz"
        try LegacyFixture.write(legacy, to: root)
        let original = try Data(contentsOf: root.appendingPathComponent("notebook.json"))
        let store = RevisionStore(directory: root)
        var upgraded = try store.load()
        upgraded.schemaVersion = Notebook.currentSchemaVersion
        try store.save(upgraded)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("notebook.json")), original)
        XCTAssertEqual(try RevisionStore(directory: root).load(), upgraded)
        XCTAssertEqual(upgraded.pages, legacy.pages)
        XCTAssertEqual(upgraded.id, legacy.id)
        XCTAssertEqual(try manifest(root).revisions.count, 2)
    }

    func testFutureManifestVersionDoesNotFallBackOrGetOverwritten() throws {
        let root = try directory()
        let store = RevisionStore(directory: root)
        var document = Notebook()
        try store.save(document)
        document.pages[0].text = "neu"
        try store.save(document)
        let future = Data("{\"formatVersion\":99}".utf8)
        let primary = root.appendingPathComponent("manifest.json")
        try future.write(to: primary)
        let olderApp = RevisionStore(directory: root)
        XCTAssertThrowsError(try olderApp.load()) { error in
            guard case RevisionError.unsupportedFormat(99) = error else { return XCTFail("\(error)") }
        }
        XCTAssertThrowsError(try olderApp.save(document))
        XCTAssertEqual(try Data(contentsOf: primary), future)
    }

    func testFutureDocumentSchemaDoesNotSilentlyUseOlderRevision() throws {
        let root = try directory()
        let store = RevisionStore(directory: root)
        let first = Notebook()
        try store.save(first)
        var second = first
        second.pages[0].text = "neu"
        try store.save(second)
        var index = try manifest(root)
        let future = Data("{\"schemaVersion\":99}".utf8)
        index.revisions[0].byteCount = future.count
        index.revisions[0].crc32 = SnapshotChecksum.crc32(future)
        try future.write(to: root.appendingPathComponent("Revisions/" + index.revisions[0].file))
        try JSONEncoder().encode(index).write(to: root.appendingPathComponent("manifest.json"))
        XCTAssertThrowsError(try RevisionStore(directory: root).load()) { error in
            guard case StorageError.unsupportedSchema(99) = error else { return XCTFail("\(error)") }
        }
    }

    func testUnsafePathSymlinkAndOversizedRecordAreRejectedWithoutTouchingFiles() throws {
        let root = try directory()
        let store = RevisionStore(directory: root)
        try store.save(Notebook())
        let index = try manifest(root)
        let primary = root.appendingPathComponent("manifest.json")
        for invalid in ["../notebook.json", "/tmp/notebook.json", "subdir/" + index.revisions[0].file] {
            var unsafe = index
            unsafe.revisions[0].file = invalid
            try JSONEncoder().encode(unsafe).write(to: primary)
            XCTAssertThrowsError(try RevisionStore(directory: root).load())
        }
        var oversized = index
        oversized.revisions[0].byteCount = 200_000_001
        try JSONEncoder().encode(oversized).write(to: primary)
        XCTAssertThrowsError(try RevisionStore(directory: root).load())
        try JSONEncoder().encode(index).write(to: primary)
        let revision = root.appendingPathComponent("Revisions/" + index.revisions[0].file)
        let preserved = root.appendingPathComponent("original.json")
        try FileManager.default.moveItem(at: revision, to: preserved)
        let original = try Data(contentsOf: preserved)
        try FileManager.default.createSymbolicLink(at: revision, withDestinationURL: preserved)
        XCTAssertThrowsError(try RevisionStore(directory: root).load())
        XCTAssertEqual(try Data(contentsOf: preserved), original)
    }

    func testUnchangedFlushDoesNotRotateHistory() throws {
        let root = try directory()
        let store = RevisionStore(directory: root)
        let first = Notebook()
        try store.save(first)
        var second = first
        second.pages[0].text = "neu"
        try store.save(second)
        let bytes = try Data(contentsOf: root.appendingPathComponent("manifest.json"))
        try store.save(second)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("manifest.json")), bytes)
    }

    func testFailedPreviousManifestWriteDoesNotChangeCurrentCommit() throws {
        let root = try directory()
        let store = RevisionStore(directory: root)
        let acknowledged = Notebook()
        try store.save(acknowledged)
        let primary = root.appendingPathComponent("manifest.json")
        let bytes = try Data(contentsOf: primary)
        let blocker = root.appendingPathComponent("manifest-previous.json")
        try FileManager.default.createDirectory(at: blocker, withIntermediateDirectories: false)
        var edited = acknowledged
        edited.pages[0].text = "nicht bestätigt"
        XCTAssertThrowsError(try store.save(edited))
        XCTAssertEqual(try Data(contentsOf: primary), bytes)
        XCTAssertEqual(try RevisionStore(directory: root).load(), acknowledged)
        try FileManager.default.removeItem(at: blocker)
        try store.save(edited)
        XCTAssertEqual(try RevisionStore(directory: root).load(), edited)
    }

    func testFailedFirstMigrationCommitRetainsReadableLegacyAndPreviousPointer() throws {
        let root = try directory()
        let legacy = Notebook()
        try LegacyFixture.write(legacy, to: root)
        let bytes = try Data(contentsOf: root.appendingPathComponent("notebook.json"))
        let store = RevisionStore(directory: root)
        _ = try store.load()
        let primary = root.appendingPathComponent("manifest.json")
        try FileManager.default.createDirectory(at: primary, withIntermediateDirectories: false)
        var edited = legacy
        edited.pages[0].text = "neue Eingabe"
        XCTAssertThrowsError(try store.save(edited))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("notebook.json")), bytes)
        XCTAssertEqual(try RevisionStore(directory: root).load(), legacy)
    }
}
